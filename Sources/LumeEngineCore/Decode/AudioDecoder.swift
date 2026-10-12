internal import CFFmpeg
#if canImport(UIKit)
import AVFAudio
#endif
import Foundation

/// FFmpeg audio decode + resample stage: `Channel<Packet>` in,
/// `Channel<AudioFrame>` out.
///
/// Output is always interleaved Float32 at the source sample rate, in the
/// speaker layout `AudioLayoutPolicy` picks for the output route — the single
/// canonical format the renderer consumes. Sources with more channels than
/// the route carries are folded down here by swresample with an explicit
/// matrix (`DownmixMatrix`); handing the sample-buffer renderer more channels
/// than the route supports produces audibly broken output. The resampling
/// context is rebuilt when source parameters change mid-stream (codec and
/// parameter changes are routine on IPTV) and when the route's width changes
/// (`AudioOutputRoute`), in both cases at a frame boundary.
///
/// Decoded frames are coalesced to at least `minOutputDuration` before
/// emission. Some codecs decode to frames far too small to schedule
/// individually — TrueHD produces 40-sample access units (0.83 ms at 48 kHz,
/// 1200 frames/s), at which point duration-budgeted frame queues hold almost
/// no audio and per-buffer costs swamp the render path. Common codecs
/// (AAC 1024, AC-3 1536 samples) already exceed the floor and pass through 1:1.
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
    private var swrRouteChannels = -1
    private var outputLayout = AVChannelLayout()
    private var currentSerial: UInt64?
    private var consecutiveErrors = 0

    // Coalescing buffer (decode-thread-only): converted samples accumulate
    // here until `minOutputDuration` is reached.
    private var pendingFrame: UnsafeMutablePointer<AVFrame>?
    private var pendingCapacity: Int32 = 0
    private var pendingFilled: Int32 = 0
    private var pendingPTS: Int64 = MediaTime.noTimestamp
    private var pendingSerial: UInt64 = 0

    /// Emission floor in seconds; see the type docs for why tiny decoded
    /// frames must not reach the frame queue individually.
    private static let minOutputDuration = 0.020

    private let maxConsecutiveErrors = 100
    private let route: AudioOutputRoute
    /// What the resampler currently produces. Guarded by `lock`.
    private var appliedOutput: AudioOutputLayout?

    /// The layout decoded audio currently leaves in, and the route width it
    /// was chosen for; nil before the first frame.
    public var currentOutput: AudioOutputLayout? {
        lock.lock()
        defer { lock.unlock() }
        return appliedOutput
    }

    /// Channel budget of the current output route. The renderer downstream
    /// cannot correctly render more channels than the route carries, so
    /// anything beyond this is downmixed in swresample.
    ///
    /// This must be the *negotiated* output width, not the route's capability:
    /// `maximumOutputNumberOfChannels` reports what the hardware could carry
    /// (8 over HDMI), but multichannel LPCM only flows once the app activates
    /// an audio session with a matching `preferredOutputNumberOfChannels`.
    /// Feeding the renderer more channels than the session actually outputs
    /// fails the renderer outright (silence, wedged pipeline) — configuring
    /// the session for surround is the app's job (PLAN.md §2.1), the engine
    /// just honors whatever was negotiated. This reads it once, for a decoder
    /// of fixed width; `PlayerSession` follows route changes instead
    /// (`AudioOutputRoute`).
    public static func defaultMaxOutputChannels() -> Int {
        #if canImport(UIKit)
        return max(2, AVAudioSession.sharedInstance().outputNumberOfChannels)
        #else
        // No AVAudioSession on macOS; default output is overwhelmingly 2ch
        // (built-in speakers, headphones). Pass an explicit limit for
        // multichannel interfaces.
        return 2
        #endif
    }

    /// A decoder whose output width is fixed at `maxOutputChannels`.
    public convenience init(
        parameters: CodecParameters,
        input: Channel<Packet>,
        output: Channel<AudioFrame>,
        maxOutputChannels: Int = AudioDecoder.defaultMaxOutputChannels()
    ) {
        self.init(
            parameters: parameters,
            input: input,
            output: output,
            route: AudioOutputRoute(outputChannels: maxOutputChannels)
        )
    }

    /// A decoder whose output follows `route` as it changes.
    public init(
        parameters: CodecParameters,
        input: Channel<Packet>,
        output: Channel<AudioFrame>,
        route: AudioOutputRoute
    ) {
        self.parameters = parameters
        self.input = input
        self.output = output
        self.route = route
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
        thread.qualityOfService = .userInteractive // data plane (see Demuxer.start)
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
                dropPending() // pre-seek samples must not merge into the new serial
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

    /// Resamples to interleaved Float32 into the pending coalescing buffer,
    /// emitting an owned AVFrame once `minOutputDuration` has accumulated.
    private func deliver(frame source: UnsafeMutablePointer<AVFrame>) {
        guard ensureResampler(for: source) else { return }

        // swr may buffer a few samples internally; reserve slack beyond the input.
        let required = source.pointee.nb_samples + 256
        if pendingFrame != nil, pendingCapacity - pendingFilled < required {
            emitPending()
        }
        if pendingFrame == nil {
            let floor = Int32(Self.minOutputDuration * Double(source.pointee.sample_rate))
            guard allocatePending(capacity: floor + required, sampleRate: source.pointee.sample_rate) else {
                return
            }
        }
        guard let pending = pendingFrame else { return }

        if pendingFilled == 0 {
            pendingPTS = source.pointee.best_effort_timestamp
            pendingSerial = currentSerial ?? 0
        }

        let channels = Int(pending.pointee.ch_layout.nb_channels)
        let sourcePlanes = UnsafeRawPointer(source.pointee.extended_data)?
            .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        var writeHead: UnsafeMutablePointer<UInt8>? = pending.pointee.data.0!
            + Int(pendingFilled) * channels * MemoryLayout<Float>.size
        let produced = withUnsafeMutablePointer(to: &writeHead) { destination in
            swr_convert(
                swrContext,
                destination, pendingCapacity - pendingFilled,
                sourcePlanes, source.pointee.nb_samples
            )
        }
        guard produced >= 0 else {
            handleDecodeError(produced)
            return
        }
        pendingFilled += produced

        let floor = Int32(Self.minOutputDuration * Double(pending.pointee.sample_rate))
        if pendingFilled >= floor {
            emitPending()
        }
    }

    private func allocatePending(capacity: Int32, sampleRate: Int32) -> Bool {
        guard let frame = av_frame_alloc() else { return false }
        frame.pointee.sample_rate = sampleRate
        frame.pointee.format = AV_SAMPLE_FMT_FLT.rawValue
        av_channel_layout_copy(&frame.pointee.ch_layout, &outputLayout)
        frame.pointee.nb_samples = capacity
        guard av_frame_get_buffer(frame, 0) >= 0 else {
            var pointer: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&pointer)
            return false
        }
        pendingFrame = frame
        pendingCapacity = capacity
        pendingFilled = 0
        return true
    }

    /// Sends whatever has accumulated (a partial buffer is fine — emission
    /// points are the duration floor, EOF drain, and format changes).
    private func emitPending() {
        guard let pending = pendingFrame else { return }
        pendingFrame = nil
        guard pendingFilled > 0 else {
            var pointer: UnsafeMutablePointer<AVFrame>? = pending
            av_frame_free(&pointer)
            return
        }
        pending.pointee.nb_samples = pendingFilled
        pendingFilled = 0
        let audioFrame = AudioFrame(adopting: pending, pts: pendingPTS, serial: pendingSerial)
        try? output.send(audioFrame)
    }

    private func dropPending() {
        guard let pending = pendingFrame else { return }
        pendingFrame = nil
        pendingFilled = 0
        var pointer: UnsafeMutablePointer<AVFrame>? = pending
        av_frame_free(&pointer)
    }

    private func ensureResampler(for frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        let format = frame.pointee.format
        let rate = frame.pointee.sample_rate
        let channels = frame.pointee.ch_layout.nb_channels
        let routeChannels = route.outputChannels

        if swrContext != nil, format == swrSourceFormat, rate == swrSourceRate, channels == swrSourceChannels,
           routeChannels == swrRouteChannels {
            return true
        }

        // Samples of the previous layout cannot share a buffer. Same-rate
        // conversion holds nothing back inside swr, so emitting the pending
        // buffer is all a switch needs to land on a frame boundary.
        emitPending()
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
        var matrix: [Double]?
        if inputLayout.order == AV_CHANNEL_ORDER_NATIVE {
            let source = SpeakerSet(rawValue: inputLayout.u.mask)
            let plan = AudioLayoutPolicy.plan(source: source, routeChannels: routeChannels)
            if plan.remixes {
                av_channel_layout_from_mask(&outputLayout, plan.output.rawValue)
                matrix = DownmixMatrix.flatCoefficients(from: source, to: plan.output)
            } else {
                av_channel_layout_copy(&outputLayout, &inputLayout)
            }
        } else if channels > Int32(routeChannels) {
            // No positions to plan with (more channels than FFmpeg has a
            // default order for): fold to the route's default layout and let
            // swr do what it can.
            av_channel_layout_default(&outputLayout, Int32(routeChannels))
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
        // A custom matrix goes in between allocation and init. Without one
        // (no remix, or a layout pair the builder refused) swr builds its own
        // from the two layouts.
        if result >= 0, let created = newContext, let matrix {
            _ = matrix.withUnsafeBufferPointer {
                swr_set_matrix(created, $0.baseAddress, Int32(DownmixMatrix.stride))
            }
        }
        guard result >= 0, let created = newContext, swr_init(created) >= 0 else {
            swr_free(&newContext)
            handleDecodeError(nil, EngineError(code: .decodeFailed, message: "swresample init failed"))
            return false
        }
        swrContext = created
        swrSourceFormat = format
        swrSourceRate = rate
        swrSourceChannels = channels
        swrRouteChannels = routeChannels
        let applied = AudioOutputLayout(
            sourceChannels: Int(channels),
            outputChannels: Int(outputLayout.nb_channels),
            routeChannels: routeChannels
        )
        lock.lock()
        appliedOutput = applied
        lock.unlock()
        return true
    }

    private func drainCodec(into frame: UnsafeMutablePointer<AVFrame>) {
        guard let context = codecContext else { return }
        avcodec_send_packet(context, nil)
        receiveFrames(into: frame)
        emitPending() // the tail below the coalescing floor still belongs to the stream
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

    /// The decoder the audio lane opens for `codecID`; also what
    /// `TrackInfo.isDecodable` asks, so the two cannot disagree.
    static func decoder(for codecID: AVCodecID) -> UnsafePointer<AVCodec>? {
        avcodec_find_decoder(codecID)
    }

    private func setupCodec() -> Bool {
        guard let codec = Self.decoder(for: parameters.raw.pointee.codec_id),
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
        dropPending()
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
