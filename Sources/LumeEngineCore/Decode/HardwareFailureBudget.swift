import Foundation

/// Decides when hardware decoding has failed often enough to give it up.
///
/// A VideoToolbox error is rarely a verdict on the stream. A corrupt packet in
/// an IPTV feed fails one frame. A screen lock or a media-services reset
/// invalidates the session, and FFmpeg rebuilds it on its own at the next
/// frame (libavcodec/videotoolbox.c restarts the session when the previous
/// decode reported a malfunction or an invalid session). Switching to software
/// on the first error leaves a 4K HEVC stream in software for the rest of the
/// session, which is what makes it stutter on Apple TV. So an error first
/// costs a flush and a resync at the next keyframe, and software only takes
/// over when hardware keeps failing:
///
/// - Any failure before hardware has produced its first frame: the session
///   never worked, so there is nothing transient to wait out. VideoToolbox
///   can accept a configuration it then fails on every frame (virtualized
///   macOS claims AV1 that way), and each retry would cost a GOP of black.
/// - `consecutiveLimit` failures with no frame decoded in between: the
///   hardware path is not coming back (an unsupported profile, a session
///   that cannot be rebuilt).
/// - `windowLimit` failures within `window`: it recovers each time but too
///   often to watch, since every recovery freezes the picture until the next
///   keyframe.
///
/// Pure value type, so the policy is testable without a decoder that fails.
struct HardwareFailureBudget: Sendable {
    let consecutiveLimit: Int
    let windowLimit: Int
    let window: TimeInterval

    private var consecutive = 0
    private var hasDecoded = false
    private var recent: [TimeInterval] = []

    init(consecutiveLimit: Int = 3, windowLimit: Int = 6, window: TimeInterval = 30) {
        self.consecutiveLimit = consecutiveLimit
        self.windowLimit = windowLimit
        self.window = window
    }

    /// A frame came out of the hardware decoder.
    mutating func recordFrame() {
        consecutive = 0
        hasDecoded = true
    }

    /// Records a hardware failure at `now` (seconds on any monotonic clock).
    /// Returns true when hardware decoding should be given up.
    mutating func recordFailure(at now: TimeInterval) -> Bool {
        consecutive += 1
        recent.removeAll { now - $0 > window }
        recent.append(now)
        return !hasDecoded || consecutive >= consecutiveLimit || recent.count >= windowLimit
    }
}
