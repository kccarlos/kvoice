import Foundation

/// Mutable job data owned by `DictationController`. Lifecycle state remains the
/// canonical G.5 enum; this aggregate carries content-free metadata that would be
/// lost if it were encoded as additional lifecycle states.
public struct DictationJob: Sendable, Equatable {
    public let id: JobID
    public let startedAt: Date
    /// The application the text goes to. Captured at the start edge;
    /// re-captured only by `retargetForRetry(_:)` (ADR-022 item 6) when the
    /// user asks a failed job to insert again into whatever is frontmost now.
    public private(set) var target: TargetApplicationSnapshot?
    /// Fixed at the start edge; rewritten only by `applyAISettings(_:)`
    /// (ADR-021, the in-recorder AI controls) and always together, so the
    /// mode the reducer sees, the translation target the history row
    /// records, and the settings the request is built from cannot disagree.
    public private(set) var modeSnapshot: DictationMode
    public private(set) var translationTargetSnapshot: TranslationLanguage?
    public let modelIDSnapshot: ModelID
    /// History enablement at the start edge. The live setting is consulted
    /// again at write time so disabling history mid-job still suppresses the
    /// row (FR-HIST-001).
    public let historyEnabled: Bool
    /// The AI endpoint settings this job will use. Contains no secrets; the
    /// credential snapshot is obtained separately at request time.
    public private(set) var aiSettingsSnapshot: AIEndpointSettings?
    /// Where the final text goes. Onboarding's first-dictation test delivers
    /// in-app instead of inserting into the frontmost application.
    public let delivery: DictationDelivery
    /// Trigger flags fixed at the start edge (or, for auto-send, armed by a
    /// double-press while still recording).
    public private(set) var options: DictationStartOptions
    public var rawTranscript: String?
    public var finalText: String?
    public var fallbackReason: AIErrorCode?
    public private(set) var durationCapReached: Bool
    public private(set) var aiCancelled: Bool
    public private(set) var transcriptionDuration: Duration?
    // MARK: History and data
    /// Wall time of a successful AI request, for the history row's
    /// `aiDurationMilliseconds` (the "Avg AI time" tile).
    public private(set) var aiDuration: Duration?
    /// True once a history row exists for this job, so a retried insertion
    /// (ADR-022 item 6) never writes a second one.
    public private(set) var historyRowWritten = false

    public init(
        id: JobID,
        startedAt: Date,
        target: TargetApplicationSnapshot?,
        modeSnapshot: DictationMode,
        translationTargetSnapshot: TranslationLanguage?,
        modelIDSnapshot: ModelID,
        historyEnabled: Bool = true,
        aiSettingsSnapshot: AIEndpointSettings? = nil,
        delivery: DictationDelivery = .insertIntoTarget,
        options: DictationStartOptions = .init(),
        rawTranscript: String? = nil,
        finalText: String? = nil,
        fallbackReason: AIErrorCode? = nil,
        durationCapReached: Bool = false,
        aiCancelled: Bool = false,
        transcriptionDuration: Duration? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.target = target
        self.modeSnapshot = modeSnapshot
        self.translationTargetSnapshot = translationTargetSnapshot
        self.modelIDSnapshot = modelIDSnapshot
        self.historyEnabled = historyEnabled
        self.aiSettingsSnapshot = aiSettingsSnapshot
        self.delivery = delivery
        self.options = options
        self.rawTranscript = rawTranscript
        self.finalText = finalText
        self.fallbackReason = fallbackReason
        self.durationCapReached = durationCapReached
        self.aiCancelled = aiCancelled
        self.transcriptionDuration = transcriptionDuration
    }

    public mutating func recordTranscriptionDuration(_ duration: Duration) {
        transcriptionDuration = duration
    }

    public mutating func markDurationCapReached() {
        durationCapReached = true
    }

    /// Arms auto-send for a job that is still recording (double-press).
    public mutating func armAutoSend() {
        options.autoSend = true
    }

    /// ADR-021: the in-recorder AI controls (⌘1–⌘0, ⌘⇧A) replace this job's
    /// AI settings snapshot while it is still being captured. The derived
    /// `mode` and the translation target follow from the same value so the
    /// three snapshots stay one fact; the persisted settings are untouched
    /// by design — the controller never writes its repository here.
    public mutating func applyAISettings(_ settings: AIEndpointSettings) {
        aiSettingsSnapshot = settings
        modeSnapshot = settings.mode
        translationTargetSnapshot = settings.translationLanguage
    }

    // MARK: History and data

    public mutating func recordAIDuration(_ duration: Duration) {
        aiDuration = duration
    }

    public mutating func markHistoryRowWritten() {
        historyRowWritten = true
    }

    /// ADR-022 item 6: "Insert Again" targets the application that is
    /// frontmost *now*, not the one captured when the recording started —
    /// the user has usually clicked into the field they meant. `nil` means
    /// nothing is frontmost and the retry ends in the clipboard fallback.
    public mutating func retargetForRetry(_ newTarget: TargetApplicationSnapshot?) {
        target = newTarget
    }

    public mutating func recordRawTranscript(_ text: String) {
        rawTranscript = text
    }

    public mutating func recordFinalText(_ text: String) {
        finalText = text
    }

    public mutating func recordAIFallback(_ code: AIErrorCode) {
        fallbackReason = code
        aiCancelled = code == .aiCancelled
        // AI fallback is atomic at the job boundary. Once an AI error or
        // cancellation is accepted, the saved local transcript is the final
        // text selected for insertion. Keeping this in the aggregate prevents a
        // late network completion from observing an unset/incorrect final value.
        if let rawTranscript {
            finalText = rawTranscript
        }
    }
}

/// Per-job trigger options (product decision #5: Auto-send).
///
/// `autoSend` posts a Return key event after a successful Accessibility or
/// typed insertion. It is never applied after a clipboard fallback.
///
/// `aiActionID` (ADR-020, App Intents) names a saved AI action to run for
/// this job only. The controller applies it to the job's *settings snapshot*
/// at the start edge — the persisted default action is never touched — and,
/// like a Selection Action, treats the explicit request as consent to run AI
/// for that job even while the master switch is off. An id that matches no
/// usable action is ignored and the job runs with the default settings.
///
/// The struct is kept (rather than a bare `Bool`) so a per-job flag has a
/// home; the Append shortcut's `appendToPrevious` lived here until that feature
/// was removed on 2026-09-13.
public struct DictationStartOptions: Sendable, Equatable {
    public var autoSend: Bool
    public var aiActionID: UUID?

    public init(autoSend: Bool = false, aiActionID: UUID? = nil) {
        self.autoSend = autoSend
        self.aiActionID = aiActionID
    }
}

/// Destination of a job's final text.
public enum DictationDelivery: Sendable, Equatable {
    /// Normal dictation: Accessibility insertion into the recording-start
    /// application, with clipboard fallback.
    case insertIntoTarget
    /// Onboarding's first-dictation test: the result is handed back to the app
    /// shell for an in-app field. No AX resolution, no clipboard, no history.
    case inApp
}
