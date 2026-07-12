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

    /// Standby session pre-opened by `prepare(next:)`, held through
    /// first-frame-decoded until `load(url:)` consumes it.
    private var preparedNext: (url: String, session: PlayerSession, info: MediaInfo)?
    /// Supersession guards: a `load`/`prepare` that lost a race against a
    /// newer call (or `stop`) discards its session instead of installing it.
    private var loadGeneration: UInt64 = 0
    private var prepareGeneration: UInt64 = 0
    /// Bound on the first-frame wait during a seamless swap; past it the swap
    /// proceeds anyway (losing only the no-gap guarantee).
    private static let firstFrameTimeout: Double = 10

    public init(configuration: PlayerConfiguration = PlayerConfiguration()) {
        self.configuration = configuration
    }

    // MARK: Lifecycle

    /// Opens `url`, replacing any previous session (each open is a fresh
    /// engine session — PLAN.md §3.1).
    ///
    /// Zero-delay switching (PLAN.md §6), governed by
    /// `PlayerConfiguration.switchPolicy`: when a session matching `url` was
    /// staged by `prepare(next:)`, the swap is immediate under any policy.
    /// Otherwise `.overlapped` keeps the current session rendering while the
    /// replacement opens through its first decoded frame (two connections
    /// briefly), and `.sequential` closes the current session *first* —
    /// freeing its source connection — while its last decoded frame stays
    /// frozen on screen until the replacement is ready. A failed overlapped
    /// open (e.g. a provider capped at one concurrent connection) falls back
    /// to the sequential path before the error surfaces.
    public func load(url: String) async throws -> MediaInfo {
        loadGeneration &+= 1
        let generation = loadGeneration

        // A prepared session for this exact URL swaps in with no open cost
        // (consuming it opens nothing new), so it is honored under any policy.
        if let prepared = preparedNext, prepared.url == url {
            preparedNext = nil
            if await prepared.session.state != .failed {
                guard generation == loadGeneration else {
                    Task { await prepared.session.shutdown() }
                    throw EngineError(code: .invalidState, message: "load superseded by a newer load")
                }
                adopt(session: prepared.session, info: prepared.info)
                return prepared.info
            }
            // The standby died while waiting (network drop) — fall through.
            let dead = prepared.session
            Task { await dead.shutdown() }
        }
        discardPreparedSession()

        let canSwitch = session != nil && state != .failed
        if canSwitch, configuration.switchPolicy == .overlapped {
            let next = PlayerSession(configuration: configuration)
            do {
                let info = try await next.open(url: url)
                await next.waitForFirstFrame(timeout: Self.firstFrameTimeout)
                guard generation == loadGeneration else {
                    Task { await next.shutdown() }
                    throw EngineError(code: .invalidState, message: "load superseded by a newer load")
                }
                adopt(session: next, info: info)
                return info
            } catch {
                Task { await next.shutdown() }
                guard generation == loadGeneration else { throw error }
                // Fall through to the sequential retry: a provider capped at
                // one concurrent connection refuses the overlapped open but
                // accepts the same URL once the current stream is closed.
            }
        }
        if canSwitch, configuration.switchPolicy != .none {
            return try await sequentialLoad(url: url, generation: generation)
        }

        await teardownSession()
        guard generation == loadGeneration else {
            throw EngineError(code: .invalidState, message: "load superseded by a newer load")
        }

        let session = PlayerSession(configuration: configuration)
        self.session = session
        state = .opening
        startObservation(of: session)

        do {
            let info = try await session.open(url: url)
            guard generation == loadGeneration else {
                throw EngineError(code: .invalidState, message: "load superseded by a newer load")
            }
            mediaInfo = info
            duration = info.duration.map(MediaTime.seconds)
            return info
        } catch {
            // A superseded load must not clobber the newer load's state.
            guard generation == loadGeneration else { throw error }
            lastError = error as? EngineError
            state = .failed
            throw error
        }
    }

    /// Single-connection switch: the current session shuts down first (its
    /// display layer keeps the last decoded frame — `SystemRenderer.shutdown`
    /// flushes without removing the displayed image, so the screen never
    /// blanks), then the replacement opens and the layers swap at its first
    /// frame. At most one source connection exists at any moment. Playback
    /// pauses for the duration of the open — the price of the connection cap.
    private func sequentialLoad(url: String, generation: UInt64) async throws -> MediaInfo {
        eventTask?.cancel()
        tickTask?.cancel()
        if let old = session {
            // Bounded join: the connection must actually be closed before the
            // replacement opens, or a one-connection provider refuses it.
            await old.shutdown()
        }
        state = .opening
        guard generation == loadGeneration else {
            throw EngineError(code: .invalidState, message: "load superseded by a newer load")
        }

        let next = PlayerSession(configuration: configuration)
        do {
            let info = try await next.open(url: url)
            await next.waitForFirstFrame(timeout: Self.firstFrameTimeout)
            guard generation == loadGeneration else {
                Task { await next.shutdown() }
                throw EngineError(code: .invalidState, message: "load superseded by a newer load")
            }
            adopt(session: next, info: info)
            return info
        } catch {
            Task { await next.shutdown() }
            guard generation == loadGeneration else { throw error }
            // The dead session stays attached: its frozen frame keeps the
            // surface alive behind whatever failure UI the app raises.
            lastError = error as? EngineError
            state = .failed
            throw error
        }
    }

    /// Stages `url` in a standby session, opened through first-frame-decoded
    /// but never played (PLAN.md §6). A following `load(url:)` for the same
    /// URL swaps it in with zero delay — this powers next-episode
    /// auto-advance and channel zapping. Current playback is untouched.
    ///
    /// Only one URL is staged at a time; a newer `prepare` replaces the
    /// previous standby. The standby holds its **own source connection** and
    /// read-ahead buffer until consumed or discarded — only call this when
    /// the source allows a stream beside the playing one (the same budget as
    /// `SwitchPolicy.overlapped`); on one-connection providers rely on the
    /// sequential switch instead.
    @discardableResult
    public func prepare(next url: String) async throws -> MediaInfo {
        discardPreparedSession()
        prepareGeneration &+= 1
        let generation = prepareGeneration

        let session = PlayerSession(configuration: configuration)
        do {
            let info = try await session.open(url: url)
            await session.waitForFirstFrame(timeout: Self.firstFrameTimeout)
            guard generation == prepareGeneration else {
                Task { await session.shutdown() }
                throw EngineError(code: .invalidState, message: "prepare superseded by a newer prepare")
            }
            preparedNext = (url, session, info)
            return info
        } catch {
            Task { await session.shutdown() }
            throw error
        }
    }

    /// Discards the standby session staged by `prepare(next:)`, if any.
    public func discardPreparedSession() {
        prepareGeneration &+= 1
        guard let prepared = preparedNext else { return }
        preparedNext = nil
        Task { await prepared.session.shutdown() }
    }

    /// Atomic swap of `prepare`d/seamlessly opened media: the new session
    /// becomes the active one (its display layer replaces the old one via the
    /// `displayLayer` observation) and the old session is torn down
    /// asynchronously — the swap never waits for thread joins.
    private func adopt(session next: PlayerSession, info: MediaInfo) {
        eventTask?.cancel()
        tickTask?.cancel()
        if let old = session {
            Task { await old.shutdown() }
        }
        session = next
        state = .ready
        mediaInfo = info
        duration = info.duration.map(MediaTime.seconds)
        lastError = nil
        subtitleText = nil
        startObservation(of: next)
        if rate != 1.0 {
            let rate = rate
            Task { await next.setRate(rate) }
        }
    }

    /// Event pump + 10 Hz position tick for the active session.
    private func startObservation(of session: PlayerSession) {
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
        loadGeneration &+= 1
        discardPreparedSession()
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
