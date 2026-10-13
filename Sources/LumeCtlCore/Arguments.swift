import Foundation
import LumeEngineCore

/// What the command line asked for. Parsing is pure (`Arguments.parse`),
/// so every flag is unit-tested without opening a stream.
public enum Command: Equatable, Sendable {
    case help
    case version
    case probe(ProbeOptions)
    case play(PlayOptions)
}

/// How to reach the source: everything `DemuxerOptions` exposes that a
/// provider issue tends to hinge on.
public struct SourceOptions: Equatable, Sendable {
    public var url: String
    /// In command-line order; a repeated name keeps the last value.
    public var headers: [Header] = []
    public var userAgent: String?
    public var referer: String?
    public var reconnect = true
    /// Seconds; nil keeps the engine default.
    public var ioTimeout: Double?
    /// Seconds; nil keeps the engine default.
    public var openTimeout: Double?

    public struct Header: Equatable, Sendable {
        public var name: String
        public var value: String
    }

    public init(url: String) {
        self.url = url
    }

    func apply(to options: inout DemuxerOptions) {
        for header in headers {
            options.httpHeaders[header.name] = header.value
        }
        if let userAgent { options.userAgent = userAgent }
        if let referer { options.referer = referer }
        options.enableReconnect = reconnect
        if let ioTimeout { options.ioTimeout = Int64((ioTimeout * 1_000_000).rounded()) }
        if let openTimeout { options.openTimeout = openTimeout }
    }
}

public struct OutputOptions: Equatable, Sendable {
    /// JSON Lines on stdout instead of text.
    public var json = false
    /// Print URLs as given instead of redacted.
    public var showURLs = false
    /// Also write every record as JSON Lines to this file.
    public var recordPath: String?

    public init() {}
}

public struct ProbeOptions: Equatable, Sendable {
    public var source: SourceOptions
    public var output = OutputOptions()

    public init(source: SourceOptions) {
        self.source = source
    }

    public var configuration: PlayerConfiguration {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        source.apply(to: &configuration.demuxer)
        return configuration
    }
}

public struct PlayOptions: Equatable, Sendable {
    public var source: SourceOptions
    public var output = OutputOptions()
    /// Wall-clock seconds to play from `play()`; nil plays to the end (or
    /// until Ctrl-C, for a live source).
    public var duration: Double?
    /// Seek here (seconds) once the first frame shows — a mid-stream seek,
    /// as opposed to `start`.
    public var seek: Double?
    /// `PlayerConfiguration.startPosition`: the resume path, which seeks
    /// before the first read.
    public var start: Double?
    public var software = false
    public var audioLanguages: [String] = []
    public var noAudio = false
    public var noVideo = false
    /// Seconds between diagnostics heartbeats; 0 turns them off.
    public var interval: Double = 2
    /// Seconds; nil keeps the engine default.
    public var stallThreshold: Double?

    public init(source: SourceOptions) {
        self.source = source
    }

    public var configuration: PlayerConfiguration {
        var configuration = PlayerConfiguration()
        // Nothing should come out of the speakers while triaging; the audio
        // lane still decodes and renders, so its timing is the real one.
        configuration.muted = true
        source.apply(to: &configuration.demuxer)
        if let start { configuration.startPosition = start }
        if software { configuration.hardwareDecode = .software }
        configuration.preferredAudioLanguages = audioLanguages
        configuration.enableAudio = !noAudio
        configuration.enableVideo = !noVideo
        if let stallThreshold { configuration.stallThreshold = stallThreshold }
        return configuration
    }
}

public struct UsageError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }

    init(_ message: String) {
        self.message = message
    }
}

public enum Arguments {
    /// Parses the arguments after the executable name.
    public static func parse(_ arguments: [String]) throws(UsageError) -> Command {
        guard let first = arguments.first else { return .help }
        // `lumectl play --help` asks for help, not for a URL.
        let options = arguments.prefix(while: { $0 != "--" })
        if options.contains("-h") || options.contains("--help") { return .help }
        switch first {
        case "help":
            return .help
        case "--version", "version":
            return .version
        case "probe":
            var reader = Reader(Array(arguments.dropFirst()))
            return .probe(try parseProbe(&reader))
        case "play":
            var reader = Reader(Array(arguments.dropFirst()))
            return .play(try parsePlay(&reader))
        default:
            throw UsageError("unknown command '\(first)' (expected probe or play)")
        }
    }

    private static func parseProbe(_ reader: inout Reader) throws(UsageError) -> ProbeOptions {
        var source = SourceOptions(url: "")
        var output = OutputOptions()
        var url: String?
        while let argument = try reader.next() {
            switch argument {
            case .positional(let value):
                try setURL(&url, value)
            case .option(let name, let inline):
                if try parseSourceOption(name, inline, &source, &reader) { continue }
                if try parseOutputOption(name, inline, &output, &reader) { continue }
                throw UsageError("unknown option '--\(name)' for probe")
            }
        }
        guard let url else { throw UsageError("probe needs a URL or file path") }
        source.url = url
        var options = ProbeOptions(source: source)
        options.output = output
        return options
    }

    private static func parsePlay(_ reader: inout Reader) throws(UsageError) -> PlayOptions {
        var options = PlayOptions(source: SourceOptions(url: ""))
        var url: String?
        while let argument = try reader.next() {
            switch argument {
            case .positional(let value):
                try setURL(&url, value)
            case .option(let name, let inline):
                if try parseSourceOption(name, inline, &options.source, &reader) { continue }
                if try parseOutputOption(name, inline, &options.output, &reader) { continue }
                switch name {
                case "duration":
                    options.duration = try seconds(name, reader.value(for: name, inline), allowZero: false)
                case "seek":
                    options.seek = try seconds(name, reader.value(for: name, inline))
                case "start":
                    options.start = try seconds(name, reader.value(for: name, inline))
                case "interval":
                    options.interval = try seconds(name, reader.value(for: name, inline))
                case "stall-threshold":
                    options.stallThreshold = try seconds(name, reader.value(for: name, inline), allowZero: false)
                case "audio-lang":
                    options.audioLanguages = try languages(reader.value(for: name, inline))
                case "software":
                    try noValue(name, inline)
                    options.software = true
                case "no-audio":
                    try noValue(name, inline)
                    options.noAudio = true
                case "no-video":
                    try noValue(name, inline)
                    options.noVideo = true
                default:
                    throw UsageError("unknown option '--\(name)' for play")
                }
            }
        }
        guard let url else { throw UsageError("play needs a URL or file path") }
        guard !(options.noAudio && options.noVideo) else {
            throw UsageError("--no-audio and --no-video together leave nothing to play")
        }
        options.source.url = url
        return options
    }

    /// Options both commands share. Returns false when `name` is not one.
    private static func parseSourceOption(
        _ name: String, _ inline: String?, _ source: inout SourceOptions, _ reader: inout Reader
    ) throws(UsageError) -> Bool {
        switch name {
        case "header":
            source.headers.append(try header(reader.value(for: name, inline)))
        case "user-agent":
            source.userAgent = try nonEmpty(name, reader.value(for: name, inline))
        case "referer":
            source.referer = try nonEmpty(name, reader.value(for: name, inline))
        case "no-reconnect":
            try noValue(name, inline)
            source.reconnect = false
        case "io-timeout":
            source.ioTimeout = try seconds(name, reader.value(for: name, inline), allowZero: false)
        case "open-timeout":
            source.openTimeout = try seconds(name, reader.value(for: name, inline), allowZero: false)
        default:
            return false
        }
        return true
    }

    private static func parseOutputOption(
        _ name: String, _ inline: String?, _ output: inout OutputOptions, _ reader: inout Reader
    ) throws(UsageError) -> Bool {
        switch name {
        case "json":
            try noValue(name, inline)
            output.json = true
        case "show-urls":
            try noValue(name, inline)
            output.showURLs = true
        case "record-events":
            output.recordPath = try nonEmpty(name, reader.value(for: name, inline))
        default:
            return false
        }
        return true
    }

    private static func setURL(_ url: inout String?, _ value: String) throws(UsageError) {
        guard url == nil else { throw UsageError("unexpected extra argument '\(value)'") }
        guard !value.isEmpty else { throw UsageError("the URL is empty") }
        url = value
    }

    private static func seconds(_ name: String, _ text: String, allowZero: Bool = true) throws(UsageError) -> Double {
        guard let value = Double(text), value.isFinite, value >= 0, allowZero || value > 0 else {
            let expected = allowZero ? "a number of seconds ≥ 0" : "a number of seconds > 0"
            throw UsageError("--\(name) expects \(expected), got '\(text)'")
        }
        return value
    }

    private static func header(_ text: String) throws(UsageError) -> SourceOptions.Header {
        guard let colon = text.firstIndex(of: ":") else {
            throw UsageError("--header expects 'Name: value', got '\(text)'")
        }
        let name = text[..<colon].trimmingCharacters(in: .whitespaces)
        let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        // FFmpeg joins headers with CRLF; a line break inside one would
        // smuggle a second header in.
        guard !name.isEmpty, !name.contains(where: \.isWhitespace),
              !value.contains(where: \.isNewline) else {
            throw UsageError("--header expects 'Name: value', got '\(text)'")
        }
        return SourceOptions.Header(name: name, value: value)
    }

    private static func languages(_ text: String) throws(UsageError) -> [String] {
        let tags = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !tags.isEmpty, tags.allSatisfy({ !$0.isEmpty }) else {
            throw UsageError("--audio-lang expects a comma-separated list such as 'de,en', got '\(text)'")
        }
        return tags
    }

    private static func nonEmpty(_ name: String, _ text: String) throws(UsageError) -> String {
        guard !text.isEmpty else { throw UsageError("--\(name) expects a value") }
        return text
    }

    private static func noValue(_ name: String, _ inline: String?) throws(UsageError) {
        if inline != nil { throw UsageError("--\(name) takes no value") }
    }
}

/// Splits arguments into positionals and `--name` / `--name=value` options;
/// everything after `--` is positional (a URL that starts with a dash).
private struct Reader {
    enum Argument {
        case positional(String)
        case option(name: String, inline: String?)
    }

    private var arguments: [String]
    private var index = 0
    private var positionalOnly = false

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    mutating func next() throws(UsageError) -> Argument? {
        guard index < arguments.count else { return nil }
        let argument = arguments[index]
        index += 1
        if positionalOnly { return .positional(argument) }
        if argument == "--" {
            positionalOnly = true
            return try next()
        }
        guard argument.hasPrefix("--"), argument.count > 2 else {
            if argument.hasPrefix("-"), argument.count > 1 {
                throw UsageError("unknown option '\(argument)' (options are spelled --name)")
            }
            return .positional(argument)
        }
        let body = argument.dropFirst(2)
        if let equals = body.firstIndex(of: "=") {
            return .option(name: String(body[..<equals]), inline: String(body[body.index(after: equals)...]))
        }
        return .option(name: String(body), inline: nil)
    }

    /// The option's value: the `=value` part, or the next argument.
    mutating func value(for name: String, _ inline: String?) throws(UsageError) -> String {
        if let inline { return inline }
        guard index < arguments.count else { throw UsageError("--\(name) expects a value") }
        let value = arguments[index]
        index += 1
        return value
    }
}
