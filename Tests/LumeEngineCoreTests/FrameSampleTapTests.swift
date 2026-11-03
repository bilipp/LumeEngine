import CoreVideo
import Foundation
import Testing
@testable import LumeEngineCore

@Suite("Frame sample tap", .serialized)
struct FrameSampleTapTests {
    // MARK: Synthetic buffers

    private typealias RGB = (red: Float, green: Float, blue: Float)

    private enum Matrix: String, CaseIterable {
        case bt601, bt709, bt2020

        var coefficients: (kr: Float, kb: Float) {
            switch self {
            case .bt601: (0.299, 0.114)
            case .bt709: (0.2126, 0.0722)
            case .bt2020: (0.2627, 0.0593)
            }
        }

        var tag: CFString {
            switch self {
            case .bt601: kCVImageBufferYCbCrMatrix_ITU_R_601_4
            case .bt709: kCVImageBufferYCbCrMatrix_ITU_R_709_2
            case .bt2020: kCVImageBufferYCbCrMatrix_ITU_R_2020
            }
        }
    }

    /// A 4:2:0 bi-planar buffer filled with one flat gamma-encoded colour,
    /// converted with `matrix` and tagged with `tag` (nil leaves it untagged).
    private func flatBuffer(
        _ color: RGB,
        matrix: Matrix,
        tag: CFString?,
        primaries: CFString? = kCVImageBufferColorPrimaries_ITU_R_709_2,
        format: OSType,
        width: Int = 64,
        height: Int = 36
    ) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &created)
        let buffer = try #require(status == kCVReturnSuccess ? created : nil)

        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let scale: Float = tenBit ? 4 : 1
        let maxCode: Float = tenBit ? 1023 : 255

        let (kr, kb) = matrix.coefficients
        let luma = kr * color.red + (1 - kr - kb) * color.green + kb * color.blue
        let cb = (color.blue - luma) / (2 * (1 - kb))
        let cr = (color.red - luma) / (2 * (1 - kr))
        func code(_ value: Float, isLuma: Bool) -> Int {
            let raw: Float
            if fullRange {
                raw = isLuma ? value * maxCode : value * maxCode + 128 * scale
            } else {
                raw = isLuma ? 16 * scale + value * 219 * scale : 128 * scale + value * 224 * scale
            }
            return Int(min(max(raw.rounded(), 0), maxCode))
        }
        let lumaCode = code(luma, isLuma: true)
        let cbCode = code(cb, isLuma: false)
        let crCode = code(cr, isLuma: false)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let planeWidth = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let values = plane == 0 ? [lumaCode] : [cbCode, crCode]
            for row in 0..<planeHeight {
                for column in 0..<planeWidth {
                    for (index, value) in values.enumerated() {
                        let sampleIndex = column * values.count + index
                        if tenBit {
                            base.storeBytes(
                                of: UInt16(value << 6),
                                toByteOffset: row * stride + sampleIndex * 2,
                                as: UInt16.self
                            )
                        } else {
                            base.storeBytes(of: UInt8(value), toByteOffset: row * stride + sampleIndex, as: UInt8.self)
                        }
                    }
                }
            }
        }
        if let tag {
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, tag, .shouldPropagate)
        }
        if let primaries {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        }
        CVBufferSetAttachment(
            buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate
        )
        return buffer
    }

    private func frame(_ buffer: CVPixelBuffer, pts: Int64, serial: UInt64 = 0) -> VideoFrame {
        VideoFrame(pixelBuffer: buffer, pts: pts, duration: 40_000, serial: serial, isHardwareDecoded: false)
    }

    private func linear(_ color: RGB) -> VideoSampleTap.Color {
        VideoSampleTap.Color(red: powf(color.red, 2.2), green: powf(color.green, 2.2), blue: powf(color.blue, 2.2))
    }

    private func distance(_ lhs: VideoSampleTap.Color, _ rhs: VideoSampleTap.Color) -> Float {
        max(abs(lhs.red - rhs.red), abs(lhs.green - rhs.green), abs(lhs.blue - rhs.blue))
    }

    private static let palette: [(name: String, color: (red: Float, green: Float, blue: Float))] = [
        ("red", (1, 0, 0)),
        ("green", (0, 1, 0)),
        ("blue", (0, 0, 1)),
        ("white", (1, 1, 1)),
        ("black", (0, 0, 0)),
        ("mixed", (0.8, 0.4, 0.2)),
    ]

    private static let formats: [OSType] = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
    ]

    // MARK: Colour conversion

    @Test("colours: each tagged matrix decodes to the source colour, 8- and 10-bit, both ranges",
          arguments: Matrix.allCases, formats)
    private func taggedMatrix(_ matrix: Matrix, format: OSType) throws {
        let configuration = VideoSampleTap.Configuration(columns: 4, rows: 3, pointsPerCell: 2, capacity: 4)
        for (name, color) in Self.palette {
            let buffer = try flatBuffer(color, matrix: matrix, tag: matrix.tag, format: format)
            let sample = try #require(VideoSampleTap.read(buffer, pts: 0, configuration: configuration))
            #expect(sample.colors.count == 12)
            let expected = linear(color)
            for cell in sample.colors {
                #expect(distance(cell, expected) < 0.02, "\(matrix.rawValue) \(name): got \(cell), want \(expected)")
            }
        }
    }

    @Test("colours: the matrix comes from the buffer's tag, not a fixed guess")
    func matrixTagIsHonoured() throws {
        let configuration = VideoSampleTap.Configuration(columns: 1, rows: 1, pointsPerCell: 1, capacity: 1)
        // Unsaturated, so the wrong matrix cannot hide behind clamping.
        let color: RGB = (0.2, 0.9, 0.3)
        let right = try flatBuffer(
            color, matrix: .bt601, tag: Matrix.bt601.tag, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let wrong = try flatBuffer(
            color, matrix: .bt601, tag: Matrix.bt709.tag, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let decodedRight = try #require(VideoSampleTap.read(right, pts: 0, configuration: configuration)?.average)
        let decodedWrong = try #require(VideoSampleTap.read(wrong, pts: 0, configuration: configuration)?.average)
        #expect(distance(decodedRight, linear(color)) < 0.02)
        #expect(distance(decodedWrong, linear(color)) > 0.05, "a 601 picture read as 709 must not come out right")
    }

    @Test("colours: untagged SD reads as BT.601, untagged HD as BT.709")
    func untaggedFallback() throws {
        let configuration = VideoSampleTap.Configuration(columns: 1, rows: 1, pointsPerCell: 1, capacity: 1)
        let color: RGB = (0.2, 0.9, 0.3)
        let sd = try flatBuffer(
            color, matrix: .bt601, tag: nil, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: 720, height: 576
        )
        let hd = try flatBuffer(
            color, matrix: .bt709, tag: nil, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: 1280, height: 720
        )
        let sdColor = try #require(VideoSampleTap.read(sd, pts: 0, configuration: configuration)?.average)
        let hdColor = try #require(VideoSampleTap.read(hd, pts: 0, configuration: configuration)?.average)
        #expect(distance(sdColor, linear(color)) < 0.02)
        #expect(distance(hdColor, linear(color)) < 0.02)
    }

    @Test("colours: BT.2020 primaries map onto BT.709, white stays white")
    func bt2020Primaries() throws {
        let configuration = VideoSampleTap.Configuration(columns: 1, rows: 1, pointsPerCell: 1, capacity: 1)
        let white = try flatBuffer(
            (1, 1, 1), matrix: .bt2020, tag: Matrix.bt2020.tag, primaries: nil,
            format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        let red = try flatBuffer(
            (0.6, 0.2, 0.2), matrix: .bt2020, tag: Matrix.bt2020.tag, primaries: nil,
            format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        let whiteColor = try #require(VideoSampleTap.read(white, pts: 0, configuration: configuration)?.average)
        let redColor = try #require(VideoSampleTap.read(red, pts: 0, configuration: configuration)?.average)
        #expect(distance(whiteColor, VideoSampleTap.Color(red: 1, green: 1, blue: 1)) < 0.02)
        // A BT.2020 red is more saturated than the same code values in BT.709.
        let unconverted = linear((0.6, 0.2, 0.2))
        #expect(redColor.red > unconverted.red)
        #expect(redColor.green < unconverted.green)
    }

    @Test("buffers it cannot read give no sample")
    func unsupportedFormat() throws {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &created)
        let buffer = try #require(created)
        #expect(VideoSampleTap.read(buffer, pts: 0, configuration: .init()) == nil)
    }

    // MARK: Ring

    @Test("ring: off by default, so nothing is kept")
    func disabledByDefault() throws {
        let tap = VideoSampleTap()
        #expect(!tap.isEnabled)
        let buffer = try flatBuffer(
            (1, 0, 0), matrix: .bt709, tag: Matrix.bt709.tag, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        tap.offer(frame(buffer, pts: 0))
        #expect(tap.latestSample == nil)

        tap.isEnabled = true
        tap.offer(frame(buffer, pts: 40_000))
        #expect(tap.latestSample?.pts == 40_000)

        tap.isEnabled = false
        #expect(tap.latestSample == nil, "disabling clears what was kept")
    }

    @Test("ring: atOrBefore picks the newest sample not after the time, capacity trims the oldest")
    func atOrBefore() throws {
        let tap = VideoSampleTap(configuration: .init(columns: 2, rows: 2, pointsPerCell: 1, capacity: 3), enabled: true)
        let buffer = try flatBuffer(
            (0, 0, 1), matrix: .bt709, tag: Matrix.bt709.tag, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        for pts in stride(from: Int64(0), through: 160_000, by: 40_000) {
            tap.offer(frame(buffer, pts: pts))
        }
        // Kept: 80_000, 120_000, 160_000.
        #expect(tap.sample(atOrBefore: 79_999) == nil)
        #expect(tap.sample(atOrBefore: 80_000)?.pts == 80_000)
        #expect(tap.sample(atOrBefore: 150_000)?.pts == 120_000)
        #expect(tap.sample(atOrBefore: 10_000_000)?.pts == 160_000)
        #expect(tap.sample(atOrBefore: MediaTime.noTimestamp) == nil)
        #expect(tap.latestSample?.color(column: 1, row: 1) != nil)
        #expect(tap.latestSample?.color(column: 2, row: 0) == nil)
    }

    @Test("ring: empty after flush; a stale serial is refused, a newer one replaces the ring")
    func flushAndSerial() throws {
        let tap = VideoSampleTap(enabled: true)
        let buffer = try flatBuffer(
            (1, 1, 1), matrix: .bt709, tag: Matrix.bt709.tag, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        tap.offer(frame(buffer, pts: 0))
        tap.offer(frame(buffer, pts: 40_000))
        #expect(tap.latestSample?.pts == 40_000)

        tap.flush()
        #expect(tap.latestSample == nil)

        tap.offer(frame(buffer, pts: 80_000))
        tap.flush(acceptingSerial: 2)
        #expect(tap.latestSample == nil)

        // A frame decoded before the seek, still in flight.
        tap.offer(frame(buffer, pts: 120_000, serial: 1))
        #expect(tap.latestSample == nil, "a pre-seek frame must not land after the flush")

        tap.offer(frame(buffer, pts: 5_000_000, serial: 2))
        #expect(tap.latestSample?.pts == 5_000_000)

        // A newer serial without a flush (serial change) starts a fresh ring.
        tap.offer(frame(buffer, pts: 1_000_000, serial: 3))
        #expect(tap.sample(atOrBefore: 5_000_000)?.pts == 1_000_000)
        #expect(tap.sample(atOrBefore: 999_999) == nil)
    }

    @Test("ring: a timeline that steps back drops what it would shadow")
    func backwardsPTS() throws {
        let tap = VideoSampleTap(enabled: true)
        let buffer = try flatBuffer(
            (0, 1, 0), matrix: .bt709, tag: Matrix.bt709.tag, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        for pts in [Int64(0), 40_000, 80_000, 120_000] {
            tap.offer(frame(buffer, pts: pts))
        }
        tap.offer(frame(buffer, pts: 60_000))
        #expect(tap.latestSample?.pts == 60_000)
        #expect(tap.sample(atOrBefore: 200_000)?.pts == 60_000)
        #expect(tap.sample(atOrBefore: 50_000)?.pts == 40_000)
    }

    @Test("ring: reconfiguring clears it and changes the grid")
    func reconfigure() throws {
        let tap = VideoSampleTap(enabled: true)
        let buffer = try flatBuffer(
            (1, 0, 0), matrix: .bt709, tag: Matrix.bt709.tag, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        tap.offer(frame(buffer, pts: 0))
        #expect(tap.latestSample?.colors.count == 16 * 9)
        tap.configuration = .init(columns: 3, rows: 2, pointsPerCell: 1, capacity: 8)
        #expect(tap.latestSample == nil)
        tap.offer(frame(buffer, pts: 40_000))
        #expect(tap.latestSample?.colors.count == 6)
        // Out-of-range values clamp rather than trap.
        let clamped = VideoSampleTap.Configuration(columns: 0, rows: 1_000, pointsPerCell: -3, capacity: 0)
        #expect(clamped.columns >= 1 && clamped.rows <= 64 && clamped.pointsPerCell >= 1 && clamped.capacity >= 1)
    }

    // MARK: Decoded fixture

    @Test("fixture: decoded quadrants come out red, green, blue, white with monotonic PTS",
          .timeLimit(.minutes(1)), arguments: ["quadrant.mp4", "quadrant10.mp4"])
    func quadrantFixture(_ fixture: String) async throws {
        let demuxer = Demuxer(url: try Fixtures.path(fixture))
        defer { demuxer.shutdown() }
        var demuxEvents = demuxer.events.makeAsyncIterator()
        demuxer.start()
        guard case .opened(let info)? = await demuxEvents.next() else {
            Issue.record("fixture \(fixture) failed to open")
            return
        }
        let track = try #require(info.videoTracks.first)
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))

        let packets = Channel<Packet>(capacity: 64)
        let frames = Channel<VideoFrame>(capacity: 16, measure: { $0.duration })
        demuxer.attach(channel: packets, toStream: track.index)
        let decoder = VideoDecoder(parameters: parameters, input: packets, output: frames)
        var decodeEvents = decoder.events.makeAsyncIterator()
        decoder.start()
        demuxer.resume()

        let tap = VideoSampleTap(
            configuration: .init(columns: 2, rows: 2, pointsPerCell: 3, capacity: 240),
            enabled: true
        )
        // Offer on the drain thread, as the render queue would; keep only PTS.
        let collector = ChannelDrain(frames, into: [Int64]()) { collected, frame in
            tap.offer(frame)
            collected.append(frame.pts)
        }

        while let event = await demuxEvents.next() {
            if case .endOfStream = event {
                decoder.signalEndOfStream()
                break
            }
        }
        guard case .endOfStream? = await decodeEvents.next() else {
            Issue.record("expected decoder .endOfStream")
            decoder.shutdown()
            return
        }
        decoder.shutdown()
        let offered = await collector.value

        #expect(offered.count >= 45, "2 s @ 25 fps ≈ 50 frames, got \(offered.count)")
        #expect(zip(offered, offered.dropFirst()).allSatisfy { $0 < $1 }, "decoded PTS must be monotonic")

        // Every offered frame is kept and found at its own PTS.
        for pts in offered {
            #expect(tap.sample(atOrBefore: pts)?.pts == pts)
        }
        if let first = offered.first {
            #expect(tap.sample(atOrBefore: first - 1) == nil)
        }

        let sample = try #require(tap.latestSample)
        let expected: [(column: Int, row: Int, name: String, color: VideoSampleTap.Color)] = [
            (0, 0, "red", .init(red: 1, green: 0, blue: 0)),
            (1, 0, "green", .init(red: 0, green: 1, blue: 0)),
            (0, 1, "blue", .init(red: 0, green: 0, blue: 1)),
            (1, 1, "white", .init(red: 1, green: 1, blue: 1)),
        ]
        for quadrant in expected {
            let got = try #require(sample.color(column: quadrant.column, row: quadrant.row))
            #expect(
                distance(got, quadrant.color) < 0.08,
                "\(fixture) \(quadrant.name) quadrant: got \(got)"
            )
        }

        tap.flush()
        #expect(tap.latestSample == nil)
        #expect(tap.sample(atOrBefore: offered.last ?? 0) == nil)
    }
}
