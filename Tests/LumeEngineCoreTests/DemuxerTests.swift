import Foundation
import Testing
@testable import LumeEngineCore

@Suite("FFmpegRuntime")
struct FFmpegRuntimeTests {
    @Test("linked FFmpeg is the 8.x line")
    func version() {
        // libavutil major 60 == FFmpeg 8.x (59 = 7.x, 58 = 6.x).
        #expect(FFmpegRuntime.avutilMajorVersion == 60, "expected FFmpeg 8.x, got \(FFmpegRuntime.versions)")
    }
}

@Suite("Demuxer", .serialized)
struct DemuxerTests {
    /// Sequentially awaits demux events with a hard timeout.
    private func nextEvent(
        _ iterator: inout AsyncStream<DemuxEvent>.Iterator,
        timeout: TimeInterval = 10
    ) async -> DemuxEvent? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if let event = await iterator.next() { return event }
        }
        return nil
    }

    @Test("open reports correct MediaInfo for MP4")
    func openBasic() async throws {
        let demuxer = Demuxer(url: try Fixtures.path("basic.mp4"))
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()

        guard case .opened(let info)? = await nextEvent(&events) else {
            Issue.record("expected .opened")
            demuxer.shutdown()
            return
        }
        #expect(info.videoTracks.count == 1)
        #expect(info.audioTracks.count == 1)
        #expect(info.isSeekable)
        #expect(!info.isLive)
        if let duration = info.duration {
            #expect(abs(MediaTime.seconds(duration) - 10.0) < 0.5, "expected ~10 s, got \(MediaTime.seconds(duration))")
        } else {
            Issue.record("expected known duration")
        }
        let video = try #require(info.videoTracks.first)
        #expect(video.codecName == "h264")
        #expect(video.video?.width == 640)
        #expect(video.video?.height == 360)
        #expect(abs((video.video?.fps ?? 0) - 30.0) < 0.1)

        #expect(demuxer.shutdown())
    }

    @Test("reads all packets to EOF; video starts on a keyframe")
    func readToEOF() async throws {
        let demuxer = Demuxer(url: try Fixtures.path("basic.mp4"))
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()

        guard case .opened(let info)? = await nextEvent(&events) else {
            Issue.record("expected .opened"); demuxer.shutdown(); return
        }
        let videoIndex = try #require(info.videoTracks.first?.index)
        let channel = Channel<Packet>(capacity: 1024)
        demuxer.attach(channel: channel, toStream: videoIndex)
        demuxer.resume()

        guard case .endOfStream? = await nextEvent(&events) else {
            Issue.record("expected .endOfStream"); demuxer.shutdown(); return
        }

        var packets: [Packet] = []
        while let packet = channel.tryReceive() { packets.append(packet) }

        #expect(packets.count >= 290, "10 s @ 30 fps should yield ~300 packets, got \(packets.count)")
        #expect(packets.first?.isKeyframe == true, "stream must start on a keyframe")
        #expect(packets.allSatisfy { $0.serial == 0 })

        // DTS must be strictly increasing within one stream.
        let dtsValues = packets.map(\.dts).filter(MediaTime.isValid)
        #expect(zip(dtsValues, dtsValues.dropFirst()).allSatisfy { $0 < $1 }, "DTS must be monotonic")

        #expect(demuxer.shutdown())
    }

    @Test("missing packet durations are synthesized from PTS steps")
    func durationSynthesis() async throws {
        // TrueHD-in-matroska packets carry no durations; every downstream
        // duration budget (read-ahead limits, buffer gates) would read a
        // loaded queue as "0 seconds". The demuxer must synthesize them.
        let demuxer = Demuxer(url: try Fixtures.path("truehd.mkv"))
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()

        guard case .opened(let info)? = await nextEvent(&events) else {
            Issue.record("expected .opened"); demuxer.shutdown(); return
        }
        let audioIndex = try #require(info.audioTracks.first?.index)
        let channel = Channel<Packet>(capacity: 8192)
        demuxer.attach(channel: channel, toStream: audioIndex)
        demuxer.resume()

        guard case .endOfStream? = await nextEvent(&events) else {
            Issue.record("expected .endOfStream"); demuxer.shutdown(); return
        }

        var totalDuration: Int64 = 0
        var count = 0
        while let packet = channel.tryReceive() {
            totalDuration += max(packet.duration, 0)
            count += 1
        }
        #expect(count > 4000, "4 s of TrueHD is ~4800 access units, got \(count)")
        // 4 s fixture: the summed synthesized durations must account for
        // nearly all of it (the very first packet has no predecessor).
        let seconds = MediaTime.seconds(totalDuration)
        #expect(seconds > 3.5 && seconds < 4.5, "synthesized durations should sum to ~4 s, got \(seconds)")

        #expect(demuxer.shutdown())
    }

    @Test("MPEG-TS timestamps stay monotonic across the 33-bit wrap seam")
    func wraparound() async throws {
        let demuxer = Demuxer(url: try Fixtures.path("wrap.ts"))
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()

        guard case .opened(let info)? = await nextEvent(&events) else {
            Issue.record("expected .opened"); demuxer.shutdown(); return
        }
        let videoIndex = try #require(info.videoTracks.first?.index)
        let audioIndex = try #require(info.audioTracks.first?.index)
        let videoChannel = Channel<Packet>(capacity: 4096)
        let audioChannel = Channel<Packet>(capacity: 4096)
        demuxer.attach(channel: videoChannel, toStream: videoIndex)
        demuxer.attach(channel: audioChannel, toStream: audioIndex)
        demuxer.resume()

        guard case .endOfStream? = await nextEvent(&events, timeout: 20) else {
            Issue.record("expected .endOfStream"); demuxer.shutdown(); return
        }

        for (label, channel) in [("video", videoChannel), ("audio", audioChannel)] {
            var dts: [Int64] = []
            while let packet = channel.tryReceive() {
                if MediaTime.isValid(packet.dts) { dts.append(packet.dts) }
            }
            #expect(dts.count > 100, "\(label): expected packets across the seam")
            #expect(
                zip(dts, dts.dropFirst()).allSatisfy { $0 <= $1 },
                "\(label): engine time must be monotonic even though raw container time wraps"
            )
            if let first = dts.first, let last = dts.last {
                let span = MediaTime.seconds(last - first)
                #expect(span > 10.0 && span < 14.0, "\(label): span should be ~12 s, got \(span)")
            }
        }

        #expect(demuxer.shutdown())
    }

    @Test("seek bumps serial; new packets carry the new serial from a keyframe")
    func seek() async throws {
        let demuxer = Demuxer(url: try Fixtures.path("basic.mp4"))
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()

        guard case .opened(let info)? = await nextEvent(&events) else {
            Issue.record("expected .opened"); demuxer.shutdown(); return
        }
        let videoIndex = try #require(info.videoTracks.first?.index)
        let channel = Channel<Packet>(capacity: 4096)
        demuxer.attach(channel: channel, toStream: videoIndex)
        demuxer.resume()

        guard case .endOfStream? = await nextEvent(&events) else {
            Issue.record("expected first .endOfStream"); demuxer.shutdown(); return
        }
        channel.flush() // discard serial-0 packets, as a session would on seek

        let target = info.startTime + MediaTime.microseconds(5.0)
        demuxer.seek(to: target)

        guard case .didSeek(_, let serial)? = await nextEvent(&events) else {
            Issue.record("expected .didSeek"); demuxer.shutdown(); return
        }
        #expect(serial == 1)

        guard case .endOfStream(let eofSerial)? = await nextEvent(&events) else {
            Issue.record("expected second .endOfStream"); demuxer.shutdown(); return
        }
        #expect(eofSerial == 1)

        var packets: [Packet] = []
        while let packet = channel.tryReceive() { packets.append(packet) }
        #expect(!packets.isEmpty)
        #expect(packets.allSatisfy { $0.serial == 1 }, "post-seek packets must carry the new serial")
        #expect(packets.first?.isKeyframe == true, "seek must land on a keyframe")
        if let first = packets.first, MediaTime.isValid(first.pts) {
            let position = MediaTime.seconds(first.pts - info.startTime)
            #expect(position <= 5.05, "keyframe-backward seek must not overshoot the target")
            #expect(position >= 2.0, "seek should land near the target, got \(position)")
        }

        #expect(demuxer.shutdown())
    }

    @Test("multitrack MKV: languages, subtitles, chapters, selective routing")
    func multitrack() async throws {
        let demuxer = Demuxer(url: try Fixtures.path("multitrack.mkv"))
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()

        guard case .opened(let info)? = await nextEvent(&events) else {
            Issue.record("expected .opened"); demuxer.shutdown(); return
        }
        #expect(info.videoTracks.count == 1)
        #expect(info.audioTracks.count == 2)
        #expect(info.subtitleTracks.count == 1)
        #expect(Set(info.audioTracks.compactMap(\.language)) == ["eng", "ger"])
        #expect(info.subtitleTracks.first?.codecName == "subrip")
        #expect(info.chapters.count == 2)
        #expect(info.chapters.first?.title == "Intro")

        // Attach ONLY the German audio track; nothing else may arrive.
        let german = try #require(info.audioTracks.first { $0.language == "ger" })
        let channel = Channel<Packet>(capacity: 4096)
        demuxer.attach(channel: channel, toStream: german.index)
        demuxer.resume()

        guard case .endOfStream? = await nextEvent(&events) else {
            Issue.record("expected .endOfStream"); demuxer.shutdown(); return
        }
        var count = 0
        while let packet = channel.tryReceive() {
            #expect(packet.streamIndex == german.index, "only the attached stream may be routed")
            count += 1
        }
        #expect(count > 50, "expected a healthy number of audio packets, got \(count)")

        #expect(demuxer.shutdown())
    }

    @Test("open failure is an event, not a hang; shutdown is idempotent")
    func openFailure() async {
        let demuxer = Demuxer(url: "/nonexistent/definitely-missing.mp4")
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()

        guard case .openFailed(let error)? = await nextEvent(&events) else {
            Issue.record("expected .openFailed")
            demuxer.shutdown()
            return
        }
        #expect(error.code == .openFailed)
        #expect(demuxer.shutdown())
        #expect(demuxer.shutdown(), "shutdown must be idempotent")
    }

    @Test("shutdown mid-read tears down within the deadline and closes channels")
    func shutdownMidRead() async throws {
        let demuxer = Demuxer(url: try Fixtures.path("wrap.ts"))
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()

        guard case .opened(let info)? = await nextEvent(&events) else {
            Issue.record("expected .opened"); demuxer.shutdown(); return
        }
        let videoIndex = try #require(info.videoTracks.first?.index)
        // Tiny channel: the reader will be blocked in send() when we shut down.
        let channel = Channel<Packet>(capacity: 2)
        demuxer.attach(channel: channel, toStream: videoIndex)
        demuxer.resume()

        // Let the reader fill the channel and block.
        try await Task.sleep(for: .milliseconds(200))

        let start = Date()
        let cleanShutdown = demuxer.shutdown(deadline: 2.0)
        let elapsed = Date().timeIntervalSince(start)
        #expect(cleanShutdown, "shutdown must complete while a producer is blocked on a full channel")
        #expect(elapsed < 2.0, "teardown must be fast (took \(elapsed)s)")
        #expect(channel.closed, "attached channels must be closed on teardown")
    }
}
