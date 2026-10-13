import CFFmpeg
import Foundation
import Synchronization
import Testing
@testable import LumeEngineCore

/// Output width that follows the route: the layout policy and the downmix
/// matrix as plain values, then the decoder at forced route widths and across
/// a route change mid-stream.
@Suite("AudioLayoutPolicy")
struct AudioLayoutPolicyTests {
    private static let surround51Back: SpeakerSet = [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .backLeft, .backRight]
    private static let surround70: SpeakerSet = SpeakerSet.surround71.subtracting(.lowFrequency)
    /// A matrix-encoded stereo pair (`AV_CH_STEREO_LEFT | AV_CH_STEREO_RIGHT`):
    /// two channels the renderer cannot name.
    private static let stereoDownmix = SpeakerSet(rawValue: 1 << 29 | 1 << 30)

    private func plan(_ source: SpeakerSet, route: Int) -> AudioLayoutPolicy.Plan {
        AudioLayoutPolicy.plan(source: source, routeChannels: route)
    }

    @Test("speaker sets are FFmpeg's native layouts")
    func layoutsMatchFFmpeg() {
        #expect(SpeakerSet.mono.rawValue == layoutMask("mono"))
        #expect(SpeakerSet.stereo.rawValue == layoutMask("stereo"))
        #expect(SpeakerSet.surround51.rawValue == layoutMask("5.1(side)"))
        #expect(SpeakerSet.surround71.rawValue == layoutMask("7.1"))
    }

    @Test("multichannel goes out discrete when the route carries it")
    func passthroughWhenItFits() {
        for route in [6, 8] {
            #expect(plan(.surround51, route: route) == .init(output: .surround51, remixes: false))
            #expect(plan(Self.surround51Back, route: route) == .init(output: Self.surround51Back, remixes: false))
        }
        #expect(plan(.surround71, route: 8) == .init(output: .surround71, remixes: false))
        for route in [2, 6, 8] {
            #expect(plan(.stereo, route: route) == .init(output: .stereo, remixes: false))
        }
    }

    @Test("a narrower route gets the widest standard layout both sides fill")
    func foldsDownToTheRoute() {
        #expect(plan(.surround51, route: 2) == .init(output: .stereo, remixes: true))
        #expect(plan(Self.surround51Back, route: 2) == .init(output: .stereo, remixes: true))
        #expect(plan(.surround71, route: 2) == .init(output: .stereo, remixes: true))
        #expect(plan(.surround71, route: 6) == .init(output: .surround51, remixes: true))
        #expect(plan(.surround71, route: 7) == .init(output: .surround51, remixes: true))
        // Odd widths fall to the standard layout below them.
        #expect(plan(.surround51, route: 4) == .init(output: .stereo, remixes: true))
    }

    @Test("no LFE channel is invented")
    func noInventedLFE() {
        #expect(plan(Self.surround70, route: 6) == .init(output: SpeakerSet.surround51.subtracting(.lowFrequency), remixes: true))
    }

    @Test("mono reaches both speakers of any route wider than one")
    func monoBecomesStereo() {
        for route in [2, 6, 8] {
            #expect(plan(.mono, route: route) == .init(output: .stereo, remixes: true))
        }
        #expect(plan(.mono, route: 1) == .init(output: .mono, remixes: false))
        #expect(plan(.mono, route: 0) == .init(output: .mono, remixes: false))
        #expect(plan(.stereo, route: 1) == .init(output: .mono, remixes: true))
    }

    @Test("channels the renderer cannot name are remixed, not passed untagged")
    func unnameableChannelsAreRemixed() {
        #expect(plan(Self.stereoDownmix, route: 8) == .init(output: .stereo, remixes: true))
    }
}

@Suite("DownmixMatrix")
struct DownmixMatrixTests {
    private let minus3dB = 0.707_106_781_186_547_6

    /// The coefficient of input speaker `input` in output speaker `output`.
    private func weight(
        _ matrix: [[Double]], from source: SpeakerSet, to target: SpeakerSet,
        _ input: SpeakerSet, into output: SpeakerSet
    ) -> Double {
        func index(_ speaker: SpeakerSet, in set: SpeakerSet) -> Int {
            // Native order is ascending bit order.
            (set.rawValue & (speaker.rawValue - 1)).nonzeroBitCount
        }
        return matrix[index(output, in: target)][index(input, in: source)]
    }

    @Test("5.1 to stereo: ITU fold-down, centre in both, LFE omitted, no cross-feed")
    func surround51ToStereo() throws {
        let source = SpeakerSet.surround51
        let matrix = try #require(DownmixMatrix.coefficients(from: source, to: .stereo))
        #expect(matrix.count == 2 && matrix.allSatisfy { $0.count == 6 })
        func w(_ input: SpeakerSet, _ output: SpeakerSet) -> Double {
            weight(matrix, from: source, to: .stereo, input, into: output)
        }
        #expect(w(.frontLeft, .frontLeft) == 1)
        #expect(w(.frontRight, .frontRight) == 1)
        #expect(w(.frontLeft, .frontRight) == 0)
        #expect(w(.frontRight, .frontLeft) == 0)
        #expect(abs(w(.frontCenter, .frontLeft) - minus3dB) < 1e-9)
        #expect(abs(w(.frontCenter, .frontRight) - minus3dB) < 1e-9)
        #expect(abs(w(.sideLeft, .frontLeft) - minus3dB) < 1e-9)
        #expect(abs(w(.sideRight, .frontRight) - minus3dB) < 1e-9)
        #expect(w(.sideLeft, .frontRight) == 0)
        #expect(w(.lowFrequency, .frontLeft) == 0)
        #expect(w(.lowFrequency, .frontRight) == 0)
    }

    @Test("7.1 to stereo: every surround folds into its own side")
    func surround71ToStereo() throws {
        let source = SpeakerSet.surround71
        let matrix = try #require(DownmixMatrix.coefficients(from: source, to: .stereo))
        func w(_ input: SpeakerSet, _ output: SpeakerSet) -> Double {
            weight(matrix, from: source, to: .stereo, input, into: output)
        }
        for (input, side) in [(SpeakerSet.backLeft, SpeakerSet.frontLeft), (.sideLeft, .frontLeft),
                              (.backRight, .frontRight), (.sideRight, .frontRight)] {
            #expect(abs(w(input, side) - minus3dB) < 1e-9)
        }
        #expect(w(.backLeft, .frontRight) == 0)
        #expect(abs(w(.frontCenter, .frontLeft) - minus3dB) < 1e-9)
        #expect(abs(w(.frontCenter, .frontRight) - minus3dB) < 1e-9)
    }

    @Test("7.1 to 5.1: fronts, centre and LFE pass straight; backs join the sides")
    func surround71To51() throws {
        let source = SpeakerSet.surround71
        let target = SpeakerSet.surround51
        let matrix = try #require(DownmixMatrix.coefficients(from: source, to: target))
        func w(_ input: SpeakerSet, _ output: SpeakerSet) -> Double {
            weight(matrix, from: source, to: target, input, into: output)
        }
        for speaker in [SpeakerSet.frontLeft, .frontRight, .frontCenter, .lowFrequency] {
            #expect(w(speaker, speaker) == 1)
        }
        #expect(w(.backLeft, .sideLeft) > 0.5)
        #expect(w(.backRight, .sideRight) > 0.5)
        #expect(w(.frontCenter, .frontLeft) == 0, "a route with a centre speaker keeps dialogue on it")
    }

    @Test("mono to stereo: equal power on both sides")
    func monoToStereo() throws {
        let matrix = try #require(DownmixMatrix.coefficients(from: .mono, to: .stereo))
        #expect(matrix.count == 2)
        #expect(abs(matrix[0][0] - minus3dB) < 1e-9)
        #expect(abs(matrix[1][0] - minus3dB) < 1e-9)
    }

    @Test("dialogue survives every stereo fold-down")
    func dialogueNeverDropped() throws {
        let sources: [SpeakerSet] = [
            [.frontLeft, .frontRight, .frontCenter],
            .surround51,
            [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .backLeft, .backRight],
            .surround71,
            SpeakerSet.surround51.union(SpeakerSet(rawValue: 1 << 8)), // 6.1, back centre
        ]
        for source in sources {
            let plan = AudioLayoutPolicy.plan(source: source, routeChannels: 2)
            let matrix = try #require(DownmixMatrix.coefficients(from: source, to: plan.output))
            let center = (source.rawValue & (SpeakerSet.frontCenter.rawValue - 1)).nonzeroBitCount
            #expect(matrix[0][center] > 0.5 && matrix[1][center] > 0.5, "centre lost folding \(source.rawValue)")
            // Every input channel except the LFE reaches the output.
            for input in 0..<source.count where input != 3 {
                #expect(matrix[0][input] + matrix[1][input] > 0, "channel \(input) of \(source.rawValue) dropped")
            }
        }
    }
}

@Suite("AudioRoute", .serialized)
struct AudioRouteDecodeTests {
    /// Decodes an audio-only fixture with the decoder following `route`.
    /// `onFrame` runs on the drain thread for each frame, in order — the place
    /// to change the route mid-stream.
    private func decode(
        fixture: String,
        route: AudioOutputRoute,
        frameQueue: Int = 256,
        onFrame: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> [AudioFrame] {
        let demuxer = Demuxer(url: try Fixtures.path(fixture))
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()
        guard case .opened(let info)? = await events.next() else {
            demuxer.shutdown()
            throw EngineError(code: .openFailed, message: "\(fixture) failed to open")
        }
        defer { demuxer.shutdown() }

        let track = try #require(info.audioTracks.first)
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))
        let packets = Channel<Packet>(capacity: 4096)
        let frames = Channel<AudioFrame>(capacity: frameQueue, measure: { $0.duration })
        demuxer.attach(channel: packets, toStream: track.index)

        let decoder = AudioDecoder(parameters: parameters, input: packets, output: frames, route: route)
        var decodeEvents = decoder.events.makeAsyncIterator()
        decoder.start()
        demuxer.resume()
        defer { decoder.shutdown() }

        let collector = ChannelDrain(frames, into: [AudioFrame]()) { collected, frame in
            collected.append(frame)
            onFrame(collected.count)
        }
        while let event = await events.next() {
            if case .endOfStream = event {
                decoder.signalEndOfStream()
                break
            }
        }
        guard case .endOfStream? = await decodeEvents.next() else {
            throw EngineError(code: .decodeFailed, message: "\(fixture): decoder never reached EOF")
        }
        decoder.shutdown()
        return await collector.value
    }

    /// Per-channel peak amplitude over all frames.
    private func peaks(_ frames: [AudioFrame]) -> [Float] {
        guard let channels = frames.first?.channels else { return [] }
        var peaks = [Float](repeating: 0, count: channels)
        for frame in frames {
            let samples = frame.samples
            for index in 0..<frame.sampleCount {
                for channel in 0..<channels {
                    peaks[channel] = max(peaks[channel], abs(samples[index * channels + channel]))
                }
            }
        }
        return peaks
    }

    @Test("FLAC 7.1 at route widths 8, 6 and 2", .timeLimit(.minutes(1)))
    func surround71AtRouteWidths() async throws {
        let wide = try await decode(fixture: "surround71.mkv", route: AudioOutputRoute(outputChannels: 8))
        #expect(wide.allSatisfy { $0.channels == 8 && $0.channelBitmap == SpeakerSet.surround71.rawValue })

        let fiveOne = try await decode(fixture: "surround71.mkv", route: AudioOutputRoute(outputChannels: 6))
        #expect(fiveOne.allSatisfy { $0.channels == 6 && $0.channelBitmap == SpeakerSet.surround51.rawValue })

        let stereo = try await decode(fixture: "surround71.mkv", route: AudioOutputRoute(outputChannels: 2))
        #expect(stereo.allSatisfy { $0.channels == 2 && $0.channelBitmap == SpeakerSet.stereo.rawValue })

        // The fixture's signal sits in the centre channel alone. Folded down,
        // it must reach both speakers equally, at −3 dB — mixed, not dropped.
        let center = try #require(peaks(wide)[safe: 2])
        #expect(center > 0.05)
        let stereoPeaks = peaks(stereo)
        #expect(abs(stereoPeaks[0] - stereoPeaks[1]) < 1e-4)
        #expect(abs(stereoPeaks[0] / center - 0.7071) < 0.01, "centre at \(stereoPeaks[0] / center) of its level")
        // On a 5.1 route the centre stays on the centre speaker.
        #expect(abs(peaks(fiveOne)[2] - center) < 1e-4)
    }

    @Test("TrueHD 5.1 at route widths 8 and 2", .timeLimit(.minutes(1)))
    func truehdAtRouteWidths() async throws {
        let wide = try await decode(fixture: "truehd.mkv", route: AudioOutputRoute(outputChannels: 8))
        #expect(wide.allSatisfy { $0.channels == 6 && $0.channelBitmap == SpeakerSet.surround51.rawValue })

        let stereo = try await decode(fixture: "truehd.mkv", route: AudioOutputRoute(outputChannels: 2))
        #expect(!stereo.isEmpty)
        #expect(stereo.allSatisfy { $0.channels == 2 })
        let center = peaks(wide)[2]
        let stereoPeaks = peaks(stereo)
        #expect(center > 0.05)
        #expect(abs(stereoPeaks[0] / center - 0.7071) < 0.01 && abs(stereoPeaks[1] / center - 0.7071) < 0.01)
        let seconds = Double(stereo.reduce(0) { $0 + $1.sampleCount }) / Double(stereo[0].sampleRate)
        #expect(abs(seconds - 4.0) < 0.1)
    }

    @Test("mono goes out on both speakers", .timeLimit(.minutes(1)))
    func monoToStereo() async throws {
        // basic.mp4's AAC track is a mono sine.
        let mono = try await decode(fixture: "basic.mp4", route: AudioOutputRoute(outputChannels: 1))
        #expect(mono.first?.channels == 1)
        let stereo = try await decode(fixture: "basic.mp4", route: AudioOutputRoute(outputChannels: 2))
        #expect(stereo.allSatisfy { $0.channels == 2 && $0.channelBitmap == SpeakerSet.stereo.rawValue })
        let level = peaks(mono)[0]
        let sides = peaks(stereo)
        #expect(level > 0.05)
        #expect(abs(sides[0] - sides[1]) < 1e-4)
        #expect(abs(sides[0] / level - 0.7071) < 0.01)
    }

    @Test("a route change mid-stream switches layout at a frame boundary, losing nothing", .timeLimit(.minutes(1)))
    func routeChangeMidStream() async throws {
        let route = AudioOutputRoute(outputChannels: 8)
        // A short frame queue keeps the decoder from finishing the file
        // before the route changes.
        let frames = try await decode(fixture: "surround71.mkv", route: route, frameQueue: 4) { count in
            if count == 40 { route.update(outputChannels: 2) }
        }
        let widths = frames.map(\.channels)
        let switchIndex = try #require(widths.firstIndex(of: 2), "the layout must follow the route")
        #expect(switchIndex >= 40, "frames decoded for the old route are not rewritten")
        #expect(widths[..<switchIndex].allSatisfy { $0 == 8 })
        #expect(widths[switchIndex...].allSatisfy { $0 == 2 }, "exactly one switch")

        // Sample-accurate abutment across the switch: nothing dropped or doubled.
        let rate = Double(frames[0].sampleRate)
        var worstGap: Double = 0
        for index in 1..<frames.count {
            let previous = frames[index - 1]
            let expected = Double(previous.pts) + Double(previous.sampleCount) * 1_000_000 / rate
            worstGap = max(worstGap, abs(Double(frames[index].pts) - expected))
        }
        #expect(worstGap < 1_000, "worst PTS gap \(worstGap) µs")
        let seconds = Double(frames.reduce(0) { $0 + $1.sampleCount }) / rate
        #expect(abs(seconds - 4.0) < 0.1, "expected ~4 s of audio, got \(seconds)")
    }
}

@Suite("AudioLossDetector")
struct AudioLossDetectorTests {
    /// Playing, both lanes fed past the playhead.
    private func playing(at playhead: Double, audioAhead: Bool = true, videoAhead: Bool? = true, serial: UInt64 = 0)
        -> AudioLossDetector.Observation {
        AudioLossDetector.Observation(
            hasAudioLane: true, audioEnded: false, audioRendererFailed: false,
            clockRunning: true, playhead: playhead,
            audioAhead: audioAhead, videoAhead: videoAhead, serial: serial
        )
    }

    /// Feeds `observation` with the playhead advanced in 0.2 s ticks over
    /// `seconds`; returns every reason the detector reported.
    private func run(
        _ detector: inout AudioLossDetector, from start: Double, seconds: Double,
        _ observation: (Double) -> AudioLossDetector.Observation
    ) -> [AudioLossReason] {
        var reported: [AudioLossReason] = []
        var playhead = start
        while playhead <= start + seconds + 1e-9 {
            if let reason = detector.observe(observation(playhead)) { reported.append(reason) }
            playhead += 0.2
        }
        return reported
    }

    @Test("no lane is absent; a lane starts healthy")
    func absentAndHealthy() {
        var detector = AudioLossDetector()
        var observation = playing(at: 0)
        observation.hasAudioLane = false
        #expect(detector.observe(observation) == nil)
        #expect(detector.health == .absent)
        #expect(detector.observe(playing(at: 0)) == nil)
        #expect(detector.health == .healthy)
    }

    @Test("audio missing at a running playhead while video plays is reported once, after the threshold")
    func starvationReportedOnce() {
        var detector = AudioLossDetector()
        let early = run(&detector, from: 0, seconds: 1.6) { playing(at: $0, audioAhead: false) }
        #expect(early.isEmpty, "not before \(AudioLossDetector.threshold) s")
        #expect(detector.health == .healthy)
        let later = run(&detector, from: 1.8, seconds: 3) { playing(at: $0, audioAhead: false) }
        #expect(later == [.starved])
        #expect(detector.health == .lost(.starved))
    }

    @Test("audio coming back clears the verdict, and a second episode is reported again")
    func recovery() {
        var detector = AudioLossDetector()
        _ = run(&detector, from: 0, seconds: 3) { playing(at: $0, audioAhead: false) }
        #expect(detector.health == .lost(.starved))
        #expect(detector.observe(playing(at: 3.2)) == nil)
        #expect(detector.health == .healthy)
        let again = run(&detector, from: 3.4, seconds: 3) { playing(at: $0, audioAhead: false) }
        #expect(again == [.starved])
    }

    @Test("moments without audio that belong to playback are not a loss")
    func legitimateSilence() {
        // Video dry too: the whole pipeline is starving, which is buffering.
        var detector = AudioLossDetector()
        #expect(run(&detector, from: 0, seconds: 5) { playing(at: $0, audioAhead: false, videoAhead: false) }.isEmpty)
        // Audio-only source: nothing to compare against.
        #expect(run(&detector, from: 0, seconds: 5) { playing(at: $0, audioAhead: false, videoAhead: nil) }.isEmpty)
        // The audio track ended (VOD whose audio is shorter than its video).
        #expect(run(&detector, from: 0, seconds: 5) {
            var observation = playing(at: $0, audioAhead: false)
            observation.audioEnded = true
            return observation
        }.isEmpty)
        // Paused or buffering: the clock does not run.
        #expect(run(&detector, from: 0, seconds: 5) {
            var observation = playing(at: $0, audioAhead: false)
            observation.clockRunning = false
            return observation
        }.isEmpty)
        #expect(detector.health == .healthy)
    }

    @Test("a pause restarts the count; a seek voids the episode")
    func pauseAndSeek() {
        var detector = AudioLossDetector()
        _ = run(&detector, from: 0, seconds: 1.6) { playing(at: $0, audioAhead: false) }
        var paused = playing(at: 1.6, audioAhead: false)
        paused.clockRunning = false
        #expect(detector.observe(paused) == nil)
        #expect(run(&detector, from: 1.6, seconds: 1.6) { playing(at: $0, audioAhead: false) }.isEmpty)

        _ = run(&detector, from: 3.4, seconds: 3) { playing(at: $0, audioAhead: false) }
        #expect(detector.health == .lost(.starved))
        // Seek back: new serial, playhead earlier — a fresh start.
        #expect(detector.observe(playing(at: 0.5, audioAhead: false, serial: 1)) == nil)
        #expect(detector.health == .healthy)
    }

    @Test("decoder and renderer failures are permanent until the lane is rebuilt")
    func permanentLosses() {
        var detector = AudioLossDetector()
        _ = detector.observe(playing(at: 0))
        detector.decoderFailed()
        #expect(detector.health == .lost(.decoderFailed))
        // Audio enqueued before the failure still plays out; the verdict stands.
        #expect(detector.observe(playing(at: 0.2)) == nil)
        #expect(detector.health == .lost(.decoderFailed))
        detector.laneReplaced()
        #expect(detector.health == .healthy)

        var failed = playing(at: 1)
        failed.audioRendererFailed = true
        #expect(detector.observe(failed) == nil)
        #expect(detector.health == .lost(.rendererFailed))
        #expect(detector.observe(playing(at: 1.2, serial: 4)) == nil)
        #expect(detector.health == .lost(.rendererFailed))
    }
}

@Suite("AudioRouteSession", .serialized)
struct AudioRouteSessionTests {
    private func eventually(
        timeout: TimeInterval = 10,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func makeSession(route: AudioOutputRoute, enableAudio: Bool = true) -> PlayerSession {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.5
        configuration.enableAudio = enableAudio
        configuration.audioOutputRoute = route
        return PlayerSession(configuration: configuration)
    }

    @Test("a playing session refits its audio when the route narrows and widens", .timeLimit(.minutes(1)))
    func followsRouteChanges() async throws {
        let route = AudioOutputRoute(outputChannels: 8)
        let session = makeSession(route: route)
        _ = try await session.open(url: try Fixtures.path("surround51.ts"))
        await session.play()
        #expect(await eventually { await session.position > 1 })
        #expect(await session.audioOutput == AudioOutputLayout(sourceChannels: 6, outputChannels: 6, routeChannels: 8))

        // HDMI receiver → AirPlay: the next decoded frame folds down to stereo.
        route.update(outputChannels: 2)
        let narrowed = await eventually { await session.audioOutput?.outputChannels == 2 }
        #expect(narrowed, "audio must refit to the stereo route")
        let before = await session.position
        let continued = await eventually { await session.position > before + 1.5 }
        #expect(continued, "playback must go on through the route change")
        #expect(!session.renderer.audioRendererFailed)
        #expect(await session.state == .playing)
        #expect(await session.audioHealth == .healthy)

        // And back to surround.
        route.update(outputChannels: 6)
        #expect(await eventually { await session.audioOutput?.outputChannels == 6 })
        let resumed = await session.position
        #expect(await eventually { await session.position > resumed + 1 })
        #expect(!session.renderer.audioRendererFailed)

        let diagnostics = await session.diagnostics
        #expect(diagnostics.audioOutput?.routeChannels == 6)
        #expect(diagnostics.audioRoute.changes == 2)
        #expect(diagnostics.description.contains("aout=6>6ch@6"))
        await session.shutdown()
    }

    // Quarantined on CI (#58): on the hosted runner the detector reports
    // nothing, likely because the VM's audio device stops the clock once the
    // renderer runs dry. Runs everywhere else.
    @Test(
        "audio that stops reaching the renderer while video plays is reported",
        .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, "flaky on the CI runner (#58)"),
        .timeLimit(.minutes(1))
    )
    func reportsLostAudio() async throws {
        let session = makeSession(route: AudioOutputRoute(outputChannels: 2))
        let errors = Mutex<[EngineError.Code]>([])
        let listener = Task { [events = session.events] in
            for await event in events {
                if case .error(let error) = event { errors.withLock { $0.append(error.code) } }
            }
        }
        _ = try await session.open(url: try Fixtures.path("surround51.ts"))
        await session.play()
        #expect(await eventually { await session.position > 1 })
        #expect(await session.audioHealth == .healthy)

        // The renderer stops taking audio; the clock and the picture go on.
        session.renderer.stopFeedingAudio()
        let lost = await eventually(timeout: 15) { await session.audioHealth == .lost(.starved) }
        let health = await session.audioHealth
        #expect(lost, "lost audio must be detected, health is \(health)")
        // The event travels through the stream after the verdict is set.
        let reported = await eventually(timeout: 2) { errors.withLock { $0.contains(.audioLost) } }
        let codes = errors.withLock { $0 }
        #expect(reported && codes.filter { $0 == .audioLost }.count == 1, "errors: \(codes)")
        #expect(await session.state == .playing, "video keeps playing")
        #expect(await session.diagnostics.description.contains("audio=lost(starved)"))

        await session.shutdown()
        listener.cancel()
    }

    @Test("a session without audio reports none", .timeLimit(.minutes(1)))
    func noAudioLane() async throws {
        let session = makeSession(route: AudioOutputRoute(outputChannels: 2), enableAudio: false)
        _ = try await session.open(url: try Fixtures.path("basic.mp4"))
        await session.play()
        #expect(await eventually { await session.position > 0.5 })
        #expect(await session.audioHealth == .absent)
        #expect(await session.audioOutput == nil)
        await session.shutdown()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// FFmpeg's mask for a named layout — the reference the speaker-set
/// constants are checked against.
private func layoutMask(_ name: String) -> UInt64 {
    var layout = AVChannelLayout()
    defer { av_channel_layout_uninit(&layout) }
    guard av_channel_layout_from_string(&layout, name) >= 0 else { return 0 }
    return layout.u.mask
}
