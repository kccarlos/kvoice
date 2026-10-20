import Foundation
import XCTest
@testable import KvoiceDomain
@testable import KvoiceUI

/// The String Catalogs are complete and current (product decision #9).
///
/// Failing here means one of: a key was added to the code and
/// `./Scripts/sync_strings.sh` was run but the zh-Hans translation is still
/// missing; a key left the code and the catalog still carries it as
/// `stale`; or a translation changed the format specifiers. The workflow is
/// in Docs/Localization.md.
final class StringCatalogTests: XCTestCase {
    /// Every language a user can pick must be translated in every catalog,
    /// and nothing else may be — a third language needs an `InterfaceLanguage`
    /// case before it ships.
    static let translatedLanguages: Set<String> = Set(InterfaceLanguage.allCases.compactMap(\.languageIdentifier))
        .subtracting(["en"])

    func testEveryTranslatableKeyHasANonEmptyTranslationInEveryLanguage() throws {
        for path in StringCatalog.all {
            let catalog = try StringCatalog(relativePath: path)
            XCTAssertFalse(catalog.entries.isEmpty, "\(path) is empty; run ./Scripts/sync_strings.sh")
            for language in Self.translatedLanguages {
                let missing = catalog.entries.filter { entry in
                    guard entry.shouldTranslate else { return false }
                    let value = entry.localizations[language]?.value ?? ""
                    return value.isEmpty
                }.map(\.key)
                XCTAssertTrue(
                    missing.isEmpty,
                    "\(path): \(missing.count) key(s) have no \(language) translation:\n" + missing.joined(separator: "\n")
                )
            }
        }
    }

    func testNoKeyIsStale() throws {
        for path in StringCatalog.all {
            let catalog = try StringCatalog(relativePath: path)
            let stale = catalog.entries.filter { $0.extractionState == "stale" }.map(\.key)
            XCTAssertTrue(
                stale.isEmpty,
                "\(path): \(stale.count) key(s) are no longer in the code; delete them from the catalog:\n" + stale.joined(separator: "\n")
            )
        }
    }

    /// Product rule (2026-09-16): the product name reads "KVoice" in every
    /// user-facing string, in English and in zh-Hans. Bundle/queue/UserDefaults
    /// identifiers (`io.github.kccarlos.kvoice`), URLs, and file/folder name patterns
    /// (`kvoice-export-<date>`, `kvoice-history.csv`, …) are not prose the user
    /// reads as the product name, so they are exempt — list additions here as
    /// they come up rather than loosening the check generally.
    func testNoLowercaseProductNameInUserFacingCatalogs() throws {
        let allowedPatterns = try [
            NSRegularExpression(pattern: #"io\.github\.kccarlos\.kvoice"#),   // bundle id / queue labels / defaults keys
            NSRegularExpression(pattern: #"https?://\S+"#),            // URLs
            NSRegularExpression(pattern: #"kvoice-[\w.<>-]*"#),        // file/folder name patterns
        ]
        let word = try NSRegularExpression(pattern: #"\bkvoice\b"#)

        func scrubbed(_ text: String) -> String {
            var result = text
            for pattern in allowedPatterns {
                let range = NSRange(result.startIndex..., in: result)
                result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            }
            return result
        }

        func stillLowercase(_ text: String) -> Bool {
            let clean = scrubbed(text)
            let range = NSRange(clean.startIndex..., in: clean)
            return word.firstMatch(in: clean, range: range) != nil
        }

        for path in StringCatalog.all {
            let catalog = try StringCatalog(relativePath: path)
            for entry in catalog.entries {
                XCTAssertFalse(
                    stillLowercase(entry.sourceValue),
                    "\(path): en value for \(entry.key.debugDescription) still reads lowercase \"kvoice\": \(entry.sourceValue.debugDescription)"
                )
                if let zhHans = entry.localizations["zh-Hans"]?.value {
                    XCTAssertFalse(
                        stillLowercase(zhHans),
                        "\(path): zh-Hans value for \(entry.key.debugDescription) still reads lowercase \"kvoice\": \(zhHans.debugDescription)"
                    )
                }
            }
        }
    }

    func testTranslationsKeepTheFormatSpecifiers() throws {
        for path in StringCatalog.all {
            let catalog = try StringCatalog(relativePath: path)
            for entry in catalog.entries where entry.shouldTranslate {
                let expected = StringCatalog.specifiers(in: entry.sourceValue)
                for (language, localization) in entry.localizations where language != "en" {
                    XCTAssertEqual(
                        StringCatalog.specifiers(in: localization.value), expected,
                        "\(path): \(language) translation of \(entry.key.debugDescription) changes the format specifiers"
                    )
                    XCTAssertFalse(
                        StringCatalog.mixesPositions(localization.value),
                        "\(path): \(language) translation of \(entry.key.debugDescription) mixes positional and plain specifiers"
                    )
                }
            }
        }
    }

    func testCatalogsCarryNoUnsupportedLanguage() throws {
        for path in StringCatalog.all {
            let catalog = try StringCatalog(relativePath: path)
            let languages = Set(catalog.entries.flatMap { $0.localizations.keys }).subtracting(["en"])
            XCTAssertTrue(
                languages.isSubset(of: Self.translatedLanguages),
                "\(path) translates \(languages.subtracting(Self.translatedLanguages).sorted()), which InterfaceLanguage does not offer"
            )
        }
    }

    /// SwiftUI resolves a package's `Text("…")` literals against
    /// `Bundle.main`, so the app target compiles KvoiceUI's catalog into the
    /// main bundle as well. Removing that reference would silently un-localize
    /// every SwiftUI view (Docs/Localization.md, "Why two copies").
    func testAppTargetCompilesTheKvoiceUICatalog() throws {
        let project = try String(
            contentsOf: StringCatalog.repositoryRoot.appendingPathComponent("Kvoice.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertTrue(project.contains("path = " + StringCatalog.kvoiceUI))
        XCTAssertTrue(project.contains("Localizable.xcstrings in Resources"))
        XCTAssertTrue(project.contains("Shell.xcstrings in Resources"))
        XCTAssertTrue(project.contains("AppShortcuts.xcstrings in Resources"), "the App Shortcut phrases ship only if the catalog is a bundle resource")
        XCTAssertTrue(project.contains("\"zh-Hans\""), "knownRegions must list every shipped language")
    }

    /// The "KVoice Shortcut" recorder window lives in KvoiceHotkeys, whose
    /// SwiftUI literals and bundle-less `String(localized:)` calls resolve
    /// against `Bundle.main` — KvoiceUI's catalog. 0.1.5 showed it in
    /// English in the Chinese UI because none of its keys were there.
    /// The literals are read from the source, so a new sentence in that file
    /// fails here until it is translated (and `sync_strings.sh` now syncs
    /// KvoiceHotkeys into the same catalog).
    func testTheShortcutRecorderWindowIsTranslated() throws {
        let source = try String(
            contentsOf: StringCatalog.repositoryRoot.appendingPathComponent(
                "Packages/KvoiceHotkeys/Sources/KvoiceHotkeys/ShortcutRecorderWindow.swift"
            ),
            encoding: .utf8
        )
        let pattern = #"(?:Text|Button|Picker|accessibilityLabel|accessibilityHint|String\(localized:)\(?\s*"((?:[^"\\]|\\.)+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        let keys = Set(regex.matches(in: source, range: range).compactMap { match -> String? in
            guard let keyRange = Range(match.range(at: 1), in: source) else { return nil }
            // `\(x)` interpolation becomes `%@` in the catalog key.
            return source[keyRange].replacingOccurrences(of: #"\\\((?:[^()]|\([^()]*\))*\)"#, with: "%@", options: .regularExpression)
        })
        XCTAssertTrue(keys.contains("KVoice Shortcut"), "the window title is localized")
        XCTAssertGreaterThanOrEqual(keys.count, 14, "the extraction found the window's sentences")
        let catalog = try StringCatalog(relativePath: StringCatalog.kvoiceUI)
        for key in keys.sorted() {
            let value = catalog.value(for: key, language: "zh-Hans")
            XCTAssertFalse(value?.isEmpty ?? true, "untranslated recorder string: \(key)")
        }
    }

    func testBaseConfigurationEmitsStringsData() throws {
        let xcconfig = try String(
            contentsOf: StringCatalog.repositoryRoot.appendingPathComponent("Config/Base.xcconfig"),
            encoding: .utf8
        )
        XCTAssertTrue(xcconfig.contains("SWIFT_EMIT_LOC_STRINGS = YES"), "sync_strings.sh needs the compiler's .stringsdata")
    }
}
