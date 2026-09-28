import Foundation
import KvoiceDomain

/// The one entry point for App Intents (Shortcuts, Siri, Spotlight) into
/// dictation — ADR-020.
///
/// The intents in the app target hold no logic: each maps its parameters onto
/// a `Command`, calls `perform`, and turns the `Outcome` into a dialog. This
/// type routes every command onto the existing `DictationController` calls
/// (`startRecording`, `stopRecording`, `cancel`, `handle(.dismiss)`) so an
/// intent-started job is the same job a hotkey would have started: same
/// prerequisite check (a missing microphone grant or model surfaces as
/// `.blocked`), same settings snapshot, same busy gating. It keeps no state
/// of its own — the controller stays the only lifecycle owner — which is
/// what makes it testable against the `KvoiceTestSupport` fakes.
///
/// `@MainActor` because the shell's gate (`startGate`) reads main-actor
/// state and App Intents' `perform()` is happy to run there; the controller
/// itself is an actor and is awaited.
@MainActor
public final class DictationCommandService {
    /// What an intent asks for. `start(aiActionID:)` carries the optional
    /// per-dictation action override (`DictationStartOptions.aiActionID`).
    public enum Command: Sendable, Equatable {
        case start(aiActionID: UUID?)
        case stop
        case toggle
        case cancel
    }

    /// The scalar result an intent turns into a dialog. Every case is a
    /// distinct sentence in the intent layer; none carries transcript text.
    public enum Outcome: Sendable, Equatable {
        /// A recording began.
        case started
        /// A recording began, but the requested AI action cannot run because
        /// no usable endpoint is configured; the job runs without AI.
        case startedWithoutAIAction
        /// The requested action id matches no saved, usable action; nothing
        /// was started.
        case unknownAIAction
        /// A recording is already running; state unchanged.
        case alreadyRecording
        /// The previous dictation is still finishing (finalizing,
        /// transcribing, AI, inserting); state unchanged.
        case busy(DictationStateKind)
        /// The shell refused the start because something else holds the
        /// speech engine (Transcribe File, the performance test, a
        /// compute-unit reload) — the hotkey path beeps in the same case.
        case engineBusy
        /// The controller's prerequisite check blocked the start; the reason
        /// is what the HUD shows.
        case blocked(BlockReason)
        /// The recording ended; transcription and insertion continue.
        case stopped
        /// The active job was discarded.
        case cancelled
        /// A terminal HUD (completed / failed / blocked) was dismissed.
        case dismissed
        /// Insertion has begun and cannot be interrupted (a partially applied
        /// AX write must finish).
        case cannotCancelWhileInserting
        /// Nothing to stop or cancel.
        case idle
    }

    /// Get Last Transcription: the newest history row's final text, or why
    /// there is none. The text is the intent's *result*, never logged.
    public enum LastTranscription: Sendable, Equatable {
        case text(String)
        case historyDisabled
        case empty
        case unavailable
    }

    /// The shell's reason for refusing a start before the controller sees it.
    /// The shell wires this to the same engine-ownership check the hotkey
    /// path makes (`AppDelegate.receiveShortcut`); the default refuses nothing.
    public typealias StartGate = @MainActor () -> Bool

    private let controller: DictationController
    private let historyRepository: (any HistoryRepository)?
    private let settingsProvider: @MainActor () -> AppSettings
    private let startGate: StartGate
    private let diagnosticLogger: any DiagnosticLogging

    /// - Parameters:
    ///   - controller: the one lifecycle owner every command is routed to.
    ///   - history: read for Get Last Transcription only; nil reports
    ///     `.unavailable`.
    ///   - settingsProvider: the live settings (the shell's `currentSettings`),
    ///     for the history switch and the saved AI actions. The controller
    ///     loads its own snapshot at the start edge; this is never persisted.
    ///   - startGate: returns `true` when the shell can admit a start now.
    ///   - diagnosticLogger: receives one scalar event per command
    ///     (`reason: "appIntent"`) so intent-driven jobs can be told apart.
    public init(
        controller: DictationController,
        history: (any HistoryRepository)? = nil,
        settingsProvider: @escaping @MainActor () -> AppSettings,
        startGate: @escaping StartGate = { true },
        diagnosticLogger: any DiagnosticLogging = NullDiagnosticLogger()
    ) {
        self.controller = controller
        historyRepository = history
        self.settingsProvider = settingsProvider
        self.startGate = startGate
        self.diagnosticLogger = diagnosticLogger
    }

    // MARK: - Commands

    @discardableResult
    public func perform(_ command: Command) async -> Outcome {
        let outcome: Outcome
        switch command {
        case .start(let aiActionID):
            outcome = await start(aiActionID: aiActionID)
        case .stop:
            outcome = await stop()
        case .toggle:
            outcome = await toggle()
        case .cancel:
            outcome = await cancel()
        }
        await log(command: command, outcome: outcome)
        return outcome
    }

    /// Toggle-style start: a terminal HUD is dismissed first (the deliberate
    /// intent should not be swallowed by a completion still on screen), an
    /// active job is reported rather than touched.
    private func start(aiActionID: UUID?) async -> Outcome {
        var aiOutcome: Outcome = .started
        if let aiActionID {
            let ai = settingsProvider().ai
            guard let action = ai.promptModes.first(where: { $0.id == aiActionID }), action.isUsable else {
                return .unknownAIAction
            }
            if !ai.canEnableProcessing {
                aiOutcome = .startedWithoutAIAction
            }
        }

        let state = await controller.state
        switch state.kind {
        case .recording:
            return .alreadyRecording
        case .finalizing, .transcribing, .processingAI, .inserting, .terminating:
            return .busy(state.kind)
        case .completed, .failed, .blocked:
            _ = await controller.handle(.dismiss)
        case .idle:
            break
        }
        guard startGate() else { return .engineBusy }

        let next = await controller.startRecording(
            options: DictationStartOptions(aiActionID: aiActionID)
        )
        switch next {
        case .recording:
            return aiOutcome
        case .blocked(let reason):
            return .blocked(reason)
        default:
            // The start was admitted and then failed at once (no capture
            // service, a capture failure); the HUD carries the failure. Or a
            // concurrent hotkey won the reservation — report what is running.
            return next.kind == .idle ? .idle : .busy(next.kind)
        }
    }

    private func stop() async -> Outcome {
        let state = await controller.state
        switch state.kind {
        case .recording:
            _ = await controller.stopRecording()
            return .stopped
        case .finalizing, .transcribing, .processingAI, .inserting, .terminating:
            return .busy(state.kind)
        case .idle, .completed, .failed, .blocked:
            return .idle
        }
    }

    private func toggle() async -> Outcome {
        let state = await controller.state
        if state.kind == .recording {
            return await stop()
        }
        return await start(aiActionID: nil)
    }

    /// Escape semantics, the same switch the shell's Escape monitor makes:
    /// an active job is discarded, a terminal HUD dismissed.
    private func cancel() async -> Outcome {
        let state = await controller.state
        switch state.kind {
        case .recording, .finalizing, .transcribing, .processingAI:
            _ = await controller.cancel()
            return .cancelled
        case .inserting:
            return .cannotCancelWhileInserting
        case .completed, .failed, .blocked:
            _ = await controller.handle(.dismiss)
            return .dismissed
        case .idle, .terminating:
            return .idle
        }
    }

    // MARK: - AI actions (the intent's `AI Action` parameter)

    /// The saved, usable AI actions in the user's order, for the entity
    /// query behind Start Dictation's optional parameter. `matching` narrows
    /// by name, case-insensitively; nil or blank returns all of them.
    public func aiActions(matching query: String? = nil) -> [PromptMode] {
        let usable = settingsProvider().ai.promptModes.filter(\.isUsable)
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !needle.isEmpty else { return usable }
        return usable.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    /// The saved actions with these ids, in the order asked for; unknown ids
    /// are dropped (Shortcuts resolves a stored parameter by id).
    public func aiActions(ids: [UUID]) -> [PromptMode] {
        let byID = Dictionary(uniqueKeysWithValues: aiActions().map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    // MARK: - Get Last Transcription

    /// The newest history row's final text. Read-only: nothing is written,
    /// and the text goes only to the caller.
    public func lastTranscription() async -> LastTranscription {
        guard settingsProvider().historyEnabled else { return .historyDisabled }
        guard let historyRepository else { return .unavailable }
        do {
            guard let newest = try await historyRepository.fetchPage(before: nil, limit: 1).first else {
                return .empty
            }
            return .text(newest.finalText)
        } catch {
            return .unavailable
        }
    }

    // MARK: - Diagnostics

    private func log(command: Command, outcome: Outcome) async {
        let state = await controller.state
        await diagnosticLogger.log(
            DiagnosticEvent(
                name: .dictationStateChanged,
                jobID: state.jobID,
                result: outcome.diagnosticResult,
                attributes: DiagnosticAttributes(
                    activeState: state.kind,
                    reason: "appIntent",
                    actionKind: command.diagnosticToken,
                    behavior: outcome.diagnosticToken
                )
            )
        )
    }
}

private extension DictationCommandService.Command {
    var diagnosticToken: String {
        switch self {
        case .start(let aiActionID): return aiActionID == nil ? "start" : "startWithAIAction"
        case .stop: return "stop"
        case .toggle: return "toggle"
        case .cancel: return "cancel"
        }
    }
}

private extension DictationCommandService.Outcome {
    var diagnosticResult: DiagnosticResult {
        switch self {
        case .started, .stopped, .cancelled, .dismissed:
            return .success
        case .startedWithoutAIAction:
            return .warning
        case .unknownAIAction, .alreadyRecording, .busy, .engineBusy, .blocked,
             .cannotCancelWhileInserting, .idle:
            return .ignored
        }
    }

    var diagnosticToken: String {
        switch self {
        case .started: return "started"
        case .startedWithoutAIAction: return "startedWithoutAIAction"
        case .unknownAIAction: return "unknownAIAction"
        case .alreadyRecording: return "alreadyRecording"
        case .busy(let kind): return "busy:\(kind.rawValue)"
        case .engineBusy: return "engineBusy"
        case .blocked(let reason): return "blocked:\(reason.code)"
        case .stopped: return "stopped"
        case .cancelled: return "cancelled"
        case .dismissed: return "dismissed"
        case .cannotCancelWhileInserting: return "cannotCancelWhileInserting"
        case .idle: return "idle"
        }
    }
}
