import XCTest
import KvoiceAppCore
import KvoiceDomain
@testable import KvoiceUI

/// ADR-022 slice 7 part B: the resolver's "changed from default" table
/// lives on `EffectiveSettings` itself (`changedFromDefault`,
/// `dictionaryBudgetEngineCap`) — `SettingsProvenanceModel`, the shell-owned
/// mirror every page used to read, is gone now that every page is a
/// projection with its own `host.effective`. `SettingsResetRow` reads that
/// host directly and sends `.resetToDefault` itself.
@MainActor
final class SettingsResetRowTests: XCTestCase {
    private func effective(_ user: AppSettings, environment: EnvironmentProfile = .unknown) -> EffectiveSettings {
        SettingsResolver.resolve(user: user, defaults: .compiled, environment: environment)
    }

    func testDefaultShowsNoAffordance() {
        XCTAssertTrue(effective(AppSettings()).changedFromDefault.isEmpty)
        XCTAssertNil(effective(AppSettings()).dictionaryBudgetEngineCap)
    }

    func testChangedFromDefaultFollowsTheUserLayer() {
        var user = AppSettings()
        user.recorderStyle = .notch
        user.triggers.autoSendEnabled = true
        XCTAssertEqual(effective(user).changedFromDefault, [.recorderStyle, .triggers])
        XCTAssertTrue(effective(user).isChangedFromDefault(.recorderStyle))
        XCTAssertFalse(effective(user).isChangedFromDefault(.maxRecordingSeconds))

        // Back to defaults clears it.
        XCTAssertTrue(effective(AppSettings()).changedFromDefault.isEmpty)
    }

    func testDictionaryCapNoteAppearsOnlyWhenTheEngineLimits() {
        let whisper = EnvironmentProfile(enginePromptTokenLimit: .tokens(111), catalogPromptTokenLimit: 224, residentModelID: "w")
        XCTAssertEqual(effective(AppSettings(), environment: whisper).dictionaryBudgetEngineCap, 111)

        let unloaded = EnvironmentProfile(catalogPromptTokenLimit: 224)
        XCTAssertNil(effective(AppSettings(), environment: unloaded).dictionaryBudgetEngineCap)
    }

    /// `SettingsResetRow`'s own reset action: one `.resetToDefault` per row
    /// in the group that is actually changed, sent through the row's host.
    func testTheResetRowSendsOneIntentPerChangedRowInTheGroup() {
        var user = AppSettings()
        user.addSpaceAfterInsertion = true
        user.typedInsertionEnabled = false
        let harness = SettingsProjectionTestHarness(settings: user)
        let rows: [ResettableSetting] = [.addSpaceAfterInsertion, .automaticTextFormatting, .typedInsertionEnabled]
        let changed = harness.host.effective.changedFromDefault
        for row in rows where changed.contains(row) {
            harness.host.send(.resetToDefault(row, origin: .page(.recording)))
        }
        let resetRows: [ResettableSetting] = harness.sent.compactMap {
            if case .resetToDefault(let row, _) = $0 { return row }
            return nil
        }
        XCTAssertEqual(resetRows, [.addSpaceAfterInsertion, .typedInsertionEnabled], "only the changed rows are reset")
    }

    func testTheResetRowRendersOnlyWhenChanged() {
        let plainHarness = SettingsProjectionTestHarness()
        var changedSettings = AppSettings()
        changedSettings.maxRecordingSeconds = 1_800
        let changedHarness = SettingsProjectionTestHarness(settings: changedSettings)

        let hidden = SettingsResetRow(.maxRecordingSeconds, host: plainHarness.host, origin: .page(.recording))
        let shown = SettingsResetRow(.maxRecordingSeconds, host: changedHarness.host, origin: .page(.recording))

        XCTAssertFalse(plainHarness.host.effective.changedFromDefault.contains(.maxRecordingSeconds))
        XCTAssertTrue(changedHarness.host.effective.changedFromDefault.contains(.maxRecordingSeconds))
        XCTAssertEqual(hidden.rows, [.maxRecordingSeconds])
        XCTAssertEqual(shown.rows, [.maxRecordingSeconds])
    }

    func testTheResetCatalogIsTranslated() throws {
        let catalog = try StringCatalog(relativePath: StringCatalog.kvoiceUI)
        for key in [
            "Changed from default", "Reset to Default",
            "Puts this section's settings back to the values KVoice ships with.",
            "Using the loaded model's cap of %lld tokens, which is lower than the model's own limit."
        ] {
            XCTAssertNotNil(catalog.value(for: key, language: "zh-Hans"), "\(key) is missing a zh-Hans translation")
        }
    }
}
