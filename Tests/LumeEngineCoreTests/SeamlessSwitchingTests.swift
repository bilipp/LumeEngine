import Foundation
import Testing
@testable import LumeEngine
@testable import LumeEngineCore

/// Zero-delay stream switching (PLAN.md §6, issue #16): `prepare(next:)`
/// stages a standby session through first-frame-decoded and `load(url:)`
/// swaps it in atomically; without a prepared session, a seamless load keeps
/// the old session alive until the replacement holds its first frame.
@Suite("Zero-delay switching", .serialized)
struct SeamlessSwitchingTests {
    private func makeConfiguration() -> PlayerConfiguration {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.3
        return configuration
    }

    @Test("waitForFirstFrame resolves on an opened, never-played session", .timeLimit(.minutes(1)))
    func firstFrameGate() async throws {
        let session = PlayerSession(configuration: makeConfiguration())
        _ = try await session.open(url: try Fixtures.path("basic.mp4"))

        // Paused throughout: the renderers must accept the first frame with
        // the clock stopped (that's what makes a standby swap gapless).
        let ready = await session.waitForFirstFrame(timeout: 10)
        #expect(ready, "first frame should decode without playback starting")

        let lowWater = session.renderer.enqueuedLowWaterMark
        #expect(MediaTime.isValid(lowWater.video), "video renderer should hold the first frame")
        #expect(session.renderer.rate == 0, "the standby clock must never run")

        await session.shutdown()
    }

    @Test("waitForFirstFrame reports failure instead of hanging", .timeLimit(.minutes(1)))
    func firstFrameGateFailure() async {
        let session = PlayerSession(configuration: makeConfiguration())
        _ = try? await session.open(url: "/nonexistent/definitely-missing.mp4")
        let ready = await session.waitForFirstFrame(timeout: 5)
        #expect(!ready)
        await session.shutdown()
    }

    @Test("prepare(next:) then load swaps sessions atomically", .timeLimit(.minutes(1)))
    @MainActor
    func prepareThenLoad() async throws {
        let player = LumePlayer(configuration: makeConfiguration())

        _ = try await player.load(url: try Fixtures.path("basic.mp4"))
        let firstLayer = player.displayLayer
        player.play()
        try await eventually(player, reaches: .playing)

        let nextURL = try Fixtures.path("multitrack.mkv")
        let preparedInfo = try await player.prepare(next: nextURL)
        #expect(preparedInfo.audioTracks.count == 2)
        // Preparation must not disturb current playback.
        #expect(player.state == .playing)
        #expect(player.displayLayer === firstLayer)

        // The staged session is consumed: the swap needs no second open.
        let start = Date()
        let info = try await player.load(url: nextURL)
        #expect(info.audioTracks.count == 2)
        #expect(Date().timeIntervalSince(start) < 2, "a prepared load must not re-open the source")
        #expect(player.displayLayer !== firstLayer, "the swap must install the standby session's layer")

        player.play()
        try await eventually(player, reaches: .playing)
        #expect(player.position < 9, "position must belong to the new session")

        await player.stop()
    }

    @Test("seamless load keeps the old session until the new one has a frame", .timeLimit(.minutes(1)))
    @MainActor
    func seamlessLoadWithoutPrepare() async throws {
        let player = LumePlayer(configuration: makeConfiguration())

        _ = try await player.load(url: try Fixtures.path("basic.mp4"))
        let firstLayer = player.displayLayer
        player.play()
        try await eventually(player, reaches: .playing)

        let info = try await player.load(url: try Fixtures.path("multitrack.mkv"))
        #expect(info.audioTracks.count == 2)
        #expect(player.displayLayer !== firstLayer)

        player.play()
        try await eventually(player, reaches: .playing)
        await player.stop()
    }

    @Test("seamless load of a dead source falls back cold and fails loudly", .timeLimit(.minutes(1)))
    @MainActor
    func seamlessLoadFailure() async throws {
        let player = LumePlayer(configuration: makeConfiguration())

        _ = try await player.load(url: try Fixtures.path("basic.mp4"))
        player.play()
        try await eventually(player, reaches: .playing)

        await #expect(throws: EngineError.self) {
            _ = try await player.load(url: "/nonexistent/definitely-missing.mp4")
        }
        // The failed load replaced the old session (load's contract), so the
        // player ends in a reportable failed state — never a silent limbo.
        // (The event pump delivers the session's state trail asynchronously,
        // so allow it to settle.)
        try await eventually(player, reaches: .failed)

        await player.stop()
    }

    @Test("sequential policy switches on one connection at a time", .timeLimit(.minutes(1)))
    @MainActor
    func sequentialSwitch() async throws {
        var configuration = makeConfiguration()
        configuration.switchPolicy = .sequential
        let player = LumePlayer(configuration: configuration)

        _ = try await player.load(url: try Fixtures.path("basic.mp4"))
        let firstLayer = player.displayLayer
        player.play()
        try await eventually(player, reaches: .playing)

        // The old session closes before the new one opens (one connection);
        // the surface swaps only once the replacement holds its first frame.
        let info = try await player.load(url: try Fixtures.path("multitrack.mkv"))
        #expect(info.audioTracks.count == 2)
        #expect(player.displayLayer !== firstLayer)

        player.play()
        try await eventually(player, reaches: .playing)
        #expect(player.position < 9, "position must belong to the new session")

        await player.stop()
    }

    @Test("sequential load of a dead source keeps the frozen surface and fails", .timeLimit(.minutes(1)))
    @MainActor
    func sequentialLoadFailure() async throws {
        var configuration = makeConfiguration()
        configuration.switchPolicy = .sequential
        let player = LumePlayer(configuration: configuration)

        _ = try await player.load(url: try Fixtures.path("basic.mp4"))
        let firstLayer = player.displayLayer
        player.play()
        try await eventually(player, reaches: .playing)

        await #expect(throws: EngineError.self) {
            _ = try await player.load(url: "/nonexistent/definitely-missing.mp4")
        }
        try await eventually(player, reaches: .failed)
        // The dead session stays attached so its last frame keeps the surface
        // alive behind the app's failure UI.
        #expect(player.displayLayer === firstLayer)

        await player.stop()
    }

    @Test("switchPolicy .none restores the cold teardown-first path", .timeLimit(.minutes(1)))
    @MainActor
    func coldSwitchWhenDisabled() async throws {
        var configuration = makeConfiguration()
        configuration.switchPolicy = .none
        let player = LumePlayer(configuration: configuration)

        _ = try await player.load(url: try Fixtures.path("basic.mp4"))
        player.play()
        try await eventually(player, reaches: .playing)

        let info = try await player.load(url: try Fixtures.path("multitrack.mkv"))
        #expect(info.audioTracks.count == 2)
        player.play()
        try await eventually(player, reaches: .playing)

        await player.stop()
    }

    @MainActor
    private func eventually(
        _ player: LumePlayer,
        reaches state: LumePlayer.State,
        within seconds: Double = 10
    ) async throws {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while player.state != state && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(player.state == state)
    }
}
