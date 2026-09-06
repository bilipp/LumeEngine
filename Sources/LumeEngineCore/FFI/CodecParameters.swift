internal import CFFmpeg

/// Owned copy of one stream's `AVCodecParameters`, snapshotted at open time so
/// decoders can be created and torn down independently of the demuxer's
/// lifetime (no shared pointers into `AVFormatContext` — PLAN.md §3.1).
public final class CodecParameters: @unchecked Sendable {
    let raw: UnsafeMutablePointer<AVCodecParameters>

    init?(copying source: UnsafePointer<AVCodecParameters>) {
        guard let allocated = avcodec_parameters_alloc() else { return nil }
        guard avcodec_parameters_copy(allocated, source) >= 0 else {
            var pointer: UnsafeMutablePointer<AVCodecParameters>? = allocated
            avcodec_parameters_free(&pointer)
            return nil
        }
        raw = allocated
    }

    public var codecName: String {
        String(cString: avcodec_get_name(raw.pointee.codec_id))
    }

    // MARK: Diagnostics accessors
    //
    // Internal, and deliberately narrow: they describe what the *source* track
    // declares, so a stream-open log line can be compared against what the
    // decode stage resolved. Digging through `AVCodecParameters` here is not
    // the `MediaInfo+FFmpeg` rule — that one is about `AVFormatContext`; this
    // is the decoders' own already-owned copy.

    /// Raw `AVCodecParameters.profile` (`AV_PROFILE_UNKNOWN` when absent).
    var profile: Int32 { raw.pointee.profile }

    var sampleRate: Int32 { raw.pointee.sample_rate }

    var channelCount: Int32 { raw.pointee.ch_layout.nb_channels }

    /// FFmpeg's formal name for the source channel layout ("5.1(side)", "7.1").
    /// `nil` when the layout is unset or the description fails.
    var channelLayoutName: String? {
        var layout = raw.pointee.ch_layout
        let capacity = 128
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: capacity)
        let written = withUnsafePointer(to: &layout) { pointer in
            av_channel_layout_describe(pointer, buffer, capacity)
        }
        guard written > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }

    deinit {
        var pointer: UnsafeMutablePointer<AVCodecParameters>? = raw
        avcodec_parameters_free(&pointer)
    }
}
