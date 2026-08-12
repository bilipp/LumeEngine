internal import CFFmpeg

/// A linear `AVFilterGraph` — `buffer` → one filter → `buffersink` — driven
/// from the video decode thread.
///
/// Deliberately **not** `Sendable`: a filter graph is single-threaded FFmpeg
/// state, and the data-plane rule (PLAN.md D1) is that blocking FFmpeg calls
/// stay on the thread that owns them. Leaving the type non-`Sendable` makes
/// that a compiler-checked property rather than a convention — the
/// `@unchecked Sendable` budget is spent on immutable FFI wrappers only
/// (PLAN.md D2).
///
/// The graph is configured for exactly one source geometry. FFmpeg cannot
/// reconfigure a `buffer` source in place, so a geometry change means a new
/// graph; `sourceFormat` is what the caller compares against.
final class VideoFilterGraph {
    /// Everything about a source frame that the `buffer` filter is configured
    /// with. Any change invalidates the graph.
    struct SourceFormat: Equatable {
        let pixelFormat: Int32
        let width: Int32
        let height: Int32
        let sampleAspectNum: Int32
        let sampleAspectDen: Int32
        let colorSpace: Int32
        let colorRange: Int32

        init(frame: UnsafePointer<AVFrame>) {
            pixelFormat = frame.pointee.format
            width = frame.pointee.width
            height = frame.pointee.height
            // 0/x and x/0 are both "unknown"; the buffer filter wants a real ratio.
            let aspect = frame.pointee.sample_aspect_ratio
            let known = aspect.num > 0 && aspect.den > 0
            sampleAspectNum = known ? aspect.num : 1
            sampleAspectDen = known ? aspect.den : 1
            colorSpace = Int32(frame.pointee.colorspace.rawValue)
            colorRange = Int32(frame.pointee.color_range.rawValue)
        }
    }

    private let graph: UnsafeMutablePointer<AVFilterGraph>
    /// Owned by `graph` — freed with it, never separately.
    private let source: UnsafeMutablePointer<AVFilterContext>
    private let sink: UnsafeMutablePointer<AVFilterContext>

    let sourceFormat: SourceFormat

    /// Time base of frames leaving the sink. Field-doubling filters halve the
    /// input time base, so output PTS are *not* engine microseconds until they
    /// are rescaled through this.
    let outputTimeBase: AVRational

    /// - Parameters:
    ///   - filter: filter name, e.g. `bwdif`.
    ///   - options: the filter's option string, e.g. `mode=send_field`.
    ///   - format: geometry of the frames that will be pushed in.
    ///   - timeBase: time base of the input frames' PTS.
    init(
        filter: String,
        options: String,
        format: SourceFormat,
        timeBase: AVRational
    ) throws {
        guard let buffer = avfilter_get_by_name("buffer"),
              let buffersink = avfilter_get_by_name("buffersink"),
              let effect = avfilter_get_by_name(filter)
        else {
            throw EngineError(code: .unsupported, message: "filter '\(filter)' is not in this FFmpeg build")
        }

        guard let allocated = avfilter_graph_alloc() else {
            throw EngineError(code: .decoderInitFailed, message: "avfilter_graph_alloc failed")
        }
        // Owns the graph until the last statement hands it to `self`; frees it
        // on every throwing path in between.
        var unowned: UnsafeMutablePointer<AVFilterGraph>? = allocated
        defer {
            if unowned != nil { avfilter_graph_free(&unowned) }
        }

        // pix_fmt is passed numerically: av_opt's format setter falls back to
        // strtol when the value is not a known format name, which is what the
        // canonical FFmpeg filtering examples rely on.
        let arguments = [
            "video_size=\(format.width)x\(format.height)",
            "pix_fmt=\(format.pixelFormat)",
            "time_base=\(timeBase.num)/\(timeBase.den)",
            "pixel_aspect=\(format.sampleAspectNum)/\(format.sampleAspectDen)",
            "colorspace=\(format.colorSpace)",
            "range=\(format.colorRange)",
        ].joined(separator: ":")

        guard let source = avfilter_graph_alloc_filter(allocated, buffer, "in") else {
            throw EngineError(code: .decoderInitFailed, message: "cannot allocate filter source")
        }
        var status = avfilter_init_str(source, arguments)
        guard status >= 0 else {
            throw EngineError.ffmpeg(status, code: .decoderInitFailed, context: "filter source (\(arguments))")
        }

        guard let effectContext = avfilter_graph_alloc_filter(allocated, effect, filter) else {
            throw EngineError(code: .decoderInitFailed, message: "cannot allocate filter '\(filter)'")
        }
        status = avfilter_init_str(effectContext, options)
        guard status >= 0 else {
            throw EngineError.ffmpeg(status, code: .decoderInitFailed, context: "\(filter)=\(options)")
        }

        guard let sink = avfilter_graph_alloc_filter(allocated, buffersink, "out") else {
            throw EngineError(code: .decoderInitFailed, message: "cannot allocate filter sink")
        }
        status = avfilter_init_str(sink, nil)
        guard status >= 0 else {
            throw EngineError.ffmpeg(status, code: .decoderInitFailed, context: "filter sink")
        }

        // No output format is pinned: `avfilter_graph_config` negotiates, and
        // inserts conversions itself where the links disagree (NV12 off the
        // hardware path is exactly that case — the deinterlacers are planar
        // only). Letting it choose keeps bit depth and chroma layout intact,
        // which the pixel-buffer factory then maps to NV12 or P010.
        status = avfilter_link(source, 0, effectContext, 0)
        if status >= 0 { status = avfilter_link(effectContext, 0, sink, 0) }
        guard status >= 0 else {
            throw EngineError.ffmpeg(status, code: .decoderInitFailed, context: "filter link")
        }

        status = avfilter_graph_config(allocated, nil)
        guard status >= 0 else {
            throw EngineError.ffmpeg(status, code: .decoderInitFailed, context: "filter graph config")
        }

        self.graph = allocated
        self.source = source
        self.sink = sink
        self.sourceFormat = format
        self.outputTimeBase = av_buffersink_get_time_base(sink)
        unowned = nil
    }

    deinit {
        var pointer: UnsafeMutablePointer<AVFilterGraph>? = graph
        avfilter_graph_free(&pointer)
    }

    /// Pushes one frame in. The frame is referenced, not consumed — the caller
    /// keeps ownership and can unref it immediately after.
    func send(_ frame: UnsafeMutablePointer<AVFrame>) throws {
        let status = av_buffersrc_add_frame_flags(
            source, frame, Int32(AV_BUFFERSRC_FLAG_KEEP_REF)
        )
        guard status >= 0 else {
            throw EngineError.ffmpeg(status, code: .decodeFailed, context: "filter input")
        }
    }

    /// Signals end of input, so the frames the filter is holding back come out
    /// of `receive`. The graph cannot accept further input afterwards.
    func flush() throws {
        let status = av_buffersrc_add_frame_flags(source, nil, 0)
        guard status >= 0 else {
            throw EngineError.ffmpeg(status, code: .decodeFailed, context: "filter flush")
        }
    }

    /// Pulls one filtered frame out.
    ///
    /// Returns `false` when the graph needs more input — a deinterlacer holds a
    /// frame back to see the next field, so the first `send` legitimately
    /// produces nothing.
    func receive(into frame: UnsafeMutablePointer<AVFrame>) throws -> Bool {
        let status = av_buffersink_get_frame(sink, frame)
        if lume_is_eagain(status) != 0 || lume_is_eof(status) != 0 { return false }
        guard status >= 0 else {
            throw EngineError.ffmpeg(status, code: .decodeFailed, context: "filter output")
        }
        return true
    }
}
