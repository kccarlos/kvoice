import Foundation
import XCTest
import KvoiceAppCore
@testable import KvoiceDomain
@testable import KvoiceUI

/// ADR-022 slice 7 part B: `AISettingsViewModel`'s nonsecret half is a
/// projection over `SettingsProjectionHost`. Tests that used to record an
/// `onChange` callback now build a `SettingsProjectionTestHarness` and read
/// `harness.sent` / `harness.settings` back; the debounce-specific tests
/// (typing coalesces after a pause) are replaced by their synchronous
/// equivalent — a draft committed by `flushPendingChanges()`.
@MainActor
final class AISettingsViewTests: XCTestCase {
    func testDefaultsAreOffAndDoNotInventAnEndpointOrCredential() {
        let model = AISettingsViewModel()

        XCTAssertEqual(model.mode, .off)
        XCTAssertNil(model.baseURL)
        XCTAssertTrue(model.modelID.isEmpty)
        XCTAssertTrue(model.apiKey.isEmpty)
        XCTAssertEqual(model.polishPrompt, DefaultPrompts.polish)
        XCTAssertNil(model.appSettings.ai.baseURL)
        XCTAssertNil(model.appSettings.ai.mode.aiMode)
    }

    func testPolishAndTranslateSettingsAreReflectedInNonsecretAppSettings() {
        let model = AISettingsViewModel()
        model.baseURLText = "https://provider.example/v1"
        model.modelID = "fixture-model"
        model.apiKey = "fixture-secret"
        model.mode = .polish
        model.polishPrompt = "Preserve Mandarin-English switching and TextEdit."

        XCTAssertEqual(model.appSettings.ai.mode, .polish)
        XCTAssertEqual(model.appSettings.ai.baseURL?.absoluteString, "https://provider.example/v1")
        XCTAssertEqual(model.appSettings.ai.modelID, "fixture-model")
        XCTAssertEqual(model.appSettings.ai.promptConfiguration.polishPrompt, "Preserve Mandarin-English switching and TextEdit.")
        let encoded = try! JSONEncoder().encode(model.appSettings)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("fixture-secret"))

        model.mode = .translate
        model.translationBCP47 = "zh-Hans"
        model.translationLanguageName = "Chinese, Simplified"
        XCTAssertEqual(model.appSettings.ai.mode, .translate)
        XCTAssertEqual(model.appSettings.ai.translationLanguage.bcp47, "zh-Hans")
        XCTAssertEqual(model.appSettings.ai.translationLanguage.displayName, "Chinese, Simplified")
    }

    func testSecretSnapshotIsSeparateAndEmptySecretsBecomeNil() {
        let model = AISettingsViewModel()

        XCTAssertNil(model.secretSettings.apiKey)
        model.apiKey = "fixture-secret"
        XCTAssertEqual(model.secretSettings.apiKey, "fixture-secret")
        model.apiKey = ""
        XCTAssertNil(model.secretSettings.apiKey)
    }

    func testConfigurationTestIsExplicitAndReportsOnlySafeStatus() async {
        var calls = 0
        var receivedCredential: AICredentialSnapshot?
        let model = AISettingsViewModel(
            configurationTester: { _, credentials in
                calls += 1
                receivedCredential = credentials
            }
        )
        model.mode = .polish
        model.baseURLText = "https://provider.example/v1"
        model.modelID = "fixture-model"
        model.apiKey = "fixture-secret"

        await model.testConfiguration()

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(receivedCredential?.apiKey, "fixture-secret")
        XCTAssertEqual(model.testState, .succeeded)
    }

    func testInvalidConfigurationDoesNotCallNetworkTester() async {
        var calls = 0
        let model = AISettingsViewModel(configurationTester: { _, _ in calls += 1 })

        await model.testConfiguration()

        XCTAssertEqual(calls, 0)
        guard case .failed(let message) = model.testState else {
            return XCTFail("expected a failure state")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testCredentialBearingBaseURLIsRejectedBeforeItIsPersisted() {
        let harness = SettingsProjectionTestHarness()
        let model = AISettingsViewModel(host: harness.host)
        model.mode = .polish
        model.modelID = "fixture-model"
        model.baseURLText = "https://provider.example/v1"
        model.flushPendingChanges()
        XCTAssertNil(model.baseURLValidationError)
        XCTAssertEqual(harness.settings.ai.baseURL?.absoluteString, "https://provider.example/v1")

        for rejected in [
            "https://user:fixture-secret@provider.example/v1",
            "https://provider.example/v1?api_key=fixture-secret",
            "https://provider.example/v1#fixture-secret"
        ] {
            model.baseURLText = rejected
            model.flushPendingChanges()
            XCTAssertNotNil(model.baseURLValidationError, rejected)
            XCTAssertNil(model.baseURL, rejected)
            XCTAssertNil(model.appSettings.ai.baseURL, rejected)
            XCTAssertFalse(model.canDiscoverModels, rejected)
            XCTAssertFalse(model.canTestConfiguration, rejected)
            // Nothing handed to the coordinator carries the secret.
            let encoded = String(decoding: try! JSONEncoder().encode(harness.settings), as: UTF8.self)
            XCTAssertFalse(encoded.contains("fixture-secret"), rejected)
            XCTAssertFalse(model.baseURLValidationError!.contains("fixture-secret"))
        }
    }

    func testNonLoopbackHTTPBaseURLIsRejectedAndLoopbackAccepted() {
        let harness = SettingsProjectionTestHarness()
        let model = AISettingsViewModel(host: harness.host)

        model.baseURLText = "http://provider.example/v1"
        model.flushPendingChanges()
        XCTAssertNotNil(model.baseURLValidationError)
        XCTAssertTrue(model.baseURLValidationError!.contains("HTTPS"))
        XCTAssertNil(model.appSettings.ai.baseURL)
        XCTAssertNil(harness.settings.ai.baseURL)

        for accepted in ["http://localhost:11434/v1", "http://127.0.0.1:8080", "http://[::1]:1234/v1"] {
            model.baseURLText = accepted
            XCTAssertNil(model.baseURLValidationError, accepted)
            XCTAssertEqual(model.appSettings.ai.baseURL?.absoluteString, accepted)
        }

        // Empty is not an error; it is simply no endpoint.
        model.baseURLText = "   "
        XCTAssertNil(model.baseURLValidationError)
        XCTAssertNil(model.baseURL)
    }

    func testRejectedBaseURLNeverBecomesOrOverwritesAConfiguration() {
        let model = AISettingsViewModel()
        var draft = AISettingsViewModel.Draft(kind: .custom)
        draft.name = "Leaky"
        draft.modelID = "fixture-model"
        draft.baseURLText = "https://user:fixture-secret@provider.example/v1"
        XCTAssertNotNil(draft.baseURLValidationError)
        XCTAssertFalse(draft.isComplete)
        XCTAssertNil(model.addConfiguration(draft))
        XCTAssertTrue(model.configurations.isEmpty)

        draft.baseURLText = "https://provider.example/v1"
        XCTAssertNil(draft.baseURLValidationError)
        let saved = try! XCTUnwrap(model.addConfiguration(draft))
        XCTAssertEqual(model.activeConfigurationID, saved.id)

        model.baseURLText = "http://provider.example/v1"
        model.updateActiveConfigurationFromFields()
        XCTAssertEqual(
            model.configurations.first?.baseURL?.absoluteString,
            "https://provider.example/v1"
        )
    }

    func testViewCanBeConstructedForSettingsScene() {
        let view = AISettingsView(viewModel: AISettingsViewModel())
        XCTAssertNotNil(view)
    }

    // MARK: Prompt modes survive AI-tab edits

    /// `aiSettings` used to build a fresh `AIEndpointSettings`, so any edit in
    /// the AI tab persisted settings with `promptModes` empty, the active mode
    /// forgotten, and the translate prompt reset.
    func testEditingTheAITabKeepsPromptModesActiveModeAndTranslatePrompt() {
        var settings = AppSettings()
        settings.ai.seedBuiltInPromptModesIfNeeded()
        let mine = PromptMode(name: "Mine", behavior: .translate, prompt: "Translate it.", translationLanguage: .init(bcp47: "pl", displayName: "Polish"))
        settings.ai.promptModes.append(mine)
        settings.ai.apply(promptMode: mine)
        XCTAssertEqual(settings.ai.promptConfiguration.translatePrompt, "Translate it.")

        let harness = SettingsProjectionTestHarness(settings: settings)
        let model = AISettingsViewModel(host: harness.host)

        model.baseURLText = "https://provider.example/v1"
        model.modelID = "gemma"
        model.isEnabled = true

        let last = harness.settings
        XCTAssertEqual(last.ai.promptModes, settings.ai.promptModes)
        XCTAssertEqual(last.ai.activePromptModeID, mine.id)
        XCTAssertEqual(last.ai.promptConfiguration.translatePrompt, "Translate it.")
        XCTAssertEqual(last.ai.translationLanguage.bcp47, "pl")
        XCTAssertEqual(last.ai.modelID, "gemma")
        XCTAssertTrue(last.ai.isEnabled)
        // The default action decides the request shape, not the AI tab.
        XCTAssertEqual(last.ai.mode, .translate)
    }

    // MARK: Drafts, committed by flushPendingChanges()

    /// No more debounce `Task`: several keystrokes are all draft-only until
    /// `flushPendingChanges()`, which sends exactly one `.setAI`.
    func testTypingCommitsOnceOnFlushNotPerKeystroke() {
        let harness = SettingsProjectionTestHarness()
        let model = AISettingsViewModel(host: harness.host)

        for text in ["h", "ht", "https://provider.example/v1"] {
            model.baseURLText = text
        }
        XCTAssertTrue(model.hasPendingChanges)
        XCTAssertTrue(harness.sent.isEmpty, "nothing is sent while typing continues")

        model.flushPendingChanges()

        XCTAssertFalse(model.hasPendingChanges)
        XCTAssertEqual(harness.sent.count, 1)
        XCTAssertEqual(harness.settings.ai.baseURL?.absoluteString, "https://provider.example/v1")
    }

    func testFlushDeliversATypedChangeAtOnceAndOnlyOnce() {
        let harness = SettingsProjectionTestHarness()
        let model = AISettingsViewModel(host: harness.host)

        model.modelID = "fixture-model"
        XCTAssertTrue(harness.sent.isEmpty)

        model.flushPendingChanges()
        XCTAssertEqual(harness.sent.count, 1)
        XCTAssertEqual(harness.settings.ai.modelID, "fixture-model")
        XCTAssertFalse(model.hasPendingChanges)

        model.flushPendingChanges()
        XCTAssertEqual(harness.sent.count, 1, "a flush with nothing pending sends nothing")
    }

    func testAPickerChangeWritesImmediatelyAndFoldsInPendingText() {
        let harness = SettingsProjectionTestHarness()
        let model = AISettingsViewModel(host: harness.host)

        model.modelID = "fixture-model"
        model.isEnabled = true

        XCTAssertEqual(harness.sent.count, 1)
        XCTAssertEqual(harness.settings.ai.isEnabled, true)
        XCTAssertEqual(harness.settings.ai.modelID, "fixture-model")
        XCTAssertFalse(model.hasPendingChanges, "the immediate write folded in the pending text")
    }

    /// The key never reaches `.setSecrets` until a flush, and only the value
    /// the user settled on is sent — never a partially-typed key.
    func testAPartiallyTypedAPIKeyNeverReachesTheSecretStoreUntilFlush() {
        let harness = SettingsProjectionTestHarness()
        let model = AISettingsViewModel(host: harness.host)

        for prefix in ["f", "fi", "fix", "fixture-secret"] {
            model.apiKey = prefix
        }
        XCTAssertTrue(harness.sent.isEmpty)

        model.flushPendingChanges()

        let secrets = harness.sent.compactMap { intent -> SecretSettings? in
            if case .setSecrets(let secrets, _) = intent { return secrets }
            return nil
        }
        XCTAssertEqual(secrets.map(\.apiKey), ["fixture-secret"])
    }

    /// A change from another door (the status menu's Configuration pick, an
    /// Import) is not silently overwritten by a stale draft: `discardStaleDrafts()`
    /// (checked before `flushPendingChanges()`, `hasPendingChanges`, and
    /// every read of `aiSettings`) re-seeds the draft from the fresh stored
    /// value rather than blending the old one over it, so the foreign write
    /// survives the next flush untouched and nothing is sent.
    func testAChangeFromAnotherDoorSurvivesTheNextFlushUntouched() {
        let harness = SettingsProjectionTestHarness()
        let model = AISettingsViewModel(host: harness.host)

        model.modelID = "typed-before-reload"
        harness.commitFromElsewhere(.setAI(AIEndpointSettings(modelID: "loaded"), origin: .statusMenu))

        model.flushPendingChanges()

        XCTAssertEqual(model.modelID, "loaded")
        XCTAssertEqual(harness.settings.ai.modelID, "loaded")
        XCTAssertFalse(model.hasPendingChanges)
        XCTAssertTrue(
            harness.sent.compactMap { if case .setAI = $0 { return true }; return nil }.isEmpty,
            "the re-seeded draft already matches the stored value, so flush sends nothing"
        )
    }

    /// Reproduces the real launch sequence (`AppDelegate.init` builds this
    /// model before `AppDelegate+Settings.loadSettingsAndRegisterShortcut`
    /// runs the coordinator's real load): the drafts seed from
    /// `AppSettings()`'s empty defaults, and only `discardStaleDrafts()` —
    /// called explicitly right after the load, as the shell does — catches
    /// them up before the first commit could otherwise blend the empty
    /// defaults over what just loaded.
    func testDraftsSeededOnDefaultsCatchUpAfterTheRealLoadAndFlushSendsNothing() {
        let harness = SettingsProjectionTestHarness()
        let model = AISettingsViewModel(host: harness.host)
        XCTAssertEqual(model.modelID, "")
        XCTAssertNil(model.baseURL)

        var real = AppSettings()
        real.ai.baseURL = URL(string: "https://provider.example/v1")
        real.ai.modelID = "loaded"
        harness.coordinator.load(real)
        model.discardStaleDrafts()

        XCTAssertEqual(model.modelID, "loaded")
        XCTAssertEqual(model.baseURL?.absoluteString, "https://provider.example/v1")

        model.flushPendingChanges()
        XCTAssertTrue(
            harness.sent.compactMap { if case .setAI = $0 { return true }; return nil }.isEmpty,
            "the re-seeded draft already matches the loaded value, so flush sends nothing"
        )
    }

    // MARK: Unsaved edits to the selected configuration

    func testSaveEditsIsOnlyOfferedWhenTheFieldsDifferFromTheSelection() {
        let model = AISettingsViewModel()
        XCTAssertFalse(model.activeConfigurationHasUnsavedEdits, "No selection, nothing to save")

        var draft = AISettingsViewModel.Draft(kind: .custom)
        draft.name = "Local"
        draft.baseURLText = "http://localhost:8080/v1"
        draft.modelID = "fixture-model"
        draft.apiKey = "fixture-secret"
        _ = model.addConfiguration(draft)
        XCTAssertFalse(model.activeConfigurationHasUnsavedEdits, "Freshly selected fields match the configuration")

        model.modelID = "another-model"
        XCTAssertTrue(model.activeConfigurationHasUnsavedEdits)
        model.updateActiveConfigurationFromFields()
        XCTAssertFalse(model.activeConfigurationHasUnsavedEdits)

        model.apiKey = ""
        XCTAssertTrue(model.activeConfigurationHasUnsavedEdits, "Clearing the key is an edit too")
    }
}
