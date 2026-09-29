import Foundation

public struct RecordingState: Sendable, Equatable {
    public let jobID: JobID
    public let elapsed: Duration

    public init(jobID: JobID, elapsed: Duration = .zero) {
        self.jobID = jobID
        self.elapsed = elapsed
    }
}

public struct BlockReason: Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public static let microphonePermission = Self(
        code: KVoiceErrorCode.permissionMicrophoneDenied.rawValue,
        message: "Microphone access is denied. Enable KVoice in System Settings › Privacy & Security › Microphone."
    )
    public static let accessibilityPermission = Self(
        code: KVoiceErrorCode.permissionAccessibilityDenied.rawValue,
        message: "Accessibility permission is required for automatic insertion."
    )
    public static let modelUnavailable = Self(
        code: KVoiceErrorCode.modelNotInstalled.rawValue,
        message: "No transcription model is ready. Download or choose one in Settings › Model."
    )
    public static let microphoneNotRequested = Self(
        code: KVoiceErrorCode.permissionMicrophoneNotDetermined.rawValue,
        message: "Microphone access has not been granted yet. Allow it in Setup or Settings › Dictation."
    )
    public static let modelLoading = Self(
        code: KVoiceErrorCode.appBusy.rawValue,
        message: "The transcription model is still loading. Try again in a moment."
    )
    /// 2026-09-29: the default model is `.optimizing` — its first Core ML
    /// build on this Mac, minutes rather than a moment. Same code as
    /// `modelLoading` (the HUD's mapping is unchanged); the sentence tells
    /// the truth about the wait, once.
    public static let modelOptimizing = Self(
        code: KVoiceErrorCode.appBusy.rawValue,
        message: "Optimizing the speech model for this Mac — first time only, this can take a few minutes. Try again when it finishes."
    )

    // MARK: System-managed models (ADR-025 amendment, 2026-09-16)

    /// The default model is system-managed (Apple Speech) and the platform
    /// holds no assets for the selected transcription language
    /// (`ModelLifecycleState.absent`). Same code as `modelUnavailable` —
    /// the HUD's error mapping is unchanged — but the sentence says what
    /// is actually missing, because "download a model" would send the user
    /// to a card that reads "Installed" for the language they left.
    public static let systemManagedAssetsMissing = Self(
        code: KVoiceErrorCode.modelNotInstalled.rawValue,
        message: "Apple Speech has no assets for the selected language on this Mac yet. Install them in Settings › Speech Models."
    )

    /// The second sentence of `systemManagedUnavailable(_:)`.
    public static let systemManagedUnavailableHint = "Choose another speech model in Settings › Speech Models."

    /// The default model is system-managed and `.unavailable(failure)`: the
    /// reason the card already shows, then where to go. Two known
    /// sentences joined by a space, the shape `DomainCopy` localizes piece
    /// by piece.
    public static func systemManagedUnavailable(_ failure: ModelFailure) -> Self {
        Self(
            code: KVoiceErrorCode.modelNotInstalled.rawValue,
            message: "\(failure.message) \(systemManagedUnavailableHint)"
        )
    }
}

public enum StartPrerequisites: Sendable, Equatable {
    case passed
    case blocked(BlockReason)
}

public struct CompletionSummary: Sendable, Equatable {
    public let insertion: InsertionOutcome
    /// Plain-language detail for a completion that deserves a warning: a
    /// clipboard fallback reason, an AI fallback reason, or the recording cap.
    public let warningMessage: String?
    /// Set when the AI stage failed or was skipped and the local transcript was
    /// used instead (D.4 "Success + AI fallback"). Nil for AI-Off jobs and AI
    /// successes.
    public let aiFallback: AIErrorCode?
    /// True when recording was stopped by the hard duration cap (FR-AUD-009).
    public let durationCapReached: Bool

    public init(
        insertion: InsertionOutcome,
        warningMessage: String? = nil,
        aiFallback: AIErrorCode? = nil,
        durationCapReached: Bool = false
    ) {
        self.insertion = insertion
        self.warningMessage = warningMessage
        self.aiFallback = aiFallback
        self.durationCapReached = durationCapReached
    }

    /// Returns the same summary with job-level context attached. The reducer is
    /// pure and does not see the job aggregate, so the controller applies this
    /// projection right after a completion transition.
    public func attaching(
        aiFallback: AIErrorCode?,
        durationCapReached: Bool,
        maxRecordingSeconds: Int = 600
    ) -> CompletionSummary {
        guard aiFallback != nil || durationCapReached else { return self }
        var lines: [String] = []
        if let aiFallback {
            lines.append(aiFallback.userFacingMessage)
        }
        if let warningMessage {
            lines.append(warningMessage)
        }
        if durationCapReached {
            // Composed from the inventory's format so `DomainCopy` (KvoiceUI)
            // can recognise and re-localize the line.
            lines.append(
                DomainUserFacingCopy.recordingCapFormat
                    .replacingOccurrences(of: "%@", with: Self.limitDescription(seconds: maxRecordingSeconds))
            )
        }
        return CompletionSummary(
            insertion: insertion,
            warningMessage: lines.isEmpty ? nil : lines.joined(separator: " "),
            aiFallback: aiFallback,
            durationCapReached: durationCapReached
        )
    }

    /// "10-minute", "30-minute", "1-hour", "4-hour" for the cap copy.
    public static func limitDescription(seconds: Int) -> String {
        let bounded = max(seconds, 1)
        if bounded % 3_600 == 0 {
            return "\(bounded / 3_600)-hour"
        }
        if bounded % 60 == 0 {
            return "\(bounded / 60)-minute"
        }
        return "\(bounded)-second"
    }
}

public struct UserFacingFailure: Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// Uses the code's plain-language copy unless a more specific message is
    /// supplied. The raw code is never shown as HUD copy (D.10).
    public init(code: KVoiceErrorCode, message: String? = nil) {
        self.code = code.rawValue
        self.message = message ?? code.userFacingMessage
    }
}

/// The one canonical lifecycle enum. Keep this aligned with G.5; feature-specific
/// progress belongs in the associated value or diagnostics, not in parallel states.
public enum DictationState: Sendable, Equatable {
    case idle
    case blocked(BlockReason)
    case recording(RecordingState)
    case finalizing(JobID)
    case transcribing(JobID)
    case processingAI(JobID, AIMode)
    case inserting(JobID)
    case completed(JobID, CompletionSummary)
    case failed(JobID?, UserFacingFailure)
    case terminating(JobID?)

    public var jobID: JobID? {
        switch self {
        case .idle, .blocked:
            return nil
        case .recording(let recording):
            return recording.jobID
        case .finalizing(let jobID), .transcribing(let jobID), .inserting(let jobID):
            return jobID
        case .processingAI(let jobID, _), .completed(let jobID, _):
            return jobID
        case .failed(let jobID, _), .terminating(let jobID):
            return jobID
        }
    }

    public var kind: DictationStateKind {
        switch self {
        case .idle: return .idle
        case .blocked: return .blocked
        case .recording: return .recording
        case .finalizing: return .finalizing
        case .transcribing: return .transcribing
        case .processingAI: return .processingAI
        case .inserting: return .inserting
        case .completed: return .completed
        case .failed: return .failed
        case .terminating: return .terminating
        }
    }
}

public enum DictationStateKind: String, Codable, Sendable, Equatable, CaseIterable {
    case idle
    case blocked
    case recording
    case finalizing
    case transcribing
    case processingAI
    case inserting
    case completed
    case failed
    case terminating
}

public enum DictationEvent: Sendable, Equatable {
    case start(jobID: JobID, prerequisites: StartPrerequisites)
    case stop(jobID: JobID)
    case escape(jobID: JobID)
    case hardDurationCap(jobID: JobID)
    case captureFailure(jobID: JobID, code: KVoiceErrorCode)
    case validRecording(jobID: JobID)
    case invalidAudio(jobID: JobID, code: KVoiceErrorCode)
    case rawTranscript(jobID: JobID, mode: DictationMode)
    case transcriptionFailure(jobID: JobID, code: KVoiceErrorCode)
    case aiSuccess(jobID: JobID)
    case aiFailure(jobID: JobID, code: KVoiceErrorCode)
    case aiCancelled(jobID: JobID)
    case insertionSucceeded(jobID: JobID, outcome: InsertionOutcome)
    case insertionFallback(jobID: JobID, outcome: InsertionOutcome)
    case clipboardFailure(jobID: JobID, code: KVoiceErrorCode)
    /// ADR-022 item 6: "Insert Again" on the failure HUD. Valid only in
    /// `.failed` for the same job while the exact final text is retained;
    /// takes the job back to `.inserting`, from where the ordinary
    /// `insertionSucceeded` / `insertionFallback` / `clipboardFailure`
    /// events finish it.
    case retryInsertion(jobID: JobID)
    case reset
    case dismiss
    case quit

    public var kind: DictationEventKind {
        switch self {
        case .start: return .start
        case .stop: return .stop
        case .escape: return .escape
        case .hardDurationCap: return .hardDurationCap
        case .captureFailure: return .captureFailure
        case .validRecording: return .validRecording
        case .invalidAudio: return .invalidAudio
        case .rawTranscript: return .rawTranscript
        case .transcriptionFailure: return .transcriptionFailure
        case .aiSuccess: return .aiSuccess
        case .aiFailure: return .aiFailure
        case .aiCancelled: return .aiCancelled
        case .insertionSucceeded: return .insertionSucceeded
        case .insertionFallback: return .insertionFallback
        case .clipboardFailure: return .clipboardFailure
        case .retryInsertion: return .retryInsertion
        case .reset: return .reset
        case .dismiss: return .dismiss
        case .quit: return .quit
        }
    }
}

public enum DictationEventKind: String, Sendable, Equatable, CaseIterable {
    case start
    case stop
    case escape
    case hardDurationCap
    case captureFailure
    case validRecording
    case invalidAudio
    case rawTranscript
    case transcriptionFailure
    case aiSuccess
    case aiFailure
    case aiCancelled
    case insertionSucceeded
    case insertionFallback
    case clipboardFailure
    case retryInsertion
    case reset
    case dismiss
    case quit
}

public enum DictationTransitionError: Error, Sendable, Equatable, LocalizedError {
    case illegalTransition(from: DictationStateKind, event: DictationEventKind)
    case staleJob(expected: JobID, received: JobID)
    case injectedJobMismatch(expected: JobID, received: JobID)

    public var errorDescription: String? {
        switch self {
        case .illegalTransition(let state, let event):
            return "Illegal dictation transition: \(state.rawValue) + \(event.rawValue)"
        case .staleJob(let expected, let received):
            return "Stale dictation job \(received.uuidString); expected \(expected.uuidString)"
        case .injectedJobMismatch(let expected, let received):
            return "Injected dictation job \(received.uuidString) does not match start job \(expected.uuidString)"
        }
    }
}

/// Pure state transition reducer. It has no clocks, services, logging, or UI side
/// effects, which makes every row in G.5 directly unit-testable.
public enum DictationReducer {
    public static func reduce(
        _ state: DictationState,
        event: DictationEvent
    ) throws -> DictationState {
        switch (state, event) {
        case (.idle, .start(let jobID, .passed)):
            return .recording(RecordingState(jobID: jobID))
        case (.idle, .start(_, .blocked(let reason))):
            return .blocked(reason)
        case (.blocked, .dismiss), (.blocked, .reset):
            return .idle

        case (.recording(let recording), .stop(let jobID)) where recording.jobID == jobID:
            return .finalizing(jobID)
        case (.recording(let recording), .escape(let jobID)) where recording.jobID == jobID:
            return .idle
        case (.recording(let recording), .hardDurationCap(let jobID)) where recording.jobID == jobID:
            return .finalizing(jobID)
        case (.recording(let recording), .captureFailure(let jobID, let code)) where recording.jobID == jobID:
            return .failed(jobID, UserFacingFailure(code: code))

        case (.finalizing(let stateJobID), .validRecording(let jobID)) where stateJobID == jobID:
            return .transcribing(jobID)
        case (.finalizing(let stateJobID), .escape(let jobID)) where stateJobID == jobID:
            return .idle
        case (.finalizing(let stateJobID), .invalidAudio(let jobID, let code)) where stateJobID == jobID:
            return .failed(jobID, UserFacingFailure(code: code))

        case (.transcribing(let stateJobID), .rawTranscript(let jobID, .off)) where stateJobID == jobID:
            return .inserting(jobID)
        case (.transcribing(let stateJobID), .rawTranscript(let jobID, let mode)) where stateJobID == jobID:
            guard let aiMode = mode.aiMode else {
                return .inserting(jobID)
            }
            return .processingAI(jobID, aiMode)
        case (.transcribing(let stateJobID), .escape(let jobID)) where stateJobID == jobID:
            return .idle
        case (.transcribing(let stateJobID), .transcriptionFailure(let jobID, let code)) where stateJobID == jobID:
            return .failed(jobID, UserFacingFailure(code: code))

        case (.processingAI(let stateJobID, _), .aiSuccess(let jobID)) where stateJobID == jobID:
            return .inserting(jobID)
        case (.processingAI(let stateJobID, _), .aiFailure(let jobID, _)) where stateJobID == jobID:
            return .inserting(jobID)
        case (.processingAI(let stateJobID, _), .aiCancelled(let jobID)) where stateJobID == jobID:
            return .inserting(jobID)
        case (.processingAI(let stateJobID, _), .escape(let jobID)) where stateJobID == jobID:
            return .inserting(jobID)

        case (.inserting(let stateJobID), .insertionSucceeded(let jobID, let outcome)) where stateJobID == jobID:
            return .completed(jobID, CompletionSummary(insertion: outcome))
        case (.inserting(let stateJobID), .insertionFallback(let jobID, let outcome)) where stateJobID == jobID:
            let warning: String
            if case .copiedToClipboard(let reason) = outcome {
                warning = reason.userFacingMessage
            } else {
                warning = DomainUserFacingCopy.clipboardFallbackGeneric
            }
            return .completed(jobID, CompletionSummary(insertion: outcome, warningMessage: warning))
        case (.inserting(let stateJobID), .clipboardFailure(let jobID, let code)) where stateJobID == jobID:
            return .failed(jobID, UserFacingFailure(code: code))

        case (.completed, .reset), (.completed, .dismiss), (.failed, .reset), (.failed, .dismiss):
            return .idle

        case (.failed(let stateJobID?, _), .retryInsertion(let jobID)) where stateJobID == jobID:
            // ADR-022 item 6: one-click recovery. Whether the retained text
            // exists is the controller's check (the reducer never sees it);
            // the reducer only says a failed job may try inserting again.
            return .inserting(jobID)

        case (.failed(let stateJobID, _), .escape(let jobID)) where stateJobID == jobID:
            // Failed is a recoverable HUD state. Escape is its state-equivalent
            // dismiss/recovery command and must never be swallowed as illegal.
            return .idle

        case (_, .quit):
            return .terminating(state.jobID)

        default:
            try validateJobMismatch(state: state, event: event)
            throw DictationTransitionError.illegalTransition(from: state.kind, event: event.kind)
        }
    }

    /// Returns true only for an event accepted by the pure reducer.
    public static func isLegal(_ state: DictationState, event: DictationEvent) -> Bool {
        (try? reduce(state, event: event)) != nil
    }

    private static func validateJobMismatch(
        state: DictationState,
        event: DictationEvent
    ) throws {
        guard let receivedJobID = event.jobID else { return }
        guard let expectedJobID = state.jobID, expectedJobID != receivedJobID else { return }
        throw DictationTransitionError.staleJob(expected: expectedJobID, received: receivedJobID)
    }
}

private extension DictationEvent {
    var jobID: JobID? {
        switch self {
        case .start(let jobID, _), .stop(let jobID), .escape(let jobID),
             .hardDurationCap(let jobID), .captureFailure(let jobID, _),
             .validRecording(let jobID), .invalidAudio(let jobID, _),
             .rawTranscript(let jobID, _), .transcriptionFailure(let jobID, _),
             .aiSuccess(let jobID), .aiFailure(let jobID, _), .aiCancelled(let jobID),
             .insertionSucceeded(let jobID, _), .insertionFallback(let jobID, _),
             .clipboardFailure(let jobID, _), .retryInsertion(let jobID):
            return jobID
        case .reset, .dismiss, .quit:
            return nil
        }
    }
}
