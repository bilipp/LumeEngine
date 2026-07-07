/// Unwraps container timestamps that wrap around a fixed bit width into
/// monotonically increasing 64-bit values.
///
/// MPEG-TS carries 33-bit PTS/DTS (90 kHz), wrapping every ~26.5 hours. The most
/// notorious live-TV failure in FFmpeg-based players — frozen video with healthy
/// audio after long uptimes — is a direct consequence of not handling this. The unwrapper runs at
/// the demux boundary for every stream whose `pts_wrap_bits < 64`. (PLAN.md §3.2)
///
/// Pure value type: trivially unit-testable across wrap seams.
public struct TimestampUnwrapper: Sendable {
    private let range: Int64
    private let threshold: Int64
    private var last: Int64?
    private var offset: Int64 = 0
    private let enabled: Bool

    /// - Parameter wrapBits: the container's timestamp width (`AVStream.pts_wrap_bits`).
    ///   Values outside `1..<64` disable unwrapping.
    public init(wrapBits: Int32) {
        if wrapBits > 0 && wrapBits < 64 {
            enabled = true
            range = Int64(1) << Int64(wrapBits)
            threshold = range / 2
        } else {
            enabled = false
            range = 0
            threshold = 0
        }
    }

    /// Unwraps a raw container timestamp. Passes `MediaTime.noTimestamp` through.
    public mutating func unwrap(_ ts: Int64) -> Int64 {
        guard enabled, MediaTime.isValid(ts) else { return ts }
        var candidate = ts &+ offset
        if let last, candidate < last - threshold {
            // Jumped backward by more than half the wrap range: the container
            // counter wrapped. Shift everything from here on by one range.
            offset &+= range
            candidate &+= range
        }
        last = candidate
        return candidate
    }

    /// Forgets continuity state (e.g. after a seek or an explicit discontinuity),
    /// keeping the accumulated wrap offset so time stays monotonic.
    public mutating func discontinuity() {
        last = nil
    }
}

/// Applies one shared unwrap decision to a packet's PTS/DTS pair so they stay
/// consistent with each other (DTS drives the wrap detection when present).
public struct StreamTimeNormalizer: Sendable {
    private var unwrapper: TimestampUnwrapper

    public init(wrapBits: Int32) {
        unwrapper = TimestampUnwrapper(wrapBits: wrapBits)
    }

    public mutating func normalize(pts: Int64, dts: Int64) -> (pts: Int64, dts: Int64) {
        // Drive wrap detection with DTS (monotonic within a stream); PTS of
        // B-frame streams legitimately jitters and must not trigger unwraps.
        if MediaTime.isValid(dts) {
            let newDts = unwrapper.unwrap(dts)
            let delta = newDts - dts
            let newPts = MediaTime.isValid(pts) ? pts &+ delta : pts
            return (newPts, newDts)
        }
        if MediaTime.isValid(pts) {
            let newPts = unwrapper.unwrap(pts)
            return (newPts, MediaTime.noTimestamp)
        }
        return (pts, dts)
    }

    public mutating func discontinuity() {
        unwrapper.discontinuity()
    }
}
