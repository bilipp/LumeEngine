import Foundation

/// Converts FFmpeg-decoded subtitle payloads into display text.
/// FFmpeg's text subtitle decoders normalize everything (SRT, WebVTT, mov_text,
/// SSA/ASS) into ASS event lines, so one parser covers all text formats.
enum SubtitleTextParser {
    /// Extracts display text from an ASS event line.
    ///
    /// Handles both event encodings FFmpeg produces:
    /// - `"Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text"`
    /// - `"ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text"` (modern API)
    static func text(fromASSEvent event: String) -> String {
        var line = event.trimmingCharacters(in: .whitespacesAndNewlines)
        var fieldsBeforeText = 8
        if line.lowercased().hasPrefix("dialogue:") {
            line = String(line.dropFirst("dialogue:".count)).trimmingCharacters(in: .whitespaces)
            fieldsBeforeText = 9
        }
        var remainder: Substring = line[...]
        for _ in 0..<fieldsBeforeText {
            guard let comma = remainder.firstIndex(of: ",") else { break }
            remainder = remainder[remainder.index(after: comma)...]
        }
        return plainText(fromStyledASS: String(remainder))
    }

    /// Strips `{\...}` override tags and converts ASS line breaks.
    static func plainText(fromStyledASS styled: String) -> String {
        var result = ""
        result.reserveCapacity(styled.count)
        var inTag = false
        var index = styled.startIndex
        while index < styled.endIndex {
            let character = styled[index]
            if character == "{" {
                inTag = true
            } else if character == "}" {
                inTag = false
            } else if !inTag {
                if character == "\\", styled.index(after: index) < styled.endIndex {
                    let next = styled[styled.index(after: index)]
                    if next == "N" || next == "n" {
                        result.append("\n")
                        index = styled.index(index, offsetBy: 2)
                        continue
                    }
                    if next == "h" {
                        result.append(" ")
                        index = styled.index(index, offsetBy: 2)
                        continue
                    }
                }
                result.append(character)
            }
            index = styled.index(after: index)
        }
        return result
    }
}
