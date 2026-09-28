import Foundation
import XCTest

/// Reads a `.xcstrings` String Catalog from the source tree. `swift build`
/// copies catalogs into the resource bundle without compiling them, so the
/// tests parse the JSON directly rather than asking Foundation for `.lproj`
/// tables (see Docs/Localization.md).
struct StringCatalog {
    struct Entry {
        let key: String
        let extractionState: String?
        let shouldTranslate: Bool
        /// Language identifier → (state, value).
        let localizations: [String: (state: String?, value: String)]
        let sourceValue: String
    }

    let path: String
    let sourceLanguage: String
    let entries: [Entry]

    /// The repository root, derived from this file's location so the tests
    /// need no environment variable.
    static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        // .../Packages/KvoiceUI/Tests/KvoiceUITests/StringCatalogSupport.swift
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    static let kvoiceUI = "Packages/KvoiceUI/Sources/KvoiceUI/Resources/Localizable.xcstrings"
    static let domainCopy = "Packages/KvoiceUI/Sources/KvoiceUI/Resources/DomainCopy.xcstrings"
    static let shell = "Apps/KvoiceApp/Resources/Shell.xcstrings"
    /// ADR-020: the App Shortcut phrases. Xcode's App Intents metadata step
    /// reads this catalog, not the compiler, so `sync_strings.sh` never
    /// touches it; it is maintained by hand like DomainCopy.
    static let appShortcuts = "Apps/KvoiceApp/Resources/AppShortcuts.xcstrings"
    static let all = [kvoiceUI, domainCopy, shell, appShortcuts]

    init(relativePath: String) throws {
        let url = Self.repositoryRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: Any] else {
            throw NSError(domain: "StringCatalog", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(relativePath) is not a String Catalog"])
        }
        path = relativePath
        sourceLanguage = root["sourceLanguage"] as? String ?? "en"
        entries = strings.map { key, raw in
            let dict = raw as? [String: Any] ?? [:]
            var localizations: [String: (state: String?, value: String)] = [:]
            for (language, value) in dict["localizations"] as? [String: Any] ?? [:] {
                let unit = (value as? [String: Any])?["stringUnit"] as? [String: Any]
                localizations[language] = (unit?["state"] as? String, unit?["value"] as? String ?? "")
            }
            return Entry(
                key: key,
                extractionState: dict["extractionState"] as? String,
                shouldTranslate: dict["shouldTranslate"] as? Bool ?? true,
                localizations: localizations,
                sourceValue: localizations["en"]?.value ?? key
            )
        }
        .sorted { $0.key < $1.key }
    }

    /// Translation of `key` in `language`, or nil when the catalog has none.
    func value(for key: String, language: String) -> String? {
        entries.first { $0.key == key }?.localizations[language]?.value
    }

    /// `[key: value]` for one language — what `DomainCopy.Table.dictionary`
    /// takes.
    func dictionary(for language: String) -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries {
            if let value = entry.localizations[language]?.value, !value.isEmpty {
                result[entry.key] = value
            }
        }
        return result
    }

    /// Format specifiers in order of appearance, positions stripped, so a
    /// translation that reorders `%1$@ %2$lld` still compares equal.
    static func specifiers(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(\d+\$)?(@|lld|lf|\.\df|f|d)"#)
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 2), in: text).map { String(text[$0]) }
        }.sorted()
    }

    /// True when a string mixes positional and non-positional specifiers,
    /// which `String(format:)` rejects.
    static func mixesPositions(_ text: String) -> Bool {
        let pattern = try! NSRegularExpression(pattern: #"%(\d+\$)?(@|lld|lf|\.\df|f|d)"#)
        let range = NSRange(text.startIndex..., in: text)
        let positional = pattern.matches(in: text, range: range).map { $0.range(at: 1).location != NSNotFound }
        return positional.contains(true) && positional.contains(false)
    }
}
