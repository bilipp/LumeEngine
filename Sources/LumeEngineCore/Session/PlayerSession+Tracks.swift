import Foundation

// Runtime track selection (PLAN.md P5). The pattern for every switch is the
// same: tear down the old lane completely, build a fresh one, then reuse the
// ordinary seek path to re-sync all lanes from the playhead — no bespoke
// "partial rebuild" states to get wrong.
extension PlayerSession {
    /// Switches the audio lane to another stream of the open source, or tears it
    /// down with `nil` — matching `selectSubtitleTrack`, where `nil` means off.
    public func selectAudioTrack(_ index: Int32?) {
        guard let index else {
            guard selectedAudioTrackIndex != nil else { return }
            teardownAudioLane()
            return
        }
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

    /// Turns audio on or off for an already-open session, landing on the track
    /// `open` would have chosen.
    ///
    /// This is not a mute: muting silences the renderer while it keeps pulling
    /// frames and keeps its claim on the audio output route. Where several
    /// sessions play at once — Lume's Multi-View grid runs up to four — a silent
    /// one must hold no claim at all, because a renderer that cannot get the
    /// route never becomes ready and stalls the synchronizer its video lane
    /// shares. Use `renderer.isMuted` for a momentary silence, this to give the
    /// audio up.
    ///
    /// A source with no audio track, or a session not yet open, is a no-op.
    public func setAudioEnabled(_ enabled: Bool) {
        guard enabled else {
            selectAudioTrack(nil)
            return
        }
        guard selectedAudioTrackIndex == nil,
              let info = mediaInfo,
              let track = defaultAudioTrack(in: info)
        else { return }
        selectAudioTrack(track.index)
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

        // Pick up cues the demuxer has already read past.
        //
        // The demuxer starts filling packet queues at open(), so by the time a
        // subtitle lane is attached its packets may already be gone — and a
        // read-ahead longer than the media (or just a small local file) means
        // *every* subtitle packet can be consumed within milliseconds of open.
        // This backfill used to be gated on .playing/.paused, which missed the
        // most natural call order of all: select the track, then play. That
        // silently produced a session with subtitles enabled and no cues,
        // permanently for short VOD. Any state with a live demuxer needs it.
        switch state {
        case .ready, .buffering, .playing, .paused:
            if mediaInfo?.isSeekable == true { seek(to: position) }
        case .idle, .opening, .ended, .failed:
            break // no demuxer progress to recover from
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
        decoder.drainAndShutdown() // shutdown() would race the drain and drop trailing cues
        markExternalSubtitlesActive()
    }
}
