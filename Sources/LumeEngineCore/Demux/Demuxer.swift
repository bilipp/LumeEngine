internal import CFFmpeg
import Foundation
import Synchronization

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
    /// Folds encoder restarts and chunk seams out of the timeline (see
    /// `TimelineFolder`); continuous streams are the ones that detect them.
    private var folder = TimelineFolder()
    private var continuousStreams: Set<Int32> = []
    /// Drops what a reconnected source sends a second time (see `ReplayFilter`).
    private var replays = ReplayFilter()
    /// Per stream, a packet `ReplayFilter` called suspect, until the stream's
    /// next packet decides it. Owned: freed if never released.
    private var heldSuspects: [Int32: (packet: ReadPacket, closesReplay: Bool)] = [:]
    private var deliveredAny = false
    private var timeBases: [Int32: AVRational] = [:]
    private var serial: UInt64 = 0
    private var atEOF = false
    private var consecutiveErrors = 0
    /// Packets whose bounded send timed out, in order; retried after the next
    /// command drain. More than one when a held suspect is released together
    /// with the packet that decided it.
    private var pendingSends: [(packet: Packet, channel: Channel<Packet>)] = []
    /// Previous packet PTS per stream, for synthesizing missing durations
    /// (reader-thread-only; reset on seek).
    private var lastPTSByStream: [Int32: Int64] = [:]
    // Guarded by `lock`: total compressed payload read (delivery-rate diagnostics).
    private var bytesDelivered: Int64 = 0
    // Guarded by `lock`: timeline seams folded since open (diagnostics).
    private var seamsFolded = 0
    // Guarded by `lock`: replayed packets dropped since open (diagnostics).
    private var replaysDropped = 0
    // Guarded by `lock`: when the first packet reached an attached lane.
    private var firstDelivery: TimeInterval?

    /// Total compressed bytes demuxed so far — diff over time for the
    /// effective network delivery rate.
    public var deliveredBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return bytesDelivered
    }

    /// Timestamp discontinuities folded out of the timeline since open
    /// (encoder restarts, chunk seams) — see `TimelineFolder`.
    public var timelineSeams: Int {
        lock.lock()
        defer { lock.unlock() }
        return seamsFolded
    }

    /// Packets dropped because the source sent them a second time, typically
    /// right after FFmpeg reconnected — see `ReplayFilter`.
    public var replayedPackets: Int {
        lock.lock()
        defer { lock.unlock() }
        return replaysDropped
    }

    /// `ProcessInfo.systemUptime` when the first packet was handed to an
    /// attached lane; nil until then. Startup diagnostics.
    var firstPacketUptime: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return firstDelivery
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
                pendingSends.removeAll() // pre-seek packets; downstream drops their serial anyway
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
                if pendingSends.isEmpty {
                    readOnePacket(reading: &reading)
                } else {
                    flushPendingSends()
                }
            } else if atEOF {
                // Park until next command.
                lock.lock()
                while commands.isEmpty { lock.wait() }
                lock.unlock()
            }
        }

        discardHeldSuspects()
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
        let deadline = OpenDeadline()
        if let openTimeout = options.openTimeout {
            let token = cancelToken
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + openTimeout) {
                deadline.expire(cancelling: token)
            }
        }
        defer { _ = deadline.finish() }

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
            let expired = deadline.finish()
            eventSink.yield(.openFailed(expired
                ? openTimedOut()
                : .ffmpeg(openResult, code: .openFailed, context: "avformat_open_input")))
            return false
        }
        formatContext = openedCtx

        let infoResult = avformat_find_stream_info(openedCtx, nil)
        let expired = deadline.finish()
        guard infoResult >= 0 else {
            closeInput()
            eventSink.yield(.openFailed(expired
                ? openTimedOut()
                : .ffmpeg(infoResult, code: .openFailed, context: "avformat_find_stream_info")))
            return false
        }
        // An interrupted probe can still succeed: the MPEG-TS demuxer returns
        // what it has when its read is aborted. But the interrupt cancelled
        // the session's token for good, so every later read would abort too,
        // and the session would open onto a source that never delivers.
        guard !expired, !cancelToken.isCancelled else {
            closeInput()
            eventSink.yield(.openFailed(expired
                ? openTimedOut()
                : EngineError(code: .cancelled, message: "open cancelled")))
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
                    let type = params.pointee.codec_type
                    let coverArt = stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0
                    if type == AVMEDIA_TYPE_AUDIO || (type == AVMEDIA_TYPE_VIDEO && !coverArt) {
                        continuousStreams.insert(index)
                    }
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

    private func openTimedOut() -> EngineError {
        let seconds = options.openTimeout.map { String(format: "%.0f s", $0) } ?? "the deadline"
        return EngineError(code: .openFailed, message: "open timed out after \(seconds): the source stopped delivering while it was probed")
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
        folder.reset()
        replays.reset()
        discardHeldSuspects()
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
                discardHeldSuspects()
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

        let read = ReadPacket(
            raw: rawPacket,
            stream: streamIndex,
            pts: MediaTime.fromStream(unwrappedPts, timeBase: timeBase),
            dts: MediaTime.fromStream(unwrappedDts, timeBase: timeBase),
            duration: MediaTime.fromStream(rawPacket.pointee.duration, timeBase: timeBase)
        )

        // A reconnected source repeats what it already sent (see
        // `ReplayFilter`). Judged on the source's own time, before folding:
        // that is what the server repeats, and folded first, the repeat would
        // become a seam. A suspect waits for the stream's next packet.
        let verdict = replays.classify(stream: streamIndex, time: read.time, size: read.size)
        if let held = heldSuspects.removeValue(forKey: streamIndex) {
            if replays.settleSuspect(
                stream: streamIndex,
                time: held.packet.time,
                size: held.packet.size,
                closesReplay: held.closesReplay,
                followedBy: verdict
            ) {
                held.packet.free()
            } else {
                process(held.packet, to: channel)
            }
        }
        switch verdict {
        case .replay:
            read.free()
        case .suspect(let closesReplay):
            heldSuspects[streamIndex] = (read, closesReplay)
        case .new:
            process(read, to: channel)
        }
        let dropped = replays.replayedCount
        if dropped != replaysDropped {
            lock.lock()
            replaysDropped = dropped
            lock.unlock()
        }
    }

    /// Suspects still held when the stream ends or seeks: never confirmed as
    /// new media, and one packet at a boundary is not worth stalling for.
    private func discardHeldSuspects() {
        for held in heldSuspects.values { held.packet.free() }
        heldSuspects.removeAll()
    }

    /// Fold, fill in timing, and hand a packet read in engine time downstream.
    private func process(_ read: ReadPacket, to channel: Channel<Packet>) {
        let rawPacket = read.raw
        let streamIndex = read.stream
        var pts = read.pts
        var dts = read.dts
        var duration = read.duration

        // Fold encoder restarts and chunk seams out of the timeline. The
        // folder sees every packet of every attached stream, so a seam is
        // corrected on all of them alike.
        let seamsBefore = folder.seamCount
        let correction = folder.correction(
            stream: streamIndex,
            continuous: continuousStreams.contains(streamIndex),
            time: MediaTime.isValid(dts) ? dts : pts,
            duration: duration
        )
        if correction != 0 {
            if MediaTime.isValid(pts) { pts += correction }
            if MediaTime.isValid(dts) { dts += correction }
        }
        if folder.seamCount != seamsBefore {
            lock.lock()
            seamsFolded += folder.seamCount - seamsBefore
            lock.unlock()
        }

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

        if !deliveredAny {
            deliveredAny = true
            lock.lock()
            firstDelivery = ProcessInfo.processInfo.systemUptime
            lock.unlock()
        }

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
    /// channel is still full after the timeout, the packet waits in
    /// `pendingSends` and the main loop retries after draining commands. A
    /// closed channel (teardown/track switch mid-flight) just drops the
    /// packet and keeps the loop responsive.
    private func deliver(_ packet: Packet, to channel: Channel<Packet>) {
        pendingSends.append((packet, channel))
        flushPendingSends()
    }

    private func flushPendingSends() {
        while let next = pendingSends.first {
            if let sent = try? next.channel.send(next.packet, timeout: 0.1), !sent { return }
            pendingSends.removeFirst()
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

/// A packet read and rescaled to engine time, before seam folding. Reader
/// thread only; owns `raw` until it is processed or freed.
private struct ReadPacket {
    let raw: UnsafeMutablePointer<AVPacket>
    let stream: Int32
    let pts: Int64
    let dts: Int64
    let duration: Int64

    /// What `ReplayFilter` keys on: DTS, or PTS when there is no DTS.
    var time: Int64 { MediaTime.isValid(dts) ? dts : pts }
    var size: Int32 { raw.pointee.size }

    func free() {
        var toFree: UnsafeMutablePointer<AVPacket>? = raw
        av_packet_free(&toFree)
    }
}

/// The open deadline, shared by the reader thread and the timer that enforces
/// it. One lock decides which happened first, so the deadline either expires
/// before open finished (and the open fails) or not at all: a timer that
/// fired just as open completed must not cancel the I/O of a session that
/// goes on to play.
private final class OpenDeadline: Sendable {
    private let state = Mutex((finished: false, expired: false))

    /// Timer side: expires the deadline and interrupts I/O, unless open already finished.
    func expire(cancelling token: CancelToken) {
        let interrupt = state.withLock { state -> Bool in
            guard !state.finished else { return false }
            state.expired = true
            return true
        }
        if interrupt { token.cancel() }
    }

    /// Reader side: open is over. Returns whether the deadline expired first.
    func finish() -> Bool {
        state.withLock { state in
            state.finished = true
            return state.expired
        }
    }
}

/// C trampoline for `AVIOInterruptCB`: returns 1 to abort blocking I/O.
private func demuxInterruptCallback(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    let token = Unmanaged<CancelToken>.fromOpaque(opaque).takeUnretainedValue()
    return token.isCancelled ? 1 : 0
}
