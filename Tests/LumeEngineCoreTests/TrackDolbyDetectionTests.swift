import Foundation
import Testing
@testable import LumeEngineCore

/// Detection-only coverage for the Dolby fields on `TrackInfo` (issue #207
/// round 1). These assert what the *container* declares — nothing here changes
/// decode, render or audio behaviour.
@Suite("Dolby detection", .serialized)
struct TrackDolbyDetectionTests {
    /// Opens a fixture and returns its `MediaInfo`.
    private func mediaInfo(_ fixture: String) async throws -> MediaInfo {
        let demuxer = Demuxer(url: try Fixtures.path(fixture))
        defer { _ = demuxer.shutdown() }
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()

        let deadline = Date(timeIntervalSinceNow: 10)
        while Date() < deadline {
            guard let event = await events.next() else { continue }
            if case .opened(let info) = event { return info }
        }
        throw NSError(
            domain: "TrackDolbyDetectionTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(fixture) never reported .opened"]
        )
    }

    // MARK: Video colour + Dolby Vision

    @Test("plain H.264 declares no Dolby Vision and stays SDR")
    func noDolbyVisionOnSDR() async throws {
        let info = try await mediaInfo("basic.mp4")
        let video = try #require(info.videoTracks.first?.video)
        #expect(video.dolbyVision == nil)
        #expect(!video.isHDR, "an untagged BT.709 stream must not be reported as HDR")
        #expect(video.bitDepth == 8)
        // basic.mp4 tags nothing, so all three read AVCOL_*_UNSPECIFIED (2).
        // Reporting that verbatim is the contract: the value a later round must
        // translate into *no attachment at all* rather than a guessed default.
        #expect(video.colorPrimaries == 2, "AVCOL_PRI_UNSPECIFIED")
        #expect(video.colorTransfer == 2, "AVCOL_TRC_UNSPECIFIED")
        #expect(video.colorSpace == 2, "AVCOL_SPC_UNSPECIFIED")
    }

    @Test("HDR10 signalling is read off the container")
    func hdr10SignallingIsDetected() async throws {
        // The stream this whole round exists to describe: BT.2020 primaries,
        // SMPTE ST 2084 (PQ) transfer, BT.2020 non-constant-luminance matrix,
        // 10-bit, plus a mastering-display SEI.
        let info = try await mediaInfo("hdr10.mp4")
        let track = try #require(info.videoTracks.first)
        #expect(track.codecName == "hevc")
        let video = try #require(track.video)

        #expect(video.isHDR)
        #expect(video.bitDepth == 10)
        #expect(video.pixelFormatName == "yuv420p10le")
        // Raw AVCOL_* numbers: `CFFmpeg` is an `internal import`, so the enum
        // names are deliberately not visible from the test target. These three
        // values *are* HDR10 signalling.
        #expect(video.colorPrimaries == 9, "AVCOL_PRI_BT2020")
        #expect(video.colorTransfer == 16, "AVCOL_TRC_SMPTE2084")
        #expect(video.colorSpace == 9, "AVCOL_SPC_BT2020_NCL")
        #expect(!video.colorRangeFull, "video-range, as broadcast HDR10 is")

        // No Dolby Vision record is invented for plain HDR10. Profile 8.1's
        // base layer *is* HDR10, so conflating the two would make every HDR10
        // stream report as Dolby Vision.
        #expect(video.dolbyVision == nil)
    }

    // MARK: Object audio

    @Test("TrueHD without the Atmos profile is not object audio")
    func trueHDWithoutAtmos() async throws {
        let info = try await mediaInfo("truehd.mkv")
        let track = try #require(info.audioTracks.first)
        #expect(track.codecName == "truehd")
        let audio = try #require(track.audio)
        #expect(
            !audio.isObjectAudio,
            "profile was \(audio.profile); only AV_PROFILE_TRUEHD_ATMOS counts"
        )
        #expect(audio.channels == 6)
        #expect(audio.channelLayoutName == "5.1(side)")
    }

    @Test("a non-Dolby codec never trips the Atmos profile comparison")
    func atmosComparisonIsCodecGated() async throws {
        // AV_PROFILE_EAC3_DDP_ATMOS and AV_PROFILE_TRUEHD_ATMOS are both 30
        // and mean nothing for FLAC — hence the codec gate. FFmpeg reports
        // AV_PROFILE_UNKNOWN here, so this covers the fixture-reachable half;
        // `objectAudioGate` below covers a profile that really is 30.
        let info = try await mediaInfo("surround71.mkv")
        let track = try #require(info.audioTracks.first)
        #expect(track.codecName == "flac")
        let audio = try #require(track.audio)
        #expect(!audio.isObjectAudio)
        #expect(audio.channelLayoutName == "7.1")
    }

    @Test("the object-audio label describes the source, not the output", .timeLimit(.minutes(1)))
    func objectAudioLabelIsSourceSideOnly() async throws {
        // Decision, not accident (PLAN.md §7): the engine decodes Dolby audio
        // to its channel bed and never bitstreams it. So the source-side
        // description must survive a decode that narrows the output — a
        // 5.1 TrueHD track played out to a stereo route still reports 6
        // channels / 5.1(side) / codec truehd, because that is what the
        // *stream* is. If a later round ever adds a passthrough lane, this is
        // the assertion that says the label was never derived from the output.
        let demuxer = Demuxer(url: try Fixtures.path("truehd.mkv"))
        defer { demuxer.shutdown() }
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()
        guard case .opened(let info)? = await events.next() else {
            Issue.record("truehd.mkv failed to open")
            return
        }

        let track = try #require(info.audioTracks.first)
        let source = try #require(track.audio)
        let parameters = try #require(demuxer.codecParameters(forStream: track.index))

        let packets = Channel<Packet>(capacity: 256)
        let frames = Channel<AudioFrame>(capacity: 256, measure: { $0.duration })
        demuxer.attach(channel: packets, toStream: track.index)
        let decoder = AudioDecoder(
            parameters: parameters, input: packets, output: frames, maxOutputChannels: 2
        )
        decoder.start()
        demuxer.resume()
        defer { decoder.shutdown() }

        let frame = try #require(frames.receive(timeout: 10), "no PCM decoded from truehd.mkv")
        #expect(frame.channels == 2, "the output was narrowed, as the route asked")
        #expect(source.channels == 6)
        #expect(source.channelLayoutName == "5.1(side)")
        #expect(!source.isObjectAudio)
    }

    // MARK: The codec gate itself
    //
    // No generatable fixture can cover this: ffmpeg's encoders cannot produce
    // an Atmos-profile E-AC-3/TrueHD stream (the positive cases) and cannot
    // produce a non-Dolby track whose profile is 30 either — its `dca` encoder
    // writes plain DTS (profile 20), never DTS-ES (30). So the gate is
    // asserted directly, which is also the only way to state the collision
    // this code exists to survive.

    @Test("Atmos profiles count only for the two codecs that can carry Atmos")
    func objectAudioGate() {
        // 30 == AV_PROFILE_EAC3_DDP_ATMOS == AV_PROFILE_TRUEHD_ATMOS.
        #expect(TrackInfo.declaresObjectAudio(codecName: "eac3", profile: 30))
        #expect(TrackInfo.declaresObjectAudio(codecName: "truehd", profile: 30))

        // The negative case that matters: the same number 30 on a codec that
        // has nothing to do with Dolby. DTS-ES really is profile 30.
        #expect(!TrackInfo.declaresObjectAudio(codecName: "dts", profile: 30))
        #expect(!TrackInfo.declaresObjectAudio(codecName: "flac", profile: 30))
        #expect(!TrackInfo.declaresObjectAudio(codecName: "aac", profile: 30))
        #expect(!TrackInfo.declaresObjectAudio(codecName: "ac3", profile: 30))

        // And a Dolby codec on any other profile is plain channel audio:
        // AV_PROFILE_UNKNOWN (-99) is what an un-probed track reports, and 20
        // is DTS's own value, which must not leak across the gate either.
        #expect(!TrackInfo.declaresObjectAudio(codecName: "eac3", profile: -99))
        #expect(!TrackInfo.declaresObjectAudio(codecName: "eac3", profile: 0))
        #expect(!TrackInfo.declaresObjectAudio(codecName: "truehd", profile: -99))
        #expect(!TrackInfo.declaresObjectAudio(codecName: "truehd", profile: 20))
    }
}
