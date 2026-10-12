import Testing
@testable import LumeEngineCore

@Suite("ReplayFilter")
struct ReplayFilterTests {
    private let video: Int32 = 0
    private let audio: Int32 = 1
    private let frame: Int64 = 40_000

    @Test("a steady stream is never a replay")
    func steady() {
        var filter = ReplayFilter()
        for i in 0..<2_000 {
            let verdict = filter.classify(stream: video, time: Int64(i) * frame, size: 1_000)
            #expect(verdict == .new)
        }
        #expect(filter.replayedCount == 0)
    }

    @Test("packets sent again after a reconnect are replays")
    func burst() {
        var filter = ReplayFilter()
        for i in 0..<250 {
            _ = filter.classify(stream: video, time: Int64(i) * frame, size: Int32(1_000 + i))
        }
        // The server resends the last 3 s, then carries on.
        var replays = 0
        for i in 175..<300 {
            if filter.classify(stream: video, time: Int64(i) * frame, size: Int32(1_000 + i)) == .replay { replays += 1 }
        }
        #expect(replays == 75)
        #expect(filter.replayedCount == 75)
    }

    @Test("the same time with another size is only a suspect, and is not recorded")
    func sizeMatters() {
        var filter = ReplayFilter()
        _ = filter.classify(stream: video, time: 1_000_000, size: 4_000)
        _ = filter.classify(stream: video, time: 1_040_000, size: 4_100)
        let damaged = filter.classify(stream: video, time: 1_000_000, size: 4_001)
        #expect(damaged == .suspect(closesReplay: false))
        let again = filter.classify(stream: video, time: 1_000_000, size: 4_001)
        #expect(again == .suspect(closesReplay: false))
    }

    @Test("a suspect opening a replay is dropped with it")
    func damagedFirstPacket() {
        var filter = ReplayFilter()
        for i in 0..<100 {
            _ = filter.classify(stream: video, time: Int64(i) * frame, size: Int32(1_000 + i))
        }
        // The reconnect resumed mid-packet: frame 60 comes back damaged.
        let first = filter.classify(stream: video, time: 60 * frame, size: 77)
        #expect(first == .suspect(closesReplay: false))
        let next = filter.classify(stream: video, time: 61 * frame, size: 1_061)
        let dropped = filter.settleSuspect(stream: video, time: 60 * frame, size: 77, closesReplay: false, followedBy: next)
        #expect(next == .replay && dropped)
        #expect(filter.replayedCount == 2)
    }

    @Test("a suspect closing a replay is dropped")
    func damagedLastPacket() {
        var filter = ReplayFilter()
        for i in 0..<99 {
            _ = filter.classify(stream: video, time: Int64(i) * frame, size: Int32(1_000 + i))
        }
        // Frame 99 went out damaged (the old connection's unfinished packet
        // joined to the new one's first bytes); the replay reaches it intact.
        _ = filter.classify(stream: video, time: 99 * frame, size: 9_999)
        for i in 60..<99 {
            _ = filter.classify(stream: video, time: Int64(i) * frame, size: Int32(1_000 + i))
        }
        let intact = filter.classify(stream: video, time: 99 * frame, size: 1_099)
        #expect(intact == .suspect(closesReplay: true))
        let next = filter.classify(stream: video, time: 100 * frame, size: 1_100)
        #expect(next == .new)
        let dropped = filter.settleSuspect(stream: video, time: 99 * frame, size: 1_099, closesReplay: true, followedBy: next)
        #expect(dropped, "frame 99 was already delivered")
    }

    @Test("a timeline restarting on the same frame grid is released, not dropped")
    func restartOnGrid() {
        var filter = ReplayFilter()
        for i in 0..<100 {
            _ = filter.classify(stream: video, time: Int64(i) * frame, size: Int32(1_000 + i))
        }
        // A catch-up chunk restarts at 0: the same timestamps, other frames.
        var held: (time: Int64, size: Int32)?
        var released = 0
        for i in 0..<50 {
            let time = Int64(i) * frame
            let size = Int32(5_000 + i)
            let verdict = filter.classify(stream: video, time: time, size: size)
            if let suspect = held,
               !filter.settleSuspect(
                   stream: video, time: suspect.time, size: suspect.size, closesReplay: false, followedBy: verdict
               ) {
                released += 1
            }
            #expect(verdict == .suspect(closesReplay: false))
            held = (time, size)
        }
        #expect(released == 49, "every frame of the restart but the still-held last one goes out")
        #expect(filter.replayedCount == 0)
    }

    @Test("repeats at the newest timestamp are new media (a clock coarser than a frame)")
    func coarseClock() {
        // TrueHD in Matroska: 0.83 ms access units on a millisecond clock.
        var filter = ReplayFilter()
        let units: [(Int64, Int32)] = [(0, 198), (1_000, 42), (2_000, 28), (3_000, 30), (3_000, 28), (3_000, 28), (4_000, 30)]
        for (time, size) in units {
            let verdict = filter.classify(stream: audio, time: time, size: size)
            #expect(verdict == .new)
        }
        #expect(filter.replayedCount == 0)
    }

    @Test("streams are judged separately")
    func perStream() {
        var filter = ReplayFilter()
        _ = filter.classify(stream: video, time: 1_000_000, size: 500)
        let audioPacket = filter.classify(stream: audio, time: 1_000_000, size: 500)
        #expect(audioPacket == .new)
    }

    @Test("history is bounded by the window, so a timeline that restarts is new media")
    func window() {
        var filter = ReplayFilter(window: 10_000_000)
        _ = filter.classify(stream: video, time: 0, size: 900)
        // Far beyond the window: the first packet is forgotten.
        _ = filter.classify(stream: video, time: 20_000_000, size: 900)
        // An encoder restart lands on the old first timestamp with the same size.
        let restarted = filter.classify(stream: video, time: 0, size: 900)
        #expect(restarted == .new)
    }

    @Test("reset forgets what was delivered")
    func reset() {
        var filter = ReplayFilter()
        _ = filter.classify(stream: video, time: 0, size: 900)
        filter.reset()
        let again = filter.classify(stream: video, time: 0, size: 900)
        #expect(again == .new)
    }
}

@Suite("StallReason")
struct StallReasonTests {
    private func lane(video: Bool, decoded: Double, packets: Double) -> StallReason.Lane {
        StallReason.Lane(isVideo: video, decoded: decoded, packets: packets)
    }

    @Test("nothing arriving is the source")
    func source() {
        let reason = StallReason.diagnose(clockShouldRun: false, clockMoved: 0, lanes: [
            lane(video: true, decoded: 0.4, packets: 0),
            lane(video: false, decoded: 0.3, packets: 0),
        ])
        #expect(reason == .source)
    }

    @Test("one stream vanishing from the mux is the source")
    func oneLaneDry() {
        let reason = StallReason.diagnose(clockShouldRun: true, clockMoved: 8, lanes: [
            lane(video: true, decoded: 0.3, packets: 15),
            lane(video: false, decoded: 0, packets: 0),
        ])
        #expect(reason == .source)
    }

    @Test("packets piling up with nothing decoded is that lane's decoder")
    func decoder() {
        let video = StallReason.diagnose(clockShouldRun: false, clockMoved: 0, lanes: [
            lane(video: true, decoded: 0, packets: 15),
            lane(video: false, decoded: 0.8, packets: 0),
        ])
        #expect(video == .videoDecoder)
        let audio = StallReason.diagnose(clockShouldRun: false, clockMoved: 0, lanes: [
            lane(video: true, decoded: 0.3, packets: 2),
            lane(video: false, decoded: 0.01, packets: 6),
        ])
        #expect(audio == .audioDecoder)
    }

    @Test("a clock that should run but stands still is the renderer")
    func renderer() {
        let reason = StallReason.diagnose(clockShouldRun: true, clockMoved: 0.02, lanes: [
            lane(video: true, decoded: 0.3, packets: 15),
            lane(video: false, decoded: 1.0, packets: 15),
        ])
        #expect(reason == .renderer)
    }
}
