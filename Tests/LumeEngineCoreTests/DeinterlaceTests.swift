import CoreVideo
import Foundation
import Testing
@testable import LumeEngineCore

/// Deinterlacing against a real field-coded fixture. The failure this guards
/// against is the visible one: interlaced broadcast content (all European sport
/// on IPTV) shown as woven frames combs on every fast movement.
@Suite("Deinterlace", .serialized)
struct DeinterlaceTests {
    private struct Decoded: Sendable {
        var pts: [Int64]
        var durations: [Int64]
        var pixelFormats: Set<OSType>
        var zeroCopy: Set<Bool>
        /// Whether the decoder ever reported a filter engaged.
        var wasFiltering: Bool
        /// Whether the codec itself ran on VideoToolbox.
        var hardwareDecode: Bool

        var frameCount: Int { pts.count }
        /// Gaps between consecutive presentation times, engine µs.
        var intervals: [Int64] { zip(pts, pts.dropFirst()).map { $1 - $0 } }
    }

    /// Decodes a whole fixture with the given policy and reports what came out.
    private func decodeAll(
        fixture: String,
        deinterlacing: VideoDecoder.Deinterlacing
    ) async throws -> Decoded {
        let demuxer = Demuxer(url: try Fixtures.path(fixture))
        defer { demuxer.shutdown() }
        var demuxEvents = demuxer.events.makeAsyncIterator()
        demuxer.start()
        guard case .opened(let info)? = await demuxEvents.next() else {
            throw EngineError(code: .openFailed, message: "fixture \(fixture) failed to open")
        }

        let track = try #require(info.videoTracks.first)
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))

        let packets = Channel<Packet>(capacity: 64)
        let frames = Channel<VideoFrame>(capacity: 16, measure: { $0.duration })
        demuxer.attach(channel: packets, toStream: track.index)

        let decoder = VideoDecoder(
            parameters: parameters,
            input: packets,
            output: frames,
            deinterlacing: deinterlacing
        )
        var decodeEvents = decoder.events.makeAsyncIterator()
        decoder.start()
        demuxer.resume()

        // Drain on a background thread: the frame channel is bounded, so a
        // consumer that waits for EOF first would deadlock the decoder.
        // `isDeinterlacing` is sampled here rather than after EOF: the drain
        // releases the graph, so by the time the decoder reports end of stream
        // the flag is legitimately back to false.
        let collector = Task.detached {
            var pts: [Int64] = []
            var durations: [Int64] = []
            var pixelFormats: Set<OSType> = []
            var zeroCopy: Set<Bool> = []
            var filtering = false
            var hardware = false
            while let frame = frames.receive(timeout: 5) {
                pts.append(frame.pts)
                durations.append(frame.duration)
                pixelFormats.insert(CVPixelBufferGetPixelFormatType(frame.pixelBuffer))
                zeroCopy.insert(frame.isHardwareDecoded)
                filtering = filtering || decoder.isDeinterlacing
                hardware = hardware || decoder.isHardwareActive
            }
            return (pts, durations, pixelFormats, zeroCopy, filtering, hardware)
        }

        while let event = await demuxEvents.next() {
            if case .endOfStream = event {
                decoder.signalEndOfStream()
                break
            }
        }
        guard case .endOfStream? = await decodeEvents.next() else {
            decoder.shutdown()
            throw EngineError(code: .decodeFailed, message: "decoder never reached EOF")
        }
        decoder.shutdown()

        let (pts, durations, pixelFormats, zeroCopy, filtering, hardware) = await collector.value
        return Decoded(
            pts: pts,
            durations: durations,
            pixelFormats: pixelFormats,
            zeroCopy: zeroCopy,
            wasFiltering: filtering,
            hardwareDecode: hardware
        )
    }

    @Test("off: interlaced content passes through untouched", .timeLimit(.minutes(1)))
    func disabled() async throws {
        let result = try await decodeAll(fixture: "interlaced.ts", deinterlacing: .off)

        // 4 s of 25 interlaced frames per second.
        #expect(result.frameCount >= 95 && result.frameCount <= 105, "got \(result.frameCount)")
        #expect(!result.wasFiltering)
        // ~40 ms apart: one frame per field pair.
        let median = result.intervals.sorted()[result.intervals.count / 2]
        #expect(median >= 39_000 && median <= 41_000, "expected ~40 ms spacing, got \(median) µs")
    }

    @Test("auto + field rate: 25i becomes 50p", .timeLimit(.minutes(1)))
    func fieldRate() async throws {
        let plain = try await decodeAll(fixture: "interlaced.ts", deinterlacing: .off)
        let result = try await decodeAll(
            fixture: "interlaced.ts",
            deinterlacing: VideoDecoder.Deinterlacing(mode: .auto, rate: .field)
        )

        #expect(result.wasFiltering, "the fixture is flagged interlaced; the filter must engage")
        // One frame per field. The EOF flush recovers the field the filter
        // holds back, so nothing but rounding separates this from exactly 2×.
        #expect(
            result.frameCount >= 2 * plain.frameCount - 2,
            "expected ~\(2 * plain.frameCount) frames, got \(result.frameCount)"
        )

        // The whole point of the rescale through the sink's time base: a
        // field-doubling filter halves it, so raw filter PTS are in half-µs.
        let intervals = result.intervals
        #expect(intervals.allSatisfy { $0 > 0 }, "output PTS must be strictly monotonic")
        let median = intervals.sorted()[intervals.count / 2]
        #expect(median >= 19_000 && median <= 21_000, "expected ~20 ms spacing, got \(median) µs")

        // Durations must halve too, or the frame channel's PTS accounting (and
        // the renderer's sample durations) double-count every field.
        let medianDuration = result.durations.sorted()[result.durations.count / 2]
        #expect(medianDuration >= 19_000 && medianDuration <= 21_000, "got \(medianDuration) µs")

        // Filtered frames are CPU-written, whatever decoded them.
        #expect(result.zeroCopy == [false])
        #expect(result.pixelFormats.isSubset(of: [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]), "unexpected pixel formats: \(result.pixelFormats)")
    }

    @Test("auto + frame rate: 25i becomes 25p", .timeLimit(.minutes(1)))
    func frameRate() async throws {
        let plain = try await decodeAll(fixture: "interlaced.ts", deinterlacing: .off)
        let result = try await decodeAll(
            fixture: "interlaced.ts",
            deinterlacing: VideoDecoder.Deinterlacing(mode: .auto, rate: .frame)
        )

        #expect(result.wasFiltering)
        #expect(
            abs(result.frameCount - plain.frameCount) <= 2,
            "frame rate must not change: \(result.frameCount) vs \(plain.frameCount)"
        )
        let median = result.intervals.sorted()[result.intervals.count / 2]
        #expect(median >= 39_000 && median <= 41_000, "expected ~40 ms spacing, got \(median) µs")
    }

    @Test("auto: progressive content never leaves the zero-copy path", .timeLimit(.minutes(1)))
    func progressiveUntouched() async throws {
        let plain = try await decodeAll(fixture: "basic.mp4", deinterlacing: .off)
        let result = try await decodeAll(
            fixture: "basic.mp4",
            deinterlacing: VideoDecoder.Deinterlacing(mode: .auto, rate: .field)
        )

        #expect(!result.wasFiltering, "no frame is flagged interlaced; no graph may be built")
        #expect(result.frameCount == plain.frameCount)
        // Same provenance as with deinterlacing off — auto mode costs nothing
        // on progressive streams, including the zero-copy hardware surface.
        #expect(result.zeroCopy == plain.zeroCopy)
    }

    @Test("always: filters a stream that flags nothing", .timeLimit(.minutes(1)))
    func forced() async throws {
        let plain = try await decodeAll(fixture: "basic.mp4", deinterlacing: .off)
        let result = try await decodeAll(
            fixture: "basic.mp4",
            deinterlacing: VideoDecoder.Deinterlacing(mode: .always, rate: .field)
        )

        #expect(result.wasFiltering, "always must not consult the interlaced flag")
        #expect(
            result.frameCount >= 2 * plain.frameCount - 2,
            "expected ~\(2 * plain.frameCount) frames, got \(result.frameCount)"
        )
        #expect(result.intervals.allSatisfy { $0 > 0 }, "output PTS must be strictly monotonic")

        // The design claim, on a fixture that decodes on VideoToolbox here:
        // deinterlacing downloads hardware frames, it does not give up the
        // hardware decoder. Written as a comparison so a host without
        // VideoToolbox still asserts something meaningful.
        #expect(
            result.hardwareDecode == plain.hardwareDecode,
            "deinterlacing must not force the codec back to software"
        )
        #expect(result.zeroCopy == [false], "filtered frames are CPU-written by definition")
    }
}
