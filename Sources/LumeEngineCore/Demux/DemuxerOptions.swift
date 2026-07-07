internal import CFFmpeg
import Foundation

/// Per-session demuxer configuration. Value type: two sessions never share
/// configuration state (PLAN.md §3.8 — no global knobs).
public struct DemuxerOptions: Sendable {
    /// Raw AVFormat options merged last (escape hatch for container-specific tuning).
    public var formatOptions: [String: String] = [:]
    /// HTTP headers, joined per FFmpeg's `headers` option.
    public var httpHeaders: [String: String] = [:]
    public var userAgent: String?
    public var referer: String?
    /// Probe limits; `nil` = FFmpeg defaults.
    public var probeSize: Int64?
    public var maxAnalyzeDuration: Int64?
    /// HTTP auto-reconnect for streamed sources.
    public var enableReconnect: Bool = true
    /// Blocking-I/O timeout (µs) applied to network protocols (`rw_timeout`).
    public var ioTimeout: Int64? = 15_000_000
    /// Hard deadline for open + stream probing. Enforced via the interrupt
    /// callback, so it bounds `open` even when `ioTimeout` is nil and the
    /// source never errors (a stalled socket must not hang `open()` forever).
    public var openTimeout: TimeInterval? = 30

    public init() {}

    /// Builds the AVDictionary handed to `avformat_open_input`.
    /// Caller owns the returned dictionary (`av_dict_free`).
    func makeDictionary() -> OpaquePointer? {
        var dict: OpaquePointer?
        if !httpHeaders.isEmpty {
            let joined = httpHeaders.map { "\($0.key): \($0.value)\r\n" }.joined()
            av_dict_set(&dict, "headers", joined, 0)
        }
        if let userAgent { av_dict_set(&dict, "user_agent", userAgent, 0) }
        if let referer { av_dict_set(&dict, "referer", referer, 0) }
        if let probeSize { av_dict_set(&dict, "probesize", String(probeSize), 0) }
        if let maxAnalyzeDuration { av_dict_set(&dict, "analyzeduration", String(maxAnalyzeDuration), 0) }
        if let ioTimeout { av_dict_set(&dict, "rw_timeout", String(ioTimeout), 0) }
        if enableReconnect {
            av_dict_set(&dict, "reconnect", "1", 0)
            av_dict_set(&dict, "reconnect_streamed", "1", 0)
            av_dict_set(&dict, "reconnect_delay_max", "5", 0)
        }
        // MPEG-TS: scan all program map tables (IPTV providers love odd muxes).
        av_dict_set(&dict, "scan_all_pmts", "1", Int32(AV_DICT_DONT_OVERWRITE))
        for (key, value) in formatOptions {
            av_dict_set(&dict, key, value, 0)
        }
        return dict
    }
}
