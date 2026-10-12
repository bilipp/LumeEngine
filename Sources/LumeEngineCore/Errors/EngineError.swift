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
        /// An `AVSampleBuffer*Renderer` reported `.failed` (e.g. a format the
        /// output route cannot render). Fatal for the session: a failed
        /// renderer stops accepting data permanently.
        case renderFailed
        /// A source with no known end (live) reached a clean end of stream
        /// and everything buffered has played. The usual cause is an HLS
        /// playlist that gained its end marker mid-broadcast, which providers
        /// append during outages. For a live channel that is a lost source,
        /// not a finished programme. (A plain HTTP body of unknown length that
        /// ends arrives as `.ioError` instead: FFmpeg cannot tell it from a
        /// dropped connection.)
        case sourceEnded
    }

    /// The HTTP status class a source answered with, when FFmpeg reported one.
    ///
    /// The engine only classifies; acting on it is the app's job, and each
    /// class wants a different answer from an IPTV client: an expired token
    /// (`.unauthorized`, `.forbidden`) wants a freshly resolved URL, a full
    /// connection slot or an overloaded panel (`.tooManyRequests`,
    /// `.serverError`) wants a wait before the next attempt, and `.notFound`
    /// will not change by retrying. A connection-capped account also tends to
    /// answer `.forbidden` while the previous connection still holds its slot.
    public enum HTTPFailure: String, Sendable, Equatable {
        /// 400.
        case badRequest
        /// 401.
        case unauthorized
        /// 403.
        case forbidden
        /// 404.
        case notFound
        /// 429.
        case tooManyRequests
        /// Any other 4xx.
        case otherClientError
        /// Any 5xx (FFmpeg does not tell 503 or 509 apart from 500).
        case serverError
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
            if let base = ptr.baseAddress, av_strerror(ret, base, ptr.count) == 0 {
                return String(cString: base)
            }
            return "unknown FFmpeg error"
        }
        return EngineError(code: code, ffmpegCode: ret, message: "\(context): \(described)")
    }

    /// The HTTP status class behind this error; nil when it did not come from
    /// an HTTP response. Derived from FFmpeg's typed `AVERROR_HTTP_*` codes —
    /// never from the message text.
    public var httpFailure: HTTPFailure? {
        guard let ffmpegCode else { return nil }
        return Self.httpFailures[ffmpegCode]
    }

    /// FFmpeg's `FFERRTAG(0xF8, a, b, c)` HTTP error codes. The macros are
    /// out of the Clang importer's reach, so the tag arithmetic is redone
    /// here: `-(0xF8 | a << 8 | b << 16 | c << 24)`.
    private static let httpFailures: [Int32: HTTPFailure] = {
        func tag(_ status: String) -> Int32 {
            let bytes = Array(status.utf8)
            let value = UInt32(0xF8) | UInt32(bytes[0]) << 8 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 24
            return -Int32(bitPattern: value)
        }
        return [
            tag("400"): .badRequest,
            tag("401"): .unauthorized,
            tag("403"): .forbidden,
            tag("404"): .notFound,
            tag("429"): .tooManyRequests,
            tag("4XX"): .otherClientError,
            tag("5XX"): .serverError,
        ]
    }()

    public var description: String {
        if let ffmpegCode {
            return "EngineError(\(code.rawValue), ffmpeg: \(ffmpegCode)): \(message)"
        }
        return "EngineError(\(code.rawValue)): \(message)"
    }
}
