internal import CFFmpeg
import Foundation

/// Events emitted by the demuxer on its own thread, consumed via `events`.
public enum DemuxEvent: Sendable {
    case opened(MediaInfo)
    case openFailed(EngineError)
    /// All packets read; more may follow after a backward seek.
    case endOfStream(serial: UInt64)
    case didSeek(to: Int64, serial: UInt64)
    case seekFailed(EngineError)
    /// Transient read error; the demuxer keeps going.
    case readError(EngineError)
    /// Terminal failure — the demuxer has stopped reading.
    case failed(EngineError)
    case closed
}

/// Owns one `AVFormatContext` and one dedicated reader thread.
///
/// Lifecycle (PLAN.md §3.1 — session epochs): a `Demuxer` opens exactly once and
/// closes exactly once; there is no "reopen". A new URL means a new `Demuxer`.
/// `shutdown()` is safe from any thread at any time, interrupts blocking I/O via
/// the cancel token, and joins the reader thread before freeing FFmpeg state —
/// the use-after-free class of bugs is structurally impossible.
///
/// Threading: all FFmpeg calls happen on the reader thread. Cross-thread state
/// (commands, outputs, lifecycle flags) lives behind one condition lock.
public final class Demuxer: @unchecked Sendable {
    private enum Command {
        case beginReading
        /// Target in engine µs on the *source* timeline (caller adds `MediaInfo.startTime`).
        case seek(target: Int64)
        case close
    }

    private enum LifecycleState {
        case idle, running, finished
    }

    public let events: AsyncStream<DemuxEvent>
    private let eventSink: AsyncStream<DemuxEvent>.Continuation

    private let url: String
    private let options: DemuxerOptions
    private let cancelToken = CancelToken()

    // Cross-thread state, guarded by `lock`.
    private let lock = NSCondition()
    private var commands: [Command] = []
    private var outputs: [Int32: Channel<Packet>] = [:]
    private var outputsChanged = false
    private var lifecycle: LifecycleState = .idle
    private var codecParametersByStream: [Int32: CodecParameters] = [:]

    // Reader-thread-only state (never touched off-thread).
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var normalizers: [Int32: StreamTimeNormalizer] = [:]
    private var timeBases: [Int32: AVRational] = [:]
    private var serial: UInt64 = 0
    private var atEOF = false
    private var consecutiveErrors = 0
    /// Packet whose bounded send timed out; retried after the next command drain.
    private var pendingSend: (packet: Packet, channel: Channel<Packet>)?
    /// Previous packet PTS per stream, for synthesizing missing durations
    /// (reader-thread-only; reset on seek).
    private var lastPTSByStream: [Int32: Int64] = [:]
    // Guarded by `lock`: total compressed payload read (delivery-rate diagnostics).
    private var bytesDelivered: Int64 = 0

    /// Total compressed bytes demuxed so far — diff over time for the
    /// effective network delivery rate.
    public var deliveredBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return bytesDelivered
    }

    /// Consecutive `av_read_frame` failures tolerated before declaring the
    /// source dead (PLAN.md §3.3 — a corrupt stream must fail loudly, not hang).
    private let maxConsecutiveErrors = 50

    public init(url: String, options: DemuxerOptions = DemuxerOptions()) {
        self.url = url
        self.options = options
        var continuation: AsyncStream<DemuxEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        eventSink = continuation
    }

    deinit {
        // Safety net; correct usage calls shutdown() explicitly.
        eventSink.finish()
    }

    // MARK: Public control surface (any thread)

    /// Spawns the reader thread and opens the source. Emits `.opened` or
    /// `.openFailed`. Reading starts only after `resume()` so the caller can
    /// attach packet channels first.
    public func start() {
        lock.lock()
        guard lifecycle == .idle else {
            lock.unlock()
            return
        }
        lifecycle = .running
        lock.unlock()

        let thread = Thread { [self] in threadMain() }
        thread.name = "engine.lume.demuxer"
        thread.stackSize = 1 << 20
        // Data-plane threads are latency-critical: at default QoS they get
        // descheduled on loaded devices (4K decode saturating the cores) —
        // the read cadence slows, TCP's window collapses, and network
        // throughput measurably drops below the stream's bitrate.
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Routes packets of `streamIndex` into `channel`. Streams without an
    /// attached channel are discarded at the container level (cheap).
    public func attach(channel: Channel<Packet>, toStream streamIndex: Int32) {
        lock.lock()
        outputs[streamIndex] = channel
        outputsChanged = true
        lock.unlock()
        lock.broadcast()
    }

    public func detach(streamIndex: Int32) {
        lock.lock()
        outputs.removeValue(forKey: streamIndex)
        outputsChanged = true
        lock.unlock()
        lock.broadcast()
    }

    /// Begins (or resumes after EOF-park) the read loop.
    public func resume() {
        enqueue(.beginReading)
    }

    /// Owned copy of a stream's codec parameters, available once `.opened` has
    /// been emitted. Valid independently of the demuxer's lifetime.
    public func codecParameters(forStream streamIndex: Int32) -> CodecParameters? {
        lock.lock()
        defer { lock.unlock() }
        return codecParametersByStream[streamIndex]
    }

    /// Seeks to `target` (engine µs on the source timeline). The caller is
    /// responsible for flushing downstream channels; packets from before the
    /// seek are identifiable by their stale serial.
    public func seek(to target: Int64) {
        enqueue(.seek(target: target))
    }

    /// Aborts any blocking FFmpeg I/O (including a pending open) without
    /// waiting for teardown. The demuxer then fails with a typed event.
    public func cancelIO() {
        cancelToken.cancel()
    }

    /// Interrupts I/O, stops the reader thread, closes attached channels, frees
    /// FFmpeg state. Blocks until torn down (bounded by `deadline`). Idempotent.
    @discardableResult
    public func shutdown(deadline: TimeInterval = 5.0) -> Bool {
        cancelToken.cancel()

        // Close attached channels FIRST: a reader blocked in a full channel's
        // send() can only be woken this way (the cancel token only interrupts
        // FFmpeg I/O). Without this, shutdown-under-backpressure deadlocks.
        lock.lock()
        let channels = Array(outputs.values)
        lock.unlock()
        for channel in channels { channel.close() }

        enqueue(.close)

        let limit = Date(timeIntervalSinceNow: deadline)
        lock.lock()
        defer { lock.unlock() }
        if lifecycle == .idle {
            lifecycle = .finished
            eventSink.finish()
            return true
        }
        while lifecycle != .finished {
            if !lock.wait(until: limit) { return false }
        }
        return true
    }

    private func enqueue(_ command: Command) {
        lock.lock()
        commands.append(command)
        lock.unlock()
        lock.broadcast()
    }

    // MARK: Reader thread

    private func threadMain() {
        FFmpegRuntime.initialize()

        guard openInput() else {
            finishThread()
            return
        }

        // Parked until the caller attaches channels and calls resume().
        var reading = false

        loop: while true {
            // 1. Drain commands.
            lock.lock()
            while commands.isEmpty && !reading && !atEOF {
                lock.wait()
            }
            let command = commands.isEmpty ? nil : commands.removeFirst()
            let syncOutputs = outputsChanged
            if syncOutputs { outputsChanged = false }
            lock.unlock()

            if syncOutputs { applyDiscardFlags() }

            switch command {
            case .beginReading:
                reading = true
                atEOF = false
            case .seek(let target):
                pendingSend = nil // pre-seek packet; downstream drops its serial anyway
                performSeek(to: target)
                atEOF = false
                reading = true
            case .close:
                break loop
            case nil:
                break
            }

            // 2. Deliver, then read. Sends are *bounded*: a producer parked
            // indefinitely under backpressure is deaf to commands, and a seek
            // command that cannot preempt a full pipeline deadlocks the
            // session (rate 0 + sated renderers = nothing ever drains).
            if reading && !atEOF {
                if let pending = pendingSend {
                    pendingSend = nil
                    deliver(pending.packet, to: pending.channel)
                } else {
                    readOnePacket(reading: &reading)
                }
            } else if atEOF {
                // Park until next command.
                lock.lock()
                while commands.isEmpty { lock.wait() }
                lock.unlock()
            }
        }

        closeInput()
        finishThread()
    }

    private func openInput() -> Bool {
        var ctx = avformat_alloc_context()
        guard ctx != nil else {
            eventSink.yield(.openFailed(EngineError(code: .openFailed, message: "avformat_alloc_context returned NULL")))
            return false
        }

        // Open deadline: a stalled source with no I/O timeout must not hang
        // open + probing forever. The watchdog fires the interrupt callback,
        // which aborts avformat_open_input / find_stream_info with EXIT.
        let openCompleted = CancelToken()
        if let openTimeout = options.openTimeout {
            let token = cancelToken
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + openTimeout) {
                if !openCompleted.isCancelled {
                    token.cancel()
                }
            }
        }
        defer { openCompleted.cancel() }

        // Retained handoff to FFmpeg's interrupt callback; balanced in closeInput()
        // *after* avformat_close_input — the callback can never see a freed token.
        let tokenRef = Unmanaged.passRetained(cancelToken)
        ctx!.pointee.interrupt_callback = AVIOInterruptCB(
            callback: demuxInterruptCallback,
            opaque: tokenRef.toOpaque()
        )

        var dict = options.makeDictionary()
        let openResult = avformat_open_input(&ctx, url, nil, &dict)
        av_dict_free(&dict)

        guard openResult >= 0, let openedCtx = ctx else {
            // avformat_open_input frees ctx on failure.
            tokenRef.release()
            eventSink.yield(.openFailed(.ffmpeg(openResult, code: .openFailed, context: "avformat_open_input")))
            return false
        }
        formatContext = openedCtx

        let infoResult = avformat_find_stream_info(openedCtx, nil)
        guard infoResult >= 0 else {
            closeInput()
            eventSink.yield(.openFailed(.ffmpeg(infoResult, code: .openFailed, context: "avformat_find_stream_info")))
            return false
        }

        // Per-stream time bases + wrap normalizers + codec parameter snapshots,
        // then discard everything until channels are attached.
        var snapshots: [Int32: CodecParameters] = [:]
        if let streams = openedCtx.pointee.streams {
            for i in 0..<Int(openedCtx.pointee.nb_streams) {
                guard let stream = streams[i] else { continue }
                let index = stream.pointee.index
                timeBases[index] = stream.pointee.time_base
                normalizers[index] = StreamTimeNormalizer(wrapBits: stream.pointee.pts_wrap_bits)
                if let params = stream.pointee.codecpar {
                    snapshots[index] = CodecParameters(copying: params)
                }
                stream.pointee.discard = AVDISCARD_ALL
            }
        }
        lock.lock()
        codecParametersByStream = snapshots
        lock.unlock()

        eventSink.yield(.opened(MediaInfo(context: openedCtx)))
        return true
    }

    private func applyDiscardFlags() {
        guard let ctx = formatContext, let streams = ctx.pointee.streams else { return }
        lock.lock()
        let attached = Set(outputs.keys)
        lock.unlock()
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = streams[i] else { continue }
            stream.pointee.discard = attached.contains(stream.pointee.index) ? AVDISCARD_DEFAULT : AVDISCARD_ALL
        }
    }

    private func performSeek(to target: Int64) {
        guard let ctx = formatContext else { return }
        var result = avformat_seek_file(ctx, -1, Int64.min, target, target, 0)
        if result < 0 {
            // Some containers only support keyframe-backward seeking.
            result = avformat_seek_file(ctx, -1, Int64.min, target, Int64.max, 0)
        }
        guard result >= 0 else {
            eventSink.yield(.seekFailed(.ffmpeg(result, code: .seekFailed, context: "avformat_seek_file")))
            return
        }
        serial &+= 1
        for key in normalizers.keys {
            normalizers[key]?.discontinuity()
        }
        lastPTSByStream.removeAll()
        consecutiveErrors = 0
        eventSink.yield(.didSeek(to: target, serial: serial))
    }

    private func readOnePacket(reading: inout Bool) {
        guard let ctx = formatContext, let rawPacket = av_packet_alloc() else { return }

        let result = av_read_frame(ctx, rawPacket)
        guard result >= 0 else {
            var toFree: UnsafeMutablePointer<AVPacket>? = rawPacket
            av_packet_free(&toFree)

            if lume_is_eof(result) != 0 {
                atEOF = true
                eventSink.yield(.endOfStream(serial: serial))
            } else if result == lume_averror_exit() || cancelToken.isCancelled {
                reading = false
            } else if lume_is_eagain(result) != 0 {
                Thread.sleep(forTimeInterval: 0.005)
            } else {
                consecutiveErrors += 1
                let error = EngineError.ffmpeg(result, code: .ioError, context: "av_read_frame")
                if consecutiveErrors >= maxConsecutiveErrors {
                    reading = false
                    eventSink.yield(.failed(error))
                } else {
                    eventSink.yield(.readError(error))
                }
            }
            return
        }
        consecutiveErrors = 0

        let streamIndex = rawPacket.pointee.stream_index
        lock.lock()
        let channel = outputs[streamIndex]
        bytesDelivered += Int64(rawPacket.pointee.size)
        lock.unlock()

        guard let channel, let timeBase = timeBases[streamIndex] else {
            var toFree: UnsafeMutablePointer<AVPacket>? = rawPacket
            av_packet_free(&toFree)
            return
        }

        // Normalize timing at the boundary: unwrap, then rescale to engine µs.
        // (Subscript-with-default is an in-place mutable access.)
        let (unwrappedPts, unwrappedDts) = normalizers[streamIndex, default: StreamTimeNormalizer(wrapBits: 0)]
            .normalize(pts: rawPacket.pointee.pts, dts: rawPacket.pointee.dts)

        let pts = MediaTime.fromStream(unwrappedPts, timeBase: timeBase)
        let dts = MediaTime.fromStream(unwrappedDts, timeBase: timeBase)
        var duration = MediaTime.fromStream(rawPacket.pointee.duration, timeBase: timeBase)

        // Containers routinely omit packet durations (matroska TrueHD tracks
        // without a default duration). All duration-budgeted accounting
        // downstream — read-ahead limits, buffer gates, stats — would read a
        // fully loaded queue as "0 seconds", so synthesize from the PTS step
        // to the previous packet of the same stream (capped: a step across a
        // gap is not a duration).
        if duration <= 0, MediaTime.isValid(pts) {
            if let previous = lastPTSByStream[streamIndex], pts > previous {
                duration = min(pts - previous, 1_000_000)
            }
        }
        if MediaTime.isValid(pts) { lastPTSByStream[streamIndex] = pts }

        // Rewrite the raw packet to engine time. Decoders set
        // `pkt_timebase = AV_TIME_BASE_Q`, so decoded frames come out already
        // unwrapped and in engine µs — the "nothing downstream ever sees
        // container time" invariant holds through the codec as well.
        rawPacket.pointee.pts = pts
        rawPacket.pointee.dts = dts
        rawPacket.pointee.duration = max(duration, 0)

        let packet = Packet(
            adopting: rawPacket,
            pts: pts,
            dts: dts,
            duration: duration,
            serial: serial
        )

        deliver(packet, to: channel)
    }

    /// Bounded send = backpressure that stays command-responsive: when the
    /// channel is still full after the timeout, the packet is parked in
    /// `pendingSend` and the main loop retries after draining commands. A
    /// closed channel (teardown/track switch mid-flight) just drops the
    /// packet and keeps the loop responsive.
    private func deliver(_ packet: Packet, to channel: Channel<Packet>) {
        if let sent = try? channel.send(packet, timeout: 0.1), !sent {
            pendingSend = (packet, channel)
        }
    }

    private func closeInput() {
        guard formatContext != nil else { return }
        let opaque = formatContext?.pointee.interrupt_callback.opaque
        avformat_close_input(&formatContext)
        if let opaque {
            Unmanaged<CancelToken>.fromOpaque(opaque).release()
        }
    }

    private func finishThread() {
        lock.lock()
        let channels = Array(outputs.values)
        lifecycle = .finished
        lock.unlock()
        lock.broadcast()

        for channel in channels { channel.close() }
        eventSink.yield(.closed)
        eventSink.finish()
    }
}

/// C trampoline for `AVIOInterruptCB`: returns 1 to abort blocking I/O.
private func demuxInterruptCallback(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    let token = Unmanaged<CancelToken>.fromOpaque(opaque).takeUnretainedValue()
    return token.isCancelled ? 1 : 0
}
