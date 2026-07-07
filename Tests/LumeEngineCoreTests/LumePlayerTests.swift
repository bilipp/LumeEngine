import Foundation
import Testing
@testable import LumeEngine
@testable import LumeEngineCore

@Suite("LumePlayer facade", .serialized)
struct LumePlayerTests {
    @Test("load → play mirrors state and position on the main actor", .timeLimit(.minutes(1)))
    @MainActor
    func facadePlayback() async throws {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.3
        let player = LumePlayer(configuration: configuration)

        let info = try await player.load(url: try Fixtures.path("basic.mp4"))
        #expect(info.videoTracks.count == 1)
        #expect(player.duration.map { abs($0 - 10) < 0.5 } == true)
        #expect(player.displayLayer != nil)

        player.play()
        let deadline = Date(timeIntervalSinceNow: 10)
        while player.state != .playing && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(player.state == .playing)

        try await Task.sleep(for: .seconds(1))
        #expect(player.position > 0.5, "observable position should tick, got \(player.position)")

        player.seek(to: 6)
        let seekDeadline = Date(timeIntervalSinceNow: 10)
        while player.position < 5.5 && Date() < seekDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(player.position >= 5.5 && player.position <= 8.5)

        await player.stop()
        #expect(player.state == .idle)
    }

    @Test("load replaces the previous session cleanly", .timeLimit(.minutes(1)))
    @MainActor
    func reload() async throws {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.3
        let player = LumePlayer(configuration: configuration)

        _ = try await player.load(url: try Fixtures.path("basic.mp4"))
        player.play()
        try await Task.sleep(for: .milliseconds(500))

        // Second load must tear down the first pipeline (no leaked threads
        // keeping the old clock alive) and start fresh.
        let info = try await player.load(url: try Fixtures.path("multitrack.mkv"))
        #expect(info.audioTracks.count == 2)
        player.play()

        let deadline = Date(timeIntervalSinceNow: 10)
        while player.state != .playing && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(player.state == .playing)
        #expect(player.position < 9, "position must belong to the new session")

        await player.stop()
    }
}
