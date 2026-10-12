import Testing
@testable import LumeEngineCore

@Suite("LogRedaction")
struct LogRedactionTests {
    private let secrets = ["alice", "s3cr3t", "abc123def", "00:1A:79:12:34:56", "deadbeef"]

    private func expectNoSecrets(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for secret in secrets {
            #expect(!text.contains(secret), "\(secret) leaked: \(text)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Single URLs

    @Test("an Xtream path keeps scheme, host, port and extension only")
    func xtreamPath() {
        let redacted = LogRedaction.redact(url: "http://iptv.example.com:8080/live/alice/s3cr3t/12345.ts")
        #expect(redacted == "http://iptv.example.com:8080/<redacted>.ts")
    }

    @Test("query credentials go with the path")
    func queryCredentials() {
        let redacted = LogRedaction.redact(url: "https://cdn.example.net/get.php?username=alice&password=s3cr3t&type=m3u_plus")
        #expect(redacted == "https://cdn.example.net/<redacted>.php")
        let token = LogRedaction.redact(url: "https://edge.example.net/hls/stream.m3u8?token=abc123def")
        #expect(token == "https://edge.example.net/<redacted>.m3u8")
    }

    @Test("userinfo is dropped")
    func userinfo() {
        let redacted = LogRedaction.redact(url: "http://alice:s3cr3t@203.0.113.7:25461/stream")
        #expect(redacted == "http://203.0.113.7:25461/<redacted>")
    }

    @Test("an IPv6 host survives")
    func ipv6() {
        let redacted = LogRedaction.redact(url: "http://[2001:db8::1]:8000/live/alice/s3cr3t/1.ts")
        #expect(redacted == "http://[2001:db8::1]:8000/<redacted>.ts")
    }

    @Test("a bare host or root stays as it is")
    func bareHost() {
        #expect(LogRedaction.redact(url: "http://example.com") == "http://example.com")
        #expect(LogRedaction.redact(url: "http://example.com/") == "http://example.com/")
    }

    @Test("a token in the last component is not mistaken for an extension")
    func tokenComponent() {
        let redacted = LogRedaction.redact(url: "http://example.com/play/abc123def.deadbeef")
        #expect(redacted == "http://example.com/<redacted>")
    }

    @Test("a local file path passes through")
    func filePath() {
        #expect(LogRedaction.redact(url: "/var/mobile/Containers/subs.srt") == "/var/mobile/Containers/subs.srt")
    }

    // MARK: Running text

    @Test("a URL mid-sentence is redacted and the sentence kept")
    func midSentence() {
        let message = "[hls @ 0x600003f0c000] Failed to open segment of playlist 0, URL http://iptv.example.com:8080/live/alice/s3cr3t/12345/seg-981.ts is not reachable"
        let redacted = LogRedaction.redact(message)
        #expect(redacted == "[hls @ 0x600003f0c000] Failed to open segment of playlist 0, URL http://iptv.example.com:8080/<redacted>.ts is not reachable")
    }

    @Test("quoted and bracketed URLs keep their delimiters")
    func delimiters() {
        let quoted = LogRedaction.redact("Opening 'https://edge.example.net/hls/stream.m3u8?token=abc123def' for reading")
        #expect(quoted == "Opening 'https://edge.example.net/<redacted>.m3u8' for reading")
        let bracketed = LogRedaction.redact("parse_playlist error Server returned 403 Forbidden [http://alice:s3cr3t@p.example.com/live/alice/s3cr3t/1.m3u8]")
        #expect(bracketed == "parse_playlist error Server returned 403 Forbidden [http://p.example.com/<redacted>.m3u8]")
        let ipv6 = LogRedaction.redact("Empty segment [http://[2001:db8::1]:80/live/alice/s3cr3t/2.ts]")
        #expect(ipv6 == "Empty segment [http://[2001:db8::1]:80/<redacted>.ts]")
    }

    @Test("trailing sentence punctuation stays outside the URL")
    func punctuation() {
        let redacted = LogRedaction.redact("Unable to open key file https://keys.example.com/k?sid=deadbeef, Server returned 401.")
        #expect(redacted == "Unable to open key file https://keys.example.com/<redacted>, Server returned 401.")
    }

    @Test("several URLs on one line are all redacted")
    func multipleURLs() {
        let message = "redirect http://a.example.com/live/alice/s3cr3t/1.ts -> https://b.example.com:443/x/1.ts?token=abc123def then rtmp://alice:s3cr3t@c.example.com/app"
        let redacted = LogRedaction.redact(message)
        #expect(redacted == "redirect http://a.example.com/<redacted>.ts -> https://b.example.com:443/<redacted>.ts then rtmp://c.example.com/<redacted>")
        expectNoSecrets(redacted)
    }

    @Test("credential pairs outside URLs lose their values")
    func pairs() {
        let cookie = LogRedaction.redact("Unable to parse 'PHPSESSID=deadbeef; auth_token=abc123def; path=/'")
        #expect(cookie == "Unable to parse 'PHPSESSID=<redacted>; auth_token=<redacted>; path=/'")
        let query = LogRedaction.redact("bad request username=alice&password=s3cr3t&mac=00:1A:79:12:34:56&output=ts")
        #expect(query == "bad request username=<redacted>&password=<redacted>&mac=<redacted>&output=ts")
    }

    @Test("ordinary FFmpeg warnings pass through untouched")
    func untouched() {
        let messages = [
            "[http @ 0x6000] Will reconnect at 1048576 in 2 second(s), error=Operation timed out.",
            "[mpegts @ 0x6000] PES packet size mismatch",
            "[h264 @ 0x6000] error while decoding MB 12 34, bytestream -5",
            "HTTP error 403 Forbidden",
        ]
        for message in messages {
            #expect(LogRedaction.redact(message) == message)
        }
    }

    @Test("a scheme separator with no scheme is left alone")
    func noScheme() {
        #expect(LogRedaction.redact("ratio 4 :// odd") == "ratio 4 :// odd")
    }

    @Test("a URL cut off by the log buffer is still redacted")
    func truncated() {
        let redacted = LogRedaction.redact("Opening 'http://iptv.example.com/live/alice/s3cr")
        #expect(redacted == "Opening 'http://iptv.example.com/<redacted>")
    }

    // MARK: Engine errors

    @Test("a failed subtitle open names the server, not the account")
    func subtitleError() async {
        let session = PlayerSession()
        // Nothing listens on port 1: the open fails at once.
        do {
            try await session.loadExternalSubtitles(url: "http://alice:s3cr3t@127.0.0.1:1/live/alice/s3cr3t/subs.srt?token=abc123def")
            Issue.record("open should have failed")
        } catch let error as EngineError {
            #expect(error.message.contains("http://127.0.0.1:1/<redacted>.srt"))
            expectNoSecrets(error.description)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        await session.shutdown()
    }
}
