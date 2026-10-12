import Foundation
import Testing
@testable import LumeEngineCore

/// `PlayerSession.shutdown()` joins the data plane on a thread of its own and
/// awaits it (see `DedicatedThread`), so other calls can reach the actor while
/// the joins run. These pin down what such an interleaving may and may not do.
@Suite("Teardown")
struct TeardownTests {
    private func makeSession() -> PlayerSession {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.5
        return PlayerSession(configuration: configuration)
    }

    @Test("shutdown while opening fails the open instead of leaving it hung", .timeLimit(.minutes(1)))
    func shutdownWhileOpening() async throws {
        // Headers, then silence: the open parks in FFmpeg's probe read.
        let server = try TortureHTTPServer(mode: .stallAfter(prefix: 0, file: Fixtures.url("wrap.ts")))
        defer { server.stop() }

        let session = makeSession()
        let opening = Task { try await session.open(url: server.url) }
        // Once the server sees the connection, `open` has run up to its
        // suspension: the demuxer exists and the open is waiting on it.
        let deadline = Date(timeIntervalSinceNow: 10)
        while server.connectionCount == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(server.connectionCount > 0)

        await session.shutdown()
        await #expect(throws: EngineError.self) { try await opening.value }
        #expect(await session.state == .failed)
    }

    @Test("concurrent shutdowns both wait for the teardown", .timeLimit(.minutes(1)))
    func concurrentShutdowns() async throws {
        let session = makeSession()
        let info = try await session.open(url: try Fixtures.path("multilang.mkv"))
        await session.play()
        let selected = await session.selectedAudioTrackIndex
        let other = try #require(info.audioTracks.first { $0.index != selected })

        async let first: Void = session.shutdown()
        async let second: Void = session.shutdown()
        _ = await (first, second)

        #expect(await session.state == .idle)
        // Nothing left to act on: a call that interleaves with (or follows)
        // the teardown must not build a lane on the closed source.
        await session.selectAudioTrack(other.index)
        #expect(await session.selectedAudioTrackIndex == selected)
    }
}
