import Foundation
import KvoiceDomain
import XCTest
@testable import KvoiceAppleSpeech

/// ADR-025: Whisper code ↔ platform locale, deterministic and independent
/// of what happens to be installed.
final class AppleSpeechLocaleMappingTests: XCTestCase {
    /// The 45 locales macOS 27.0 reported on 2026-09-16.
    private static let observed27_0 = """
    bn_IN de_AT de_CH de_DE en_AU en_CA en_GB en_IE en_IN en_NZ en_SG en_US en_ZA es_CL es_ES es_MX es_US \
    fr_BE fr_CA fr_CH fr_FR gu_IN hi_IN it_CH it_IT ja_JP kn_IN ko_KR ks_IN mai_IN ml_IN mr_IN mul_IN ne_IN \
    or_IN pa_IN pt_BR pt_PT ta_IN te_IN ur_IN yue_CN zh_CN zh_HK zh_TW
    """.split(separator: " ").map(String.init)

    private let us = Locale(identifier: "en_US")
    private let uk = Locale(identifier: "en_GB")
    private let hongKong = Locale(identifier: "zh_HK")

    func testTheObservedLocaleListYieldsTheShippedCatalogCodes() {
        XCTAssertEqual(
            AppleSpeechLocaleMapping.languageCodes(forSupportedLocales: Self.observed27_0),
            TranscriptionLanguage.appleSpeechShippedLanguageCodes,
            "the catalog's shipped list is exactly what the mapping derives from the observed locales"
        )
    }

    func testPlatformLanguagesWithoutAWhisperCodeAreDroppedAndCantoneseComesFromEitherSpelling() {
        XCTAssertEqual(AppleSpeechLocaleMapping.languageCodes(forSupportedLocales: ["mul_IN", "ks_IN", "or_IN"]), [])
        XCTAssertEqual(AppleSpeechLocaleMapping.languageCodes(forSupportedLocales: ["zh_HK"]), ["yue", "zh"])
        XCTAssertEqual(AppleSpeechLocaleMapping.languageCodes(forSupportedLocales: ["yue_CN"]), ["yue"])
        XCTAssertEqual(AppleSpeechLocaleMapping.languageCodes(forSupportedLocales: ["jv_ID"]), ["jw"], "Whisper spells Javanese jw")
        XCTAssertEqual(AppleSpeechLocaleMapping.languageCodes(forSupportedLocales: ["en-US", "en_GB"]), ["en"], "hyphen or underscore")
    }

    func testTheUsersRegionWinsThenTheDefaultRegionThenTheFirstSupported() {
        let supported = Self.observed27_0
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: "en", supportedLocales: supported, current: uk), "en_GB")
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: "en", supportedLocales: supported, current: us), "en_US")
        // A German speaker in the US: no de_US, so the default region.
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: "de", supportedLocales: supported, current: us), "de_DE")
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: "es", supportedLocales: supported, current: us), "es_US")
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: "es", supportedLocales: supported, current: uk), "es_ES")
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: "pt", supportedLocales: supported, current: us), "pt_BR")
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: "zh", supportedLocales: supported, current: us), "zh_CN")
        // `zh` is Mandarin: a Hong Kong Mac must not land on the platform's
        // Cantonese locale; the default region applies instead.
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: "zh", supportedLocales: supported, current: hongKong), "zh_CN")
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: "zh", supportedLocales: ["zh_HK", "zh_TW"], current: hongKong), "zh_TW")
        XCTAssertNil(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: "zh", supportedLocales: ["zh_HK"], current: hongKong), "zh_HK alone serves Cantonese only")
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: "yue", supportedLocales: supported, current: us), "yue_CN")
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: "yue", supportedLocales: ["zh_HK", "zh_CN"], current: us), "zh_HK", "the platform's own Cantonese fallback")
        // No default region listed: the first supported locale, in order.
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: "hi", supportedLocales: supported, current: us), "hi_IN")
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: "ja", supportedLocales: supported, current: uk), "ja_JP")
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: "jw", supportedLocales: ["jv_ID"], current: us), "jv_ID")
    }

    func testAnUnsupportedLanguageIsNilAndAnEmptyListIsNil() {
        XCTAssertNil(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: "fr", supportedLocales: ["en_US"], current: us))
        XCTAssertNil(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: "en", supportedLocales: [], current: us))
        XCTAssertNil(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: nil, supportedLocales: [], current: us))
    }

    func testAutomaticMeansTheMacsOwnLanguage() {
        let supported = Self.observed27_0
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: nil, supportedLocales: supported, current: uk), "en_GB")
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: nil, supportedLocales: supported, current: hongKong), "zh_HK")
        // A Mac in a region the platform lacks for its language: the language's rule.
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: nil, supportedLocales: supported, current: Locale(identifier: "de_LU")), "de_DE")
        // A Mac whose language the platform lacks entirely: English (US).
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: nil, supportedLocales: supported, current: Locale(identifier: "fi_FI")), "en_US")
        XCTAssertEqual(AppleSpeechLocaleMapping.localeIdentifier(forLanguageCode: nil, supportedLocales: ["ja_JP"], current: Locale(identifier: "fi_FI")), "ja_JP")
    }
}
