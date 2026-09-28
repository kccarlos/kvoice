import XCTest
import KvoiceAppCore
@testable import KvoiceDomain
@testable import KvoiceUI

/// Modes are named prompts the user switches between from the menu bar.
/// Selecting one copies its prompt and semantics into the live request fields,
/// which is what the request path actually reads.
@MainActor
final class PromptModeTests: XCTestCase {
    // MARK: Built-ins

    func testShippedModesAreDistinctAndUsable() {
        let all = BuiltInPromptModes.all
        XCTAssertGreaterThanOrEqual(all.count, 3, "at least three modes ship")

        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "identifiers must be unique")
        XCTAssertEqual(Set(all.map(\.name)).count, all.count, "menu names must be unique")
        for mode in all {
            XCTAssertTrue(mode.isUsable, "\(mode.name) must have a name and a prompt")
            XCTAssertTrue(mode.isBuiltIn)
            XCTAssertFalse(mode.isRevisedBuiltIn, "a freshly shipped mode is not revised")
        }
    }

    func testBuiltInIdentifiersAreStableAcrossCalls() {
        // Selection is persisted by id, so these must not be random per launch.
        XCTAssertEqual(BuiltInPromptModes.all.map(\.id), BuiltInPromptModes.all.map(\.id))
    }

    func testShippedPromptsDefendAgainstInjectionAndForbidFormatting() {
        for mode in BuiltInPromptModes.all {
            let prompt = mode.prompt
            XCTAssertTrue(
                prompt.contains("<TRANSCRIPT>"),
                "\(mode.name) must name the transcript delimiter it is given"
            )
            XCTAssertTrue(
                prompt.lowercased().contains("never instructions")
                    || prompt.lowercased().contains("not instructions"),
                "\(mode.name) must tell the model the transcript is data"
            )
        }
    }

    func testTranslateModeCarriesLanguagePlaceholders() {
        let translate = BuiltInPromptModes.shipped(forKey: BuiltInPromptModes.Key.translate)
        XCTAssertEqual(translate?.behavior, .translate)
        XCTAssertTrue(translate?.prompt.contains("{targetLanguageDisplayName}") == true)
    }

    func testOnlyTheTranslateActionsUseTranslateBehavior() {
        let translating = Set([BuiltInPromptModes.Key.translate, BuiltInPromptModes.Key.translate2])
        for mode in BuiltInPromptModes.all {
            if translating.contains(mode.builtInKey ?? "") {
                XCTAssertEqual(mode.behavior, .translate, "\(mode.name) translates")
                XCTAssertNotNil(mode.translationLanguage)
            } else {
                XCTAssertEqual(mode.behavior, .polish, "\(mode.name) edits rather than translates")
            }
        }
    }

    // MARK: Applying

    func testSelectingAPolishModeSetsThePolishPrompt() {
        var settings = AIEndpointSettings(
            baseURL: URL(string: "http://localhost:11434/v1"),
            modelID: "gemma4:latest",
            isEnabled: true
        )
        settings.seedBuiltInPromptModesIfNeeded()
        let notes = settings.promptModes.first { $0.builtInKey == BuiltInPromptModes.Key.notes }!

        settings.apply(promptMode: notes)

        XCTAssertEqual(settings.mode, .polish)
        XCTAssertEqual(settings.promptConfiguration.polishPrompt, notes.prompt)
        XCTAssertEqual(settings.activePromptModeID, notes.id)
    }

    func testSelectingATranslateModeSetsTranslatePromptAndLanguage() {
        var settings = AIEndpointSettings(
            baseURL: URL(string: "http://localhost:11434/v1"),
            modelID: "gemma4:latest",
            isEnabled: true
        )
        settings.seedBuiltInPromptModesIfNeeded()
        var translate = settings.promptModes.first { $0.behavior == .translate }!
        translate.translationLanguage = TranslationLanguage(bcp47: "ja", displayName: "Japanese")

        settings.apply(promptMode: translate)

        XCTAssertEqual(settings.mode, .translate)
        XCTAssertEqual(settings.promptConfiguration.translatePrompt, translate.prompt)
        XCTAssertEqual(settings.translationLanguage.bcp47, "ja")
    }

    /// A custom translate prompt has to actually reach the request, and its
    /// placeholders must be resolved.
    func testCustomTranslatePromptIsUsedWithSubstitution() {
        var settings = AIEndpointSettings()
        let custom = PromptMode(
            name: "To German",
            behavior: .translate,
            prompt: "Translate into {targetLanguageDisplayName} ({targetLanguageBCP47}).",
            translationLanguage: TranslationLanguage(bcp47: "de", displayName: "German")
        )
        settings.apply(promptMode: custom)

        let resolved = settings.promptConfiguration.systemPrompt(
            for: .translate,
            targetLanguage: settings.translationLanguage
        )
        XCTAssertEqual(resolved, "Translate into German (de).")
    }

    func testSeedingDoesNotOverwriteExistingModes() {
        var settings = AIEndpointSettings()
        let mine = PromptMode(name: "Mine", behavior: .polish, prompt: "Do the thing.")
        settings.promptModes = [mine]

        settings.seedBuiltInPromptModesIfNeeded()

        XCTAssertEqual(settings.promptModes, [mine])
    }

    // MARK: View model

    /// Includes an endpoint, because processing cannot be enabled without one.
    private func makeViewModel(
        preview: @escaping @MainActor (PromptMode, String) async throws -> String = { _, _ in "" }
    ) -> PromptModeSettingsViewModel {
        var settings = AIEndpointSettings(
            baseURL: URL(string: "http://localhost:11434/v1"),
            modelID: "gemma4:latest",
            isEnabled: true
        )
        settings.seedBuiltInPromptModesIfNeeded()
        return PromptModeSettingsViewModel(host: .detached(settings: AppSettings(ai: settings)), previewRunner: preview)
    }

    /// Enabling a mode with no endpoint would persist settings that
    /// `AIEndpointSettings` then refuses to decode, losing the user's settings.
    func testSelectingAModeWithoutAnEndpointDoesNotEnableProcessing() {
        var settings = AIEndpointSettings()
        settings.seedBuiltInPromptModesIfNeeded()
        let model = PromptModeSettingsViewModel(host: .detached(settings: AppSettings(ai: settings)))

        model.selectMode(id: model.modes[0].id)

        XCTAssertEqual(model.activeModeID, model.modes[0].id, "the choice is remembered")
        XCTAssertFalse(model.isProcessingEnabled, "but processing stays off")
        XCTAssertFalse(model.canEnableProcessing)

        // The result must round-trip, which is the invariant being protected.
        XCTAssertNoThrow(
            try JSONDecoder().decode(
                AIEndpointSettings.self,
                from: try JSONEncoder().encode(model.settings)
            )
        )
    }

    func testSelectingAModeMakesItActive() {
        let model = makeViewModel()
        let mode = model.modes[1]

        model.selectMode(id: mode.id)

        XCTAssertEqual(model.activeModeID, mode.id)
        XCTAssertTrue(model.isProcessingEnabled)
        XCTAssertEqual(model.settings.promptConfiguration.polishPrompt, mode.prompt)
    }

    func testDisablingKeepsTheChosenModeButStopsProcessing() {
        let model = makeViewModel()
        let mode = model.modes[0]
        model.selectMode(id: mode.id)

        model.disableProcessing()

        XCTAssertFalse(model.isProcessingEnabled)
        XCTAssertEqual(model.activeModeID, mode.id, "the choice is remembered")
    }

    func testAddingAModeRequiresNameAndPrompt() {
        let model = makeViewModel()
        model.selectMode(id: model.modes[0].id)
        XCTAssertNil(model.addMode(PromptModeDraft(name: "", prompt: "x")))
        XCTAssertNil(model.addMode(PromptModeDraft(name: "x", prompt: "  ")))

        let added = model.addMode(PromptModeDraft(name: "Terse", prompt: "Be terse."))
        XCTAssertNotNil(added)
        XCTAssertNotEqual(model.activeModeID, added?.id, "adding an action does not steal the default")
        XCTAssertFalse(added?.isBuiltIn ?? true)
        XCTAssertTrue(added?.usesSystemInstructionsTemplate ?? false, "a new action is written as a task")
        XCTAssertTrue(added?.effectiveSystemPrompt.contains("<SYSTEM_INSTRUCTIONS>") ?? false)
    }

    func testAddingTheFirstActionMakesItTheDefault() {
        let model = PromptModeSettingsViewModel()
        let added = model.addMode(PromptModeDraft(name: "Only", prompt: "Do it."))
        XCTAssertEqual(model.activeModeID, added?.id)
    }

    func testAddedModeNamesStayDistinct() {
        let model = makeViewModel()
        let existing = model.modes[0].name

        let added = model.addMode(PromptModeDraft(name: existing, prompt: "Something."))

        XCTAssertEqual(added?.name, "\(existing) 2")
    }

    func testEditingABuiltInMarksItRevisedAndCanBeRestored() {
        let model = makeViewModel()
        let original = model.modes[0]

        var draft = PromptModeDraft(mode: original)
        draft.prompt = "Completely different instructions."
        model.updateMode(id: original.id, from: draft)

        XCTAssertTrue(model.modes[0].isRevisedBuiltIn)
        XCTAssertTrue(model.modes[0].isBuiltIn, "it keeps its link to the original")

        model.restoreBuiltIn(id: original.id)
        XCTAssertFalse(model.modes[0].isRevisedBuiltIn)
        XCTAssertEqual(model.modes[0].prompt, original.prompt)
    }

    func testBuiltInsCannotBeDeletedButUserActionsCan() {
        let model = makeViewModel()
        let builtIn = model.modes[0]
        XCTAssertFalse(model.canDelete(id: builtIn.id))
        model.deleteMode(id: builtIn.id)
        XCTAssertTrue(model.modes.contains { $0.id == builtIn.id }, "a built-in survives a delete request")

        let mine = model.addMode(PromptModeDraft(name: "Mine", prompt: "Do it."))!
        XCTAssertTrue(model.canDelete(id: mine.id))
        model.deleteMode(id: mine.id)
        XCTAssertFalse(model.modes.contains { $0.id == mine.id })
    }

    func testResetAllBuiltInsRestoresTextAndAddsMissingOnesLeavingCustomAlone() {
        var settings = AIEndpointSettings()
        // A user who seeded before the new built-ins shipped has only a few.
        settings.promptModes = Array(BuiltInPromptModes.all.prefix(2))
        settings.promptModes[0].prompt = "Edited."
        settings.promptModes[0].options.formalWriting = true
        let model = PromptModeSettingsViewModel(host: .detached(settings: AppSettings(ai: settings)))
        let mine = model.addMode(PromptModeDraft(name: "Mine", prompt: "Do it."))!

        model.resetAllBuiltIns()

        XCTAssertEqual(
            Set(model.modes.compactMap(\.builtInKey)),
            Set(BuiltInPromptModes.all.compactMap(\.builtInKey)),
            "every shipped action is present"
        )
        XCTAssertFalse(model.modes[0].isRevisedBuiltIn)
        XCTAssertTrue(model.modes[0].options.formalWriting, "mode settings survive a reset")
        XCTAssertEqual(model.modes.filter { $0.id == mine.id }.count, 1)
    }

    func testDuplicatingAnActionMakesAnEditableCopyWithoutTriggers() {
        let model = makeViewModel()
        let original = model.modes.first { $0.builtInKey == BuiltInPromptModes.Key.terminal }!

        let copy = model.duplicateMode(id: original.id)!

        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertEqual(copy.prompt, original.prompt)
        XCTAssertEqual(copy.name, "Terminal copy")
        XCTAssertTrue(copy.triggerWords.isEmpty, "a copy must not compete for the original's trigger words")
        XCTAssertTrue(model.canDelete(id: copy.id))
    }

    func testDeletingAnActionUnbindsItsSelectionSlot() {
        let model = makeViewModel()
        let mine = model.addMode(PromptModeDraft(name: "Mine", prompt: "Do it."))!
        model.bindSelectionAction(mine.id, slot: 1)
        XCTAssertEqual(model.selectionAction(slot: 1)?.id, mine.id)

        model.deleteMode(id: mine.id)

        XCTAssertNil(model.selectionActionSlots[1])
        XCTAssertNil(model.settings.selectionAction(slot: 1))
    }

    func testEditingTheActiveModeReappliesItImmediately() {
        let model = makeViewModel()
        let mode = model.modes[0]
        model.selectMode(id: mode.id)

        var draft = PromptModeDraft(mode: mode)
        draft.prompt = "New instructions."
        model.updateMode(id: mode.id, from: draft)

        XCTAssertEqual(
            model.settings.promptConfiguration.polishPrompt,
            "New instructions.",
            "a live mode must pick up its own edit"
        )
    }

    // MARK: Preview

    func testPreviewRunsTheDraftPromptAndReportsOutput() async {
        let model = makeViewModel(preview: { _, sample in "cleaned: \(sample)" })
        model.previewInput = "um so like the thing"

        await model.runPreview(using: PromptModeDraft(name: "T", prompt: "Clean it."))

        XCTAssertEqual(model.previewOutput, "cleaned: um so like the thing")
        XCTAssertEqual(model.previewState, .succeeded)
    }

    func testPreviewNeedsSampleTextAndACompleteDraft() async {
        let model = makeViewModel(preview: { _, _ in "out" })

        model.previewInput = "   "
        XCTAssertFalse(model.canRunPreview)

        model.previewInput = "hello"
        await model.runPreview(using: PromptModeDraft(name: "", prompt: ""))
        XCTAssertEqual(model.previewState, .failed("Give the action a name and instructions first."))
    }

    func testPreviewFailureIsReportedWithoutEndpointDetail() async {
        let model = makeViewModel(preview: { _, _ in
            throw KVoiceError(code: .aiUnreachable)
        })
        model.previewInput = "hello"

        await model.runPreview(using: PromptModeDraft(name: "T", prompt: "Clean it."))

        guard case .failed(let message) = model.previewState else {
            return XCTFail("expected a failure state")
        }
        XCTAssertFalse(message.lowercased().contains("http"))
        XCTAssertFalse(message.contains("localhost"))
    }

    // MARK: Persistence

    func testModesSurviveARoundTrip() throws {
        var settings = AIEndpointSettings(
            baseURL: URL(string: "http://localhost:11434/v1"),
            modelID: "gemma4:latest"
        )
        settings.seedBuiltInPromptModesIfNeeded()
        let chosen = settings.promptModes[2]
        settings.apply(promptMode: chosen)

        let decoded = try JSONDecoder().decode(
            AIEndpointSettings.self,
            from: try JSONEncoder().encode(settings)
        )

        XCTAssertEqual(decoded.promptModes.count, settings.promptModes.count)
        XCTAssertEqual(decoded.activePromptModeID, chosen.id)
        XCTAssertEqual(decoded.activePromptMode?.name, chosen.name)
    }

    /// Settings written before modes existed must still load.
    func testSettingsWithoutModesStillDecode() throws {
        let json = #"{"mode":"off","modelID":"","translationLanguage":{"bcp47":"en","displayName":"English"}}"#
        let decoded = try JSONDecoder().decode(AIEndpointSettings.self, from: Data(json.utf8))

        XCTAssertTrue(decoded.promptModes.isEmpty)
        XCTAssertNil(decoded.activePromptModeID)
    }
}
