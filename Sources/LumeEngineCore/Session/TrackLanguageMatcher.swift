import Foundation

/// Ordered language-preference matching over container tracks.
///
/// Used at open time only (`PlayerSession.buildPipeline`): the track a viewer
/// wants must be chosen *while the pipeline is being built*, never by opening
/// on one track and switching afterwards. Switching after open re-syncs every
/// lane through `seek(to: position)`, and at open `position` is still 0 —
/// which would silently discard `PlayerConfiguration.startPosition` on VOD
/// resume, and issue a seek against live IPTV endpoints that report
/// `isSeekable` but drop the connection when one arrives.
///
/// Contract with the app (PLAN.md §3.8 — configuration in, no global knobs):
/// preferences arrive **already normalised** as ordered bare language tags
/// (`["de", "en"]`). The engine never consults the device locale and never
/// invents a preference; an empty list means "leave the container's own
/// choice alone", which is what every pre-existing session gets.
///
/// Container tags are whatever the muxer wrote, so the *track* side does need
/// normalising: ISO 639-2/B (`ger`), /T (`deu`), 639-1 (`de`), a BCP-47
/// variant (`de-AT`), or nothing at all with the language spelled out in the
/// title instead.
enum TrackLanguageMatcher {
    /// Ranked quality of one track↔preference hit. Lower is better, and the
    /// fields are compared in declaration order:
    ///
    /// 1. `rank` — position in the caller's ordered preference list.
    /// 2. `penalty` — commentary / audio-description labels lose to a plain
    ///    track of the same language (a viewer asking for German means the
    ///    German feature audio, never the director's commentary).
    /// 3. `quality` — an exact bare-code tag beats a regional variant
    ///    (`de` over `de-AT`), which beats a language code found in the free
    ///    text of the title.
    /// 4. `order` — container order; first match wins all else being equal.
    private struct Score: Comparable {
        let rank: Int
        let penalty: Int
        let quality: Int
        let order: Int

        static func < (lhs: Score, rhs: Score) -> Bool {
            (lhs.rank, lhs.penalty, lhs.quality, lhs.order)
                < (rhs.rank, rhs.penalty, rhs.quality, rhs.order)
        }
    }

    /// Best track for an ordered preference list, or `nil` when nothing
    /// matches. `nil` means *do nothing* — callers keep the container's own
    /// selection rather than falling back to some arbitrary track.
    static func bestMatch(in tracks: [TrackInfo], preferring languages: [String]) -> TrackInfo? {
        guard !tracks.isEmpty else { return nil }
        let wanted = normalizedPreferences(languages)
        guard !wanted.isEmpty else { return nil }

        var best: (score: Score, track: TrackInfo)?
        for (order, track) in tracks.enumerated() {
            guard let hit = score(track, order: order, against: wanted) else { continue }
            if best == nil || hit < best!.score {
                best = (hit, track)
            }
        }
        return best?.track
    }

    /// True when the track is one the viewer asked for. Used to decide
    /// whether the audio that ended up selected is *foreign* to the viewer,
    /// which is what gates forced-subtitle auto-enable. An empty preference
    /// list makes every track "wanted", so nothing is ever foreign — the
    /// default configuration cannot reach the forced branch at all.
    static func matches(_ track: TrackInfo, preferring languages: [String]) -> Bool {
        let wanted = normalizedPreferences(languages)
        guard !wanted.isEmpty else { return true }
        return score(track, order: 0, against: wanted) != nil
    }

    // MARK: Scoring

    private static func score(_ track: TrackInfo, order: Int, against wanted: [String]) -> Score? {
        let penalty = isDeprioritized(track) ? 1 : 0

        if let tag = track.language, let canonical = canonicalize(tag) {
            if let rank = wanted.firstIndex(of: canonical) {
                return Score(rank: rank, penalty: penalty, quality: hasSubtags(tag) ? 1 : 0, order: order)
            }
        }

        // Free-text titles ("ger 5.1", "DE"). Matched per whitespace/punctuation
        // token, never by substring: a bare "de" occurs inside half the Romance
        // titles ever written and would match everything.
        if let title = track.title {
            for token in tokens(of: title) {
                guard let canonical = canonicalize(token), let rank = wanted.firstIndex(of: canonical) else { continue }
                return Score(rank: rank, penalty: penalty, quality: 2, order: order)
            }
        }

        return nil
    }

    /// Labels that mean "not the feature audio": director commentary and
    /// audio description. Matched on the title, since `TrackInfo` carries no
    /// FFmpeg comment/visual-impaired disposition.
    private static func isDeprioritized(_ track: TrackInfo) -> Bool {
        guard let title = track.title?.lowercased() else { return false }
        for phrase in commentaryPhrases where title.contains(phrase) {
            return true
        }
        // "English AD" — an abbreviation only as a standalone token.
        return tokens(of: title).contains("ad")
    }

    private static let commentaryPhrases = [
        "commentary", "commentaire", "kommentar", "comentario", "comentário",
        "commento", "audio description", "audiodescription", "audiodescricao",
        "audiodescrição", "audiodescripcion", "audiodescripción", "descriptive",
        "described", "hörfilm",
    ]

    // MARK: Language tags

    /// Ordered, de-duplicated canonical forms of the caller's preferences.
    private static func normalizedPreferences(_ languages: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for language in languages {
            guard let canonical = canonicalize(language), seen.insert(canonical).inserted else { continue }
            result.append(canonical)
        }
        return result
    }

    /// Reduces a tag to a comparable primary language subtag, or `nil` when it
    /// carries no language information at all.
    ///
    /// `Locale.LanguageCode` covers the ISO 639-2/T codes (`deu` → `de`) but
    /// returns nil for the bibliographic /B forms that MKV and MPEG-TS
    /// actually carry (`ger`, `fre`, `chi`, `cze`, `dut`, `gre`, …), so those
    /// need the table below. Three-letter codes with no two-letter form at all
    /// (`fil`, `haw`) stay as they are and still compare against each other.
    static func canonicalize(_ tag: String) -> String? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let primary = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? trimmed
        guard primary.allSatisfy(\.isLetter) else { return nil }
        guard !placeholders.contains(primary) else { return nil }

        switch primary.count {
        case 2:
            return primary
        case 3:
            if let alpha2 = bibliographicAlpha2[primary] { return alpha2 }
            if let alpha2 = Locale.LanguageCode(primary).identifier(.alpha2), alpha2.count == 2 {
                return alpha2
            }
            return primary
        default:
            return nil
        }
    }

    /// True when the tag names a region/script beyond the language itself
    /// (`de-AT`), which loses to an exact `de` when both are present.
    private static func hasSubtags(_ tag: String) -> Bool {
        tag.contains("-") || tag.contains("_")
    }

    /// Tags that assert the absence of a single language. `vo` is French
    /// broadcast shorthand for "version originale" (not Volapük, which no
    /// IPTV provider has ever muxed), and `multi` is the IPTV convention for
    /// a multiplexed multi-language track. All of them mean "no match" — the
    /// container's own choice stands.
    private static let placeholders: Set<String> = [
        "und", "mul", "mis", "zxx", "vo", "vos", "vost", "multi", "original", "unknown",
    ]

    /// ISO 639-2/B → 639-1, i.e. exactly the codes `Locale.LanguageCode`
    /// cannot resolve because it only knows the terminological forms.
    private static let bibliographicAlpha2: [String: String] = [
        "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "chi": "zh",
        "cze": "cs", "dut": "nl", "fre": "fr", "geo": "ka", "ger": "de",
        "gre": "el", "ice": "is", "mac": "mk", "may": "ms", "mao": "mi",
        "per": "fa", "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy",
    ]

    private static func tokens(of text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
    }
}
