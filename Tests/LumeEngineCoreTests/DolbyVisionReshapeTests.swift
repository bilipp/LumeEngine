import CoreVideo
import Foundation
import simd
import Testing
@testable import LumeEngineCore

/// Dolby Vision IPT-PQ-c2 reshaping (issue #207): profiles whose base layer has
/// no backward-compatible signal (5, 20, 10.0) render pink/green unless the RPU
/// is applied. The kernel is checked against the CPU reference on synthetic
/// input; the real-stream test runs only where the gitignored sample exists.
@Suite("Dolby Vision reshaping", .serialized)
struct DolbyVisionReshapeTests {
    /// The RPU of `DVprofile20.mp4` (frame at 8.29 s), as ffprobe prints it:
    /// polynomial curves, the standard IPT matrix, 2 % crosstalk.
    static let sampleParameters: DolbyVisionReshapeParameters = {
        let denominator = Float(1 << 23)
        func curve(pivots: [Float], c0: Float, c1: Float) -> DolbyVisionReshapeParameters.Curve {
            let piece = DolbyVisionReshapeParameters.Piece(
                isMMR: false,
                poly: SIMD3(c0 / denominator, c1 / denominator, 0),
                mmrOrder: 0,
                mmrConstant: 0,
                mmr: []
            )
            return .init(
                pivots: pivots.map { $0 / 1023 },
                pieces: Array(repeating: piece, count: pivots.count - 1)
            )
        }
        let luma = curve(pivots: [0, 173, 283, 392, 502, 611, 721, 830, 1023], c0: -612_867, c1: 9_803_467)
        let chroma = curve(pivots: [0, 288, 512, 736, 1023], c0: -599_187, c1: 9_584_640)
        return DolbyVisionReshapeParameters(
            curves: [luma, chroma, chroma],
            nonlinear: simd_double3x3(rows: [
                SIMD3(8192, 799, 1681) / 8192,
                SIMD3(8192, -933, 1091) / 8192,
                SIMD3(8192, 267, -5545) / 8192,
            ]),
            nonlinearOffset: SIMD3(0, 0.5, 0.5),
            rgbToLMS: simd_double3x3(rows: [
                SIMD3(17081, -349, -349) / 16384,
                SIMD3(-349, 17081, -349) / 16384,
                SIMD3(-349, -349, 17081) / 16384,
            ])
        )
    }()

    @Test("parameters pack into the layout the kernel reads")
    func packing() {
        let parameters = Self.sampleParameters
        #expect(parameters.isValid)
        let packed = parameters.packed()
        #expect(packed.count == DolbyVisionReshapeParameters.headerFloats + 3 * DolbyVisionReshapeParameters.curveStride)
        #expect(packed[0] == 1) // nonlinear[0][0]
        #expect(abs(packed[1] - 799 / 8192) < 1e-6) // row-major
        #expect(packed[10] == 0.5)
        let luma = DolbyVisionReshapeParameters.headerFloats
        #expect(packed[luma] == 8)
        #expect(abs(packed[luma + 9] - 1) < 1e-6) // last pivot
    }

    /// The neutral axis is the easiest thing to get wrong and the easiest to
    /// see: IPT with P = T = neutral must come out grey, not green or magenta.
    @Test("CPU reference: neutral IPT is neutral RGB")
    func neutralIsGrey() {
        // Invert the chroma curve at 0.5: c0 + c1·x = 0.5.
        let chroma = Self.sampleParameters.curves[1].pieces[0].poly
        let neutral = (0.5 - chroma.x) / chroma.y
        let rgb = Self.sampleParameters.reference(i: 0.5, p: neutral, t: neutral)
        #expect(abs(rgb.x - rgb.y) < 0.002 && abs(rgb.y - rgb.z) < 0.002, "got \(rgb)")
    }

    @Test("GPU kernel matches the CPU reference")
    func kernelMatchesReference() throws {
        guard let reshaper = DolbyVisionReshaper() else {
            // No Metal device (some CI hosts): nothing to compare.
            return
        }
        let samples: [(i: UInt16, p: UInt16, t: UInt16)] = [
            (600, 480, 560), (200, 512, 512), (900, 400, 600), (64, 700, 300),
        ]
        for sample in samples {
            let source = try Self.uniformBuffer(i: sample.i, p: sample.p, t: sample.t)
            let output = try reshaper.reshape(source, parameters: Self.sampleParameters)

            #expect(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            let rgb = Self.sampleParameters.reference(
                i: Float(sample.i) / 1023, p: Float(sample.p) / 1023, t: Float(sample.t) / 1023
            )
            let y = dot(rgb, SIMD3(0.2627, 0.6780, 0.0593))
            let expected = (
                y: (64 + 876 * y).rounded(),
                cb: (512 + 896 * (rgb.z - y) / 1.8814).rounded(),
                cr: (512 + 896 * (rgb.x - y) / 1.4746).rounded()
            )
            let actual = Self.codes(of: output)
            #expect(abs(Float(actual.y) - expected.y) <= 1, "Y \(actual.y) vs \(expected.y) for \(sample)")
            #expect(abs(Float(actual.cb) - expected.cb) <= 1, "Cb \(actual.cb) vs \(expected.cb) for \(sample)")
            #expect(abs(Float(actual.cr) - expected.cr) <= 1, "Cr \(actual.cr) vs \(expected.cr) for \(sample)")
        }
    }

    @Test("output is tagged HDR10")
    func outputTags() throws {
        guard let reshaper = DolbyVisionReshaper() else { return }
        let output = try reshaper.reshape(
            try Self.uniformBuffer(i: 500, p: 512, t: 512), parameters: Self.sampleParameters
        )
        let attachments = (CVBufferCopyAttachments(output, .shouldPropagate) as? [String: Any]) ?? [:]
        #expect(attachments[kCVImageBufferColorPrimariesKey as String] as? String
            == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        #expect(attachments[kCVImageBufferTransferFunctionKey as String] as? String
            == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        #expect(attachments[kCVImageBufferYCbCrMatrixKey as String] as? String
            == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
    }

    // MARK: Real stream

    static let profile20Sample = Fixtures.repoRoot
        .appendingPathComponent("TestStreams/DolbyVision/DVprofile20.mp4")

    /// Both decode paths must reshape, and must agree with each other: the
    /// VideoToolbox surface and the swscale buffer carry the same samples.
    @Test(
        "profile 20 reshapes on the hardware and the software path",
        .enabled(if: FileManager.default.fileExists(atPath: profile20Sample.path)),
        .timeLimit(.minutes(2))
    )
    func profile20BothPaths() async throws {
        let hardware = try await Self.decodedFrame(policy: .videoToolbox, index: 0)
        let software = try await Self.decodedFrame(policy: .software, index: 0)
        for frame in [hardware, software] {
            #expect(CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            #expect(frame.colorimetry.transfer == 16, "AVCOL_TRC_SMPTE2084")
            #expect(frame.colorimetry.matrix == 9, "AVCOL_SPC_BT2020_NCL, not IPT-C2")
            #expect(!frame.isHardwareDecoded, "a reshaped buffer is not the VideoToolbox surface")
        }
        let a = Self.meanCodes(of: hardware.pixelBuffer)
        let b = Self.meanCodes(of: software.pixelBuffer)
        #expect(abs(a.y - b.y) < 2 && abs(a.cb - b.cb) < 2 && abs(a.cr - b.cr) < 2, "hw \(a) vs sw \(b)")

        // The frame the tint was reported on (hippo in sea water, ~10 s):
        // the water is blue-green, so Cb sits above neutral. The untreated IPT
        // picture has it well below — that *is* the green tint.
        let reported = try await Self.decodedFrame(policy: .videoToolbox, index: 240)
        let mean = Self.meanCodes(of: reported.pixelBuffer)
        #expect(mean.cb > 512, "mean \(mean)")
        if let dump = ProcessInfo.processInfo.environment["LUME_DV_DUMP"] {
            try Self.dump(reported.pixelBuffer, to: URL(fileURLWithPath: dump))
        }
    }

    // MARK: Support

    /// A 4×4 full-range 10-bit buffer with one IPT value everywhere.
    static func uniformBuffer(i: UInt16, p: UInt16, t: UInt16) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, attributes as CFDictionary, &buffer)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        for plane in 0..<2 {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane))
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, plane) {
                let line = base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)
                for column in 0..<CVPixelBufferGetWidthOfPlane(pixelBuffer, plane) {
                    if plane == 0 {
                        line[column] = i << 6
                    } else {
                        line[column * 2] = p << 6
                        line[column * 2 + 1] = t << 6
                    }
                }
            }
        }
        return pixelBuffer
    }

    /// The top-left sample of each channel, as 10-bit codes.
    static func codes(of buffer: CVPixelBuffer) -> (y: UInt16, cb: UInt16, cr: UInt16) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt16.self)
        return (luma[0] >> 6, chroma[0] >> 6, chroma[1] >> 6)
    }

    static func meanCodes(of buffer: CVPixelBuffer) -> (y: Double, cb: Double, cr: Double) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        func mean(plane: Int, channel: Int, channels: Int) -> Double {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            var total = 0.0
            var count = 0.0
            for row in Swift.stride(from: 0, to: height, by: 4) {
                let line = base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)
                for column in Swift.stride(from: 0, to: width, by: 4) {
                    total += Double(line[column * channels + channel] >> 6)
                    count += 1
                }
            }
            return total / count
        }
        return (mean(plane: 0, channel: 0, channels: 1), mean(plane: 1, channel: 0, channels: 2), mean(plane: 1, channel: 1, channels: 2))
    }

    /// Raw planes, tightly packed (`yuv420p10`-style P010 layout: Y then CbCr).
    static func dump(_ buffer: CVPixelBuffer, to url: URL) throws {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var data = Data()
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rowBytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * 2 * (plane == 0 ? 1 : 2)
            for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                data.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: rowBytes)
            }
        }
        try data.write(to: url)
    }

    static func decodedFrame(policy: VideoDecoder.HardwarePolicy, index: Int) async throws -> VideoFrame {
        let demuxer = Demuxer(url: profile20Sample.path)
        defer { demuxer.shutdown() }
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()
        guard case .opened(let info)? = await events.next() else {
            throw EngineError(code: .openFailed, message: "DVprofile20.mp4 failed to open")
        }
        let track = try #require(info.videoTracks.first)
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))
        let packets = Channel<Packet>(capacity: 64)
        let frames = Channel<VideoFrame>(capacity: 4)
        demuxer.attach(channel: packets, toStream: track.index)

        let decoder = VideoDecoder(parameters: parameters, input: packets, output: frames, policy: policy, deinterlacing: .off)
        defer { decoder.shutdown() }
        decoder.start()
        demuxer.resume()

        for _ in 0..<index {
            guard frames.receive(timeout: 20) != nil else {
                throw EngineError(code: .decodeFailed, message: "stream ended early")
            }
        }
        guard let frame = frames.receive(timeout: 20) else {
            throw EngineError(code: .decodeFailed, message: "no frame \(index)")
        }
        return frame
    }
}
