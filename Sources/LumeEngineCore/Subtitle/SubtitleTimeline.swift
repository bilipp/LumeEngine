import Foundation

/// One display update from a subtitle decoder on the engine timeline (µs),
/// before the timeline decides how long it stays up.
struct SubtitleEvent: Sendable, Equatable {
    var start: Int64
    /// `nil` when the source gives no end. DVB, PGS and closed captions say
    /// exactly that — "until the next update" — and a decoder that turned it
    /// into a number would leave the text up for 49 days (`UINT32_MAX` ms).
    var end: Int64?
    /// Display text, trimmed. Empty on a replacing track means "clear the
    /// screen", which is how those formats end what is showing.
    var text: String
    /// The track describes the whole screen with every update (closed
    /// captions, DVB, PGS, DVD): an update ends everything shown before it.
    /// Text formats (SRT, ASS, WebVTT, mov_text) overlap freely instead, each
    /// cue carrying its own end.
    var replacesPrevious: Bool

    /// Where an `AVSubtitle` sits on the engine timeline. `base` is the
    /// subtitle's PTS in engine µs, display times are milliseconds after it.
    /// `nil` end means open: shows until replaced (see `SubtitleTimeline`).
    static func span(
        base: Int64,
        startDisplay: UInt32,
        endDisplay: UInt32,
        packetDuration: Int64,
        replacesPrevious: Bool
    ) -> (start: Int64, end: Int64?) {
        let start = base + Int64(startDisplay) * 1_000
        // UINT32_MAX is FFmpeg's "no end" (PGS always, closed captions in
        // real-time mode, DVB without a computed end).
        guard endDisplay != .max else { return (start, nil) }
        let end = base + Int64(endDisplay) * 1_000
        if endDisplay != 0, end > start { return (start, end) }
        // No usable end. A replacing track's update lasts until the next one;
        // a text cue without one gets its packet's duration, or a reading-time
        // guess, as it always has.
        if replacesPrevious { return (start, nil) }
        return (start, packetDuration > 0 ? base + packetDuration : start + 3_000_000)
    }
}

/// The cue-lifecycle policy behind `SubtitleStore`: a timeline of cues sorted
/// by start, deciding how long each one shows. Pure value type — the store
/// adds the lock.
///
/// The failure modes it exists for, all of which used to reach the screen:
/// - Cues without an end (PGS, closed captions, DVB "until the next page")
///   stayed up for good, piling onto every later cue.
/// - The empty update that DVB, PGS and closed captions send to clear the
///   screen was dropped as "no text", so the previous cue stayed for its full
///   timeout (DVB pages time out after tens of seconds).
/// - Every cue a live session ever decoded was kept: a day of roll-up
///   captions is hundreds of thousands of them.
///
/// The rules:
/// - An open cue ends where the next update of its track starts, or after
///   `openEndedLimit` when none comes.
/// - On a replacing track every update — cue or clear — ends everything
///   shown before it, and when one arrives out of order (a range re-read
///   after a seek) the update already stored after it bounds it in turn.
/// - Text tracks keep their overlaps; only their open cues are ended by the
///   next cue.
/// - An update already held is dropped, so re-reading a range (backward
///   seek, backfill seek) does not double its lines. On a replacing track a
///   different update at the same start replaces the stored one: the screen
///   at one instant has one state, and the latest decode of it wins.
/// - At most `capacity` cues are kept; the ones farthest from where cues are
///   being added go first.
struct SubtitleTimeline: Sendable {
    /// How long an open cue stays without a successor. Caption decoders on
    /// televisions erase a caption left standing by about this long without
    /// caption data; a longer limit leaves stale text over the next scene
    /// when a clear is lost, a shorter one cuts captions that are still
    /// being spoken.
    static let openEndedLimit: Int64 = 16_000_000

    /// Cues kept. Far above any film's subtitle file (a few thousand cues);
    /// for a live track it is half an hour or more of roll-up captions.
    static let capacity = 8_192

    /// How far back from an insertion point active cues are looked for.
    /// Overlap is rare and short-lived; a replacing track has at most one.
    private static let scanLimit = 64

    private struct Entry: Sendable {
        var cue: SubtitleCue
        /// The end is the limit, not the source's: the next update or a seek
        /// may still bound it.
        var provisional: Bool
    }

    private var entries: [Entry] = []
    private var nextID: UInt64 = 0

    var count: Int { entries.count }

    mutating func apply(_ event: SubtitleEvent) {
        if event.text.isEmpty {
            // A clear. Text tracks have no such thing; an empty text cue is
            // just nothing to show.
            guard event.replacesPrevious else { return }
            end(at: event.start, onlyProvisional: false)
            return
        }

        if isDuplicate(event) { return }
        if event.replacesPrevious { removeEntries(startingAt: event.start) }
        // What this update takes over from: everything on screen for a
        // replacing track, only the cues with no end of their own otherwise.
        end(at: event.start, onlyProvisional: !event.replacesPrevious)

        let index = insertionIndex(for: event.start)
        var end = event.end ?? event.start + Self.openEndedLimit
        if (event.replacesPrevious || event.end == nil), index < entries.count {
            // Arrived out of order: the next update already stored ends it.
            end = min(end, entries[index].cue.start)
        }
        guard end > event.start else { return }

        entries.insert(
            Entry(
                cue: SubtitleCue(id: nextID, start: event.start, end: end, text: event.text),
                provisional: event.end == nil
            ),
            at: index
        )
        nextID += 1
        trim(keeping: index)
    }

    /// Ends open cues at a discontinuity (a seek to `time`): the screen state
    /// after it is unknown until the source sends its next update, and
    /// showing the stale one meanwhile is worse than showing nothing. Cues
    /// with an end from the source are facts about the timeline and stay.
    mutating func closeOpenCues(at time: Int64) {
        end(at: time, onlyProvisional: true)
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    /// All cues covering `time` (engine µs), ordered by start.
    func activeCues(at time: Int64) -> [SubtitleCue] {
        var active: [SubtitleCue] = []
        var index = insertionIndex(for: time) - 1
        var scanned = 0
        while index >= 0 && scanned < Self.scanLimit {
            let cue = entries[index].cue
            if cue.start <= time && time < cue.end {
                active.append(cue)
            }
            index -= 1
            scanned += 1
        }
        return active.reversed()
    }

    // MARK: Internals

    /// First entry starting after `time`.
    private func insertionIndex(for time: Int64) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].cue.start <= time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func isDuplicate(_ event: SubtitleEvent) -> Bool {
        var index = insertionIndex(for: event.start) - 1
        while index >= 0 && entries[index].cue.start == event.start {
            let entry = entries[index]
            if entry.cue.text == event.text {
                // A stored end may have been bounded by a successor since, so
                // it only has to match where both ends came from the source.
                if event.replacesPrevious || event.end == nil || entry.provisional { return true }
                if entry.cue.end == event.end { return true }
            }
            index -= 1
        }
        return false
    }

    private mutating func removeEntries(startingAt start: Int64) {
        var index = insertionIndex(for: start) - 1
        while index >= 0 && entries[index].cue.start == start {
            entries.remove(at: index)
            index -= 1
        }
    }

    /// Ends the cues that started before `time` and still show at it.
    private mutating func end(at time: Int64, onlyProvisional: Bool) {
        var index = insertionIndex(for: time) - 1
        var scanned = 0
        while index >= 0 && scanned < Self.scanLimit {
            let entry = entries[index]
            if entry.cue.start < time, entry.cue.end > time, !onlyProvisional || entry.provisional {
                entries[index].cue = SubtitleCue(
                    id: entry.cue.id, start: entry.cue.start, end: time, text: entry.cue.text
                )
            }
            index -= 1
            scanned += 1
        }
    }

    /// Drops cues beyond `capacity` from the end farther from `index`, where
    /// cues are being added — the front on a live timeline, the back after a
    /// seek far into the past of a long file. Drops an eighth more than
    /// needed so the shift is not paid on every insert.
    private mutating func trim(keeping index: Int) {
        guard entries.count > Self.capacity else { return }
        let excess = entries.count - Self.capacity + Self.capacity / 8
        if index < entries.count / 2 {
            entries.removeLast(excess)
        } else {
            entries.removeFirst(excess)
        }
    }
}
