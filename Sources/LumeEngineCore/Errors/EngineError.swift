internal import CFFmpeg

/// Typed error surface of the engine. Every failure path produces one of these —
/// never a bare FFmpeg return code, never a crash. (PLAN.md §3.9, D8)
public struct EngineError: Error, Sendable, CustomStringConvertible, Equatable {
    public enum Code: String, Sendable {
        case openFailed
        case ioError
        case decoderInitFailed
        case decodeFailed
        case seekFailed
        case invalidState
        case cancelled
        case unsupported
        case internalError
    }

    public let code: Code
    /// Raw FFmpeg error return, when the failure originated in FFmpeg.
    public let ffmpegCode: Int32?
    public let message: String

    public init(code: Code, ffmpegCode: Int32? = nil, message: String) {
        self.code = code
        self.ffmpegCode = ffmpegCode
        self.message = message
    }

    /// Builds an error from an FFmpeg return code, resolving the human-readable
    /// message via `av_strerror`.
    public static func ffmpeg(_ ret: Int32, code: Code, context: String) -> EngineError {
        var buffer = [CChar](repeating: 0, count: 128)
        let described: String = buffer.withUnsafeMutableBufferPointer { ptr in
            if av_strerror(ret, ptr.baseAddress, ptr.count) == 0 {
                return String(cString: ptr.baseAddress!)
            }
            return "unknown FFmpeg error"
        }
        return EngineError(code: code, ffmpegCode: ret, message: "\(context): \(described)")
    }

    public var description: String {
        if let ffmpegCode {
            return "EngineError(\(code.rawValue), ffmpeg: \(ffmpegCode)): \(message)"
        }
        return "EngineError(\(code.rawValue)): \(message)"
    }
}
