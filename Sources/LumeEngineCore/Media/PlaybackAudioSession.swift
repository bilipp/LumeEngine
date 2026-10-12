#if canImport(UIKit)
import AVFAudio
import Foundation

/// iOS/tvOS/visionOS audio session lifecycle for playback: category setup,
/// interruption handling (phone call → pause, resume when the system says so),
/// route-change handling (headphones unplugged → pause), and recovery from a
/// media-services reset.
///
/// Engine-owned (rather than left to the app) so every consumer gets correct
/// behavior out of the box.
@MainActor
public final class PlaybackAudioSession {
    public struct Callbacks: Sendable {
        /// Interruption began or output route disappeared: pause now.
        public var pauseRequested: @MainActor @Sendable () -> Void = {}
        /// Interruption ended with `.shouldResume`; the session is active again.
        public var resumeAllowed: @MainActor @Sendable () -> Void = {}
        /// The media server restarted. Every audio and video object from
        /// before is dead, renderers included: open a new player session. The
        /// audio session itself has been set up again by the time this runs.
        public var mediaServicesReset: @MainActor @Sendable () -> Void = {}
        public init() {}
    }

    private var observers: [NSObjectProtocol] = []

    public init() {}

    /// Activates the `.playback` / `.moviePlayback` session and installs
    /// interruption + route observers.
    public func activate(callbacks: Callbacks) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { notification in
            // Extract Sendable values before hopping isolation (the Notification
            // object itself is not Sendable).
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                switch type {
                case .began:
                    callbacks.pauseRequested()
                case .ended:
                    if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                        // The interruption deactivated the session. Resuming
                        // the clock on an inactive session leaves the render
                        // synchronizer frozen: the rate is set and nothing moves.
                        try? AVAudioSession.sharedInstance().setActive(true)
                        callbacks.resumeAllowed()
                    }
                @unknown default:
                    break
                }
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                if reason == .oldDeviceUnavailable {
                    callbacks.pauseRequested() // headphones yanked: never blast the room
                }
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // The reset also discarded the category and the activation.
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.playback, mode: .moviePlayback)
                try? session.setActive(true)
                callbacks.mediaServicesReset()
            }
        })
    }

    public func deactivate() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
