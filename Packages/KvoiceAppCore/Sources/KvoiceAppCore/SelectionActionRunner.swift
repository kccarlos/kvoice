import Foundation
import KvoiceDomain

/// The Selection Action pipeline (product decisions #2/#4): a shortcut slot
/// fires, the focused selection is read through Accessibility, the slot's
/// action runs it through the configured endpoint, and the result replaces
/// the selection through the ordinary insertion tiers — never a simulated
/// paste, never the pasteboard on success.
///
/// Independent of `DictationController`: no recording, no state machine, no
/// history row. One run at a time; a second shortcut press while one is in
/// flight is refused as `.busy`. Everything it touches is a domain protocol,
/// so the whole pipeline is testable with fakes.
public actor SelectionActionRunner {
    public enum Outcome: Sendable, Equatable {
        /// The action's result replaced the selection (or was copied, per
        /// the insertion outcome).
        case inserted(InsertionOutcome)
        /// No slot binding, or the bound action no longer exists.
        case noAction
        /// The endpoint is not configured.
        case notConfigured
        /// Nothing usable is selected in the focused element.
        case noSelection
        /// No frontmost application to insert into.
        case noTarget
        /// Another selection action is still running.
        case busy
        /// The AI request or the insertion failed; nothing was inserted.
        case failed(KVoiceErrorCode)
    }

    private let settingsRepository: any SettingsRepository
    private let secretsRepository: (any SecretsRepository)?
    private let aiClient: any AIProcessingClient
    private let insertionService: any TextInsertionService
    private let selectionReader: any SelectionReading
    private let contextProvider: (any AIContextProviding)?
    private let diagnostics: (any DiagnosticLogging)?
    private var isRunning = false

    public init(
        settingsRepository: any SettingsRepository,
        secretsRepository: (any SecretsRepository)? = nil,
        aiClient: any AIProcessingClient,
        insertionService: any TextInsertionService,
        selectionReader: any SelectionReading,
        contextProvider: (any AIContextProviding)? = nil,
        diagnostics: (any DiagnosticLogging)? = nil
    ) {
        self.settingsRepository = settingsRepository
        self.secretsRepository = secretsRepository
        self.aiClient = aiClient
        self.insertionService = insertionService
        self.selectionReader = selectionReader
        self.contextProvider = contextProvider
        self.diagnostics = diagnostics
    }

    /// Runs the action bound to a slot (0-based) on the current selection.
    public func run(slot: Int) async -> Outcome {
        guard !isRunning else { return .busy }
        isRunning = true
        defer { isRunning = false }

        let settings = (try? await settingsRepository.load()) ?? AppSettings()
        guard let action = settings.ai.selectionAction(slot: slot), action.isUsable else {
            return .noAction
        }
        return await run(action: action, settings: settings)
    }

    /// Runs a specific action on the current selection.
    public func run(action: PromptMode, settings: AppSettings) async -> Outcome {
        var ai = settings.ai
        // The selection action is explicit, so it runs whether or not the
        // master switch is on; it still needs an endpoint.
        ai.isEnabled = true
        ai.apply(promptMode: action)
        guard ai.mode != .off else { return .notConfigured }

        // Target first, then selection: the selection must come from the
        // application the result goes back into.
        guard let target = await insertionService.captureTargetApplication() else {
            return .noTarget
        }
        guard let selection = await selectionReader.readFocusedSelection() else {
            return .noSelection
        }

        var context = AIRequestContext(userProfile: ai.userProfile)
        if action.includesClipboardText, let contextProvider {
            context.clipboardText = await contextProvider.clipboardText()
        }
        // The selection *is* the transcript here, so the selected-text
        // opt-in adds nothing.

        let jobID = UUID()
        let request = AIProcessRequest(
            jobID: jobID,
            mode: ai.mode,
            rawTranscript: selection,
            modelID: ai.modelID,
            targetLanguage: ai.translationLanguage,
            polishPrompt: ai.promptConfiguration.polishPrompt,
            context: context
        )

        let result: AIProcessResult
        do {
            let credentials = try await secretsRepository?.load()
            if let credentialClient = aiClient as? any CredentialInjectingAIProcessingClient {
                result = try await credentialClient.process(
                    request,
                    settings: ai,
                    credentials: credentials.map { AICredentialSnapshot(apiKey: $0.apiKey) }
                )
            } else {
                result = try await aiClient.process(request, settings: ai)
            }
        } catch let error as KVoiceError {
            emit(name: .aiRequestCompleted, result: .failure, code: error.code, mode: ai.mode)
            return .failed(error.code)
        } catch is CancellationError {
            return .failed(.aiCancelled)
        } catch {
            emit(name: .aiRequestCompleted, result: .failure, code: .aiUnreachable, mode: ai.mode)
            return .failed(.aiUnreachable)
        }

        do {
            let outcome = try await insertionService.insert(result.text, into: target, jobID: jobID)
            return .inserted(outcome)
        } catch let error as KVoiceError {
            return .failed(error.code)
        } catch {
            return .failed(.accessibilitySetFailed)
        }
    }

    private func emit(name: DiagnosticEventName, result: DiagnosticResult, code: KVoiceErrorCode, mode: DictationMode) {
        guard let diagnostics else { return }
        let event = DiagnosticEvent(
            name: name,
            result: result,
            errorCode: code,
            attributes: DiagnosticAttributes(mode: mode, actionKind: "selectionAction")
        )
        Task { await diagnostics.log(event) }
    }
}


public extension SelectionActionRunner.Outcome {
    /// Plain-language copy for the HUD (D.10: what happened, what kvoice did
    /// with the text, the next action). `nil` for `.inserted(.inserted)`,
    /// which the HUD shows as an ordinary success; a clipboard fallback and
    /// every refusal get a sentence. Error codes reuse the dictation catalog.
    var userFacingMessage: String? {
        switch self {
        case .inserted(.inserted), .inserted(.deliveredInApp):
            return nil
        case .inserted(.copiedToClipboard(let reason)):
            return reason.userFacingMessage
        case .inserted(.abortedAtTermination):
            return "KVoice was quitting; the selection was left as it was."
        case .noAction:
            return "No action is assigned to this shortcut. Choose one in AI Actions."
        case .notConfigured:
            return "Add an AI configuration in AI Actions before using a Selection Action."
        case .noSelection:
            return "Select some text first, then press the shortcut."
        case .noTarget:
            return "No application is in front to work on."
        case .busy:
            return "A Selection Action is still running."
        case .failed(let code):
            return code.userFacingMessage
        }
    }

    /// Every sentence `userFacingMessage` can return that is not already in
    /// `DomainUserFacingCopy` — the localization seam's inventory for this
    /// module (KvoiceUI's `DomainCopyTests` checks each has a translation).
    static var userFacingMessageInventory: [String] {
        [
            Self.inserted(.abortedAtTermination),
            .noAction,
            .notConfigured,
            .noSelection,
            .noTarget,
            .busy
        ].compactMap(\.userFacingMessage)
    }

    /// True when the selection was replaced (or the result copied) and the
    /// HUD should show a completion rather than a failure.
    var isSuccess: Bool {
        if case .inserted(let outcome) = self, outcome != .abortedAtTermination { return true }
        return false
    }
}
