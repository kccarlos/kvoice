import Foundation
import XCTest
import KvoiceAppCore
@testable import KvoiceDomain
@testable import KvoiceUI

/// The Interface language picker (product decision #9): the setting persists
/// as a `.setInterfaceLanguage` intent from the page, the `AppleLanguages`
/// mirror is written once the coordinator accepted it, and the view model
/// raises a relaunch intent that resolves to the shell's Restart route or to
/// nothing.
@MainActor
final class InterfaceLanguageTests: XCTestCase {
    func testPickingALanguageWritesTheOverridePersistsAndAsksToRelaunch() {
        var overrides: [InterfaceLanguage] = []
        var restarts = 0
        let harness = SettingsProjectionTestHarness()
        let model = GeneralSettingsViewModel(
            host: harness.host,
            onRestartApp: { restarts += 1 },
            applyLanguageOverride: { overrides.append($0) }
        )
        XCTAssertEqual(model.interfaceLanguage, .system)
        XCTAssertFalse(model.isRelaunchForLanguagePending)

        model.interfaceLanguage = .simplifiedChinese

        XCTAssertEqual(overrides, [.simplifiedChinese], "the mirror is written before the relaunch is offered")
        XCTAssertEqual(harness.sent, [.setInterfaceLanguage(.simplifiedChinese, origin: .page(.general))])
        XCTAssertEqual(harness.effects, [.persist, .rebuildMenu], "a page asks the relaunch consent itself; no offerRelaunch effect")
        XCTAssertTrue(model.isRelaunchForLanguagePending)
        XCTAssertEqual(restarts, 0, "nothing relaunches until the user confirms")

        model.relaunchForLanguage()
        XCTAssertEqual(restarts, 1)
        XCTAssertFalse(model.isRelaunchForLanguagePending)
    }

    func testDecliningTheRelaunchKeepsTheSetting() {
        var restarts = 0
        let harness = SettingsProjectionTestHarness()
        let model = GeneralSettingsViewModel(host: harness.host, onRestartApp: { restarts += 1 }, applyLanguageOverride: { _ in })

        model.interfaceLanguage = .english
        model.deferRelaunchForLanguage()

        XCTAssertFalse(model.isRelaunchForLanguagePending)
        XCTAssertEqual(model.interfaceLanguage, .english)
        XCTAssertEqual(harness.settings.interfaceLanguage, .english)
        XCTAssertEqual(restarts, 0)
    }

    func testARefusedLanguageChangeWritesNoOverrideAndOffersNoRelaunch() {
        var overrides: [InterfaceLanguage] = []
        let harness = SettingsProjectionTestHarness()
        let model = GeneralSettingsViewModel(host: harness.host, applyLanguageOverride: { overrides.append($0) })
        harness.startJob()

        model.interfaceLanguage = .english

        XCTAssertEqual(model.interfaceLanguage, .system, "the picker snaps back")
        XCTAssertTrue(overrides.isEmpty, "a language the coordinator refused is never mirrored")
        XCTAssertFalse(model.isRelaunchForLanguagePending)
        XCTAssertEqual(model.refusalNote, "Finish the current dictation first.")
    }

    func testAChangeFromAnotherDoorDoesNotOfferARelaunchHere() {
        var overrides: [InterfaceLanguage] = []
        let harness = SettingsProjectionTestHarness(settings: AppSettings(interfaceLanguage: .english))
        let model = GeneralSettingsViewModel(host: harness.host, applyLanguageOverride: { overrides.append($0) })
        XCTAssertEqual(model.interfaceLanguage, .english)

        harness.commitFromElsewhere(.setInterfaceLanguage(.simplifiedChinese, origin: .import))

        XCTAssertEqual(model.interfaceLanguage, .simplifiedChinese)
        XCTAssertTrue(overrides.isEmpty, "an import is not a page edit; the shell's offerRelaunch effect mirrors it and asks")
        XCTAssertEqual(harness.effects.first, .offerRelaunch(.simplifiedChinese))
        XCTAssertFalse(model.isRelaunchForLanguagePending)
    }

    func testOverrideWritesAndRemovesAppleLanguagesInTheGivenDomain() {
        let suite = "io.github.kccarlos.kvoice.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(InterfaceLanguageOverride.stored(in: defaults, domain: suite))

        XCTAssertTrue(InterfaceLanguageOverride.apply(.simplifiedChinese, defaults: defaults, domain: suite))
        XCTAssertEqual(InterfaceLanguageOverride.stored(in: defaults, domain: suite), "zh-Hans")
        XCTAssertEqual(defaults.array(forKey: InterfaceLanguageOverride.appleLanguagesKey) as? [String], ["zh-Hans"])

        XCTAssertFalse(InterfaceLanguageOverride.apply(.simplifiedChinese, defaults: defaults, domain: suite), "re-applying the same value is not a change")

        XCTAssertTrue(InterfaceLanguageOverride.apply(.english, defaults: defaults, domain: suite))
        XCTAssertEqual(InterfaceLanguageOverride.stored(in: defaults, domain: suite), "en")

        XCTAssertTrue(InterfaceLanguageOverride.apply(.system, defaults: defaults, domain: suite))
        XCTAssertNil(InterfaceLanguageOverride.stored(in: defaults, domain: suite), ".system removes the override rather than writing a list")
    }
}
