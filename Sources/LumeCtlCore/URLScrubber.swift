/// Keeps credentials out of what lumectl prints.
///
/// IPTV providers put the account in the URL itself — Xtream-style paths
/// (`/live/<user>/<password>/<id>.ts`), `get.php?username=…&password=…`,
/// tokens in the query, userinfo before the host — and terminal output ends
/// up pasted into issues and chats. So a URL is reduced to what triage needs:
/// scheme, host and port (which provider, which edge), plus the file
/// extension (HLS playlist vs raw TS), and everything else is withheld.
///
/// Deliberately small and private to the tool: it only has to be right for
/// the strings this tool prints.
public enum URLScrubber {
    static let placeholder = "[redacted]"

    /// The URL reduced to `scheme://host[:port]`, with `/[redacted]` (plus a
    /// short file extension when the path has one) standing for anything
    /// after it. Strings without a scheme — local paths — come back as given:
    /// a path names a file on the developer's own machine, not an account.
    public static func redact(_ url: String) -> String {
        guard let separator = url.range(of: "://") else { return url }
        let scheme = url[..<separator.lowerBound]
        guard isScheme(scheme) else { return url }
        // A file URL is a local path too.
        if scheme.lowercased() == "file" { return url }

        let afterScheme = url[separator.upperBound...]
        let authorityEnd = afterScheme.firstIndex(where: { "/?#".contains($0) }) ?? afterScheme.endIndex
        var authority = afterScheme[..<authorityEnd]
        // userinfo (`user:password@`) never survives; the last `@` ends it,
        // since an unescaped one can appear in a sloppy password.
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }

        var result = "\(scheme)://\(authority)"
        let rest = afterScheme[authorityEnd...]
        if rest == "/" {
            result += "/"
        } else if !rest.isEmpty {
            result += "/" + placeholder + fileExtension(of: rest)
        }
        return result
    }

    /// Every URL embedded in free text redacted: error messages, renderer
    /// errors and container metadata are printed verbatim otherwise, and any
    /// of them can carry a URL (a playlist or key URI, a referer).
    public static func redactText(_ text: String) -> String {
        guard text.contains("://") else { return text }
        // A scheme followed by `://` and everything up to whitespace or a
        // character that commonly closes a quoted URL in a message. Built per
        // call: `Regex` is not Sendable, so it cannot be a shared constant.
        let embeddedURL = #/[A-Za-z][A-Za-z0-9+.\-]*://[^\s'"<>()\[\]{}]+/#
        return text.replacing(embeddedURL) { match in
            redact(String(text[match.range]))
        }
    }

    private static func isScheme(_ candidate: Substring) -> Bool {
        guard let first = candidate.first, first.isASCII, first.isLetter else { return false }
        return candidate.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
    }

    /// `.m3u8`, `.ts`, `.mkv` … of the last path component, when it looks
    /// like a real extension (1–5 alphanumerics): it tells an HLS playlist
    /// from a raw stream without saying which stream.
    private static func fileExtension(of rest: Substring) -> String {
        let pathEnd = rest.firstIndex(where: { "?#".contains($0) }) ?? rest.endIndex
        let path = rest[..<pathEnd]
        guard let lastComponent = path.split(separator: "/").last,
              let dot = lastComponent.lastIndex(of: ".") else { return "" }
        let ext = lastComponent[lastComponent.index(after: dot)...]
        guard (1...5).contains(ext.count),
              ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return "" }
        return "." + ext
    }
}
