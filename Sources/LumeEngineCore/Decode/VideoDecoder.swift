internal import CFFmpeg
import CoreVideo
import Foundation
import VideoToolbox

/// Events emitted by decoders on their own threads.
public enum DecodeEvent: Sendable {
    /// Frames now come from software decoding: either hardware decoding kept
    /// failing mid-stream and the decoder rebuilt itself in software
    /// (continuing from the next keyframe), or VideoToolbox refused the stream
    /// and FFmpeg fell back on its own. Informational.
    case downgradedToSoftware(EngineError)
    /// The codec has been fully drained for the given serial.
    case endOfStream(serial: UInt64)
    /// Terminal: the decoder stopped.
    case failed(EngineError)
}

/// FFmpeg video decode stage: `Channel<Packet>` in, `Channel<VideoFrame>` out.
///
/// One hardware path only (PLAN.md §3.5): FFmpeg-managed VideoToolbox via
/// `get_format` + `av_hwdevice_ctx_create`. One recovery policy: on hardware
/// error, flush and resume at the next keyframe, still in hardware; only when
/// hardware keeps failing (`HardwareFailureBudget`) rebuild in software, emit
/// `.downgradedToSoftware`, and resume at the next keyframe. Software decode
/// errors are tolerated (corrupt packets must not kill the pipeline — PLAN.md
/// §3.3) until a consecutive-error limit.
public final class VideoDecoder: @unchecked Sendable {
    public enum HardwarePolicy: Sendable {
        /// Try VideoToolbox, fall back to software automatically.
        case videoToolbox
        /// Software only (exotic codecs, tests, diagnostics).
        case software
    }

    /// Deinterlacing policy. Interlaced content — most European broadcast
    /// television, so most IPTV sport — is displayed combed by any renderer
    /// that treats a field pair as one frame: horizontal fringes on anything
    /// that moves between the two fields.
    public struct Deinterlacing: Sendable, Equatable {
        public enum Mode: Sendable, Equatable {
            /// Never filter; every frame stays on the zero-copy hardware path.
            case off
            /// Filter once the decoder reports an interlaced frame
            /// (`AV_FRAME_FLAG_INTERLACED`). Detection comes from decoded-frame
            /// metadata, never from FFmpeg log strings (PLAN.md §3, failure 6).
            case auto
            /// Filter unconditionally — for encoders that ship interlaced
            /// content without flagging it, which IPTV transcoders do.
            case always
        }

        public enum Rate: Sendable, Equatable {
            /// One output frame per *field*: 1080i50 becomes 1080p50. Removes
            /// combing and doubles temporal resolution, which is what makes
            /// panning shots of a football pitch look right. Doubles the
            /// downstream frame rate, and with it render-side work.
            case field
            /// One output frame per input frame: 1080i50 becomes 1080p25.
            /// Half the output rate, so noticeably cheaper.
            case frame
        }

        public var mode: Mode
        public var rate: Rate

        public init(mode: Mode = .auto, rate: Rate = .field) {
            self.mode = mode
            self.rate = rate
        }

        public static let off = Deinterlacing(mode: .off)
    }

    public let events: AsyncStream<DecodeEvent>
    private let eventSink: AsyncStream<DecodeEvent>.Continuation

    private let parameters: CodecParameters
    private let input: Channel<Packet>
    private let output: Channel<VideoFrame>
    private let policy: HardwarePolicy
    private let deinterlacing: Deinterlacing

    // Cross-thread lifecycle, guarded by `lock`.
    private let lock = NSCondition()
    private var started = false
    private var finished = false
    private var stopRequested = false
    private var drainRequested = false
    private var deinterlaceActive = false
    private var dolbyVisionActive = false
    /// Whether the frames actually coming out are VideoToolbox surfaces; nil
    /// until the current codec has produced one. Not the same as
    /// `usingHardware`: FFmpeg falls back to software on its own, without an
    /// error, when VideoToolbox refuses a stream.
    private var framesFromHardware: Bool?

    // Decode-thread-only state.
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    /// HEVC only: strips enhancement layers (MV-HEVC's second view) before
    /// the codec sees them — see `HEVCBaseLayerFilter` for why that decides
    /// between hardware and software decoding.
    private let baseLayerFilter: HEVCBaseLayerFilter?
    /// Scratch packet for the base-layer copy of a multi-layer packet.
    private var baseLayerPacket: UnsafeMutablePointer<AVPacket>?
    private var usingHardware = false
    private var currentSerial: UInt64?
    private var waitingForKeyframe = false
    private var consecutiveErrors = 0
    private var hardwareFailures = HardwareFailureBudget()
    private let pixelFactory = PixelBufferFactory()

    // Deinterlace state, decode-thread-only.
    private var filterGraph: VideoFilterGraph? {
        didSet {
            lock.lock()
            deinterlaceActive = filterGraph != nil
            lock.unlock()
        }
    }
    /// Set when the graph could not be built or failed mid-stream. Filtering
    /// stops for the rest of the session; playback continues combed rather
    /// than stopping (PLAN.md §3.3 — degrade, never crash).
    private var filteringGivenUp = false
    private var downloadedFrame: UnsafeMutablePointer<AVFrame>?
    private var filteredFrame: UnsafeMutablePointer<AVFrame>?

    // Dolby Vision state, decode-thread-only.
    /// The stream's Dolby Vision configuration record. Only a fallback for
    /// untagged frames without an RPU of their own: the frames decide
    /// (`DolbyVisionDetection`).
    private let dolbyVisionRecord: DolbyVisionDetection.Record?
    /// Built on the first frame that needs it, so sessions without Dolby
    /// Vision never touch Metal.
    private var dolbyVisionConverter: DolbyVisionConverter?
    /// Set when the GPU path could not be built or failed mid-stream. The rest
    /// of the session plays unconverted, tinted rather than stopped (PLAN.md
    /// §3.3 — degrade, never crash), exactly like a failed deinterlacer.
    private var dolbyVisionGivenUp = false

    private let maxConsecutiveErrors = 100

    public init(
        parameters: CodecParameters,
        input: Channel<Packet>,
        output: Channel<VideoFrame>,
        policy: HardwarePolicy = .videoToolbox,
        deinterlacing: Deinterlacing = Deinterlacing()
    ) {
        self.parameters = parameters
        self.input = input
        self.output = output
        self.policy = policy
        self.deinterlacing = deinterlacing
        self.dolbyVisionRecord = DolbyVisionDetection.Record(parameters.raw)
        self.baseLayerFilter = parameters.raw.pointee.codec_id == AV_CODEC_ID_HEVC
            ? HEVCBaseLayerFilter(extradata: UnsafeRawBufferPointer(
                start: parameters.raw.pointee.extradata,
                count: Int(max(parameters.raw.pointee.extradata_size, 0))
            ))
            : nil
        var continuation: AsyncStream<DecodeEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        eventSink = continuation
    }

    deinit {
        eventSink.finish()
    }

    /// True when frames are currently produced by VideoToolbox — judged from
    /// the frames themselves once there are any, so a silent FFmpeg fallback
    /// to software reads as software.
    public var isHardwareActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return framesFromHardware ?? usingHardware
    }

    /// True while frames are being routed through the deinterlacer — i.e. the
    /// stream was found to be interlaced (or filtering was forced).
    public var isDeinterlacing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return deinterlaceActive
    }

    /// True while Dolby Vision frames with an IPT base layer are being
    /// converted to HDR10 on the GPU — judged per frame, like the conversion
    /// itself, so a source that switches to plain HDR10 reads false again.
    public var isConvertingDolbyVision: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dolbyVisionActive
    }

    // MARK: Control (any thread)

    public func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        let thread = Thread { [self] in threadMain() }
        thread.name = "engine.lume.video-decoder"
        thread.stackSize = 1 << 21 // some codecs are stack-hungry
        thread.qualityOfService = .userInteractive // data plane (see Demuxer.start)
        thread.start()
    }

    /// Asks the decoder to drain the codec once the input channel is empty and
    /// emit `.endOfStream`. The decoder stays usable (live streams resume).
    public func signalEndOfStream() {
        lock.lock()
        drainRequested = true
        lock.unlock()
    }

    /// Stops the decode thread and closes the output channel. Idempotent.
    @discardableResult
    public func shutdown(deadline: TimeInterval = 5.0) -> Bool {
        lock.lock()
        stopRequested = true
        let wasStarted = started
        lock.unlock()

        // Unblock a receive() on input and a send() on output.
        output.close()

        let limit = Date(timeIntervalSinceNow: deadline)
        lock.lock()
        defer { lock.unlock() }
        if !wasStarted {
            finished = true
            eventSink.finish()
            return true
        }
        while !finished {
            if !lock.wait(until: limit) { return false }
        }
        return true
    }

    // MARK: Decode thread

    private func threadMain() {
        FFmpegRuntime.initialize()

        let wantHardware = policy == .videoToolbox
            && Self.decoder(for: parameters.raw.pointee.codec_id, hardware: true) != nil
        if !setupCodec(hardware: wantHardware), !setupCodec(hardware: false) {
            eventSink.yield(.failed(EngineError(
                code: .decoderInitFailed,
                message: "no usable decoder for \(parameters.codecName)"
            )))
            finishThread()
            return
        }

        guard let reusableFrame = av_frame_alloc() else {
            eventSink.yield(.failed(EngineError(code: .decoderInitFailed, message: "av_frame_alloc failed")))
            finishThread()
            return
        }
        defer {
            var pointer: UnsafeMutablePointer<AVFrame>? = reusableFrame
            av_frame_free(&pointer)
        }

        if deinterlacing.mode != .off {
            downloadedFrame = av_frame_alloc()
            filteredFrame = av_frame_alloc()
            filteringGivenUp = downloadedFrame == nil || filteredFrame == nil
        }
        defer {
            filterGraph = nil
            dolbyVisionConverter = nil
            av_frame_free(&downloadedFrame)
            av_frame_free(&filteredFrame)
        }

        if baseLayerFilter != nil { baseLayerPacket = av_packet_alloc() }
        defer { av_packet_free(&baseLayerPacket) }

        while true {
            lock.lock()
            let stop = stopRequested
            let drain = drainRequested
            lock.unlock()
            if stop { break }

            guard let packet = input.receive(timeout: 0.05) else {
                if input.closed {
                    drainCodec(into: reusableFrame, emitEOFSerial: currentSerial)
                    break
                }
                if drain {
                    lock.lock()
                    drainRequested = false
                    lock.unlock()
                    drainCodec(into: reusableFrame, emitEOFSerial: currentSerial)
                }
                continue
            }

            // Seek boundary: flush and re-sync (PLAN.md §3.4 — serials make
            // stale data structurally identifiable).
            if let serial = currentSerial, serial != packet.serial {
                avcodec_flush_buffers(codecContext)
                waitingForKeyframe = false
                // The filter holds fields from before the seek; a graph is
                // cheap to rebuild and stale fields would be blended into the
                // first frame at the new position.
                filterGraph = nil
            }
            currentSerial = packet.serial

            if waitingForKeyframe {
                guard packet.isKeyframe else { continue }
                waitingForKeyframe = false
            }

            decode(packet: packet, into: reusableFrame)
        }

        finishThread()
    }

    private func decode(packet: Packet, into frame: UnsafeMutablePointer<AVFrame>) {
        guard let context = codecContext,
              let input = baseLayer(of: packet)
        else { return }

        var sendResult = avcodec_send_packet(context, input)
        if lume_is_eagain(sendResult) != 0 {
            // Decoder is full: pull frames, then retry once. Draining can
            // rebuild the codec underneath us (a delivery failure downgrades to
            // software), so the context is re-read rather than reused.
            receiveFrames(into: frame)
            guard let retryContext = codecContext else { return }
            sendResult = avcodec_send_packet(retryContext, input)
        }
        if sendResult < 0 && lume_is_eagain(sendResult) == 0 && lume_is_eof(sendResult) == 0 {
            handleDecodeError(sendResult)
            return
        }
        receiveFrames(into: frame)
    }

    private func receiveFrames(into frame: UnsafeMutablePointer<AVFrame>) {
        // Re-read per iteration, never hoisted: delivering a frame can fail,
        // and the hardware recovery policy frees this very context and opens a
        // software one. A hoisted pointer would be dangling on the next pass.
        while let context = codecContext {
            let result = avcodec_receive_frame(context, frame)
            if lume_is_eagain(result) != 0 || lume_is_eof(result) != 0 { return }
            guard result >= 0 else {
                handleDecodeError(result)
                return
            }
            consecutiveErrors = 0
            if usingHardware { hardwareFailures.recordFrame() }
            noteFrameSource(frame)
            emit(frame: frame)
            av_frame_unref(frame)
        }
    }

    /// The packet the codec should see: the demuxer's own, or a base-layer copy
    /// in the scratch packet when it carries enhancement layers. Nil when
    /// nothing of the base layer is left — never send an empty packet, which
    /// FFmpeg reads as end of stream.
    private func baseLayer(of packet: Packet) -> UnsafeMutablePointer<AVPacket>? {
        guard let filter = baseLayerFilter,
              let scratch = baseLayerPacket,
              let data = packet.raw.pointee.data,
              packet.raw.pointee.size > 0
        else { return packet.raw }

        let source = UnsafeRawBufferPointer(start: data, count: Int(packet.raw.pointee.size))
        guard let ranges = filter.baseLayerRanges(of: source) else { return packet.raw }
        let size = ranges.reduce(0) { $0 + $1.count }
        guard size > 0 else { return nil }

        av_packet_unref(scratch)
        guard av_new_packet(scratch, Int32(size)) >= 0,
              av_packet_copy_props(scratch, packet.raw) >= 0,
              let destination = scratch.pointee.data
        else {
            // Out of memory: the full packet still decodes, just in software.
            return packet.raw
        }
        var offset = 0
        for range in ranges {
            (destination + offset).update(from: data + range.lowerBound, count: range.count)
            offset += range.count
        }
        return scratch
    }

    /// Replaces the context's extradata with its base-layer version (FFmpeg's
    /// MP4 demuxer folds `lhvC` into it). Called before `avcodec_open2`.
    private func stripEnhancementLayers(fromExtradataOf context: UnsafeMutablePointer<AVCodecContext>) {
        guard let filter = baseLayerFilter,
              let extradata = context.pointee.extradata,
              context.pointee.extradata_size > 0,
              let stripped = filter.baseLayerExtradata(UnsafeRawBufferPointer(
                  start: extradata, count: Int(context.pointee.extradata_size)
              )),
              let replacement = av_mallocz(stripped.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))
        else { return }
        replacement.copyMemory(from: stripped, byteCount: stripped.count)
        av_freep(&context.pointee.extradata)
        context.pointee.extradata = replacement.assumingMemoryBound(to: UInt8.self)
        context.pointee.extradata_size = Int32(stripped.count)
    }

    /// Tracks where frames really come from. A hardware context whose frames
    /// arrive in software means FFmpeg gave up on VideoToolbox by itself —
    /// reported like any other downgrade, because silently decoding 4K in
    /// software is exactly what makes a stream stutter.
    private func noteFrameSource(_ frame: UnsafeMutablePointer<AVFrame>) {
        let hardware = frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue
        lock.lock()
        let previous = framesFromHardware
        framesFromHardware = hardware
        let attached = usingHardware
        lock.unlock()

        if attached, !hardware, previous != false {
            eventSink.yield(.downgradedToSoftware(EngineError(
                code: .decoderInitFailed,
                message: "VideoToolbox refused \(parameters.codecName); FFmpeg is decoding in software"
            )))
        }
    }

    // MARK: Deinterlace (decode thread only)

    /// Routes one decoded frame to the renderer, through the deinterlacer when
    /// the stream needs it.
    private func emit(frame: UnsafeMutablePointer<AVFrame>) {
        guard shouldDeinterlace(frame) else {
            deliver(frame: frame, pts: frame.pointee.best_effort_timestamp, duration: frame.pointee.duration)
            return
        }
        deinterlace(frame)
    }

    private func shouldDeinterlace(_ frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        guard deinterlacing.mode != .off, !filteringGivenUp else { return false }
        if deinterlacing.mode == .always { return true }
        // Once a stream has shown an interlaced frame, every frame keeps going
        // through the graph: `deint=interlaced` passes progressive frames
        // through untouched, and one path keeps the filter's temporal window
        // continuous across the progressive splices a live broadcast is full of
        // (the ad break in the middle of a 1080i match). A stream that is
        // progressive throughout never builds a graph and never leaves the
        // zero-copy path.
        if filterGraph != nil { return true }
        return frame.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0
    }

    private func deinterlace(_ frame: UnsafeMutablePointer<AVFrame>) {
        // The deinterlacers are software, planar-only filters, so a
        // VideoToolbox frame has to come back to the CPU first. This is the
        // cost of deinterlacing on the hardware path; it is still cheaper than
        // giving up hardware decode, and it keeps the decoder's lifecycle out
        // of it — no codec rebuild, no keyframe resync, and a stream that
        // switches between interlaced and progressive is just data.
        guard let software = softwarePixels(of: frame),
              let output = filteredFrame
        else {
            giveUpFiltering(deliveringInstead: frame)
            return
        }

        let format = VideoFilterGraph.SourceFormat(frame: software)
        if filterGraph?.sourceFormat != format {
            filterGraph = makeFilterGraph(format: format)
        }
        guard let graph = filterGraph else {
            giveUpFiltering(deliveringInstead: frame)
            return
        }

        do {
            try graph.send(software)
        } catch {
            giveUpFiltering(deliveringInstead: frame)
            return
        }

        do {
            // A deinterlacer holds a frame back to see the next field, so an
            // input legitimately yields zero, one, or (in field mode) two.
            while try graph.receive(into: output) {
                deliver(
                    frame: output,
                    pts: rescale(output.pointee.pts, from: graph.outputTimeBase),
                    duration: rescale(max(output.pointee.duration, 0), from: graph.outputTimeBase)
                )
                av_frame_unref(output)
            }
        } catch {
            av_frame_unref(output)
            // Input was accepted, so the frame is not lost — no fallback
            // delivery here, or it would be presented twice.
            giveUpFiltering(deliveringInstead: nil)
        }
    }

    /// Hardware frames are downloaded into a reusable scratch frame; software
    /// frames are already what the filter wants.
    private func softwarePixels(of frame: UnsafeMutablePointer<AVFrame>) -> UnsafeMutablePointer<AVFrame>? {
        guard frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue else { return frame }
        guard let scratch = downloadedFrame else { return nil }
        av_frame_unref(scratch)
        guard av_hwframe_transfer_data(scratch, frame, 0) >= 0 else { return nil }
        // Carries PTS, duration, field order and colour properties across the
        // download; the filter reads the field flags to pick field parity.
        guard av_frame_copy_props(scratch, frame) >= 0 else { return nil }
        return scratch
    }

    private func makeFilterGraph(format: VideoFilterGraph.SourceFormat) -> VideoFilterGraph? {
        let mode = deinterlacing.rate == .field ? "send_field" : "send_frame"
        // `deint=interlaced` in auto mode: frames the decoder did not flag stay
        // untouched. In `.always` the flags are what we distrust, so filter all.
        let scope = deinterlacing.mode == .always ? "all" : "interlaced"
        let options = "mode=\(mode):parity=auto:deint=\(scope)"

        // bwdif is the better filter and ships NEON kernels; yadif is the
        // fallback for a build that lacks it.
        for filter in ["bwdif", "yadif"] {
            if let graph = try? VideoFilterGraph(
                filter: filter,
                options: options,
                format: format,
                timeBase: lume_av_time_base_q()
            ) {
                return graph
            }
        }
        return nil
    }

    /// Stops filtering for the rest of the session and, when a frame is still
    /// in hand, presents it unfiltered.
    private func giveUpFiltering(deliveringInstead frame: UnsafeMutablePointer<AVFrame>?) {
        filteringGivenUp = true
        filterGraph = nil
        guard let frame else { return }
        deliver(frame: frame, pts: frame.pointee.best_effort_timestamp, duration: frame.pointee.duration)
    }

    /// Filter output carries the sink's time base — a field-doubling filter
    /// halves it — so timestamps come back to engine microseconds here.
    private func rescale(_ value: Int64, from timeBase: AVRational) -> Int64 {
        guard MediaTime.isValid(value) else { return value }
        return av_rescale_q(value, timeBase, lume_av_time_base_q())
    }

    // MARK: Delivery

    private func deliver(frame: UnsafeMutablePointer<AVFrame>, pts: Int64, duration: Int64) {
        let duration = max(duration, 0)
        let serial = currentSerial ?? 0

        var pixelBuffer: CVPixelBuffer
        var hardware = frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue
        if hardware {
            guard let opaque = frame.pointee.data.3 else { return }
            // +0 borrow; storing into VideoFrame retains it before av_frame_unref.
            pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(opaque)).takeUnretainedValue()
        } else {
            do {
                pixelBuffer = try pixelFactory.makePixelBuffer(from: frame)
            } catch {
                handleDecodeError(nil, error as? EngineError)
                return
            }
        }

        if let converted = convertDolbyVision(frame, pixelBuffer) {
            pixelBuffer = converted
            hardware = false // an engine-written surface, not VideoToolbox's
        }

        let videoFrame = VideoFrame(
            pixelBuffer: pixelBuffer,
            pts: pts,
            duration: duration,
            serial: serial,
            isHardwareDecoded: hardware
        )
        // Blocking send = backpressure; closed output (teardown) just drops.
        try? output.send(videoFrame)
    }

    // MARK: Dolby Vision (decode thread only)

    /// Converts a Dolby Vision frame whose base layer is IPTPQc2 to HDR10;
    /// nil for every other frame, which is delivered as decoded. Profile 8
    /// and the like carry the same metadata, but their base layer is already
    /// HDR10, so they stay on the zero-copy path. Decided per frame, because
    /// sources switch (see `DolbyVisionDetection`).
    private func convertDolbyVision(
        _ frame: UnsafeMutablePointer<AVFrame>,
        _ pixelBuffer: CVPixelBuffer
    ) -> CVPixelBuffer? {
        let converted = convertIfIPT(frame, pixelBuffer)
        lock.lock()
        dolbyVisionActive = converted != nil
        lock.unlock()
        return converted
    }

    private func convertIfIPT(
        _ frame: UnsafeMutablePointer<AVFrame>,
        _ pixelBuffer: CVPixelBuffer
    ) -> CVPixelBuffer? {
        guard !dolbyVisionGivenUp,
              DolbyVisionDetection.baseLayerIsIPT(
                  record: dolbyVisionRecord,
                  matrix: DolbyVisionDetection.Matrix(frame.pointee.colorspace),
                  rpu: DolbyVisionDetection.RPU(frame: frame, codecID: parameters.raw.pointee.codec_id)
              ),
              let mapping = DolbyVisionMapping(frame: frame)
        else { return nil }

        do {
            let converter = try dolbyVisionConverter ?? DolbyVisionConverter()
            dolbyVisionConverter = converter
            return try converter.convert(pixelBuffer, mapping: mapping, chromaSiting: Self.chromaSiting(of: frame))
        } catch let error as EngineError where error.code == .renderFailed {
            // The GPU refused this frame — iOS does that to a backgrounded app —
            // so this one goes out as decoded and the next one tries again.
            // Giving up here would leave the picture tinted after the app comes
            // back to the foreground.
            return nil
        } catch {
            dolbyVisionGivenUp = true
            dolbyVisionConverter = nil
            return nil
        }
    }

    private static func chromaSiting(of frame: UnsafeMutablePointer<AVFrame>) -> DolbyVisionConverter.ChromaSiting {
        switch frame.pointee.chroma_location {
        case AVCHROMA_LOC_TOPLEFT: .topLeft
        case AVCHROMA_LOC_CENTER: .center
        case AVCHROMA_LOC_TOP: .top
        // Unspecified reads as the HEVC (and MPEG-2) default.
        default: .left
        }
    }

    private func drainCodec(into frame: UnsafeMutablePointer<AVFrame>, emitEOFSerial serial: UInt64?) {
        guard let context = codecContext else { return }
        avcodec_send_packet(context, nil)
        receiveFrames(into: frame)
        drainFilter()
        // Same reason as in `receiveFrames`: draining may have replaced it.
        avcodec_flush_buffers(codecContext) // stay usable for post-EOF seeks/live resume
        eventSink.yield(.endOfStream(serial: serial ?? 0))
    }

    /// Pushes the deinterlacer's held-back fields out at end of stream. The
    /// graph is at EOF afterwards and cannot take more input, so it is dropped;
    /// a live stream that resumes simply builds a new one.
    private func drainFilter() {
        guard let graph = filterGraph, let output = filteredFrame else { return }
        filterGraph = nil
        do {
            try graph.flush()
            while try graph.receive(into: output) {
                deliver(
                    frame: output,
                    pts: rescale(output.pointee.pts, from: graph.outputTimeBase),
                    duration: rescale(max(output.pointee.duration, 0), from: graph.outputTimeBase)
                )
                av_frame_unref(output)
            }
        } catch {
            av_frame_unref(output)
        }
    }

    private func handleDecodeError(_ code: Int32?, _ underlying: EngineError? = nil) {
        let error = underlying ?? code.map {
            EngineError.ffmpeg($0, code: .decodeFailed, context: "video decode")
        } ?? EngineError(code: .decodeFailed, message: "video decode failed")

        if usingHardware {
            if !hardwareFailures.recordFailure(at: ProcessInfo.processInfo.systemUptime) {
                // Stay in hardware: drop what the codec holds and resync at the
                // next keyframe. A session VideoToolbox invalidated is rebuilt
                // by FFmpeg on the next frame it decodes.
                avcodec_flush_buffers(codecContext)
                waitingForKeyframe = true
                // The deinterlacer holds fields from before the gap; blending
                // them into the first frame after it would smear the resync.
                filterGraph = nil
                return
            }
            // Hardware keeps failing: rebuild in software, resume at the next
            // keyframe.
            teardownCodec()
            if setupCodec(hardware: false) {
                waitingForKeyframe = true
                eventSink.yield(.downgradedToSoftware(error))
                return
            }
            eventSink.yield(.failed(error))
            lock.lock()
            stopRequested = true
            lock.unlock()
            return
        }

        consecutiveErrors += 1
        if consecutiveErrors >= maxConsecutiveErrors {
            eventSink.yield(.failed(error))
            lock.lock()
            stopRequested = true
            lock.unlock()
        }
    }

    // MARK: Codec lifecycle (decode thread only)

    private func setupCodec(hardware: Bool) -> Bool {
        guard let codec = Self.decoder(for: parameters.raw.pointee.codec_id, hardware: hardware),
              let context = avcodec_alloc_context3(codec)
        else { return false }

        guard avcodec_parameters_to_context(context, parameters.raw) >= 0 else {
            var pointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&pointer)
            return false
        }
        stripEnhancementLayers(fromExtradataOf: context)

        // Demux boundary rewrote packet timestamps to engine µs.
        context.pointee.pkt_timebase = lume_av_time_base_q()

        if hardware {
            var device: UnsafeMutablePointer<AVBufferRef>?
            guard av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0 else {
                var pointer: UnsafeMutablePointer<AVCodecContext>? = context
                avcodec_free_context(&pointer)
                return false
            }
            context.pointee.hw_device_ctx = av_buffer_ref(device)
            av_buffer_unref(&device)
            context.pointee.get_format = lumeSelectPixelFormat
        } else {
            context.pointee.thread_count = 0 // auto
            context.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
        }

        guard avcodec_open2(context, codec, nil) >= 0 else {
            var pointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&pointer)
            return false
        }

        codecContext = context
        lock.lock()
        usingHardware = hardware
        framesFromHardware = nil
        lock.unlock()
        return true
    }

    private func teardownCodec() {
        avcodec_free_context(&codecContext)
    }

    private func finishThread() {
        teardownCodec()
        output.close()
        lock.lock()
        finished = true
        lock.unlock()
        lock.broadcast()
        eventSink.finish()
    }

    // MARK: Decoder choice

    /// The FFmpeg decoder for one path. Deliberately not `avcodec_find_decoder`,
    /// which returns the first registered decoder for the codec: for AV1 the
    /// right one depends on the path. FFmpeg's native `av1` decoder is the only
    /// one with a VideoToolbox hwaccel, but it cannot decode without one
    /// (libavcodec/av1dec.c); dav1d (`libdav1d`, registered first) decodes in
    /// software but has no hardware path. Taking the first registered decoder
    /// either loses AV1 hardware decoding or, without dav1d, plays AV1 as a
    /// black picture — the frames never come.
    ///
    /// Otherwise registration order is kept, and like `avcodec_find_decoder`
    /// an experimental decoder is only the last resort.
    static func decoder(for codecID: AVCodecID, hardware: Bool) -> UnsafePointer<AVCodec>? {
        if hardware, !deviceDecodesInHardware(codecID) { return nil }
        var iterator: UnsafeMutableRawPointer?
        var experimental: UnsafePointer<AVCodec>?
        while let codec = av_codec_iterate(&iterator) {
            guard codec.pointee.id == codecID, av_codec_is_decoder(codec) != 0 else { continue }
            let usable = hardware ? hasVideoToolboxConfig(codec) : !isHardwareOnly(codec)
            guard usable else { continue }
            if codec.pointee.capabilities & AV_CODEC_CAP_EXPERIMENTAL != 0 {
                experimental = experimental ?? codec
                continue
            }
            return codec
        }
        return experimental
    }

    /// Codecs whose VideoToolbox decoder depends on the chip. For these the
    /// hardware path is only worth opening when the device has one, because
    /// FFmpeg's decoder for them has no software fallback to land on. H.264
    /// and HEVC are in hardware on every supported device; the other hwaccel
    /// codecs fall back inside FFmpeg.
    private static func deviceDecodesInHardware(_ codecID: AVCodecID) -> Bool {
        switch codecID {
        case AV_CODEC_ID_AV1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        default: true
        }
    }

    private static func hasVideoToolboxConfig(_ codec: UnsafePointer<AVCodec>) -> Bool {
        var index: Int32 = 0
        while let config = avcodec_get_hw_config(codec, index) {
            if config.pointee.device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
               config.pointee.methods & Int32(AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) != 0 {
                return true
            }
            index += 1
        }
        return false
    }

    /// Decoders that open fine and then fail every packet without hardware.
    /// FFmpeg flags none of them: its native AV1 decoder is hwaccel-only by
    /// implementation (av1dec.c returns ENOSYS without one), so it is named.
    private static func isHardwareOnly(_ codec: UnsafePointer<AVCodec>) -> Bool {
        if codec.pointee.capabilities & AV_CODEC_CAP_HARDWARE != 0 { return true }
        return codec.pointee.id == AV_CODEC_ID_AV1 && String(cString: codec.pointee.name) == "av1"
    }
}

/// `get_format` trampoline: prefer VideoToolbox when a hardware device is
/// attached; otherwise take the decoder's first software format.
private func lumeSelectPixelFormat(
    _ context: UnsafeMutablePointer<AVCodecContext>?,
    _ formats: UnsafePointer<AVPixelFormat>?
) -> AVPixelFormat {
    guard let context, let formats else { return AV_PIX_FMT_NONE }
    var index = 0
    var firstSoftware = AV_PIX_FMT_NONE
    while formats[index] != AV_PIX_FMT_NONE {
        let format = formats[index]
        if format == AV_PIX_FMT_VIDEOTOOLBOX, context.pointee.hw_device_ctx != nil {
            return format
        }
        if firstSoftware == AV_PIX_FMT_NONE, format != AV_PIX_FMT_VIDEOTOOLBOX {
            firstSoftware = format
        }
        index += 1
    }
    return firstSoftware
}
