import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import LumeEngineCore

/// Colour tagging for CPU-produced pixel buffers (issue #207, round 2).
///
/// Two things are under test and they pull in opposite directions:
///
/// 1. A stream that *declares* its colour must reach CoreVideo with that
///    colour attached — otherwise HDR10/HLG (and Dolby Vision profile 8.1,
///    whose base layer is HDR10) renders washed out on every path the CPU
///    touched, which includes the deinterlacer.
/// 2. A stream that declares **nothing** must reach CoreVideo with nothing
///    attached. `AVCOL_*_UNSPECIFIED` is what SD and IPTV emit constantly, and
///    a guessed default there would colour-shift ordinary channels for every
///    user — a far worse regression than the bug being fixed.
///
/// The VideoToolbox zero-copy path is deliberately not asserted on: it was
/// measured correct on real hardware and the engine does not touch it.
@Suite("Colour tagging", .serialized)
struct ColorTaggingTests {
    // MARK: The AVCOL_* → CoreVideo table

    /// The whole domain, not just the interesting values: anything the table
    /// does not name explicitly must come back `nil`, which is the property
    /// that keeps a future code point from silently acquiring a guess.
    private static let domain = UInt32(0)...UInt32(32)

    @Test("primaries: every mapped code point, and nothing else")
    func primariesTable() {
        let expected: [UInt32: CFString] = [
            1: kCVImageBufferColorPrimaries_ITU_R_709_2,   // AVCOL_PRI_BT709
            5: kCVImageBufferColorPrimaries_EBU_3213,      // AVCOL_PRI_BT470BG
            6: kCVImageBufferColorPrimaries_SMPTE_C,       // AVCOL_PRI_SMPTE170M
            7: kCVImageBufferColorPrimaries_SMPTE_C,       // AVCOL_PRI_SMPTE240M
            9: kCVImageBufferColorPrimaries_ITU_R_2020,    // AVCOL_PRI_BT2020
            11: kCVImageBufferColorPrimaries_DCI_P3,       // AVCOL_PRI_SMPTE431
            12: kCVImageBufferColorPrimaries_P3_D65,       // AVCOL_PRI_SMPTE432
        ]
        for raw in Self.domain {
            #expect(
                CoreVideoColor.primaries(raw) == expected[raw],
                "primaries(\(raw)) mapped to \(String(describing: CoreVideoColor.primaries(raw)))"
            )
        }
    }

    @Test("transfer function: every mapped code point, and nothing else")
    func transferTable() {
        let expected: [UInt32: CFString] = [
            1: kCVImageBufferTransferFunction_ITU_R_709_2,      // AVCOL_TRC_BT709
            6: kCVImageBufferTransferFunction_ITU_R_709_2,      // AVCOL_TRC_SMPTE170M
            7: kCVImageBufferTransferFunction_SMPTE_240M_1995,  // AVCOL_TRC_SMPTE240M
            8: kCVImageBufferTransferFunction_Linear,           // AVCOL_TRC_LINEAR
            12: kCVImageBufferTransferFunction_ITU_R_709_2,     // AVCOL_TRC_BT1361_ECG
            13: kCVImageBufferTransferFunction_sRGB,            // AVCOL_TRC_IEC61966_2_1
            14: kCVImageBufferTransferFunction_ITU_R_2020,      // AVCOL_TRC_BT2020_10
            15: kCVImageBufferTransferFunction_ITU_R_2020,      // AVCOL_TRC_BT2020_12
            16: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, // AVCOL_TRC_SMPTE2084
            17: kCVImageBufferTransferFunction_SMPTE_ST_428_1,  // AVCOL_TRC_SMPTE428
            18: kCVImageBufferTransferFunction_ITU_R_2100_HLG,  // AVCOL_TRC_ARIB_STD_B67
        ]
        for raw in Self.domain {
            #expect(
                CoreVideoColor.transferFunction(raw) == expected[raw],
                "transfer(\(raw)) mapped to \(String(describing: CoreVideoColor.transferFunction(raw)))"
            )
        }
    }

    @Test("YCbCr matrix: every mapped code point, and nothing else")
    func matrixTable() {
        let expected: [UInt32: CFString] = [
            1: kCVImageBufferYCbCrMatrix_ITU_R_709_2,      // AVCOL_SPC_BT709
            5: kCVImageBufferYCbCrMatrix_ITU_R_601_4,      // AVCOL_SPC_BT470BG
            6: kCVImageBufferYCbCrMatrix_ITU_R_601_4,      // AVCOL_SPC_SMPTE170M
            7: kCVImageBufferYCbCrMatrix_SMPTE_240M_1995,  // AVCOL_SPC_SMPTE240M
            9: kCVImageBufferYCbCrMatrix_ITU_R_2020,       // AVCOL_SPC_BT2020_NCL
        ]
        for raw in Self.domain {
            #expect(
                CoreVideoColor.yCbCrMatrix(raw) == expected[raw],
                "matrix(\(raw)) mapped to \(String(describing: CoreVideoColor.yCbCrMatrix(raw)))"
            )
        }
    }

    /// Called out on its own because it is the rule the rest of the feature
    /// hangs off: unspecified is not "unknown, pick something sensible", it is
    /// "the source said nothing, so say nothing".
    @Test("AVCOL_*_UNSPECIFIED maps to no attachment at all")
    func unspecifiedMapsToNothing() {
        let unspecified: UInt32 = 2
        #expect(CoreVideoColor.primaries(unspecified) == nil)
        #expect(CoreVideoColor.transferFunction(unspecified) == nil)
        #expect(CoreVideoColor.yCbCrMatrix(unspecified) == nil)
    }

    /// BT.2020 constant luminance is a different matrix from the one
    /// CoreVideo's `ITU_R_2020` constant names, so it stays unmapped rather
    /// than borrowing the NCL tag.
    @Test("BT.2020 constant luminance is not mapped onto the non-CL constant")
    func constantLuminanceIsNotGuessed() {
        #expect(CoreVideoColor.yCbCrMatrix(10) == nil, "AVCOL_SPC_BT2020_CL")
        #expect(CoreVideoColor.yCbCrMatrix(9) == kCVImageBufferYCbCrMatrix_ITU_R_2020, "AVCOL_SPC_BT2020_NCL")
    }

    // MARK: Buffers the CPU produced

    @Test("software path: an HDR10 stream reaches CoreVideo fully tagged", .timeLimit(.minutes(1)))
    func softwarePathTagsHDR10() async throws {
        let frame = try await firstFrame(fixture: "hdr10.mp4", deinterlacing: .off)
        #expect(!frame.isHardwareDecoded, "policy .software must not produce a VideoToolbox surface")

        let attachments = propagatedAttachments(of: frame.pixelBuffer)
        #expect(
            attachments[kCVImageBufferColorPrimariesKey as String] as? String
                == kCVImageBufferColorPrimaries_ITU_R_2020 as String
        )
        #expect(
            attachments[kCVImageBufferTransferFunctionKey as String] as? String
                == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        )
        #expect(
            attachments[kCVImageBufferYCbCrMatrixKey as String] as? String
                == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
        )

        // The fixture is graded P3-D65 / 1000 nits, so both static HDR payloads
        // are present and must arrive in the exact byte widths CoreVideo wants.
        let mastering = try #require(
            attachments[kCVImageBufferMasteringDisplayColorVolumeKey as String] as? Data,
            "ST 2086 mastering display volume missing"
        )
        #expect(mastering.count == 24, "ST 2086 payload is 24 bytes, got \(mastering.count)")
        // Byte-exact against the fixture's own grade —
        // G(13250,34500) B(7500,3000) R(34000,16000) WP(15635,16450) L(10000000,1).
        // This is what proves the primaries are re-ordered on the way out:
        // FFmpeg normalises the SEI's G,B,R into R,G,B, and ST 2086 wants
        // G,B,R back. A payload in the wrong order is still 24 valid-looking
        // bytes, so only the values catch it.
        #expect(
            Array(mastering) == [
                0x33, 0xC2, 0x86, 0xC4, // G 13250, 34500
                0x1D, 0x4C, 0x0B, 0xB8, // B  7500,  3000
                0x84, 0xD0, 0x3E, 0x80, // R 34000, 16000
                0x3D, 0x13, 0x40, 0x42, // WP 15635, 16450
                0x00, 0x98, 0x96, 0x80, // max luminance 10000000 (1000 nits)
                0x00, 0x00, 0x00, 0x01, // min luminance 1 (0.0001 nits)
            ],
            "unexpected ST 2086 payload: \(Array(mastering).map { String(format: "%02X", $0) }.joined(separator: " "))"
        )
        let light = try #require(
            attachments[kCVImageBufferContentLightLevelInfoKey as String] as? Data,
            "CTA-861.3 content light level missing"
        )
        #expect(light.count == 4, "content light payload is 4 bytes, got \(light.count)")
        // MaxCLL 1000, MaxFALL 400 — big-endian, in that order.
        #expect(Array(light) == [0x03, 0xE8, 0x01, 0x90])
    }

    /// The point of the whole change: `CMVideoFormatDescriptionCreateForImageBuffer`
    /// only describes colour it can read off the buffer, and that description
    /// is what the renderer enqueues.
    @Test("software path: the format description built from the buffer is tagged", .timeLimit(.minutes(1)))
    func formatDescriptionCarriesColor() async throws {
        let frame = try await firstFrame(fixture: "hdr10.mp4", deinterlacing: .off)
        var cache: CMVideoFormatDescription?
        _ = try SampleBufferBuilder.video(from: frame, formatCache: &cache)
        let description = try #require(cache)

        let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
        #expect(
            extensions[kCVImageBufferTransferFunctionKey as String] as? String
                == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
            "format description must describe PQ, got \(extensions)"
        )
        #expect(
            extensions[kCVImageBufferColorPrimariesKey as String] as? String
                == kCVImageBufferColorPrimaries_ITU_R_2020 as String
        )
    }

    /// Deinterlacing is on by default and downloads hardware frames to the CPU,
    /// so an interlaced HDR broadcast goes through `PixelBufferFactory` even on
    /// a hardware decode. `.always` forces that path for a progressive fixture.
    @Test("deinterlaced path: filter output is tagged from what the filter produced", .timeLimit(.minutes(1)))
    func deinterlacedPathTagsHDR10() async throws {
        let frame = try await firstFrame(
            fixture: "hdr10.mp4",
            deinterlacing: .init(mode: .always, rate: .frame)
        )
        let attachments = propagatedAttachments(of: frame.pixelBuffer)
        #expect(
            attachments[kCVImageBufferColorPrimariesKey as String] as? String
                == kCVImageBufferColorPrimaries_ITU_R_2020 as String
        )
        #expect(
            attachments[kCVImageBufferTransferFunctionKey as String] as? String
                == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        )
        #expect(
            attachments[kCVImageBufferYCbCrMatrixKey as String] as? String
                == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
        )
    }

    /// The regression guard. `basic.mp4` declares nothing at all — the shape of
    /// most SD and IPTV channels — and must come out exactly as bare as it did
    /// before this feature existed.
    @Test("an undeclared stream gets no colour attachments at all", .timeLimit(.minutes(1)))
    func unspecifiedStreamStaysBare() async throws {
        for deinterlacing in [VideoDecoder.Deinterlacing.off, .init(mode: .always, rate: .frame)] {
            let frame = try await firstFrame(fixture: "basic.mp4", deinterlacing: deinterlacing)
            #expect(frame.colorimetry.primaries == 2, "AVCOL_PRI_UNSPECIFIED")
            let attachments = propagatedAttachments(of: frame.pixelBuffer)
            #expect(attachments[kCVImageBufferColorPrimariesKey as String] == nil)
            #expect(attachments[kCVImageBufferTransferFunctionKey as String] == nil)
            #expect(attachments[kCVImageBufferYCbCrMatrixKey as String] == nil)
            #expect(attachments[kCVImageBufferMasteringDisplayColorVolumeKey as String] == nil)
            #expect(attachments[kCVImageBufferContentLightLevelInfoKey as String] == nil)
        }
    }

    @Test("preservesHDRMetadata off leaves buffers untagged", .timeLimit(.minutes(1)))
    func knobDisablesTagging() async throws {
        let frame = try await firstFrame(
            fixture: "hdr10.mp4", deinterlacing: .off, preservesHDRMetadata: false
        )
        // The frame still *reports* what the source declared; only the buffer
        // is left alone.
        #expect(frame.colorimetry.transfer == 16, "AVCOL_TRC_SMPTE2084")

        let attachments = propagatedAttachments(of: frame.pixelBuffer)
        #expect(attachments[kCVImageBufferColorPrimariesKey as String] == nil)
        #expect(attachments[kCVImageBufferTransferFunctionKey as String] == nil)
        #expect(attachments[kCVImageBufferYCbCrMatrixKey as String] == nil)
    }

    // MARK: Support

    /// `.shouldPropagate` is the set that travels into the `CMSampleBuffer`, so
    /// it is the only set worth asserting on.
    private func propagatedAttachments(of buffer: CVPixelBuffer) -> [String: Any] {
        (CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any]) ?? [:]
    }

    /// Decodes a fixture on the CPU and returns the first delivered frame.
    private func firstFrame(
        fixture: String,
        deinterlacing: VideoDecoder.Deinterlacing,
        preservesHDRMetadata: Bool = true
    ) async throws -> VideoFrame {
        let demuxer = Demuxer(url: try Fixtures.path(fixture))
        defer { demuxer.shutdown() }
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()
        guard case .opened(let info)? = await events.next() else {
            throw EngineError(code: .openFailed, message: "fixture \(fixture) failed to open")
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
            // Software only: the VideoToolbox surface is tagged by
            // VideoToolbox itself and is not what this suite is about.
            policy: .software,
            deinterlacing: deinterlacing,
            preservesHDRMetadata: preservesHDRMetadata
        )
        defer { decoder.shutdown() }
        decoder.start()
        demuxer.resume()

        guard let frame = frames.receive(timeout: 10) else {
            throw EngineError(code: .decodeFailed, message: "\(fixture) produced no frame")
        }
        return frame
    }
}
