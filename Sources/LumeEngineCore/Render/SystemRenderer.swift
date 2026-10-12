@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// The default presentation backend (PLAN.md D3): decoded frames are enqueued
/// into `AVSampleBufferVideoRenderer` / `AVSampleBufferAudioRenderer`, both
/// attached to one `AVSampleBufferRenderSynchronizer`. Apple's clock owns A/V
/// sync, rate (with pitch correction), HDR tone mapping, and frame scheduling —
/// the engine never hand-rolls a drop-frame heuristic.
///
/// The synchronizer timeline == the engine timeline (µs since source start),
/// so `currentTime` is directly comparable to frame PTS.
public final class SystemRenderer: @unchecked Sendable {
    /// The layer to install in the view hierarchy.
    public let displayLayer: AVSampleBufferDisplayLayer

    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let videoRenderer: AVSampleBufferVideoRenderer
    let audioRenderer = AVSampleBufferAudioRenderer()

    // Data-plane queues: the pumps feed the renderers on a deadline — at
    // default QoS they get descheduled on loaded devices (see Demuxer.start).
    private let videoQueue = DispatchQueue(label: "engine.lume.render.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "engine.lume.render.audio", qos: .userInteractive)
    /// How long a starved pump waits before asking for data again. This is
    /// the only latency a frame that lands in an empty channel picks up, so
    /// keep it well under a frame interval at 50/60 fps.
    private let starvationRetryMilliseconds = 10

    // Guarded by `lock`.
    private let lock = NSLock()
    private var videoInput: Channel<VideoFrame>?
    private var audioInput: Channel<AudioFrame>?
    private var acceptedSerial: UInt64 = 0
    private var lastEnqueuedVideoPTS = MediaTime.noTimestamp
    private var lastEnqueuedAudioPTS = MediaTime.noTimestamp
    private var firstEnqueuedVideoPTS = MediaTime.noTimestamp
    private var firstEnqueuedAudioPTS = MediaTime.noTimestamp
    private var videoPumpScheduled = false
    private var audioPumpScheduled = false
    private var stopped = false
    // How often each pump has run. Read through `pumpCounts`.
    private var videoPumpCount = 0
    private var audioPumpCount = 0

    // Queue-confined format caches.
    private var videoFormatCache: CMVideoFormatDescription?
    private var audioFormatCache: (description: CMAudioFormatDescription, sampleRate: Int, channels: Int, channelBitmap: UInt64)?
    // Audio-queue-confined; serial changes re-anchor it after a seek flush.
    private var audioTimeline = AudioTimeline()

    /// Audio enqueued but not yet played, kept so it can be enqueued again
    /// after the renderer drops it on its own (see `refillAfterAutomaticFlush`).
    /// Audio-queue-confined.
    private struct RetainedAudio {
        let sample: CMSampleBuffer
        let serial: UInt64
        /// End of the sample on the engine timeline (µs).
        let end: Int64
    }
    private var retainedAudio: [RetainedAudio] = []
    /// Backstop only: the renderer stops asking for audio once it holds a
    /// second or two, so the retention stays that size even while paused.
    private static let maxRetainedAudio = 1024
    /// Automatic audio flushes (and output reconfigurations) answered by
    /// re-enqueueing. Guarded by `lock`.
    var automaticAudioFlushes: Int { lock.withLock { automaticAudioFlushCount } }
    private var automaticAudioFlushCount = 0
    /// Notification tokens, removed on shutdown. Guarded by `lock`.
    private var notificationTokens: [NSObjectProtocol] = []

    /// Fires (once per lane) when a renderer transitions to `.failed` — e.g.
    /// an audio format the output route cannot render. A failed renderer
    /// silently stops accepting data, which would otherwise wedge the pipeline
    /// with no event (§3.3: silence is never a failure mode) — the session
    /// must surface this as a typed failure. Set before `attach`.
    public var onRenderFailure: (@Sendable (EngineError) -> Void)?
    // One handle per lane rather than an append-only list: `attach` is called
    // again on every track switch, which would otherwise stack a fresh observer
    // on the same renderer each time.
    private var videoObservation: NSKeyValueObservation?
    private var audioObservation: NSKeyValueObservation?
    /// Whether a lane is currently feeding its renderer. Guarded by `lock`.
    private var videoLaneAttached = false
    private var audioLaneAttached = false
    private var reportedFailure = false

    public init(muted: Bool = false) {
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        videoRenderer = displayLayer.sampleBufferRenderer
        audioRenderer.isMuted = muted

        synchronizer.addRenderer(videoRenderer)
        // The audio renderer is added by `attach` when a lane actually feeds it
        // and removed again by `detachAudioRenderer`. A renderer that is fed
        // claims the output route, and on tvOS the route is scarce enough that a
        // second claimant never becomes ready — which stalls the synchronizer the
        // video lane shares, freezing the picture on its first frame with no
        // failure event. Multi-View plays up to four sources at once, so an
        // audio-less tile must hold no claim at all.
        synchronizer.setRate(0, time: .zero)
        observeSystemNotifications()
    }

    deinit {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    /// The audio renderer drops everything it holds when the output route
    /// changes (AirPlay, HomePod, AirPods, HDMI) and when the synchronizer's
    /// rate changes between two non-zero values. The clock keeps running, so
    /// without an answer the dropped stretch plays as silence. Media services
    /// being reset invalidates every renderer for good, which only a new
    /// session can recover from.
    private func observeSystemNotifications() {
        // Both notifications are deprecated as of the OS 27 SDKs in favour of
        // the renderer's Receiver API, which the iOS/tvOS 18 floor predates.
        let center = NotificationCenter.default
        var tokens = [center.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: audioRenderer,
            queue: nil
        ) { [weak self] notification in
            // Plain µs out of the notification before hopping queues (the
            // notification itself is not Sendable).
            let value = notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue
            let flushTime = value.map { $0.timeValue }
            let micros = flushTime.flatMap { $0.isValid ? $0.convertScale(SampleBufferBuilder.timescale, method: .default).value : nil }
            guard let self else { return }
            self.audioQueue.async { self.refillAfterAutomaticFlush(from: micros ?? self.currentTime) }
        }, center.addObserver(
            // The output hardware was reconfigured for another client's format
            // (an HDMI or HomePod route renegotiating): the renderer keeps
            // playing, suboptimally, until it is flushed and fed again from the
            // playhead, which configures the hardware for this stream.
            forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
            object: audioRenderer,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.audioQueue.async { self.refillAfterAutomaticFlush(from: self.currentTime) }
        }]
        #if os(iOS) || os(tvOS) || os(visionOS)
        tokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.reportRenderFailure(lane: "audio", underlying: nil, reason: "media services were reset")
        })
        #endif
        lock.withLock { notificationTokens = tokens }
    }

    /// Answers an automatic flush: re-enqueue what was dropped, from the time
    /// the renderer flushed at. Runs on the audio queue, so no pump pass runs
    /// alongside it.
    func refillAfterAutomaticFlush(from flushTime: Int64) {
        lock.lock()
        let serial = acceptedSerial
        let active = !stopped && audioLaneAttached
        if active { automaticAudioFlushCount += 1 }
        lock.unlock()
        guard active else { return }

        // A pump pass may have enqueued between the automatic flush and this
        // answer; that audio is retained too, so drop it and re-enqueue
        // everything in order.
        audioRenderer.flush()
        for entry in retainedAudio where entry.serial == serial && (!MediaTime.isValid(flushTime) || entry.end > flushTime) {
            audioRenderer.enqueue(entry.sample)
        }
        // A seek that flushed while this ran may have been overtaken by the
        // re-enqueue; its audio belongs to the old position.
        if lock.withLock({ acceptedSerial }) != serial {
            audioRenderer.flush()
        }
    }

    // MARK: Wiring

    /// Attaches decoded-frame channels and starts pulling. `nil` disables a lane.
    ///
    /// Safe to call repeatedly — a track switch re-attaches the same lane — and
    /// each lane only starts or stops on an actual transition, so re-attaching
    /// audio does not re-observe or re-request on a renderer already running.
    public func attach(video: Channel<VideoFrame>?, audio: Channel<AudioFrame>?) {
        lock.lock()
        let audioChanged = audioInput !== audio
        videoInput = video
        audioInput = audio
        let videoWasAttached = videoLaneAttached
        let audioWasAttached = audioLaneAttached
        videoLaneAttached = video != nil
        audioLaneAttached = audio != nil
        lock.unlock()

        if audioChanged {
            // Retained audio belongs to the lane that enqueued it; a refill
            // after a track switch must not bring the old track back.
            audioQueue.async { [weak self] in self?.retainedAudio.removeAll() }
        }

        if video != nil, !videoWasAttached {
            let observation = videoRenderer.observe(\.status, options: [.initial, .new]) { [weak self] renderer, _ in
                guard renderer.status == .failed else { return }
                self?.reportRenderFailure(lane: "video", underlying: renderer.error)
            }
            lock.lock()
            videoObservation = observation
            lock.unlock()
            videoQueue.async { [weak self] in self?.armVideo() }
        }

        if audio != nil {
            guard !audioWasAttached else { return }
            synchronizer.addRenderer(audioRenderer)
            let observation = audioRenderer.observe(\.status, options: [.initial, .new]) { [weak self] renderer, _ in
                guard renderer.status == .failed else { return }
                self?.reportRenderFailure(lane: "audio", underlying: renderer.error)
            }
            lock.lock()
            audioObservation = observation
            lock.unlock()
            audioQueue.async { [weak self] in self?.armAudio() }
        } else if audioWasAttached {
            detachAudioRenderer()
        }
    }

    /// Releases the audio output route: stop pulling, drop what is queued, and
    /// leave the synchronizer so nothing is holding a claim. Mirrors the audio
    /// half of `shutdown`, which is the proven release sequence.
    private func detachAudioRenderer() {
        lock.lock()
        let observation = audioObservation
        audioObservation = nil
        lock.unlock()
        observation?.invalidate()
        audioRenderer.stopRequestingMediaData()
        audioRenderer.flush()
        // A lane given up before the clock ever ran has no valid current time —
        // dropping a tile's audio during startup is exactly that case.
        let now = synchronizer.currentTime()
        synchronizer.removeRenderer(audioRenderer, at: now.isValid ? now : .zero)
    }

    private func reportRenderFailure(lane: String, underlying: Error?, reason: String? = nil) {
        lock.lock()
        let alreadyReported = reportedFailure || stopped
        reportedFailure = true
        lock.unlock()
        guard !alreadyReported else { return }
        let detail = (reason ?? underlying?.localizedDescription).map { " — \($0)" } ?? ""
        onRenderFailure?(EngineError(
            code: .renderFailed,
            message: "\(lane) renderer failed\(detail)"
        ))
    }

    // MARK: Transport

    /// Starts/updates the clock. `mediaTime` anchors the timeline (engine µs);
    /// pass `nil` to keep the current position.
    public func setRate(_ rate: Float, anchoredAt mediaTime: Int64? = nil) {
        if let mediaTime {
            synchronizer.setRate(rate, time: SampleBufferBuilder.time(mediaTime))
        } else {
            synchronizer.rate = rate
        }
    }

    public var rate: Float {
        synchronizer.rate
    }

    /// Current playback position on the engine timeline (µs).
    public var currentTime: Int64 {
        let time = synchronizer.currentTime()
        guard time.isValid else { return MediaTime.noTimestamp }
        return time.convertScale(SampleBufferBuilder.timescale, method: .default).value
    }

    /// Audio pitch preservation while rate ≠ 1.
    public var audioTimePitchAlgorithm: AVAudioTimePitchAlgorithm {
        get { audioRenderer.audioTimePitchAlgorithm }
        set { audioRenderer.audioTimePitchAlgorithm = newValue }
    }

    public var volume: Float {
        get { audioRenderer.volume }
        set { audioRenderer.volume = newValue }
    }

    public var isMuted: Bool {
        get { audioRenderer.isMuted }
        set { audioRenderer.isMuted = newValue }
    }

    // MARK: Seek support

    /// Flushes both renderers and accepts only frames of `serial` from now on.
    /// Call after flushing the decode channels; the clock is re-anchored by the
    /// following `setRate(_:anchoredAt:)`.
    public func flush(acceptingSerial serial: UInt64) {
        lock.lock()
        acceptedSerial = serial
        lastEnqueuedVideoPTS = MediaTime.noTimestamp
        lastEnqueuedAudioPTS = MediaTime.noTimestamp
        firstEnqueuedVideoPTS = MediaTime.noTimestamp
        firstEnqueuedAudioPTS = MediaTime.noTimestamp
        lock.unlock()

        videoRenderer.flush()
        audioRenderer.flush()
    }

    /// Highest enqueued PTS per lane — used by the session for end-of-playback
    /// detection (`currentTime >= enqueued high-water mark`).
    public var enqueuedHighWaterMark: (video: Int64, audio: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (lastEnqueuedVideoPTS, lastEnqueuedAudioPTS)
    }

    /// First enqueued PTS per lane since the last flush — where delivered
    /// media actually starts. The session compares this against a seek target
    /// to detect a demuxer that landed somewhere else entirely (e.g. matroska
    /// falling back to the earliest cluster when its cues are unreachable
    /// over non-range HTTP) and re-anchors the clock to ground truth.
    public var enqueuedLowWaterMark: (video: Int64, audio: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (firstEnqueuedVideoPTS, firstEnqueuedAudioPTS)
    }

    /// Raw renderer health for diagnostics (status is
    /// `AVQueuedSampleBufferRenderingStatus`: 0 unknown, 1 rendering, 2 failed).
    public var rendererHealth: (videoStatus: Int, audioStatus: Int, videoError: String?, audioError: String?) {
        (
            videoRenderer.status.rawValue,
            audioRenderer.status.rawValue,
            videoRenderer.error?.localizedDescription,
            audioRenderer.error?.localizedDescription
        )
    }

    public func shutdown() {
        lock.lock()
        stopped = true
        let observations = [videoObservation, audioObservation].compactMap { $0 }
        videoObservation = nil
        audioObservation = nil
        videoLaneAttached = false
        audioLaneAttached = false
        let tokens = notificationTokens
        notificationTokens = []
        lock.unlock()
        observations.forEach { $0.invalidate() }
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        videoRenderer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
        synchronizer.setRate(0, time: .zero)
        videoRenderer.flush()
        audioRenderer.flush()
    }

    // MARK: Pumps (render queues)

    // `requestMediaDataWhenReady` is not edge-triggered: for as long as the
    // renderer stays ready, AVFoundation calls the block again the moment it
    // returns. A pump that returns early because it has nothing to enqueue
    // would therefore spin — millions of calls a second, a whole core per lane
    // at userInteractive. Live TV is that state almost all the time: frames
    // arrive in real time, so the renderer never fills up. So a starved pump
    // stops requesting and its retry re-arms, and a pump with no lane
    // (detached or shut down) stops requesting without re-arming.
    //
    // Arming always happens on the lane's queue, the queue the pump stops
    // requesting on. That orders the two: a track switch that detaches and
    // re-attaches audio can't have its fresh request cancelled by a pump that
    // was still running against the old, detached lane.

    /// Lane-queue-confined.
    private func armVideo() {
        lock.lock()
        let live = videoLaneAttached && !stopped
        lock.unlock()
        guard live else { return }
        videoRenderer.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
            self?.pumpVideo()
        }
    }

    /// Lane-queue-confined.
    private func armAudio() {
        lock.lock()
        let live = audioLaneAttached && !stopped
        lock.unlock()
        guard live else { return }
        audioRenderer.requestMediaDataWhenReady(on: audioQueue) { [weak self] in
            self?.pumpAudio()
        }
    }

    /// How many times each pump has run — what a starvation spin inflates.
    var pumpCounts: (video: Int, audio: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (videoPumpCount, audioPumpCount)
    }

    /// Feeds the video renderer. On starvation it stops requesting and
    /// self-schedules a re-arm, so the pump never silently stops (the classic
    /// "spinner stuck forever" failure, PLAN.md §3.3) and never spins either.
    private func pumpVideo() {
        lock.lock()
        let input = videoInput
        let serial = acceptedSerial
        let isStopped = stopped
        videoPumpCount += 1
        lock.unlock()
        guard let input, !isStopped else {
            videoRenderer.stopRequestingMediaData()
            return
        }

        while videoRenderer.isReadyForMoreMediaData {
            guard let frame = input.tryReceive() else {
                videoRenderer.stopRequestingMediaData()
                scheduleVideoRetry()
                return
            }
            guard frame.serial == serial else { continue } // stale pre-seek frame
            do {
                let sample = try SampleBufferBuilder.video(from: frame, formatCache: &videoFormatCache)
                videoRenderer.enqueue(sample)
                lock.lock()
                lastEnqueuedVideoPTS = frame.pts
                if !MediaTime.isValid(firstEnqueuedVideoPTS) { firstEnqueuedVideoPTS = frame.pts }
                lock.unlock()
            } catch {
                continue // malformed frame: drop, keep the pump alive
            }
        }
    }

    private func pumpAudio() {
        lock.lock()
        let input = audioInput
        let serial = acceptedSerial
        let isStopped = stopped
        audioPumpCount += 1
        lock.unlock()
        guard let input, !isStopped else {
            audioRenderer.stopRequestingMediaData()
            return
        }

        while audioRenderer.isReadyForMoreMediaData {
            guard let frame = input.tryReceive() else {
                audioRenderer.stopRequestingMediaData()
                scheduleAudioRetry()
                return
            }
            guard frame.serial == serial else { continue }
            do {
                let sample = try SampleBufferBuilder.audio(
                    from: frame,
                    presentationTime: audioTimeline.presentationTime(for: frame),
                    formatCache: &audioFormatCache
                )
                audioRenderer.enqueue(sample)
                lock.lock()
                lastEnqueuedAudioPTS = frame.pts + frame.duration
                if !MediaTime.isValid(firstEnqueuedAudioPTS) { firstEnqueuedAudioPTS = frame.pts }
                lock.unlock()
                retainAudio(sample, serial: serial, end: frame.pts + frame.duration)
            } catch {
                continue
            }
        }
    }

    /// Keeps `sample` until the clock has played past it. Audio queue only.
    private func retainAudio(_ sample: CMSampleBuffer, serial: UInt64, end: Int64) {
        let now = currentTime
        retainedAudio.removeAll { entry in
            entry.serial != serial || (MediaTime.isValid(now) && entry.end <= now)
        }
        if retainedAudio.count >= Self.maxRetainedAudio { retainedAudio.removeFirst() }
        retainedAudio.append(RetainedAudio(sample: sample, serial: serial, end: end))
    }

    private func scheduleVideoRetry() {
        lock.lock()
        let shouldSchedule = !videoPumpScheduled && !stopped
        if shouldSchedule { videoPumpScheduled = true }
        lock.unlock()
        guard shouldSchedule else { return }
        videoQueue.asyncAfter(deadline: .now() + .milliseconds(starvationRetryMilliseconds)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.videoPumpScheduled = false
            self.lock.unlock()
            self.armVideo()
        }
    }

    private func scheduleAudioRetry() {
        lock.lock()
        let shouldSchedule = !audioPumpScheduled && !stopped
        if shouldSchedule { audioPumpScheduled = true }
        lock.unlock()
        guard shouldSchedule else { return }
        audioQueue.asyncAfter(deadline: .now() + .milliseconds(starvationRetryMilliseconds)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.audioPumpScheduled = false
            self.lock.unlock()
            self.armAudio()
        }
    }
}
