import CoreVideo
import Foundation
import Testing
@testable import LumeEngineCore

/// Coverage for the stream-open diagnostics added for issue #207 round 1.
///
/// These exist to protect one property above all: the readouts fire **once per
/// stream open** and on genuine format changes only. A regression that moves
/// them onto the per-frame path costs 4K playback and shows up nowhere else.
@Suite("Stream-open diagnostics", .serialized)
struct StreamOpenDiagnosticsTests {
    // MARK: Colour readout cadence

    @Test("video: the colour readout fires once for a whole stream", .timeLimit(.minutes(1)))
    func colorReadoutIsOncePerStream() async throws {
        let demuxer = Demuxer(url: try Fixtures.path("basic.mp4"))
        defer { _ = demuxer.shutdown() }
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()
        guard case .opened(let info)? = await events.next() else {
            Issue.record("fixture failed to open")
            return
        }

        let track = try #require(info.videoTracks.first)
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))
        let packets = Channel<Packet>(capacity: 64)
        let frames = Channel<VideoFrame>(capacity: 16)
        demuxer.attach(channel: packets, toStream: track.index)

        // Deinterlacing off: `basic.mp4` is progressive, so the graph would
        // never engage anyway, but pinning it keeps the assertion about the
        // cadence rather than about which path won.
        let decoder = VideoDecoder(
            parameters: parameters, input: packets, output: frames, deinterlacing: .off
        )
        decoder.start()
        demuxer.resume()

        var count = 0
        while frames.receive(timeout: 5) != nil {
            count += 1
            if count == 120 { break }
        }
        #expect(count == 120)
        // 120 frames from one unchanging stream is exactly one line.
        #expect(
            decoder.colorDiagnosticsCount == 1,
            "expected one colour readout for the stream, got \(decoder.colorDiagnosticsCount)"
        )

        decoder.shutdown()
    }

    @Test(
        "video: the deinterlaced path logs once, not once per field",
        .timeLimit(.minutes(1))
    )
    func colorReadoutIsOncePerStreamWhileDeinterlacing() async throws {
        // The path that matters most for the cadence invariant: deinterlacing
        // is on by default and, in `.field` rate, delivers two frames per
        // decoded input. A per-frame readout here would cost 4K playback and
        // the fixture matrix would never notice.
        let demuxer = Demuxer(url: try Fixtures.path("interlaced.ts"))
        defer { demuxer.shutdown() }
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()
        guard case .opened(let info)? = await events.next() else {
            Issue.record("fixture failed to open")
            return
        }

        let track = try #require(info.videoTracks.first)
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))
        let packets = Channel<Packet>(capacity: 64)
        let frames = Channel<VideoFrame>(capacity: 16)
        demuxer.attach(channel: packets, toStream: track.index)

        let decoder = VideoDecoder(
            parameters: parameters,
            input: packets,
            output: frames,
            deinterlacing: VideoDecoder.Deinterlacing(mode: .always, rate: .field)
        )
        decoder.start()
        demuxer.resume()

        var count = 0
        while frames.receive(timeout: 5) != nil {
            count += 1
            if count == 120 { break }
        }
        #expect(count == 120)
        // One line for the stream. A second is legitimate only if the *format*
        // changed — the fixture's does not — so anything above 1 is a
        // regression onto the per-frame path.
        #expect(
            decoder.colorDiagnosticsCount == 1,
            "expected one colour readout across 120 filtered frames, got \(decoder.colorDiagnosticsCount)"
        )

        decoder.shutdown()
    }

    @Test("video: nothing is logged before the first frame is delivered")
    func colorReadoutIsNotEmittedAtConstruction() async throws {
        let demuxer = Demuxer(url: try Fixtures.path("basic.mp4"))
        defer { _ = demuxer.shutdown() }
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()
        guard case .opened(let info)? = await events.next() else {
            Issue.record("fixture failed to open")
            return
        }
        let track = try #require(info.videoTracks.first)
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))

        let decoder = VideoDecoder(
            parameters: parameters,
            input: Channel<Packet>(capacity: 8),
            output: Channel<VideoFrame>(capacity: 8)
        )
        #expect(decoder.colorDiagnosticsCount == 0)
    }

    // MARK: HDR signalling reaches the readout

    @Test("an HDR10 stream reaches the colour readout as a 10-bit buffer")
    func hdrSignallingIsVisible() async throws {
        // The CoreVideo half of the readout, over a real 10-bit HDR stream
        // rather than only the 8-bit SDR fixtures. The source-signalling half
        // — what `logStreamOpen` prints — is asserted in
        // `TrackDolbyDetectionTests`; this one owns the decode side and the
        // once-per-stream cadence.
        let demuxer = Demuxer(url: try Fixtures.path("hdr10.mp4"))
        defer { demuxer.shutdown() }
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()
        guard case .opened(let info)? = await events.next() else {
            Issue.record("fixture failed to open")
            return
        }

        let track = try #require(info.videoTracks.first)
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))
        let packets = Channel<Packet>(capacity: 64)
        let frames = Channel<VideoFrame>(capacity: 16)
        demuxer.attach(channel: packets, toStream: track.index)
        let decoder = VideoDecoder(
            parameters: parameters, input: packets, output: frames, deinterlacing: .off
        )
        decoder.start()
        demuxer.resume()

        let frame = try #require(frames.receive(timeout: 10), "no frame decoded from hdr10.mp4")
        // 10-bit decode must not have been quietly narrowed to 8-bit on the way
        // to CoreVideo — that alone would wash the picture out.
        let format = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        #expect(
            format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            "expected a 10-bit pixel buffer, got \(VideoDecoder.fourCC(format))"
        )
        #expect(decoder.colorDiagnosticsCount == 1)

        decoder.shutdown()
    }

    // MARK: Formatting helpers

    @Test("pixel-format types print as four-character codes")
    func fourCCFormatting() {
        #expect(VideoDecoder.fourCC(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) == "'420v'")
        #expect(VideoDecoder.fourCC(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) == "'x420'")
        // Non-printable types (the raw-number formats) keep their number.
        #expect(VideoDecoder.fourCC(OSType(24)) == "24")
    }

    @Test("Dolby Vision renders in profile.compatibility notation")
    func dolbyVisionDescription() {
        #expect(PlayerSession.describe(nil) == "none")

        let profile81 = TrackInfo.DolbyVision(
            profile: 8, level: 9, blCompatibilityID: 1, hasRPU: true, hasBaseLayer: true
        )
        #expect(PlayerSession.describe(profile81) == "P8.1/L9 bl=yes rpu=yes")

        // Profile 5 has no cross-compatible base layer — the reason it is
        // documented as a limitation rather than chased (PLAN.md §7).
        let profile5 = TrackInfo.DolbyVision(
            profile: 5, level: 6, blCompatibilityID: 0, hasRPU: true, hasBaseLayer: true
        )
        #expect(PlayerSession.describe(profile5) == "P5.0/L6 bl=yes rpu=yes")
    }

    // MARK: Heartbeat line

    @Test("the heartbeat line carries Dolby facts only when the source has them")
    func diagnosticsDescription() {
        func diagnostics(
            dolbyVision: TrackInfo.DolbyVision?,
            objectAudio: Bool,
            layout: String?
        ) -> PlayerSession.Diagnostics {
            PlayerSession.Diagnostics(
                state: "playing",
                playheadSeconds: 1,
                videoQueue: nil,
                audioQueue: nil,
                videoPacketQueue: nil,
                audioPacketQueue: nil,
                videoLeadSeconds: 0,
                audioLeadSeconds: 0,
                videoFirstSeconds: -1,
                audioFirstSeconds: -1,
                rendererHealth: (0, 0, nil, nil),
                demuxAtEOF: false,
                deliveredBytes: 0,
                dolbyVision: dolbyVision,
                audioProfile: nil,
                audioIsObjectAudio: objectAudio,
                audioChannelLayoutName: layout
            )
        }

        let plain = diagnostics(dolbyVision: nil, objectAudio: false, layout: nil).description
        #expect(!plain.contains("dv="))
        #expect(!plain.contains("objectAudio="))
        #expect(!plain.contains("alayout="))

        let dolby = diagnostics(
            dolbyVision: TrackInfo.DolbyVision(
                profile: 8, level: 9, blCompatibilityID: 1, hasRPU: true, hasBaseLayer: true
            ),
            objectAudio: true,
            layout: "5.1(side)"
        ).description
        #expect(dolby.contains("dv=P8.1/L9 bl=yes rpu=yes"))
        #expect(dolby.contains("objectAudio=yes"))
        #expect(dolby.contains("alayout=5.1(side)"))
    }
}
