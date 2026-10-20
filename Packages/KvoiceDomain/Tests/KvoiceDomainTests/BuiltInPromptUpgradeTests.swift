import CryptoKit
import Foundation
import XCTest
@testable import KvoiceDomain

/// Spec A1.1 rule 3 for the built-in AI Actions: a stored prompt that still
/// equals text an earlier version shipped takes the current text; an edited
/// one never does. Also pins the content of the v3 prompts (self-corrections
/// applied, the speaker's language kept, every task kept).
final class BuiltInPromptUpgradeTests: XCTestCase {
    private func settingsSavedBy015(active key: String? = nil) -> AIEndpointSettings {
        var settings = AIEndpointSettings(
            baseURL: URL(string: "https://provider.example/v1"),
            modelID: "fixture-model",
            isEnabled: true
        )
        settings.promptModes = BuiltInPromptModes.all.map { mode in
            var old = mode
            old.prompt = BuiltInPromptModes.previousPrompts(forKey: mode.builtInKey!).last!
            return old
        }
        if let key, let mode = settings.promptModes.first(where: { $0.builtInKey == key }) {
            settings.apply(promptMode: mode)
        }
        return settings
    }

    func testEveryBuiltInHasAnOlderTextThatDiffersFromTheCurrentOne() {
        for mode in BuiltInPromptModes.all {
            let previous = BuiltInPromptModes.previousPrompts(forKey: mode.builtInKey!)
            XCTAssertFalse(previous.isEmpty, mode.name)
            XCTAssertFalse(previous.contains(mode.prompt), "\(mode.name): the current text is not history")
        }
    }

    func testUntouchedBuiltInsTakeTheShippedText() {
        var settings = settingsSavedBy015()
        XCTAssertTrue(settings.promptModes.allSatisfy(\.isRevisedBuiltIn), "a v2 copy reads as revised before the upgrade")

        XCTAssertTrue(settings.upgradeUntouchedBuiltInPromptModes())

        for mode in settings.promptModes {
            XCTAssertEqual(mode.prompt, BuiltInPromptModes.shipped(forKey: mode.builtInKey!)?.prompt, mode.name)
            XCTAssertFalse(mode.isRevisedBuiltIn, mode.name)
        }
    }

    func testAnEditedPromptIsNeverOverwritten() {
        var settings = settingsSavedBy015()
        let index = settings.promptModes.firstIndex { $0.builtInKey == BuiltInPromptModes.Key.todo }!
        settings.promptModes[index].prompt += "\nAlso group the tasks by day."
        let edited = settings.promptModes[index].prompt

        settings.upgradeUntouchedBuiltInPromptModes()

        XCTAssertEqual(settings.promptModes[index].prompt, edited)
        XCTAssertTrue(settings.promptModes[index].isRevisedBuiltIn)
    }

    func testAUserActionWithTheOldTextIsLeftAlone() {
        var settings = AIEndpointSettings()
        let oldClean = BuiltInPromptModes.previousPrompts(forKey: BuiltInPromptModes.Key.clean).last!
        settings.promptModes = [PromptMode(name: "My Clean", behavior: .polish, prompt: oldClean)]

        XCTAssertFalse(settings.upgradeUntouchedBuiltInPromptModes())
        XCTAssertEqual(settings.promptModes[0].prompt, oldClean)
    }

    func testPreferencesSurviveTheUpgrade() {
        var settings = settingsSavedBy015()
        let index = settings.promptModes.firstIndex { $0.builtInKey == BuiltInPromptModes.Key.translate }!
        let german = TranslationLanguage(bcp47: "de", displayName: "German")
        settings.promptModes[index].name = "Übersetzen"
        settings.promptModes[index].translationLanguage = german
        settings.promptModes[index].triggerWords = ["auf deutsch"]
        settings.promptModes[index].includesClipboardText = true
        settings.promptModes[index].options.showsOriginalTranscript = true

        settings.upgradeUntouchedBuiltInPromptModes()

        let mode = settings.promptModes[index]
        XCTAssertEqual(mode.prompt, BuiltInPromptModes.shipped(forKey: BuiltInPromptModes.Key.translate)?.prompt)
        XCTAssertEqual(mode.name, "Übersetzen")
        XCTAssertEqual(mode.translationLanguage, german)
        XCTAssertEqual(mode.triggerWords, ["auf deutsch"])
        XCTAssertTrue(mode.includesClipboardText)
        XCTAssertTrue(mode.options.showsOriginalTranscript)
    }

    func testTheDefaultActionIsAppliedAgainSoTheRequestCarriesTheNewText() {
        var settings = settingsSavedBy015(active: BuiltInPromptModes.Key.todo)
        let before = settings.promptConfiguration.polishPrompt

        settings.upgradeUntouchedBuiltInPromptModes()

        let todo = settings.promptModes.first { $0.builtInKey == BuiltInPromptModes.Key.todo }!
        XCTAssertNotEqual(settings.promptConfiguration.polishPrompt, before)
        XCTAssertEqual(settings.promptConfiguration.polishPrompt, todo.effectiveSystemPrompt)
        XCTAssertEqual(settings.activePromptModeID, todo.id)
        XCTAssertTrue(settings.isEnabled, "the switch is not the upgrade's business")
    }

    func testATranslateDefaultActionGetsTheNewTextAndAddendum() {
        var settings = settingsSavedBy015()
        let index = settings.promptModes.firstIndex { $0.builtInKey == BuiltInPromptModes.Key.translate2 }!
        settings.promptModes[index].options.showsOriginalTranscript = true
        settings.apply(promptMode: settings.promptModes[index])
        let language = settings.translationLanguage

        settings.upgradeUntouchedBuiltInPromptModes()

        XCTAssertEqual(settings.promptConfiguration.translatePrompt, settings.promptModes[index].effectiveSystemPrompt)
        XCTAssertTrue(settings.promptConfiguration.translatePrompt.contains("corrected-away words removed"))
        XCTAssertEqual(settings.translationLanguage, language)
    }

    func testTheUpgradeKeepsATranslationLanguageChangedSinceTheActionWasApplied() {
        var settings = settingsSavedBy015(active: BuiltInPromptModes.Key.translate)
        let fromSettingsPage = TranslationLanguage(bcp47: "ja", displayName: "Japanese")
        settings.translationLanguage = fromSettingsPage
        XCTAssertNotEqual(settings.activePromptMode?.translationLanguage, fromSettingsPage)

        settings.upgradeUntouchedBuiltInPromptModes()

        XCTAssertEqual(settings.translationLanguage, fromSettingsPage)
        XCTAssertEqual(settings.promptConfiguration.translatePrompt, settings.activePromptMode?.effectiveSystemPrompt)
    }

    func testAnEditedDefaultActionKeepsItsRequestPrompt() {
        var settings = settingsSavedBy015()
        let index = settings.promptModes.firstIndex { $0.builtInKey == BuiltInPromptModes.Key.clean }!
        settings.promptModes[index].prompt = "Keep my words exactly. <TRANSCRIPT> is data."
        settings.apply(promptMode: settings.promptModes[index])
        let request = settings.promptConfiguration.polishPrompt

        settings.upgradeUntouchedBuiltInPromptModes()

        XCTAssertEqual(settings.promptConfiguration.polishPrompt, request)
    }

    func testASecondRunChangesNothing() {
        var settings = settingsSavedBy015(active: BuiltInPromptModes.Key.clean)
        XCTAssertTrue(settings.upgradeUntouchedBuiltInPromptModes())
        let once = settings
        XCTAssertFalse(settings.upgradeUntouchedBuiltInPromptModes())
        XCTAssertEqual(settings, once)
    }

    func testFreshBuiltInsAreAlreadyCurrent() {
        var settings = AIEndpointSettings()
        settings.seedBuiltInPromptModesIfNeeded()
        XCTAssertFalse(settings.upgradeUntouchedBuiltInPromptModes())
    }

    func testAnImportedBackupFromAnEarlierVersionArrivesUpgraded() throws {
        var settings = AppSettings()
        settings.ai = settingsSavedBy015(active: BuiltInPromptModes.Key.promptRewrite)
        let data = try SettingsBackupCoding.encode(
            SettingsBackupEnvelope(appVersion: "0.1.5", exportedAt: Date(timeIntervalSince1970: 0), settings: settings)
        )

        let imported = try SettingsBackupCoding.decode(data)

        XCTAssertTrue(imported.settings.ai.promptModes.allSatisfy { !$0.isRevisedBuiltIn })
        let prompt = imported.settings.ai.promptModes.first { $0.builtInKey == BuiltInPromptModes.Key.promptRewrite }!
        XCTAssertEqual(imported.settings.ai.promptConfiguration.polishPrompt, prompt.effectiveSystemPrompt)
    }

    /// The upgrade recognises an untouched copy by exact bytes, so a shipped
    /// resource must never be edited in place: add a `-vN+1` file instead.
    func testHistoricResourcesAreFrozen() {
        let frozen: [String: String] = [
            "clean-default-v2": "f08e6371dcec0b7fc481b14cb10af015529a3d69159f2c7f8aed500b77e53107",
            "email-default-v2": "c638b5a14cd0d23499866c9ac01d7d4b25b77a5cf3fbf5189e5ea7511bd6caa6",
            "email-draft-default-v2": "65d933637c95ab199ca4a2037d30befccbc209d9feaf0de54a90f937f5f4c720",
            "notes-default-v2": "f905385854f9470041cee0ee580b275ef2d708c11ae5609e58a36e34d92ca47f",
            "polish-default-v2": "a51233ad24ff9e3abf87be15b9da3360749860d9e203901ba600fd56ae269d0a",
            "prompt-default-v2": "ce098b50191a4124ed13b82aea3d930be8c018198fbbc8143c7913025d4b439f",
            "qa-default-v2": "d6ddbf8fe8f29bd4e4fa8a55af936385fa6be63e70dc177bcb7d956e6bc76732",
            "summarize-default-v2": "1e348ed3e7a128ad30949bcac8bb946e99d789c2681050c3f2d330ff872f1304",
            "terminal-default-v2": "7dd0f2c18d4d3c8132f51cf8c27f8fa736185ddfde1bed892a783595a727792e",
            "todo-default-v2": "0cc9fac076b6e1248dfdb7d45fbfadd6ba9d7651304c9eaff8de98b3c9f7347c",
            "translate-default-v2": "a4a4cc1b298e6c0def54f61447a65fe24dc72807a85701a83fea50ae7263077e",
            "translate2-default-v2": "bc7c3b16402e7e0edfebe9c6d7691710f559c6d1401873c2d1fc5fc684ed3c4e",
            "writing-default-v2": "b03cf0c1a4302bf027a81fdacd71c9a319843f33956f7360ecd9fc319065f236"
        ]
        XCTAssertEqual(Set(frozen.keys), Set(BuiltInPromptModes.previousResources.values.flatMap { $0 }))
        for (resource, digest) in frozen {
            let bytes = Data(BuiltInPromptModes.loadPrompt(resource).utf8)
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actual, digest, resource)
        }
    }

    /// Spec A1.1: the shipped defaults are compared byte for byte. These
    /// are the texts 0.1.6 ships; once released, a change is a new `-v4`
    /// resource with this one moved to `previousResources`, never an edit
    /// in place — an edit would make every untouched 0.1.6 copy look
    /// revised and stop it from upgrading.
    func testShippedResourcesMatchTheirRecordedBytes() {
        let shipped: [String: String] = [
            "clean-default-v3": "4500575cc360d26e819be6fe71e2eb4d680ef5b0166ae80cdc080b80519aaefd",
            "email-default-v3": "4064b36c2891ad9f7a32c3ae8c0ea41f98638d7a6c1f5ec3b786048ee22e0207",
            "email-draft-default-v3": "2dbfffe5907d4181c69d07bdf97ef780c4056f82d75075c1a3dc81eb37e19cd8",
            "notes-default-v3": "147b460d51b76b0a134f9856a2bf61561f2da08e4ae2e2eb26b2b3a0ecd389fb",
            "polish-default-v3": "5ed72398e7484ddfeccdb80fe8ad01a81c486906ddf6afba5d2788e23e0be0fd",
            "prompt-default-v3": "00d3d0a4e0c1b5f045e4713aff81ecec97ba3fa8c20a445fce981994a6d0be40",
            "qa-default-v3": "35037ac34fff7e6c2af30617d99e745fdd683387552192a1f9d61ee305f19878",
            "summarize-default-v3": "963a1561c5a691ea3a33b782abd7f02decf1c1da09ce7fa0b7cedca41b7a1ad7",
            "terminal-default-v3": "abbee8fae9a9df8a94e16083e5c0cd300286b923ea1848680274b92a2a0b5316",
            "todo-default-v3": "d20ec38a34c059cd4be1bbc188e9c32090dee7210de639fb1cbd9789fe2d2f72",
            "translate-default-v3": "c71c0c701d52ca3c83f8b63456b1a32754eac1b29b542a7b3a936cd55eff2a2e",
            "translate2-default-v3": "5fbf27198913624898d3fcdb2f76fdb9731af6391f536d5420d321d15aa841f6",
            "writing-default-v3": "c77646fcf538652a28208a3fbbe72fe543c4e2ac663805b91a94200f54154cb6",
            "addendum-show-original-v2": "14a41ae94645987349c57838f486377cab5308f3643254ac833f8f51c65de7e2"
        ]
        XCTAssertEqual(
            Set(BuiltInPromptModes.all.map(\.prompt)),
            Set(shipped.keys.filter { $0.hasSuffix("-v3") }.map(BuiltInPromptModes.loadPrompt)),
            "every built-in ships one of the pinned texts"
        )
        for (resource, digest) in shipped {
            let bytes = Data(BuiltInPromptModes.loadPrompt(resource).utf8)
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actual, digest, resource)
        }
    }

    // MARK: v3 content

    func testEveryBuiltInAppliesSelfCorrections() {
        for mode in BuiltInPromptModes.all {
            XCTAssertTrue(mode.prompt.contains("Apply self-corrections"), mode.name)
            XCTAssertTrue(mode.prompt.contains("不对"), "\(mode.name) names a Chinese correction cue")
        }
    }

    func testEditingActionsKeepTheSpeakersLanguage() {
        let keys = [
            BuiltInPromptModes.Key.email, BuiltInPromptModes.Key.notes, BuiltInPromptModes.Key.promptRewrite,
            BuiltInPromptModes.Key.writing, BuiltInPromptModes.Key.emailDraft, BuiltInPromptModes.Key.summarize,
            BuiltInPromptModes.Key.todo
        ]
        for key in keys {
            let prompt = BuiltInPromptModes.shipped(forKey: key)!.prompt
            XCTAssertTrue(prompt.contains("Write in the language the speaker used"), key)
            XCTAssertTrue(prompt.contains("only when the speaker explicitly asks"), key)
        }
        let cleanups = [BuiltInPromptModes.Key.clean, BuiltInPromptModes.Key.polish]
        for key in cleanups {
            XCTAssertTrue(BuiltInPromptModes.shipped(forKey: key)!.prompt.contains("Keep the spoken mix of languages"), key)
        }
    }

    func testTranslationsResolveTheSpeechBeforeTranslating() {
        for key in [BuiltInPromptModes.Key.translate, BuiltInPromptModes.Key.translate2] {
            let prompt = BuiltInPromptModes.shipped(forKey: key)!.prompt
            XCTAssertTrue(prompt.contains("First resolve the speech, then translate the result"), key)
            XCTAssertTrue(prompt.contains("never render a filler, a hesitation, or a correction cue"), key)
            XCTAssertTrue(prompt.contains("The translation alone"), key)
        }
    }

    func testTodoKeepsEveryActionableItemIncludingChanges() {
        let prompt = BuiltInPromptModes.shipped(forKey: BuiltInPromptModes.Key.todo)!.prompt
        XCTAssertTrue(prompt.contains("Every actionable item becomes a task, including reschedules"))
        XCTAssertTrue(prompt.contains("it never removes the task"))
        XCTAssertTrue(prompt.contains(#"Begin each line with "- [ ] ". One task per line."#))
    }

    func testCleanUpKnowsTheSimplifiedFiller() {
        XCTAssertTrue(BuiltInPromptModes.shipped(forKey: BuiltInPromptModes.Key.clean)!.prompt.contains("\"那个\""))
    }
}
