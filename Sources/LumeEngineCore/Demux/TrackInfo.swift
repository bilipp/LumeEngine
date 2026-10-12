/// Engine-facing description of one stream in the container.
/// Pure value type — built once at open, never mutated.
public struct TrackInfo: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable {
        case video, audio, subtitle, data, attachment, unknown
    }

    public struct Video: Sendable, Equatable {
        public let width: Int
        public let height: Int
        /// Best-guess frames per second (0 when unknown).
        public let fps: Double
        public let bitDepth: Int
        public let pixelFormatName: String?
        /// Counter-clockwise display rotation in degrees (0/90/180/270).
        public let rotation: Int
        /// True when transfer characteristics indicate PQ (HDR10/DV) or HLG.
        public let isHDR: Bool
        /// Raw AVColorPrimaries / AVColorTransferCharacteristic / AVColorSpace values.
        public let colorPrimaries: UInt32
        public let colorTransfer: UInt32
        public let colorSpace: UInt32
        public let colorRangeFull: Bool
        /// Whether the stream is coded interlaced, from the field order the
        /// container or codec reports; nil when it reports none. A prediction
        /// only: whether frames really come out interlaced is decided per
        /// frame (`VideoDecoder.isDeinterlacing`).
        public let isInterlaced: Bool?
        /// The stream's Dolby Vision configuration record; nil when it has none.
        public let dolbyVision: DolbyVisionConfiguration?
    }

    public struct Audio: Sendable, Equatable {
        public let channels: Int
        public let sampleRate: Int
    }

    /// Stream index in the container — stable for the session.
    public let index: Int32
    public var id: Int32 { index }

    public let kind: Kind
    public let codecName: String
    /// Raw `AVCodecID` value.
    public let codecID: UInt32
    public let language: String?
    public let title: String?
    public let isDefault: Bool
    public let isForced: Bool
    public let bitrate: Int64
    public let video: Video?
    public let audio: Audio?

    /// Container timestamp width for this stream (`AVStream.pts_wrap_bits`);
    /// drives the wrap unwrapper.
    public let wrapBits: Int32

    /// Whether this build has a decoder the engine would open for the track:
    /// for video on either the VideoToolbox or the software path. False for
    /// codecs FFmpeg demuxes but cannot decode — AC-4 and MPEG-H 3D Audio in
    /// DVB/ATSC muxes are the usual ones — and for data and attachment
    /// streams. Such tracks are listed but never chosen automatically;
    /// selecting one explicitly ends in a `.decoderInitFailed` error.
    public internal(set) var isDecodable = true
}

/// A Dolby Vision decoder configuration record (`dvcC`/`dvvC`/`dvwC`), as the
/// container or the stream's descriptor carries it.
public struct DolbyVisionConfiguration: Sendable, Equatable {
    public let versionMajor: UInt8
    public let versionMinor: UInt8
    public let profile: UInt8
    public let level: UInt8
    public let hasRPU: Bool
    public let hasEnhancementLayer: Bool
    public let hasBaseLayer: Bool
    /// What the base layer is on its own: 0 none (IPTPQc2), 1 HDR10, 2 SDR,
    /// 4 HLG, 6 BT.2020 HDR10.
    public let baseLayerCompatibilityID: UInt8
    public let metadataCompression: UInt8

    public init(
        versionMajor: UInt8 = 1,
        versionMinor: UInt8 = 0,
        profile: UInt8,
        level: UInt8,
        hasRPU: Bool = true,
        hasEnhancementLayer: Bool = false,
        hasBaseLayer: Bool = true,
        baseLayerCompatibilityID: UInt8,
        metadataCompression: UInt8 = 0
    ) {
        self.versionMajor = versionMajor
        self.versionMinor = versionMinor
        self.profile = profile
        self.level = level
        self.hasRPU = hasRPU
        self.hasEnhancementLayer = hasEnhancementLayer
        self.hasBaseLayer = hasBaseLayer
        self.baseLayerCompatibilityID = baseLayerCompatibilityID
        self.metadataCompression = metadataCompression
    }

    /// The record claims an IPTPQc2 base layer rather than a displayable
    /// fallback (HDR10, SDR, HLG): profiles 5, 10.0 and 20. Records lie
    /// (remuxes label HDR10 as profile 5), so the engine decides per frame
    /// whether to convert to HDR10 (`DolbyVisionDetection`); this is the
    /// stream-level claim.
    public var baseLayerIsIPT: Bool {
        DolbyVisionDetection.Record(self).claimsIPT
    }
}

extension TrackInfo {
    /// Index of the closed-caption track carried inside the video stream
    /// (CEA-608 in A/53 side data — how US broadcast and much IPTV ship
    /// captions). It is no container stream, so it gets an index no container
    /// reaches ("CC" in ASCII, channel 1); pass it to `selectSubtitleTrack`
    /// like any other subtitle index.
    public static let embeddedClosedCaptionsIndex: Int32 = 0x4343_0001

    /// True for the synthetic closed-caption track (`embeddedClosedCaptionsIndex`),
    /// which `PlayerSession.mediaInfo` lists once captions turn up in the video.
    public var isEmbeddedClosedCaptions: Bool {
        index == Self.embeddedClosedCaptionsIndex
    }
}

/// A chapter marker, in engine microseconds.
public struct ChapterInfo: Sendable, Equatable {
    public let title: String?
    public let start: Int64
    public let end: Int64

    public init(title: String?, start: Int64, end: Int64) {
        self.title = title
        self.start = start
        self.end = end
    }
}

/// Everything the engine knows about an opened source.
public struct MediaInfo: Sendable {
    public let formatName: String
    /// Total duration in engine µs; `nil` for live/unbounded streams.
    public let duration: Int64?
    /// Timestamp of the first packet on the source timeline (engine µs, 0 if unknown).
    /// Positions reported to the app are relative to this baseline.
    public let startTime: Int64
    public let isSeekable: Bool
    public let bitrate: Int64
    public let metadata: [String: String]
    /// Streams found at open, plus tracks discovered while playing (the
    /// closed-caption track — see `PlayerSession.mediaInfo`).
    public internal(set) var tracks: [TrackInfo]
    public let chapters: [ChapterInfo]

    public var videoTracks: [TrackInfo] { tracks.filter { $0.kind == .video } }
    public var audioTracks: [TrackInfo] { tracks.filter { $0.kind == .audio } }
    public var subtitleTracks: [TrackInfo] { tracks.filter { $0.kind == .subtitle } }

    /// Live heuristic: no known duration.
    public var isLive: Bool { duration == nil }

    /// This info with `track` appended, unless a track with its index is
    /// already listed.
    func adding(_ track: TrackInfo) -> MediaInfo {
        guard !tracks.contains(where: { $0.index == track.index }) else { return self }
        var copy = self
        copy.tracks.append(track)
        return copy
    }
}
