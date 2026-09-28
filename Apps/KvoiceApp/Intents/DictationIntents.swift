import AppIntents
import KvoiceAppCore
import KvoiceDomain
import KvoiceUI

// ADR-020: the App Intents surface — what the Shortcuts app, Siri, and
// Spotlight can ask kvoice to do. Every intent here is deliberately thin: it
// maps its parameters onto a `DictationCommandService.Command`, awaits the
// service, and turns the scalar `Outcome` into a dialog. All gating and state
// live in `DictationController` behind the service, which is what the unit
// tests cover (`DictationCommandServiceTests`); these types get a compile
// check and a human in the Shortcuts app.
//
// The intents run in-process (`openAppWhenRun == false`): kvoice is a
// menu-bar agent, the recorder and the HUD are already in this process, and
// bringing the app frontmost would steal focus from the very app the
// transcript is meant to land in. `AppDependencyManager` hands the service
// to each intent; `AppDelegate+Intents.swift` registers it at launch.
//
// Strings: titles, descriptions, and dialogs are `LocalizedStringResource`
// literals in the `Shell` table (the app target's catalog) so they are
// synced and translated like every other shell string.

// MARK: - Start

struct StartDictationIntent: AppIntent {
    static let title = LocalizedStringResource("Start Dictation", table: "Shell")
    static let description = IntentDescription(
        LocalizedStringResource(
            "Starts a hands-free recording, as if the shortcut were pressed in Toggle mode. Stop it with Stop Dictation, Toggle Dictation, or the shortcut.",
            table: "Shell"
        )
    )
    static let openAppWhenRun = false

    /// Optional: run this saved AI action for this dictation only
    /// (`DictationStartOptions.aiActionID`). The default action and the
    /// master switch are not changed.
    @Parameter(title: LocalizedStringResource("AI Action", table: "Shell"))
    var aiAction: AIActionEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Start dictation with \(\.$aiAction)", table: "Shell") {}
    }

    @Dependency
    private var service: DictationCommandService

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await service.perform(.start(aiActionID: aiAction?.id))
        return .result(dialog: IntentDialogs.dialog(for: outcome))
    }
}

// MARK: - Stop

struct StopDictationIntent: AppIntent {
    static let title = LocalizedStringResource("Stop Dictation", table: "Shell")
    static let description = IntentDescription(
        LocalizedStringResource(
            "Ends the active recording; the transcript is inserted into the app that was in front when it started.",
            table: "Shell"
        )
    )
    static let openAppWhenRun = false

    @Dependency
    private var service: DictationCommandService

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await service.perform(.stop)
        return .result(dialog: IntentDialogs.dialog(for: outcome))
    }
}

// MARK: - Toggle

struct ToggleDictationIntent: AppIntent {
    static let title = LocalizedStringResource("Toggle Dictation", table: "Shell")
    static let description = IntentDescription(
        LocalizedStringResource(
            "Starts a recording when KVoice is idle and stops it when it is recording. Bind this to one trigger for start and stop.",
            table: "Shell"
        )
    )
    static let openAppWhenRun = false

    @Dependency
    private var service: DictationCommandService

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await service.perform(.toggle)
        return .result(dialog: IntentDialogs.dialog(for: outcome))
    }
}

// MARK: - Cancel

struct CancelDictationIntent: AppIntent {
    static let title = LocalizedStringResource("Cancel Dictation", table: "Shell")
    static let description = IntentDescription(
        LocalizedStringResource(
            "Discards the active dictation without inserting anything, or dismisses the result shown on screen. The same as pressing Escape.",
            table: "Shell"
        )
    )
    static let openAppWhenRun = false

    @Dependency
    private var service: DictationCommandService

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await service.perform(.cancel)
        return .result(dialog: IntentDialogs.dialog(for: outcome))
    }
}

// MARK: - Get Last Transcription

struct GetLastTranscriptionIntent: AppIntent {
    static let title = LocalizedStringResource("Get Last Transcription", table: "Shell")
    static let description = IntentDescription(
        LocalizedStringResource(
            "Returns the final text of the newest History entry, so another action can use it. Needs History to be on.",
            table: "Shell"
        )
    )
    static let openAppWhenRun = false

    @Dependency
    private var service: DictationCommandService

    /// The text is the intent's *result* — that is the point of the action —
    /// and goes nowhere else; the service never logs it (rule 3).
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        switch await service.lastTranscription() {
        case .text(let text):
            return .result(
                value: text,
                dialog: IntentDialog(LocalizedStringResource("Here is the last transcription.", table: "Shell"))
            )
        case .historyDisabled:
            return .result(
                value: "",
                dialog: IntentDialog(LocalizedStringResource("History is off, so there is no last transcription. Turn it on in Data & Privacy.", table: "Shell"))
            )
        case .empty:
            return .result(
                value: "",
                dialog: IntentDialog(LocalizedStringResource("There is no transcription in History yet.", table: "Shell"))
            )
        case .unavailable:
            return .result(
                value: "",
                dialog: IntentDialog(LocalizedStringResource("History is unavailable right now.", table: "Shell"))
            )
        }
    }
}

// MARK: - Dialogs

/// One sentence per `Outcome`. Kept in one place so the four commands read
/// the same way in Shortcuts and Siri.
enum IntentDialogs {
    static func dialog(for outcome: DictationCommandService.Outcome) -> IntentDialog {
        switch outcome {
        case .started:
            return IntentDialog(LocalizedStringResource("Recording. Stop when you are done.", table: "Shell"))
        case .startedWithoutAIAction:
            return IntentDialog(LocalizedStringResource("Recording without the AI action: no AI endpoint is configured.", table: "Shell"))
        case .unknownAIAction:
            return IntentDialog(LocalizedStringResource("That AI action no longer exists. Pick another one in the shortcut.", table: "Shell"))
        case .alreadyRecording:
            return IntentDialog(LocalizedStringResource("KVoice is already recording.", table: "Shell"))
        case .busy:
            return IntentDialog(LocalizedStringResource("KVoice is still finishing the previous dictation.", table: "Shell"))
        case .engineBusy:
            return IntentDialog(LocalizedStringResource("KVoice is busy with another transcription. Try again when it finishes.", table: "Shell"))
        case .blocked(let reason):
            // The controller's own Blocked copy, localized the way the HUD
            // localizes it.
            let message = DomainCopy.localized(reason.message)
            return IntentDialog(LocalizedStringResource("Couldn't start dictation. \(message)", table: "Shell"))
        case .stopped:
            return IntentDialog(LocalizedStringResource("Stopped. Transcribing and inserting.", table: "Shell"))
        case .cancelled:
            return IntentDialog(LocalizedStringResource("Dictation cancelled.", table: "Shell"))
        case .dismissed:
            return IntentDialog(LocalizedStringResource("Dismissed.", table: "Shell"))
        case .cannotCancelWhileInserting:
            return IntentDialog(LocalizedStringResource("The text is being inserted and can't be cancelled now.", table: "Shell"))
        case .idle:
            return IntentDialog(LocalizedStringResource("KVoice is not recording.", table: "Shell"))
        }
    }
}
