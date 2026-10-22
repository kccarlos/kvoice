import XCTest
import KvoiceAppCore
import KvoiceDomain
@testable import KvoiceUI

/// Q3 (2026-10-22): the restructured AI Actions page's seams — the top
/// card's status line (same words as Home), the default strip's facts line,
/// the action detail's draft now carrying the mode settings (saved by Save,
/// reverted by Cancel), and which of the detail's immediate buttons apply.
@MainActor
final class AIActionsIATests: XCTestCase {
    private func seeded(endpoint: Bool = true, enabled: Bool = true) -> AIEndpointSettings {
        var ai = AIEndpointSettings(
            baseURL: endpoint ? URL(string: "http://localhost:11434/v1") : nil,
            modelID: endpoint ? "gemma4:latest" : ""
        )
        ai.seedBuiltInPromptModesIfNeeded()
        let configuration = AIConfiguration(name: "Local Ollama", kind: .ollama, baseURL: ai.baseURL, modelID: ai.modelID)
        if endpoint {
            ai.configurations = [configuration]
            ai.activeConfigurationID = configuration.id
        }
        ai.apply(promptMode: ai.promptModes[0])
        ai.isEnabled = enabled
        return ai
    }

    private func persistedAI(_ harness: SettingsProjectionTestHarness) -> [AIEndpointSettings] {
        harness.sent.compactMap {
            if case .setAI(let settings, _) = $0 { return settings }
            return nil
        }
    }

    // MARK: Status line

    func testStatusLineSaysWhatADictationDoesAndMatchesHome() {
        let ai = seeded()
        let action = ai.activePromptMode!
        let on = AIActionsStatus(settings: ai, test: .idle)
        XCTAssertEqual(on.tone, .on)
        let named = "\(action.icon) \(action.menuTitle)"
        XCTAssertEqual(on.line, "On · " + AIActionsCopy.summary(action: named, configuration: "Local Ollama"))
        // Home's chip joins the same two names the same way.
        let home = HomeHeroState(
            readiness: .preview, interaction: .pushToTalk, modelName: "M", microphoneName: "Mic",
            ai: .on(action: action.menuTitle, configuration: "Local Ollama")
        )
        XCTAssertEqual(home.aiChipTitle, AIActionsCopy.summary(action: action.menuTitle, configuration: "Local Ollama"))

        XCTAssertTrue(AIActionsStatus(settings: ai, test: .succeeded).line.hasSuffix(" · tested OK"))
        XCTAssertTrue(AIActionsStatus(settings: ai, test: .failed("HTTP 404")).line.hasSuffix(" · test failed"))
        XCTAssertFalse(AIActionsStatus(settings: ai, test: .testing).line.contains("test"), "a test in flight claims nothing")
    }

    func testStatusLineWhenOffKeepsTheDefaultAndWhenBlockedSaysWhy() {
        let off = AIActionsStatus(settings: seeded(enabled: false), test: .succeeded)
        XCTAssertEqual(off.tone, .idle)
        XCTAssertTrue(off.line.hasPrefix(AIActionsCopy.aiOff + " · "))
        XCTAssertTrue(off.line.contains("default action kept"))
        XCTAssertFalse(off.line.contains("tested"), "off says nothing about a test")

        var noDefault = seeded(enabled: false)
        noDefault.activePromptModeID = nil
        XCTAssertFalse(AIActionsStatus(settings: noDefault, test: .idle).line.contains("default action kept"))

        let noEndpoint = AIActionsStatus(settings: seeded(endpoint: false), test: .idle)
        XCTAssertEqual(noEndpoint.tone, .attention)
        XCTAssertTrue(noEndpoint.line.contains("no configuration"))

        var awaiting = seeded()
        awaiting.activePromptModeID = nil
        let waiting = AIActionsStatus(settings: awaiting, test: .idle)
        XCTAssertEqual(waiting.tone, .attention)
        XCTAssertTrue(waiting.line.contains("no default action"))
    }

    func testStatusLineTakesTheConfigurationsModelsName() {
        let line = AIActionsStatus(settings: seeded(), configurationName: .some("Gemini"), test: .idle).line
        XCTAssertTrue(line.hasSuffix(" · Gemini"))
    }

    // MARK: Default strip

    func testFactsLineNamesBehaviourModeSettingsTriggersAndShortcut() {
        var polish = BuiltInPromptModes.all.first { $0.builtInKey == BuiltInPromptModes.Key.polish }!
        polish.options.formalWriting = true
        polish.triggerWords = ["polish"]
        XCTAssertEqual(
            AIActionFacts.line(for: polish, badge: "⌘2", triggersOn: true),
            "Edits the transcript · formal writing · trigger words: “polish” · ⌘2"
        )
        XCTAssertTrue(AIActionFacts.line(for: polish, badge: nil, triggersOn: false).contains("trigger words (off)"))

        var translate = BuiltInPromptModes.all.first { $0.behavior == .translate }!
        translate.translationLanguage = TranslationLanguage(bcp47: "fr", displayName: "French")
        translate.options.secondTranslationLanguage = TranslationLanguage(bcp47: "ja", displayName: "Japanese")
        translate.triggerWords = []
        XCTAssertEqual(AIActionFacts.line(for: translate, badge: nil, triggersOn: true), "Translates to French · also Japanese")
    }

    // MARK: Action detail draft

    func testTheDraftCarriesModeSettingsAndSaveWritesThemOnTheDefault() throws {
        var ai = seeded()
        let polish = try XCTUnwrap(ai.promptModes.first { $0.builtInKey == BuiltInPromptModes.Key.polish })
        ai.apply(promptMode: polish)
        let harness = SettingsProjectionTestHarness(settings: AppSettings(ai: ai))
        let model = PromptModeSettingsViewModel(host: harness.host)

        var draft = PromptModeDraft(mode: polish)
        XCTAssertEqual(draft.options, polish.options)
        XCTAssertEqual(draft.settingsFamily, .polish)
        draft.options.formalWriting = true
        XCTAssertTrue(harness.sent.isEmpty, "editing the draft writes nothing until Save")

        model.updateMode(id: polish.id, from: draft)
        let saved = try XCTUnwrap(persistedAI(harness).last)
        XCTAssertEqual(saved.promptModes.first { $0.id == polish.id }?.options.formalWriting, true)
        XCTAssertTrue(saved.promptConfiguration.polishPrompt.contains("FORMAL WRITING"), "the default's request copy is re-applied")
    }

    func testCancelLeavesSettingsAsTheyWere() {
        let harness = SettingsProjectionTestHarness(settings: AppSettings(ai: seeded()))
        let model = PromptModeSettingsViewModel(host: harness.host)
        var draft = PromptModeDraft(mode: model.modes[0])
        draft.name = "Changed"
        draft.options.formalWriting = true
        draft.triggerWords = ["x"]
        // Cancel drops the draft; nothing is committed.
        model.clearPreview()
        model.flushPendingChanges()
        XCTAssertTrue(harness.sent.isEmpty)
        XCTAssertEqual(model.modes[0].name, BuiltInPromptModes.all[0].name)
    }

    func testDraftFamilyFollowsTheBehaviourAndASecondLanguageNeedsBothFields() {
        var draft = PromptModeDraft(name: "Mine", prompt: "Do it.")
        XCTAssertEqual(draft.settingsFamily, PromptModeSettingsFamily.none)
        draft.behavior = .translate
        XCTAssertEqual(draft.settingsFamily, .translate)
        XCTAssertTrue(draft.isComplete)
        draft.options.secondTranslationLanguage = TranslationLanguage(bcp47: " ", displayName: "Japanese")
        XCTAssertFalse(draft.isComplete)
        draft.options.secondTranslationLanguage = TranslationLanguage(bcp47: " ja ", displayName: "Japanese ")
        XCTAssertTrue(draft.isComplete)

        var mode = PromptMode(name: "Mine", behavior: .translate, prompt: "Do it.")
        draft.write(into: &mode)
        XCTAssertEqual(mode.options.secondTranslationLanguage, TranslationLanguage(bcp47: "ja", displayName: "Japanese"))
    }

    func testANewActionFromATemplateDoesNotInheritTheShippedFamily() {
        let polish = BuiltInPromptModes.all.first { $0.builtInKey == BuiltInPromptModes.Key.polish }!
        XCTAssertEqual(PromptModeDraft(mode: polish).settingsFamily, .polish)
        XCTAssertEqual(PromptModeDraft(basedOn: polish, name: "Mine").settingsFamily, PromptModeSettingsFamily.none)
    }

    // MARK: Detail buttons

    func testDetailButtonsFollowTheSavedAction() {
        let new = AIActionDetailContext()
        XCTAssertTrue(new.isNew)
        XCTAssertFalse(new.canSetDefault || new.canReset || new.canDelete || new.canDuplicate(draft: PromptModeDraft()))

        var builtIn = BuiltInPromptModes.all[1]
        let shipped = AIActionDetailContext(saved: builtIn)
        XCTAssertTrue(shipped.canSetDefault)
        XCTAssertFalse(shipped.canReset, "an untouched built-in has nothing to reset")
        XCTAssertFalse(shipped.canDelete, "built-ins are never deleted")
        builtIn.prompt += " Edited."
        XCTAssertTrue(AIActionDetailContext(saved: builtIn).canReset)
        XCTAssertFalse(AIActionDetailContext(saved: builtIn, isDefault: true).canSetDefault)

        let user = PromptMode(name: "Mine", behavior: .polish, prompt: "Do it.")
        let context = AIActionDetailContext(saved: user)
        XCTAssertTrue(context.canDelete)
        var draft = PromptModeDraft(mode: user)
        XCTAssertTrue(context.canDuplicate(draft: draft))
        draft.summary = "unsaved"
        XCTAssertFalse(context.canDuplicate(draft: draft), "Duplicate waits for Save or Cancel")

        let incomplete = PromptMode(name: "Empty", behavior: .polish, prompt: "")
        XCTAssertFalse(AIActionDetailContext(saved: incomplete).canSetDefault)
    }

    // MARK: Page

    func testThePageAndTheDetailWriteNothingWhenShown() {
        let harness = SettingsProjectionTestHarness(settings: AppSettings(ai: seeded()))
        let actions = PromptModeSettingsViewModel(host: harness.host)
        let configurations = AISettingsViewModel(host: harness.host)
        _ = AIActionsForm(configurations: configurations, actions: actions).body
        _ = AIActionEditorView(
            viewModel: actions, draft: .constant(PromptModeDraft(mode: actions.modes[0])), isBuiltIn: true,
            context: AIActionDetailContext(saved: actions.modes[0], isDefault: true, shortcutBadge: "⌘1"),
            onSave: {}, onCancel: {}
        ).body
        XCTAssertTrue(harness.sent.isEmpty)
    }
}
