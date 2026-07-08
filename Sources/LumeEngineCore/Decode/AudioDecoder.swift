internal import CFFmpeg
#if canImport(UIKit)
import AVFAudio
#endif
import Foundation

/// FFmpeg audio decode + resample stage: `Channel<Packet>` in,
/// `Channel<AudioFrame>` out.
///
/// Output is always interleaved Float32 at the source sample rate, downmixed
/// to at most `maxOutputChannels` — the single canonical format the renderer
/// consumes. Sources with more channels than the output route can carry are
/// downmixed here by swresample (normalized matrix); handing the sample-buffer
/// renderer more channels than the route supports produces audibly broken
/// output. Resampling context is rebuilt automatically when source parameters
/// change mid-stream (codec/parameter changes are routine on IPTV).
public final class AudioDecoder: @unchecked Sendable {
    public let events: AsyncStream<DecodeEvent>
    private let eventSink: AsyncStream<DecodeEvent>.Continuation

    private let parameters: CodecParameters
    private let input: Channel<Packet>
    private let output: Channel<AudioFrame>

    // Cross-thread lifecycle, guarded by `lock`.
    private let lock = NSCondition()
    private var started = false
    private var finished = false
    private var stopRequested = false
    private var drainRequested = false

    // Decode-thread-only state.
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var swrContext: OpaquePointer?
    private var swrSourceFormat: Int32 = -1
    private var swrSourceRate: Int32 = -1
    private var swrSourceChannels: Int32 = -1
    private var outputLayout = AVChannelLayout()
    private var currentSerial: UInt64?
    private var consecutiveErrors = 0

    private let maxConsecutiveErrors = 100
    private let maxOutputChannels: Int

    /// Channel budget of the current output route. The renderer downstream
    /// cannot correctly render more channels than the route carries, so
    /// anything beyond this is downmixed in swresample.
    public static func defaultMaxOutputChannels() -> Int {
        #if canImport(UIKit)
        return max(2, AVAudioSession.sharedInstance().maximumOutputNumberOfChannels)
        #else
        // No AVAudioSession on macOS; default output is overwhelmingly 2ch
        // (built-in speakers, headphones). Pass an explicit limit for
        // multichannel interfaces.
        return 2
        #endif
    }

    public init(
        parameters: CodecParameters,
        input: Channel<Packet>,
        output: Channel<AudioFrame>,
        maxOutputChannels: Int = AudioDecoder.defaultMaxOutputChannels()
    ) {
        self.parameters = parameters
        self.input = input
        self.output = output
        self.maxOutputChannels = max(1, maxOutputChannels)
        var continuation: AsyncStream<DecodeEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        eventSink = continuation
    }

    deinit {
        eventSink.finish()
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
        thread.name = "engine.lume.audio-decoder"
        thread.stackSize = 1 << 20
        thread.start()
    }

    public func signalEndOfStream() {
        lock.lock()
        drainRequested = true
        lock.unlock()
    }

    @discardableResult
    public func shutdown(deadline: TimeInterval = 5.0) -> Bool {
        lock.lock()
        stopRequested = true
        let wasStarted = started
        lock.unlock()

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

        guard setupCodec() else {
            eventSink.yield(.failed(EngineError(
                code: .decoderInitFailed,
                message: "no usable audio decoder for \(parameters.codecName)"
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
                    drainCodec(into: reusableFrame)
                    break
                }
                if drain {
                    lock.lock()
                    drainRequested = false
                    lock.unlock()
                    drainCodec(into: reusableFrame)
                }
                continue
            }

            if let serial = currentSerial, serial != packet.serial {
                avcodec_flush_buffers(codecContext)
            }
            currentSerial = packet.serial

            decode(packet: packet, into: reusableFrame)
        }

        finishThread()
    }

    private func decode(packet: Packet, into frame: UnsafeMutablePointer<AVFrame>) {
        guard let context = codecContext else { return }

        var sendResult = avcodec_send_packet(context, packet.raw)
        if lume_is_eagain(sendResult) != 0 {
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

    /// Resamples to interleaved Float32 and hands off an owned AVFrame.
    private func deliver(frame source: UnsafeMutablePointer<AVFrame>) {
        guard ensureResampler(for: source) else { return }

        guard let converted = av_frame_alloc() else { return }
        converted.pointee.sample_rate = source.pointee.sample_rate
        converted.pointee.format = AV_SAMPLE_FMT_FLT.rawValue
        av_channel_layout_copy(&converted.pointee.ch_layout, &outputLayout)
        // swr may buffer; size output generously.
        converted.pointee.nb_samples = source.pointee.nb_samples + 256

        guard av_frame_get_buffer(converted, 0) >= 0 else {
            var pointer: UnsafeMutablePointer<AVFrame>? = converted
            av_frame_free(&pointer)
            return
        }

        let sourcePlanes = UnsafeRawPointer(source.pointee.extended_data)?
            .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        let produced = swr_convert(
            swrContext,
            converted.pointee.extended_data, converted.pointee.nb_samples,
            sourcePlanes, source.pointee.nb_samples
        )
        guard produced > 0 else {
            var pointer: UnsafeMutablePointer<AVFrame>? = converted
            av_frame_free(&pointer)
            if produced < 0 { handleDecodeError(produced) }
            return
        }
        converted.pointee.nb_samples = produced

        let audioFrame = AudioFrame(
            adopting: converted,
            pts: source.pointee.best_effort_timestamp,
            serial: currentSerial ?? 0
        )
        try? output.send(audioFrame)
    }

    private func ensureResampler(for frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        let format = frame.pointee.format
        let rate = frame.pointee.sample_rate
        let channels = frame.pointee.ch_layout.nb_channels

        if swrContext != nil, format == swrSourceFormat, rate == swrSourceRate, channels == swrSourceChannels {
            return true
        }

        swr_free(&swrContext)
        // swr needs concrete layouts on both sides to build a (down)mix
        // matrix; sources reporting an unspecified order (routine for PCM)
        // are assumed to follow FFmpeg's default order for their count.
        var inputLayout = AVChannelLayout()
        if frame.pointee.ch_layout.order == AV_CHANNEL_ORDER_NATIVE {
            av_channel_layout_copy(&inputLayout, &frame.pointee.ch_layout)
        } else {
            av_channel_layout_default(&inputLayout, channels)
        }
        defer { av_channel_layout_uninit(&inputLayout) }
        av_channel_layout_uninit(&outputLayout)
        if channels > Int32(maxOutputChannels) {
            av_channel_layout_default(&outputLayout, Int32(maxOutputChannels))
        } else {
            av_channel_layout_copy(&outputLayout, &inputLayout)
        }
        var newContext: OpaquePointer?
        let result = swr_alloc_set_opts2(
            &newContext,
            &outputLayout, AV_SAMPLE_FMT_FLT, rate,
            &inputLayout, AVSampleFormat(rawValue: format), rate,
            0, nil
        )
        guard result >= 0, let created = newContext, swr_init(created) >= 0 else {
            handleDecodeError(nil, EngineError(code: .decodeFailed, message: "swresample init failed"))
            return false
        }
        swrContext = created
        swrSourceFormat = format
        swrSourceRate = rate
        swrSourceChannels = channels
        return true
    }

    private func drainCodec(into frame: UnsafeMutablePointer<AVFrame>) {
        guard let context = codecContext else { return }
        avcodec_send_packet(context, nil)
        receiveFrames(into: frame)
        avcodec_flush_buffers(context)
        eventSink.yield(.endOfStream(serial: currentSerial ?? 0))
    }

    private func handleDecodeError(_ code: Int32?, _ underlying: EngineError? = nil) {
        let error = underlying ?? code.map {
            EngineError.ffmpeg($0, code: .decodeFailed, context: "audio decode")
        } ?? EngineError(code: .decodeFailed, message: "audio decode failed")

        consecutiveErrors += 1
        if consecutiveErrors >= maxConsecutiveErrors {
            eventSink.yield(.failed(error))
            lock.lock()
            stopRequested = true
            lock.unlock()
        }
    }

    private func setupCodec() -> Bool {
        guard let codec = avcodec_find_decoder(parameters.raw.pointee.codec_id),
              let context = avcodec_alloc_context3(codec)
        else { return false }

        guard avcodec_parameters_to_context(context, parameters.raw) >= 0 else {
            var pointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&pointer)
            return false
        }
        context.pointee.pkt_timebase = lume_av_time_base_q()

        guard avcodec_open2(context, codec, nil) >= 0 else {
            var pointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&pointer)
            return false
        }
        codecContext = context
        return true
    }

    private func finishThread() {
        avcodec_free_context(&codecContext)
        swr_free(&swrContext)
        av_channel_layout_uninit(&outputLayout)
        output.close()
        lock.lock()
        finished = true
        lock.unlock()
        lock.broadcast()
        eventSink.finish()
    }
}
