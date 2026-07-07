import Foundation

/// Events surfaced to the app layer (PLAN.md D8 — typed events, no delegates).
public enum PlayerEvent: Sendable {
    case stateChanged(PlayerSession.State)
    case opened(MediaInfo)
    case decoderDowngraded(EngineError)
    case didSeek(position: Double)
    /// Playback should be progressing but the clock hasn't moved for
    /// `stallThreshold` seconds (dead source, starved network, silent decoder
    /// death upstream). The engine kicks seekable sources once; live sources
    /// are the app's cue to reconnect (Lume: PlaybackRetryController).
    case stalled(position: Double)
    case error(EngineError)
}

/// Per-session configuration (PLAN.md §3.8 — no global knobs).
public struct PlayerConfiguration: Sendable {
    public var demuxer = DemuxerOptions()
    public var hardwareDecode: VideoDecoder.HardwarePolicy = .videoToolbox
    /// Seconds of decoded media to buffer before starting/resuming playback.
    public var bufferTarget: Double = 1.0
    /// Frame-channel capacities (video frames retain pixel buffers — keep small).
    public var videoQueueDepth = 8
    public var audioQueueDepth = 48
    public var enableVideo = true
    public var enableAudio = true
    public var muted = false
    /// Seconds without clock progress (while expected) before `.stalled` fires.
    public var stallThreshold: Double = 8

    public init() {}
}

/// The control plane: owns one media source end-to-end (demuxer → decoders →
/// renderer) and serializes every lifecycle operation on the actor.
///
/// Session-epoch rule (PLAN.md §3.1): a `PlayerSession` opens exactly one URL.
/// A new URL is a new session — there is no rebuild-in-place, so the
/// rebuild-races-decoder class of use-after-free bugs is unrepresentable. State is derived, never cached
/// across opens (§3.4).
public actor PlayerSession {
    public enum State: Sendable, Equatable {
        case idle
        case opening
        case ready
        case buffering
        case playing
        case paused
        case ended
        case failed
    }

    public nonisolated let events: AsyncStream<PlayerEvent>
    private let eventSink: AsyncStream<PlayerEvent>.Continuation

    private let configuration: PlayerConfiguration
    /// The presentation backend; expose `renderer.displayLayer` in a view.
    public nonisolated let renderer: SystemRenderer
    /// Active subtitle cues (embedded track or external file). Query with
    /// `activeCues(at: renderer.currentTime)` from any thread.
    public nonisolated let subtitles = SubtitleStore()

    private(set) var state: State = .idle {
        didSet {
            if state != oldValue { eventSink.yield(.stateChanged(state)) }
        }
    }

    private var demuxer: Demuxer?
    private var videoDecoder: VideoDecoder?
    private var audioDecoder: AudioDecoder?
    private var videoPackets: Channel<Packet>?
    private var audioPackets: Channel<Packet>?
    private var videoFrames: Channel<VideoFrame>?
    private var audioFrames: Channel<AudioFrame>?

    private var info: MediaInfo?
    private var openContinuation: CheckedContinuation<MediaInfo, Error>?
    private var pumpTasks: [Task<Void, Never>] = []
    private var monitorTask: Task<Void, Never>?

    private var targetRate: Float = 1.0
    private var shouldPlay = false
    private var currentSerial: UInt64 = 0
    private var demuxAtEOF = false
    private var videoAtEOF = false
    private var audioAtEOF = false
    private var lastError: EngineError?
    private var pendingSeekTarget: Int64?

    // Stall watchdog (PLAN.md §3.3 — silence is never an acceptable failure mode).
    private var lastObservedPosition: Double = -1
    private var lastProgressDate = Date.distantFuture
    private var lastStallKick: Date?

    // Track lanes (see PlayerSession+Tracks.swift).
    private var subtitleDecoder: SubtitleDecoder?
    private var subtitlePackets: Channel<Packet>?
    public private(set) var selectedAudioTrackIndex: Int32?
    public private(set) var selectedVideoTrackIndex: Int32?
    public private(set) var selectedSubtitleTrackIndex: Int32?
    public private(set) var usingExternalSubtitles = false

    public init(configuration: PlayerConfiguration = PlayerConfiguration()) {
        self.configuration = configuration
        renderer = SystemRenderer(muted: configuration.muted)
        var continuation: AsyncStream<PlayerEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        eventSink = continuation
    }

    // MARK: Lifecycle

    /// Opens the source and prepares the pipeline. One call per session.
    @discardableResult
    public func open(url: String) async throws -> MediaInfo {
        guard state == .idle else {
            throw EngineError(code: .invalidState, message: "PlayerSession.open called twice — create a new session")
        }
        state = .opening

        let demuxer = Demuxer(url: url, options: configuration.demuxer)
        self.demuxer = demuxer
        demuxer.start()

        let pump = Task { [events = demuxer.events] in
            for await event in events {
                await self.handleDemux(event)
            }
        }
        pumpTasks.append(pump)

        do {
            // Cancellation-safe: cancelling the calling task aborts FFmpeg I/O,
            // which resolves the continuation through the .openFailed event.
            let info = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    openContinuation = continuation
                }
            } onCancel: {
                demuxer.cancelIO()
            }
            try buildPipeline(info: info)
            state = .ready
            eventSink.yield(.opened(info))
            return info
        } catch {
            let engineError = (error as? EngineError) ?? EngineError(code: .openFailed, message: "\(error)")
            lastError = engineError
            state = .failed
            eventSink.yield(.error(engineError))
            throw engineError
        }
    }

    private func buildPipeline(info: MediaInfo) throws {
        guard let demuxer else { throw EngineError(code: .invalidState, message: "no demuxer") }
        self.info = info

        // Default track selection: container default flag, else first of kind.
        let videoTrack = configuration.enableVideo
            ? info.videoTracks.first(where: \.isDefault) ?? info.videoTracks.first
            : nil
        let audioTrack = configuration.enableAudio
            ? info.audioTracks.first(where: \.isDefault) ?? info.audioTracks.first
            : nil

        guard videoTrack != nil || audioTrack != nil else {
            throw EngineError(code: .unsupported, message: "source has no playable tracks")
        }

        selectedVideoTrackIndex = videoTrack?.index
        selectedAudioTrackIndex = audioTrack?.index

        if let track = videoTrack,
           let parameters = demuxer.codecParameters(forStream: track.index) {
            let packets = Channel<Packet>(capacity: 256, measure: { max($0.duration, 0) })
            let frames = Channel<VideoFrame>(capacity: configuration.videoQueueDepth, measure: { max($0.duration, 0) })
            demuxer.attach(channel: packets, toStream: track.index)
            let decoder = VideoDecoder(parameters: parameters, input: packets, output: frames, policy: configuration.hardwareDecode)
            videoPackets = packets
            videoFrames = frames
            videoDecoder = decoder
            let pump = Task { [events = decoder.events] in
                for await event in events {
                    await self.handleDecode(event, isVideo: true)
                }
            }
            pumpTasks.append(pump)
            decoder.start()
        }

        if let track = audioTrack,
           let parameters = demuxer.codecParameters(forStream: track.index) {
            let packets = Channel<Packet>(capacity: 256, measure: { max($0.duration, 0) })
            let frames = Channel<AudioFrame>(capacity: configuration.audioQueueDepth, measure: { $0.duration })
            demuxer.attach(channel: packets, toStream: track.index)
            let decoder = AudioDecoder(parameters: parameters, input: packets, output: frames)
            audioPackets = packets
            audioFrames = frames
            audioDecoder = decoder
            let pump = Task { [events = decoder.events] in
                for await event in events {
                    await self.handleDecode(event, isVideo: false)
                }
            }
            pumpTasks.append(pump)
            decoder.start()
        }

        renderer.attach(video: videoFrames, audio: audioFrames)
        renderer.flush(acceptingSerial: 0)
        renderer.setRate(0, anchoredAt: startTimeline)
        demuxer.resume()

        monitorTask = Task {
            await self.monitorLoop()
        }
    }

    /// Timeline origin: media start time plus any requested start position.
    private var startTimeline: Int64 {
        info?.startTime ?? 0
    }

    // MARK: Transport

    public func play() {
        guard state == .ready || state == .paused || state == .buffering || state == .playing || state == .ended else { return }
        shouldPlay = true
        evaluatePlayback()
    }

    public func pause() {
        guard state == .playing || state == .buffering else { return }
        shouldPlay = false
        renderer.setRate(0)
        state = .paused
    }

    public func setRate(_ rate: Float) {
        targetRate = max(0.1, rate)
        if state == .playing {
            renderer.setRate(targetRate)
        }
    }

    public var rate: Float { targetRate }

    /// Position in seconds relative to the start of the media.
    public var position: Double {
        let now = renderer.currentTime
        guard MediaTime.isValid(now), let info else { return 0 }
        return max(0, MediaTime.seconds(now - info.startTime))
    }

    public var duration: Double? {
        info?.duration.map(MediaTime.seconds)
    }

    public var mediaInfo: MediaInfo? { info }

    // MARK: Seek

    /// Seeks to `position` seconds (media-relative). Flush order matters:
    /// channels first (unblocks producers), then the demuxer repositions, then
    /// the renderer accepts only the new serial (PLAN.md §3.4).
    public func seek(to position: Double) {
        guard let demuxer, let info else { return }
        let clamped = max(0, position)
        let target = info.startTime + MediaTime.microseconds(clamped)
        pendingSeekTarget = target

        videoPackets?.flush()
        audioPackets?.flush()
        subtitlePackets?.flush()
        videoFrames?.flush()
        audioFrames?.flush()
        renderer.setRate(0)
        demuxAtEOF = false
        videoAtEOF = false
        audioAtEOF = false
        demuxer.seek(to: target)
        // Completion continues in handleDemux(.didSeek).
    }

    // MARK: Teardown

    /// Stops everything. Bounded, idempotent, safe at any point of the lifecycle.
    public func shutdown() {
        monitorTask?.cancel()
        monitorTask = nil
        renderer.shutdown()
        videoDecoder?.shutdown()
        audioDecoder?.shutdown()
        subtitleDecoder?.shutdown()
        demuxer?.shutdown()
        for task in pumpTasks { task.cancel() }
        pumpTasks.removeAll()
        if state != .failed { state = .idle }
        eventSink.finish()
    }

    // MARK: Track-lane internals (used by PlayerSession+Tracks.swift)

    var activeDemuxer: Demuxer? { demuxer }

    func replaceAudioLane(demuxer: Demuxer, trackIndex: Int32, parameters: CodecParameters) {
        if let old = selectedAudioTrackIndex {
            demuxer.detach(streamIndex: old)
        }
        audioDecoder?.shutdown(deadline: 2)
        audioPackets?.close()

        let packets = Channel<Packet>(capacity: 256, measure: { max($0.duration, 0) })
        let frames = Channel<AudioFrame>(capacity: configuration.audioQueueDepth, measure: { $0.duration })
        demuxer.attach(channel: packets, toStream: trackIndex)
        let decoder = AudioDecoder(parameters: parameters, input: packets, output: frames)
        audioPackets = packets
        audioFrames = frames
        audioDecoder = decoder
        audioAtEOF = false
        selectedAudioTrackIndex = trackIndex
        let pump = Task { [events = decoder.events] in
            for await event in events {
                await self.handleDecode(event, isVideo: false)
            }
        }
        pumpTasks.append(pump)
        decoder.start()
        renderer.attach(video: videoFrames, audio: frames)
    }

    func teardownSubtitleLane() {
        if let old = selectedSubtitleTrackIndex {
            demuxer?.detach(streamIndex: old)
        }
        subtitleDecoder?.shutdown(deadline: 2)
        subtitlePackets?.close()
        subtitleDecoder = nil
        subtitlePackets = nil
        selectedSubtitleTrackIndex = nil
        usingExternalSubtitles = false
        subtitles.removeAll()
    }

    func installSubtitleLane(trackIndex: Int32, packets: Channel<Packet>, decoder: SubtitleDecoder) {
        subtitlePackets = packets
        subtitleDecoder = decoder
        selectedSubtitleTrackIndex = trackIndex
        usingExternalSubtitles = false
    }

    func markExternalSubtitlesActive() {
        usingExternalSubtitles = true
    }

    // MARK: Event handling

    private func handleDemux(_ event: DemuxEvent) {
        switch event {
        case .opened(let info):
            openContinuation?.resume(returning: info)
            openContinuation = nil

        case .openFailed(let error):
            openContinuation?.resume(throwing: error)
            openContinuation = nil

        case .didSeek(_, let serial):
            currentSerial = serial
            renderer.flush(acceptingSerial: serial)
            if let target = pendingSeekTarget {
                renderer.setRate(shouldPlay ? targetRate : 0, anchoredAt: target)
                pendingSeekTarget = nil
                eventSink.yield(.didSeek(position: MediaTime.seconds(target - (info?.startTime ?? 0))))
            }
            if state == .ended { state = shouldPlay ? .playing : .paused }
            evaluatePlayback()

        case .seekFailed(let error):
            pendingSeekTarget = nil
            renderer.setRate(shouldPlay ? targetRate : 0)
            eventSink.yield(.error(error))

        case .endOfStream:
            demuxAtEOF = true
            videoDecoder?.signalEndOfStream()
            audioDecoder?.signalEndOfStream()

        case .readError:
            break // transient; the demuxer keeps reading

        case .failed(let error):
            lastError = error
            state = .failed
            renderer.setRate(0)
            eventSink.yield(.error(error))

        case .closed:
            break
        }
    }

    private func handleDecode(_ event: DecodeEvent, isVideo: Bool) {
        switch event {
        case .downgradedToSoftware(let error):
            eventSink.yield(.decoderDowngraded(error))
        case .endOfStream:
            if isVideo { videoAtEOF = true } else { audioAtEOF = true }
        case .failed(let error):
            // One lane dying is not necessarily fatal (e.g. broken audio track,
            // healthy video) — surface it; the monitor decides on full failure.
            eventSink.yield(.error(error))
            if isVideo { videoAtEOF = true } else { audioAtEOF = true }
            lastError = error
        }
    }

    // MARK: Buffering / end detection

    private func monitorLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
            evaluatePlayback()
            runStallWatchdog()
        }
    }

    /// Ground truth is the playhead, not any state flag: if playback should be
    /// progressing and the clock isn't moving, something upstream died — no
    /// matter what the components claim (decode threads can die without an
    /// error, and buffering callbacks lie).
    private func runStallWatchdog() {
        let expectingProgress = shouldPlay
            && (state == .playing || state == .buffering)
            && pendingSeekTarget == nil
            && !demuxAtEOF

        guard expectingProgress else {
            lastProgressDate = .distantFuture
            lastObservedPosition = -1
            return
        }

        let current = position
        if current != lastObservedPosition {
            lastObservedPosition = current
            lastProgressDate = Date()
            return
        }
        if lastProgressDate == .distantFuture {
            lastProgressDate = Date()
            return
        }

        let stalledFor = Date().timeIntervalSince(lastProgressDate)
        guard stalledFor >= configuration.stallThreshold else { return }

        // Rate-limit to one report per stall window.
        if let lastKick = lastStallKick, Date().timeIntervalSince(lastKick) < configuration.stallThreshold {
            return
        }
        lastStallKick = Date()
        eventSink.yield(.stalled(position: current))

        // Self-heal once for seekable sources: re-enter through the ordinary
        // seek path, which rebuilds every queue state from scratch.
        if info?.isSeekable == true {
            seek(to: current)
        }
        lastProgressDate = Date()
    }

    /// Buffer state is *derived* from actual queue depth and clock positions —
    /// never from cached flags (PLAN.md §3.4).
    private func evaluatePlayback() {
        guard state != .failed, state != .idle, state != .opening, info != nil else { return }
        guard pendingSeekTarget == nil else { return }

        let buffered = bufferedSeconds
        let eligibleLanes = (videoFrames != nil ? 1 : 0) + (audioFrames != nil ? 1 : 0)
        guard eligibleLanes > 0 else { return }

        let allEOF = demuxAtEOF
            && (videoDecoder == nil || videoAtEOF)
            && (audioDecoder == nil || audioAtEOF)

        // End detection: everything drained and the clock passed the last
        // enqueued sample.
        if allEOF, buffered <= 0.01 {
            let highWater = renderer.enqueuedHighWaterMark
            let mark = max(highWater.video, highWater.audio)
            if !MediaTime.isValid(mark) || renderer.currentTime >= mark {
                if state != .ended {
                    renderer.setRate(0)
                    state = .ended
                    shouldPlay = false
                }
                return
            }
        }

        guard shouldPlay else { return }

        switch state {
        case .ready, .paused, .buffering:
            // Start when the target is buffered, when every lane is as full as
            // it can get (capacity < target), or when EOF means no more is coming.
            if buffered >= configuration.bufferTarget || allLanesSaturated || allEOF || demuxAtEOF {
                renderer.setRate(targetRate)
                state = .playing
            } else if state != .buffering {
                state = .buffering
            }
        case .playing:
            // Starvation: queues empty and more data is expected → buffer.
            if buffered <= 0.01, !demuxAtEOF {
                renderer.setRate(0)
                state = .buffering
            }
        default:
            break
        }
    }

    /// Decoded seconds waiting in the frame queues (per-lane minimum: playback
    /// stalls on the emptiest lane).
    private var bufferedSeconds: Double {
        var lanes: [Double] = []
        if let videoFrames {
            lanes.append(MediaTime.seconds(videoFrames.stats.bufferedDuration))
        }
        if let audioFrames {
            lanes.append(MediaTime.seconds(audioFrames.stats.bufferedDuration))
        }
        return lanes.min() ?? 0
    }

    /// True when every active lane's frame queue is at capacity — waiting any
    /// longer cannot buffer more (queue capacity may be below the time target).
    private var allLanesSaturated: Bool {
        var saturated = true
        var lanes = 0
        if let videoFrames {
            lanes += 1
            saturated = saturated && videoFrames.stats.isFull
        }
        if let audioFrames {
            lanes += 1
            saturated = saturated && audioFrames.stats.isFull
        }
        return lanes > 0 && saturated
    }
}
