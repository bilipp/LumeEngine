/// Strips credentials out of text bound for a log or an error message.
///
/// IPTV source URLs are credentials: Xtream-style panels put the account in
/// the path (`/live/<user>/<pass>/<id>.ts`), others in the query
/// (`?username=…&password=…`, `?token=…`) or in userinfo (`user:pass@host`).
/// FFmpeg names those URLs in its warnings (HLS playlist and segment errors,
/// key files), the engine forwards those warnings to the unified log as public
/// text, and sysdiagnoses with that log get attached to bug reports. So every
/// URL keeps only what tells a reader which server and what kind of resource
/// was involved — scheme, host, port, file extension — and loses the rest.
///
/// Pure and allocation-light on the common path (no URL, no `=`): the FFmpeg
/// log callback runs it on data-plane threads.
enum LogRedaction {
    static let marker = "<redacted>"

    /// `text` with every URL reduced to `scheme://host[:port]/<redacted>[.ext]`
    /// and the values of credential-looking `name=value` pairs outside URLs
    /// (cookies, bare query strings) replaced by the marker.
    static func redact(_ text: String) -> String {
        guard text.contains("://") || text.contains("=") else { return text }
        let characters = Array(text)
        var output = ""
        output.reserveCapacity(characters.count)
        var plainStart = 0
        var index = 0
        while index < characters.count {
            guard let url = urlRange(in: characters, separatorAt: index) else {
                index += 1
                continue
            }
            output += redactPairs(String(characters[plainStart..<url.lowerBound]))
            output += redact(url: String(characters[url]))
            plainStart = url.upperBound
            index = url.upperBound
        }
        output += redactPairs(String(characters[plainStart...]))
        return output
    }

    /// One URL reduced to `scheme://host[:port]`, followed by `/<redacted>`
    /// (plus the last path component's extension, when it has a short one)
    /// whenever it carried a path, query or fragment. Userinfo is dropped.
    /// A plain file path has no scheme and nothing to hide; it passes through
    /// like running text.
    static func redact(url: String) -> String {
        guard let separator = url.range(of: "://") else { return redactPairs(url) }
        let scheme = url[..<separator.lowerBound]
        let afterScheme = url[separator.upperBound...]
        let authorityEnd = afterScheme.firstIndex(where: { "/?#".contains($0) }) ?? afterScheme.endIndex
        var host = afterScheme[..<authorityEnd]
        if let at = host.lastIndex(of: "@") {
            host = host[host.index(after: at)...]
        }
        let rest = afterScheme[authorityEnd...]
        var result = "\(scheme)://\(host)"
        guard !rest.isEmpty, rest != "/" else { return result + rest }
        result += "/" + marker
        if let fileExtension = fileExtension(of: rest) {
            result += "." + fileExtension
        }
        return result
    }

    // MARK: URLs in running text

    private static let schemeCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+.-")
    /// Characters that cannot be part of a URL as FFmpeg prints one.
    private static let urlTerminators = Set(" \t\r\n\"'<>`")
    /// Closers matched to the character in front of a URL: FFmpeg wraps them
    /// in quotes or brackets (`'…'`, `[…]`).
    private static let closers: [Character: Character] = ["'": "'", "\"": "\"", "[": "]", "(": ")", "<": ">", "{": "}"]
    /// Sentence punctuation after a URL, which belongs to the message.
    private static let trailingPunctuation = Set(".,;:!?")

    /// The URL whose `://` starts at `index`, or nil when there is none.
    private static func urlRange(in characters: [Character], separatorAt index: Int) -> Range<Int>? {
        guard index + 2 < characters.count,
              characters[index] == ":", characters[index + 1] == "/", characters[index + 2] == "/"
        else { return nil }
        var start = index
        while start > 0, schemeCharacters.contains(characters[start - 1]) { start -= 1 }
        // A scheme starts with a letter; anything in front of it is text.
        while start < index, !characters[start].isLetter { start += 1 }
        guard start < index else { return nil }

        let opener = start > 0 ? characters[start - 1] : nil
        let closer = opener.flatMap { closers[$0] }
        // Brackets the URL opens itself (an IPv6 host inside `[…]`) close
        // before the wrapping one does.
        var depth = 0
        var end = index + 3
        while end < characters.count {
            let character = characters[end]
            if urlTerminators.contains(character) { break }
            if character == closer {
                if depth == 0 { break }
                depth -= 1
            } else if character == opener, opener != closer {
                depth += 1
            }
            end += 1
        }
        while end > index + 3, trailingPunctuation.contains(characters[end - 1]) { end -= 1 }
        return start..<end
    }

    /// The last path component's extension when it looks like a file type
    /// (`m3u8`, `ts`, `mp4`): kept because it says which kind of resource
    /// failed, and too short to hide anything.
    private static func fileExtension(of rest: Substring) -> String? {
        let pathEnd = rest.firstIndex(where: { "?#".contains($0) }) ?? rest.endIndex
        let path = rest[..<pathEnd]
        guard let lastComponent = path.split(separator: "/").last,
              let dot = lastComponent.lastIndex(of: ".")
        else { return nil }
        let candidate = lastComponent[lastComponent.index(after: dot)...]
        guard (1...5).contains(candidate.count),
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return String(candidate)
    }

    // MARK: name=value pairs outside URLs

    /// Names whose value is a credential when they show up as `name=value`
    /// outside a URL — a cookie FFmpeg could not parse, a query string logged
    /// on its own. `mac` is the account key of MAC-address portals.
    private static let credentialNames: Set<String> = [
        "user", "username", "login", "uid", "pass", "passwd", "pwd", "password",
        "key", "apikey", "api_key", "sig", "signature", "hash", "sid", "mac",
    ]
    /// Matched anywhere in a name: `auth_token`, `PHPSESSID`, `client_secret`.
    private static let credentialFragments = ["token", "password", "secret", "auth", "sess"]

    private static func isCredentialName(_ name: Substring) -> Bool {
        let lowered = name.lowercased()
        return credentialNames.contains(lowered) || credentialFragments.contains { lowered.contains($0) }
    }

    private static func redactPairs(_ text: String) -> String {
        guard text.contains("=") else { return text }
        let pair = /(?<name>[A-Za-z_][A-Za-z0-9_.\-]*)=(?<value>[^\s&;'",)\]]+)/
        return text.replacing(pair) { match in
            isCredentialName(match.output.name) ? "\(match.output.name)=\(marker)" : String(match.output.0)
        }
    }
}
