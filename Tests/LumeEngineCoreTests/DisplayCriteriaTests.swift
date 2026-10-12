import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import LumeEngineCore

/// The display mode asked of the TV is what the engine outputs, not what the
/// container says: deinterlacing doubles the rate, Dolby Vision with an IPT
/// base layer leaves as HDR10. Getting it wrong is visible on every frame —
/// a 50p football match judders at 25 Hz; an HDR10 picture in Dolby Vision
/// mode, or the reverse, is mis-toned.
@Suite("ContentDisplayCriteria")
struct ContentDisplayCriteriaTests {
    private typealias Criteria = ContentDisplayCriteria

    private func resolve(
        _ stream: Criteria.Stream,
        deinterlacing: VideoDecoder.Deinterlacing = VideoDecoder.Deinterlacing(),
        output: Criteria.Output? = nil
    ) -> Criteria {
        Criteria.resolve(stream: stream, deinterlacing: deinterlacing, output: output)
    }

    private func broadcast(fps: Double = 25, interlaced: Bool? = true) -> Criteria.Stream {
        Criteria.Stream(codecName: "h264", width: 1920, height: 1080, frameRate: fps, isInterlaced: interlaced)
    }

    private func dolbyVision(profile: UInt8, compatibility: UInt8) -> Criteria.Stream {
        Criteria.Stream(
            codecName: "hevc", width: 3840, height: 2160, frameRate: 24000.0 / 1001,
            isInterlaced: false, colorTransfer: 16,
            dolbyVision: DolbyVisionConfiguration(profile: profile, level: 6, baseLayerCompatibilityID: compatibility)
        )
    }

    // MARK: Refresh rate

    @Test("1080i50 deinterlaced at field rate asks for 50 Hz, before the first frame")
    func interlacedFieldRateDoubles() {
        let criteria = resolve(broadcast())
        #expect(criteria.refreshRate == 50)
        #expect(criteria.basis == .stream)
    }

    @Test("frame-rate deinterlacing, or none, keeps the frame rate")
    func interlacedFrameRateKeeps() {
        #expect(resolve(broadcast(), deinterlacing: .init(mode: .auto, rate: .frame)).refreshRate == 25)
        #expect(resolve(broadcast(), deinterlacing: .off).refreshRate == 25)
    }

    @Test("a progressive or unflagged stream is not predicted to deinterlace; .always is")
    func deinterlacePrediction() {
        #expect(resolve(broadcast(interlaced: false)).refreshRate == 25)
        #expect(resolve(broadcast(interlaced: nil)).refreshRate == 25)
        #expect(resolve(broadcast(interlaced: false), deinterlacing: .init(mode: .always)).refreshRate == 50)
    }

    @Test("NTSC and film rates snap to their exact values, apart from their integer neighbours")
    func ntscRates() {
        let cases: [(Double, Double)] = [
            (23.976, 24000.0 / 1001), (24, 24), (25, 25),
            (29.97, 30000.0 / 1001), (30, 30), (50, 50),
            (59.94, 60000.0 / 1001), (60, 60),
            // Timestamp jitter around a grid rate.
            (25.04, 25), (59.95, 60000.0 / 1001), (23.98, 24000.0 / 1001), (23.995, 24),
        ]
        for (fps, expected) in cases {
            let rate = resolve(broadcast(fps: fps, interlaced: false)).refreshRate
            #expect(rate == expected, "\(fps) fps must ask for \(expected), got \(String(describing: rate))")
        }
        // 29.97i deinterlaced at field rate is 59.94p.
        #expect(resolve(broadcast(fps: 30000.0 / 1001)).refreshRate == 60000.0 / 1001)
    }

    @Test("unknown or off-grid rates ask for no rate at all")
    func unknownRates() {
        for fps in [0, -1, .nan, .infinity, 12.5, 15, 48, 25.5, 100, 120] {
            let rate = resolve(broadcast(fps: fps, interlaced: false)).refreshRate
            #expect(rate == nil, "\(fps) fps must not ask for a rate, got \(String(describing: rate))")
        }
    }

    @Test("the measured cadence of the output beats the container's guess")
    func outputCadenceWins() {
        // Field-coded H.264 can report its field rate; what comes out decides.
        let reportsFieldRate = broadcast(fps: 50, interlaced: true)
        let output = Criteria.Output(width: 1920, height: 1080, frameInterval: 20_000, isDeinterlacing: true)
        let criteria = resolve(reportsFieldRate, output: output)
        #expect(criteria.refreshRate == 50)
        #expect(criteria.basis == .output)

        // Interlaced in the container, progressive frames out: 25.
        let progressive = Criteria.Output(width: 1920, height: 1080, frameInterval: 40_000, isDeinterlacing: false)
        #expect(resolve(broadcast(), output: progressive).refreshRate == 25)
    }

    @Test("frames without a cadence yet: the decoder's deinterlacing state replaces the prediction")
    func outputWithoutCadence() {
        let flaggedLate = Criteria.Output(width: 1920, height: 1080, isDeinterlacing: true)
        let criteria = resolve(broadcast(interlaced: nil), output: flaggedLate)
        #expect(criteria.refreshRate == 50)
        #expect(criteria.basis == .stream, "a rate not yet measured is still a prediction")
    }

    // MARK: Dynamic range

    @Test("SDR, HDR10 and HLG from the stream's transfer characteristics")
    func streamRanges() {
        var stream = broadcast(interlaced: false)
        #expect(resolve(stream).dynamicRange == .sdr)
        stream.colorTransfer = 16
        #expect(resolve(stream).dynamicRange == .hdr10)
        stream.colorTransfer = 18
        #expect(resolve(stream).dynamicRange == .hlg)
    }

    @Test("the frames' transfer function beats the stream's")
    func outputRange() {
        let untagged = broadcast(interlaced: false)
        let pq = Criteria.Output(
            width: 3840, height: 2160,
            transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        )
        #expect(resolve(untagged, output: pq).dynamicRange == .hdr10)
        let hlg = Criteria.Output(
            width: 3840, height: 2160,
            transferFunction: kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
        )
        #expect(resolve(untagged, output: hlg).dynamicRange == .hlg)

        var taggedPQ = untagged
        taggedPQ.colorTransfer = 16
        let sdrFrames = Criteria.Output(
            width: 1920, height: 1080,
            transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2 as String
        )
        #expect(resolve(taggedPQ, output: sdrFrames).dynamicRange == .sdr)
    }

    @Test("Dolby Vision profile 5, 10.0 and 20 are converted, so they ask for HDR10")
    func iptProfilesAskForHDR10() {
        for profile: UInt8 in [5, 10, 20] {
            let criteria = resolve(dolbyVision(profile: profile, compatibility: 0))
            #expect(criteria.dynamicRange == .hdr10, "profile \(profile)")
            #expect(criteria.refreshRate == 24000.0 / 1001)
        }
    }

    @Test("Dolby Vision with a displayable base layer (8.1, 8.4, 10.1) stays Dolby Vision")
    func compatibleProfilesStayDolbyVision() {
        #expect(resolve(dolbyVision(profile: 8, compatibility: 1)).dynamicRange == .dolbyVision)
        #expect(resolve(dolbyVision(profile: 8, compatibility: 4)).dynamicRange == .dolbyVision)
        #expect(resolve(dolbyVision(profile: 10, compatibility: 1)).dynamicRange == .dolbyVision)
        // Even when its frames are tagged HDR10, which 8.1's base layer is.
        let pq = Criteria.Output(
            width: 3840, height: 2160,
            transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        )
        #expect(resolve(dolbyVision(profile: 8, compatibility: 1), output: pq).dynamicRange == .dolbyVision)
    }

    // MARK: Format description

    @Test("HDR10 converted from profile 5 is described as plain HEVC HDR10")
    func convertedFormatDescription() throws {
        let format = try #require(resolve(dolbyVision(profile: 5, compatibility: 0)).makeFormatDescription())
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        #expect(extensionString(format, kCMFormatDescriptionExtension_TransferFunction)
            == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        #expect(extensionString(format, kCMFormatDescriptionExtension_ColorPrimaries)
            == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        #expect(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) == nil)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        #expect(dimensions.width == 3840 && dimensions.height == 2160)
    }

    @Test("profile 8.1 is described as dvh1 with its dvvC record")
    func dolbyVisionFormatDescription() throws {
        let format = try #require(resolve(dolbyVision(profile: 8, compatibility: 1)).makeFormatDescription())
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_DolbyVisionHEVC)
        let atoms = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Data]
        let record = try #require(atoms?["dvvC"])
        // Version 1.0, profile 8, level 6, RPU + base layer, compatibility 1.
        #expect(Array(record) == [0x01, 0x00, 0x10, 0x35, 0x10] + [UInt8](repeating: 0, count: 19))
    }

    @Test("the record's box follows the profile: dvcC to 7, dvvC to 10, dvwC beyond")
    func dolbyVisionBoxType() {
        #expect(DolbyVisionConfiguration(profile: 7, level: 6, baseLayerCompatibilityID: 6).boxType == "dvcC")
        #expect(DolbyVisionConfiguration(profile: 10, level: 6, baseLayerCompatibilityID: 1).boxType == "dvvC")
        #expect(DolbyVisionConfiguration(profile: 20, level: 6, baseLayerCompatibilityID: 0).boxType == "dvwC")
    }

    @Test("SDR before the first frame is described as BT.709")
    func sdrFormatDescription() throws {
        let format = try #require(resolve(broadcast()).makeFormatDescription())
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
        #expect(extensionString(format, kCMFormatDescriptionExtension_TransferFunction)
            == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
    }

    @Test("asking twice for the same mode is recognised, whatever the basis")
    func sameMode() {
        let predicted = resolve(broadcast())
        let confirmed = resolve(broadcast(), output: .init(width: 1920, height: 1080, frameInterval: 20_000))
        #expect(predicted.asksForSameMode(as: confirmed))
        #expect(!predicted.asksForSameMode(as: resolve(broadcast(), deinterlacing: .off)))
        #expect(confirmed.description == "50Hz/sdr(output)")
    }

    private func extensionString(_ format: CMFormatDescription, _ key: CFString) -> String? {
        CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
    }
}

@Suite("FrameCadence")
struct FrameCadenceTests {
    @Test("needs a handful of intervals before it reports one")
    func needsSamples() {
        var cadence = FrameCadence()
        for frame in 0..<FrameCadence.minimumSamples {
            cadence.observe(pts: Int64(frame) * 40_000)
        }
        #expect(cadence.interval == nil, "\(FrameCadence.minimumSamples) frames are one interval short")
        cadence.observe(pts: Int64(FrameCadence.minimumSamples) * 40_000)
        #expect(cadence.interval == 40_000)
    }

    @Test("90 kHz timestamps rounded to µs still separate 59.94 from 60")
    func quantizedNTSC() {
        var cadence = FrameCadence()
        // 59.94 fps is 1501.5 ticks of 90 kHz: TS carries 1501 and 1502 alternately.
        var ticks: Int64 = 0
        for frame in 0..<64 {
            cadence.observe(pts: ticks * 1_000_000 / 90_000)
            ticks += frame.isMultiple(of: 2) ? 1501 : 1502
        }
        let interval = cadence.interval ?? 0
        let rate = ContentDisplayCriteria.nominalRefreshRate(for: 1_000_000 / interval)
        #expect(rate == 60000.0 / 1001, "measured \(1_000_000 / interval) fps")
    }

    @Test("dropouts, seams and a restart do not distort the cadence")
    func ignoresGaps() {
        var cadence = FrameCadence()
        var pts: Int64 = 0
        for frame in 0..<40 {
            cadence.observe(pts: pts)
            pts += frame == 20 ? 2_000_000 : 20_000 // one long dropout
        }
        cadence.observe(pts: 0) // a seam backwards
        cadence.restart()
        cadence.observe(pts: 90_000_000) // after a seek: no interval to the old frame
        cadence.observe(pts: 90_020_000)
        cadence.observe(pts: 90_060_000) // one dropped frame
        #expect(cadence.interval == 20_000)
    }
}

/// The same, end to end: real fixtures through a real session.
@Suite("Display criteria (pipeline)", .serialized)
struct DisplayCriteriaPipelineTests {
    private func session(deinterlacing: VideoDecoder.Deinterlacing = .init()) -> PlayerSession {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.5
        configuration.deinterlace = deinterlacing
        return PlayerSession(configuration: configuration)
    }

    /// Polls until the session's criteria are confirmed by its output.
    private func confirmedCriteria(_ session: PlayerSession, timeout: TimeInterval = 10) async -> ContentDisplayCriteria? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if let criteria = await session.displayCriteria, criteria.basis == .output { return criteria }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    @Test("the interlaced fixture asks for 50 Hz SDR, predicted at open and confirmed by its frames", .timeLimit(.minutes(1)))
    func interlacedFieldRate() async throws {
        let session = session()
        let info = try await session.open(url: try Fixtures.path("interlaced.ts"))
        #expect(info.videoTracks.first?.video?.isInterlaced == true)
        let predicted = await session.displayCriteria
        #expect(predicted?.refreshRate == 50, "predicted \(String(describing: predicted))")

        await session.play()
        let confirmed = await confirmedCriteria(session)
        #expect(confirmed?.refreshRate == 50, "confirmed \(String(describing: confirmed))")
        #expect(confirmed?.dynamicRange == .sdr)
        #expect(await session.diagnostics.description.contains("display=50Hz/sdr(output)"))
        await session.shutdown()
    }

    @Test("deinterlacing at frame rate keeps the fixture at 25 Hz", .timeLimit(.minutes(1)))
    func interlacedFrameRate() async throws {
        let session = session(deinterlacing: .init(mode: .auto, rate: .frame))
        _ = try await session.open(url: try Fixtures.path("interlaced.ts"))
        await session.play()
        let confirmed = await confirmedCriteria(session)
        #expect(confirmed?.refreshRate == 25, "confirmed \(String(describing: confirmed))")
        await session.shutdown()
    }

    @Test("a progressive 30 fps file asks for 30 Hz", .timeLimit(.minutes(1)))
    func progressive() async throws {
        let session = session()
        let info = try await session.open(url: try Fixtures.path("basic.mp4"))
        #expect(info.videoTracks.first?.video?.isInterlaced != true)
        await session.play()
        let confirmed = await confirmedCriteria(session)
        #expect(confirmed?.refreshRate == 30, "confirmed \(String(describing: confirmed))")
        await session.shutdown()
    }

    @Test("an audio-only source has no display criteria", .timeLimit(.minutes(1)))
    func audioOnly() async throws {
        let session = session()
        _ = try await session.open(url: try Fixtures.path("surround71.mkv"))
        #expect(await session.displayCriteria == nil)
        await session.shutdown()
    }
}

/// The start hold a host uses to sit out a display mode switch: the clock
/// must not start into a blank TV, and must start by itself once the bound
/// passes, whatever the host does.
@Suite("Start hold", .serialized)
struct StartHoldTests {
    private func makeSession(stallThreshold: Double = 8) -> PlayerSession {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.5
        configuration.stallThreshold = stallThreshold
        return PlayerSession(configuration: configuration)
    }

    private func eventually(timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test("a held session buffers and waits; releasing starts it", .timeLimit(.minutes(1)))
    func holdThenRelease() async throws {
        // A short stall threshold: waiting while held must not read as a stall.
        let session = makeSession(stallThreshold: 1)
        var events = session.events.makeAsyncIterator()
        _ = try await session.open(url: try Fixtures.path("basic.mp4"))
        await session.holdStart(for: 20)
        await session.play()

        try await Task.sleep(for: .seconds(2))
        #expect(await session.state == .buffering)
        #expect(await session.isStartHeld)
        #expect(await session.position == 0)

        await session.releaseStartHold()
        #expect(await eventually { await session.state == .playing })
        await session.shutdown()

        var stalled = false
        while let event = await events.next() {
            if case .stalled = event { stalled = true }
        }
        #expect(!stalled, "a held start is not a stall")
    }

    @Test("the hold runs out by itself", .timeLimit(.minutes(1)))
    func holdExpires() async throws {
        let session = makeSession()
        _ = try await session.open(url: try Fixtures.path("basic.mp4"))
        await session.holdStart(for: 1)
        await session.play()
        #expect(await session.state != .playing)
        #expect(await eventually { await session.state == .playing })
        #expect(await !session.isStartHeld)
        await session.shutdown()
    }
}
