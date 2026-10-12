/// Folds timestamp discontinuities out of the engine timeline at the demux
/// boundary, after wrap unwrapping and rescaling to engine µs.
///
/// The 33-bit wrap is one discontinuity among several a live source produces:
///
/// - an encoder restart resets PTS to an arbitrary value;
/// - catch-up archives served as concatenated TS chunks restart PTS near zero
///   in every chunk (and libavformat's own wrap guess can turn that restart
///   into a jump of +26.5 h);
/// - a reconnect can land somewhere else on the source's clock.
///
/// The renderer's clock runs on, so a forward jump strands every following
/// frame hours in the future (frozen picture, silent audio) and a backward
/// jump makes them all late. Folding keeps the engine timeline continuous:
/// a jump beyond the limits on a continuous stream (audio, video) is taken
/// as a seam and corrected so the stream picks up where it left off.
///
/// One seam moves every stream. Each continuous stream detects it on its own
/// (streams are interleaved, so they cross it at different packets), and a
/// stream that meets a jump matching a seam another stream already folded
/// reuses that seam's correction, so A/V sync across the seam stays what the
/// source had. Sparse streams (subtitles, data) have gaps of minutes by
/// nature and never detect seams; they follow every seam found so far.
///
/// Pure value type, reset on seek: a seek target is a position on the source's
/// own timeline, so after a seek the folded offsets no longer apply.
struct TimelineFolder: Sendable {
    /// A jump forward by more than this between two packets of one continuous
    /// stream is a seam. Larger than any real gap a live source leaves while
    /// still delivering (signal loss shows as missing time, and a few seconds
    /// of it should stay missing).
    static let forwardLimit: Int64 = 10_000_000
    /// A jump backward by more than this is a seam. Decode timestamps of one
    /// stream never go backward; this only leaves room for presentation-time
    /// jitter on streams that carry no decode timestamps.
    static let backwardLimit: Int64 = 2_000_000
    /// Two streams' jumps within this of each other are the same seam: the
    /// streams' last timestamps before it differ by their interleave distance.
    static let matchTolerance: Int64 = 3_000_000
    /// Upper bound for the per-packet step a folded stream continues with.
    private static let maxStep: Int64 = 1_000_000

    private struct Seam {
        /// The jump as the stream that found it saw it.
        let jump: Int64
        let correction: Int64
    }

    private struct StreamState {
        var last: Int64?
        /// Typical distance between packets, to place the first packet after
        /// a seam where the next one was due.
        var step: Int64 = 0
        /// Seams this stream has crossed (a prefix of `seams`).
        var crossed: Int
        var correction: Int64
    }

    private var seams: [Seam] = []
    private var streams: [Int32: StreamState] = [:]
    private var sparseCorrection: Int64 = 0

    init() {}

    /// Number of seams folded since the last reset.
    var seamCount: Int { seams.count }

    /// The correction to add to a packet's PTS and DTS.
    ///
    /// - Parameters:
    ///   - stream: the packet's stream index.
    ///   - continuous: true for audio and video, false for sparse streams.
    ///   - time: the packet's DTS, or its PTS when it has no DTS (engine µs).
    ///   - duration: the packet's duration when known (engine µs, else ≤ 0).
    mutating func correction(
        stream: Int32,
        continuous: Bool,
        time: Int64,
        duration: Int64
    ) -> Int64 {
        guard continuous else { return sparseCorrection }
        guard MediaTime.isValid(time) else { return streams[stream]?.correction ?? sparseCorrection }

        // A stream that starts late begins where every seam so far has moved
        // the timeline.
        var state = streams[stream] ?? StreamState(crossed: seams.count, correction: sparseCorrection)
        var corrected = time + state.correction

        if let last = state.last {
            let jump = corrected - last
            if jump > Self.forwardLimit || jump < -Self.backwardLimit {
                if let index = seams[state.crossed...].firstIndex(where: { abs($0.jump - jump) <= Self.matchTolerance }) {
                    // Another stream folded this seam already: take its
                    // correction (and any earlier seam this stream skipped).
                    for seam in seams[state.crossed...index] { state.correction += seam.correction }
                    state.crossed = index + 1
                } else {
                    let step = duration > 0 ? min(duration, Self.maxStep) : state.step
                    let correction = last + step - corrected
                    seams.append(Seam(jump: jump, correction: correction))
                    sparseCorrection += correction
                    state.correction += correction
                    state.crossed = seams.count
                }
                corrected = time + state.correction
            } else if jump > 0 {
                state.step = min(jump, Self.maxStep)
            }
        }

        state.last = corrected
        streams[stream] = state
        return state.correction
    }

    /// Forgets every seam and offset (after a seek).
    mutating func reset() {
        self = TimelineFolder()
    }
}
