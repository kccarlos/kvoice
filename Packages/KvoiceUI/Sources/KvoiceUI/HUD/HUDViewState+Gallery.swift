import Foundation
import KvoiceDomain

extension HUDViewState {
    /// One state per row of the UI v2 recorder board that the app can
    /// actually reach, in the board's order, for the previews and
    /// `LayoutSnapshotTests.testRenderEveryHUDState`. The facts are sample
    /// values; the failure and warning reasons are the product's real
    /// sentences (`KVoiceErrorCode.userFacingMessage`), so the renders show
    /// how the actual copy fits. Never shown to a user.
    static var galleryStates: [(name: String, state: HUDViewState)] {
        let ai = HUDAIIndicator(isEnabled: true, actionName: "Clean Up", shortcutBadge: "⌘1")
        let facts = HUDJobFacts(
            modelName: "Whisper large-v3-turbo", aiActionName: "Clean Up", aiProviderName: "Local Ollama",
            targetAppName: "Notes", wordCount: 38
        )
        func recording(
            _ elapsed: Int, level: Double = 0.6, mode: RecordingInteraction = .pushToTalk,
            ai: HUDAIIndicator? = ai, captureStarted: Bool = true
        ) -> HUDPhase {
            .recording(HUDRecordingState(
                inputLevel: level, elapsed: .seconds(elapsed), mode: mode, ai: ai, captureStarted: captureStarted
            ))
        }
        func failed(_ code: KVoiceErrorCode, fatal: Bool = false) -> HUDPhase {
            .failed(HUDFailureState(
                code: code.rawValue, message: code.userFacingMessage, isFatal: fatal,
                settingsActionTitle: fatal ? "Open Model Settings" : nil
            ))
        }
        return [
            ("01-starting", HUDViewState(phase: recording(0, level: 0, captureStarted: false), facts: facts)),
            ("02-recording", HUDViewState(phase: recording(7), facts: facts)),
            ("03-recording-toggle", HUDViewState(phase: recording(21, mode: .toggle, ai: nil), facts: facts)),
            ("04-recording-live-text", HUDViewState(
                phase: recording(12, ai: nil),
                partialTranscript: "Let’s move the review to Thursday and send the deck to Maya",
                facts: facts
            )),
            ("04b-recording-live-chinese", HUDViewState(
                phase: recording(9, ai: nil),
                partialTranscript: "我们把设计评审改到星期四，然后把文稿发给玛雅",
                facts: facts
            )),
            ("05-recording-long", HUDViewState(phase: recording(312, ai: nil), facts: facts)),
            ("06-recording-finishing", HUDViewState(phase: recording(3, ai: nil), finishingCount: 1, facts: facts)),
            ("06b-recording-ai-off", HUDViewState(phase: recording(5, ai: HUDAIIndicator(isEnabled: false, actionName: "Clean Up", shortcutBadge: "⌘1")), facts: facts)),
            ("07-preparing", HUDViewState(phase: .finalizing, facts: facts)),
            ("08-transcribing", HUDViewState(phase: .transcribing, facts: facts)),
            ("09-polishing", HUDViewState(phase: .processingAI(HUDProcessingAIState(mode: .polish)), facts: facts)),
            ("09b-translating", HUDViewState(phase: .processingAI(HUDProcessingAIState(mode: .translate, targetLanguageDisplayName: "Japanese")), facts: facts)),
            ("09c-busy", HUDViewState(phase: .transcribing, busyHint: true, facts: facts)),
            ("10-inserting", HUDViewState(phase: .inserting, facts: facts)),
            ("11-inserted", HUDViewState(phase: .completed(HUDCompletionState(kind: .success)), facts: facts)),
            ("12-ai-unavailable", HUDViewState(phase: .completed(HUDCompletionState(
                kind: .aiFallback, warningMessage: KVoiceErrorCode.aiUnreachable.userFacingMessage, aiFallback: .aiUnreachable
            )), facts: facts)),
            ("13-copied", HUDViewState(phase: .completed(HUDCompletionState(
                kind: .clipboardFallback, warningMessage: KVoiceErrorCode.accessibilityNotEditable.userFacingMessage,
                clipboardReason: .notEditable
            )), facts: facts)),
            ("14-nothing-inserted", HUDViewState(phase: failed(.sttEmpty), facts: facts)),
            ("14b-nothing-inserted-long-reason", HUDViewState(phase: failed(.audioInterrupted), facts: facts)),
            ("15-transcript-kept", HUDViewState(
                phase: .failed(HUDFailureState(code: "insertion.failed", message: "The app lost focus before insertion")),
                recoverableTranscript: "Let’s move the design review to Thursday and send the deck to Maya.",
                canRecoverFailedInsertion: true,
                facts: facts
            )),
            ("16-model-unavailable", HUDViewState(phase: failed(.modelLoadFailed, fatal: true), facts: facts)),
            ("17-needs-attention", HUDViewState(phase: .blocked(HUDBlockedState(
                code: KVoiceErrorCode.permissionMicrophoneDenied.rawValue,
                message: KVoiceErrorCode.permissionMicrophoneDenied.userFacingMessage
            )), facts: facts)),
            ("17b-needs-attention-other", HUDViewState(phase: .blocked(HUDBlockedState(
                code: KVoiceErrorCode.modelNotInstalled.rawValue,
                message: KVoiceErrorCode.modelNotInstalled.userFacingMessage
            )), facts: facts))
        ]
    }
}
