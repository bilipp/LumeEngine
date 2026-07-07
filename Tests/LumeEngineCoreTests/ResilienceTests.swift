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
        try await Task.sleep(for: .milliseconds(700))
        #expect(await session.position > 0.2)
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
        }
        #expect(Date().timeIntervalSince(start) < 15, "403 must fail promptly")
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
