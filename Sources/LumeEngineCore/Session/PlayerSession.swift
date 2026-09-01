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
    /// Deinterlacing policy. Defaults to filtering as soon as the decoder
    /// reports interlaced frames, at field rate — broadcast sport is the
    /// motivating case, and untouched 1080i combs badly on fast motion.
    public var deinterlace = VideoDecoder.Deinterlacing()
    /// Seconds of decoded media to buffer before starting/resuming playback.
    public var bufferTarget: Double = 1.0
    /// Seconds of *compressed* media the demuxer reads ahead per lane (packet
    /// queues). This is the jitter absorber for network sources: decoded
    /// queues are deliberately tiny (video frames retain pixel buffers), so
    /// smoothing must come from cheap undecoded packets. Budgeted in media
    /// time — packet-count limits are meaningless across codecs (256 TrueHD
    /// packets are 0.2 s; 256 AC-3 packets are 8 s). IPTV providers deliver
    /// in bursts separated by multi-second gaps; the read-ahead must span the
    /// gaps (~100 MB of compressed 4K at the default — the price every
    /// smooth player pays).
    public var packetReadAhead: Double = 15.0
    /// Initial playback position (seconds); the seek happens after open but
    /// *before* the demuxer starts streaming, while the I/O layer is still at
    /// the container header. Seeking an in-flight streaming connection is
    /// exactly what some IPTV providers cannot survive (range request against
    /// a consumed session → dead connection), so a resume position must not
    /// be implemented as open-then-seek from the app.
    public var startPosition: Double = 0
    /// Frame-channel capacities (video frames retain pixel buffers — keep small).
    public var videoQueueDepth = 8
    public var audioQueueDepth = 48
    public var enableVideo = true
    public var enableAudio = true
    public var muted = false
    /// Ordered, ALREADY-NORMALISED bare language tags supplied by the caller
    /// (`["de", "en"]`); empty means use the container default.
    ///
    /// The engine does no normalisation of its own — it never reads the device
    /// locale and never invents a preference — but it does normalise the
    /// *container's* tags, which arrive as ISO 639-2/B (`ger`), /T (`deu`),
    /// 639-1, or a regional variant (`de-AT`). Applied while the pipeline is
    /// built, before the demuxer streams a byte (see `TrackLanguageMatcher`).
    ///
    /// Also ranks the forced subtitle track when
    /// `autoEnableForcedSubtitlesForForeignAudio` is on.
    public var preferredAudioLanguages: [String] = []
    /// Turn a forced subtitle track on by itself when the audio that ends up
    /// selected matches none of `preferredAudioLanguages`.
    ///
    /// Off by default: whether untranslated dialogue should be subtitled is a
    /// viewer-facing policy the host owns. The mechanism lives here because it
    /// has to run while the pipeline is built — attaching the lane after
    /// `open()` would miss cues and route through a seek.
    public var autoEnableForcedSubtitlesForForeignAudio = false
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
    /// Set when a seek completed and the landing position still needs to be
    /// verified against the first actually-delivered frames.
    private var seekLandingTarget: Int64?

    // Stall watchdog (PLAN.md §3.3 — silence is never an acceptable failure mode).
    /// Watchdog progress signal: playhead + buffered media (see `runStallWatchdog`).
    private var lastObservedProgress: Double = -1
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
                self.handleDemux(event)
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

        // Track selection: the app's ordered language preference first, then
        // the container default flag, then the first track of the kind. The
        // preference is resolved *here*, while the pipeline is being built —
        // selecting after open would route through `seek(to: position)` with
        // position still 0, discarding `startPosition` on VOD resume and
        // seeking live sources that do not survive one (see
        // `TrackLanguageMatcher`). An empty preference list matches nothing,
        // so a default configuration behaves exactly as it did before.
        let videoTrack = configuration.enableVideo
            ? info.videoTracks.first(where: \.isDefault) ?? info.videoTracks.first
            : nil
        let audioTrack = configuration.enableAudio
            ? TrackLanguageMatcher.bestMatch(in: info.audioTracks, preferring: configuration.preferredAudioLanguages)
            ?? info.audioTracks.first(where: \.isDefault) ?? info.audioTracks.first
            : nil

        guard videoTrack != nil || audioTrack != nil else {
            throw EngineError(code: .unsupported, message: "source has no playable tracks")
        }

        selectedVideoTrackIndex = videoTrack?.index
        selectedAudioTrackIndex = audioTrack?.index

        if let track = videoTrack,
           let parameters = demuxer.codecParameters(forStream: track.index) {
            let packets = makeVideoPacketChannel()
            let frames = Channel<VideoFrame>(capacity: configuration.videoQueueDepth, measure: { max($0.duration, 0) })
            demuxer.attach(channel: packets, toStream: track.index)
            let decoder = VideoDecoder(
                parameters: parameters,
                input: packets,
                output: frames,
                policy: configuration.hardwareDecode,
                deinterlacing: configuration.deinterlace
            )
            videoPackets = packets
            videoFrames = frames
            videoDecoder = decoder
            let pump = Task { [events = decoder.events] in
                for await event in events {
                    self.handleDecode(event, isVideo: true)
                }
            }
            pumpTasks.append(pump)
            decoder.start()
        }

        if let track = audioTrack,
           let parameters = demuxer.codecParameters(forStream: track.index) {
            let packets = makeAudioPacketChannel()
            let frames = Channel<AudioFrame>(capacity: configuration.audioQueueDepth, measure: { $0.duration })
            demuxer.attach(channel: packets, toStream: track.index)
            let decoder = AudioDecoder(parameters: parameters, input: packets, output: frames)
            audioPackets = packets
            audioFrames = frames
            audioDecoder = decoder
            let pump = Task { [events = decoder.events] in
                for await event in events {
                    self.handleDecode(event, isVideo: false)
                }
            }
            pumpTasks.append(pump)
            decoder.start()
        }

        // The one case where the engine turns subtitles on by itself, and only
        // when the host asked for it: the audio the viewer will hear is foreign
        // to them (it matched none of their preferred audio languages) and the
        // source carries a forced track for the untranslated dialogue.
        // Attaching here rather than after open keeps it on the same no-seek
        // path as the audio choice, and the demuxer has not read a packet yet,
        // so no cue is missed.
        if configuration.autoEnableForcedSubtitlesForForeignAudio,
           let audioTrack,
           !configuration.preferredAudioLanguages.isEmpty,
           !TrackLanguageMatcher.matches(audioTrack, preferring: configuration.preferredAudioLanguages),
           let forced = forcedSubtitleTrack(in: info),
           let parameters = demuxer.codecParameters(forStream: forced.index) {
            let packets = Channel<Packet>(capacity: 128)
            demuxer.attach(channel: packets, toStream: forced.index)
            let decoder = SubtitleDecoder(parameters: parameters, input: packets, store: subtitles)
            installSubtitleLane(trackIndex: forced.index, packets: packets, decoder: decoder)
            decoder.start()
        }

        renderer.onRenderFailure = { [weak self] error in
            guard let self else { return }
            Task { await self.handleRenderFailure(error) }
        }
        renderer.attach(video: videoFrames, audio: audioFrames)
        renderer.flush(acceptingSerial: 0)
        renderer.setRate(0, anchoredAt: startTimeline)
        // A resume position seeks BEFORE the first read: the demux thread
        // processes commands in order, so the seek runs while the I/O layer
        // is still at the header (matching `ffplay -ss` / KSPlayer), not
        // against a connection that already streamed megabytes of body.
        if configuration.startPosition > 0, info.isSeekable {
            let target = info.startTime + MediaTime.microseconds(configuration.startPosition)
            pendingSeekTarget = target
            demuxer.seek(to: target)
        }
        demuxer.resume()

        monitorTask = Task {
            await self.monitorLoop()
        }
    }

    /// The forced track to show under foreign audio, ranked by the viewer's
    /// audio preference (someone who wants German audio reads German signs)
    /// and otherwise whatever forced track exists — a forced track is short,
    /// on-screen only for dialogue the soundtrack leaves untranslated, and is
    /// what the mux author expected to be shown.
    private func forcedSubtitleTrack(in info: MediaInfo) -> TrackInfo? {
        let forced = info.subtitleTracks.filter(\.isForced)
        guard !forced.isEmpty else { return nil }
        return TrackLanguageMatcher.bestMatch(in: forced, preferring: configuration.preferredAudioLanguages)
            ?? forced.first
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

    /// One-line pipeline health snapshot for app-side diagnostics/logging:
    /// where the playhead is, how full each stage is, and whether the
    /// renderers are still healthy. Cheap to compute; poll at a low rate.
    public struct Diagnostics: Sendable, CustomStringConvertible {
        public let state: String
        public let playheadSeconds: Double
        public let videoQueue: (count: Int, seconds: Double)?
        public let audioQueue: (count: Int, seconds: Double)?
        /// Undecoded read-ahead per lane (packet queues).
        public let videoPacketQueue: (count: Int, seconds: Double)?
        public let audioPacketQueue: (count: Int, seconds: Double)?
        public let videoLeadSeconds: Double
        public let audioLeadSeconds: Double
        /// First enqueued PTS per lane since the last flush (seconds; -1 when
        /// nothing accepted yet) — shows where post-seek media actually landed.
        public let videoFirstSeconds: Double
        public let audioFirstSeconds: Double
        public let rendererHealth: (videoStatus: Int, audioStatus: Int, videoError: String?, audioError: String?)
        public let demuxAtEOF: Bool
        /// Total compressed bytes demuxed — diff across heartbeats for the
        /// effective delivery rate.
        public let deliveredBytes: Int64

        public var description: String {
            func lane(_ queue: (count: Int, seconds: Double)?, lead: Double, first: Double) -> String {
                guard let queue else { return "off" }
                return String(format: "%d/%.2fs+%.2fs@%.2f", queue.count, queue.seconds, lead, first)
            }
            func packets(_ queue: (count: Int, seconds: Double)?) -> String {
                guard let queue else { return "off" }
                return String(format: "%d/%.2fs", queue.count, queue.seconds)
            }
            var health = "v\(rendererHealth.videoStatus) a\(rendererHealth.audioStatus)"
            if let error = rendererHealth.videoError { health += " vErr(\(error))" }
            if let error = rendererHealth.audioError { health += " aErr(\(error))" }
            return String(
                format: "state=%@ playhead=%.2fs vq=%@ vp=%@ aq=%@ ap=%@ renderers=%@ demuxEOF=%@ read=%.1fMB",
                state, playheadSeconds,
                lane(videoQueue, lead: videoLeadSeconds, first: videoFirstSeconds),
                packets(videoPacketQueue),
                lane(audioQueue, lead: audioLeadSeconds, first: audioFirstSeconds),
                packets(audioPacketQueue),
                health, demuxAtEOF ? "yes" : "no",
                Double(deliveredBytes) / 1_048_576
            )
        }
    }

    public var diagnostics: Diagnostics {
        let playhead = renderer.currentTime
        let highWater = renderer.enqueuedHighWaterMark
        let lowWater = renderer.enqueuedLowWaterMark
        func lead(_ mark: Int64) -> Double {
            guard MediaTime.isValid(mark), MediaTime.isValid(playhead), mark > playhead else { return 0 }
            return MediaTime.seconds(mark - playhead)
        }
        func lane(_ channel: Channel<some Sendable>?) -> (count: Int, seconds: Double)? {
            guard let stats = channel?.stats else { return nil }
            return (stats.count, MediaTime.seconds(stats.bufferedDuration))
        }
        return Diagnostics(
            state: String(describing: state),
            playheadSeconds: MediaTime.isValid(playhead) ? MediaTime.seconds(playhead) : -1,
            videoQueue: lane(videoFrames),
            audioQueue: lane(audioFrames),
            videoPacketQueue: lane(videoPackets),
            audioPacketQueue: lane(audioPackets),
            videoLeadSeconds: lead(highWater.video),
            audioLeadSeconds: lead(highWater.audio),
            videoFirstSeconds: MediaTime.isValid(lowWater.video) ? MediaTime.seconds(lowWater.video) : -1,
            audioFirstSeconds: MediaTime.isValid(lowWater.audio) ? MediaTime.seconds(lowWater.audio) : -1,
            rendererHealth: renderer.rendererHealth,
            demuxAtEOF: demuxAtEOF,
            deliveredBytes: demuxer?.deliveredBytes ?? 0
        )
    }

    // MARK: Seek

    /// Seeks to `position` seconds (media-relative). Flush order matters:
    /// channels first (unblocks producers), then the demuxer repositions, then
    /// the renderer accepts only the new serial (PLAN.md §3.4).
    public func seek(to position: Double) {
        guard let demuxer, let info else { return }
        guard info.isSeekable else {
            // avformat "succeeds" on unseekable sources by landing at the
            // earliest available point — worse than useless: the clock would
            // anchor at the target while media arrives from somewhere else.
            eventSink.yield(.error(EngineError(
                code: .seekFailed, message: "source is not seekable"
            )))
            return
        }
        let clamped = max(0, position)
        let target = info.startTime + MediaTime.microseconds(clamped)
        pendingSeekTarget = target
        seekLandingTarget = nil

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

    /// Packet channels are budgeted in media time (`packetReadAhead`); the
    /// element counts are memory backstops for streams that report no packet
    /// durations. Audio gets a high count because packets can be minuscule
    /// (TrueHD: 40 samples ≈ 0.83 ms — 4 s needs ~4800 packets of ~100 bytes).
    private func makeVideoPacketChannel() -> Channel<Packet> {
        Channel<Packet>(
            capacity: 512,
            durationBudget: MediaTime.microseconds(configuration.packetReadAhead),
            measure: { max($0.duration, 0) }
        )
    }

    func makeAudioPacketChannel() -> Channel<Packet> {
        Channel<Packet>(
            capacity: 32_768,
            durationBudget: MediaTime.microseconds(configuration.packetReadAhead),
            measure: { max($0.duration, 0) }
        )
    }

    func replaceAudioLane(demuxer: Demuxer, trackIndex: Int32, parameters: CodecParameters) {
        if let old = selectedAudioTrackIndex {
            demuxer.detach(streamIndex: old)
        }
        audioDecoder?.shutdown(deadline: 2)
        audioPackets?.close()

        let packets = makeAudioPacketChannel()
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
                self.handleDecode(event, isVideo: false)
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
                // Anchor paused; evaluatePlayback raises the rate once the
                // lanes are buffered, exactly like a cold start. Running the
                // clock immediately lets it sprint ahead of any source that
                // delivers at ≤ real time (4K remuxes over IPTV) — every
                // frame then arrives pre-expired and playback never engages.
                renderer.setRate(0, anchoredAt: target)
                pendingSeekTarget = nil
                seekLandingTarget = target // verified against delivered PTS
                eventSink.yield(.didSeek(position: MediaTime.seconds(target - (info?.startTime ?? 0))))
            }
            // The clock is now paused for re-buffering: a session that wants
            // to play re-enters through .buffering (stale pre-seek frames can
            // make the lanes look non-starved, which would strand .playing
            // with a stopped renderer).
            if shouldPlay {
                state = .buffering
            } else if state == .ended {
                state = .paused
            }
            evaluatePlayback()

        case .seekFailed(let error):
            pendingSeekTarget = nil
            // The pipeline was flushed for the seek; re-buffer before running
            // the clock again (evaluatePlayback restores the rate when ready).
            renderer.setRate(0)
            eventSink.yield(.error(error))
            evaluatePlayback()

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

    /// A renderer went `.failed` (it permanently stops accepting data — the
    /// pipeline would wedge with a healthy-looking demux/decode chain and no
    /// event). Fail the session with the typed reason; recovery policy
    /// (engine fallback, retry) is the app's job.
    private func handleRenderFailure(_ error: EngineError) {
        guard state != .failed, state != .idle else { return }
        lastError = error
        state = .failed
        renderer.setRate(0)
        eventSink.yield(.error(error))
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
            verifySeekLanding()
            evaluatePlayback()
            runStallWatchdog()
        }
    }

    /// A container seek can "succeed" while landing somewhere else entirely —
    /// matroska falls back to the earliest cluster when its cues are
    /// unreachable (end-of-file cues over non-range HTTP is the classic IPTV
    /// case). The clock was anchored at the *requested* target, so all
    /// delivered media would be hours late: video renders as a stuttering
    /// slideshow, audio is dropped wholesale, and the pipeline never buffers.
    /// Compare the first delivered post-seek PTS against the target and
    /// re-anchor the clock to ground truth when they clearly disagree.
    private func verifySeekLanding() {
        guard let target = seekLandingTarget, pendingSeekTarget == nil else { return }
        let lowWater = renderer.enqueuedLowWaterMark
        var marks: [Int64] = []
        if videoDecoder != nil, MediaTime.isValid(lowWater.video) { marks.append(lowWater.video) }
        if audioDecoder != nil, MediaTime.isValid(lowWater.audio) { marks.append(lowWater.audio) }
        // max, not min: a genuinely mis-landed seek moves *every* lane (they
        // share the demux position), while a transient pre-landing sliver on
        // one lane must not drag the estimate away from where data really is.
        guard let landed = marks.max() else { return } // nothing delivered yet

        seekLandingTarget = nil
        // Backward slack covers a keyframe-backward landing (normal: the late
        // frames snap playback to the target); anything further off means the
        // demuxer did not honor the seek.
        let backwardSlack = MediaTime.microseconds(30)
        let forwardSlack = MediaTime.microseconds(5)
        guard landed < target - backwardSlack || landed > target + forwardSlack else { return }

        // Preserve the current transport state: re-anchoring corrects the
        // timeline, it must not start or stop playback on its own.
        renderer.setRate(renderer.rate, anchoredAt: landed)
        eventSink.yield(.didSeek(position: MediaTime.seconds(landed - (info?.startTime ?? 0))))
    }

    /// Ground truth is progress, not any state flag: the signal is the
    /// least-advanced lane's enqueued high-water mark plus the remaining
    /// pipeline runway. It grows in every healthy mode — enqueues advance
    /// while playing, media accumulates while buffering — and freezes exactly
    /// when the source stopped delivering *or* one lane silently died (a dead
    /// decode thread pins its lane's high-water mark even while packets pile
    /// up and the clock keeps running; decode threads can die without an
    /// error, and buffering callbacks lie).
    private func runStallWatchdog() {
        let expectingProgress = shouldPlay
            && (state == .playing || state == .buffering)
            && pendingSeekTarget == nil
            && !demuxAtEOF

        guard expectingProgress else {
            lastProgressDate = .distantFuture
            lastObservedProgress = -1
            return
        }

        let current = position
        let highWater = renderer.enqueuedHighWaterMark
        var laneMarks: [Double] = []
        if videoDecoder != nil, !videoAtEOF {
            laneMarks.append(MediaTime.isValid(highWater.video) ? MediaTime.seconds(highWater.video) : 0)
        }
        if audioDecoder != nil, !audioAtEOF {
            laneMarks.append(MediaTime.isValid(highWater.audio) ? MediaTime.seconds(highWater.audio) : 0)
        }
        let progress = (laneMarks.min() ?? 0) + pipelineSeconds
        if progress > lastObservedProgress + 0.01 {
            lastObservedProgress = progress
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

        let pipeline = pipelineSeconds
        let eligibleLanes = (videoFrames != nil ? 1 : 0) + (audioFrames != nil ? 1 : 0)
        guard eligibleLanes > 0 else { return }

        let allEOF = demuxAtEOF
            && (videoDecoder == nil || videoAtEOF)
            && (audioDecoder == nil || audioAtEOF)

        // End detection: everything drained and the clock passed the last
        // enqueued sample.
        if allEOF, pipeline <= 0.01 {
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
            // Start when every lane is as buffered as it can usefully get,
            // or when EOF means no more is coming.
            if allLanesReady || allEOF || demuxAtEOF {
                renderer.setRate(targetRate)
                state = .playing
            } else if state != .buffering {
                state = .buffering
            }
        case .playing:
            // Starvation: the *entire pipeline* (decoded + packets) is dry and
            // more data is expected → buffer. Judged on total runway, not the
            // decoded queues alone: a transient decode dip refills in
            // milliseconds, while a rebuffer pause costs a second or more.
            if pipeline <= 0.01, !demuxAtEOF {
                renderer.setRate(0)
                state = .buffering
            } else if renderer.rate == 0, shouldPlay {
                // Reconcile: .playing with a stopped renderer must never
                // persist (any path that pauses the clock without demoting
                // the state would otherwise strand playback silently).
                renderer.setRate(targetRate)
            }
        default:
            break
        }
    }

    private struct LaneDepth {
        /// Decoded seconds ahead of the playhead: frame queue + renderer lead.
        var buffered: Double
        /// Total runway: `buffered` plus undecoded packets — the currency of
        /// both gates. Start: a multi-second buffer target is only reachable
        /// in compressed form (decoded queues are tiny by design). Starvation:
        /// a transient decode dip with seconds of packets queued must not stop
        /// the clock (decoders refill in milliseconds; a rebuffer pause is
        /// orders of magnitude worse).
        var pipeline: Double
        /// Frame *and* packet queues at capacity — this lane physically
        /// cannot buffer more; waiting longer is pointless.
        var queueFull: Bool
    }

    /// Per-lane decoded media ahead of the playhead. Counts both the frame
    /// queue and what is already enqueued in the renderer but not yet played —
    /// the pumps drain the queues into the renderers (whose appetite spans
    /// seconds), so queue depth alone reads near-zero on a healthy consuming
    /// lane and the state would flap or report `.buffering` long after
    /// playback actually started (a post-seek warm start runs the renderer
    /// while still `.buffering`). Lanes whose decoder hit EOF are excluded:
    /// nothing more is coming, so they must not gate decisions.
    private var laneDepths: [LaneDepth] {
        let playhead = renderer.currentTime
        let highWater = renderer.enqueuedHighWaterMark
        func rendererLead(_ mark: Int64) -> Double {
            guard MediaTime.isValid(mark), MediaTime.isValid(playhead), mark > playhead else { return 0 }
            return MediaTime.seconds(mark - playhead)
        }
        var lanes: [LaneDepth] = []
        if let videoFrames, !videoAtEOF {
            let frameStats = videoFrames.stats
            let packetStats = videoPackets?.stats
            let buffered = MediaTime.seconds(frameStats.bufferedDuration) + rendererLead(highWater.video)
            lanes.append(LaneDepth(
                buffered: buffered,
                pipeline: buffered + MediaTime.seconds(packetStats?.bufferedDuration ?? 0),
                queueFull: frameStats.isFull && (packetStats?.isFull ?? true)
            ))
        }
        if let audioFrames, !audioAtEOF {
            let frameStats = audioFrames.stats
            let packetStats = audioPackets?.stats
            let buffered = MediaTime.seconds(frameStats.bufferedDuration) + rendererLead(highWater.audio)
            lanes.append(LaneDepth(
                buffered: buffered,
                pipeline: buffered + MediaTime.seconds(packetStats?.bufferedDuration ?? 0),
                queueFull: frameStats.isFull && (packetStats?.isFull ?? true)
            ))
        }
        return lanes
    }

    /// Renderable media on the emptiest lane (start gate).
    private var bufferedSeconds: Double {
        laneDepths.map(\.buffered).min() ?? 0
    }

    /// Total runway on the emptiest lane (starvation and stall detection).
    private var pipelineSeconds: Double {
        laneDepths.map(\.pipeline).min() ?? 0
    }

    /// Start gate: every active lane either holds the buffer target across
    /// its whole pipeline (packets count — decoded queues are tiny by design,
    /// so a multi-second target is only reachable in compressed form) or
    /// physically cannot buffer more anywhere. Judged per lane — requiring
    /// every queue full at the same instant is a race a consuming lane loses.
    private var allLanesReady: Bool {
        let lanes = laneDepths
        return !lanes.isEmpty && lanes.allSatisfy {
            $0.pipeline >= configuration.bufferTarget || $0.queueFull
        }
    }
}
