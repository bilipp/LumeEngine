import CFFmpeg
import Foundation
import Testing
@testable import LumeEngineCore

/// CEA-608 caption data as a broadcast encoder writes it: one byte pair for
/// CC1 per frame, null padding on every frame without one. Mirrors the
/// caption script in `generate-fixtures.sh`.
private enum CaptionScript {
    static let frameDuration: Int64 = 1_000_000 / 30

    static func oddParity(_ value: UInt8) -> UInt8 {
        let bits = value & 0x7F
        return bits.nonzeroBitCount % 2 == 0 ? bits | 0x80 : bits
    }

    /// Byte pairs per frame index for two pop-on captions (shown at frames
    /// 30 and 120, erased at 90 and 180 — 1–3 s and 4–6 s at 30 fps).
    static let pairs: [Int: (UInt8, UInt8)] = {
        var script: [Int: (UInt8, UInt8)] = [:]
        func popOn(load: Int, _ text: String, show: Int, clear: Int) {
            var pairs: [(UInt8, UInt8)] = [(0x14, 0x20), (0x14, 0x70)] // load, row 15
            let bytes = Array(text.utf8)
            for index in stride(from: 0, to: bytes.count, by: 2) {
                pairs.append((bytes[index], index + 1 < bytes.count ? bytes[index + 1] : 0))
            }
            for (offset, pair) in pairs.enumerated() { script[load + offset] = pair }
            script[show] = (0x14, 0x2F)  // end of caption
            script[clear] = (0x14, 0x2C) // erase displayed memory
        }
        popOn(load: 5, "HELLO CAPTIONS", show: 30, clear: 90)
        popOn(load: 100, "SECOND CAPTION", show: 120, clear: 180)
        return script
    }()

    /// The A/53 `cc_data` triples of one frame: CC1 data, field-2 nulls.
    static func ccData(frame: Int) -> [UInt8] {
        let (first, second) = pairs[frame] ?? (0, 0)
        return [0xFC, oddParity(first), oddParity(second), 0xFD, 0x80, 0x80]
    }
}

@Suite("Closed captions")
struct ClosedCaptionTests {
    @Test("caption detection ignores null padding, field 2 and invalid triples")
    func detection() {
        func carries(_ bytes: [UInt8]) -> Bool {
            bytes.withUnsafeBytes { ClosedCaptionData.carriesCaptions($0) }
        }
        #expect(!carries([0xFC, 0x80, 0x80, 0xFD, 0x80, 0x80]), "null padding on both fields")
        #expect(!carries([0xFD, 0x14, 0x20]), "field 2 (CC3/XDS)")
        #expect(!carries([0xF8, 0x14, 0x20]), "cc_valid not set")
        #expect(!carries([0xFE, 0x41, 0x42]), "DTVCC packet data")
        #expect(carries([0xFD, 0x80, 0x80, 0xFC, 0x94, 0x20]), "CC1 control code")
        #expect(!carries([0xFC, 0x94]), "truncated triple")
    }

    /// The decoder runs FFmpeg's caption decoder in real-time mode, which
    /// stamps an update with the time of the one before; the cue has to start
    /// on the frame that put the caption on screen and end on the frame that
    /// erased it, or captions drift from the speech they transcribe.
    @Test("caption packets become cues on their frames' timestamps", .timeLimit(.minutes(1)))
    func decodeCaptionPackets() throws {
        let parameters = try #require(CodecParameters.closedCaptions())
        let packets = Channel<Packet>(capacity: 512)
        let store = SubtitleStore()
        let decoder = SubtitleDecoder(
            parameters: parameters, input: packets, store: store, codecOptions: ["data_field": "first"]
        )
        decoder.start()

        let origin: Int64 = 50_000_000
        for frame in 0..<240 {
            let bytes = CaptionScript.ccData(frame: frame)
            let packet = try #require(bytes.withUnsafeBytes {
                Packet(copying: $0, pts: origin + Int64(frame) * CaptionScript.frameDuration, serial: 0)
            })
            try packets.send(packet)
        }
        #expect(decoder.drainAndShutdown())

        func time(frame: Int) -> Int64 { origin + Int64(frame) * CaptionScript.frameDuration }
        #expect(store.count == 2)
        let first = store.activeCues(at: time(frame: 30))
        #expect(first.map(\.text) == ["HELLO CAPTIONS"])
        #expect(first.first?.start == time(frame: 30))
        #expect(first.first?.end == time(frame: 90))
        #expect(store.activeCues(at: time(frame: 29)).isEmpty)
        #expect(store.activeCues(at: time(frame: 90)).isEmpty)
        #expect(store.activeCues(at: time(frame: 150)).map(\.text) == ["SECOND CAPTION"])
        #expect(store.activeCues(at: time(frame: 200)).isEmpty)
    }

    @Test("the tap detects captions and forwards them stamped with the frame's PTS")
    func tapForwardsSideData() throws {
        let tap = ClosedCaptionTap()
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let raw = try #require(frame)

        // No side data: nothing detected, nothing forwarded.
        let sink = Channel<Packet>(capacity: 4)
        tap.attach(sink)
        tap.offer(raw, serial: 3)
        #expect(!tap.hasDetectedCaptions)
        #expect(sink.tryReceive() == nil)

        func attach(_ bytes: [UInt8]) throws {
            av_frame_remove_side_data(raw, AV_FRAME_DATA_A53_CC)
            let sideData = try #require(av_frame_new_side_data(raw, AV_FRAME_DATA_A53_CC, bytes.count))
            sideData.pointee.data.update(from: bytes, count: bytes.count)
        }

        // Padding only: forwarded (the decoder needs the frame cadence), but
        // no caption track to offer yet.
        raw.pointee.best_effort_timestamp = 7_000_000
        try attach(CaptionScript.ccData(frame: 0))
        tap.offer(raw, serial: 3)
        #expect(!tap.hasDetectedCaptions)
        let padding = try #require(sink.tryReceive())
        #expect(padding.pts == 7_000_000)
        #expect(padding.serial == 3)
        #expect(padding.byteCount == 6)

        raw.pointee.best_effort_timestamp = 7_033_333
        try attach(CaptionScript.ccData(frame: 5))
        tap.offer(raw, serial: 3)
        #expect(tap.hasDetectedCaptions)
        #expect(sink.tryReceive()?.pts == 7_033_333)

        // Detached: detection stays, forwarding stops.
        tap.attach(nil)
        tap.offer(raw, serial: 3)
        #expect(tap.hasDetectedCaptions)
        #expect(sink.tryReceive() == nil)
    }
}

@Suite("Closed captions in playback", .serialized)
struct ClosedCaptionPlaybackTests {
    private func eventually(
        timeout: TimeInterval = 10,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func makeSession(hardware: Bool) -> PlayerSession {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.3
        configuration.hardwareDecode = hardware ? .videoToolbox : .software
        return PlayerSession(configuration: configuration)
    }

    /// End to end: SEI in an H.264 TS → frame side data (VideoToolbox frames
    /// carry it too: FFmpeg parses SEI itself) → caption lane → cues on the
    /// video's timestamps. Seeks back to 0 after selecting so the first
    /// caption is decoded again rather than raced against the decode lead.
    @Test(
        "captions in the video surface as a CC track and decode in sync",
        .timeLimit(.minutes(1)),
        arguments: [true, false]
    )
    func captionsFromVideo(hardware: Bool) async throws {
        let session = makeSession(hardware: hardware)
        let info = try await session.open(url: try Fixtures.path("captions.ts"))
        let listedAtOpen = info.tracks.contains(where: \.isEmbeddedClosedCaptions)
        #expect(!listedAtOpen, "unknown at open")

        let offered = await eventually {
            await session.mediaInfo?.subtitleTracks.contains(where: \.isEmbeddedClosedCaptions) == true
        }
        #expect(offered, "the CC track should appear once captions are decoded")

        await session.selectSubtitleTrack(TrackInfo.embeddedClosedCaptionsIndex)
        #expect(await session.selectedSubtitleTrackIndex == TrackInfo.embeddedClosedCaptionsIndex)
        await session.seek(to: 0)
        await session.play()

        // Done once the second caption has been erased again. Not a cue
        // count: what was decoded before the seek joined the first caption
        // halfway through loading and may have left a fragment of its own.
        let start = info.startTime
        let frame: Int64 = 1_000_000 / 30
        let sawBoth = await eventually(timeout: 30) {
            let second = session.subtitles.activeCues(at: start + 5_000_000)
            return second.map(\.text) == ["SECOND CAPTION"] && second.allSatisfy { $0.end <= start + 6_000_000 + frame }
        }
        #expect(sawBoth, "both captions should decode, store has \(session.subtitles.count)")

        let first = session.subtitles.activeCues(at: start + 2_000_000)
        #expect(first.map(\.text) == ["HELLO CAPTIONS"])
        if let cue = first.first {
            #expect(abs(cue.start - (start + 1_000_000)) <= frame, "shown at 1 s, got \(cue.start - start) µs")
            #expect(abs(cue.end - (start + 3_000_000)) <= frame, "erased at 3 s, got \(cue.end - start) µs")
        }
        #expect(session.subtitles.activeCues(at: start + 3_500_000).isEmpty)
        #expect(session.subtitles.activeCues(at: start + 5_000_000).map(\.text) == ["SECOND CAPTION"])

        await session.selectSubtitleTrack(nil)
        #expect(session.subtitles.count == 0)
        await session.shutdown()
    }

    @Test("a source without captions offers no CC track", .timeLimit(.minutes(1)))
    func noCaptionsNoTrack() async throws {
        let session = makeSession(hardware: true)
        _ = try await session.open(url: try Fixtures.path("basic.mp4"))
        await session.play()
        _ = await eventually { await session.position > 1 }
        let tracks = await session.mediaInfo?.subtitleTracks ?? []
        let listed = tracks.contains(where: \.isEmbeddedClosedCaptions)
        #expect(!listed)
        await session.shutdown()
    }
}
