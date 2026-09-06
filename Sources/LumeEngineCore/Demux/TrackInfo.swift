/// Engine-facing description of one stream in the container.
/// Pure value type — built once at open, never mutated.
public struct TrackInfo: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable {
        case video, audio, subtitle, data, attachment, unknown
    }

    /// Dolby Vision configuration as the container declares it (`dvcC`/`dvvC`,
    /// or the MPEG-TS DOVI descriptor) — read from the stream's `DOVI_CONF`
    /// side data at open, never from the elementary stream.
    ///
    /// This is *description only*: the engine does not decode or forward RPU
    /// metadata today, so a profile-5 stream still renders from its own
    /// (IPT-PQ-C2) base layer. See PLAN.md §7.
    public struct DolbyVision: Sendable, Equatable {
        /// `dv_profile` — 5 = single-layer IPT-PQ-C2, 8 = single-layer with a
        /// cross-compatible base layer, 7 = dual layer.
        public let profile: Int
        /// `dv_level`.
        public let level: Int
        /// `dv_bl_signal_compatibility_id` — 1 = HDR10 base layer (profile 8.1),
        /// 4 = HLG, 0 = none (the base layer is not independently viewable).
        public let blCompatibilityID: Int
        /// `rpu_present_flag` — per-frame dynamic metadata is carried in-stream.
        public let hasRPU: Bool
        /// `bl_present_flag` — a base layer is present in this stream.
        public let hasBaseLayer: Bool

        public init(profile: Int, level: Int, blCompatibilityID: Int, hasRPU: Bool, hasBaseLayer: Bool) {
            self.profile = profile
            self.level = level
            self.blCompatibilityID = blCompatibilityID
            self.hasRPU = hasRPU
            self.hasBaseLayer = hasBaseLayer
        }
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
        /// True when transfer characteristics indicate PQ (HDR10/DV) or HLG,
        /// or the container declares Dolby Vision.
        public let isHDR: Bool
        /// Raw AVColorPrimaries / AVColorTransferCharacteristic / AVColorSpace values.
        public let colorPrimaries: UInt32
        public let colorTransfer: UInt32
        public let colorSpace: UInt32
        public let colorRangeFull: Bool
        /// Non-nil when the container carries a Dolby Vision configuration record.
        public let dolbyVision: DolbyVision?
    }

    public struct Audio: Sendable, Equatable {
        public let channels: Int
        public let sampleRate: Int
        /// Raw `AVCodecParameters.profile` (`AV_PROFILE_UNKNOWN` when absent).
        public let profile: Int32
        /// True when the codec+profile pair declares Dolby Atmos object audio
        /// (E-AC-3 JOC or TrueHD + Atmos). Detection only — the engine decodes
        /// such a stream to its channel bed and never bitstreams it. See PLAN.md §7.
        public let isObjectAudio: Bool
        /// FFmpeg's formal channel-layout name, e.g. `5.1(side)` or `7.1`.
        public let channelLayoutName: String?
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
    public let tracks: [TrackInfo]
    public let chapters: [ChapterInfo]

    public var videoTracks: [TrackInfo] { tracks.filter { $0.kind == .video } }
    public var audioTracks: [TrackInfo] { tracks.filter { $0.kind == .audio } }
    public var subtitleTracks: [TrackInfo] { tracks.filter { $0.kind == .subtitle } }

    /// Live heuristic: no known duration.
    public var isLive: Bool { duration == nil }
}
