internal import CFFmpeg

/// RAII ownership of one `AVPacket`, plus engine-normalized timing.
///
/// Immutable after the demuxer hands it off — that immutability is the entire
/// justification for `@unchecked Sendable` (PLAN.md D2). The only `Unmanaged`-free
/// way FFmpeg buffers cross threads in this engine is inside these wrappers.
public final class Packet: @unchecked Sendable {
    /// Owned pointer; freed in deinit.
    let raw: UnsafeMutablePointer<AVPacket>

    /// Stream index within the source (`AVPacket.stream_index`).
    public let streamIndex: Int32
    /// Presentation timestamp, engine µs, wrap-unwrapped. `MediaTime.noTimestamp` if absent.
    public let pts: Int64
    /// Decode timestamp, engine µs, wrap-unwrapped. `MediaTime.noTimestamp` if absent.
    public let dts: Int64
    /// Duration in engine µs (0 when unknown).
    public let duration: Int64
    /// Seek generation this packet belongs to. Downstream stages drop packets
    /// whose serial doesn't match the current one — stale data from before a
    /// seek can never reach the renderer. (mpv-style serials, PLAN.md §3.4)
    public let serial: UInt64
    public let isKeyframe: Bool

    init(
        adopting raw: UnsafeMutablePointer<AVPacket>,
        pts: Int64,
        dts: Int64,
        duration: Int64,
        serial: UInt64
    ) {
        self.raw = raw
        self.streamIndex = raw.pointee.stream_index
        self.pts = pts
        self.dts = dts
        self.duration = duration
        self.serial = serial
        self.isKeyframe = raw.pointee.flags & AV_PKT_FLAG_KEY != 0
    }

    /// Best-effort ordering timestamp: DTS, falling back to PTS.
    public var orderingTimestamp: Int64 {
        MediaTime.isValid(dts) ? dts : pts
    }

    public var byteCount: Int { Int(raw.pointee.size) }

    deinit {
        var ptr: UnsafeMutablePointer<AVPacket>? = raw
        av_packet_free(&ptr)
    }
}
