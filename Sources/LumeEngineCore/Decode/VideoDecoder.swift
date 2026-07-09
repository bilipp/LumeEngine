internal import CFFmpeg
import CoreVideo
import Foundation

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

    public let events: AsyncStream<DecodeEvent>
    private let eventSink: AsyncStream<DecodeEvent>.Continuation

    private let parameters: CodecParameters
    private let input: Channel<Packet>
    private let output: Channel<VideoFrame>
    private let policy: HardwarePolicy

    // Cross-thread lifecycle, guarded by `lock`.
    private let lock = NSCondition()
    private var started = false
    private var finished = false
    private var stopRequested = false
    private var drainRequested = false

    // Decode-thread-only state.
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var usingHardware = false
    private var currentSerial: UInt64?
    private var waitingForKeyframe = false
    private var consecutiveErrors = 0
    private let pixelFactory = PixelBufferFactory()

    private let maxConsecutiveErrors = 100

    public init(
        parameters: CodecParameters,
        input: Channel<Packet>,
        output: Channel<VideoFrame>,
        policy: HardwarePolicy = .videoToolbox
    ) {
        self.parameters = parameters
        self.input = input
        self.output = output
        self.policy = policy
        var continuation: AsyncStream<DecodeEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        eventSink = continuation
    }

    deinit {
        eventSink.finish()
    }

    /// True when frames are currently produced by VideoToolbox.
    public var isHardwareActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return usingHardware
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
            // Decoder is full: pull frames, then retry once.
            receiveFrames(into: frame)
            sendResult = avcodec_send_packet(context, packet.raw)
        }
        if sendResult < 0 && lume_is_eagain(sendResult) == 0 && lume_is_eof(sendResult) == 0 {
            handleDecodeError(sendResult)
            return
        }
        receiveFrames(into: frame)
    }

    private func receiveFrames(into frame: UnsafeMutablePointer<AVFrame>) {
        guard let context = codecContext else { return }
        while true {
            let result = avcodec_receive_frame(context, frame)
            if lume_is_eagain(result) != 0 || lume_is_eof(result) != 0 { return }
            guard result >= 0 else {
                handleDecodeError(result)
                return
            }
            consecutiveErrors = 0
            deliver(frame: frame)
            av_frame_unref(frame)
        }
    }

    private func deliver(frame: UnsafeMutablePointer<AVFrame>) {
        let pts = frame.pointee.best_effort_timestamp
        let duration = max(frame.pointee.duration, 0)
        let serial = currentSerial ?? 0

        let pixelBuffer: CVPixelBuffer
        let hardware = frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue
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

    private func drainCodec(into frame: UnsafeMutablePointer<AVFrame>, emitEOFSerial serial: UInt64?) {
        guard let context = codecContext else { return }
        avcodec_send_packet(context, nil)
        receiveFrames(into: frame)
        avcodec_flush_buffers(context) // stay usable for post-EOF seeks/live resume
        eventSink.yield(.endOfStream(serial: serial ?? 0))
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
