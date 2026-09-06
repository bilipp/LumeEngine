internal import CFFmpeg
import CoreVideo
import Foundation
import os

/// Events emitted by decoders on their own threads.
public enum DecodeEvent: Sendable {
    /// Hardware decoding failed mid-stream; the decoder rebuilt itself in
    /// software and continues from the next keyframe. Informational.
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
/// error, rebuild in software, emit `.downgradedToSoftware`, resume at the next
/// keyframe. Software decode errors are tolerated (corrupt packets must not
/// kill the pipeline — PLAN.md §3.3) until a consecutive-error limit.
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
    private var colorLogCount = 0

    // Decode-thread-only state.
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var usingHardware = false
    private var currentSerial: UInt64?
    private var waitingForKeyframe = false
    private var consecutiveErrors = 0
    private let pixelFactory: PixelBufferFactory

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

    private let maxConsecutiveErrors = 100

    /// Signature of the last frame whose colour handling was logged. Rebuilt
    /// and compared on every delivered frame — eight integer reads, no
    /// allocation, no formatting — so the log line below is written exactly
    /// once per stream and again only when the delivered format genuinely
    /// changes: a hardware to software downgrade, a resolution change on a
    /// live splice, or the deinterlacer engaging. See `FFmpegRuntime.diagnostics`.
    private var loggedColorSignature: ColorSignature?

    public init(
        parameters: CodecParameters,
        input: Channel<Packet>,
        output: Channel<VideoFrame>,
        policy: HardwarePolicy = .videoToolbox,
        deinterlacing: Deinterlacing = Deinterlacing(),
        preservesHDRMetadata: Bool = true
    ) {
        self.parameters = parameters
        self.input = input
        self.output = output
        self.policy = policy
        self.deinterlacing = deinterlacing
        pixelFactory = PixelBufferFactory(attachesColorMetadata: preservesHDRMetadata)
        var continuation: AsyncStream<DecodeEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        eventSink = continuation
    }

    deinit {
        eventSink.finish()
    }

    /// How many colour-handling lines this decoder has written. One per
    /// stream, plus one per genuine format change — the invariant the
    /// diagnostics rest on, and the reason it is observable at all: a
    /// regression that logs per frame is otherwise invisible until it shows up
    /// as a dropped-frame report. Guarded by `lock` (taken only when a line is
    /// actually emitted, never per frame).
    var colorDiagnosticsCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return colorLogCount
    }

    /// True when frames are currently produced by VideoToolbox.
    public var isHardwareActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return usingHardware
    }

    /// True while frames are being routed through the deinterlacer — i.e. the
    /// stream was found to be interlaced (or filtering was forced).
    public var isDeinterlacing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return deinterlaceActive
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

        let wantHardware = policy == .videoToolbox && Self.codecSupportsVideoToolbox(parameters.raw.pointee.codec_id)
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
            av_frame_free(&downloadedFrame)
            av_frame_free(&filteredFrame)
        }

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
        guard let context = codecContext else { return }

        var sendResult = avcodec_send_packet(context, packet.raw)
        if lume_is_eagain(sendResult) != 0 {
            // Decoder is full: pull frames, then retry once. Draining can
            // rebuild the codec underneath us (a delivery failure downgrades to
            // software), so the context is re-read rather than reused.
            receiveFrames(into: frame)
            guard let retryContext = codecContext else { return }
            sendResult = avcodec_send_packet(retryContext, packet.raw)
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
            emit(frame: frame)
            av_frame_unref(frame)
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

        // Read off the frame that is actually being delivered — on the
        // deinterlaced path that is the filter's output, so this is what the
        // filter produced rather than what went in.
        let colorimetry = VideoColorimetry(frame: frame)

        let pixelBuffer: CVPixelBuffer
        let hardware = frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue
        if hardware {
            guard let opaque = frame.pointee.data.3 else { return }
            // +0 borrow; storing into VideoFrame retains it before av_frame_unref.
            // Handed on untouched: VideoToolbox already tagged this surface from
            // the bitstream VUI (measured on an Apple TV 4K against a DV P8.1
            // title — all three colour keys present and the picture clean), so
            // re-stamping it could only make a working path worse.
            pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(opaque)).takeUnretainedValue()
        } else {
            do {
                pixelBuffer = try pixelFactory.makePixelBuffer(from: frame, colorimetry: colorimetry)
            } catch {
                handleDecodeError(nil, error as? EngineError)
                return
            }
        }

        // Which of the three paths produced this buffer is the whole point of
        // the readout below: they attach (or fail to attach) colour metadata
        // differently, and the deinterlaced path is the ordinary one for
        // European broadcast, not an exotic case.
        let path: DeliveryPath
        if hardware {
            path = .videoToolbox
        } else if frame == filteredFrame {
            path = .deinterlaced
        } else {
            path = .software
        }
        let signature = ColorSignature(path: path, hardwareAccelerated: usingHardware, frame: frame)
        if loggedColorSignature != signature {
            loggedColorSignature = signature
            logColorHandling(signature: signature, frame: frame, pixelBuffer: pixelBuffer)
        }

        let videoFrame = VideoFrame(
            pixelBuffer: pixelBuffer,
            pts: pts,
            duration: duration,
            serial: serial,
            isHardwareDecoded: hardware,
            colorimetry: colorimetry
        )
        // Blocking send = backpressure; closed output (teardown) just drops.
        try? output.send(videoFrame)
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
            // ONE fallback policy: rebuild software, resume at next keyframe.
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

    // MARK: Colour diagnostics (decode thread only)

    /// Which stage handed the pixel buffer over. The engine attaches no colour
    /// metadata of its own today, so what CoreVideo ends up carrying is
    /// entirely a property of the path — and the three paths differ.
    enum DeliveryPath: String {
        /// `frame.data.3` — the CVPixelBuffer VideoToolbox itself produced.
        case videoToolbox
        /// A software-decoded AVFrame wrapped by `PixelBufferFactory`
        /// directly — no filter in between.
        case software
        /// Delivered from the deinterlacer's output frame and wrapped by
        /// `PixelBufferFactory`. A VideoToolbox frame reaches this path via
        /// `softwarePixels(of:)`, which downloads it to the CPU with
        /// `av_hwframe_transfer_data` — read `hwaccel=` to tell the two apart.
        /// Deinterlacing is on by default, so this is the ordinary path for
        /// interlaced broadcast, not an exotic case.
        case deinterlaced
    }

    /// Everything that decides how a frame should be colour-tagged, as plain
    /// integers. Built for every delivered frame; formatted only when it
    /// differs from the last one logged.
    struct ColorSignature: Equatable {
        let path: DeliveryPath
        /// Whether the *codec context* was opened with the VideoToolbox
        /// hwaccel, which is not the same question as `path`. On the
        /// deinterlaced path it is the only way to tell a VideoToolbox frame
        /// downloaded to the CPU from one that was software-decoded all along,
        /// and it makes a mid-stream hardware downgrade re-log even when the
        /// delivery path does not change. `path=software hwaccel=videotoolbox`
        /// is a real and interesting state: the hwaccel is open, but this
        /// frame came back in system memory anyway.
        let hardwareAccelerated: Bool
        let width: Int32
        let height: Int32
        let pixelFormat: Int32
        let primaries: UInt32
        let transfer: UInt32
        let matrix: UInt32
        let range: UInt32

        init(path: DeliveryPath, hardwareAccelerated: Bool, frame: UnsafeMutablePointer<AVFrame>) {
            self.path = path
            self.hardwareAccelerated = hardwareAccelerated
            width = frame.pointee.width
            height = frame.pointee.height
            pixelFormat = frame.pointee.format
            primaries = frame.pointee.color_primaries.rawValue
            transfer = frame.pointee.color_trc.rawValue
            matrix = frame.pointee.colorspace.rawValue
            range = frame.pointee.color_range.rawValue
        }
    }

    /// Dumps the source's own colour signalling next to what CoreVideo is
    /// actually carrying, so the two can be compared without a debugger.
    ///
    /// `CVBufferCopyAttachments(.shouldPropagate)` is exactly the set that
    /// travels into the `CMSampleBuffer` the renderer enqueues, so an ABSENT
    /// here is an absent all the way to the display — which is what washed-out
    /// HDR looks like from the code's side.
    ///
    /// What this readout established against `hdr10.mp4` (BT.2020 / PQ /
    /// BT.2020ncl), and the reason it is worth keeping permanently:
    ///
    /// - `path=videoToolbox` — all three keys **PRESENT**. VideoToolbox tags
    ///   the buffer itself from the bitstream VUI; the zero-copy path needs
    ///   nothing from us for a correctly signalled stream.
    /// - `path=software` and `path=deinterlaced` — all three were **ABSENT**,
    ///   even though the `AVFrame` carried the full signalling.
    ///   `PixelBufferFactory` built those buffers and attached no colour
    ///   metadata. That mattered well beyond exotic software decodes: because
    ///   deinterlacing is on by default and downloads hardware frames to the
    ///   CPU, an interlaced HDR broadcast lost its colour tags *even on a
    ///   hardware decode*.
    ///
    /// That gap is now closed — `PixelBufferFactory` tags the buffers it
    /// builds, `AVCOL_*_UNSPECIFIED` mapping to no attachment at all rather
    /// than to a guessed default — and this readout is the evidence: both CPU
    /// paths must now report PRESENT for a stream that declares its colour, and
    /// must still report ABSENT for one that declares nothing. Deleting or
    /// weakening it removes the only way to tell those two apart in the field.
    private func logColorHandling(
        signature: ColorSignature,
        frame: UnsafeMutablePointer<AVFrame>,
        pixelBuffer: CVPixelBuffer
    ) {
        let attachments = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) as NSDictionary?
        func attached(_ key: CFString) -> String {
            guard let value = attachments?[key] else { return "ABSENT" }
            return "PRESENT(\(value))"
        }
        // The raw value is always printed alongside the name, and not only as
        // a fallback: FFmpeg's own name for `AVCOL_*_UNSPECIFIED` is the
        // string "unknown", which is otherwise indistinguishable from a value
        // it has no name for — and "unspecified" is exactly the case that must
        // stay distinguishable, because it is the one that maps to no
        // attachment at all rather than to a guessed default.
        func named(_ pointer: UnsafePointer<CChar>?, raw: UInt32) -> String {
            let name = pointer.map { String(cString: $0) } ?? "unnamed"
            return "\(name)(\(raw))"
        }

        let source = [
            "primaries=" + named(
                av_color_primaries_name(frame.pointee.color_primaries), raw: signature.primaries
            ),
            "transfer=" + named(
                av_color_transfer_name(frame.pointee.color_trc), raw: signature.transfer
            ),
            "matrix=" + named(
                av_color_space_name(frame.pointee.colorspace), raw: signature.matrix
            ),
            "range=" + named(
                av_color_range_name(frame.pointee.color_range), raw: signature.range
            )
        ].joined(separator: " ")

        let coreVideo = [
            "ColorPrimaries=" + attached(kCVImageBufferColorPrimariesKey),
            "TransferFunction=" + attached(kCVImageBufferTransferFunctionKey),
            "YCbCrMatrix=" + attached(kCVImageBufferYCbCrMatrixKey)
        ].joined(separator: " ")

        // Everything CoreVideo carries that is *not* one of the three colour
        // keys. A count on its own ("4 attachments, none of them colour") is
        // no use to a measurement pass; the names say whether the buffer is
        // bare or merely missing colour.
        let colorKeys: Set<String> = [
            kCVImageBufferColorPrimariesKey as String,
            kCVImageBufferTransferFunctionKey as String,
            kCVImageBufferYCbCrMatrixKey as String
        ]
        let otherKeys = (attachments?.allKeys as? [String] ?? [])
            .filter { !colorKeys.contains($0) }
            .sorted()
            .joined(separator: ",")

        let pixelFormatName = av_get_pix_fmt_name(AVPixelFormat(rawValue: signature.pixelFormat))
            .map { String(cString: $0) } ?? "unknown(\(signature.pixelFormat))"

        let message = "video-format path=\(signature.path.rawValue)"
            + " hwaccel=\(signature.hardwareAccelerated ? "videotoolbox" : "none")"
            + " codec=\(parameters.codecName)"
            + " \(signature.width)x\(signature.height)"
            + " avframe=\(pixelFormatName)"
            + " cvpixelbuffer=\(Self.fourCC(CVPixelBufferGetPixelFormatType(pixelBuffer)))"
            + " source[\(source)]"
            + " cvbuffer[\(coreVideo)]"
            + " otherAttachments[\(otherKeys)]"
        FFmpegRuntime.diagnostics.notice("\(message, privacy: .public)")
        lock.lock()
        colorLogCount += 1
        lock.unlock()
    }

    /// `'420v'` rather than `875704438`; falls back to the number for the
    /// pixel-format types that are not four printable characters.
    static func fourCC(_ value: OSType) -> String {
        let bytes = [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ]
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }),
              let text = String(bytes: bytes, encoding: .ascii)
        else { return "\(value)" }
        return "'\(text)'"
    }

    // MARK: Codec lifecycle (decode thread only)

    private func setupCodec(hardware: Bool) -> Bool {
        guard let codec = avcodec_find_decoder(parameters.raw.pointee.codec_id),
              let context = avcodec_alloc_context3(codec)
        else { return false }

        guard avcodec_parameters_to_context(context, parameters.raw) >= 0 else {
            var pointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&pointer)
            return false
        }

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

    static func codecSupportsVideoToolbox(_ codecID: AVCodecID) -> Bool {
        guard let codec = avcodec_find_decoder(codecID) else { return false }
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
