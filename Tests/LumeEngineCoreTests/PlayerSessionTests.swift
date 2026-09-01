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

        // Poll for progress rather than measuring a fixed wall-clock window:
        // a contended CI runner can stall the sampling itself, which says
        // nothing about the clock. "Advances in real time" means it keeps
        // moving and does not outrun the media — both hold whenever the
        // sampler gets scheduled.
        let p1 = await session.position
        let advanced = await eventually { await session.position - p1 > 0.6 }
        let reached = await session.position - p1
        #expect(advanced, "clock must keep advancing, reached \(reached)")

        let elapsed = Date()
        let p2 = await session.position
        try await Task.sleep(for: .milliseconds(500))
        let drift = (await session.position - p2) - Date().timeIntervalSince(elapsed)
        #expect(drift < 0.5, "clock must not outrun wall time, got \(drift) s of excess")

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

        // Stopping is not instantaneous: the synchronizer's timebase is slaved
        // to the audio renderer's clock, so `rate = 0` lands a moment after
        // pause() returns — on a contended host, a visible moment. What must
        // hold is that the clock converges to a stop and then stays there, not
        // that it is already frozen on the next line.
        let stopped = await eventually {
            let a = await session.position
            try? await Task.sleep(for: .milliseconds(100))
            return abs(await session.position - a) < 0.01
        }
        #expect(stopped, "paused clock must come to a stop")

        let p1 = await session.position
        try await Task.sleep(for: .milliseconds(500))
        let p2 = await session.position
        #expect(abs(p2 - p1) < 0.05, "paused clock must stay stopped (drifted \(p2 - p1))")

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

        // Still playing after the seek. Poll for progress instead of measuring
        // a rate over a fixed window: the landing check above is satisfied the
        // moment the renderer anchors at the target with the rate still 0, so a
        // short window can be spent almost entirely on the post-seek rebuffer
        // (the same race that made the audio-switch test flake in CI).
        let p1 = await session.position
        let advanced = await eventually(timeout: 15) { await session.position > p1 + 0.3 }
        let p2 = await session.position
        #expect(advanced, "playback must continue after seek (was \(p1), now \(p2))")

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

    // MARK: Preferred languages
    //
    // The selection must happen while the pipeline is built: selecting after
    // open() routes through seek(to: position) with position still 0, which
    // wipes a startPosition resume and seeks live sources that cannot take one.
    // These tests therefore assert the state right after open(), before play().

    private func makeLanguageSession(audioLanguages: [String] = []) -> PlayerSession {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.5
        configuration.preferredAudioLanguages = audioLanguages
        // What a host that wants the forced-subtitle rule sets. The rule is
        // opt-in, so these tests have to opt in the same way Lume does.
        configuration.autoEnableForcedSubtitlesForForeignAudio = true
        return PlayerSession(configuration: configuration)
    }

    @Test("preferred audio language beats the container default", .timeLimit(.minutes(1)))
    func preferredAudioLanguageWins() async throws {
        // multilang.mkv: a:0 eng carries the default disposition, a:1 ger does not.
        let session = makeLanguageSession(audioLanguages: ["de", "en"])
        let info = try await session.open(url: try Fixtures.path("multilang.mkv"))

        let german = try #require(info.audioTracks.first { $0.language == "ger" })
        #expect(await session.selectedAudioTrackIndex == german.index)
        #expect(await session.selectedSubtitleTrackIndex == nil, "subtitles must stay off")

        await session.shutdown()
    }

    @Test("no preference keeps the container default", .timeLimit(.minutes(1)))
    func noPreferenceKeepsContainerDefault() async throws {
        let session = makeLanguageSession()
        let info = try await session.open(url: try Fixtures.path("multilang.mkv"))

        let english = try #require(info.audioTracks.first { $0.language == "eng" })
        #expect(await session.selectedAudioTrackIndex == english.index)

        await session.shutdown()
    }

    @Test("an unmatched preference is inert", .timeLimit(.minutes(1)))
    func unmatchedPreferenceIsInert() async throws {
        // No Japanese track: "no match" means leaving the container alone, not
        // picking track 0 and not surfacing anything.
        let session = makeLanguageSession(audioLanguages: ["ja"])
        let info = try await session.open(url: try Fixtures.path("multilang.mkv"))

        let english = try #require(info.audioTracks.first { $0.language == "eng" })
        #expect(await session.selectedAudioTrackIndex == english.index)

        await session.shutdown()
    }

    @Test("foreign audio auto-enables a forced subtitle track", .timeLimit(.minutes(1)))
    func forcedSubtitlesUnderForeignAudio() async throws {
        // forcedsubs.mkv has English audio only; a German-preferring viewer
        // gets audio they did not ask for, so the forced track comes on.
        let session = makeLanguageSession(audioLanguages: ["de"])
        let info = try await session.open(url: try Fixtures.path("forcedsubs.mkv"))

        let forced = try #require(info.subtitleTracks.first { $0.isForced })
        #expect(await session.selectedSubtitleTrackIndex == forced.index)

        await session.shutdown()
    }

    @Test("foreign audio never enables a non-forced subtitle track", .timeLimit(.minutes(1)))
    func foreignAudioLeavesFullSubtitleTracksOff() async throws {
        // multitrack.mkv is eng+ger audio with a plain (non-forced) eng SRT.
        // A Japanese-preferring viewer gets foreign audio, but only a forced
        // track is ever switched on for them — a full track stays the app's
        // call, made through selectSubtitleTrack(_:).
        let session = makeLanguageSession(audioLanguages: ["ja"])
        _ = try await session.open(url: try Fixtures.path("multitrack.mkv"))
        #expect(await session.selectedSubtitleTrackIndex == nil, "only forced tracks are ever auto-enabled")
        await session.shutdown()
    }

    @Test("matching audio leaves forced subtitles off", .timeLimit(.minutes(1)))
    func forcedSubtitlesStayOffWhenAudioMatches() async throws {
        let session = makeLanguageSession(audioLanguages: ["en"])
        _ = try await session.open(url: try Fixtures.path("forcedsubs.mkv"))
        #expect(await session.selectedSubtitleTrackIndex == nil)
        await session.shutdown()
    }

    @Test("default configuration never reaches the forced branch", .timeLimit(.minutes(1)))
    func forcedSubtitlesUnreachableWithoutPreferences() async throws {
        let session = makeLanguageSession()
        _ = try await session.open(url: try Fixtures.path("forcedsubs.mkv"))
        #expect(await session.selectedSubtitleTrackIndex == nil, "empty preferences must behave exactly as before")
        await session.shutdown()
    }
}
