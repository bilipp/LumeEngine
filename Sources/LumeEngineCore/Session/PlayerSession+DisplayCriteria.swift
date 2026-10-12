extension PlayerSession {
    /// The display mode the selected video wants — refresh rate and dynamic
    /// range of what the engine outputs, after deinterlacing and Dolby Vision
    /// conversion. Predicted from the stream once it is open
    /// (`basis == .stream`), confirmed from the enqueued frames once enough
    /// have gone to the renderer (`.output`). Nil without a video lane.
    ///
    /// Cheap (a lock and a sort of a few dozen intervals); poll it at a low
    /// rate. tvOS applies it with `DisplayCriteriaMatcher`.
    public var displayCriteria: ContentDisplayCriteria? {
        guard let info = mediaInfo,
              let index = selectedVideoTrackIndex,
              let track = info.tracks.first(where: { $0.index == index }),
              let stream = ContentDisplayCriteria.Stream(track: track)
        else { return nil }
        let isDeinterlacing = activeVideoDecoder?.isDeinterlacing ?? false
        let output = renderer.videoOutput.map {
            ContentDisplayCriteria.Output(
                formatDescription: $0.format,
                frameInterval: $0.frameInterval,
                isDeinterlacing: isDeinterlacing
            )
        }
        return ContentDisplayCriteria.resolve(
            stream: stream,
            deinterlacing: configuration.deinterlace,
            output: output
        )
    }
}
