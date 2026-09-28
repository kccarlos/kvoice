import XCTest
import KvoiceDomain
@testable import KvoiceUI

/// ADR-022 item 3: the observable table the pages read.
@MainActor
final class SettingsAvailabilityModelTests: XCTestCase {
    func testEveryKeyIsEnabledUntilTheShellSaysOtherwise() {
        let model = SettingsAvailabilityModel()
        for key in SettingKey.allCases {
            XCTAssertTrue(model.isEnabled(key), key.rawValue)
            XCTAssertNil(model.disabledReason(key), key.rawValue)
            XCTAssertEqual(model.footnote(key, base: "Base."), "Base.", key.rawValue)
        }
    }

    func testUpdateTakesTheShellsTableAndLocalizesTheReason() {
        let model = SettingsAvailabilityModel()
        let table = SettingsAvailability.table(
            settings: AppSettings(),
            environment: EnvironmentProfile(hasNotch: true, enginePromptTokenLimit: .unsupported, residentModelID: "parakeet"),
            gate: SettingsGate(dictation: .jobActive)
        )
        model.update(table)
        XCTAssertFalse(model.isEnabled(.recordingFeedback))
        XCTAssertEqual(model.disabledReason(.recordingFeedback), DomainCopy.localized(SettingAvailabilityReason.finishDictationFirst.message))
        XCTAssertEqual(
            model.footnote(.dictionary, base: "Names and jargon."),
            "Names and jargon. " + DomainCopy.localized(SettingAvailabilityReason.modelTakesNoPrompt.message)
        )
        // Rules that do not read the gate answer from the settings alone
        // (the default AI block has the switch off).
        XCTAssertEqual(model.disabledReason(.aiActionSettings), DomainCopy.localized(SettingAvailabilityReason.aiActionsOff.message))
    }

    func testAnUnchangedTableIsNotRewritten() {
        let model = SettingsAvailabilityModel()
        let table: [SettingKey: SettingAvailability] = [.dictionary: .disabled(reason: "x")]
        model.update(table)
        // The equality guard is what keeps a 1 Hz poll from re-rendering
        // every page; the observable value is only replaced on a change.
        let before = model.table
        model.update(table)
        XCTAssertEqual(model.table, before)
        model.update([:])
        XCTAssertEqual(model.table, [:])
        XCTAssertTrue(model.isEnabled(.dictionary))
    }

    func testEveryReasonHasAChineseTranslation() throws {
        let catalog = try StringCatalog(relativePath: StringCatalog.domainCopy)
        let zhHans = DomainCopy.Table.dictionary(catalog.dictionary(for: "zh-Hans"))
        for reason in SettingAvailabilityReason.allCases {
            XCTAssertNotEqual(DomainCopy.localized(reason.message, table: zhHans), reason.message, reason.rawValue)
        }
    }
}
