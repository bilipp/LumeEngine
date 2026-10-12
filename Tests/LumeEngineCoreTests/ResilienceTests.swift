import Foundation
import Testing
@testable import LumeEngineCore

@Suite("Resilience", .serialized)
struct ResilienceTests {
    private func makeConfiguration(ioTimeout: Int64? = 2_000_000, stallThreshold: Double = 2) -> PlayerConfiguration {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.3
        configuration.stallThreshold = stallThreshold
        configuration.demuxer.ioTimeout = ioTimeout
        configuration.demuxer.enableReconnect = false // deterministic failure paths
        return configuration
    }

    private func eventually(
        timeout: TimeInterval = 15,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test("HTTP playback works against a local server", .timeLimit(.minutes(1)))
    func httpHappyPath() async throws {
        let server = try TortureHTTPServer(mode: .file(Fixtures.url("wrap.ts")))
        defer { server.stop() }

        let session = PlayerSession(configuration: makeConfiguration())
        _ = try await session.open(url: server.url)
        await session.play()
        let playing = await eventually { await session.state == .playing }
        #expect(playing, "HTTP playback should start")
        let advanced = await eventually { await session.position > 0.2 }
        let reached = await session.position
        #expect(advanced, "clock must advance over HTTP, reached \(reached)")
        await session.shutdown()
    }

    @Test("resume-style seek over a range-less HTTP server keeps playing", .timeLimit(.minutes(1)))
    func seekOverRangelessHTTP() async throws {
        // Matroska cues live at end-of-file and this server ignores Range
        // requests (a routine IPTV-provider defect), so a seek right after
        // open cannot use the index — FFmpeg lands wherever it can. Two engine
        // guarantees are exercised: the seek command must preempt pipeline
        // backpressure (a demuxer parked in a full channel's send() once
        // deadlocked the whole session, watchdog disabled), and a landing
        // that disagrees with the target must be re-anchored to the delivered
        // PTS instead of running the clock where no media exists (silent
        // stuttering wedge). Wherever FFmpeg lands, playback must be running
        // and the clock advancing shortly after the seek.
        let server = try TortureHTTPServer(mode: .file(Fixtures.url("seekcues.mkv")))
        defer { server.stop() }

        var configuration = makeConfiguration()
        // Small read-ahead: this server's post-seek connection dies at its
        // end, and a large read-ahead would surface that I/O error during
        // initial buffering — this test is about seek dispatch and landing
        // recovery, not read-ahead policy.
        configuration.packetReadAhead = 2
        let session = PlayerSession(configuration: configuration)
        _ = try await session.open(url: server.url)
        // Resume flow: seek straight after open, like an app restoring the
        // last playback position before play().
        await session.seek(to: 45)
        await session.play()

        let playing = await eventually(timeout: 15) { await session.state == .playing }
        #expect(playing, "playback must start after the seek (no pipeline deadlock)")
        let p1 = await session.position
        let advanced = await eventually { await session.position > p1 + 1.0 }
        let p2 = await session.position
        #expect(advanced, "clock must advance after the seek, got \(p1) → \(p2)")
        await session.shutdown()
    }

    @Test("surplus delivery accumulates into the packet read-ahead", .timeLimit(.minutes(1)))
    func readAheadAccumulation() async throws {
        // Serve seekcues.mkv at 1.4× its own realtime bitrate: the pipeline must
        // bank the 0.4× surplus into the packet queues while playing, and that
        // accumulated runway is what absorbs the delivery gaps of bursty IPTV
        // sources.
        //
        // The rate is derived from the fixture rather than hardcoded. Fixtures are
        // encoded by whatever host ffmpeg/x264 is installed, and `-preset ultrafast`
        // with no rate target makes the size version-dependent — a hardcoded
        // 126_000 B/s was 1.40× on one machine and could be ~1.0× on another,
        // which silently turns "surplus" into "just barely enough" and fails the
        // accumulation expectations for reasons that have nothing to do with the
        // engine.
        let fixture = try Fixtures.url("seekcues.mkv")
        let fixtureBytes = try FileManager.default.attributesOfItem(atPath: fixture.path)[.size] as? Int ?? 0
        let realtimeBytesPerSecond = Double(fixtureBytes) / 60.0 // fixture is 60 s by construction
        let deliveryRate = Int(realtimeBytesPerSecond * 1.4)
        #expect(fixtureBytes > 0, "fixture missing or empty")

        let server = try TortureHTTPServer(mode: .throttled(file: fixture, bytesPerSecond: deliveryRate))
        defer { server.stop() }

        let session = PlayerSession(configuration: makeConfiguration(stallThreshold: 30))
        _ = try await session.open(url: server.url)
        await session.play()
        let playing = await eventually { await session.state == .playing }
        #expect(playing, "throttled-but-sufficient delivery must start playback")

        try await Task.sleep(for: .seconds(12))
        let diagnostics = await session.diagnostics
        let videoRunway = (diagnostics.videoQueue?.seconds ?? 0) + (diagnostics.videoPacketQueue?.seconds ?? 0)
        let audioRunway = (diagnostics.audioQueue?.seconds ?? 0) + (diagnostics.audioPacketQueue?.seconds ?? 0)
        // Failure messages carry the delivery parameters: if this ever fails on a
        // machine that isn't at hand, the first question is whether the feed really
        // was 1.4× realtime.
        let feed = "fed \(deliveryRate) B/s = 1.4x of \(Int(realtimeBytesPerSecond)) B/s realtime"
        #expect(videoRunway > 2.5, "video pipeline must accumulate surplus, got \(videoRunway)s (\(feed))")
        #expect(audioRunway > 2.5, "audio pipeline must accumulate surplus, got \(audioRunway)s (\(feed))")
        #expect(await session.state == .playing, "playback must continue while accumulating")
        await session.shutdown()
    }


    @Test("403 fails fast with a typed error, no hang", .timeLimit(.minutes(1)))
    func forbidden() async throws {
        let server = try TortureHTTPServer(mode: .forbidden)
        defer { server.stop() }

        let session = PlayerSession(configuration: makeConfiguration())
        let start = Date()
        do {
            _ = try await session.open(url: server.url)
            Issue.record("open should have thrown")
        } catch {
            #expect((error as? EngineError)?.code == .openFailed)
            #expect((error as? EngineError)?.httpFailure == .forbidden)
        }
        #expect(Date().timeIntervalSince(start) < 15, "403 must fail promptly")
        #expect(await session.state == .failed)
        await session.shutdown()
    }

    @Test(
        "HTTP refusals are classified by status, not message",
        .timeLimit(.minutes(1)),
        arguments: [
            (400, EngineError.HTTPFailure.badRequest),
            (401, .unauthorized),
            (404, .notFound),
            (410, .otherClientError),
            (429, .tooManyRequests),
            (503, .serverError),
            (509, .serverError),
        ]
    )
    func httpStatusMatrix(status: Int, expected: EngineError.HTTPFailure) async throws {
        let server = try TortureHTTPServer(mode: .status(status))
        defer { server.stop() }

        let session = PlayerSession(configuration: makeConfiguration())
        do {
            _ = try await session.open(url: server.url)
            Issue.record("open should have thrown for HTTP \(status)")
        } catch {
            let engineError = error as? EngineError
            #expect(engineError?.code == .openFailed)
            #expect(engineError?.httpFailure == expected, "HTTP \(status): \(String(describing: engineError))")
        }
        await session.shutdown()
    }

    @Test("a live HLS channel that ends fails the session instead of ending it", .timeLimit(.minutes(1)))
    func liveSourceEnded() async throws {
        // The first playlist has no end marker, so the channel opens live (no
        // duration); every refresh carries one. FFmpeg's HLS demuxer then
        // plays the remaining segments and reports a clean end of file.
        let directory = try Fixtures.url("hls-live/index.m3u8").deletingLastPathComponent()
        let server = try TortureHTTPServer(mode: .hlsLiveThenEnded(directory: directory))
        defer { server.stop() }

        let session = PlayerSession(configuration: makeConfiguration(stallThreshold: 30))
        let info = try await session.open(url: server.hlsURL)
        #expect(info.isLive, "a playlist without an end marker must open as live")

        let errors = LockedBox<[EngineError]>([])
        let eventTask = Task {
            for await event in session.events {
                if case .error(let error) = event { errors.set(errors.get() + [error]) }
            }
        }
        defer { eventTask.cancel() }

        await session.play()
        let failed = await eventually(timeout: 30) { await session.state == .failed }
        let finalState = await session.state
        #expect(failed, "a live source reaching its end must fail the session, state is \(finalState)")
        // The error event trails the state change; give the stream a moment.
        let reported = await eventually(timeout: 5) { errors.get().contains { $0.code == .sourceEnded } }
        #expect(reported, "errors: \(errors.get())")
        // Everything that arrived was played before the session gave up: the
        // live join starts three segments from the end, 6 s of media.
        #expect(await session.position > 4, "buffered media must play out before failing")
        await session.shutdown()
    }

    @Test("a live HTTP body that ends plays out what arrived, then fails", .timeLimit(.minutes(1)))
    func liveHTTPBodyEnded() async throws {
        // FFmpeg reports the end of a body of unknown length as an I/O error,
        // so this reaches the session as a demuxer failure. The whole 12 s
        // arrive in well under a second: the session must play them out
        // before it fails, and fail once, with the source's error.
        let server = try TortureHTTPServer(mode: .unbounded(file: Fixtures.url("wrap.ts")))
        defer { server.stop() }

        let session = PlayerSession(configuration: makeConfiguration(stallThreshold: 30))
        let errors = LockedBox<[EngineError]>([])
        let eventTask = Task {
            for await event in session.events {
                if case .error(let error) = event { errors.set(errors.get() + [error]) }
            }
        }
        defer { eventTask.cancel() }

        let info = try await session.open(url: server.url)
        #expect(info.isLive)
        await session.play()
        let lost = await eventually(timeout: 10) { await session.diagnostics.sourceLost }
        #expect(lost, "the session must notice the source is gone")
        let lostAt = Date()
        let settled = await eventually(timeout: 30) {
            let state = await session.state
            return state == .failed || state == .ended
        }
        #expect(settled)
        #expect(await session.state == .failed)
        let playedOut = Date().timeIntervalSince(lostAt)
        #expect(playedOut > 6, "the buffered seconds must play before the failure, failed after \(playedOut) s")
        // State changes before the event reaches the task; give it a moment.
        _ = await eventually(timeout: 2) { !errors.get().isEmpty }
        try? await Task.sleep(for: .milliseconds(300))
        let reported = errors.get()
        #expect(reported.map(\.code) == [.ioError], "one failure, the source's: \(reported)")
        await session.shutdown()
    }

    @Test("a live channel that reconnects plays the replayed seconds once", .timeLimit(.minutes(1)))
    func reconnectReplay() async throws {
        // The connection breaks at ~6 s; FFmpeg reconnects and the server
        // answers from ~3 s, as one answering from its buffer does.
        let file = try Fixtures.url("wrap.ts")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        let server = try TortureHTTPServer(mode: .reconnectReplay(file: file, dropAt: size / 2, resumeAt: size / 4))
        defer { server.stop() }

        var configuration = makeConfiguration(stallThreshold: 30)
        configuration.demuxer.enableReconnect = true
        let session = PlayerSession(configuration: configuration)
        _ = try await session.open(url: server.url)
        await session.play()

        let finished = await eventually(timeout: 40) { await session.state == .failed }
        #expect(finished, "the source ends after the replay, so the session fails once it played out")
        #expect(server.connectionCount == 2, "FFmpeg must have reconnected once")
        let diagnostics = await session.diagnostics
        #expect(diagnostics.replayedPackets > 100, "~3 s of the source arrive twice: \(diagnostics)")
        #expect(diagnostics.timelineSeams == 0, "a replay is not a seam: \(diagnostics)")
        await session.shutdown()
    }

    @Test("catch-up chunks that restart their timestamps play straight through", .timeLimit(.minutes(1)))
    func catchUpChunks() async throws {
        let session = PlayerSession(configuration: makeConfiguration(stallThreshold: 4))
        _ = try await session.open(url: try Fixtures.path("catchup.ts"))

        let stalled = LockedBox<Bool>(false)
        let eventTask = Task {
            for await event in session.events {
                if case .stalled = event { stalled.set(true) }
            }
        }
        defer { eventTask.cancel() }

        await session.play()
        // The seam sits 6 s in; a clock that froze or jumped there would never
        // get past it at real time.
        let crossed = await eventually(timeout: 20) { await session.position > 8 }
        let position = await session.position
        #expect(crossed, "playback must continue past the chunk seam, reached \(position)")
        #expect(!stalled.get(), "the seam must not stall playback")
        #expect(await session.diagnostics.timelineSeams >= 1)
        await session.shutdown()
    }

    @Test("an open the deadline interrupts fails instead of opening a dead source", .timeLimit(.minutes(1)))
    func openDeadlineWhileProbing() async throws {
        // Enough to open the container but not to finish probing, then
        // silence. The MPEG-TS probe returns what it has when the deadline
        // interrupts it; opening on that would leave a demuxer whose every
        // read is already cancelled.
        let server = try TortureHTTPServer(mode: .stallAfter(prefix: 400_000, file: Fixtures.url("wrap.ts")))
        defer { server.stop() }

        var configuration = makeConfiguration(ioTimeout: nil)
        configuration.demuxer.openTimeout = 3
        let session = PlayerSession(configuration: configuration)
        let started = Date()
        do {
            _ = try await session.open(url: server.url)
            Issue.record("open must fail once its deadline interrupted it")
        } catch let error as EngineError {
            #expect(error.code == .openFailed)
            #expect(error.message.contains("timed out"), "\(error)")
        }
        #expect(Date().timeIntervalSince(started) < 10, "the deadline bounds open")
        #expect(await session.state == .failed)
        await session.shutdown()
    }

    @Test("mid-stream stall fires the watchdog", .timeLimit(.minutes(2)))
    func midStreamStall() async throws {
        // ~1 MB of a ~2 MB TS: enough to open, probe, and start, then silence.
        let server = try TortureHTTPServer(mode: .stallAfter(prefix: 1_000_000, file: Fixtures.url("wrap.ts")))
        defer { server.stop() }

        // No I/O timeout: the read blocks silently — the exact failure mode the
        // watchdog exists for (a dead source that never errors).
        let session = PlayerSession(configuration: makeConfiguration(ioTimeout: nil, stallThreshold: 2))
        _ = try await session.open(url: server.url)

        let stalledFlag = LockedBox<Bool>(false)
        let eventTask = Task {
            for await event in session.events {
                if case .stalled = event { stalledFlag.set(true) }
            }
        }
        defer { eventTask.cancel() }

        await session.play()
        _ = await eventually { await session.state == .playing }

        let stalled = await eventually(timeout: 30) { stalledFlag.get() }
        #expect(stalled, "watchdog must report a stall — silence is not an acceptable failure mode")
        #expect(await session.lastStallReason == .source, "nothing arrives: the source stalled")

        // Teardown while the demuxer is blocked in network I/O must still be bounded.
        let teardownStart = Date()
        await session.shutdown()
        #expect(Date().timeIntervalSince(teardownStart) < 6, "teardown must interrupt blocked I/O")
    }

    @Test("mid-stream connection drop does not hang the session", .timeLimit(.minutes(2)))
    func midStreamDrop() async throws {
        let server = try TortureHTTPServer(mode: .dropAfter(prefix: 400_000, file: Fixtures.url("wrap.ts")))
        defer { server.stop() }

        let session = PlayerSession(configuration: makeConfiguration())
        _ = try await session.open(url: server.url)
        await session.play()
        _ = await eventually { await session.state == .playing }

        // After the drop the demuxer sees EOF/error; either way the session
        // must settle into a terminal-ish state rather than spinning.
        let settled = await eventually(timeout: 30) {
            let state = await session.state
            return state == .ended || state == .failed || state == .paused
        }
        let settledState = await session.state
        #expect(settled, "session must settle after a connection drop, state is \(settledState)")

        let teardownStart = Date()
        await session.shutdown()
        #expect(Date().timeIntervalSince(teardownStart) < 6)
    }

    @Test("seek/pause/rate storm never wedges the session", .timeLimit(.minutes(3)))
    func seekStorm() async throws {
        let session = PlayerSession(configuration: makeConfiguration())
        let info = try await session.open(url: try Fixtures.path("multitrack.mkv"))
        await session.play()
        _ = await eventually { await session.state == .playing }

        var generator = SplitMix64(seed: 0xDEADBEEF)
        let audioTracks = info.audioTracks.map(\.index)
        for _ in 0..<120 {
            switch generator.next() % 6 {
            case 0: await session.seek(to: Double(generator.next() % 8))
            case 1: await session.pause()
            case 2: await session.play()
            case 3: await session.setRate([0.5, 1.0, 1.5, 2.0][Int(generator.next() % 4)])
            case 4: if let track = audioTracks.randomElement(using: &generator) { await session.selectAudioTrack(track) }
            default: try? await Task.sleep(for: .milliseconds(Int(generator.next() % 40)))
            }
        }

        // The session must still respond to ordinary commands.
        await session.setRate(1.0)
        await session.play()
        await session.seek(to: 1.0)
        let alive = await eventually(timeout: 15) {
            let state = await session.state
            let position = await session.position
            return state == .playing && position > 0.9
        }
        let finalState = await session.state
        #expect(alive, "after the storm the session must still play (state \(finalState))")

        let teardownStart = Date()
        await session.shutdown()
        #expect(Date().timeIntervalSince(teardownStart) < 6, "storm must not break teardown")
    }
}

/// Deterministic RNG so storm failures reproduce.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
