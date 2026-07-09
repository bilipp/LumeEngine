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
    private let audioRenderer = AVSampleBufferAudioRenderer()

    // Data-plane queues: the pumps feed the renderers on a deadline — at
    // default QoS they get descheduled on loaded devices (see Demuxer.start).
    private let videoQueue = DispatchQueue(label: "engine.lume.render.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "engine.lume.render.audio", qos: .userInteractive)

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

    // Queue-confined format caches.
    private var videoFormatCache: CMVideoFormatDescription?
    private var audioFormatCache: (description: CMAudioFormatDescription, sampleRate: Int, channels: Int, channelBitmap: UInt64)?
    // Audio-queue-confined; serial changes re-anchor it after a seek flush.
    private var audioTimeline = AudioTimeline()

    /// Fires (once per lane) when a renderer transitions to `.failed` — e.g.
    /// an audio format the output route cannot render. A failed renderer
    /// silently stops accepting data, which would otherwise wedge the pipeline
    /// with no event (§3.3: silence is never a failure mode) — the session
    /// must surface this as a typed failure. Set before `attach`.
    public var onRenderFailure: (@Sendable (EngineError) -> Void)?
    private var statusObservations: [NSKeyValueObservation] = []
    private var reportedFailure = false

    public init(muted: Bool = false) {
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        videoRenderer = displayLayer.sampleBufferRenderer
        audioRenderer.isMuted = muted

        synchronizer.addRenderer(videoRenderer)
        synchronizer.addRenderer(audioRenderer)
        synchronizer.setRate(0, time: .zero)
    }

    // MARK: Wiring

    /// Attaches decoded-frame channels and starts pulling. `nil` disables a lane.
    public func attach(video: Channel<VideoFrame>?, audio: Channel<AudioFrame>?) {
        lock.lock()
        videoInput = video
        audioInput = audio
        lock.unlock()

        var observations: [NSKeyValueObservation] = []
        if video != nil {
            observations.append(videoRenderer.observe(\.status, options: [.initial, .new]) { [weak self] renderer, _ in
                guard renderer.status == .failed else { return }
                self?.reportRenderFailure(lane: "video", underlying: renderer.error)
            })
            videoRenderer.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
                self?.pumpVideo()
            }
        }
        if audio != nil {
            observations.append(audioRenderer.observe(\.status, options: [.initial, .new]) { [weak self] renderer, _ in
                guard renderer.status == .failed else { return }
                self?.reportRenderFailure(lane: "audio", underlying: renderer.error)
            })
            audioRenderer.requestMediaDataWhenReady(on: audioQueue) { [weak self] in
                self?.pumpAudio()
            }
        }
        lock.lock()
        statusObservations.append(contentsOf: observations)
        lock.unlock()
    }

    private func reportRenderFailure(lane: String, underlying: Error?) {
        lock.lock()
        let alreadyReported = reportedFailure || stopped
        reportedFailure = true
        lock.unlock()
        guard !alreadyReported else { return }
        let detail = underlying.map { " — \($0.localizedDescription)" } ?? ""
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
        let observations = statusObservations
        statusObservations = []
        lock.unlock()
        observations.forEach { $0.invalidate() }
        videoRenderer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
        synchronizer.setRate(0, time: .zero)
        videoRenderer.flush()
        audioRenderer.flush()
    }

    // MARK: Pumps (render queues)

    /// Feeds the video renderer. `requestMediaDataWhenReady` only re-fires on
    /// readiness transitions, so on starvation we self-schedule a retry — the
    /// pump never silently stops (the classic "spinner stuck forever" failure, PLAN.md §3.3).
    private func pumpVideo() {
        lock.lock()
        let input = videoInput
        let serial = acceptedSerial
        let isStopped = stopped
        lock.unlock()
        guard let input, !isStopped else { return }

        while videoRenderer.isReadyForMoreMediaData {
            guard let frame = input.tryReceive() else {
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
        lock.unlock()
        guard let input, !isStopped else { return }

        while audioRenderer.isReadyForMoreMediaData {
            guard let frame = input.tryReceive() else {
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
            } catch {
                continue
            }
        }
    }

    private func scheduleVideoRetry() {
        lock.lock()
        let shouldSchedule = !videoPumpScheduled && !stopped
        if shouldSchedule { videoPumpScheduled = true }
        lock.unlock()
        guard shouldSchedule else { return }
        videoQueue.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.videoPumpScheduled = false
            self.lock.unlock()
            self.pumpVideo()
        }
    }

    private func scheduleAudioRetry() {
        lock.lock()
        let shouldSchedule = !audioPumpScheduled && !stopped
        if shouldSchedule { audioPumpScheduled = true }
        lock.unlock()
        guard shouldSchedule else { return }
        audioQueue.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.audioPumpScheduled = false
            self.lock.unlock()
            self.pumpAudio()
        }
    }
}
