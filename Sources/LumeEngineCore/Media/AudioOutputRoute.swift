#if os(iOS) || os(tvOS) || os(visionOS)
import AVFAudio
#endif
import Foundation
import Synchronization

/// How many channels the audio output route carries, kept current while the
/// route changes under a playing session (HDMI receiver → AirPlay → HomePods).
///
/// The audio decoder reads it for every decoded frame and folds its output to
/// fit (`AudioLayoutPolicy`), so a route change takes effect at the next frame
/// boundary; the renderer reads it to keep audio decoded for a wider, earlier
/// route away from a narrower one.
///
/// The width is what the audio session *negotiated*
/// (`outputNumberOfChannels`), never what the hardware could carry
/// (`maximumOutputNumberOfChannels`): multichannel LPCM only flows once the
/// host asks for it with `setPreferredOutputNumberOfChannels`, and a renderer
/// fed more channels than the session outputs failed outright on tvOS.
/// Configuring and activating the session is the host's job — this type only
/// observes it.
///
/// `system()` follows the shared `AVAudioSession`. On macOS there is no audio
/// session; it reports stereo, which is what the default output overwhelmingly
/// is. A host that knows better (a macOS multichannel interface), and tests,
/// create one with `init(outputChannels:)` and drive it with `update`.
public final class AudioOutputRoute: Sendable {
    public struct Snapshot: Sendable, Equatable, CustomStringConvertible {
        /// Channels the route carries for this app now.
        public var outputChannels: Int
        /// Channels the route could carry if the host asked for them; nil
        /// where nothing reports it. More than `outputChannels` on a surround
        /// route means the host did not ask for the route's full width.
        public var maximumOutputChannels: Int?
        /// Output port types (`HDMIOutput`, `AirPlay`, …). Types only, never
        /// the user-visible port names.
        public var ports: [String]
        /// How often the width has changed since the route was created.
        public var changes: Int

        public var description: String {
            var line = "\(outputChannels)ch"
            if let maximumOutputChannels { line += "/\(maximumOutputChannels)" }
            if !ports.isEmpty { line += " " + ports.joined(separator: "+") }
            return line
        }
    }

    private let state: Mutex<Snapshot>
    private let observers = Mutex<[any NSObjectProtocol]>([])

    /// A route of fixed width that only `update` changes.
    public init(outputChannels: Int, maximumOutputChannels: Int? = nil, ports: [String] = []) {
        state = Mutex(Snapshot(
            outputChannels: max(1, outputChannels),
            maximumOutputChannels: maximumOutputChannels,
            ports: ports,
            changes: 0
        ))
    }

    deinit {
        for observer in observers.withLock({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// The route of the shared audio session, followed through route changes.
    public static func system() -> AudioOutputRoute {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let current = sessionSnapshot()
        let route = AudioOutputRoute(
            outputChannels: current.outputChannels,
            maximumOutputChannels: current.maximumOutputChannels,
            ports: current.ports
        )
        route.followSession()
        return route
        #else
        return AudioOutputRoute(outputChannels: 2)
        #endif
    }

    /// Channels the route carries now. Cheap: read once per decoded frame.
    public var outputChannels: Int {
        state.withLock { $0.outputChannels }
    }

    public var snapshot: Snapshot {
        state.withLock { $0 }
    }

    /// Reports a new width (and, when known, capability and ports).
    public func update(outputChannels: Int, maximumOutputChannels: Int? = nil, ports: [String]? = nil) {
        state.withLock { snapshot in
            let width = max(1, outputChannels)
            if width != snapshot.outputChannels { snapshot.changes += 1 }
            snapshot.outputChannels = width
            if let maximumOutputChannels { snapshot.maximumOutputChannels = maximumOutputChannels }
            if let ports { snapshot.ports = ports }
        }
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    /// The session's current output. Clamped to stereo at the bottom: an
    /// inactive session reports 0 or 1, and a stereo fold-down is right for
    /// every real route that is narrower.
    private static func sessionSnapshot() -> (outputChannels: Int, maximumOutputChannels: Int, ports: [String]) {
        let session = AVAudioSession.sharedInstance()
        return (
            max(2, session.outputNumberOfChannels),
            session.maximumOutputNumberOfChannels,
            session.currentRoute.outputs.map(\.portType.rawValue)
        )
    }

    /// Route changes are posted on a system thread; the width is re-read
    /// there. A change of the negotiated width alone (the host asking for more
    /// channels) arrives as `.routeConfigurationChange`, so every reason is
    /// taken.
    private func followSession() {
        // The token is created inside the lock so it never leaves the
        // mutex's region (it is not Sendable).
        observers.withLock { observers in
            observers.append(NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                let current = Self.sessionSnapshot()
                self?.update(
                    outputChannels: current.outputChannels,
                    maximumOutputChannels: current.maximumOutputChannels,
                    ports: current.ports
                )
            })
        }
    }
    #endif
}
