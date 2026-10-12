import Foundation
import Testing
@testable import LumeEngineCore

@Suite("Subtitle cue lifecycle")
struct SubtitleTimelineTests {
    private let second: Int64 = 1_000_000

    private func screen(_ start: Int64, _ text: String, end: Int64? = nil) -> SubtitleEvent {
        SubtitleEvent(start: start, end: end, text: text, replacesPrevious: true)
    }

    private func text(_ start: Int64, _ text: String, end: Int64?) -> SubtitleEvent {
        SubtitleEvent(start: start, end: end, text: text, replacesPrevious: false)
    }

    private func shown(_ timeline: SubtitleTimeline, at time: Int64) -> [String] {
        timeline.activeCues(at: time).map(\.text)
    }

    // MARK: Timing of one AVSubtitle

    @Test("UINT32_MAX end means open, on any track")
    func endlessIsOpen() {
        let span = SubtitleEvent.span(
            base: 10 * second, startDisplay: 0, endDisplay: .max, packetDuration: 0, replacesPrevious: false
        )
        #expect(span.start == 10 * second)
        #expect(span.end == nil)
    }

    @Test("a missing end is open on a replacing track, a guess on a text track")
    func missingEnd() {
        let replacing = SubtitleEvent.span(
            base: 10 * second, startDisplay: 0, endDisplay: 0, packetDuration: 2 * second, replacesPrevious: true
        )
        #expect(replacing.end == nil)

        let withDuration = SubtitleEvent.span(
            base: 10 * second, startDisplay: 0, endDisplay: 0, packetDuration: 2 * second, replacesPrevious: false
        )
        #expect(withDuration.end == 12 * second)

        let withoutDuration = SubtitleEvent.span(
            base: 10 * second, startDisplay: 500, endDisplay: 0, packetDuration: 0, replacesPrevious: false
        )
        #expect(withoutDuration.start == 10_500_000)
        #expect(withoutDuration.end == 13_500_000)
    }

    @Test("display times are milliseconds after the base")
    func explicitSpan() {
        let span = SubtitleEvent.span(
            base: 10 * second, startDisplay: 250, endDisplay: 4_000, packetDuration: 0, replacesPrevious: true
        )
        #expect(span.start == 10_250_000)
        #expect(span.end == 14 * second)
    }

    // MARK: Replacing tracks (captions, DVB, PGS)

    /// Before the timeline, a cue without an end (`UINT32_MAX` ms) stayed up
    /// for 49 days and every later caption stacked under it.
    @Test("an open cue ends where the next update starts")
    func openCueEndsAtNext() {
        var timeline = SubtitleTimeline()
        timeline.apply(screen(1 * second, "one"))
        timeline.apply(screen(4 * second, "two"))

        #expect(shown(timeline, at: 3 * second) == ["one"])
        #expect(shown(timeline, at: 4 * second) == ["two"])
        #expect(shown(timeline, at: 5 * second) == ["two"])
    }

    /// The empty update DVB/PGS/captions send to clear the screen used to be
    /// dropped as "no text", leaving the previous cue up.
    @Test("a clear ends what is showing and shows nothing itself")
    func clearEndsCue() {
        var timeline = SubtitleTimeline()
        timeline.apply(screen(1 * second, "one"))
        timeline.apply(screen(3 * second, ""))

        #expect(shown(timeline, at: 2 * second) == ["one"])
        #expect(shown(timeline, at: 3 * second).isEmpty)
        #expect(timeline.count == 1)
    }

    @Test("a cue with an end of its own is still ended by the next update")
    func explicitEndCutByNext() {
        var timeline = SubtitleTimeline()
        // DVB page timeouts are long; the next page replaces it well before.
        timeline.apply(screen(1 * second, "page one", end: 31 * second))
        timeline.apply(screen(5 * second, "page two", end: 35 * second))
        #expect(shown(timeline, at: 4 * second) == ["page one"])
        #expect(shown(timeline, at: 6 * second) == ["page two"])
        #expect(shown(timeline, at: 36 * second).isEmpty)
    }

    @Test("an open cue without a successor stops after the limit")
    func openCueIsCapped() {
        var timeline = SubtitleTimeline()
        timeline.apply(screen(1 * second, "stuck"))
        let limit = SubtitleTimeline.openEndedLimit
        #expect(shown(timeline, at: 1 * second + limit - 1) == ["stuck"])
        #expect(shown(timeline, at: 1 * second + limit).isEmpty)
    }

    @Test("an update arriving before one already stored is bounded by it")
    func outOfOrderIsBounded() {
        var timeline = SubtitleTimeline()
        timeline.apply(screen(5 * second, "later"))
        timeline.apply(screen(2 * second, "earlier"))
        #expect(shown(timeline, at: 4 * second) == ["earlier"])
        #expect(shown(timeline, at: 5 * second) == ["later"])
    }

    /// A re-read range (backward seek) sends the same updates again; the
    /// stored ones were bounded by their successors meanwhile, so the ends
    /// differ and only start and text can identify them.
    @Test("re-reading a range does not double it")
    func rereadIsDeduplicated() {
        var timeline = SubtitleTimeline()
        for _ in 0..<2 {
            timeline.apply(screen(1 * second, "one"))
            timeline.apply(screen(3 * second, ""))
            timeline.apply(screen(4 * second, "two"))
        }
        #expect(timeline.count == 2)
        #expect(shown(timeline, at: 2 * second) == ["one"])
        #expect(shown(timeline, at: 3_500_000).isEmpty)
        #expect(shown(timeline, at: 4_500_000) == ["two"])
    }

    @Test("on a replacing track, a different update at the same instant wins")
    func sameStartReplaces() {
        var timeline = SubtitleTimeline()
        timeline.apply(screen(1 * second, "ROW ONE\nROW TWO"))
        // After a seek the caption decoder starts from an empty screen and
        // decodes the same instant differently.
        timeline.apply(screen(1 * second, "ROW TWO"))
        #expect(timeline.count == 1)
        #expect(shown(timeline, at: 2 * second) == ["ROW TWO"])
    }

    // MARK: Text tracks (SRT, ASS, WebVTT)

    @Test("text cues keep their overlaps")
    func textOverlapKept() {
        var timeline = SubtitleTimeline()
        timeline.apply(text(1 * second, "one", end: 5 * second))
        timeline.apply(text(2 * second, "two", end: 4 * second))
        #expect(shown(timeline, at: 3 * second) == ["one", "two"])
        #expect(shown(timeline, at: 4_500_000) == ["one"])
    }

    @Test("an open text cue ends at the next cue, a closed one does not")
    func openTextCueEndsAtNext() {
        var timeline = SubtitleTimeline()
        timeline.apply(text(1 * second, "open", end: nil))
        timeline.apply(text(3 * second, "next", end: 6 * second))
        #expect(shown(timeline, at: 2 * second) == ["open"])
        #expect(shown(timeline, at: 4 * second) == ["next"])
    }

    @Test("an empty text cue is nothing, not a clear")
    func emptyTextCueIgnored() {
        var timeline = SubtitleTimeline()
        timeline.apply(text(1 * second, "one", end: 5 * second))
        timeline.apply(text(2 * second, "", end: 3 * second))
        #expect(shown(timeline, at: 4 * second) == ["one"])
    }

    // MARK: Seeks and growth

    @Test("a seek ends open cues, not the ones the source gave an end")
    func seekClosesOpenCues() {
        var timeline = SubtitleTimeline()
        timeline.apply(screen(1 * second, "open"))
        timeline.apply(text(1 * second, "closed", end: 9 * second))
        timeline.closeOpenCues(at: 4 * second)
        #expect(shown(timeline, at: 3 * second) == ["open", "closed"])
        #expect(shown(timeline, at: 5 * second) == ["closed"])

        // Cues after the seek target are the future of the new position.
        var later = SubtitleTimeline()
        later.apply(screen(10 * second, "ahead"))
        later.closeOpenCues(at: 4 * second)
        #expect(shown(later, at: 11 * second) == ["ahead"])
    }

    /// A day of live roll-up captions is hundreds of thousands of updates;
    /// every one of them used to be kept.
    @Test("the timeline keeps a bounded number of cues, dropping the oldest")
    func boundedGrowth() {
        var timeline = SubtitleTimeline()
        let total = SubtitleTimeline.capacity * 2
        for index in 0..<total {
            timeline.apply(screen(Int64(index) * 200_000, "line \(index)"))
        }
        #expect(timeline.count <= SubtitleTimeline.capacity)
        let last = Int64(total - 1) * 200_000
        #expect(shown(timeline, at: last) == ["line \(total - 1)"])
        #expect(shown(timeline, at: 0).isEmpty)
    }

    @Test("a cue added far before the rest survives the trim")
    func trimKeepsInsertionPoint() {
        var timeline = SubtitleTimeline()
        for index in 0..<SubtitleTimeline.capacity {
            timeline.apply(text(1_000 * second + Int64(index) * second, "line \(index)", end: 1_000 * second + Int64(index) * second + 500_000))
        }
        timeline.apply(text(1 * second, "rewound", end: 2 * second))
        #expect(timeline.count <= SubtitleTimeline.capacity)
        #expect(shown(timeline, at: 1_500_000) == ["rewound"])
    }
}
