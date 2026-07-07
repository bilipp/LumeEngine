@preconcurrency import AVFoundation
import Foundation
import LumeEngineCore
import Observation

/// Main-actor facade over `PlayerSession` for UI code.
///
/// Observation is coalesced: `position` ticks at ~10 Hz on the main actor so a
/// SwiftUI scrubber can bind to it without re-rendering per frame (the lesson
/// from Lume's `PlaybackClock` isolation — PLAN.md §2.1). All engine work stays
/// off the main thread; this type only mirrors state.
@MainActor
@Observable
public final class LumePlayer {
    public enum State: Sendable, Equatable {
        case idle, opening, ready, buffering, playing, paused, ended, failed
    }

    // MARK: Observable UI state

    public private(set) var state: State = .idle
    /// Media-relative position in seconds, ~10 Hz.
    public private(set) var position: Double = 0
    public private(set) var duration: Double?
    public private(set) var mediaInfo: MediaInfo?
    public private(set) var lastError: EngineError?
    /// True while the active decode path is VideoToolbox.
    public private(set) var isHardwareDecoding = false
    /// Text of the currently visible subtitle cue(s), `nil` when none.
    public private(set) var subtitleText: String?

    public var audioTracks: [TrackInfo] { mediaInfo?.audioTracks ?? [] }
    public var subtitleTracks: [TrackInfo] { mediaInfo?.subtitleTracks ?? [] }

    public var rate: Float = 1.0 {
        didSet {
            let session = session
            let rate = rate
            Task { await session?.setRate(rate) }
        }
    }

    /// Present this layer via `LumePlayerView` (SwiftUI) or add it to a view's
    /// layer tree directly (UIKit/AppKit).
    public var displayLayer: LumeDisplayLayer? { session?.renderer.displayLayer }

    private var session: PlayerSession?
    private var eventTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private let configuration: PlayerConfiguration

    public init(configuration: PlayerConfiguration = PlayerConfiguration()) {
        self.configuration = configuration
    }

    // MARK: Lifecycle

    /// Opens `url`, replacing any previous session (each open is a fresh
    /// engine session — PLAN.md §3.1).
    public func load(url: String) async throws -> MediaInfo {
        await teardownSession()

        let session = PlayerSession(configuration: configuration)
        self.session = session
        state = .opening

        eventTask = Task { [events = session.events] in
            for await event in events {
                self.handle(event: event)
            }
        }
        tickTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                await self.tick()
            }
        }

        do {
            let info = try await session.open(url: url)
            mediaInfo = info
            duration = info.duration.map(MediaTime.seconds)
            return info
        } catch {
            lastError = error as? EngineError
            state = .failed
            throw error
        }
    }

    public func play() {
        let session = session
        Task { await session?.play() }
    }

    public func pause() {
        let session = session
        Task { await session?.pause() }
    }

    public func seek(to seconds: Double) {
        let session = session
        Task { await session?.seek(to: seconds) }
    }

    public func skip(by seconds: Double) {
        seek(to: max(0, position + seconds))
    }

    public func selectAudioTrack(_ index: Int32) {
        let session = session
        Task { await session?.selectAudioTrack(index) }
    }

    /// `nil` disables subtitles.
    public func selectSubtitleTrack(_ index: Int32?) {
        let session = session
        Task { await session?.selectSubtitleTrack(index) }
        if index == nil { subtitleText = nil }
    }

    public func loadExternalSubtitles(url: String) async throws {
        guard let session else {
            throw EngineError(code: .invalidState, message: "no media loaded")
        }
        try await session.loadExternalSubtitles(url: url)
    }

    public func stop() async {
        await teardownSession()
        state = .idle
        position = 0
        mediaInfo = nil
        duration = nil
    }

    // MARK: Internals

    private func teardownSession() async {
        eventTask?.cancel()
        tickTask?.cancel()
        eventTask = nil
        tickTask = nil
        if let session {
            await session.shutdown()
        }
        session = nil
    }

    private func handle(event: PlayerEvent) {
        switch event {
        case .stateChanged(let sessionState):
            state = Self.mirror(sessionState)
        case .opened(let info):
            mediaInfo = info
            duration = info.duration.map(MediaTime.seconds)
        case .decoderDowngraded:
            isHardwareDecoding = false
        case .didSeek(let position):
            self.position = position
        case .stalled:
            break // app-level recovery hook; Lume wires this to its retry controller
        case .error(let error):
            lastError = error
        }
    }

    private func tick() async {
        guard let session else { return }
        position = await session.position

        let now = session.renderer.currentTime
        if MediaTime.isValid(now) {
            let cues = session.subtitles.activeCues(at: now)
            let text = cues.map(\.text).joined(separator: "\n")
            subtitleText = text.isEmpty ? nil : text
        } else {
            subtitleText = nil
        }
    }

    private static func mirror(_ state: PlayerSession.State) -> State {
        switch state {
        case .idle: .idle
        case .opening: .opening
        case .ready: .ready
        case .buffering: .buffering
        case .playing: .playing
        case .paused: .paused
        case .ended: .ended
        case .failed: .failed
        }
    }
}
