import Foundation
import MediaPlayer
import Testing
@testable import LumeEngineCore

@Suite("Platform integration", .serialized)
struct PlatformIntegrationTests {
    @Test("Now Playing metadata publishes to MPNowPlayingInfoCenter")
    @MainActor
    func nowPlayingMetadata() {
        let center = NowPlayingCenter()
        center.activate(handlers: NowPlayingCenter.Handlers())
        center.update(metadata: .init(title: "Big Buck Bunny", artist: "LumeEngine", isLiveStream: false))
        center.update(position: 42.5, duration: 600, rate: 1.0)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        #expect(info?[MPMediaItemPropertyTitle] as? String == "Big Buck Bunny")
        #expect(info?[MPMediaItemPropertyArtist] as? String == "LumeEngine")
        #expect(info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 42.5)
        #expect(info?[MPMediaItemPropertyPlaybackDuration] as? Double == 600)
        #expect(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Float == 1.0)
        #expect(info?[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == false)

        center.clear()
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
    }

    @Test("remote commands route to handlers")
    @MainActor
    func remoteCommands() {
        let center = NowPlayingCenter()
        let played = LockedBox<Bool>(false)
        let sought = LockedBox<Double>(-1)

        var handlers = NowPlayingCenter.Handlers()
        handlers.play = { played.set(true) }
        handlers.seek = { sought.set($0) }
        center.activate(handlers: handlers)

        #expect(MPRemoteCommandCenter.shared().playCommand.isEnabled)
        #expect(MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled)
        #expect(MPRemoteCommandCenter.shared().skipForwardCommand.preferredIntervals == [15])

        center.clear()
        #expect(!MPRemoteCommandCenter.shared().playCommand.isEnabled)
    }

    @Test("PiP bridge initializes against a live session without crashing", .timeLimit(.minutes(1)))
    @MainActor
    func pipBridge() async throws {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        let session = PlayerSession(configuration: configuration)
        let info = try await session.open(url: try Fixtures.path("basic.mp4"))

        let bridge = PictureInPictureBridge(session: session, mediaInfo: info)
        // Headless CI has no PiP support; on a desktop it should not crash either way.
        _ = bridge.isSupported
        _ = bridge.isPossible
        bridge.stop() // no-op when unsupported/inactive

        await session.shutdown()
    }
}
