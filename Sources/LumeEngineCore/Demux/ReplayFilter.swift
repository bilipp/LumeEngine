/// Recognises packets a reconnected source sends a second time.
///
/// A live HTTP source that drops is reconnected by FFmpeg, which requests the
/// stream again from the start; the server answers from its live edge, and
/// most IPTV servers open that answer with a burst of what they still have
/// buffered — seconds the session already received. Delivered again, those
/// packets reach the timeline as a backward jump: a few hundred milliseconds
/// arrive out of order (and stutter), a few seconds are folded as a seam and
/// play twice, every reconnect adding its overlap to the live delay.
///
/// A replayed packet is the same frame, so it carries the same timestamp and
/// the same payload size on the same stream, and it arrives *behind* the
/// stream's newest timestamp: a replay always jumps back. The filter
/// remembers the pairs it let through, per stream, over a window of media
/// time around the latest one, and only judges packets behind the newest.
/// Repeats at the newest timestamp are ordinary in containers whose clock is
/// coarser than a frame: Matroska counts milliseconds, a TrueHD access unit
/// lasts 0.83 ms, so consecutive units share timestamps and often sizes. (At
/// the newest timestamp a packet is judged only inside a replay, which is
/// where the replay's last frame lands.) Times are the demuxer's unwrapped
/// engine µs *before* seam folding, because that is what the server repeats.
/// Reset on seek.
///
/// The first packet of a replay is usually damaged: the new response starts
/// mid-packet, so the demuxer joins its tail to whatever the old connection
/// left unfinished. It keeps the frame's timestamp but not its size, so it is
/// `.suspect` — a timestamp already delivered with another size — and the
/// caller holds it until the stream's next packet settles it. The last packet
/// before the jump is damaged the same way, and was delivered damaged, so
/// when the replay reaches that frame its intact copy is a suspect too. A
/// suspect is dropped when the next packet is a replay (it opens one) or the
/// previous one was (it closes one); otherwise it is released. A timestamp
/// match alone cannot decide, because chunked catch-up streams restart on the
/// same frame grid within seconds, and dropping a restart's frames would cost
/// its keyframe.
///
/// Pure value type, so the policy is testable without a server that replays.
struct ReplayFilter: Sendable {
    enum Verdict: Equatable {
        /// Not delivered before; recorded.
        case new
        /// Delivered before, byte for byte the same frame: drop it.
        case replay
        /// Its timestamp was delivered with another size; not recorded. Hold
        /// it until the stream's next packet, then `settleSuspect`.
        /// `closesReplay`: the packet before it on its stream was a replay.
        case suspect(closesReplay: Bool)
    }

    /// Media time around the latest packet a stream's history covers. Server
    /// bursts are a few seconds; the margin covers slow reconnects.
    let window: Int64
    /// Backstop per stream, for sources whose timestamps barely move.
    let capacity: Int

    private struct Key: Hashable {
        let time: Int64
        let size: Int32
    }

    private struct History {
        var order: [Key] = []
        var head = 0
        var members: Set<Key> = []
        /// Delivered packets per timestamp, whatever their size.
        var times: [Int64: Int] = [:]
        var lastWasReplay = false
        /// Newest timestamp of the current timeline (see `record`).
        var newest: Int64?

        var count: Int { order.count - head }

        func verdict(for key: Key) -> Verdict {
            guard let newest, key.time < newest || (key.time == newest && lastWasReplay) else { return .new }
            if members.contains(key) { return .replay }
            if times[key.time] != nil { return .suspect(closesReplay: lastWasReplay) }
            return .new
        }

        mutating func record(_ key: Key, window: Int64, capacity: Int) {
            // A timestamp more than a window behind is a new timeline (an
            // encoder restart), not a replay; it starts its own newest.
            if let current = newest, key.time <= current, current - key.time <= window {
                // Within the current timeline, behind or at its newest.
            } else {
                newest = key.time
            }
            guard members.insert(key).inserted else { return }
            order.append(key)
            times[key.time, default: 0] += 1
            // Oldest first, measured from the latest packet in either
            // direction: after an encoder restart the old timeline lies far
            // *above* the new one.
            while count > 0 {
                let oldest = order[head].time
                let distance = oldest > key.time ? oldest - key.time : key.time - oldest
                guard distance > window || count > capacity else { break }
                evictFirst()
            }
        }

        private mutating func evictFirst() {
            let key = order[head]
            members.remove(key)
            if let remaining = times[key.time], remaining > 1 {
                times[key.time] = remaining - 1
            } else {
                times.removeValue(forKey: key.time)
            }
            head += 1
            // Compact once the dead prefix dominates, keeping appends amortised O(1).
            if head > 1024, head * 2 > order.count {
                order.removeFirst(head)
                head = 0
            }
        }
    }

    private var histories: [Int32: History] = [:]
    /// Packets dropped as replays (suspects included) since creation.
    private(set) var replayedCount = 0

    init(window: Int64 = 60_000_000, capacity: Int = 16_384) {
        self.window = window
        self.capacity = capacity
    }

    /// Judges a packet; records it when it is `.new`. `time` is the packet's
    /// DTS, or its PTS when it has no DTS.
    mutating func classify(stream: Int32, time: Int64, size: Int32) -> Verdict {
        guard MediaTime.isValid(time) else { return .new }
        let key = Key(time: time, size: size)
        // Subscript-with-default mutates in place; a copy out of the
        // dictionary would duplicate the whole history on every packet.
        let verdict = histories[stream, default: History()].verdict(for: key)
        switch verdict {
        case .new:
            histories[stream, default: History()].record(key, window: window, capacity: capacity)
        case .replay:
            replayedCount += 1
        case .suspect:
            break
        }
        histories[stream]?.lastWasReplay = verdict == .replay
        return verdict
    }

    /// Settles a suspect held on `stream` once the stream's next packet was
    /// classified as `next`. Returns true when the suspect is dropped;
    /// otherwise records it as delivered.
    mutating func settleSuspect(
        stream: Int32,
        time: Int64,
        size: Int32,
        closesReplay: Bool,
        followedBy next: Verdict
    ) -> Bool {
        if next == .replay || closesReplay {
            replayedCount += 1
            return true
        }
        if MediaTime.isValid(time) {
            histories[stream, default: History()]
                .record(Key(time: time, size: size), window: window, capacity: capacity)
        }
        return false
    }

    mutating func reset() {
        histories.removeAll()
    }
}
