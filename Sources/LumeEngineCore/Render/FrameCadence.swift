/// The interval between the video frames the renderer is actually handed —
/// measured, because the container's frame rate is a guess about the input,
/// not a statement about the output. The deinterlacer at field rate doubles
/// it (1080i50 comes out as 50p), a field-coded stream can report its field
/// rate as its frame rate, and live sources carry no reliable rate at all.
///
/// Pure value type, confined to whoever feeds it (the renderer keeps it under
/// its lock): one subtraction per frame, the statistics only when asked.
struct FrameCadence: Sendable, Equatable {
    /// Intervals kept: enough to see through the odd dropped or repeated frame.
    static let capacity = 32
    /// Intervals needed before a cadence is reported. Fewer is a guess.
    static let minimumSamples = 8
    /// Longer gaps are dropouts or seams, not frame intervals (5 fps floor).
    static let maximumInterval: Int64 = 200_000

    private var lastPTS: Int64?
    private var intervals: [Int64] = []
    private var nextSlot = 0

    /// Forgets the previous frame, keeping what was learned: after a seek the
    /// stream is the same, only its timeline jumped.
    mutating func restart() {
        lastPTS = nil
    }

    mutating func observe(pts: Int64) {
        guard MediaTime.isValid(pts) else { return }
        defer { lastPTS = pts }
        guard let lastPTS else { return }
        let interval = pts - lastPTS
        // Backwards or too long: a seam or a dropout, not a frame interval.
        guard interval > 0, interval <= Self.maximumInterval else { return }
        if intervals.count < Self.capacity {
            intervals.append(interval)
        } else {
            intervals[nextSlot] = interval
            nextSlot = (nextSlot + 1) % Self.capacity
        }
    }

    /// The typical frame interval in engine µs, nil until enough frames were
    /// seen. The mean of the middle half: timestamps quantized by a 90 kHz
    /// clock and rounded to µs alternate between two neighbouring values
    /// (59.94 fps is 16 678 / 16 689 µs), so a single median sample would be
    /// off by more than the gap between 59.94 and 60; the outer quartiles
    /// drop the odd duplicated or skipped frame.
    var interval: Double? {
        guard intervals.count >= Self.minimumSamples else { return nil }
        let sorted = intervals.sorted()
        let quarter = sorted.count / 4
        let middle = sorted[quarter..<(sorted.count - quarter)]
        return Double(middle.reduce(0, +)) / Double(middle.count)
    }
}
