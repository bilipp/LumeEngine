import Foundation
import Synchronization

/// One subtitle cue on the engine timeline. Text-only for now; bitmap cues
/// (PGS/DVB) and full libass styling land with the subtitle pack (PLAN.md P5+).
public struct SubtitleCue: Sendable, Equatable, Identifiable {
    public let id: UInt64
    /// Engine µs.
    public let start: Int64
    public let end: Int64
    /// Plain display text (override tags stripped, line breaks preserved).
    public let text: String

    public init(id: UInt64, start: Int64, end: Int64, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Time-indexed cue container, safe for concurrent insert (decoder thread) and
/// query (UI tick). The lifecycle policy — how long a cue shows, what ends it,
/// how many are kept — is `SubtitleTimeline`'s.
///
/// Cues outlive seeks on purpose — the store is a timeline, not a queue — so
/// the same packet reaches it again whenever the demuxer re-reads a range it
/// already delivered: a backward seek, or the seek that backfills a subtitle
/// track selected after the demuxer read past its packets. An identical cue
/// is therefore dropped, or every re-read would show its lines doubled.
public final class SubtitleStore: Sendable {
    private let timeline = Mutex(SubtitleTimeline())

    public init() {}

    /// A text cue with a known end (tests, and the shape every text format
    /// decodes to).
    func insert(start: Int64, end: Int64, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, end > start else { return }
        apply(SubtitleEvent(start: start, end: end, text: trimmed, replacesPrevious: false))
    }

    func apply(_ event: SubtitleEvent) {
        timeline.withLock { $0.apply(event) }
    }

    /// Ends cues still open at `time`: the session seeked there, and what the
    /// source shows after it is unknown until its next update.
    func closeOpenCues(at time: Int64) {
        timeline.withLock { $0.closeOpenCues(at: time) }
    }

    /// All cues covering `time` (engine µs).
    public func activeCues(at time: Int64) -> [SubtitleCue] {
        timeline.withLock { $0.activeCues(at: time) }
    }

    public var count: Int {
        timeline.withLock { $0.count }
    }

    public func removeAll() {
        timeline.withLock { $0.removeAll() }
    }
}
