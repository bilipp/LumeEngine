import Foundation
import Testing
@testable import LumeEngineCore

/// Tracks this build demuxes but cannot decode (AC-4 and MPEG-H in DVB/ATSC
/// muxes) are listed in `MediaInfo`, never chosen automatically, and fail with
/// a typed error when the host picks one.
@Suite("Undecodable tracks", .serialized)
struct DecodableTrackTests {
    private func makeSession(audioLanguages: [String] = []) -> PlayerSession {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.5
        configuration.preferredAudioLanguages = audioLanguages
        return PlayerSession(configuration: configuration)
    }

    private func track(_ index: Int32, kind: TrackInfo.Kind, language: String? = nil, isDefault: Bool = false, decodable: Bool) -> TrackInfo {
        var track = TrackInfo(
            index: index, kind: kind, codecName: decodable ? "aac" : "ac4", codecID: 0,
            language: language, title: nil, isDefault: isDefault, isForced: false, bitrate: 0,
            video: nil, audio: kind == .audio ? TrackInfo.Audio(channels: 2, sampleRate: 48_000) : nil,
            wrapBits: 33
        )
        track.isDecodable = decodable
        return track
    }

    private func mediaInfo(_ tracks: [TrackInfo]) -> MediaInfo {
        MediaInfo(
            formatName: "mpegts", duration: nil, startTime: 0, isSeekable: false,
            bitrate: 0, metadata: [:], tracks: tracks, chapters: []
        )
    }

    // MARK: MediaInfo

    @Test("an AC-4 track is listed but marked undecodable", .timeLimit(.minutes(1)))
    func listedButUndecodable() async throws {
        let demuxer = Demuxer(url: try Fixtures.path("ac4.ts"))
        var events = demuxer.events.makeAsyncIterator()
        demuxer.start()
        defer { demuxer.shutdown() }
        guard case .opened(let info)? = await events.next() else {
            Issue.record("expected .opened")
            return
        }
        let ac4 = try #require(info.audioTracks.first { $0.codecName == "ac4" })
        #expect(!ac4.isDecodable)
        #expect(ac4.language == "ger")
        let aac = try #require(info.audioTracks.first { $0.codecName == "aac" })
        #expect(aac.isDecodable)
        let videoDecodable = info.videoTracks.allSatisfy { $0.isDecodable }
        #expect(videoDecodable)
    }

    // MARK: Automatic choice

    @Test("an undecodable first audio track is passed over", .timeLimit(.minutes(1)))
    func firstTrackSkipped() async throws {
        let session = makeSession()
        let info = try await session.open(url: try Fixtures.path("ac4.ts"))
        let aac = try #require(info.audioTracks.first { $0.codecName == "aac" })
        #expect(await session.selectedAudioTrackIndex == aac.index)
        await session.shutdown()
    }

    @Test("a language match does not pull in an undecodable track", .timeLimit(.minutes(1)))
    func languageMatchSkipped() async throws {
        // The German track is the AC-4 one: playable English beats a lane
        // that fails at once.
        let session = makeSession(audioLanguages: ["de"])
        let info = try await session.open(url: try Fixtures.path("ac4.ts"))
        let aac = try #require(info.audioTracks.first { $0.codecName == "aac" })
        #expect(await session.selectedAudioTrackIndex == aac.index)
        await session.shutdown()
    }

    @Test("the default flag does not pull in an undecodable track")
    func defaultFlagSkipped() async {
        let session = makeSession()
        let info = mediaInfo([
            track(0, kind: .audio, isDefault: true, decodable: false),
            track(1, kind: .audio, decodable: true),
            track(2, kind: .audio, decodable: true),
        ])
        #expect(await session.defaultAudioTrack(in: info)?.index == 1)
    }

    @Test("with nothing decodable the choice is unchanged")
    func nothingDecodable() async {
        let session = makeSession(audioLanguages: ["de"])
        let info = mediaInfo([
            track(0, kind: .audio, language: "eng", decodable: false),
            track(1, kind: .audio, language: "ger", decodable: false),
            track(2, kind: .video, decodable: false),
        ])
        #expect(await session.defaultAudioTrack(in: info)?.index == 1)
        #expect(await session.defaultVideoTrack(in: info)?.index == 2)
    }

    @Test("an undecodable video track is passed over")
    func videoSkipped() async {
        let session = makeSession()
        let info = mediaInfo([
            track(0, kind: .video, isDefault: true, decodable: false),
            track(1, kind: .video, decodable: true),
        ])
        #expect(await session.defaultVideoTrack(in: info)?.index == 1)
    }

    // MARK: Explicit choice

    @Test("selecting an undecodable track fails with a typed error", .timeLimit(.minutes(1)))
    func explicitSelectionFails() async throws {
        let session = makeSession()
        let info = try await session.open(url: try Fixtures.path("ac4.ts"))
        let ac4 = try #require(info.audioTracks.first { !$0.isDecodable })

        let failure = Task { () -> EngineError? in
            for await event in session.events {
                if case .error(let error) = event { return error }
            }
            return nil
        }
        await session.selectAudioTrack(ac4.index)
        let timeout = Task {
            try? await Task.sleep(for: .seconds(10))
            failure.cancel()
        }
        let error = await failure.value
        timeout.cancel()
        #expect(error?.code == .decoderInitFailed)
        #expect(await session.selectedAudioTrackIndex == ac4.index)
        await session.shutdown()
    }
}
