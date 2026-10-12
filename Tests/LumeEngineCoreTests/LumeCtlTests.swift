import Foundation
import Testing
@testable import LumeCtlCore
import LumeEngineCore

// lumectl lives in this test target rather than one of its own: its runs
// need the generated fixtures and the torture server, both of which live here.

@Suite("lumectl arguments")
struct LumeCtlArgumentTests {
    private func play(_ arguments: String...) throws -> PlayOptions {
        guard case .play(let options) = try Arguments.parse(["play"] + arguments) else {
            throw UsageError("not a play command")
        }
        return options
    }

    private func usageError(_ arguments: [String]) -> String? {
        do {
            _ = try Arguments.parse(arguments)
            return nil
        } catch {
            return error.message
        }
    }

    @Test("no arguments, help and version")
    func helpAndVersion() throws {
        #expect(try Arguments.parse([]) == .help)
        #expect(try Arguments.parse(["--help"]) == .help)
        #expect(try Arguments.parse(["help"]) == .help)
        #expect(try Arguments.parse(["play", "http://h/x.ts", "-h"]) == .help)
        #expect(try Arguments.parse(["--version"]) == .version)
    }

    @Test("play with every option, both spellings")
    func playEverything() throws {
        let options = try play(
            "http://host/live.ts",
            "--duration", "12.5", "--seek=30", "--start", "60", "--interval", "0",
            "--software", "--audio-lang", "DE, en", "--no-video", "--stall-threshold=4",
            "--header", "Authorization: Bearer a:b", "--header=X-Device:  tv ",
            "--user-agent", "Lume/1", "--referer", "http://ref/", "--no-reconnect",
            "--io-timeout", "2.5", "--open-timeout", "10",
            "--json", "--show-urls", "--record-events", "/tmp/run.jsonl"
        )
        #expect(options.source.url == "http://host/live.ts")
        #expect(options.duration == 12.5)
        #expect(options.seek == 30)
        #expect(options.start == 60)
        #expect(options.interval == 0)
        #expect(options.software)
        #expect(options.audioLanguages == ["de", "en"])
        #expect(options.noVideo && !options.noAudio)
        #expect(options.stallThreshold == 4)
        #expect(options.source.headers == [
            .init(name: "Authorization", value: "Bearer a:b"),
            .init(name: "X-Device", value: "tv"),
        ])
        #expect(options.source.userAgent == "Lume/1")
        #expect(options.source.referer == "http://ref/")
        #expect(!options.source.reconnect)
        #expect(options.source.ioTimeout == 2.5)
        #expect(options.source.openTimeout == 10)
        #expect(options.output.json && options.output.showURLs)
        #expect(options.output.recordPath == "/tmp/run.jsonl")
    }

    @Test("defaults: muted, engine defaults kept")
    func playDefaults() throws {
        let options = try play("/path/basic.mp4")
        #expect(options.duration == nil && options.seek == nil && options.start == nil)
        #expect(options.interval == 2)
        let configuration = options.configuration
        let engineDefaults = PlayerConfiguration()
        #expect(configuration.muted)
        #expect(configuration.hardwareDecode == .videoToolbox)
        #expect(configuration.enableAudio && configuration.enableVideo)
        #expect(configuration.startPosition == 0)
        #expect(configuration.stallThreshold == engineDefaults.stallThreshold)
        #expect(configuration.demuxer.ioTimeout == engineDefaults.demuxer.ioTimeout)
        #expect(configuration.demuxer.openTimeout == engineDefaults.demuxer.openTimeout)
        #expect(configuration.demuxer.enableReconnect)
        #expect(configuration.demuxer.httpHeaders.isEmpty)
    }

    @Test("options map onto PlayerConfiguration")
    func configurationMapping() throws {
        let configuration = try play(
            "u", "--io-timeout", "2.5", "--open-timeout", "7", "--no-reconnect", "--software",
            "--start", "42", "--audio-lang", "de,en", "--no-audio", "--stall-threshold", "3",
            "--header", "A: 1", "--header", "A: 2", "--user-agent", "UA", "--referer", "R"
        ).configuration
        #expect(configuration.demuxer.ioTimeout == 2_500_000, "seconds become microseconds")
        #expect(configuration.demuxer.openTimeout == 7)
        #expect(!configuration.demuxer.enableReconnect)
        #expect(configuration.hardwareDecode == .software)
        #expect(configuration.startPosition == 42)
        #expect(configuration.preferredAudioLanguages == ["de", "en"])
        #expect(!configuration.enableAudio)
        #expect(configuration.stallThreshold == 3)
        #expect(configuration.demuxer.httpHeaders == ["A": "2"], "a repeated header keeps the last value")
        #expect(configuration.demuxer.userAgent == "UA")
        #expect(configuration.demuxer.referer == "R")
    }

    @Test("probe takes source and output options only")
    func probe() throws {
        let command = try Arguments.parse(["probe", "--json", "http://h/a.m3u8", "--user-agent", "UA"])
        guard case .probe(let options) = command else {
            Issue.record("expected probe, got \(command)")
            return
        }
        #expect(options.source.url == "http://h/a.m3u8")
        #expect(options.output.json)
        #expect(options.configuration.demuxer.userAgent == "UA")
        #expect(usageError(["probe", "u", "--duration", "3"])?.contains("unknown option '--duration'") == true)
    }

    @Test("-- ends options, so a URL may start with a dash")
    func doubleDash() throws {
        #expect(try play("--json", "--", "-odd-name.ts").source.url == "-odd-name.ts")
    }

    @Test("bad command lines say what is wrong")
    func usageErrors() {
        let cases: [([String], String)] = [
            (["stream", "u"], "unknown command"),
            (["play"], "needs a URL"),
            (["play", "a", "b"], "unexpected extra argument 'b'"),
            (["play", "u", "--duration"], "--duration expects a value"),
            (["play", "u", "--duration", "-1"], "> 0"),
            (["play", "u", "--duration", "0"], "> 0"),
            (["play", "u", "--seek", "abc"], "≥ 0"),
            (["play", "u", "--interval", "nan"], "≥ 0"),
            (["play", "u", "--io-timeout", "inf"], "> 0"),
            (["play", "u", "--header", "no colon"], "'Name: value'"),
            (["play", "u", "--header", ": empty name"], "'Name: value'"),
            (["play", "u", "--header", "A: 1\r\nB: 2"], "'Name: value'"),
            (["play", "u", "--audio-lang", "de,,en"], "comma-separated"),
            (["play", "u", "--software=yes"], "takes no value"),
            (["play", "u", "--frobnicate"], "unknown option '--frobnicate'"),
            (["play", "u", "-d", "3"], "spelled --name"),
            (["play", "u", "--no-audio", "--no-video"], "nothing to play"),
            (["play", ""], "empty"),
        ]
        for (arguments, expected) in cases {
            let message = usageError(arguments)
            #expect(message?.contains(expected) == true, "\(arguments) → \(message ?? "no error")")
        }
    }
}

@Suite("lumectl URL redaction")
struct URLScrubberTests {
    @Test("credentials in path, query and userinfo are withheld")
    func redactsCredentials() {
        let cases: [(String, String)] = [
            ("http://provider.tv:8080/live/alice/s3cret/1234.ts", "http://provider.tv:8080/[redacted].ts"),
            ("http://provider.tv/get.php?username=alice&password=s3cret&type=m3u", "http://provider.tv/[redacted].php"),
            ("https://alice:s3cret@cdn.example.com/hls/index.m3u8?token=abc#t=1", "https://cdn.example.com/[redacted].m3u8"),
            ("http://a:p@ss@host/x", "http://host/[redacted]"),
            ("http://host:80/movie/alice/s3cret/99", "http://host:80/[redacted]"),
            ("http://host/stream?auth=xyz", "http://host/[redacted]"),
            ("rtmp://ingest.example.com/app/streamkey", "rtmp://ingest.example.com/[redacted]"),
            ("HTTP://Host/path.with.dots/file.TS", "HTTP://Host/[redacted].TS"),
            ("http://host/clip.verylongext", "http://host/[redacted]"),
            ("http://host/v1.2/stream", "http://host/[redacted]"),
        ]
        for (input, expected) in cases {
            #expect(URLScrubber.redact(input) == expected, "\(input)")
        }
    }

    @Test("bare hosts and local paths are left alone")
    func keepsWhatIsNotSecret() {
        #expect(URLScrubber.redact("http://host:8080") == "http://host:8080")
        #expect(URLScrubber.redact("http://host/") == "http://host/")
        #expect(URLScrubber.redact("/Users/dev/TestStreams/basic.mp4") == "/Users/dev/TestStreams/basic.mp4")
        #expect(URLScrubber.redact("file:///Users/dev/a.ts") == "file:///Users/dev/a.ts")
        #expect(URLScrubber.redact("not a url") == "not a url")
        #expect(URLScrubber.redact("1http://x/y") == "1http://x/y", "not a scheme")
    }

    @Test("URLs inside messages are redacted where they stand")
    func redactsText() {
        let message = "Failed to open segment 'http://cdn.tv/live/alice/s3cret/seg7.ts?t=1' (via https://u:p@edge.tv/k) for reading"
        #expect(URLScrubber.redactText(message)
            == "Failed to open segment 'http://cdn.tv/[redacted].ts' (via https://edge.tv/[redacted]) for reading")
        #expect(URLScrubber.redactText("Connection refused") == "Connection refused")
        #expect(URLScrubber.redactText("") == "")
    }
}

@Suite("lumectl output")
struct LumeCtlOutputTests {
    @Test("JSON keeps key order and escapes")
    func jsonEncoding() {
        let value = JSON.object([
            ("t", .double(1.23456)),
            ("type", .string("a\"b\\c\nd\u{01}é")),
            ("n", .null), ("ok", .bool(true)), ("i", .int(-5)),
            ("nan", .double(.nan)), ("list", .array([.int(1), .optional(nil as String?)])),
        ])
        #expect(value.encoded
            == #"{"t":1.235,"type":"a\"b\\c\nd\u0001é","n":null,"ok":true,"i":-5,"nan":null,"list":[1,null]}"#)
    }

    @Test("exit status: failure outranks stall, Ctrl-C is no verdict")
    func exitCodes() {
        #expect(ExitCode.playback(failed: false, stalls: 0) == .success)
        #expect(ExitCode.playback(failed: false, stalls: 2) == .stalled)
        #expect(ExitCode.playback(failed: true, stalls: 2) == .playbackFailed)
        #expect(ExitCode.playback(failed: true, stalls: 0) == .playbackFailed)
        let codes = [ExitCode.success, .toolFailure, .usage, .openFailed, .playbackFailed, .stalled, .interrupted]
        #expect(Set(codes.map(\.rawValue)).count == codes.count, "every outcome has its own code")
    }

    @Test("errors carry the HTTP class and no URL")
    func errorRendering() {
        let forbidden = EngineError(
            code: .openFailed, ffmpegCode: -(0xF8 | 0x34 << 8 | 0x30 << 16 | 0x33 << 24),
            message: "open http://h/live/u/p/1.ts: Forbidden"
        )
        let rendered = Describe(showURLs: false).error(forbidden)
        #expect(rendered.text.contains("http forbidden"))
        #expect(!rendered.text.contains("/u/p/"))
        #expect(rendered.json.encoded.contains(#""http":"forbidden""#))
        #expect(Describe(showURLs: true).error(forbidden).text.contains("/live/u/p/1.ts"))
    }
}

/// Collects what a run prints.
private final class Output: Sendable {
    private let lines = LockedBox<[String]>([])

    var sink: Reporter.Sink {
        { [lines] line in lines.set(lines.get() + [line]) }
    }

    var all: [String] { lines.get() }

    /// JSON records of a `--json` run, by type.
    func records(_ type: String) -> [[String: Any]] {
        all.compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == type else { return nil }
            return object
        }
    }
}

@Suite("lumectl runs", .serialized)
struct LumeCtlRunTests {
    private func run(_ arguments: [String], interrupts: AsyncStream<Void> = AsyncStream { _ in }) async throws
        -> (ExitCode, Output)
    {
        let output = Output()
        let code = await LumeCtl.run(
            try Arguments.parse(arguments), interrupts: interrupts, stdout: output.sink, stderr: output.sink
        )
        return (code, output)
    }

    @Test("probe prints the tracks", .timeLimit(.minutes(1)))
    func probe() async throws {
        let (code, output) = try await run(["probe", try Fixtures.path("multitrack.mkv"), "--json"])
        #expect(code == .success)
        let media = output.records("media").first?["media"] as? [String: Any]
        let tracks = media?["tracks"] as? [[String: Any]] ?? []
        #expect(tracks.map { $0["kind"] as? String } == ["video", "audio", "audio", "subtitle"])
        #expect(tracks.compactMap { $0["language"] as? String }.contains("ger"))
        #expect((media?["chapters"] as? [Any])?.count == 2)
        #expect(output.records("summary").first?["exitCode"] as? Int == 0)
    }

    @Test("play prints startup, heartbeats and a clean summary", .timeLimit(.minutes(1)))
    func play() async throws {
        let (code, output) = try await run([
            "play", try Fixtures.path("basic.mp4"), "--duration", "2", "--interval", "0.5", "--json",
        ])
        #expect(code == .success, "\(output.all.joined(separator: "\n"))")
        #expect(output.records("startup").first.flatMap { $0["startup"] as? [String: Any] }?["firstFrameShown"] is Double)
        #expect(output.records("heartbeat").count >= 2)
        let states = output.records("state").compactMap { $0["state"] as? String }
        #expect(states.contains("playing"))
        let summary = output.records("summary").first
        #expect(summary?["outcome"] as? String == "ok")
        #expect((summary?["position"] as? Double ?? 0) > 1, "two seconds of playback")
    }

    @Test("a refused open exits 3 and never prints the credentials", .timeLimit(.minutes(1)))
    func openFailure() async throws {
        let server = try TortureHTTPServer(mode: .forbidden)
        defer { server.stop() }
        let url = "http://alice:pw@127.0.0.1:\(server.port)/live/alice/s3cret/1.ts?token=t0k"
        let (code, output) = try await run(["play", url, "--no-reconnect", "--io-timeout", "2"])
        #expect(code == .openFailed)
        let text = output.all.joined(separator: "\n")
        #expect(text.contains("http forbidden"), "\(text)")
        for secret in ["alice", "pw", "s3cret", "t0k"] {
            #expect(!text.contains(secret), "leaked '\(secret)': \(text)")
        }
    }

    @Test("a source that goes silent exits 5 with the stage", .timeLimit(.minutes(1)))
    func stall() async throws {
        // ~6 s of a 12 s TS, then nothing on an open connection. Less than
        // FFmpeg's ~5 s MPEG-TS probe window would hold `open` until its
        // timeout instead. The watchdog reports the source within the
        // threshold of it going quiet, while the buffer still plays out.
        let server = try TortureHTTPServer(mode: .stallAfter(prefix: 700_000, file: Fixtures.url("wrap.ts")))
        defer { server.stop() }
        let (code, output) = try await run([
            "play", server.url, "--duration", "5", "--stall-threshold", "2",
            "--io-timeout", "60", "--no-reconnect", "--interval", "0", "--json",
        ])
        #expect(code == .stalled, "\(output.all.joined(separator: "\n"))")
        #expect(output.records("stalled").first?["reason"] as? String == "source")
    }

    @Test("a live channel that ends exits 4", .timeLimit(.minutes(1)))
    func liveSourceEnded() async throws {
        let directory = try Fixtures.url("hls-live/index.m3u8").deletingLastPathComponent()
        let server = try TortureHTTPServer(mode: .hlsLiveThenEnded(directory: directory))
        defer { server.stop() }
        let (code, output) = try await run([
            "play", server.hlsURL, "--duration", "30", "--stall-threshold", "30", "--interval", "0", "--json",
        ])
        #expect(code == .playbackFailed, "\(output.all.joined(separator: "\n"))")
        let failure = output.records("summary").first?["failure"] as? [String: Any]
        #expect(failure?["code"] as? String == "sourceEnded")
    }

    @Test("an interrupt ends the run cleanly", .timeLimit(.minutes(1)))
    func interrupt() async throws {
        let (interrupts, continuation) = AsyncStream<Void>.makeStream()
        let started = Date()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            continuation.yield()
        }
        let (code, output) = try await run(
            ["play", try Fixtures.path("basic.mp4"), "--interval", "0", "--json"], interrupts: interrupts
        )
        #expect(code == .success)
        #expect(Date().timeIntervalSince(started) < 8, "a 10 s file must not play to its end")
        #expect(output.records("note").first?["note"] as? String == "interrupted")
        #expect(output.records("summary").count == 1)
    }

    #if os(macOS)
    @Test("Ctrl-C on the real binary shuts down and exits 0", .timeLimit(.minutes(1)))
    func sigint() async throws {
        // The test bundle sits next to the products it was built with.
        let binary = Bundle(for: BundleMarker.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("lumectl")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "no lumectl at \(binary.path)")

        let process = Process()
        process.executableURL = binary
        process.arguments = ["play", try Fixtures.path("basic.mp4"), "--interval", "0"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        try await Task.sleep(for: .seconds(2))
        process.interrupt()
        let deadline = Date(timeIntervalSinceNow: 10)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { process.terminate() }
        let text = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(text)")
        #expect(text.contains("interrupted, shutting down"))
        #expect(text.contains("summary ok (exit 0)"))
    }
    #endif
}

private final class BundleMarker {}
