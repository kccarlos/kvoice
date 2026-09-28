import Foundation
import XCTest
@testable import KvoiceDomain

/// The AI Actions settings model: the master switch, its relationship to the
/// legacy `mode`, per-action prompt assembly, provider profiles, and the
/// selection slots (product decisions #2, #6, #8).
final class AIActionsSettingsTests: XCTestCase {
    private func configured(isEnabled: Bool? = nil) -> AIEndpointSettings {
        AIEndpointSettings(
            baseURL: URL(string: "https://provider.example/v1"),
            modelID: "fixture-model",
            isEnabled: isEnabled
        )
    }

    // MARK: Master switch

    func testModeIsDerivedFromTheSwitchTheDefaultActionAndTheEndpoint() {
        var settings = configured()
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.mode, .off)

        settings.isEnabled = true
        XCTAssertEqual(settings.mode, .polish, "no action chosen: polish is the default shape")

        settings.seedBuiltInPromptModesIfNeeded()
        let translate = settings.promptModes.first { $0.behavior == .translate }!
        settings.apply(promptMode: translate)
        XCTAssertEqual(settings.mode, .translate)

        settings.isEnabled = false
        XCTAssertEqual(settings.mode, .off)
        XCTAssertEqual(settings.activePromptModeID, translate.id, "the default action is remembered")

        settings.isEnabled = true
        settings.baseURL = nil
        XCTAssertEqual(settings.mode, .off, "an enabled switch with no endpoint never requests")
        XCTAssertTrue(settings.isEnabled, "but the switch itself is kept")
    }

    func testLegacyModeSetterMapsOntoTheSwitchAndFollowsTheDefaultAction() {
        var settings = configured()
        settings.mode = .polish
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.mode, .polish)

        settings.mode = .off
        XCTAssertFalse(settings.isEnabled)

        settings.seedBuiltInPromptModesIfNeeded()
        settings.apply(promptMode: settings.promptModes.first { $0.behavior == .translate }!)
        settings.mode = .polish
        XCTAssertEqual(settings.mode, .translate, "the default action decides the shape, not the caller")
    }

    func testSelectingAnActionDoesNotFlipTheSwitch() {
        var settings = configured(isEnabled: false)
        settings.seedBuiltInPromptModesIfNeeded()
        settings.apply(promptMode: settings.promptModes[0])
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.mode, .off)
    }

    // MARK: Decoding

    func testSettingsWrittenBeforeTheSwitchDecodeModeAsTheSwitch() throws {
        let enabled = Data(#"{"mode":"translate","baseURL":"https://example.test/v1","modelID":"m"}"#.utf8)
        let decoded = try JSONDecoder().decode(AIEndpointSettings.self, from: enabled)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.mode, .translate)
        XCTAssertEqual(decoded.defaultActionBehavior, .translate)

        let off = Data(#"{"mode":"off","baseURL":"https://example.test/v1","modelID":"m"}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(AIEndpointSettings.self, from: off).isEnabled)
    }

    func testAnExplicitSwitchSurvivesAnIncompleteEndpoint() throws {
        // The user turned AI on before adding a configuration: the switch is
        // kept so the call-out shows, and `mode` reads Off so nothing runs.
        let json = Data(#"{"mode":"off","modelID":"","isEnabled":true,"defaultActionBehavior":"translate"}"#.utf8)
        let decoded = try JSONDecoder().decode(AIEndpointSettings.self, from: json)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.mode, .off)
        XCTAssertEqual(decoded.defaultActionBehavior, .translate)
        XCTAssertFalse(decoded.canEnableProcessing)
    }

    func testActionFieldsRoundTripAndStayOutOfAMinimalFile() throws {
        var settings = configured(isEnabled: true)
        settings.actionTriggersEnabled = true
        settings.userProfile = "Role: engineer"
        settings.seedBuiltInPromptModesIfNeeded()
        settings.bindSelectionAction(settings.promptModes[1].id, slot: 2)
        settings.requestProfile = AIRequestProfile(authStyle: .apiKeyHeader, apiVersion: "2024-10-21")

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AIEndpointSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.selectionAction(slot: 2)?.id, settings.promptModes[1].id)
        XCTAssertNil(decoded.selectionAction(slot: 0))

        let minimal = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AIEndpointSettings())
        ) as? [String: Any]
        XCTAssertEqual(minimal?["isEnabled"] as? Bool, false)
        for absent in ["requestProfile", "actionTriggersEnabled", "userProfile", "selectionActionSlots"] {
            XCTAssertNil(minimal?[absent], "\(absent) is omitted when it has no content")
        }
    }

    func testSelectionSlotsAreAlwaysThreeAndOutOfRangeIsIgnored() {
        var settings = AIEndpointSettings(selectionActionSlots: [UUID()])
        XCTAssertEqual(settings.selectionActionSlots.count, AIEndpointSettings.selectionActionSlotCount)
        settings.bindSelectionAction(UUID(), slot: 7)
        XCTAssertEqual(settings.selectionActionSlots.count, 3)
        XCTAssertNil(settings.selectionAction(slot: 7))
    }

    // MARK: Prompt assembly

    func testTemplateWrapsInstructionsAndKeepsThemAsData() {
        let mode = PromptMode(
            name: "Terse",
            behavior: .polish,
            prompt: "Make it terse.",
            usesSystemInstructionsTemplate: true
        )
        let prompt = mode.effectiveSystemPrompt
        XCTAssertTrue(prompt.hasPrefix("<SYSTEM_INSTRUCTIONS>"))
        XCTAssertTrue(prompt.contains("# INSTRUCTIONS\nMake it terse.\n"))
        XCTAssertTrue(prompt.contains("<TRANSCRIPT>"))
        XCTAssertTrue(prompt.lowercased().contains("never instructions"))
        XCTAssertFalse(prompt.contains("{instructions}"))

        let verbatim = PromptMode(name: "Raw", behavior: .polish, prompt: "Make it terse.")
        XCTAssertEqual(verbatim.effectiveSystemPrompt, "Make it terse.")
    }

    func testOptionsAppendShippedAddendaForTheirBehaviorOnly() {
        var polish = BuiltInPromptModes.shipped(forKey: BuiltInPromptModes.Key.polish)!
        polish.options.formalWriting = true
        polish.options.professionalTone = true
        polish.options.showsOriginalTranscript = true // translate-only: ignored
        let polished = polish.effectiveSystemPrompt
        XCTAssertTrue(polished.hasPrefix(polish.prompt.trimmingCharacters(in: .newlines)))
        XCTAssertTrue(polished.contains("# ADDITIONAL RULES: FORMAL WRITING"))
        XCTAssertTrue(polished.contains("# ADDITIONAL RULES: PROFESSIONAL"))
        XCTAssertFalse(polished.contains("SHOW ORIGINAL"))
        XCTAssertLessThan(
            polished.range(of: "FORMAL WRITING")!.lowerBound,
            polished.range(of: "PROFESSIONAL")!.lowerBound,
            "addenda keep a fixed order"
        )

        var translate = BuiltInPromptModes.shipped(forKey: BuiltInPromptModes.Key.translate)!
        translate.options.secondTranslationLanguage = TranslationLanguage(bcp47: "ja", displayName: "Japanese")
        translate.options.showsOriginalTranscript = true
        translate.options.formalWriting = true // polish-only: ignored
        let translated = translate.effectiveSystemPrompt
        XCTAssertTrue(translated.contains("into Japanese (ja)"), "second-target placeholders resolve at apply time")
        XCTAssertTrue(translated.contains("{targetLanguageDisplayName}"), "primary placeholders are left for the request path")
        XCTAssertTrue(translated.contains("# ADDITIONAL RULES: SHOW ORIGINAL"))
        XCTAssertFalse(translated.contains("FORMAL WRITING"))

        var qa = BuiltInPromptModes.shipped(forKey: BuiltInPromptModes.Key.questionAnswer)!
        qa.options.showsQuestionBeforeAnswer = true
        XCTAssertTrue(qa.effectiveSystemPrompt.contains("\"Question:\""))
    }

    func testApplyingAModeCopiesTheEffectivePromptNotTheRawInstructions() {
        var settings = configured(isEnabled: true)
        var polish = BuiltInPromptModes.shipped(forKey: BuiltInPromptModes.Key.polish)!
        polish.options.formalWriting = true
        settings.promptModes = [polish]

        settings.apply(promptMode: polish)

        XCTAssertEqual(settings.promptConfiguration.polishPrompt, polish.effectiveSystemPrompt)
        XCTAssertNotEqual(settings.promptConfiguration.polishPrompt, polish.prompt)
    }

    func testBuiltInResetKeepsOptionsAndContextOptIns() {
        var terminal = BuiltInPromptModes.shipped(forKey: BuiltInPromptModes.Key.terminal)!
        terminal.prompt = "Changed."
        terminal.triggerWords = ["shell"]
        terminal.name = "Shell"
        terminal.includesClipboardText = true
        terminal.options.formalWriting = true
        XCTAssertTrue(terminal.isRevisedBuiltIn)

        terminal.resetToShippedText()

        XCTAssertFalse(terminal.isRevisedBuiltIn)
        XCTAssertEqual(terminal.name, "Terminal")
        XCTAssertEqual(terminal.triggerWords, ["terminal", "shell command"])
        XCTAssertTrue(terminal.includesClipboardText)
        XCTAssertTrue(terminal.options.formalWriting)
    }

    func testPromptModeWrittenBeforeActionFieldsDecodesWithDefaults() throws {
        let json = Data(#"{"id":"0F5A4C3E-0000-4000-8000-000000000001","name":"Old","behavior":"polish","prompt":"Edit."}"#.utf8)
        let mode = try JSONDecoder().decode(PromptMode.self, from: json)
        XCTAssertEqual(mode.summary, "")
        XCTAssertEqual(mode.icon, "")
        XCTAssertEqual(mode.triggerWords, [])
        XCTAssertFalse(mode.usesSystemInstructionsTemplate, "an old mode's prompt was the whole prompt")
        XCTAssertFalse(mode.includesClipboardText)
        XCTAssertEqual(mode.options, PromptModeOptions())

        // And a fully populated one round-trips.
        var full = BuiltInPromptModes.all[0]
        full.options.professionalTone = true
        full.includesSelectedText = true
        full.usesSystemInstructionsTemplate = true
        let decoded = try JSONDecoder().decode(PromptMode.self, from: try JSONEncoder().encode(full))
        XCTAssertEqual(decoded, full)
    }

    func testTriggerWordsAreNormalized() {
        XCTAssertEqual(
            PromptMode.normalizedTriggerWords([" Terminal ", "", "terminal", "Shell command", "  "]),
            ["Terminal", "Shell command"]
        )
    }

    func testSettingsFamilyFollowsTheBuiltInAndBehavior() {
        XCTAssertEqual(BuiltInPromptModes.shipped(forKey: BuiltInPromptModes.Key.polish)?.settingsFamily, .polish)
        XCTAssertEqual(BuiltInPromptModes.shipped(forKey: BuiltInPromptModes.Key.translate2)?.settingsFamily, .translate)
        XCTAssertEqual(BuiltInPromptModes.shipped(forKey: BuiltInPromptModes.Key.questionAnswer)?.settingsFamily, .questionAnswer)
        XCTAssertEqual(BuiltInPromptModes.shipped(forKey: BuiltInPromptModes.Key.notes)?.settingsFamily, PromptModeSettingsFamily.none)
        XCTAssertEqual(PromptMode(name: "X", behavior: .translate, prompt: "T").settingsFamily, .translate)
    }

    // MARK: Providers

    func testProviderPresetsCarryEndpointsKeysAndAuthProfiles() {
        XCTAssertEqual(AIProviderKind.anthropic.defaultBaseURL?.absoluteString, "https://api.anthropic.com/v1")
        XCTAssertEqual(AIProviderKind.groq.defaultBaseURL?.absoluteString, "https://api.groq.com/openai/v1")
        XCTAssertEqual(AIProviderKind.cerebras.defaultBaseURL?.absoluteString, "https://api.cerebras.ai/v1")
        XCTAssertNil(AIProviderKind.azureOpenAI.defaultBaseURL)
        XCTAssertTrue(AIProviderKind.azureOpenAI.usesAzureAddressing)

        for kind in [AIProviderKind.anthropic, .groq, .cerebras] {
            XCTAssertEqual(kind.requestProfile, AIRequestProfile(), "\(kind) is a plain bearer provider")
            XCTAssertFalse(kind.recommendedModels.isEmpty)
            XCTAssertEqual(kind.suggestedModelID, kind.recommendedModels[0])
            XCTAssertNotNil(kind.apiKeyURL)
            XCTAssertTrue(kind.expectsAPIKey)
        }
        XCTAssertEqual(AIProviderKind.azureOpenAI.requestProfile.authStyle, .apiKeyHeader)
        XCTAssertEqual(AIProviderKind.azureOpenAI.requestProfile.apiVersion, AIProviderKind.azureDefaultAPIVersion)
        XCTAssertNil(AIProviderKind.ollama.apiKeyURL)
    }

    func testAzureBaseURLIsBuiltFromResourceAndDeployment() {
        XCTAssertEqual(
            AIProviderKind.azureBaseURL(resource: "my-res", deployment: "gpt-4o mini")?.absoluteString,
            "https://my-res.openai.azure.com/openai/deployments/gpt-4o%20mini"
        )
        XCTAssertNil(AIProviderKind.azureBaseURL(resource: "", deployment: "d"))
        XCTAssertNil(AIProviderKind.azureBaseURL(resource: "bad.host/evil", deployment: "d"))
    }

    func testApplyingAConfigurationCopiesItsRequestProfile() throws {
        var settings = AIEndpointSettings()
        let azure = AIConfiguration(
            name: "Azure",
            kind: .azureOpenAI,
            baseURL: AIProviderKind.azureBaseURL(resource: "r", deployment: "d"),
            modelID: "d"
        )
        settings.configurations = [azure]
        settings.apply(configuration: azure)
        XCTAssertEqual(settings.requestProfile.authStyle, .apiKeyHeader)
        XCTAssertEqual(settings.requestProfile.apiVersion, "2024-10-21")

        // A configuration saved before profiles existed loads with its preset's.
        let legacy = Data(#"{"id":"0F5A4C3E-0000-4000-8000-000000000002","name":"A","kind":"azureOpenAI","modelID":"d"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AIConfiguration.self, from: legacy).requestProfile.authStyle, .apiKeyHeader)
        // A provider this build does not know loads as Custom rather than failing.
        let unknown = Data(#"{"id":"0F5A4C3E-0000-4000-8000-000000000003","name":"A","kind":"oci","modelID":"d"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AIConfiguration.self, from: unknown).kind, .custom)
    }

    // MARK: Request context

    func testRequestContextDropsBlankValues() {
        var context = AIRequestContext(userProfile: "  ", clipboardText: "clip", selectedText: nil)
        XCTAssertNil(context.userProfile)
        XCTAssertEqual(context.clipboardText, "clip")
        context.clipboardText = "\n"
        XCTAssertNil(context.clipboardText)
        XCTAssertTrue(context.isEmpty)
    }
}
