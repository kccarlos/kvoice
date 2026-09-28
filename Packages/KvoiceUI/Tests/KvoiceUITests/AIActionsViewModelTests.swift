import XCTest
import KvoiceAppCore
import KvoiceDomain
@testable import KvoiceUI

/// The view-model states behind the AI Actions section: the master switch,
/// ⌘1–⌘0 selection, mode settings, triggers, the profile, and the
/// configuration sheet's Verify & Save. ADR-022 slice 7 part B: both view
/// models are projections, so `makeActions` builds a `SettingsProjectionTestHarness`
/// and `persisted` reads back what the model committed, in place of the old
/// `onChange` callback.
@MainActor
final class AIActionsViewModelTests: XCTestCase {
    private func makeActions(endpoint: Bool = true) -> (model: PromptModeSettingsViewModel, harness: SettingsProjectionTestHarness) {
        var ai = AIEndpointSettings(
            baseURL: endpoint ? URL(string: "http://localhost:11434/v1") : nil,
            modelID: endpoint ? "gemma4:latest" : ""
        )
        ai.seedBuiltInPromptModesIfNeeded()
        let harness = SettingsProjectionTestHarness(settings: AppSettings(ai: ai))
        return (PromptModeSettingsViewModel(host: harness.host), harness)
    }

    /// Every `.setAI` this harness committed, newest last — the drop-in
    /// replacement for the old `onChange` recorder.
    private func persistedAI(_ harness: SettingsProjectionTestHarness) -> [AIEndpointSettings] {
        harness.sent.compactMap {
            if case .setAI(let settings, _) = $0 { return settings }
            return nil
        }
    }

    // MARK: Master switch

    func testTheSwitchPersistsIndependentlyOfTheDefaultAction() {
        let (model, harness) = makeActions()
        XCTAssertFalse(model.isEnabled)
        XCTAssertFalse(model.isProcessingEnabled)

        model.isEnabled = true
        XCTAssertEqual(persistedAI(harness).last?.isEnabled, true)
        XCTAssertTrue(model.isProcessingEnabled, "an endpoint and the switch are enough: polish is the default shape")

        model.selectMode(id: model.modes[3].id)
        XCTAssertTrue(model.isEnabled, "choosing an action never flips the switch")
        XCTAssertEqual(persistedAI(harness).last?.activePromptModeID, model.modes[3].id)

        model.disableProcessing()
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.activeModeID, model.modes[3].id, "the default action is remembered")
        XCTAssertEqual(persistedAI(harness).last?.isEnabled, false)

        model.isEnabled = false
        XCTAssertEqual(persistedAI(harness).count, 3, "an unchanged value writes nothing")
    }

    func testTheSwitchCanBeOnWithoutAnEndpointAndNothingRuns() {
        let (model, _) = makeActions(endpoint: false)
        model.isEnabled = true
        XCTAssertTrue(model.isEnabled)
        XCTAssertFalse(model.canEnableProcessing, "the section shows the add-a-configuration call-out")
        XCTAssertFalse(model.isProcessingEnabled)
        XCTAssertEqual(model.settings.mode, .off)
        XCTAssertNoThrow(try JSONDecoder().decode(AIEndpointSettings.self, from: try JSONEncoder().encode(model.settings)))
    }

    // MARK: ⌘1–⌘0

    func testShortcutNumbersSelectBySavedOrderWithZeroAsTenth() {
        let (model, _) = makeActions()
        XCTAssertEqual(model.selectDefaultAction(shortcutNumber: 1)?.id, model.modes[0].id)
        XCTAssertEqual(model.activeModeID, model.modes[0].id)
        XCTAssertEqual(model.selectDefaultAction(shortcutNumber: 9)?.id, model.modes[8].id)
        XCTAssertEqual(model.selectDefaultAction(shortcutNumber: 0)?.id, model.modes[9].id)
        XCTAssertNil(model.selectDefaultAction(shortcutNumber: 11))
        XCTAssertEqual(model.activeModeID, model.modes[9].id, "an empty slot changes nothing")

        XCTAssertEqual(model.shortcutBadge(for: model.modes[0].id), "⌘1")
        XCTAssertEqual(model.shortcutBadge(for: model.modes[9].id), "⌘0")
        XCTAssertNil(model.shortcutBadge(for: model.modes[10].id), "only ten actions get a badge")
    }

    // MARK: Mode settings and editing

    func testUpdatingOptionsOnTheDefaultActionReappliesThePrompt() {
        let (model, harness) = makeActions()
        let polish = model.modes.first { $0.builtInKey == BuiltInPromptModes.Key.polish }!
        model.selectMode(id: polish.id)

        var options = polish.options
        options.formalWriting = true
        model.updateOptions(id: polish.id, options)

        XCTAssertTrue(persistedAI(harness).last?.promptConfiguration.polishPrompt.contains("FORMAL WRITING") ?? false)
        XCTAssertEqual(persistedAI(harness).last?.promptModes.first { $0.id == polish.id }?.options.formalWriting, true)

        let before = persistedAI(harness).count
        model.updateOptions(id: polish.id, options)
        XCTAssertEqual(persistedAI(harness).count, before, "an unchanged option writes nothing")
    }

    func testEditingWritesTheActionFieldsAndNormalizesThem() {
        let (model, _) = makeActions()
        var draft = PromptModeDraft(mode: model.modes[0])
        draft.summary = "  Short and sweet  "
        draft.icon = "🎯🎯"
        draft.triggerWords = ["Go", "go", " ", "Run"]
        draft.includesClipboardText = true
        draft.usesSystemInstructionsTemplate = true

        model.updateMode(id: model.modes[0].id, from: draft)

        let edited = model.modes[0]
        XCTAssertEqual(edited.summary, "Short and sweet")
        XCTAssertEqual(edited.icon, "🎯")
        XCTAssertEqual(edited.triggerWords, ["Go", "Run"])
        XCTAssertTrue(edited.includesClipboardText)
        XCTAssertTrue(edited.usesSystemInstructionsTemplate)
        XCTAssertTrue(edited.isRevisedBuiltIn)
        XCTAssertTrue(edited.isBuiltIn, "an edited built-in keeps its key")
    }

    func testANewDraftUsesTheTemplateAndATemplateBasedDraftKeepsItsSource() {
        XCTAssertTrue(PromptModeDraft().usesSystemInstructionsTemplate)
        let terminal = BuiltInPromptModes.shipped(forKey: BuiltInPromptModes.Key.terminal)!
        let draft = PromptModeDraft(basedOn: terminal, name: "Mine")
        XCTAssertFalse(draft.usesSystemInstructionsTemplate, "a shipped prompt is complete already")
        XCTAssertEqual(draft.prompt, terminal.prompt)
        XCTAssertEqual(draft.icon, terminal.icon)
        XCTAssertTrue(draft.triggerWords.isEmpty)
        XCTAssertEqual(draft.effectiveSystemPrompt, terminal.prompt)
    }

    // MARK: Triggers, slots, profile

    func testTriggersAndSlotsPersistThroughTheActionsSnapshot() {
        let (model, harness) = makeActions()

        model.actionTriggersEnabled = true
        XCTAssertEqual(persistedAI(harness).last?.actionTriggersEnabled, true)

        model.bindSelectionAction(model.modes[2].id, slot: 1)
        XCTAssertEqual(persistedAI(harness).last?.selectionActionSlots[1], model.modes[2].id)
        XCTAssertEqual(model.selectionAction(slot: 1)?.id, model.modes[2].id)

        let before = persistedAI(harness).count
        model.bindSelectionAction(model.modes[2].id, slot: 1)
        model.bindSelectionAction(model.modes[2].id, slot: 9)
        XCTAssertEqual(persistedAI(harness).count, before, "unchanged or out-of-range bindings write nothing")
    }

    /// ADR-022 slice 7 part B: `userProfile` is a draft committed by
    /// `flushPendingChanges()` — no more debounce `Task`, so this now
    /// verifies the clamp and the commit-on-flush contract synchronously.
    func testUserProfileIsCappedAndCommittedOnFlush() {
        var ai = AIEndpointSettings()
        ai.seedBuiltInPromptModesIfNeeded()
        let harness = SettingsProjectionTestHarness(settings: AppSettings(ai: ai))
        let model = PromptModeSettingsViewModel(host: harness.host)

        model.userProfile = "Role: eng"
        XCTAssertTrue(model.hasPendingChanges)
        XCTAssertTrue(persistedAI(harness).isEmpty)
        model.flushPendingChanges()
        XCTAssertEqual(persistedAI(harness).last?.userProfile, "Role: eng")
        XCTAssertFalse(model.hasPendingChanges)

        model.userProfile = String(repeating: "x", count: AIEndpointSettings.userProfileMaximumCharacters + 50)
        XCTAssertEqual(model.userProfile.count, AIEndpointSettings.userProfileMaximumCharacters)
        model.flushPendingChanges()
        XCTAssertEqual(persistedAI(harness).last?.userProfile.count, AIEndpointSettings.userProfileMaximumCharacters)
        XCTAssertFalse(model.hasPendingChanges)

        // A change from another door replaces the draft entirely:
        // `discardStaleDrafts()` (checked before `flushPendingChanges()`,
        // `hasPendingChanges`, and every read of `settings`) re-seeds
        // `userProfile` from the fresh stored value rather than blending the
        // old draft over it, so the foreign write survives the next flush
        // untouched and nothing is sent.
        let before = persistedAI(harness).count
        harness.commitFromElsewhere(.setAI(AIEndpointSettings(userProfile: "From elsewhere"), origin: .statusMenu))
        model.flushPendingChanges()
        XCTAssertEqual(model.userProfile, "From elsewhere")
        XCTAssertFalse(model.hasPendingChanges)
        XCTAssertEqual(persistedAI(harness).count, before, "the re-seeded draft already matches the stored value, so flush sends nothing")
    }

    /// Reproduces the real launch sequence (`AppDelegate.init` builds this
    /// model before `AppDelegate+Settings.loadSettingsAndRegisterShortcut`
    /// runs the coordinator's real load): the draft seeds from
    /// `AppSettings()`'s empty default, and only `discardStaleDrafts()` —
    /// called explicitly right after the load, as the shell does — catches
    /// it up before the first commit could otherwise blend the empty
    /// default over what just loaded.
    func testDraftSeededOnTheDefaultCatchesUpAfterTheRealLoadAndFlushSendsNothing() {
        let harness = SettingsProjectionTestHarness()
        let model = PromptModeSettingsViewModel(host: harness.host)
        XCTAssertEqual(model.userProfile, "")

        var real = AppSettings()
        real.ai.userProfile = "Role: eng"
        harness.coordinator.load(real)
        model.discardStaleDrafts()
        XCTAssertEqual(model.userProfile, "Role: eng")

        model.flushPendingChanges()
        XCTAssertTrue(persistedAI(harness).isEmpty, "the re-seeded draft already matches the loaded value, so flush sends nothing")
    }

    // MARK: Configuration sheet

    func testVerifyAndSaveStoresOnlyAVerifiedDraft() async {
        var tested: [AIEndpointSettings] = []
        var shouldFail = true
        let model = AISettingsViewModel(
            configurationTester: { settings, _ in
                tested.append(settings)
                if shouldFail { throw KVoiceError(code: .aiHTTPError, metadata: .init(httpStatus: 404)) }
            }
        )
        var draft = AISettingsViewModel.Draft(kind: .groq)
        draft.apiKey = "fixture-secret"

        let failed = await model.verifyAndSave(draft)
        XCTAssertNil(failed)
        XCTAssertTrue(model.configurations.isEmpty, "nothing is saved on a failed test")
        XCTAssertEqual(model.verificationState, .failed("The endpoint returned an error (HTTP 404). Check the model name and URL path."))
        XCTAssertEqual(tested.last?.baseURL?.absoluteString, "https://api.groq.com/openai/v1")
        XCTAssertEqual(tested.last?.modelID, AIProviderKind.groq.suggestedModelID)

        shouldFail = false
        let saved = await model.verifyAndSave(draft)
        XCTAssertEqual(saved?.kind, .groq)
        XCTAssertEqual(model.configurations.count, 1)
        XCTAssertEqual(model.activeConfigurationID, saved?.id, "the verified configuration becomes active")
        XCTAssertEqual(model.verificationState, .succeeded)
        XCTAssertEqual(model.secretSettings.apiKey(for: saved!.id), "fixture-secret")

        // Editing through the sheet updates in place.
        var edit = AISettingsViewModel.Draft(configuration: saved!, apiKey: model.apiKey(for: saved!.id))
        edit.name = "Fast"
        edit.modelID = "llama-3.1-8b-instant"
        let updated = await model.verifyAndSave(edit, replacing: saved!.id)
        XCTAssertEqual(updated?.id, saved?.id)
        XCTAssertEqual(model.configurations.count, 1)
        XCTAssertEqual(model.configurations[0].name, "Fast")
        XCTAssertEqual(model.modelID, "llama-3.1-8b-instant", "the live endpoint follows the active configuration")
    }

    func testAzureDraftDerivesTheEndpointAndProfile() async {
        var tested: [AIEndpointSettings] = []
        let model = AISettingsViewModel(configurationTester: { settings, _ in tested.append(settings) })
        var draft = AISettingsViewModel.Draft(kind: .azureOpenAI)
        XCTAssertFalse(draft.isComplete)
        XCTAssertNil(draft.baseURLValidationError, "no complaint before anything is typed")

        draft.azureResource = "my-resource"
        draft.azureDeployment = "gpt-4o-mini"
        draft.apiKey = "k"
        XCTAssertTrue(draft.isComplete)
        XCTAssertEqual(draft.resolvedModelID, "gpt-4o-mini", "the deployment doubles as the model id")
        XCTAssertEqual(draft.requestProfile.authStyle, .apiKeyHeader)

        let saved = await model.verifyAndSave(draft)
        XCTAssertEqual(saved?.baseURL?.absoluteString, "https://my-resource.openai.azure.com/openai/deployments/gpt-4o-mini")
        XCTAssertEqual(saved?.requestProfile.apiVersion, AIProviderKind.azureDefaultAPIVersion)
        XCTAssertEqual(tested.last?.requestProfile.authStyle, .apiKeyHeader)
        XCTAssertEqual(model.aiSettings.requestProfile.authStyle, .apiKeyHeader, "the live request profile follows")

        let reopened = AISettingsViewModel.Draft(configuration: saved!, apiKey: "k")
        XCTAssertEqual(reopened.azureResource, "my-resource")
        XCTAssertEqual(reopened.azureDeployment, "gpt-4o-mini")

        draft.azureResource = "bad host"
        XCTAssertNotNil(draft.baseURLValidationError)
    }

    func testTestConfigurationReportsTheFailureClassWithoutDetail() async {
        let model = AISettingsViewModel(
            configurationTester: { _, _ in throw KVoiceError(code: .aiAuthentication, metadata: .init(httpStatus: 401)) }
        )
        model.baseURLText = "https://provider.example/v1"
        model.modelID = "m"
        model.apiKey = "fixture-secret"

        await model.testConfiguration()

        guard case .failed(let message) = model.testState else { return XCTFail("expected a failure") }
        XCTAssertEqual(message, "Authentication failed (HTTP 401). Check the API key.")
        XCTAssertFalse(message.contains("provider.example"))
        XCTAssertFalse(message.contains("fixture-secret"))
    }

    func testFailureDescriptionsCoverEveryClass() {
        func describe(_ code: KVoiceErrorCode, status: Int? = nil) -> String {
            AISettingsViewModel.failureDescription(for: KVoiceError(code: code, metadata: .init(httpStatus: status)))
        }
        XCTAssertTrue(describe(.aiTimeout).contains("Timed out"))
        XCTAssertTrue(describe(.aiUnreachable).contains("could not be reached"))
        XCTAssertTrue(describe(.aiRateLimited, status: 429).contains("HTTP 429"))
        XCTAssertTrue(describe(.aiMalformedResponse).contains("not with the expected reply"))
        XCTAssertTrue(describe(.aiInsecureRemoteURL).contains("URL"))
        XCTAssertEqual(AISettingsViewModel.failureDescription(for: URLError(.badServerResponse)), "The request failed.")
    }

    func testTestConfigurationNoLongerNeedsTheSwitch() {
        let model = AISettingsViewModel()
        model.baseURLText = "https://provider.example/v1"
        model.modelID = "m"
        XCTAssertFalse(model.isEnabled)
        XCTAssertTrue(model.canTestConfiguration)
    }

    // MARK: Prompt regression for the new built-ins

    func testEveryShippedActionHasIconSummaryAndHouseStyle() {
        let all = BuiltInPromptModes.all
        XCTAssertEqual(all.count, 13)
        for action in all {
            XCTAssertFalse(action.icon.isEmpty, "\(action.name) has an icon")
            XCTAssertEqual(action.icon.count, 1, "\(action.name)'s icon is one grapheme")
            XCTAssertFalse(action.summary.isEmpty, "\(action.name) has a description")
            XCTAssertFalse(action.usesSystemInstructionsTemplate, "\(action.name) ships a complete prompt")
            XCTAssertTrue(action.prompt.hasPrefix("<SYSTEM_INSTRUCTIONS>"), "\(action.name) opens with the house block")
            XCTAssertTrue(action.prompt.contains("# OUTPUT"), "\(action.name) states its output")
            XCTAssertEqual(action.effectiveSystemPrompt, action.prompt, "no options: the prompt is sent as shipped")
        }
        let keys = Set(all.compactMap(\.builtInKey))
        typealias Key = BuiltInPromptModes.Key
        for key in [Key.terminal, Key.questionAnswer, Key.summarize, Key.todo, Key.writing, Key.emailDraft, Key.translate2] {
            XCTAssertTrue(keys.contains(key), "\(key) ships")
        }
    }

    func testTerminalPromptNeverExecutesAndHasAFailsafe() {
        let terminal = BuiltInPromptModes.shipped(forKey: BuiltInPromptModes.Key.terminal)!
        XCTAssertTrue(terminal.prompt.contains("Never execute anything"))
        XCTAssertTrue(terminal.prompt.contains("# unable to produce a command"))
        XCTAssertTrue(terminal.prompt.lowercased().contains("destructive"))
    }

    func testAddendaAndTemplateResourcesLoad() {
        for addendum in PromptTemplate.Addendum.allCases {
            XCTAssertTrue(PromptTemplate.addendum(addendum).hasPrefix("# ADDITIONAL RULES"), addendum.rawValue)
        }
        XCTAssertTrue(PromptTemplate.systemInstructionsTemplate.contains("{instructions}"))
        XCTAssertTrue(PromptTemplate.systemInstructionsTemplate.contains("<USER_PROFILE>"))
    }
}
