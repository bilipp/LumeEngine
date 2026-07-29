import Foundation
import Testing
@testable import LumeEngineCore

@Suite("Subtitle parsing")
struct SubtitleParserTests {
    @Test("modern ASS event (8 leading fields)")
    func modernEvent() {
        let event = "1,0,Default,,0,0,0,,Hello {\\i1}world{\\i0}!"
        #expect(SubtitleTextParser.text(fromASSEvent: event) == "Hello world!")
    }

    @Test("classic Dialogue: event (9 leading fields)")
    func dialogueEvent() {
        let event = "Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,Line one\\NLine two"
        #expect(SubtitleTextParser.text(fromASSEvent: event) == "Line one\nLine two")
    }

    @Test("override tags, hard spaces, commas in text")
    func styling() {
        let event = "2,0,Default,,0,0,0,,{\\an8\\c&HFFFFFF&}Top, center\\htext"
        #expect(SubtitleTextParser.text(fromASSEvent: event) == "Top, center text")
    }

    @Test("store returns cues covering a timestamp")
    func store() {
        let store = SubtitleStore()
        store.insert(start: 1_000_000, end: 3_000_000, text: "one")
        store.insert(start: 4_000_000, end: 6_000_000, text: "two")
        store.insert(start: 2_500_000, end: 5_000_000, text: "overlap")

        #expect(store.activeCues(at: 0).isEmpty)
        #expect(store.activeCues(at: 2_000_000).map(\.text) == ["one"])
        #expect(Set(store.activeCues(at: 2_700_000).map(\.text)) == ["one", "overlap"])
        #expect(Set(store.activeCues(at: 4_500_000).map(\.text)) == ["overlap", "two"])
        #expect(store.activeCues(at: 6_500_000).isEmpty)
    }
}

@Suite("Tracks & subtitles", .serialized)
struct TrackSubtitleTests {
    private func eventually(
        timeout: TimeInterval = 10,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func makeSession() -> PlayerSession {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.3
        return PlayerSession(configuration: configuration)
    }

    @Test("embedded SRT track produces timed cues", .timeLimit(.minutes(1)))
    func embeddedSubtitles() async throws {
        let session = makeSession()
        let info = try await session.open(url: try Fixtures.path("multitrack.mkv"))
        let subtitleTrack = try #require(info.subtitleTracks.first)

        await session.selectSubtitleTrack(subtitleTrack.index)
        await session.play()
        _ = await eventually { await session.state == .playing }

        // Fixture cues: 1–3 s "Hello from LumeEngine", 4–6 s "Second cue".
        let sawCues = await eventually {
            session.subtitles.count >= 2
        }
        #expect(sawCues, "both cues should decode, store has \(session.subtitles.count)")

        let start = info.startTime
        let atTwoSeconds = session.subtitles.activeCues(at: start + 2_000_000)
        #expect(atTwoSeconds.map(\.text) == ["Hello from LumeEngine"])
        let atFiveSeconds = session.subtitles.activeCues(at: start + 5_000_000)
        #expect(atFiveSeconds.map(\.text) == ["Second cue"])
        let atGap = session.subtitles.activeCues(at: start + 3_500_000)
        #expect(atGap.isEmpty)

        // Deselect clears the store.
        await session.selectSubtitleTrack(nil)
        #expect(session.subtitles.count == 0)

        await session.shutdown()
    }

    @Test("subtitles selected before play backfill cues the demuxer already read", .timeLimit(.minutes(1)))
    func subtitlesSelectedBeforePlayBackfill() async throws {
        // multitrack.mkv is 8 s and the default read-ahead is 15 s, so open()
        // pulls the entire file — every subtitle packet included — into the
        // packet queues within milliseconds. Waiting here makes that certain
        // instead of racy: any cue delivery after this point can only come from
        // selectSubtitleTrack's backfill.
        //
        // `embeddedSubtitles` covers the same ground but only catches this by
        // losing a race, which is why the bug reached CI as an intermittent
        // failure and passed locally for weeks. Selecting a track before play()
        // used to skip the backfill entirely and yield a session with subtitles
        // enabled and permanently zero cues.
        let session = makeSession()
        let info = try await session.open(url: try Fixtures.path("multitrack.mkv"))
        let subtitleTrack = try #require(info.subtitleTracks.first)
        try await Task.sleep(for: .milliseconds(600))

        await session.selectSubtitleTrack(subtitleTrack.index)
        await session.play()

        let sawCues = await eventually { session.subtitles.count >= 2 }
        #expect(sawCues, "backfill must recover cues read before selection, store has \(session.subtitles.count)")
        let start = info.startTime
        #expect(session.subtitles.activeCues(at: start + 2_000_000).map(\.text) == ["Hello from LumeEngine"])
        #expect(session.subtitles.activeCues(at: start + 5_000_000).map(\.text) == ["Second cue"])

        await session.shutdown()
    }

    @Test("external SRT file loads into the cue store", .timeLimit(.minutes(1)))
    func externalSubtitles() async throws {
        // The fixture generator leaves subs.srt next to the media.
        _ = try Fixtures.path("multitrack.mkv")
        let sidecar = Fixtures.outputDirectory.appendingPathComponent("subs.srt").path

        let session = makeSession()
        _ = try await session.open(url: try Fixtures.path("basic.mp4"))
        try await session.loadExternalSubtitles(url: sidecar)

        #expect(session.subtitles.count == 2)
        #expect(await session.usingExternalSubtitles)
        let cues = session.subtitles.activeCues(at: 2_000_000)
        #expect(cues.map(\.text) == ["Hello from LumeEngine"])

        await session.shutdown()
    }

    @Test("audio track switch mid-playback keeps playing", .timeLimit(.minutes(1)))
    func audioSwitch() async throws {
        let session = makeSession()
        let info = try await session.open(url: try Fixtures.path("multitrack.mkv"))
        let english = try #require(info.audioTracks.first { $0.language == "eng" })
        let german = try #require(info.audioTracks.first { $0.language == "ger" })
        #expect(await session.selectedAudioTrackIndex == english.index, "default should be the first audio track")

        await session.play()
        _ = await eventually { await session.state == .playing }
        try await Task.sleep(for: .milliseconds(700))

        await session.selectAudioTrack(german.index)
        #expect(await session.selectedAudioTrackIndex == german.index)

        // Playback must recover and keep advancing on the new lane.
        let playing = await eventually { await session.state == .playing }
        #expect(playing, "state must return to .playing after track switch")
        let p1 = await session.position
        try await Task.sleep(for: .milliseconds(800))
        let p2 = await session.position
        #expect(p2 > p1 + 0.3, "clock must keep advancing after audio switch (was \(p1), now \(p2))")

        await session.shutdown()
    }
}
