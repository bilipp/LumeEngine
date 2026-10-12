#if os(tvOS)
@preconcurrency import AVKit
import Foundation
import UIKit

/// Match Content for the sample-buffer pipeline: asks the TV for the refresh
/// rate and dynamic range a session's video wants, through the window's
/// `AVDisplayManager`.
///
/// AVPlayer does this by itself; a sample-buffer renderer cannot, so without
/// it an Apple TV set to Match Frame Rate / Match Dynamic Range leaves a
/// 1080i50 channel judder-converted to the UI's 60 Hz and HDR in the SDR
/// mode. The criteria are the engine's output (`PlayerSession.displayCriteria`),
/// not the container's: field-rate deinterlacing makes 50i a 50 Hz request,
/// and an IPT Dolby Vision stream converted to HDR10 asks for HDR10.
///
/// Opt-in: nothing changes the display mode unless a host creates a matcher.
/// One per player screen, kept across sessions: zapping between two channels
/// that want the same mode must not send the TV through the UI's mode and
/// back, so `match` only asks when the mode differs, and only `reset` (the
/// player screen going away) hands the display back. An unreset preference
/// keeps the TV in the content's mode after playback — call `reset`.
///
/// A mode switch blanks the TV for one to three seconds. While the matcher is
/// waiting for one, it holds the session's start (`PlayerSession.holdStart`),
/// so the opening plays to a lit screen; the hold is bounded by
/// `Options.maximumHold`, in the session as well as here.
@MainActor
public final class DisplayCriteriaMatcher {
    public struct Options: Sendable {
        /// Hold the session's start while the TV switches mode.
        public var holdsStartDuringModeSwitch = true
        /// Upper bound on that hold, counted from `match(_:)`. The session
        /// starts by itself once it passes.
        public var maximumHold: Double = 6
        /// How long to wait for the first frames to confirm the criteria
        /// before asking for what the stream predicts. Frames usually arrive
        /// well inside it; a prediction that turns out wrong costs a second
        /// mode switch.
        public var outputWait: Double = 2
        /// After asking for a mode, how long to wait for the switch to begin
        /// before concluding the TV is already in it.
        public var switchStartWindow: Double = 0.75

        public init() {}
    }

    /// The window whose display is matched — the one showing the video.
    /// Without one nothing is applied.
    public weak var window: UIWindow?
    public let options: Options
    /// What the display was last asked for; nil when nothing is, or after
    /// `reset`.
    public private(set) var appliedCriteria: ContentDisplayCriteria?

    private var trackingTask: Task<Void, Never>?
    private weak var heldSession: PlayerSession?
    /// Sessions that show no frames are given up on after this long.
    private static let trackingLimit: Double = 15

    public init(window: UIWindow? = nil, options: Options = Options()) {
        self.window = window
        self.options = options
    }

    /// True while the user's settings let apps switch the display mode
    /// (Settings → Video and Audio → Match Content).
    public var isMatchingEnabled: Bool {
        window?.avDisplayManager.isDisplayCriteriaMatchingEnabled ?? false
    }

    /// True while the display is switching modes and may be blank.
    public var isModeSwitchInProgress: Bool {
        window?.avDisplayManager.isDisplayModeSwitchInProgress ?? false
    }

    /// Matches the display to `session`'s video. Call after `open` succeeds
    /// and before `play()`: the start hold is in place when this returns, the
    /// rest (waiting for the first frames, the switch) continues in the
    /// background. A later call for another session supersedes this one.
    public func match(_ session: PlayerSession) async {
        trackingTask?.cancel()
        if let previous = heldSession, previous !== session {
            await previous.releaseStartHold()
        }
        heldSession = nil

        let holding = options.holdsStartDuringModeSwitch && isMatchingEnabled
        if holding {
            heldSession = session
            await session.holdStart(for: options.maximumHold)
        }
        let started = ProcessInfo.processInfo.systemUptime
        trackingTask = Task { [weak self] in
            await self?.track(session, holding: holding, since: started)
        }
    }

    /// Hands the display back to the system's default mode and stops
    /// matching. Call when the player screen goes away — not between
    /// sessions on it.
    public func reset() {
        trackingTask?.cancel()
        trackingTask = nil
        if let session = heldSession {
            Task { await session.releaseStartHold() }
        }
        heldSession = nil
        if appliedCriteria != nil {
            window?.avDisplayManager.preferredDisplayCriteria = nil
        }
        appliedCriteria = nil
    }

    // MARK: Tracking

    /// Applies the criteria once the first frames confirm them, or the
    /// stream's prediction when frames are slow, correcting a prediction once
    /// if the frames disagree. Mid-stream changes are not chased: every
    /// switch blanks the TV, and a live channel's ad break must not.
    private func track(_ session: PlayerSession, holding: Bool, since started: TimeInterval) async {
        var holding = holding
        var applied: ContentDisplayCriteria?
        while !Task.isCancelled {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if let criteria = await session.displayCriteria {
                let confirmed = criteria.basis == .output
                if applied == nil, confirmed || elapsed >= options.outputWait {
                    await apply(criteria, to: session, holding: holding, since: started)
                    applied = criteria
                    // The TV is in its mode (or the hold ran out): start.
                    if holding {
                        holding = false
                        await release(session)
                    }
                } else if let previous = applied, previous.basis == .stream, confirmed {
                    if !previous.asksForSameMode(as: criteria) {
                        await apply(criteria, to: session, holding: false, since: started)
                    }
                    applied = criteria
                }
                if applied?.basis == .output { break }
            } else if await session.mediaInfo != nil, await session.selectedVideoTrackIndex == nil {
                break // nothing to match: no video
            }
            guard elapsed < Self.trackingLimit else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Gave up without asking (no video, no frames): don't keep the
        // session waiting for a switch that is not coming. A cancelled track
        // was superseded, and whoever cancelled it released the hold.
        if holding, !Task.isCancelled {
            await release(session)
        }
    }

    private func release(_ session: PlayerSession) async {
        await session.releaseStartHold()
        if heldSession === session { heldSession = nil }
    }

    private func apply(
        _ criteria: ContentDisplayCriteria,
        to session: PlayerSession,
        holding: Bool,
        since started: TimeInterval
    ) async {
        guard let manager = window?.avDisplayManager,
              manager.isDisplayCriteriaMatchingEnabled,
              let format = criteria.makeFormatDescription()
        else { return }
        if let current = appliedCriteria, current.asksForSameMode(as: criteria) {
            appliedCriteria = criteria
            return // already in it: asking again would at best do nothing
        }
        // A refresh rate of 0 leaves the rate to the system: content whose
        // rate is unknown or off the grid still gets its dynamic range.
        manager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: Float(criteria.refreshRate ?? 0),
            formatDescription: format
        )
        appliedCriteria = criteria
        guard holding else { return }
        await waitForModeSwitch(manager, deadline: started + options.maximumHold)
    }

    /// Waits for the switch the last request started, if it started one.
    /// Polled: the flag is the documented signal, and a switch lasts seconds.
    private func waitForModeSwitch(_ manager: AVDisplayManager, deadline: TimeInterval) async {
        func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        let asked = now()
        var switching = manager.isDisplayModeSwitchInProgress
        while !switching, now() - asked < options.switchStartWindow, now() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            switching = manager.isDisplayModeSwitchInProgress
        }
        while switching, now() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            switching = manager.isDisplayModeSwitchInProgress
        }
    }
}
#endif
