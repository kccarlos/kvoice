import Foundation
import KvoiceDomain

/// Applies Settings › General › Interface language the way macOS apps do it:
/// by writing `AppleLanguages` into the app's own defaults domain and
/// relaunching. Foundation reads that key once, at process start, and AppKit
/// menus and hosted SwiftUI do not re-localize in place, so the change is
/// visible only after a relaunch (Docs/Architecture.md, "Localization").
///
/// `AppSettings.interfaceLanguage` stays the source of truth; this mirror is
/// re-applied on every launch so a restored settings file or a cleared
/// defaults domain converges on the next start.
public enum InterfaceLanguageOverride {
    public static let appleLanguagesKey = "AppleLanguages"

    /// Writes (or, for `.system`, removes) the override. Returns true when the
    /// stored value changed, which is when a relaunch is worth offering.
    ///
    /// `domain` names the defaults domain to inspect — the app's bundle
    /// identifier for `.standard`, the suite name for a test's suite.
    @discardableResult
    public static func apply(
        _ language: InterfaceLanguage,
        defaults: UserDefaults = .standard,
        domain: String = Bundle.main.bundleIdentifier ?? ""
    ) -> Bool {
        let before = stored(in: defaults, domain: domain)
        if let identifier = language.languageIdentifier {
            defaults.set([identifier], forKey: appleLanguagesKey)
        } else {
            defaults.removeObject(forKey: appleLanguagesKey)
        }
        return before != stored(in: defaults, domain: domain)
    }

    /// The override currently stored in the app's own domain: nil when the
    /// app follows the system list. Only the app's own write is inspected —
    /// `UserDefaults.array(forKey:)` would also return the global list.
    public static func stored(
        in defaults: UserDefaults = .standard,
        domain: String = Bundle.main.bundleIdentifier ?? ""
    ) -> String? {
        let own = defaults.persistentDomain(forName: domain) ?? [:]
        return (own[appleLanguagesKey] as? [String])?.first
    }
}
