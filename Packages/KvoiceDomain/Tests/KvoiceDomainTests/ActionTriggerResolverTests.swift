import Foundation
import XCTest
@testable import KvoiceDomain

final class ActionTriggerResolverTests: XCTestCase {
    private let terminal = PromptMode(
        name: "Terminal", behavior: .polish, prompt: "Command.", triggerWords: ["terminal", "shell command"]
    )
    private let translate = PromptMode(
        name: "Translate", behavior: .translate, prompt: "Translate {targetLanguageDisplayName}.",
        translationLanguage: TranslationLanguage(bcp47: "de", displayName: "German"),
        triggerWords: ["translate"]
    )
    private let translate2 = PromptMode(
        name: "Translate 2", behavior: .translate, prompt: "Translate again.",
        translationLanguage: TranslationLanguage(bcp47: "ja", displayName: "Japanese"),
        triggerWords: ["translate two"]
    )

    private var actions: [PromptMode] { [terminal, translate, translate2] }

    func testMatchesCaseInsensitivelyAndStripsTheTriggerAndPunctuation() {
        let match = ActionTriggerResolver.match(transcript: "  Terminal, list the files here.", actions: actions)
        XCTAssertEqual(match?.action.id, terminal.id)
        XCTAssertEqual(match?.transcript, "list the files here.")
        XCTAssertEqual(match?.trigger, "terminal")

        let phrase = ActionTriggerResolver.match(transcript: "shell command: show disk usage", actions: actions)
        XCTAssertEqual(phrase?.action.id, terminal.id)
        XCTAssertEqual(phrase?.transcript, "show disk usage")
    }

    func testRequiresAWordBoundaryAfterTheTrigger() {
        XCTAssertNil(ActionTriggerResolver.match(transcript: "terminally ill patients", actions: actions))
        XCTAssertNil(ActionTriggerResolver.match(transcript: "translated documents are ready", actions: actions))
    }

    func testDoesNotMatchInTheMiddleOfATranscript() {
        XCTAssertNil(ActionTriggerResolver.match(transcript: "open the terminal please", actions: actions))
    }

    func testLongestTriggerWins() {
        let match = ActionTriggerResolver.match(transcript: "Translate two, where is the station", actions: actions)
        XCTAssertEqual(match?.action.id, translate2.id)
        XCTAssertEqual(match?.transcript, "where is the station")

        let single = ActionTriggerResolver.match(transcript: "translate where is the station", actions: actions)
        XCTAssertEqual(single?.action.id, translate.id)
    }

    func testATriggerAloneIsNotAMatch() {
        XCTAssertNil(ActionTriggerResolver.match(transcript: "Terminal.", actions: actions))
        XCTAssertNil(ActionTriggerResolver.match(transcript: "", actions: actions))
    }

    func testUnusableActionsAndEmptyTriggersAreSkipped() {
        let blank = PromptMode(name: "Blank", behavior: .polish, prompt: "  ", triggerWords: ["terminal"])
        let empty = PromptMode(name: "Empty", behavior: .polish, prompt: "x", triggerWords: ["", "  "])
        XCTAssertNil(ActionTriggerResolver.match(transcript: "terminal list files", actions: [blank, empty]))
    }

    func testResolveAppliesTheTriggeredActionOnlyWhenTriggersAndAIAreOn() {
        var settings = AIEndpointSettings(
            baseURL: URL(string: "https://provider.example/v1"),
            modelID: "m",
            promptModes: actions,
            isEnabled: true
        )
        settings.apply(promptMode: terminal)

        let off = ActionTriggerResolver.resolve(transcript: "translate hello", settings: settings)
        XCTAssertNil(off.triggeredAction)
        XCTAssertEqual(off.transcript, "translate hello")
        XCTAssertEqual(off.settings, settings)

        settings.actionTriggersEnabled = true
        let on = ActionTriggerResolver.resolve(transcript: "translate hello", settings: settings)
        XCTAssertEqual(on.triggeredAction?.id, translate.id)
        XCTAssertEqual(on.transcript, "hello")
        XCTAssertEqual(on.settings.mode, .translate)
        XCTAssertEqual(on.settings.translationLanguage.bcp47, "de")
        XCTAssertEqual(on.settings.promptConfiguration.translatePrompt, translate.prompt)
        XCTAssertEqual(on.settings.activePromptModeID, translate.id)
        XCTAssertEqual(settings.activePromptModeID, terminal.id, "the caller's settings are untouched")

        settings.isEnabled = false
        let disabled = ActionTriggerResolver.resolve(transcript: "translate hello", settings: settings)
        XCTAssertNil(disabled.triggeredAction, "triggers are inactive while AI Actions is off")
    }

    func testEveryShippedTriggerWordResolvesToItsOwnAction() {
        let shipped = BuiltInPromptModes.all
        for action in shipped {
            for trigger in action.triggerWords {
                let match = ActionTriggerResolver.match(transcript: "\(trigger) something to process", actions: shipped)
                XCTAssertEqual(match?.action.id, action.id, "\(trigger) must select \(action.name)")
            }
        }
    }
}
