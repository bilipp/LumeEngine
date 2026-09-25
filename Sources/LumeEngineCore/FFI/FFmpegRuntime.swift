internal import CFFmpeg
import os

/// Process-wide FFmpeg setup: log bridging and version info.
///
/// Logs are forwarded to `os_log` for diagnostics only — the engine never
/// drives control flow off log text (PLAN.md §3.6). This is the only
/// process-global state in the engine, and it is configuration-free.
public enum FFmpegRuntime {
    private static let logger = Logger(subsystem: "engine.lume", category: "ffmpeg")

    private static let didInitialize: Bool = {
        av_log_set_level(AV_LOG_WARNING)
        av_log_set_callback(ffmpegLogCallback)
        avformat_network_init()
        return true
    }()

    /// Idempotent; called by every entry point that touches FFmpeg.
    public static func initialize() {
        _ = didInitialize
    }

    public struct Versions: Sendable, CustomStringConvertible {
        public let avformat: UInt32
        public let avcodec: UInt32
        public let avutil: UInt32

        public var description: String {
            func fmt(_ v: UInt32) -> String { "\(v >> 16).\((v >> 8) & 0xFF).\(v & 0xFF)" }
            return "avformat \(fmt(avformat)), avcodec \(fmt(avcodec)), avutil \(fmt(avutil))"
        }
    }

    public static var versions: Versions {
        initialize()
        return Versions(
            avformat: avformat_version(),
            avcodec: avcodec_version(),
            avutil: avutil_version()
        )
    }

    /// libavutil's `LIBAVUTIL_VERSION_MAJOR` for the linked binary; used by tests
    /// to pin the expected FFmpeg release line.
    public static var avutilMajorVersion: UInt32 {
        avutil_version() >> 16
    }

    fileprivate static func log(level: Int32, message: String) {
        switch level {
        case ...AV_LOG_ERROR: logger.error("\(message, privacy: .public)")
        case ...AV_LOG_WARNING: logger.warning("\(message, privacy: .public)")
        default: logger.debug("\(message, privacy: .public)")
        }
    }
}

/// C-convention trampoline for `av_log_set_callback`. Formats via FFmpeg's own
/// line formatter; never interprets the text.
private func ffmpegLogCallback(
    _ context: UnsafeMutableRawPointer?,
    _ level: Int32,
    _ format: UnsafePointer<CChar>?,
    _ args: CVaListPointer?
) {
    guard level <= av_log_get_level(), let format, let args else { return }
    var buffer = [UInt8](repeating: 0, count: 1024)
    var printPrefix: Int32 = 1
    let written = buffer.withUnsafeMutableBufferPointer { ptr in
        ptr.withMemoryRebound(to: CChar.self) { charPtr in
            av_log_format_line2(context, level, format, args, charPtr.baseAddress, Int32(charPtr.count), &printPrefix)
        }
    }
    guard written > 0 else { return }
    let length = min(Int(written), buffer.count - 1)
    let message = String(decoding: buffer[..<length], as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { return }
    FFmpegRuntime.log(level: level, message: message)
}

extension FFmpegRuntime {
    /// Stream-open diagnostics channel — the same `os_log` facility the FFmpeg
    /// bridge above uses, one category further along so a measurement pass can
    /// isolate it:
    ///
    /// ```
    /// log stream --predicate 'subsystem == "engine.lume" && category == "diagnostics"'
    /// ```
    ///
    /// Everything written here is emitted **once per stream open** (and again
    /// only when the thing being described actually changes). Nothing on this
    /// channel may be written per frame or per tick: the video path reaches it
    /// from inside `deliver()`, which runs 50–120 times a second on a 4K
    /// stream, so a caller must have compared a cheap value-type signature
    /// *before* formatting anything.
    ///
    /// Level convention follows `FFmpegRuntime.log`: `.notice` for the
    /// once-per-stream facts (persisted, so they survive into `log collect`
    /// from an Apple TV), `.error`/`.warning` reserved for failures.
    static let diagnostics = Logger(subsystem: "engine.lume", category: "diagnostics")
}
