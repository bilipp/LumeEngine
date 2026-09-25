import Foundation
import Testing
@testable import LumeEngineCore

@Suite("TrackLanguageMatcher")
struct TrackLanguageMatcherTests {
    private func audio(
        _ index: Int32,
        language: String?,
        title: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false
    ) -> TrackInfo {
        TrackInfo(
            index: index,
            kind: .audio,
            codecName: "aac",
            codecID: 0,
            language: language,
            title: title,
            isDefault: isDefault,
            isForced: isForced,
            bitrate: 0,
            video: nil,
            audio: TrackInfo.Audio(
                channels: 2, sampleRate: 48_000,
                profile: -99, isObjectAudio: false, channelLayoutName: "stereo"
            ),
            wrapBits: 64
        )
    }

    @Test("an empty preference matches nothing — the container's choice stands")
    func emptyPreferenceIsInert() {
        let tracks = [audio(0, language: "eng"), audio(1, language: "ger")]
        #expect(TrackLanguageMatcher.bestMatch(in: tracks, preferring: []) == nil)
    }

    @Test("ISO 639-2/B container tags resolve to the app's bare codes")
    func bibliographicCodes() {
        // Locale.LanguageCode cannot do these: "ger"/"fre"/"chi"/"cze"/"dut"
        // all return nil for .alpha2, and MKV/TS write exactly those.
        let cases: [(String, String)] = [
            ("ger", "de"), ("deu", "de"), ("fre", "fr"), ("fra", "fr"),
            ("chi", "zh"), ("cze", "cs"), ("dut", "nl"), ("gre", "el"),
            ("por", "pt"), ("eng", "en"),
        ]
        for (tag, wanted) in cases {
            let track = audio(0, language: tag)
            #expect(
                TrackLanguageMatcher.bestMatch(in: [track], preferring: [wanted])?.index == 0,
                "\(tag) must match \(wanted)"
            )
        }
    }

    @Test("preference order decides, not container order")
    func preferenceOrderWins() {
        let tracks = [audio(0, language: "eng"), audio(1, language: "ger"), audio(2, language: "fre")]
        #expect(TrackLanguageMatcher.bestMatch(in: tracks, preferring: ["fr", "de"])?.index == 2)
        #expect(TrackLanguageMatcher.bestMatch(in: tracks, preferring: ["de", "fr"])?.index == 1)
    }

    @Test("a bare preference matches a regional variant, exact first")
    func regionalVariants() {
        let variantOnly = [audio(0, language: "eng"), audio(1, language: "pt-BR")]
        #expect(TrackLanguageMatcher.bestMatch(in: variantOnly, preferring: ["pt"])?.index == 1)

        // de-AT is offered first in the container; the exact de still wins.
        let both = [audio(0, language: "de-AT"), audio(1, language: "de")]
        #expect(TrackLanguageMatcher.bestMatch(in: both, preferring: ["de"])?.index == 1)
    }

    @Test("first container match wins between equals")
    func firstMatchWins() {
        let tracks = [
            audio(0, language: "ger", title: "German 5.1"),
            audio(1, language: "ger", title: "German Stereo"),
        ]
        #expect(TrackLanguageMatcher.bestMatch(in: tracks, preferring: ["de"])?.index == 0)
    }

    @Test("commentary and audio description lose to the feature audio")
    func commentaryIsDeprioritized() {
        let commentaryFirst = [
            audio(0, language: "eng", title: "English (Director's Commentary)"),
            audio(1, language: "eng", title: "English"),
        ]
        #expect(TrackLanguageMatcher.bestMatch(in: commentaryFirst, preferring: ["en"])?.index == 1)

        let describedFirst = [
            audio(0, language: "eng", title: "English AD"),
            audio(1, language: "eng", title: "English"),
        ]
        #expect(TrackLanguageMatcher.bestMatch(in: describedFirst, preferring: ["en"])?.index == 1)

        // Still selected when it is the only track of that language: a
        // de-prioritised match beats no audio at all.
        let onlyCommentary = [audio(0, language: "eng", title: "Commentary")]
        #expect(TrackLanguageMatcher.bestMatch(in: onlyCommentary, preferring: ["en"])?.index == 0)
    }

    @Test("und / mul / VO / Multi are not a match")
    func placeholderTagsNeverMatch() {
        for tag in ["und", "mul", "VO", "Multi", "unknown", "zxx"] {
            let tracks = [audio(0, language: tag)]
            #expect(
                TrackLanguageMatcher.bestMatch(in: tracks, preferring: ["de", "en", "fr"]) == nil,
                "\(tag) must not match"
            )
        }
    }

    @Test("an untagged track matches through its title, per token")
    func titleTokens() {
        let tagged = [audio(0, language: nil, title: "GER 5.1"), audio(1, language: nil, title: "ENG")]
        #expect(TrackLanguageMatcher.bestMatch(in: tagged, preferring: ["de"])?.index == 0)

        // No substring matching: "de" inside "Bande originale" is not French.
        let prose = [audio(0, language: nil, title: "Bande originale")]
        #expect(TrackLanguageMatcher.bestMatch(in: prose, preferring: ["de"]) == nil)

        // A real language tag outranks a title hit.
        let mixed = [audio(0, language: nil, title: "eng"), audio(1, language: "eng")]
        #expect(TrackLanguageMatcher.bestMatch(in: mixed, preferring: ["en"])?.index == 1)
    }

    @Test("matches() is what makes audio 'foreign' — and never with an empty list")
    func foreignAudioTest() {
        let english = audio(0, language: "eng")
        #expect(TrackLanguageMatcher.matches(english, preferring: []))
        #expect(TrackLanguageMatcher.matches(english, preferring: ["en"]))
        #expect(!TrackLanguageMatcher.matches(english, preferring: ["de"]))
    }
}
