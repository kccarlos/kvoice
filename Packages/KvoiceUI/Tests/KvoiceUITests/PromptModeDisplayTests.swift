import Foundation
import KvoiceAppCore
import KvoiceDomain
import XCTest
@testable import KvoiceUI

/// 2026-10-22: the built-in AI actions' names and descriptions follow the
/// interface language at display time, while the stored `name` / `summary`
/// stay the shipped English (so `isRevisedBuiltIn`, Reset and the 0.1.6
/// "unedited built-in picks up new instructions" rule keep working). A
/// renamed or user-created action shows exactly what the user typed.
@MainActor
final class PromptModeDisplayTests: XCTestCase {
    private var zhHans: DomainCopy.Table!
    private let english = DomainCopy.Table.dictionary([:])

    override func setUpWithError() throws {
        let catalog = try StringCatalog(relativePath: StringCatalog.domainCopy)
        zhHans = .dictionary(catalog.dictionary(for: "zh-Hans"))
    }

    private func builtIn(_ key: String) throws -> PromptMode {
        try XCTUnwrap(BuiltInPromptModes.shipped(forKey: key))
    }

    func testAnUnrenamedBuiltInShowsItsLocalizedNameAndDescription() throws {
        let clean = try builtIn(BuiltInPromptModes.Key.clean)
        XCTAssertEqual(clean.displayTitle(table: zhHans), "清理")
        XCTAssertEqual(clean.displaySummary(table: zhHans), "最小清理：去掉口头语和说错重来的部分，保留措辞、语气和结构。")
        XCTAssertEqual(clean.displayTitle(table: english), "Clean Up", "English resolves to the shipped name")
        XCTAssertEqual(clean.name, "Clean Up", "the stored value is untouched")
    }

    func testEveryBuiltInHasAChineseNameAndDescription() {
        for mode in BuiltInPromptModes.all {
            XCTAssertNotEqual(mode.displayTitle(table: zhHans), mode.name, "\(mode.name) is shown in English")
            XCTAssertNotEqual(mode.displaySummary(table: zhHans), mode.summary, "\(mode.name)'s description is shown in English")
        }
    }

    func testARenamedBuiltInShowsExactlyWhatTheUserTyped() throws {
        var clean = try builtIn(BuiltInPromptModes.Key.clean)
        clean.name = "My Cleanup"
        XCTAssertEqual(clean.displayTitle(table: zhHans), "My Cleanup")
        XCTAssertEqual(
            clean.displaySummary(table: zhHans), "最小清理：去掉口头语和说错重来的部分，保留措辞、语气和结构。",
            "an untouched description stays localized: each field is judged on its own"
        )
        clean.summary = "Mine"
        XCTAssertEqual(clean.displaySummary(table: zhHans), "Mine")
    }

    func testAUserActionNamedLikeABuiltInIsShownVerbatim() {
        let mine = PromptMode(name: "Clean Up", behavior: .polish, prompt: "x", summary: "Minimal cleanup: remove fillers and false starts; keep wording, tone, and structure.")
        XCTAssertEqual(mine.displayTitle(table: zhHans), "Clean Up", "not a built-in: user data, never translated")
        XCTAssertEqual(mine.displaySummary(table: zhHans), mine.summary)
    }

    // MARK: The detail sheet's round trip

    func testSavingAnUntouchedBuiltInInChineseStoresTheEnglishUnchanged() throws {
        var ai = AIEndpointSettings()
        ai.seedBuiltInPromptModesIfNeeded()
        let harness = SettingsProjectionTestHarness(settings: AppSettings(ai: ai))
        let model = PromptModeSettingsViewModel(host: harness.host)
        let clean = try XCTUnwrap(model.modes.first { $0.builtInKey == BuiltInPromptModes.Key.clean })

        let draft = PromptModeDraft(mode: clean, table: zhHans)
        XCTAssertEqual(draft.name, "清理", "the sheet shows the localized name")
        XCTAssertEqual(draft.storedName, "Clean Up")
        XCTAssertEqual(draft.storedSummary, clean.summary)

        model.updateMode(id: clean.id, from: draft)
        let saved = try XCTUnwrap(harness.host.settings.ai.promptModes.first { $0.id == clean.id })
        XCTAssertEqual(saved, clean, "an untouched Save writes the stored English back, byte for byte")
        XCTAssertFalse(saved.isRevisedBuiltIn)
    }

    func testARenameInTheSheetIsStoredAsTyped() throws {
        let translate = try builtIn(BuiltInPromptModes.Key.translate)
        var draft = PromptModeDraft(mode: translate, table: zhHans)
        XCTAssertEqual(draft.name, "翻译")
        draft.name = "翻译成日语"
        XCTAssertEqual(draft.storedName, "翻译成日语")
        draft.summary = "日语"
        XCTAssertEqual(draft.storedSummary, "日语")
    }

    func testANewActionFromABuiltInTemplateKeepsTheShownTextAsItsOwn() throws {
        let notes = try builtIn(BuiltInPromptModes.Key.notes)
        let shown = notes.displaySummary(table: .module)
        let draft = PromptModeDraft(basedOn: notes, name: "Mine")
        XCTAssertEqual(draft.storedName, "Mine")
        XCTAssertEqual(draft.storedSummary, shown, "a user action stores what it showed; it is never mapped back to the built-in's key")
    }

    func testDisplayingAnActionNeverWritesSettings() {
        var ai = AIEndpointSettings()
        ai.seedBuiltInPromptModesIfNeeded()
        let harness = SettingsProjectionTestHarness(settings: AppSettings(ai: ai))
        let model = PromptModeSettingsViewModel(host: harness.host)
        for mode in model.modes {
            _ = mode.displayTitle(table: zhHans)
            _ = mode.displaySummary(table: zhHans)
            _ = PromptModeDraft(mode: mode, table: zhHans)
        }
        XCTAssertTrue(harness.sent.isEmpty, "localizing is display-only")
        XCTAssertEqual(harness.host.settings.ai.promptModes.map(\.name), BuiltInPromptModes.all.map(\.name))
    }
}
