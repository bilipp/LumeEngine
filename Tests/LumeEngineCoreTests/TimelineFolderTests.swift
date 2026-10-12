import Testing
@testable import LumeEngineCore

@Suite("TimelineFolder")
struct TimelineFolderTests {
    private let video: Int32 = 0
    private let audio: Int32 = 1
    private let subtitle: Int32 = 2
    private let frame: Int64 = 40_000 // 25 fps
    private let audioFrame: Int64 = 21_333 // AAC at 48 kHz

    @Test("steady timestamps are never corrected")
    func steady() {
        var folder = TimelineFolder()
        for i in 0..<500 {
            let correction = folder.correction(stream: video, continuous: true, time: Int64(i) * frame, duration: frame)
            #expect(correction == 0)
        }
        #expect(folder.seamCount == 0)
    }

    @Test("a forward jump is folded so the stream continues where it left off")
    func forwardJump() {
        var folder = TimelineFolder()
        var last: Int64 = 0
        for i in 0..<100 {
            last = Int64(i) * frame
            _ = folder.correction(stream: video, continuous: true, time: last, duration: frame)
        }
        // libavformat's wrap guess turning a chunk restart into +26.5 h.
        let restarted: Int64 = 95_445_000_000
        let correction = folder.correction(stream: video, continuous: true, time: restarted, duration: frame)
        #expect(restarted + correction == last + frame)
        #expect(folder.seamCount == 1)
        // The packets after it keep the same correction.
        let next = folder.correction(stream: video, continuous: true, time: restarted + frame, duration: frame)
        #expect(next == correction)
    }

    @Test("a restart near zero is folded")
    func backwardRestart() {
        var folder = TimelineFolder()
        var last: Int64 = 0
        for i in 0..<100 {
            last = 600_000_000 + Int64(i) * frame
            _ = folder.correction(stream: video, continuous: true, time: last, duration: frame)
        }
        let correction = folder.correction(stream: video, continuous: true, time: 1_400_000, duration: frame)
        #expect(1_400_000 + correction == last + frame)
    }

    @Test("small backward steps are not seams")
    func jitter() {
        var folder = TimelineFolder()
        let times: [Int64] = [0, 80_000, 40_000, 160_000, 120_000, 1_000_000, 900_000]
        for time in times {
            let result = folder.correction(stream: video, continuous: true, time: time, duration: 0)
            #expect(result == 0)
        }
        #expect(folder.seamCount == 0)
    }

    @Test("both streams take one correction, keeping A/V sync across the seam")
    func sharedSeam() {
        var folder = TimelineFolder()
        // Interleaved: audio runs ~300 ms behind video in mux order.
        var videoTime: Int64 = 600_000_000
        var audioTime: Int64 = 599_700_000
        for _ in 0..<50 {
            _ = folder.correction(stream: video, continuous: true, time: videoTime, duration: frame)
            _ = folder.correction(stream: audio, continuous: true, time: audioTime, duration: audioFrame)
            videoTime += frame
            audioTime += audioFrame
        }
        // Video crosses into the new chunk first; audio still has a few
        // packets of the old one to deliver.
        let videoCorrection = folder.correction(stream: video, continuous: true, time: 1_400_000, duration: frame)
        for _ in 0..<5 {
            let result = folder.correction(stream: audio, continuous: true, time: audioTime, duration: audioFrame)
            #expect(result == 0)
            audioTime += audioFrame
        }
        // In the new chunk audio starts 200 ms after video, as the source has it.
        let audioCorrection = folder.correction(stream: audio, continuous: true, time: 1_600_000, duration: audioFrame)
        #expect(audioCorrection == videoCorrection)
        #expect(folder.seamCount == 1)
    }

    @Test("sparse streams follow every seam and never find one")
    func sparse() {
        var folder = TimelineFolder()
        // A subtitle gap of minutes is normal and not a seam.
        let first = folder.correction(stream: subtitle, continuous: false, time: 0, duration: 0)
        let minutesLater = folder.correction(stream: subtitle, continuous: false, time: 300_000_000, duration: 0)
        #expect(first == 0 && minutesLater == 0)
        #expect(folder.seamCount == 0)

        for i in 0..<10 {
            _ = folder.correction(stream: video, continuous: true, time: 600_000_000 + Int64(i) * frame, duration: frame)
        }
        let correction = folder.correction(stream: video, continuous: true, time: 1_400_000, duration: frame)
        let afterSeam = folder.correction(stream: subtitle, continuous: false, time: 2_000_000, duration: 0)
        #expect(afterSeam == correction)
    }

    @Test("reset forgets every correction")
    func reset() {
        var folder = TimelineFolder()
        _ = folder.correction(stream: video, continuous: true, time: 600_000_000, duration: frame)
        _ = folder.correction(stream: video, continuous: true, time: 1_400_000, duration: frame)
        #expect(folder.seamCount == 1)
        folder.reset()
        #expect(folder.seamCount == 0)
        let result = folder.correction(stream: video, continuous: true, time: 1_440_000, duration: frame)
        #expect(result == 0)
    }
}

@Suite("HardwareFailureBudget")
struct HardwareFailureBudgetTests {
    @Test("isolated failures with frames in between keep hardware")
    func isolated() {
        var budget = HardwareFailureBudget()
        budget.recordFrame()
        // One failure a minute, recovering each time: a corrupt packet now
        // and then on an otherwise healthy channel.
        for minute in 0..<20 {
            let gaveUp = budget.recordFailure(at: Double(minute) * 60)
            #expect(!gaveUp)
            budget.recordFrame()
        }
    }

    @Test("a failure before the first frame gives up at once")
    func neverDecoded() {
        var budget = HardwareFailureBudget()
        let gaveUp = budget.recordFailure(at: 0)
        #expect(gaveUp)
    }

    @Test("consecutive failures without a frame give up")
    func consecutive() {
        var budget = HardwareFailureBudget()
        budget.recordFrame()
        let first = budget.recordFailure(at: 0)
        let second = budget.recordFailure(at: 1)
        let third = budget.recordFailure(at: 2)
        #expect(!first && !second)
        #expect(third)
    }

    @Test("frequent failures give up even when each one recovers")
    func frequent() {
        var budget = HardwareFailureBudget()
        budget.recordFrame()
        var gaveUp = false
        for second in 0..<6 {
            gaveUp = budget.recordFailure(at: Double(second) * 4)
            budget.recordFrame()
        }
        #expect(gaveUp)
    }

    @Test("old failures age out of the window")
    func window() {
        var budget = HardwareFailureBudget()
        budget.recordFrame()
        for second in 0..<5 {
            _ = budget.recordFailure(at: Double(second))
            budget.recordFrame()
        }
        // Six failures in all, but the first five are over 30 s old.
        let gaveUp = budget.recordFailure(at: 100)
        #expect(!gaveUp)
    }
}
