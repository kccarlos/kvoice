import Foundation
import KvoiceDomain

/// Maps kvoice's transcription language (a Whisper code, `nil` = automatic)
/// onto the `SpeechTranscriber` locales the platform reports, and back
/// (ADR-025). Pure and deterministic — `Locale` is Foundation, not a
/// vendor type — so the engine, the assets adapter and the tests share one
/// answer.
///
/// Why not `SpeechTranscriber.supportedLocale(equivalentTo:)`: for a bare
/// language code it returns an arbitrary region (observed on macOS 27.0:
/// `en` → `en_ZA`, `es` → `es_CL`, `yue` → `zh_HK`), and its documented
/// preference for an installed locale would make the answer drift as
/// assets come and go. The rule here is stable: the user's own region when
/// the platform has that pair, else a documented default per language,
/// else the first supported locale for the language in identifier order.
public enum AppleSpeechLocaleMapping {
    /// The region to use for a language when the user's region has no
    /// supported pair. The obvious "home" region of each language; any
    /// language not listed falls through to the first supported locale.
    static let defaultRegions: [String: String] = [
        "en": "US", "zh": "CN", "yue": "CN", "es": "ES", "pt": "BR", "fr": "FR",
        "de": "DE", "it": "IT", "ja": "JP", "ko": "KR", "nl": "NL", "sv": "SE",
        "da": "DK", "nb": "NO", "no": "NO", "fi": "FI", "pl": "PL", "tr": "TR",
        "ru": "RU", "uk": "UA", "ar": "SA", "he": "IL", "th": "TH", "vi": "VN",
        "id": "ID", "ms": "MY", "cs": "CZ", "sk": "SK", "hu": "HU", "ro": "RO",
        "el": "GR", "ca": "ES", "hr": "HR", "bg": "BG"
    ]

    /// Whisper spellings that differ from the platform's `Locale.LanguageCode`.
    /// Whisper's `jw` is Javanese (`jv`); everything else is ISO 639-1 or
    /// the 639-3 code both sides use (`yue`, `haw`).
    static let whisperToPlatformLanguage: [String: String] = ["jw": "jv"]
    static let platformToWhisperLanguage: [String: String] = ["jv": "jw"]

    /// The Whisper codes the platform's locale list covers, sorted. A
    /// platform language with no Whisper code (`mul`, `ks`, `mai`, `or` on
    /// macOS 27.0) is not selectable and is dropped; `zh_HK` also counts as
    /// Cantonese (`yue`), because the platform's own equivalence maps
    /// Cantonese there.
    public static func languageCodes(forSupportedLocales identifiers: [String]) -> [String] {
        var codes = Set<String>()
        for identifier in identifiers {
            let locale = Locale(identifier: identifier)
            guard let language = locale.language.languageCode?.identifier else { continue }
            let whisper = platformToWhisperLanguage[language] ?? language
            if TranscriptionLanguage.whisperLanguages.contains(where: { $0.code == whisper }) {
                codes.insert(whisper)
            }
            if language == "zh", locale.region?.identifier == "HK" {
                codes.insert("yue")
            }
        }
        return codes.sorted()
    }

    /// The supported locale to transcribe `code` in, or nil when the
    /// platform supports no locale for the language. `nil` (automatic)
    /// means the Mac's own language (`current`): its exact locale when
    /// supported, else the same rule applied to its language, else English
    /// (US), else the first supported locale — a system runtime has no
    /// language detection, so "Auto-detect" is "your Mac's language".
    public static func localeIdentifier(
        forLanguageCode code: String?,
        supportedLocales identifiers: [String],
        current: Locale = .current
    ) -> String? {
        let supported = identifiers.map { Locale(identifier: $0).identifier }.sorted()
        guard !supported.isEmpty else { return nil }
        let currentIdentifier = Locale(identifier: current.identifier).identifier
        guard let code else {
            if supported.contains(currentIdentifier) { return currentIdentifier }
            if let language = current.language.languageCode?.identifier,
               let match = bestLocale(forPlatformLanguage: language, supported: supported, current: current) {
                return match
            }
            return supported.contains("en_US") ? "en_US" : supported.first
        }
        let language = whisperToPlatformLanguage[code] ?? code
        if let match = bestLocale(forPlatformLanguage: language, supported: supported, current: current) {
            return match
        }
        // Cantonese: the platform's own equivalence lands on zh_HK when it
        // ships no `yue_*` locale.
        if code == "yue", supported.contains("zh_HK") { return "zh_HK" }
        return nil
    }

    private static func bestLocale(forPlatformLanguage language: String, supported: [String], current: Locale) -> String? {
        let candidates = supported.filter { identifier in
            let locale = Locale(identifier: identifier)
            guard locale.language.languageCode?.identifier == language else { return false }
            // `zh_HK` is the platform's Cantonese; a `zh` (Mandarin) request
            // must not land on it just because the Mac's region is HK.
            return !(language == "zh" && locale.region?.identifier == "HK")
        }
        guard !candidates.isEmpty else { return nil }
        if let region = current.region?.identifier,
           let match = candidates.first(where: { Locale(identifier: $0).region?.identifier == region }) {
            return match
        }
        if let region = defaultRegions[language],
           let match = candidates.first(where: { Locale(identifier: $0).region?.identifier == region }) {
            return match
        }
        return candidates.first
    }
}
