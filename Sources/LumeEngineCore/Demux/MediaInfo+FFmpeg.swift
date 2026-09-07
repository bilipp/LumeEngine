internal import CFFmpeg

// Builders that translate FFmpeg contexts into the engine's value-type models.
// This is the only file that digs through AVFormatContext internals for metadata.

extension MediaInfo {
    init(context: UnsafeMutablePointer<AVFormatContext>) {
        let ctx = context.pointee

        formatName = ctx.iformat.flatMap { String(cString: $0.pointee.name) } ?? "unknown"

        let rawDuration = ctx.duration
        duration = MediaTime.isValid(rawDuration) && rawDuration > 0 ? rawDuration : nil

        startTime = MediaTime.isValid(ctx.start_time) ? ctx.start_time : 0
        bitrate = ctx.bit_rate

        // A source is seekable when its I/O layer says so, or when it exposes a
        // duration (some network protocols report unseekable pb but still seek).
        if let pb = ctx.pb {
            isSeekable = pb.pointee.seekable != 0 || duration != nil
        } else {
            isSeekable = duration != nil
        }

        metadata = Self.dictionary(from: ctx.metadata)

        var builtTracks: [TrackInfo] = []
        if let streams = ctx.streams {
            for i in 0..<Int(ctx.nb_streams) {
                guard let stream = streams[i] else { continue }
                builtTracks.append(TrackInfo(stream: stream, context: context))
            }
        }
        tracks = builtTracks

        var builtChapters: [ChapterInfo] = []
        if let chapters = ctx.chapters {
            for i in 0..<Int(ctx.nb_chapters) {
                guard let chapter = chapters[i] else { continue }
                let timeBase = chapter.pointee.time_base
                builtChapters.append(ChapterInfo(
                    title: Self.dictionary(from: chapter.pointee.metadata)["title"],
                    start: MediaTime.fromStream(chapter.pointee.start, timeBase: timeBase),
                    end: MediaTime.fromStream(chapter.pointee.end, timeBase: timeBase)
                ))
            }
        }
        chapters = builtChapters
    }

    static func dictionary(from dict: OpaquePointer?) -> [String: String] {
        var result: [String: String] = [:]
        var entry: UnsafePointer<AVDictionaryEntry>?
        while let next = av_dict_iterate(dict, entry) {
            if let key = next.pointee.key, let value = next.pointee.value {
                result[String(cString: key)] = String(cString: value)
            }
            entry = next
        }
        return result
    }
}

extension TrackInfo {
    init(stream: UnsafeMutablePointer<AVStream>, context: UnsafeMutablePointer<AVFormatContext>) {
        let st = stream.pointee
        let par = st.codecpar.pointee

        index = st.index
        wrapBits = st.pts_wrap_bits

        switch par.codec_type {
        case AVMEDIA_TYPE_VIDEO: kind = .video
        case AVMEDIA_TYPE_AUDIO: kind = .audio
        case AVMEDIA_TYPE_SUBTITLE: kind = .subtitle
        case AVMEDIA_TYPE_DATA: kind = .data
        case AVMEDIA_TYPE_ATTACHMENT: kind = .attachment
        default: kind = .unknown
        }

        codecName = String(cString: avcodec_get_name(par.codec_id))
        codecID = par.codec_id.rawValue
        bitrate = par.bit_rate

        let meta = MediaInfo.dictionary(from: st.metadata)
        language = meta["language"]
        title = meta["title"]
        isDefault = st.disposition & AV_DISPOSITION_DEFAULT != 0
        isForced = st.disposition & AV_DISPOSITION_FORCED != 0

        if par.codec_type == AVMEDIA_TYPE_VIDEO {
            let fpsRational = av_guess_frame_rate(context, stream, nil)
            let fps = fpsRational.den > 0 ? av_q2d(fpsRational) : 0

            var bitDepth = 0
            var pixelFormatName: String?
            if par.format >= 0 {
                let pixelFormat = AVPixelFormat(rawValue: par.format)
                if let descriptor = av_pix_fmt_desc_get(pixelFormat) {
                    bitDepth = Int(descriptor.pointee.comp.0.depth)
                }
                if let name = av_get_pix_fmt_name(pixelFormat) {
                    pixelFormatName = String(cString: name)
                }
            }

            var rotation = 0
            if let sideData = av_packet_side_data_get(
                par.coded_side_data, par.nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX
            ), let data = sideData.pointee.data {
                let degrees = data.withMemoryRebound(to: Int32.self, capacity: 9) {
                    av_display_rotation_get($0)
                }
                if degrees.isFinite {
                    rotation = (Int(degrees.rounded()) % 360 + 360) % 360
                }
            }

            // Dolby Vision is declared by the container (mp4 `dvcC`/`dvvC`,
            // MPEG-TS DOVI descriptor), which libavformat surfaces as coded
            // side data — same shape as the display matrix above.
            var dolbyVision: DolbyVision?
            if let sideData = av_packet_side_data_get(
                par.coded_side_data, par.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF
            ), let data = sideData.pointee.data,
               sideData.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size {
                // All-uint8_t record: alignment 1, so rebinding is safe.
                let record = data.withMemoryRebound(
                    to: AVDOVIDecoderConfigurationRecord.self, capacity: 1
                ) { $0.pointee }
                dolbyVision = DolbyVision(
                    profile: Int(record.dv_profile),
                    level: Int(record.dv_level),
                    blCompatibilityID: Int(record.dv_bl_signal_compatibility_id),
                    hasRPU: record.rpu_present_flag != 0,
                    hasBaseLayer: record.bl_present_flag != 0
                )
            }

            // Profile-5 streams routinely leave color_trc unspecified, so the
            // DV declaration is a third way to know the stream is HDR.
            let isHDR = par.color_trc == AVCOL_TRC_SMPTE2084
                || par.color_trc == AVCOL_TRC_ARIB_STD_B67
                || dolbyVision != nil

            video = Video(
                width: Int(par.width),
                height: Int(par.height),
                fps: fps,
                bitDepth: bitDepth,
                pixelFormatName: pixelFormatName,
                rotation: rotation,
                isHDR: isHDR,
                colorPrimaries: par.color_primaries.rawValue,
                colorTransfer: par.color_trc.rawValue,
                colorSpace: par.color_space.rawValue,
                colorRangeFull: par.color_range == AVCOL_RANGE_JPEG,
                dolbyVision: dolbyVision
            )
        } else {
            video = nil
        }

        if par.codec_type == AVMEDIA_TYPE_AUDIO {
            audio = Audio(
                channels: Int(par.ch_layout.nb_channels),
                sampleRate: Int(par.sample_rate),
                profile: par.profile,
                isObjectAudio: Self.declaresObjectAudio(codecName: codecName, profile: par.profile),
                channelLayoutName: Self.channelLayoutName(par.ch_layout)
            )
        } else {
            audio = nil
        }
    }

    /// True when a codec+profile pair declares Dolby Atmos object audio: E-AC-3
    /// with the JOC profile, or TrueHD with the Atmos profile.
    ///
    /// The gate on the codec is the whole point. `AV_PROFILE_EAC3_DDP_ATMOS`
    /// and `AV_PROFILE_TRUEHD_ATMOS` are *both* the number 30, and 30 is a
    /// perfectly ordinary profile elsewhere — DTS-ES is 30 — so comparing the
    /// profile alone would label unrelated tracks as Atmos.
    ///
    /// Keyed on FFmpeg's canonical codec name rather than `AVCodecID` so the
    /// gate is unit-testable: `CFFmpeg` is an `internal import`, so the enum
    /// cases are not nameable from the test target, while the two names here
    /// are stable FFmpeg API (`avcodec_get_name`).
    static func declaresObjectAudio(codecName: String, profile: Int32) -> Bool {
        switch codecName {
        case "eac3": profile == AV_PROFILE_EAC3_DDP_ATMOS
        case "truehd": profile == AV_PROFILE_TRUEHD_ATMOS
        default: false
        }
    }

    /// FFmpeg's formal name for a channel layout ("5.1(side)", "7.1", …).
    /// `nil` when the layout is unset or the description fails.
    private static func channelLayoutName(_ layout: AVChannelLayout) -> String? {
        var layout = layout
        let capacity = 128
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: capacity)
        let written = withUnsafePointer(to: &layout) { pointer in
            av_channel_layout_describe(pointer, buffer, capacity)
        }
        guard written > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
