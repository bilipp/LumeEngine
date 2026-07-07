import Testing
@testable import LumeEngineCore

@Suite("TimestampUnwrapper")
struct TimestampUnwrapperTests {
    /// 33-bit MPEG-TS wrap: 2^33 = 8_589_934_592 ticks at 90 kHz.
    private let wrapRange: Int64 = 1 << 33

    @Test("monotonic across a single 33-bit wrap seam")
    func singleWrap() {
        var unwrapper = TimestampUnwrapper(wrapBits: 33)
        let nearEnd = wrapRange - 90_000 // 1 s before the seam
        var previous = Int64.min
        // Step in 40 ms ticks (3600 @ 90 kHz) across the seam.
        var raw = nearEnd
        for _ in 0..<100 {
            let wrapped = raw % wrapRange
            let unwrapped = unwrapper.unwrap(wrapped)
            #expect(unwrapped > previous, "timestamps must stay monotonic across the seam")
            previous = unwrapped
            raw += 3600
        }
        #expect(previous >= wrapRange, "post-seam values must continue past the wrap range")
    }

    @Test("multiple consecutive wraps accumulate offsets")
    func multipleWraps() {
        var unwrapper = TimestampUnwrapper(wrapBits: 8) // tiny range (256) for fast coverage
        var previous = Int64.min
        for i in 0..<2000 {
            let raw = Int64(i * 7 % 256)
            _ = raw
        }
        // Feed a strictly increasing virtual clock through an 8-bit wrap.
        for virtual in stride(from: Int64(0), to: 2000, by: 5) {
            let unwrapped = unwrapper.unwrap(virtual % 256)
            #expect(unwrapped > previous)
            previous = unwrapped
        }
        #expect(previous >= 1900, "should have unwrapped through ~7 wrap cycles")
    }

    @Test("B-frame PTS jitter does not trigger unwrapping")
    func bFrameJitter() {
        var unwrapper = TimestampUnwrapper(wrapBits: 33)
        // PTS pattern with reordering jitter: 0, 3600, 1800, 7200, 5400 ...
        let jittered: [Int64] = [0, 3600, 1800, 7200, 5400, 10800, 9000]
        var results: [Int64] = []
        for ts in jittered {
            results.append(unwrapper.unwrap(ts))
        }
        #expect(results == jittered, "small backward jumps must pass through untouched")
    }

    @Test("no-timestamp sentinel passes through")
    func noTimestamp() {
        var unwrapper = TimestampUnwrapper(wrapBits: 33)
        #expect(unwrapper.unwrap(MediaTime.noTimestamp) == MediaTime.noTimestamp)
        #expect(unwrapper.unwrap(100) == 100)
        #expect(unwrapper.unwrap(MediaTime.noTimestamp) == MediaTime.noTimestamp)
        #expect(unwrapper.unwrap(200) == 200)
    }

    @Test("64-bit streams are left untouched")
    func disabled() {
        var unwrapper = TimestampUnwrapper(wrapBits: 64)
        let samples: [Int64] = [Int64.max - 10, 5, Int64.min + 10, 0]
        for sample in samples {
            #expect(unwrapper.unwrap(sample) == sample)
        }
    }

    @Test("discontinuity resets continuity but keeps monotonic offset")
    func discontinuityKeepsOffset() {
        var unwrapper = TimestampUnwrapper(wrapBits: 8)
        _ = unwrapper.unwrap(250)
        let wrapped = unwrapper.unwrap(4) // wraps: 4 + 256 = 260
        #expect(wrapped == 260)
        unwrapper.discontinuity()
        // After a seek, a backward raw value must not be misread as a wrap.
        let afterSeek = unwrapper.unwrap(100)
        #expect(afterSeek == 100 + 256, "wrap offset persists so time stays monotonic")
    }

    @Test("normalizer applies DTS-driven offset to PTS")
    func normalizerConsistency() {
        var normalizer = StreamTimeNormalizer(wrapBits: 8)
        _ = normalizer.normalize(pts: 251, dts: 250)
        // DTS wraps; PTS (slightly ahead, also small number) must get the same shift.
        let (pts, dts) = normalizer.normalize(pts: 3, dts: 2)
        #expect(dts == 2 + 256)
        #expect(pts == 3 + 256)
    }
}
