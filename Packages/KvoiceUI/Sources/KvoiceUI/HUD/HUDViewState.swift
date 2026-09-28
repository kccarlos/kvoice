import Foundation
import KvoiceDomain

public struct HUDBlockedState: Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// ADR-021: what the recorder shows about the *current job's* AI settings
/// — the on/off indicator at its leading edge and the action that will run.
/// Rendered from the job's snapshot, so ⌘1–⌘0 and ⌘⇧A while recording change
/// it without touching the persisted settings.
public struct HUDAIIndicator: Equatable, Sendable {
    /// True when a request will actually be made after transcription (the
    /// snapshot's derived `mode != .off`), not merely when the switch is on.
    public let isEnabled: Bool
    /// The action that would run (the snapshot's default action), shown
    /// even while the switch is off so the user knows what ⌘⇧A would run.
    public let actionName: String?
    /// "⌘2"-style badge for `actionName`, by its saved position; nil beyond
    /// the tenth action.
    public let shortcutBadge: String?

    public init(isEnabled: Bool, actionName: String? = nil, shortcutBadge: String? = nil) {
        self.isEnabled = isEnabled
        self.actionName = actionName
        self.shortcutBadge = shortcutBadge
    }

    public var symbolName: String {
        isEnabled ? "sparkles" : "sparkles.slash"
    }

    /// One line for VoiceOver's value and the notch style's caption.
    public var accessibilityDescription: String {
        switch (isEnabled, actionName) {
        case (true, let name?):
            return String(localized: "AI on, \(name)", bundle: .module)
        case (true, nil):
            return String(localized: "AI on", bundle: .module)
        case (false, let name?):
            return String(localized: "AI off, \(name)", bundle: .module)
        case (false, nil):
            return String(localized: "AI off", bundle: .module)
        }
    }
}

public struct HUDRecordingState: Equatable, Sendable {
    /// D.5: an unobtrusive hint at 4:30, a warning at 5:00, and a hard stop
    /// at the user's limit (product decision #10; 10:00 by default) handled by
    /// the recorder.
    public static let longDictationHintAfter: Duration = .seconds(270)
    public static let longDictationWarningAfter: Duration = .seconds(300)

    public let inputLevel: Double
    public let elapsed: Duration
    public let mode: RecordingInteraction
    /// The recorder's ceiling for this job, for the warning line; nil for
    /// "No limit", which then omits the clock (the four-hour bound is a
    /// memory guard, not a feature).
    public let maximumDuration: Duration?
    /// ADR-021: the in-recorder AI controls' state; nil hides them (the
    /// onboarding in-app test, which never runs AI).
    public let ai: HUDAIIndicator?
    /// False until the first captured buffer with signal
    /// (`DictationController.Snapshot.captureStarted`, 2026-09-16): the
    /// input route may still be switching and nothing is being recorded,
    /// so the title reads "Starting mic…" instead of "Recording". The
    /// meter, the clock, and the controls are unchanged either way.
    public let captureStarted: Bool

    public init(
        inputLevel: Double = 0,
        elapsed: Duration = .zero,
        mode: RecordingInteraction = .pushToTalk,
        maximumDuration: Duration? = .seconds(600),
        ai: HUDAIIndicator? = nil,
        captureStarted: Bool = true
    ) {
        self.inputLevel = min(max(inputLevel, 0), 1)
        self.elapsed = elapsed
        self.mode = mode
        self.maximumDuration = maximumDuration
        self.ai = ai
        self.captureStarted = captureStarted
    }

    /// Length hint for the recording detail line, or nil under 4:30.
    public var lengthHint: String? {
        if elapsed >= Self.longDictationWarningAfter, let maximumDuration {
            return String(localized: "Long dictation — recording stops automatically at \(HUDViewState.formatElapsed(maximumDuration)).", bundle: .module)
        }
        if elapsed >= Self.longDictationHintAfter {
            return String(localized: "Long dictation — KVoice works best with shorter input.", bundle: .module)
        }
        return nil
    }
}

public struct HUDProcessingAIState: Equatable, Sendable {
    public let mode: AIMode
    public let targetLanguageDisplayName: String?

    public init(mode: AIMode, targetLanguageDisplayName: String? = nil) {
        self.mode = mode
        self.targetLanguageDisplayName = targetLanguageDisplayName
    }
}

public enum HUDCompletionKind: Equatable, Sendable {
    case success
    case aiFallback
    case clipboardFallback
}

public struct HUDCompletionState: Equatable, Sendable {
    public let kind: HUDCompletionKind
    public let warningMessage: String?
    /// True when the recording was stopped by the hard cap; the completion
    /// then keeps the longer warning timing even on a plain success.
    public let durationCapReached: Bool

    public init(kind: HUDCompletionKind, warningMessage: String? = nil, durationCapReached: Bool = false) {
        self.kind = kind
        self.warningMessage = warningMessage
        self.durationCapReached = durationCapReached
    }
}

/// ADR-022 item 6: the one-click recovery actions on a failure HUD that
/// retains the exact transcript. Render-only — the shell supplies the
/// closures (`HUDRecoveryActions`); the state only says which buttons exist
/// and what they are called, so tests and VoiceOver see the same labels.
public enum HUDRecoveryAction: String, Equatable, Sendable, CaseIterable, Identifiable {
    /// Writes the exact retained text to the pasteboard (the failure path
    /// may use the clipboard; FR-AX-009 is about the success path).
    case copy
    /// Re-runs the ordinary insertion tiers over the retained text into
    /// whatever is frontmost now.
    case insertAgain

    public var id: Self { self }

    public var title: String {
        switch self {
        case .copy: return String(localized: "Copy", bundle: .module)
        case .insertAgain: return String(localized: "Insert Again", bundle: .module)
        }
    }

    public var symbolName: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .insertAgain: return "text.insert"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .copy: return String(localized: "Copy transcript", bundle: .module)
        case .insertAgain: return String(localized: "Insert transcript again", bundle: .module)
        }
    }

    public var accessibilityHint: String {
        switch self {
        case .copy: return String(localized: "Copies the kept transcript to the clipboard.", bundle: .module)
        case .insertAgain: return String(localized: "Inserts the kept transcript into the app that is in front now.", bundle: .module)
        }
    }
}

public struct HUDFailureState: Equatable, Sendable {
    public let code: String
    public let message: String
    public let isFatal: Bool
    public let settingsActionTitle: String?

    public init(
        code: String,
        message: String,
        isFatal: Bool = false,
        settingsActionTitle: String? = nil
    ) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
        self.settingsActionTitle = settingsActionTitle
    }
}

public enum HUDPhase: Equatable, Sendable {
    case idle
    case blocked(HUDBlockedState)
    case recording(HUDRecordingState)
    case finalizing
    case transcribing
    case processingAI(HUDProcessingAIState)
    case inserting
    case completed(HUDCompletionState)
    case failed(HUDFailureState)

    /// The phase without its payload. The view animates and VoiceOver
    /// announces on this, not on the full phase, so a meter tick during
    /// recording is neither a layout transition nor an announcement.
    public var kind: HUDPhaseKind {
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
        }
    }
}

public enum HUDPhaseKind: String, Equatable, Sendable, CaseIterable {
    case idle, blocked, recording, finalizing, transcribing, processingAI, inserting, completed, failed
}

/// Colour semantics for the HUD symbol, named rather than coloured so the
/// mapping is testable and the view is the only place that picks a `Color`.
/// Accent while recording, secondary while working, green on success, orange
/// for anything the user should read, red only for a fatal model error.
public enum HUDSymbolTone: String, Equatable, Sendable {
    case neutral
    case accent
    case secondary
    case success
    case warning
    case fatal
}

/// Immutable, render-only state for the HUD. `partialTranscript` is retained
/// as a future streaming seam but is nil for the v1 Whisper flow and is never
/// rendered during recording. `recoverableTranscript` is only populated when
/// a clipboard fallback failed and the exact final text must remain available
/// until the user explicitly dismisses the warning.
public struct HUDViewState: Equatable, Sendable {
    public let phase: HUDPhase
    public let partialTranscript: String?
    public let recoverableTranscript: String?
    /// C.6: a shortcut press arrived while a job was still finishing. The
    /// processing HUD pulses "Finishing previous dictation" instead of queuing.
    public let busyHint: Bool
    /// ADR-022 item 6: the controller's `Snapshot.canRecoverFailedInsertion`
    /// — the one scalar that puts Copy / Insert Again on a failure (the
    /// status menu reads the same value). Kept only in `.failed`.
    public let canRecoverFailedInsertion: Bool
    /// ADR-022 item 7: jobs still finishing behind the one this state shows
    /// (`Snapshot.finishingCount`) — the "1 finishing" badge beside the
    /// title. Kept while recording and in the processing phases; 0 elsewhere
    /// and whenever overlapping jobs are off.
    public let finishingCount: Int
    /// ADR-022 item 7: the developer flag is on but the environment turned
    /// it off, and the press that would have overlapped got the busy pulse.
    /// The detail line says why, once. Kept in the processing phases only.
    public let overlapPausedReason: OverlapPauseReason?

    public init(
        phase: HUDPhase,
        partialTranscript: String? = nil,
        recoverableTranscript: String? = nil,
        busyHint: Bool = false,
        canRecoverFailedInsertion: Bool = false,
        finishingCount: Int = 0,
        overlapPausedReason: OverlapPauseReason? = nil
    ) {
        // ADR-017 (amending FR-STT-001): live partial text is shown only
        // while a streaming dictation is being captured or transcribed. Every
        // other phase drops it, so the final text is the only text a
        // completion or failure can show.
        switch phase {
        case .recording, .finalizing, .transcribing:
            self.partialTranscript = partialTranscript
        default:
            self.partialTranscript = nil
        }
        if case .failed = phase {
            self.recoverableTranscript = recoverableTranscript
            self.canRecoverFailedInsertion = canRecoverFailedInsertion && recoverableTranscript != nil
        } else {
            self.recoverableTranscript = nil
            self.canRecoverFailedInsertion = false
        }
        switch phase {
        case .finalizing, .transcribing, .processingAI, .inserting:
            self.busyHint = busyHint
            self.finishingCount = max(0, finishingCount)
            self.overlapPausedReason = overlapPausedReason
        case .recording:
            self.busyHint = false
            self.finishingCount = max(0, finishingCount)
            self.overlapPausedReason = nil
        default:
            self.busyHint = false
            self.finishingCount = 0
            self.overlapPausedReason = nil
        }
        self.phase = phase
    }

    /// ADR-022 item 7: the badge text beside the title while older jobs are
    /// still finishing behind this one, or nil when there are none.
    public var finishingBadge: String? {
        guard finishingCount > 0 else { return nil }
        return String(localized: "\(finishingCount) finishing", bundle: .module)
    }

    /// The one-line note for a press that could not overlap because the
    /// environment turned the flag off (ADR-022 item 7's safeties).
    public static func overlapPausedNote(_ reason: OverlapPauseReason) -> String {
        switch reason {
        case .memoryPressure:
            return String(localized: "Overlapping dictation paused: memory pressure", bundle: .module)
        case .cpuOnlyCompute:
            return String(localized: "Overlapping dictation paused: CPU-only compute", bundle: .module)
        case .slowTranscription:
            return String(localized: "Overlapping dictation paused: slow transcription", bundle: .module)
        }
    }

    public static let idle = Self(phase: .idle)

    /// The recovery buttons this state offers: both while the controller
    /// says the failed job is recoverable, none otherwise. Escape still
    /// dismisses.
    public var recoveryActions: [HUDRecoveryAction] {
        canRecoverFailedInsertion ? HUDRecoveryAction.allCases : []
    }

    public var isVisible: Bool {
        if case .idle = phase { return false }
        return true
    }

    public var title: String {
        switch phase {
        case .idle:
            return ""
        case .blocked:
            return String(localized: "KVoice needs attention", bundle: .module)
        case .recording(let state):
            return state.captureStarted
                ? String(localized: "Recording", bundle: .module)
                : String(localized: "Starting mic…", bundle: .module)
        case .finalizing:
            return String(localized: "Preparing audio", bundle: .module)
        case .transcribing:
            return String(localized: "Transcribing locally", bundle: .module)
        case .processingAI(let state):
            switch state.mode {
            case .polish:
                return String(localized: "Polishing", bundle: .module)
            case .translate:
                let language = state.targetLanguageDisplayName ?? String(localized: "target language", bundle: .module)
                return String(localized: "Translating to \(language)", bundle: .module)
            }
        case .inserting:
            return String(localized: "Inserting", bundle: .module)
        case .completed(let state):
            switch state.kind {
            case .success:
                return String(localized: "Inserted", bundle: .module)
            case .aiFallback:
                return String(localized: "Inserted local transcript; AI unavailable", bundle: .module)
            case .clipboardFallback:
                return String(localized: "Copied to clipboard", bundle: .module)
            }
        case .failed(let state):
            if recoverableTranscript != nil {
                return String(localized: "Not inserted — transcript kept", bundle: .module)
            }
            return state.isFatal ? String(localized: "Model unavailable", bundle: .module) : String(localized: "Nothing inserted", bundle: .module)
        }
    }

    /// The title as VoiceOver should read it: the visual "Starting mic…"
    /// becomes the full word, everything else is the title verbatim.
    public var accessibilityTitle: String {
        if case .recording(let state) = phase, !state.captureStarted {
            return String(localized: "Starting microphone", bundle: .module)
        }
        return title
    }

    public var detail: String? {
        switch phase {
        case .idle:
            return nil
        case .finalizing, .transcribing, .inserting, .processingAI:
            if let overlapPausedReason {
                return Self.overlapPausedNote(overlapPausedReason)
            }
            return busyHint ? String(localized: "Finishing previous dictation…", bundle: .module) : nil
        case .blocked(let state):
            return state.message
        case .recording(let state):
            // H5: the release/toggle instruction never disappears — the
            // long-dictation note is appended beside it, not swapped in.
            let instruction = state.mode == .pushToTalk
                ? String(localized: "Release to stop", bundle: .module)
                : String(localized: "Press again to stop", bundle: .module)
            if let hint = state.lengthHint {
                return String(localized: "\(instruction) · \(hint)", bundle: .module)
            }
            return instruction
        case .completed(let state):
            return state.warningMessage
        case .failed(let state):
            if recoverableTranscript != nil {
                // H6: the reason only — the two buttons below (Copy, Insert
                // Again) already say what they do; Escape is the third way
                // out.
                return state.message
            }
            if state.isFatal, let action = state.settingsActionTitle {
                return String(localized: "\(state.message) \(action).", bundle: .module)
            }
            return state.message
        }
    }

    public var symbolName: String {
        switch phase {
        case .idle:
            return "mic"
        case .blocked:
            return "exclamationmark.triangle"
        case .recording:
            return "waveform"
        case .finalizing, .transcribing, .processingAI, .inserting:
            return "ellipsis.circle"
        case .completed(let state):
            switch state.kind {
            case .success:
                return "checkmark.circle"
            case .aiFallback:
                // D.4: "Checkmark + warning".
                return "checkmark.circle.trianglebadge.exclamationmark"
            case .clipboardFallback:
                return "doc.on.clipboard"
            }
        case .failed(let state):
            return state.isFatal ? "xmark.octagon" : "exclamationmark.triangle"
        }
    }

    public var symbolTone: HUDSymbolTone {
        switch phase {
        case .idle:
            return .neutral
        case .recording:
            return .accent
        case .finalizing, .transcribing, .processingAI, .inserting:
            return .secondary
        case .completed(let state):
            return state.kind == .success ? .success : .warning
        case .blocked:
            return .warning
        case .failed(let state):
            return state.isFatal ? .fatal : .warning
        }
    }

    /// What VoiceOver should say when this state first appears, or nil for
    /// the intermediate spinner phases, which would only be noise between
    /// "Recording" and the outcome.
    public var accessibilityAnnouncement: String? {
        switch phase {
        case .idle, .finalizing, .transcribing, .processingAI, .inserting:
            return nil
        case .recording, .blocked, .completed, .failed:
            if let detail, !detail.isEmpty {
                return "\(accessibilityTitle). \(detail)"
            }
            return accessibilityTitle
        }
    }

    /// Elapsed recording time as m:ss ("0:07", "4:30", "10:00").
    public static func formatElapsed(_ elapsed: Duration) -> String {
        let totalSeconds = max(0, elapsed.components.seconds)
        return String(format: "%lld:%02lld", totalSeconds / 60, totalSeconds % 60)
    }

    public var showsActivityIndicator: Bool {
        switch phase {
        case .finalizing, .transcribing, .processingAI, .inserting:
            return true
        default:
            return false
        }
    }

    /// D.4 exit timings with the compiled table. Recoverable errors and
    /// blocked prerequisites are non-modal and auto-dismiss (FR-HUD-005); a
    /// fatal model error and a failed clipboard copy (whose transcript must
    /// stay selectable) do not.
    public var autoDismissAfter: Duration? {
        autoDismissAfter(timings: .compiled)
    }

    /// The same rule against the developer defaults the shell loaded
    /// (ADR-022 slice 5: `HUDController.dismissTimings`).
    public func autoDismissAfter(timings: HUDDismissTimings) -> Duration? {
        switch phase {
        case .completed(let state):
            switch state.kind {
            case .success:
                return state.durationCapReached ? timings.durationCapReached : timings.success
            case .aiFallback:
                return timings.aiFallback
            case .clipboardFallback:
                return timings.clipboardFallback
            }
        case .blocked:
            return timings.blocked
        case .failed(let state):
            if state.isFatal || recoverableTranscript != nil {
                return nil
            }
            return timings.failure
        default:
            return nil
        }
    }

    /// Projects the canonical domain state into a render-only HUD snapshot.
    /// The only transcript that crosses this boundary is exact final text that
    /// must remain recoverable after a clipboard write failure.
    public init(
        dictationState: DictationState,
        inputLevel: Double = 0,
        recordingMode: RecordingInteraction = .pushToTalk,
        translationTarget: TranslationLanguage? = nil,
        partialTranscript: String? = nil,
        recoverableTranscript: String? = nil,
        busyHint: Bool = false,
        maximumRecordingDuration: Duration? = .seconds(600),
        aiIndicator: HUDAIIndicator? = nil,
        canRecoverFailedInsertion: Bool = false,
        captureStarted: Bool = true,
        finishingCount: Int = 0,
        overlapPausedReason: OverlapPauseReason? = nil
    ) {
        switch dictationState {
        case .idle, .terminating:
            self.init(phase: .idle)
        case .blocked(let reason):
            self.init(
                phase: .blocked(HUDBlockedState(code: reason.code, message: DomainCopy.localized(reason.message)))
            )
        case .recording(let recording):
            self.init(
                phase: .recording(
                    HUDRecordingState(
                        inputLevel: inputLevel,
                        elapsed: recording.elapsed,
                        mode: recordingMode,
                        maximumDuration: maximumRecordingDuration,
                        ai: aiIndicator,
                        captureStarted: captureStarted
                    )
                ),
                partialTranscript: partialTranscript,
                finishingCount: finishingCount
            )
        case .finalizing:
            self.init(
                phase: .finalizing, partialTranscript: partialTranscript, busyHint: busyHint,
                finishingCount: finishingCount, overlapPausedReason: overlapPausedReason
            )
        case .transcribing:
            self.init(
                phase: .transcribing, partialTranscript: partialTranscript, busyHint: busyHint,
                finishingCount: finishingCount, overlapPausedReason: overlapPausedReason
            )
        case .processingAI(_, let mode):
            self.init(
                phase: .processingAI(
                    HUDProcessingAIState(
                        mode: mode,
                        targetLanguageDisplayName: translationTarget.map { DomainCopy.localized($0.displayName) }
                    )
                ),
                partialTranscript: partialTranscript,
                busyHint: busyHint,
                finishingCount: finishingCount,
                overlapPausedReason: overlapPausedReason
            )
        case .inserting:
            self.init(
                phase: .inserting, partialTranscript: partialTranscript, busyHint: busyHint,
                finishingCount: finishingCount, overlapPausedReason: overlapPausedReason
            )
        case .completed(_, let summary):
            let kind: HUDCompletionKind
            switch summary.insertion {
            case .inserted, .deliveredInApp, .abortedAtTermination:
                kind = summary.aiFallback == nil ? .success : .aiFallback
            case .copiedToClipboard:
                kind = .clipboardFallback
            }
            self.init(
                phase: .completed(
                    HUDCompletionState(
                        kind: kind,
                        warningMessage: summary.warningMessage.map { DomainCopy.localized($0) },
                        durationCapReached: summary.durationCapReached
                    )
                ),
                partialTranscript: partialTranscript
            )
        case .failed(_, let failure):
            let fatalModelCodes: Set<String> = [
                KVoiceErrorCode.modelNotInstalled.rawValue,
                KVoiceErrorCode.modelIntegrityFailed.rawValue,
                KVoiceErrorCode.modelIncompatible.rawValue,
                KVoiceErrorCode.modelPathUnreadable.rawValue,
                KVoiceErrorCode.modelLoadFailed.rawValue,
                KVoiceErrorCode.modelOfflineAssetMissing.rawValue,
                KVoiceErrorCode.modelRuntimeNetworkAttempt.rawValue
            ]
            let fatal = fatalModelCodes.contains(failure.code)
            self.init(
                phase: .failed(
                    HUDFailureState(
                        code: failure.code,
                        message: DomainCopy.localized(failure.message),
                        isFatal: fatal,
                        settingsActionTitle: fatal ? String(localized: "Open Model Settings", bundle: .module) : nil
                    )
                ),
                partialTranscript: partialTranscript,
                recoverableTranscript: recoverableTranscript,
                canRecoverFailedInsertion: canRecoverFailedInsertion
            )
        }
    }
}
