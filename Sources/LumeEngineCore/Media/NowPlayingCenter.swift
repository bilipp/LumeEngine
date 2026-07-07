import Foundation
import MediaPlayer

/// Lock screen / Control Center integration (PLAN.md §6 — explicit requirement:
/// metadata must show on the iPhone lock screen, including while the route goes
/// to an Apple TV).
///
/// One instance per app (the system has a single Now Playing slot); attach and
/// detach players as they come and go. Works with any engine — Lume's shared
/// app-level service wraps this so the AVPlayer/AirPlay path gets it too.
@MainActor
public final class NowPlayingCenter {
    public struct Metadata: Sendable, Equatable {
        public var title: String
        public var artist: String?
        public var albumTitle: String?
        public var isLiveStream: Bool

        public init(title: String, artist: String? = nil, albumTitle: String? = nil, isLiveStream: Bool = false) {
            self.title = title
            self.artist = artist
            self.albumTitle = albumTitle
            self.isLiveStream = isLiveStream
        }
    }

    /// Remote commands forwarded to the app/player.
    public struct Handlers: Sendable {
        public var play: @MainActor @Sendable () -> Void = {}
        public var pause: @MainActor @Sendable () -> Void = {}
        public var seek: @MainActor @Sendable (_ position: Double) -> Void = { _ in }
        public var skipForward: @MainActor @Sendable (_ interval: Double) -> Void = { _ in }
        public var skipBackward: @MainActor @Sendable (_ interval: Double) -> Void = { _ in }
        public var next: (@MainActor @Sendable () -> Void)?
        public var previous: (@MainActor @Sendable () -> Void)?

        public init() {}
    }

    private var registeredTargets: [(MPRemoteCommand, Any)] = []
    private var artwork: MPMediaItemArtwork?

    public init() {}

    /// Installs remote command handlers (idempotent; replaces previous handlers).
    public func activate(handlers: Handlers, skipInterval: Double = 15) {
        deactivateCommands()
        let center = MPRemoteCommandCenter.shared()

        register(center.playCommand) { _ in
            handlers.play()
            return .success
        }
        register(center.pauseCommand) { _ in
            handlers.pause()
            return .success
        }
        register(center.togglePlayPauseCommand) { _ in
            handlers.play() // player decides; toggle semantics live app-side
            return .success
        }
        register(center.changePlaybackPositionCommand) { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            handlers.seek(event.positionTime)
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        register(center.skipForwardCommand) { _ in
            handlers.skipForward(skipInterval)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        register(center.skipBackwardCommand) { _ in
            handlers.skipBackward(skipInterval)
            return .success
        }
        if let next = handlers.next {
            register(center.nextTrackCommand) { _ in
                next()
                return .success
            }
        }
        if let previous = handlers.previous {
            register(center.previousTrackCommand) { _ in
                previous()
                return .success
            }
        }
    }

    /// Publishes static metadata (call once per item).
    public func update(metadata: Metadata) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = metadata.title
        info[MPMediaItemPropertyArtist] = metadata.artist
        info[MPMediaItemPropertyAlbumTitle] = metadata.albumTitle
        info[MPNowPlayingInfoPropertyIsLiveStream] = metadata.isLiveStream
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    public func update(artworkImage: CGImage) {
        #if canImport(UIKit)
        let image = UIImage(cgImage: artworkImage)
        #else
        let image = NSImage(cgImage: artworkImage, size: NSSize(width: artworkImage.width, height: artworkImage.height))
        #endif
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        self.artwork = artwork
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Publishes dynamic playback state (call on state/rate/seek changes —
    /// the system extrapolates elapsed time between calls, so ~per-event
    /// frequency is enough; never per-frame).
    public func update(position: Double, duration: Double?, rate: Float) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    public func clear() {
        deactivateCommands()
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func register(_ command: MPRemoteCommand, handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
        let target = command.addTarget(handler: handler)
        registeredTargets.append((command, target))
    }

    private func deactivateCommands() {
        for (command, target) in registeredTargets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        registeredTargets.removeAll()
    }
}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
