internal import CFFmpeg

/// Engine-internal time: microseconds on the `AV_TIME_BASE` scale, `Int64`.
/// All timestamps are normalized to this scale at the demux boundary —
/// nothing downstream ever sees container time bases. (PLAN.md §3.2)
public enum MediaTime {
    /// FFmpeg's "no timestamp" sentinel (`AV_NOPTS_VALUE`).
    public static let noTimestamp: Int64 = lume_av_nopts_value()

    /// One second in engine time units.
    public static let timeBase: Int64 = Int64(AV_TIME_BASE)

    @inlinable
    public static func isValid(_ ts: Int64) -> Bool { ts != noTimestamp }

    /// Rescales a timestamp from a stream time base to engine microseconds.
    /// Internal: `AVRational` must not leak into the public interface (the
    /// CFFmpeg dependency is an implementation detail — see Package.swift).
    static func fromStream(_ ts: Int64, timeBase: AVRational) -> Int64 {
        guard isValid(ts) else { return noTimestamp }
        return av_rescale_q(ts, timeBase, lume_av_time_base_q())
    }

    /// Rescales engine microseconds to a stream time base.
    static func toStream(_ us: Int64, timeBase: AVRational) -> Int64 {
        guard isValid(us) else { return noTimestamp }
        return av_rescale_q(us, lume_av_time_base_q(), timeBase)
    }

    @inlinable
    public static func seconds(_ us: Int64) -> Double {
        Double(us) / Double(timeBase)
    }

    @inlinable
    public static func microseconds(_ seconds: Double) -> Int64 {
        Int64((seconds * Double(timeBase)).rounded())
    }
}
