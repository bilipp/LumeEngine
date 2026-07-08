import CoreMedia
import Foundation
import Testing
@testable import LumeEngineCore

/// End-to-end integrity checks on the decoded PCM itself: a dropped, duplicated
/// or misordered chunk anywhere in decode → swresample → AudioFrame is an
/// audible scratch, so assert sample-level continuity on a known signal.
@Suite("AudioPipeline", .serialized)
struct AudioPipelineTests {
    /// Decodes an audio-only sine fixture end to end and returns the frames in order.
    private func decode(fixture: String, maxOutputChannels: Int = 8) async throws -> [AudioFrame] {
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

        let packets = Channel<Packet>(capacity: 256)
        let frames = Channel<AudioFrame>(capacity: 256, measure: { $0.duration })
        demuxer.attach(channel: packets, toStream: track.index)

        let decoder = AudioDecoder(
            parameters: parameters, input: packets, output: frames,
            maxOutputChannels: maxOutputChannels
        )
        decoder.start()
        demuxer.resume()
        defer { decoder.shutdown() }

        var collected: [AudioFrame] = []
        while let frame = frames.receive(timeout: 5) {
            collected.append(frame)
        }
        return collected
    }

    private func decodeSurround(maxOutputChannels: Int = 8) async throws -> [AudioFrame] {
        try await decode(fixture: "surround71.mkv", maxOutputChannels: maxOutputChannels)
    }

    @Test("7.1 decode: PCM is sample-continuous in every channel", .timeLimit(.minutes(1)))
    func pcmContinuity() async throws {
        let frames = try await decodeSurround()
        #expect(!frames.isEmpty)
        let channels = try #require(frames.first?.channels)
        #expect(channels == 8)
        let rate = try #require(frames.first?.sampleRate)

        // Concatenate per-channel and look for step discontinuities. A 440 Hz
        // sine at rate R moves at most 2π·440/R per sample (~0.058 at 48 kHz),
        // so a jump of 3× that bound is a glitch, not signal.
        var perChannel: [[Float]] = Array(repeating: [], count: channels)
        for frame in frames {
            let samples = frame.samples
            for index in 0..<frame.sampleCount {
                for channel in 0..<channels {
                    perChannel[channel].append(samples[index * channels + channel])
                }
            }
        }
        let maxStep = Float(3.0 * 2.0 * Double.pi * 440.0 / Double(rate))
        for (channel, signal) in perChannel.enumerated() {
            let amplitude = signal.map(abs).max() ?? 0
            guard amplitude > 0.01 else { continue } // silent channel: nothing to check
            var worst: Float = 0
            for index in 1..<signal.count {
                worst = max(worst, abs(signal[index] - signal[index - 1]))
            }
            #expect(
                worst <= maxStep * amplitude,
                "channel \(channel): sample step \(worst) exceeds sine slope bound \(maxStep * amplitude)"
            )
        }
    }

    @Test("7.1 downmixed to a stereo route stays clean and audible", .timeLimit(.minutes(1)))
    func stereoDownmix() async throws {
        let frames = try await decodeSurround(maxOutputChannels: 2)
        let first = try #require(frames.first)
        #expect(first.channels == 2)
        #expect(first.channelBitmap == 0x3) // FL FR

        // The center-channel sine must survive the downmix into both outputs,
        // continuously (no glitch steps), without clipping.
        var left: [Float] = []
        for frame in frames {
            let samples = frame.samples
            for index in 0..<frame.sampleCount {
                left.append(samples[index * 2])
            }
        }
        let rate = try #require(frames.first?.sampleRate)
        let amplitude = left.map(abs).max() ?? 0
        // Mono sine → 7.1 upmix → stereo downmix through normalized matrices
        // lands well below unity; it just must be audible and unclipped.
        #expect(amplitude > 0.05 && amplitude <= 1.0, "downmix amplitude \(amplitude)")
        let maxStep = Float(3.0 * 2.0 * Double.pi * 440.0 / Double(rate)) * amplitude
        for index in 1..<left.count {
            if abs(left[index] - left[index - 1]) > maxStep {
                Issue.record("downmix glitch at sample \(index)")
                break
            }
        }
    }

    @Test("7.1 decode: frame PTS abut sample-accurately", .timeLimit(.minutes(1)))
    func ptsAbutment() async throws {
        let frames = try await decodeSurround()
        #expect(frames.count > 2)
        let rate = try #require(frames.first?.sampleRate)

        var worstGap: Double = 0
        for index in 1..<frames.count {
            let previous = frames[index - 1]
            let expected = Double(previous.pts) + Double(previous.sampleCount) * 1_000_000.0 / Double(rate)
            let gap = abs(Double(frames[index].pts) - expected)
            worstGap = max(worstGap, gap)
        }
        // Container timestamp rounding is fine (< 1 ms); anything larger means
        // the renderer sees gaps/overlaps between buffers.
        #expect(worstGap < 1_000, "worst PTS gap \(worstGap) µs between consecutive audio frames")
    }

    @Test("audio timeline: buffers are sample-contiguous despite container PTS jitter", .timeLimit(.minutes(1)))
    func timelineContiguity() async throws {
        let frames = try await decodeSurround()
        #expect(frames.count > 2)

        var timeline = AudioTimeline()
        var expectedNext: CMTime?
        for frame in frames {
            let pts = timeline.presentationTime(for: frame)
            if let expectedNext {
                // Exactly contiguous: no µs rounding, no ms container jitter.
                #expect(pts == expectedNext, "buffer at \(frame.pts) µs not contiguous")
            }
            expectedNext = CMTimeAdd(pts, CMTime(value: CMTimeValue(frame.sampleCount), timescale: pts.timescale))
            // The regenerated time never drifts far from the container PTS.
            let deviation = abs(pts.convertScale(1_000_000, method: .default).value - frame.pts)
            #expect(deviation < 40_000, "regenerated PTS drifted \(deviation) µs from container PTS")
        }
    }

    @Test("TrueHD access units coalesce into schedulable frames, PCM intact", .timeLimit(.minutes(1)))
    func truehdCoalescing() async throws {
        // TrueHD decodes to 40-sample frames (0.83 ms at 48 kHz). Uncoalesced,
        // duration-budgeted frame queues hold ~40 ms of audio and playback
        // oscillates between buffering and starvation (~1 s crackle cycle).
        let frames = try await decode(fixture: "truehd.mkv")
        #expect(!frames.isEmpty)
        let rate = try #require(frames.first?.sampleRate)
        let channels = try #require(frames.first?.channels)
        #expect(channels == 6)

        // Every frame except the EOF tail must meet the coalescing floor (20 ms).
        let floor = Int(0.020 * Double(rate))
        for frame in frames.dropLast() {
            #expect(
                frame.sampleCount >= floor,
                "frame at \(frame.pts) µs is \(frame.sampleCount) samples — below the coalescing floor \(floor)"
            )
        }

        // Nothing lost or duplicated by coalescing: full duration survives...
        let totalSeconds = Double(frames.reduce(0) { $0 + $1.sampleCount }) / Double(rate)
        #expect(abs(totalSeconds - 4.0) < 0.1, "expected ~4 s of audio, got \(totalSeconds)")

        // ...and the sine stays continuous across every coalesced boundary
        // (an offset-write bug in the accumulator would step here).
        let maxStep = Float(3.0 * 2.0 * Double.pi * 440.0 / Double(rate))
        var perChannel: [[Float]] = Array(repeating: [], count: channels)
        for frame in frames {
            let samples = frame.samples
            for index in 0..<frame.sampleCount {
                for channel in 0..<channels {
                    perChannel[channel].append(samples[index * channels + channel])
                }
            }
        }
        for (channel, signal) in perChannel.enumerated() {
            let amplitude = signal.map(abs).max() ?? 0
            guard amplitude > 0.01 else { continue }
            var worst: Float = 0
            for index in 1..<signal.count {
                worst = max(worst, abs(signal[index] - signal[index - 1]))
            }
            #expect(
                worst <= maxStep * amplitude,
                "channel \(channel): sample step \(worst) exceeds sine slope bound \(maxStep * amplitude)"
            )
        }
    }

    @Test("audio timeline: seek (new serial) and stream gaps re-anchor")
    func timelineReanchoring() throws {
        // Hand-built frames: 1024 samples @ 48 kHz, container PTS quantized to
        // whole milliseconds the way MKV stores them.
        func stubFrame(pts: Int64, serial: UInt64) throws -> AudioFrame {
            try #require(AudioFrame.silence(
                pts: pts, serial: serial, sampleRate: 48_000, channels: 2, sampleCount: 1_024
            ))
        }

        var timeline = AudioTimeline()
        let first = timeline.presentationTime(for: try stubFrame(pts: 0, serial: 0))
        #expect(first == CMTime(value: 0, timescale: 48_000))

        // 1024 samples = 21333.3 µs; container says 21000 (ms floor). Absorbed.
        let second = timeline.presentationTime(for: try stubFrame(pts: 21_000, serial: 0))
        #expect(second == CMTime(value: 1_024, timescale: 48_000))

        // Genuine gap (> 40 ms): re-anchor at the container PTS.
        let afterGap = timeline.presentationTime(for: try stubFrame(pts: 500_000, serial: 0))
        #expect(afterGap == CMTime(value: 24_000, timescale: 48_000)) // 0.5 s × 48 kHz

        // New serial after a seek flush: re-anchor even if the PTS is close.
        let afterSeek = timeline.presentationTime(for: try stubFrame(pts: 521_000, serial: 1))
        #expect(afterSeek == CMTime(value: 25_008, timescale: 48_000)) // 0.521 s × 48 kHz
    }
}
