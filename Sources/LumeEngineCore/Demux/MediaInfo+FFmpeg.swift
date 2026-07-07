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

            let isHDR = par.color_trc == AVCOL_TRC_SMPTE2084 || par.color_trc == AVCOL_TRC_ARIB_STD_B67

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
                colorRangeFull: par.color_range == AVCOL_RANGE_JPEG
            )
        } else {
            video = nil
        }

        if par.codec_type == AVMEDIA_TYPE_AUDIO {
            audio = Audio(
                channels: Int(par.ch_layout.nb_channels),
                sampleRate: Int(par.sample_rate)
            )
        } else {
            audio = nil
        }
    }
}
