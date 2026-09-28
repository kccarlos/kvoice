import Foundation
import KvoiceDomain

/// Names of speech and translation languages in the interface language.
///
/// `TranscriptionLanguage.displayName` is Whisper's English name. Foundation
/// already knows every language's name in every language, so the UI asks it,
/// in the language the bundle resolved to (not `Locale.current`, whose
/// language follows the region-format setting and can differ from the
/// `AppleLanguages` override). Unknown codes fall back to the English name.
public enum LanguageNames {
    /// The locale whose language matches what the app is displaying.
    public static var interfaceLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// "Chinese" → "中文" under the Simplified Chinese interface; "Auto-detect"
    /// (localized) for nil, the same rule as `TranscriptionLanguage.displayName(forCode:)`.
    public static func transcriptionLanguageName(forCode code: String?, locale: Locale = interfaceLocale) -> String {
        guard let code else {
            return String(localized: "Auto-detect", bundle: .module)
        }
        return locale.localizedString(forLanguageCode: code) ?? TranscriptionLanguage.displayName(forCode: code)
    }
}
