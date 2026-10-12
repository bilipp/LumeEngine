import CFFmpeg
import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import LumeEngineCore

/// HDR10 static metadata and HDR10+ dynamic metadata, carried from the stream
/// to what the renderer reads. Without them the display tone maps an HDR grade
/// blind: a 1000-nit master and a 4000-nit master come out the same.
@Suite("HDR metadata", .serialized)
struct HDRMetadataTests {
    // MARK: Payload layout

    /// The mastering display colour volume SEI exactly as x265 writes it into
    /// `hdr10.mp4` for `master-display=G(13250,34500)B(7500,3000)R(34000,16000)
    /// WP(15635,16450)L(10000000,50)` — read back with FFmpeg's `trace_headers`.
    /// Apple's payload *is* that SEI, so this is the reference, byte for byte.
    static let fixtureMasteringDisplayPayload: [UInt8] = [
        0x33, 0xC2, 0x86, 0xC4, // green x 13250, y 34500
        0x1D, 0x4C, 0x0B, 0xB8, // blue x 7500, y 3000
        0x84, 0xD0, 0x3E, 0x80, // red x 34000, y 16000
        0x3D, 0x13, 0x40, 0x42, // white point x 15635, y 16450
        0x00, 0x98, 0x96, 0x80, // max luminance 10 000 000 (1000 cd/m²)
        0x00, 0x00, 0x00, 0x32, // min luminance 50 (0.005 cd/m²)
    ]

    /// `max-cll=1000,400`: MaxCLL then MaxFALL, big-endian.
    static let fixtureContentLightPayload: [UInt8] = [0x03, 0xE8, 0x01, 0x90]

    /// The user-data-registered T.35 SEI payload x265 writes for the
    /// fixture's HDR10+ scene, again read back with `trace_headers`. Apple's
    /// attachment is this message from the country code on.
    static let fixtureHDR10PlusMessage: [UInt8] = [
        181, 0, 60, 0, 1, 4, 1, 64, 0, 12, 128, 39, 16, 23, 112, 13, 172, 0, 250, 36, 8, 0, 0, 40,
        1, 144, 80, 3, 32, 200, 4, 177, 144, 6, 66, 88, 7, 210, 208, 9, 98, 248, 10, 243, 24, 12,
        128, 0, 64, 0, 0, 37, 0, 128, 48, 15, 255, 255, 255, 255, 255, 255, 255, 0,
    ]

    @Test("mastering display: FFmpeg's RGB rationals become the SEI's GBR big-endian payload")
    func masteringDisplayPayload() throws {
        // As FFmpeg's HEVC decoder exports the fixture's SEI: red, green, blue.
        var metadata = AVMasteringDisplayMetadata()
        metadata.display_primaries = (
            (AVRational(num: 34000, den: 50000), AVRational(num: 16000, den: 50000)),
            (AVRational(num: 13250, den: 50000), AVRational(num: 34500, den: 50000)),
            (AVRational(num: 7500, den: 50000), AVRational(num: 3000, den: 50000))
        )
        metadata.white_point = (AVRational(num: 15635, den: 50000), AVRational(num: 16450, den: 50000))
        metadata.max_luminance = AVRational(num: 10_000_000, den: 10000)
        metadata.min_luminance = AVRational(num: 50, den: 10000)
        metadata.has_primaries = 1
        metadata.has_luminance = 1

        let display = try #require(HDRMetadata.MasteringDisplay(metadata))
        let payload = [UInt8](display.payload)
        #expect(payload == Self.fixtureMasteringDisplayPayload)
    }

    @Test("mastering display: container rationals in other units are rescaled and rounded")
    func masteringDisplayRescales() throws {
        // Matroska stores plain chromaticities and cd/m²; FFmpeg reduces them
        // to lowest terms (0.68 → 17/25).
        var metadata = AVMasteringDisplayMetadata()
        metadata.display_primaries = (
            (AVRational(num: 17, den: 25), AVRational(num: 8, den: 25)),
            (AVRational(num: 53, den: 200), AVRational(num: 69, den: 100)),
            (AVRational(num: 3, den: 20), AVRational(num: 3, den: 50))
        )
        metadata.white_point = (AVRational(num: 3127, den: 10000), AVRational(num: 329, den: 1000))
        metadata.max_luminance = AVRational(num: 4000, den: 1)
        metadata.min_luminance = AVRational(num: 1, den: 3) // 3333.3 units: rounds down
        metadata.has_primaries = 1
        metadata.has_luminance = 1

        let display = try #require(HDRMetadata.MasteringDisplay(metadata))
        let expectedRed = HDRMetadata.Chromaticity(x: 34000, y: 16000)
        let expectedGreen = HDRMetadata.Chromaticity(x: 13250, y: 34500)
        let expectedWhite = HDRMetadata.Chromaticity(x: 15635, y: 16450)
        #expect(display.red == expectedRed)
        #expect(display.green == expectedGreen)
        #expect(display.whitePoint == expectedWhite)
        #expect(display.maxLuminance == 40_000_000)
        #expect(display.minLuminance == 3333)
    }

    @Test("mastering display: half a description, or a broken one, is no description")
    func masteringDisplayIncomplete() {
        var metadata = AVMasteringDisplayMetadata()
        metadata.display_primaries = (
            (AVRational(num: 17, den: 25), AVRational(num: 8, den: 25)),
            (AVRational(num: 53, den: 200), AVRational(num: 69, den: 100)),
            (AVRational(num: 3, den: 20), AVRational(num: 3, den: 50))
        )
        metadata.white_point = (AVRational(num: 3127, den: 10000), AVRational(num: 329, den: 1000))
        metadata.has_primaries = 1
        metadata.has_luminance = 0
        #expect(HDRMetadata.MasteringDisplay(metadata) == nil, "luminance missing")

        metadata.has_luminance = 1
        metadata.max_luminance = AVRational(num: 1000, den: 0)
        #expect(HDRMetadata.MasteringDisplay(metadata) == nil, "zero denominator")

        metadata.max_luminance = AVRational(num: 1000, den: 1)
        metadata.min_luminance = AVRational(num: -1, den: 1)
        #expect(HDRMetadata.MasteringDisplay(metadata) == nil, "negative luminance")

        // Out-of-range chromaticities are clamped to ST 2086's limit, not
        // wrapped around 16 bits.
        metadata.min_luminance = AVRational(num: 0, den: 1)
        metadata.white_point.0 = AVRational(num: 3, den: 2)
        let clamped = HDRMetadata.MasteringDisplay(metadata)
        #expect(clamped?.whitePoint.x == 50000)
    }

    @Test("content light level: MaxCLL then MaxFALL, big-endian, clamped to 16 bits")
    func contentLightPayload() {
        let level = HDRMetadata.ContentLightLevel(AVContentLightMetadata(MaxCLL: 1000, MaxFALL: 400))
        #expect([UInt8](level.payload) == Self.fixtureContentLightPayload)

        let huge = HDRMetadata.ContentLightLevel(AVContentLightMetadata(MaxCLL: 70000, MaxFALL: 12))
        #expect(huge.maxCLL == UInt16.max)
    }

    @Test("HDR10+: FFmpeg's serialization gains the T.35 header and parses back")
    func hdr10PlusRoundTrip() throws {
        var size = 0
        let metadata = try #require(av_dynamic_hdr_plus_alloc(&size))
        defer { av_free(metadata) }
        metadata.pointee.application_version = 1
        metadata.pointee.num_windows = 1
        metadata.pointee.targeted_system_display_maximum_luminance = AVRational(num: 400, den: 1)
        metadata.pointee.params.0.average_maxrgb = AVRational(num: 1000, den: 100_000)
        metadata.pointee.params.0.maxscl = (
            AVRational(num: 5000, den: 100_000),
            AVRational(num: 6000, den: 100_000),
            AVRational(num: 7000, den: 100_000)
        )
        metadata.pointee.params.0.tone_mapping_flag = 1
        metadata.pointee.params.0.knee_point_x = AVRational(num: 0, den: 4095)
        metadata.pointee.params.0.knee_point_y = AVRational(num: 0, den: 4095)
        metadata.pointee.params.0.num_bezier_curve_anchors = 2
        metadata.pointee.params.0.bezier_curve_anchors.0 = AVRational(num: 256, den: 1023)
        metadata.pointee.params.0.bezier_curve_anchors.1 = AVRational(num: 512, den: 1023)

        let message = try #require(HDR10Plus.t35Message(metadata))
        #expect(Array(message.prefix(6)) == [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04])

        var parsedSize = 0
        let parsed = try #require(av_dynamic_hdr_plus_alloc(&parsedSize))
        defer { av_free(parsed) }
        let body = [UInt8](message.dropFirst(6))
        let status = body.withUnsafeBufferPointer {
            av_dynamic_hdr_plus_from_t35(parsed, $0.baseAddress, $0.count)
        }
        #expect(status >= 0)
        #expect(parsed.pointee.application_version == 1)
        #expect(parsed.pointee.num_windows == 1)
        #expect(av_q2d(parsed.pointee.targeted_system_display_maximum_luminance) == 400)
        #expect(av_q2d(parsed.pointee.params.0.maxscl.2) == 0.07)
        #expect(parsed.pointee.params.0.num_bezier_curve_anchors == 2)
        #expect(av_q2d(parsed.pointee.params.0.bezier_curve_anchors.1) == 512.0 / 1023)
    }

    // MARK: Attachments

    @Test("apply writes both keys, and a recycled buffer loses the previous stream's")
    func applyWritesAndClears() throws {
        let buffer = try Self.makeBuffer()
        let full = HDRMetadata(
            masteringDisplay: HDRMetadata.MasteringDisplay(
                red: .init(x: 34000, y: 16000), green: .init(x: 13250, y: 34500),
                blue: .init(x: 7500, y: 3000), whitePoint: .init(x: 15635, y: 16450),
                maxLuminance: 10_000_000, minLuminance: 50
            ),
            contentLightLevel: .init(maxCLL: 1000, maxFALL: 400)
        )
        full.apply(to: buffer)
        #expect(Self.bytes(buffer, kCVImageBufferMasteringDisplayColorVolumeKey) == Self.fixtureMasteringDisplayPayload)
        #expect(Self.bytes(buffer, kCVImageBufferContentLightLevelInfoKey) == Self.fixtureContentLightPayload)

        HDRMetadata().apply(to: buffer)
        #expect(Self.bytes(buffer, kCVImageBufferMasteringDisplayColorVolumeKey) == nil)
        #expect(Self.bytes(buffer, kCVImageBufferContentLightLevelInfoKey) == nil)
    }

    @Test("frame side data: what FFmpeg attached is what is read; Dolby Vision L6 fills a missing light level")
    func readsFrameSideData() throws {
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let raw = try #require(frame)
        #expect(HDRMetadata(frame: raw) == HDRMetadata())
        #expect(HDR10Plus.t35Message(from: raw) == nil)

        // A Dolby Vision RPU whose level 6 block holds the HDR10 light levels.
        var doviSize = 0
        let dovi = try #require(av_dovi_metadata_alloc(&doviSize))
        // No free callback: the default is `av_free`, which is what the
        // allocation wants.
        let doviData = try #require(av_buffer_create(
            UnsafeMutableRawPointer(dovi).assumingMemoryBound(to: UInt8.self), doviSize, nil, nil, 0
        ))
        dovi.pointee.num_ext_blocks = 1
        let block = try #require(av_dovi_get_ext(dovi, 0))
        block.pointee.level = 6
        block.pointee.l6 = AVDOVIDmLevel6(max_luminance: 1000, min_luminance: 50, max_cll: 900, max_fall: 300)
        var doviRef: UnsafeMutablePointer<AVBufferRef>? = doviData
        #expect(av_frame_new_side_data_from_buf(raw, AV_FRAME_DATA_DOVI_METADATA, doviRef) != nil)
        doviRef = nil

        let fromRPU = HDRMetadata(frame: raw)
        #expect(fromRPU.masteringDisplay == nil, "level 6 has no primaries: no mastering display is made up")
        #expect(fromRPU.contentLightLevel == HDRMetadata.ContentLightLevel(maxCLL: 900, maxFALL: 300))

        // The stream's own light level wins over the RPU's.
        let light = try #require(av_content_light_metadata_create_side_data(raw))
        light.pointee.MaxCLL = 1000
        light.pointee.MaxFALL = 400
        let display = try #require(av_mastering_display_metadata_create_side_data(raw))
        display.pointee.display_primaries = (
            (AVRational(num: 34000, den: 50000), AVRational(num: 16000, den: 50000)),
            (AVRational(num: 13250, den: 50000), AVRational(num: 34500, den: 50000)),
            (AVRational(num: 7500, den: 50000), AVRational(num: 3000, den: 50000))
        )
        display.pointee.white_point = (AVRational(num: 15635, den: 50000), AVRational(num: 16450, den: 50000))
        display.pointee.max_luminance = AVRational(num: 1000, den: 1)
        display.pointee.min_luminance = AVRational(num: 50, den: 10000)
        display.pointee.has_primaries = 1
        display.pointee.has_luminance = 1

        let fromStream = HDRMetadata(frame: raw)
        #expect(fromStream.contentLightLevel == HDRMetadata.ContentLightLevel(maxCLL: 1000, maxFALL: 400))
        #expect(fromStream.masteringDisplay.map { [UInt8]($0.payload) } == Self.fixtureMasteringDisplayPayload)
    }

    @Test("format description follows the metadata: new values and no values both rebuild it")
    func formatDescriptionFollowsMetadata() throws {
        let buffer = try Self.makeBuffer()
        var cache: CMVideoFormatDescription?
        func describe(_ metadata: HDRMetadata) throws -> CMVideoFormatDescription? {
            metadata.apply(to: buffer)
            let frame = VideoFrame(pixelBuffer: buffer, pts: 0, duration: 40_000, serial: 0, isHardwareDecoded: false)
            _ = try SampleBufferBuilder.video(from: frame, formatCache: &cache)
            return cache
        }
        func extensionBytes(_ description: CMVideoFormatDescription?, _ key: CFString) -> [UInt8]? {
            guard let description else { return nil }
            return (CMFormatDescriptionGetExtension(description, extensionKey: key) as? Data).map { [UInt8]($0) }
        }

        let first = HDRMetadata(masteringDisplay: nil, contentLightLevel: .init(maxCLL: 1000, maxFALL: 400))
        let described = try describe(first)
        #expect(extensionBytes(described, kCMFormatDescriptionExtension_ContentLightLevelInfo) == Self.fixtureContentLightPayload)

        let brighter = HDRMetadata(masteringDisplay: nil, contentLightLevel: .init(maxCLL: 4000, maxFALL: 400))
        let rebuilt = try describe(brighter)
        #expect(extensionBytes(rebuilt, kCMFormatDescriptionExtension_ContentLightLevelInfo) == [0x0F, 0xA0, 0x01, 0x90])

        let none = try describe(HDRMetadata())
        #expect(extensionBytes(none, kCMFormatDescriptionExtension_ContentLightLevelInfo) == nil,
                "a description must not keep metadata the frames no longer carry")
    }

    @Test("HDR10+ travels as a sample attachment")
    func hdr10PlusSampleAttachment() throws {
        let buffer = try Self.makeBuffer()
        var cache: CMVideoFormatDescription?
        let message = Data(Self.fixtureHDR10PlusMessage)
        let tagged = try SampleBufferBuilder.video(
            from: VideoFrame(pixelBuffer: buffer, pts: 0, duration: 40_000, serial: 0, isHardwareDecoded: false,
                             hdr10PlusMessage: message),
            formatCache: &cache
        )
        #expect(Self.sampleAttachment(tagged) == Self.fixtureHDR10PlusMessage)

        let untagged = try SampleBufferBuilder.video(
            from: VideoFrame(pixelBuffer: buffer, pts: 40_000, duration: 40_000, serial: 0, isHardwareDecoded: false),
            formatCache: &cache
        )
        #expect(Self.sampleAttachment(untagged) == nil)
    }

    // MARK: Decoded fixture

    private enum Path: String, CustomTestStringConvertible, CaseIterable {
        case hardware, software, deinterlaced
        var testDescription: String { rawValue }
    }

    @Test("every decode path delivers the stream's HDR10 and HDR10+ metadata", arguments: Path.allCases)
    private func decodedFixture(path: Path) async throws {
        if path == .hardware, !VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) { return }
        let frames = try await decode(
            try Fixtures.url("hdr10.mp4"),
            policy: path == .software ? .software : .videoToolbox,
            deinterlacing: path == .deinterlaced ? .init(mode: .always, rate: .frame) : .off
        )
        #expect(frames.count == 50)
        for frame in frames {
            if path == .hardware {
                #expect(frame.zeroCopy, "a progressive HEVC frame must stay a VideoToolbox surface")
            }
            if path == .deinterlaced {
                #expect(!frame.zeroCopy, "the filter writes its own buffers")
            }
            #expect(frame.masteringDisplay == Self.fixtureMasteringDisplayPayload)
            #expect(frame.contentLight == Self.fixtureContentLightPayload)
            #expect(frame.describedMasteringDisplay == Self.fixtureMasteringDisplayPayload)
            #expect(frame.describedContentLight == Self.fixtureContentLightPayload)
            #expect(frame.hdr10Plus == Self.fixtureHDR10PlusMessage)
        }
    }

    /// A real stream whose static metadata lives only in the container — the
    /// Matroska colour elements, stored as floats, which FFmpeg hands over as
    /// power-of-two rationals — with HDR10+ in the AV1 bitstream. Dolby Vision
    /// profile 10.1, so the base layer is HDR10 and stays unconverted. The
    /// sample is not redistributable and the test skips without it (see
    /// `DolbyVisionTests`).
    @Test(
        "container-level metadata reaches the buffers (local Dolby Vision profile 10 sample)",
        .enabled(if: FileManager.default.fileExists(atPath: Self.profile10Sample.path), "local sample missing"),
        .timeLimit(.minutes(2))
    )
    func containerLevelMetadata() async throws {
        let frames = try await decode(Self.profile10Sample, policy: .videoToolbox, deinterlacing: .off, limit: 4)
        #expect(frames.count == 4)
        for frame in frames {
            // P3-D65 primaries, 1000 cd/m² peak, 0.005 minimum: the same
            // monitor as the fixture's, so the same 24 bytes.
            #expect(frame.masteringDisplay == Self.fixtureMasteringDisplayPayload)
            #expect(frame.describedMasteringDisplay == Self.fixtureMasteringDisplayPayload)
            // MaxCLL 2010, MaxFALL 167.
            #expect(frame.contentLight == [0x07, 0xDA, 0x00, 0xA7])
            #expect(frame.hdr10Plus.map { Array($0.prefix(6)) } == HDR10Plus.t35Header)
        }
    }

    private static let profile10Sample = Fixtures.repoRoot.appendingPathComponent("TestStreams/DolbyVision/DVprofile10.mkv")

    private struct Decoded: Sendable {
        let zeroCopy: Bool
        let masteringDisplay: [UInt8]?
        let contentLight: [UInt8]?
        /// What the renderer's format description says, built the way the
        /// renderer builds it.
        let describedMasteringDisplay: [UInt8]?
        let describedContentLight: [UInt8]?
        /// The sample buffer's HDR10+ attachment.
        let hdr10Plus: [UInt8]?
    }

    /// Decodes a whole stream, or its first `limit` frames, and reports what
    /// the renderer would be handed.
    private func decode(
        _ url: URL,
        policy: VideoDecoder.HardwarePolicy,
        deinterlacing: VideoDecoder.Deinterlacing,
        limit: Int? = nil
    ) async throws -> [Decoded] {
        let demuxer = Demuxer(url: url.path)
        defer { demuxer.shutdown() }
        var demuxEvents = demuxer.events.makeAsyncIterator()
        demuxer.start()
        guard case .opened(let info)? = await demuxEvents.next() else {
            throw EngineError(code: .openFailed, message: "\(url.lastPathComponent) failed to open")
        }
        let track = try #require(info.videoTracks.first)
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))
        let packets = Channel<Packet>(capacity: 64)
        let frames = Channel<VideoFrame>(capacity: 16, measure: { $0.duration })
        demuxer.attach(channel: packets, toStream: track.index)

        let decoder = VideoDecoder(
            parameters: parameters, input: packets, output: frames,
            policy: policy, deinterlacing: deinterlacing
        )
        var decodeEvents = decoder.events.makeAsyncIterator()
        decoder.start()
        demuxer.resume()

        let collector = ChannelDrain(frames, into: (cache: CMVideoFormatDescription?.none, frames: [Decoded]())) { state, frame in
            if let limit, state.frames.count >= limit { return }
            let sample = try? SampleBufferBuilder.video(from: frame, formatCache: &state.cache)
            let description = sample.flatMap { CMSampleBufferGetFormatDescription($0) }
            func described(_ key: CFString) -> [UInt8]? {
                description.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: key) as? Data }.map { [UInt8]($0) }
            }
            state.frames.append(Decoded(
                zeroCopy: frame.isHardwareDecoded,
                masteringDisplay: Self.bytes(frame.pixelBuffer, kCVImageBufferMasteringDisplayColorVolumeKey),
                contentLight: Self.bytes(frame.pixelBuffer, kCVImageBufferContentLightLevelInfoKey),
                describedMasteringDisplay: described(kCMFormatDescriptionExtension_MasteringDisplayColorVolume),
                describedContentLight: described(kCMFormatDescriptionExtension_ContentLightLevelInfo),
                hdr10Plus: sample.flatMap(Self.sampleAttachment)
            ))
            // Stopping the decoder closes the frame channel, which ends the
            // drain — the local samples are long 4K files.
            if let limit, state.frames.count == limit { decoder.shutdown() }
        }
        if limit != nil {
            let decoded = await collector.value.frames
            decoder.shutdown()
            return decoded
        }

        // The whole file, then a drain: the deinterlacer holds a frame back
        // until end of stream.
        while let event = await demuxEvents.next() {
            if case .endOfStream = event {
                decoder.signalEndOfStream()
                break
            }
        }
        var reachedEndOfStream = false
        while let event = await decodeEvents.next() {
            if case .endOfStream = event { reachedEndOfStream = true; break }
            if case .failed = event { break }
        }
        decoder.shutdown() // closes the frame channel; the drain ends on that
        let decoded = await collector.value.frames
        #expect(reachedEndOfStream, "decoder never reached end of stream")
        return decoded
    }

    // MARK: Support

    private static func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, nil, &buffer)
        return try #require(status == kCVReturnSuccess ? buffer : nil)
    }

    private static func bytes(_ buffer: CVPixelBuffer, _ key: CFString) -> [UInt8]? {
        (CVBufferCopyAttachment(buffer, key, nil) as? Data).map { [UInt8]($0) }
    }

    private static func sampleAttachment(_ sample: CMSampleBuffer) -> [UInt8]? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]],
              let data = attachments.first?[kCMSampleAttachmentKey_HDR10PlusPerFrameData] as? Data
        else { return nil }
        return [UInt8](data)
    }
}
