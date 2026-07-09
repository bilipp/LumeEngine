import Foundation
import Testing
@testable import LumeEngineCore

@Suite("PlayerSession", .serialized)
struct PlayerSessionTests {
    private func makeSession() -> PlayerSession {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.5
        return PlayerSession(configuration: configuration)
    }

    /// Polls an actor-derived condition with a deadline.
    private func eventually(
        timeout: TimeInterval = 10,
        interval: Duration = .milliseconds(100),
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: interval)
        }
        return false
    }

    @Test("open → play advances the clock in real time", .timeLimit(.minutes(1)))
    func playbackAdvances() async throws {
        let session = makeSession()
        let info = try await session.open(url: try Fixtures.path("basic.mp4"))
        #expect(info.videoTracks.count == 1)
        #expect(await session.state == .ready)

        await session.play()
        let reachedPlaying = await eventually { await session.state == .playing }
        #expect(reachedPlaying, "session must reach .playing")

        let p1 = await session.position
        try await Task.sleep(for: .seconds(1))
        let p2 = await session.position
        let advanced = p2 - p1
        #expect(advanced > 0.6 && advanced < 1.6, "clock should advance ~1 s of media per wall second, got \(advanced)")

        await session.shutdown()
    }

    @Test("pause freezes the clock; play resumes", .timeLimit(.minutes(1)))
    func pauseResume() async throws {
        let session = makeSession()
        _ = try await session.open(url: try Fixtures.path("basic.mp4"))
        await session.play()
        _ = await eventually { await session.state == .playing }

        await session.pause()
        #expect(await session.state == .paused)
        let p1 = await session.position
        try await Task.sleep(for: .milliseconds(500))
        let p2 = await session.position
        #expect(abs(p2 - p1) < 0.05, "paused clock must not advance (drifted \(p2 - p1))")

        await session.play()
        let resumed = await eventually { await session.state == .playing }
        #expect(resumed)
        try await Task.sleep(for: .milliseconds(500))
        let p3 = await session.position
        #expect(p3 > p2 + 0.2, "clock must advance after resume")

        await session.shutdown()
    }

    @Test("seek jumps the position and playback continues", .timeLimit(.minutes(1)))
    func seek() async throws {
        let session = makeSession()
        _ = try await session.open(url: try Fixtures.path("basic.mp4"))
        await session.play()
        _ = await eventually { await session.state == .playing }

        await session.seek(to: 7.0)
        let landed = await eventually {
            let position = await session.position
            return position >= 6.5 && position <= 8.5
        }
        let landedPosition = await session.position
        #expect(landed, "position should land near 7 s, got \(landedPosition)")

        // Still playing after the seek.
        let p1 = await session.position
        try await Task.sleep(for: .milliseconds(700))
        let p2 = await session.position
        #expect(p2 > p1 + 0.3, "playback must continue after seek")

        await session.shutdown()
    }

    @Test("startPosition opens at the requested resume point", .timeLimit(.minutes(1)))
    func startPosition() async throws {
        // Resume positions must seek before the demuxer's first read (some
        // IPTV providers kill a connection that seeks mid-stream), so the
        // engine takes them via configuration, not open-then-seek.
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.5
        configuration.startPosition = 7.0
        let session = PlayerSession(configuration: configuration)
        _ = try await session.open(url: try Fixtures.path("basic.mp4"))
        await session.play()
        let playing = await eventually { await session.state == .playing }
        #expect(playing, "session must reach .playing from a start position")
        let position = await session.position
        #expect(position > 6.0 && position < 9.5, "expected playback near 7 s, got \(position)")
        await session.shutdown()
    }

    @Test("playback reaches .ended at end of file", .timeLimit(.minutes(2)))
    func playsToEnd() async throws {
        let session = makeSession()
        _ = try await session.open(url: try Fixtures.path("basic.mp4"))
        await session.setRate(2.0)
        await session.play()
        _ = await eventually { await session.state == .playing }

        // Jump near the end so the test doesn't wait ~10 s.
        await session.seek(to: 8.5)
        let ended = await eventually(timeout: 20) { await session.state == .ended }
        let endState = await session.state
        #expect(ended, "state should become .ended, is \(endState)")

        // Seek back revives playback (seamless-loop building block).
        await session.play()
        await session.seek(to: 1.0)
        let revived = await eventually { await session.state == .playing }
        #expect(revived, "seek after EOF must revive playback")

        await session.shutdown()
    }

    @Test("open failure throws and the session is .failed", .timeLimit(.minutes(1)))
    func openFailure() async {
        let session = makeSession()
        do {
            _ = try await session.open(url: "/nonexistent/nope.mkv")
            Issue.record("open should have thrown")
        } catch {
            #expect((error as? EngineError)?.code == .openFailed)
        }
        #expect(await session.state == .failed)
        await session.shutdown()
    }

    @Test("audio-only source plays (no video lane)", .timeLimit(.minutes(1)))
    func audioOnly() async throws {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.enableVideo = false
        configuration.bufferTarget = 0.3
        let session = PlayerSession(configuration: configuration)

        _ = try await session.open(url: try Fixtures.path("basic.mp4"))
        await session.play()
        let playing = await eventually { await session.state == .playing }
        #expect(playing)
        try await Task.sleep(for: .milliseconds(800))
        #expect(await session.position > 0.4)

        await session.shutdown()
    }

    @Test("MPEG-TS with wrapped timestamps plays and seeks", .timeLimit(.minutes(1)))
    func wrappedTransportStream() async throws {
        let session = makeSession()
        _ = try await session.open(url: try Fixtures.path("wrap.ts"))
        // Whatever origin FFmpeg reports for the wrapped TS timeline, the
        // engine's position must be media-relative (0-based).

        await session.play()
        let playing = await eventually { await session.state == .playing }
        #expect(playing)

        let settled = await eventually {
            let position = await session.position
            return position > 0 && position < 13
        }
        #expect(settled, "position must be media-relative despite the wrapped TS timeline")

        await session.shutdown()
    }
}
