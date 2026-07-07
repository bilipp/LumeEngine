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
