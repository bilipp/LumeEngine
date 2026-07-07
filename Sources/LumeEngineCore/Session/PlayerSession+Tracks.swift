import Foundation

// Runtime track selection (PLAN.md P5). The pattern for every switch is the
// same: tear down the old lane completely, build a fresh one, then reuse the
// ordinary seek path to re-sync all lanes from the playhead — no bespoke
// "partial rebuild" states to get wrong.
extension PlayerSession {
    /// Switches the audio lane to another stream of the open source.
    public func selectAudioTrack(_ index: Int32) {
        guard let demuxer = activeDemuxer,
              index != selectedAudioTrackIndex,
              let parameters = demuxer.codecParameters(forStream: index)
        else { return }

        replaceAudioLane(demuxer: demuxer, trackIndex: index, parameters: parameters)

        // Re-sync every lane from the playhead (also drops in-flight frames of
        // the old track via the serial bump).
        if mediaInfo?.isSeekable == true {
            seek(to: position)
        }
    }

    /// Selects an embedded subtitle track, or `nil` to disable subtitles.
    public func selectSubtitleTrack(_ index: Int32?) {
        teardownSubtitleLane()
        guard let index,
              let demuxer = activeDemuxer,
              let parameters = demuxer.codecParameters(forStream: index)
        else { return }

        let packets = Channel<Packet>(capacity: 128)
        demuxer.attach(channel: packets, toStream: index)
        let decoder = SubtitleDecoder(parameters: parameters, input: packets, store: subtitles)
        installSubtitleLane(trackIndex: index, packets: packets, decoder: decoder)
        decoder.start()

        // Pick up cues that started before the current demux position.
        if mediaInfo?.isSeekable == true, state == .playing || state == .paused {
            seek(to: position)
        }
    }

    /// Loads a sidecar subtitle file (SRT/VTT/ASS/…) into the session's cue
    /// store, replacing any embedded selection. Resolves once the file is
    /// fully parsed.
    public func loadExternalSubtitles(url: String) async throws {
        teardownSubtitleLane()

        let demuxer = Demuxer(url: url, options: DemuxerOptions())
        demuxer.start()

        var iterator = demuxer.events.makeAsyncIterator()
        guard case .opened(let info)? = await iterator.next() else {
            demuxer.shutdown()
            throw EngineError(code: .openFailed, message: "cannot open subtitle file \(url)")
        }
        guard let track = info.subtitleTracks.first,
              let parameters = demuxer.codecParameters(forStream: track.index)
        else {
            demuxer.shutdown()
            throw EngineError(code: .unsupported, message: "no subtitle track in \(url)")
        }

        let packets = Channel<Packet>(capacity: 512)
        demuxer.attach(channel: packets, toStream: track.index)
        let decoder = SubtitleDecoder(parameters: parameters, input: packets, store: subtitles)
        decoder.start()
        demuxer.resume()

        // Sidecar files are tiny: read to EOF, then tear the loader down.
        while let event = await iterator.next() {
            if case .endOfStream = event { break }
            if case .failed(let error) = event {
                demuxer.shutdown()
                decoder.shutdown()
                throw error
            }
        }
        demuxer.shutdown() // closes the packet channel → decoder drains and stops
        decoder.shutdown()
        markExternalSubtitlesActive()
    }
}
