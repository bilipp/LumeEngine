import CFFmpeg
import CoreVideo
import Foundation
import Testing
@testable import LumeEngineCore

/// Which Dolby Vision frames are IPT and get converted. The failure this
/// guards against is the quiet one: a stream whose configuration record says
/// profile 5 while its frames are plain HDR10 — a mislabelled remux, or a
/// broadcast that dropped the RPUs — converted as IPT, so correct HDR10 comes
/// out in wrong colours.
@Suite("Dolby Vision detection", .serialized)
struct DolbyVisionDetectionTests {
    typealias Detection = DolbyVisionDetection

    private static let profile5 = Detection.Record(profile: 5, compatibilityID: 0)
    private static let profile81 = Detection.Record(profile: 8, compatibilityID: 1)

    // MARK: Decision

    private struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let record: Detection.Record?
        let matrix: Detection.Matrix
        let rpu: Detection.RPU
        let ipt: Bool
        var testDescription: String { name }
    }

    private static let cases: [Case] = [
        // Genuine IPT.
        Case(name: "P5 with its RPU, VUI matrix unspecified", record: profile5, matrix: .unspecified,
             rpu: .own(signalColorSpace: 2), ipt: true),
        Case(name: "P5 frame whose RPU was lost: the record covers an untagged frame", record: profile5,
             matrix: .unspecified, rpu: .carriedOver, ipt: true),
        Case(name: "tagged IPT-C2 is IPT even without an RPU of its own", record: nil, matrix: .iptC2,
             rpu: .carriedOver, ipt: true),
        Case(name: "an RPU that says IPT outweighs a missing record", record: nil, matrix: .stated,
             rpu: .own(signalColorSpace: 2), ipt: true),
        Case(name: "an RPU that says IPT outweighs a record that says HDR10", record: profile81, matrix: .unspecified,
             rpu: .own(signalColorSpace: 2), ipt: true),
        // Displayable, whatever the record claims.
        Case(name: "P5 record over an RPU that says YCbCr (mislabelled remux)", record: profile5, matrix: .stated,
             rpu: .own(signalColorSpace: 0), ipt: false),
        Case(name: "P5 record over an RPU that says YCbCr, untagged", record: profile5, matrix: .unspecified,
             rpu: .own(signalColorSpace: 0), ipt: false),
        Case(name: "P5 record, BT.2020 frame, RPUs dropped: HDR10", record: profile5, matrix: .stated,
             rpu: .carriedOver, ipt: false),
        Case(name: "P5 record, no Dolby Vision metadata at all", record: profile5, matrix: .unspecified,
             rpu: .none, ipt: false),
        Case(name: "tagged IPT-C2 but nothing to convert with", record: profile5, matrix: .iptC2,
             rpu: .none, ipt: false),
        Case(name: "profile 8.1 stays on the zero-copy path", record: profile81, matrix: .stated,
             rpu: .own(signalColorSpace: 0), ipt: false),
        Case(name: "no record, untagged, carried-over metadata", record: nil, matrix: .unspecified,
             rpu: .carriedOver, ipt: false),
        Case(name: "an RGB signal is not IPT", record: profile5, matrix: .unspecified,
             rpu: .own(signalColorSpace: 1), ipt: false),
    ]

    @Test("per-frame decision", arguments: cases)
    private func decision(_ testCase: Case) {
        let ipt = Detection.baseLayerIsIPT(record: testCase.record, matrix: testCase.matrix, rpu: testCase.rpu)
        #expect(ipt == testCase.ipt)
    }

    @Test("record: only profiles 5, 10.0 and 20 claim an IPT base layer")
    func recordClaims() {
        #expect(Detection.Record(profile: 5, compatibilityID: 0).claimsIPT)
        #expect(Detection.Record(profile: 10, compatibilityID: 0).claimsIPT)
        #expect(Detection.Record(profile: 20, compatibilityID: 0).claimsIPT)
        #expect(!Detection.Record(profile: 10, compatibilityID: 1).claimsIPT)
        #expect(!Detection.Record(profile: 8, compatibilityID: 1).claimsIPT)
        // Profile 4: compatibility ID 0, but an SDR base layer.
        #expect(!Detection.Record(profile: 4, compatibilityID: 0).claimsIPT)
    }

    @Test("matrix: IPT-C2, open, or stated")
    func matrices() {
        #expect(Detection.Matrix(AVCOL_SPC_IPT_C2) == .iptC2)
        #expect(Detection.Matrix(AVCOL_SPC_UNSPECIFIED) == .unspecified)
        #expect(Detection.Matrix(AVCOL_SPC_RESERVED) == .unspecified)
        #expect(Detection.Matrix(AVCOL_SPC_BT2020_NCL) == .stated)
        #expect(Detection.Matrix(AVCOL_SPC_BT709) == .stated)
    }

    // MARK: RPU evidence from frames

    @Test("RPU: own only with the raw RPU on HEVC; always own on AV1")
    func rpuClassification() throws {
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let raw = try #require(frame)
        #expect(Detection.RPU(frame: raw, codecID: AV_CODEC_ID_HEVC) == .none)

        // Parsed metadata, as FFmpeg's HEVC decoder attaches to every frame
        // after an RPU, saying IPT.
        var size = 0
        let metadata = try #require(av_dovi_metadata_alloc(&size))
        try #require(av_dovi_get_color(metadata)).pointee.signal_color_space = 2
        let buffer = try #require(av_buffer_create(
            UnsafeMutableRawPointer(metadata).assumingMemoryBound(to: UInt8.self), size, nil, nil, 0
        ))
        #expect(av_frame_new_side_data_from_buf(raw, AV_FRAME_DATA_DOVI_METADATA, buffer) != nil)

        #expect(Detection.RPU(frame: raw, codecID: AV_CODEC_ID_HEVC) == .carriedOver,
                "HEVC metadata without the frame's own RPU is a previous frame's")
        #expect(Detection.RPU(frame: raw, codecID: AV_CODEC_ID_AV1) == .own(signalColorSpace: 2),
                "AV1 metadata is attached only to the frame that carried it")

        // The raw RPU, attached only to the access unit that carried one.
        #expect(av_frame_new_side_data(raw, AV_FRAME_DATA_DOVI_RPU_BUFFER, 16) != nil)
        #expect(Detection.RPU(frame: raw, codecID: AV_CODEC_ID_HEVC) == .own(signalColorSpace: 2))
    }

    // MARK: Real streams (local only)

    private static func sample(_ name: String) -> URL {
        Fixtures.repoRoot.appendingPathComponent("TestStreams/DolbyVision/\(name)")
    }

    private static func hasSample(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: sample(name).path)
    }

    /// The field the decision rests on, read from real RPUs: profile 20's
    /// base layer is IPT, profile 8.1's and 10.1's are HDR10, profile 4's SDR.
    @Test(
        "real RPUs state their signal's colour space",
        .enabled(if: hasSample("DV8_TEST.mp4") || hasSample("DVprofile20.mp4"), "local Dolby Vision samples missing"),
        .timeLimit(.minutes(2)),
        arguments: [
            ("DVprofile20.mp4", UInt8(2)),
            ("DV8_TEST.mp4", UInt8(0)),
            ("DVprofile10.mkv", UInt8(0)),
            ("LG Demo DolbyVision Comparison.mkv", UInt8(0)),
        ]
    )
    func realRPUs(name: String, signalColorSpace: UInt8) throws {
        guard Self.hasSample(name) else { return }
        let observed = try Self.firstFramesRPU(Self.sample(name), count: 3)
        #expect(observed == Array(repeating: .own(signalColorSpace: signalColorSpace), count: 3))
    }

    /// The regression itself, on a real stream: profile 8.1 — an HDR10 base
    /// layer with RPUs that say so — under a configuration record rewritten
    /// to claim profile 5. The record used to decide on its own and send every
    /// frame through the IPT conversion.
    @Test(
        "an HDR10 stream labelled profile 5 is not converted",
        .enabled(if: hasSample("DV8_TEST.mp4"), "local Dolby Vision sample missing"),
        .timeLimit(.minutes(2)),
        arguments: [VideoDecoder.HardwarePolicy.videoToolbox, .software]
    )
    func mislabelledProfile5(policy: VideoDecoder.HardwarePolicy) async throws {
        let frames = try await decodeFirstFrames(
            Self.sample("DV8_TEST.mp4"), count: 6, policy: policy,
            record: Detection.Record(profile: 5, compatibilityID: 0)
        )
        #expect(frames.count == 6)
        for frame in frames {
            #expect(!frame.converting, "the RPU says YCbCr; the record's profile 5 is wrong")
            #expect(frame.zeroCopy == (policy == .videoToolbox), "HDR10 stays on the zero-copy path")
            #expect(frame.matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
        }
    }

    // MARK: Support

    /// Decodes the first frames straight through FFmpeg — software, no engine
    /// in between — and classifies each one's RPU.
    private static func firstFramesRPU(_ url: URL, count: Int) throws -> [Detection.RPU] {
        var format: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&format, url.path, nil, nil) >= 0, let format else {
            throw EngineError(code: .openFailed, message: "\(url.lastPathComponent) failed to open")
        }
        defer {
            var pointer: UnsafeMutablePointer<AVFormatContext>? = format
            avformat_close_input(&pointer)
        }
        guard avformat_find_stream_info(format, nil) >= 0 else {
            throw EngineError(code: .openFailed, message: "no stream info")
        }
        let index = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        let stream = try #require(index >= 0 ? format.pointee.streams[Int(index)] : nil)
        let parameters = try #require(stream.pointee.codecpar)
        let codecID = parameters.pointee.codec_id
        let codec = try #require(VideoDecoder.decoder(for: codecID, hardware: false))
        var context: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&context) }
        let decoder = try #require(context)
        #expect(avcodec_parameters_to_context(decoder, parameters) >= 0)
        #expect(avcodec_open2(decoder, codec, nil) >= 0)

        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer {
            av_packet_free(&packet)
            av_frame_free(&frame)
        }
        let pkt = try #require(packet)
        let frm = try #require(frame)
        var observed: [Detection.RPU] = []
        while observed.count < count, av_read_frame(format, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard pkt.pointee.stream_index == index else { continue }
            guard avcodec_send_packet(decoder, pkt) >= 0 else { continue }
            while observed.count < count, avcodec_receive_frame(decoder, frm) >= 0 {
                observed.append(Detection.RPU(frame: frm, codecID: codecID))
                av_frame_unref(frm)
            }
        }
        return observed
    }

    private struct DecodedFrame: Sendable {
        let zeroCopy: Bool
        let converting: Bool
        let matrix: String?
    }

    /// Like `DolbyVisionTests`' helper, with the stream's configuration
    /// record replaced before the decoder sees it.
    private func decodeFirstFrames(
        _ url: URL,
        count: Int,
        policy: VideoDecoder.HardwarePolicy,
        record: Detection.Record
    ) async throws -> [DecodedFrame] {
        let demuxer = Demuxer(url: url.path)
        defer { demuxer.shutdown() }
        var demuxEvents = demuxer.events.makeAsyncIterator()
        demuxer.start()
        guard case .opened(let info)? = await demuxEvents.next() else {
            throw EngineError(code: .openFailed, message: "\(url.lastPathComponent) failed to open")
        }

        let track = try #require(info.videoTracks.first)
        let original = try #require(demuxer.codecParameters(forStream: track.index))
        let parameters = try #require(CodecParameters(copying: original.raw))
        try Self.rewriteRecord(of: parameters, to: record)
        #expect(Detection.Record(parameters.raw) == record)

        let packets = Channel<Packet>(capacity: 64)
        let frames = Channel<VideoFrame>(capacity: 4, measure: { $0.duration })
        demuxer.attach(channel: packets, toStream: track.index)

        let decoder = VideoDecoder(parameters: parameters, input: packets, output: frames, policy: policy)
        decoder.start()
        demuxer.resume()

        let collector = ChannelDrain(frames, into: [DecodedFrame]()) { collected, frame in
            guard collected.count < count else { return }
            collected.append(DecodedFrame(
                zeroCopy: frame.isHardwareDecoded,
                converting: decoder.isConvertingDolbyVision,
                matrix: CVBufferCopyAttachment(frame.pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
            ))
            if collected.count == count { decoder.shutdown() }
        }
        let result = await collector.value
        decoder.shutdown()
        return result
    }

    private static func rewriteRecord(of parameters: CodecParameters, to record: Detection.Record) throws {
        let sideData = try #require(av_packet_side_data_get(
            parameters.raw.pointee.coded_side_data,
            parameters.raw.pointee.nb_coded_side_data,
            AV_PKT_DATA_DOVI_CONF
        ))
        let bytes = try #require(sideData.pointee.data)
        try #require(sideData.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size)
        let raw = UnsafeMutableRawPointer(bytes)
        var configuration = raw.loadUnaligned(as: AVDOVIDecoderConfigurationRecord.self)
        configuration.dv_profile = record.profile
        configuration.dv_bl_signal_compatibility_id = record.compatibilityID
        raw.storeBytes(of: configuration, as: AVDOVIDecoderConfigurationRecord.self)
    }
}
