import AppKit
import XCTest
@testable import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceUI

@MainActor
final class HUDViewStateTests: XCTestCase {
    func testAllPRDPhasesHaveSafeUserFacingCopy() {
        let phases: [HUDPhase] = [
            .idle,
            .blocked(HUDBlockedState(code: "MODEL-NOT-INSTALLED", message: "Install a model.")),
            .recording(HUDRecordingState(inputLevel: 0.4, elapsed: .seconds(3))),
            .finalizing,
            .transcribing,
            .processingAI(HUDProcessingAIState(mode: .polish)),
            .processingAI(HUDProcessingAIState(mode: .translate, targetLanguageDisplayName: "Chinese")),
            .inserting,
            .completed(HUDCompletionState(kind: .success)),
            .completed(HUDCompletionState(kind: .aiFallback)),
            .completed(HUDCompletionState(kind: .clipboardFallback)),
            .failed(HUDFailureState(code: "AI-TIMEOUT", message: "AI did not respond.")),
            .failed(HUDFailureState(
                code: "MODEL-LOAD-FAILED",
                message: "The local model is unavailable.",
                isFatal: true,
                settingsActionTitle: "Open Model Settings"
            ))
        ]

        for phase in phases {
            let state = HUDViewState(phase: phase)
            if case .idle = phase {
                XCTAssertFalse(state.isVisible)
                XCTAssertEqual(state.title, "")
            } else {
                XCTAssertTrue(state.isVisible)
                XCTAssertFalse(state.title.isEmpty)
                XCTAssertFalse(state.symbolName.isEmpty)
            }
        }

        XCTAssertEqual(
            HUDViewState(phase: .processingAI(
                HUDProcessingAIState(mode: .translate, targetLanguageDisplayName: "Chinese")
            )).title,
            "Translating to Chinese"
        )
    }

    /// ADR-017 amends FR-STT-001: a streaming dictation may show its live
    /// partial while recording, finalizing, and transcribing; every other
    /// phase drops it so an outcome never shows anything but final text.
    func testPartialTranscriptSurvivesOnlyTheStreamingPhases() {
        let partial = "live words"
        for phase in [HUDPhase.recording(HUDRecordingState()), .finalizing, .transcribing] {
            XCTAssertEqual(HUDViewState(phase: phase, partialTranscript: partial).partialTranscript, partial)
        }
        XCTAssertEqual(HUDViewState(phase: .recording(HUDRecordingState()), partialTranscript: "").partialTranscript, "")
        for phase in [
            HUDPhase.processingAI(HUDProcessingAIState(mode: .polish)),
            .inserting,
            .completed(HUDCompletionState(kind: .success)),
            .failed(HUDFailureState(code: "x", message: "y")),
            .blocked(HUDBlockedState(code: "x", message: "y")),
            .idle
        ] {
            XCTAssertNil(HUDViewState(phase: phase, partialTranscript: partial).partialTranscript, "\(phase)")
        }

        // The domain projection passes it through for recording, and the
        // meter filter keeps it while it coalesces the level.
        let projected = HUDViewState(
            dictationState: .recording(RecordingState(jobID: UUID(), elapsed: .seconds(2))),
            partialTranscript: partial
        )
        XCTAssertEqual(projected.partialTranscript, partial)
        var filter = HUDRecordingFeedbackFilter()
        let now = ContinuousClock.now
        XCTAssertEqual(filter.apply(projected, now: now).partialTranscript, partial)
        let inside = HUDViewState(
            dictationState: .recording(RecordingState(jobID: UUID(), elapsed: .seconds(2))),
            partialTranscript: partial + " more"
        )
        XCTAssertEqual(filter.apply(inside, now: now + .milliseconds(10)).partialTranscript, partial + " more")
    }

    func testRecordingShowsMeterAndElapsed() {
        let state = HUDViewState(
            phase: .recording(HUDRecordingState(
                inputLevel: 2,
                elapsed: .seconds(65),
                mode: .pushToTalk
            ))
        )

        XCTAssertEqual(state.title, "Recording")
        XCTAssertEqual(state.detail, "Release to stop")
        if case .recording(let recording) = state.phase {
            XCTAssertEqual(recording.inputLevel, 1)
            XCTAssertEqual(recording.elapsed, .seconds(65))
        } else {
            XCTFail("expected recording phase")
        }
    }

    func testCompletionDismissDurationsMatchPRD() {
        XCTAssertEqual(
            HUDViewState(phase: .completed(HUDCompletionState(kind: .success))).autoDismissAfter,
            .milliseconds(900)
        )
        XCTAssertEqual(
            HUDViewState(phase: .completed(HUDCompletionState(kind: .aiFallback))).autoDismissAfter,
            .milliseconds(2_500)
        )
        XCTAssertEqual(
            HUDViewState(phase: .completed(HUDCompletionState(kind: .clipboardFallback))).autoDismissAfter,
            .milliseconds(3_500)
        )
    }

    func testDomainProjectionMapsClipboardAndFatalStates() {
        let jobID = UUID()
        let clipboard = DictationState.completed(
            jobID,
            CompletionSummary(
                insertion: .copiedToClipboard(reason: .targetApplicationChanged),
                warningMessage: "Text was copied to the clipboard."
            )
        )
        let clipboardState = HUDViewState(dictationState: clipboard)
        XCTAssertEqual(clipboardState.title, "Copied to clipboard")
        XCTAssertEqual(clipboardState.detail, "Text was copied to the clipboard.")

        let fatal = DictationState.failed(
            jobID,
            UserFacingFailure(code: .modelLoadFailed, message: "Model unavailable")
        )
        let fatalState = HUDViewState(dictationState: fatal)
        XCTAssertEqual(fatalState.title, "Model unavailable")
        if case .failed(let failure) = fatalState.phase {
            XCTAssertTrue(failure.isFatal)
            XCTAssertEqual(failure.settingsActionTitle, "Open Model Settings")
        } else {
            XCTFail("expected failed phase")
        }
    }

    func testClipboardFailureProjectionRetainsSelectableTranscriptWithoutDismissal() {
        let jobID = UUID()
        let failed = DictationState.failed(
            jobID,
            UserFacingFailure(code: .clipboardWriteFailed)
        )

        let state = HUDViewState(
            dictationState: failed,
            recoverableTranscript: "exact final text"
        )

        XCTAssertEqual(state.recoverableTranscript, "exact final text")
        XCTAssertEqual(state.title, "Not inserted — transcript kept")
        // H6: the reason only — the Copy / Insert Again buttons say the rest.
        XCTAssertEqual(state.detail, KVoiceErrorCode.clipboardWriteFailed.userFacingMessage)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.autoDismissAfter)
    }

    /// ADR-022 item 6: the failure that keeps the transcript offers Copy and
    /// Insert Again — and only that state does.
    func testRecoverableFailureExposesCopyAndInsertAgainWithVoiceOverLabels() {
        let jobID = UUID()
        let recoverable = HUDViewState(
            dictationState: .failed(jobID, UserFacingFailure(code: .accessibilityVerifyFailed)),
            recoverableTranscript: "exact final text",
            canRecoverFailedInsertion: true
        )
        XCTAssertEqual(recoverable.recoveryActions, [.copy, .insertAgain])
        // The controller's scalar is the gate, not the transcript's presence:
        // a kept transcript the controller will not act on shows no buttons.
        let notRecoverable = HUDViewState(
            dictationState: .failed(jobID, UserFacingFailure(code: .accessibilityVerifyFailed)),
            recoverableTranscript: "exact final text",
            canRecoverFailedInsertion: false
        )
        XCTAssertTrue(notRecoverable.recoveryActions.isEmpty)
        XCTAssertEqual(notRecoverable.recoverableTranscript, "exact final text", "the transcript is still shown")
        XCTAssertEqual(HUDRecoveryAction.copy.title, "Copy")
        XCTAssertEqual(HUDRecoveryAction.insertAgain.title, "Insert Again")
        XCTAssertEqual(HUDRecoveryAction.copy.accessibilityLabel, "Copy transcript")
        XCTAssertEqual(HUDRecoveryAction.insertAgain.accessibilityLabel, "Insert transcript again")
        for action in HUDRecoveryAction.allCases {
            XCTAssertFalse(action.accessibilityHint.isEmpty)
            XCTAssertFalse(action.symbolName.isEmpty)
        }
        XCTAssertNil(recoverable.autoDismissAfter, "the buttons need the panel to stay")

        // No transcript to recover: no buttons, and the failure auto-dismisses as before.
        let bare = HUDViewState(dictationState: .failed(jobID, UserFacingFailure(code: .sttEmpty)), canRecoverFailedInsertion: true)
        XCTAssertTrue(bare.recoveryActions.isEmpty, "no transcript, nothing to act on whatever the flag says")
        // A transcript handed to a non-failed phase is dropped, buttons with it.
        let completed = HUDViewState(
            dictationState: .completed(jobID, CompletionSummary(insertion: .inserted(method: .selectedTextAttribute))),
            recoverableTranscript: "ignored",
            canRecoverFailedInsertion: true
        )
        XCTAssertTrue(completed.recoveryActions.isEmpty)
        XCTAssertFalse(completed.canRecoverFailedInsertion)
        XCTAssertNil(completed.recoverableTranscript)
        let fatal = HUDViewState(
            dictationState: .failed(jobID, UserFacingFailure(code: .modelLoadFailed)),
            recoverableTranscript: "kept",
            canRecoverFailedInsertion: true
        )
        XCTAssertEqual(fatal.recoveryActions, [.copy, .insertAgain], "a kept transcript is recoverable whatever the failure code")
    }

    func testControllerPassesTheRecoveryHandlersToTheHostedViewAndAcceptsFirstMouse() {
        let controller = HUDController(announce: { _ in })
        var performed: [HUDRecoveryAction] = []
        controller.recoveryActions = HUDRecoveryActions { performed.append($0) }
        let state = HUDViewState(
            dictationState: .failed(UUID(), UserFacingFailure(code: .accessibilityVerifyFailed)),
            recoverableTranscript: "kept",
            canRecoverFailedInsertion: true
        )
        controller.show(state)
        let hosting = controller.panel?.contentView as? HUDHostingView
        XCTAssertNotNil(hosting, "the HUD is hosted by the first-mouse-accepting view")
        XCTAssertEqual(hosting?.acceptsFirstMouse(for: nil), true, "a click on a button must not be spent activating a panel that cannot become key")
        XCTAssertEqual(controller.panel?.ignoresMouseEvents, false, "the recovery state takes mouse input")
        hosting?.rootView.recoveryActions?.perform(.insertAgain)
        hosting?.rootView.recoveryActions?.perform(.copy)
        XCTAssertEqual(performed, [.insertAgain, .copy])
        controller.dismiss()
        XCTAssertEqual(controller.panel?.ignoresMouseEvents, true)
    }

    func testPanelIsNonActivatingAndJoinsSpaces() {
        let panel = HUDPanel()
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.transient))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
    }

    // MARK: - D.4 completion variants

    func testAIFallbackCompletionProjectsWarningStateFromSummaryContext() {
        let summary = CompletionSummary(insertion: .inserted(method: .selectedTextAttribute))
            .attaching(aiFallback: .aiTimeout, durationCapReached: false)
        let state = HUDViewState(dictationState: .completed(UUID(), summary))

        XCTAssertEqual(state.title, "Inserted local transcript; AI unavailable")
        XCTAssertEqual(state.detail, KVoiceErrorCode.aiTimeout.userFacingMessage)
        XCTAssertEqual(state.autoDismissAfter, .milliseconds(2_500))
    }

    func testPlainSuccessStaysSuccessWithoutFallbackContext() {
        let summary = CompletionSummary(insertion: .inserted(method: .selectedTextAttribute))
            .attaching(aiFallback: nil, durationCapReached: false)
        let state = HUDViewState(dictationState: .completed(UUID(), summary))

        XCTAssertEqual(state.title, "Inserted")
        XCTAssertNil(state.detail)
        XCTAssertEqual(state.autoDismissAfter, .milliseconds(900))
    }

    func testDurationCapCompletionKeepsWarningTiming() {
        let summary = CompletionSummary(insertion: .inserted(method: .selectedTextAttribute))
            .attaching(aiFallback: nil, durationCapReached: true)
        let state = HUDViewState(dictationState: .completed(UUID(), summary))

        XCTAssertEqual(state.title, "Inserted")
        XCTAssertEqual(state.detail, "Recording stopped at the 10-minute limit.")
        XCTAssertEqual(state.autoDismissAfter, .milliseconds(3_500))
    }

    func testClipboardReasonCopyIsSpecific() {
        let jobID = UUID()
        let next = try! DictationReducer.reduce(
            .inserting(jobID),
            event: .insertionFallback(jobID: jobID, outcome: .copiedToClipboard(reason: .secureTarget))
        )
        let state = HUDViewState(dictationState: next)
        XCTAssertEqual(state.title, "Copied to clipboard")
        XCTAssertEqual(state.detail, KVoiceErrorCode.accessibilitySecureTarget.userFacingMessage)
    }

    // MARK: - Failure and blocked copy

    func testRecoverableFailureUsesPlainLanguageAndAutoDismisses() {
        let state = HUDViewState(
            dictationState: .failed(UUID(), UserFacingFailure(code: .sttEmpty))
        )
        XCTAssertEqual(state.title, "Nothing inserted")
        XCTAssertEqual(state.detail, KVoiceErrorCode.sttEmpty.userFacingMessage)
        XCTAssertFalse(state.detail?.contains("STT-") ?? true)
        XCTAssertEqual(state.autoDismissAfter, .milliseconds(3_500))
    }

    func testFatalModelFailureDoesNotAutoDismiss() {
        let state = HUDViewState(
            dictationState: .failed(UUID(), UserFacingFailure(code: .modelLoadFailed))
        )
        XCTAssertEqual(state.title, "Model unavailable")
        XCTAssertNil(state.autoDismissAfter)
    }

    func testBlockedStateAutoDismissesAndShowsReason() {
        let state = HUDViewState(dictationState: .blocked(.microphonePermission))
        XCTAssertEqual(state.title, "KVoice needs attention")
        XCTAssertEqual(state.detail, BlockReason.microphonePermission.message)
        XCTAssertEqual(state.autoDismissAfter, .milliseconds(3_500))
    }

    // MARK: - D.5 recording hints and C.6 busy pulse

    func testRecordingDetailShowsLengthHintsAtFourThirtyAndFive() {
        let jobID = UUID()
        func detail(at seconds: Int) -> String? {
            HUDViewState(
                dictationState: .recording(RecordingState(jobID: jobID, elapsed: .seconds(seconds)))
            ).detail
        }
        XCTAssertEqual(detail(at: 10), "Release to stop")
        // H5: appended to the release instruction, never replacing it.
        XCTAssertEqual(detail(at: 270), "Release to stop · Long dictation — KVoice works best with shorter input.")
        XCTAssertEqual(detail(at: 300), "Release to stop · Long dictation — recording stops automatically at 10:00.")
    }

    func testBusyHintOnlyAppliesToProcessingPhases() {
        let jobID = UUID()
        let transcribing = HUDViewState(dictationState: .transcribing(jobID), busyHint: true)
        XCTAssertEqual(transcribing.detail, "Finishing previous dictation…")

        let recording = HUDViewState(
            dictationState: .recording(RecordingState(jobID: jobID)),
            busyHint: true
        )
        XCTAssertFalse(recording.busyHint)
        XCTAssertEqual(recording.detail, "Release to stop")
    }

    // MARK: - Overlapping jobs (ADR-022 item 7)

    func testFinishingBadgeShowsWhileRecordingAndProcessingOnly() {
        let jobID = UUID()
        let recording = HUDViewState(
            dictationState: .recording(RecordingState(jobID: jobID)),
            finishingCount: 1
        )
        XCTAssertEqual(recording.finishingCount, 1)
        XCTAssertEqual(recording.finishingBadge, "1 finishing")
        XCTAssertEqual(recording.title, "Recording", "the badge sits beside the title, not in it")

        let transcribing = HUDViewState(dictationState: .transcribing(jobID), finishingCount: 2)
        XCTAssertEqual(transcribing.finishingBadge, "2 finishing")
        XCTAssertNil(transcribing.detail, "a badge is not the busy hint")

        let none = HUDViewState(dictationState: .transcribing(jobID))
        XCTAssertNil(none.finishingBadge)
        let completed = HUDViewState(
            dictationState: .completed(jobID, CompletionSummary(insertion: .inserted(method: .selectedTextAttribute))),
            finishingCount: 1
        )
        XCTAssertEqual(completed.finishingCount, 0, "a terminal state never carries the badge")
        XCTAssertNil(completed.finishingBadge)
        XCTAssertEqual(HUDViewState(phase: .inserting, finishingCount: -3).finishingCount, 0)
    }

    func testOverlapPausedNoteReplacesTheBusyHintInProcessingPhasesOnly() {
        let jobID = UUID()
        let paused = HUDViewState(
            dictationState: .transcribing(jobID),
            busyHint: true,
            overlapPausedReason: .memoryPressure
        )
        XCTAssertEqual(paused.detail, "Overlapping dictation paused: memory pressure")
        XCTAssertEqual(
            HUDViewState(dictationState: .inserting(jobID), overlapPausedReason: .cpuOnlyCompute).detail,
            "Overlapping dictation paused: CPU-only compute"
        )
        XCTAssertEqual(
            HUDViewState(dictationState: .finalizing(jobID), overlapPausedReason: .slowTranscription).detail,
            "Overlapping dictation paused: slow transcription"
        )
        let recording = HUDViewState(
            dictationState: .recording(RecordingState(jobID: jobID)),
            overlapPausedReason: .memoryPressure
        )
        XCTAssertNil(recording.overlapPausedReason, "the note belongs to the processing HUD the pulse lands on")
        XCTAssertEqual(recording.detail, "Release to stop")
        for reason in OverlapPauseReason.allCases {
            XCTAssertFalse(HUDViewState.overlapPausedNote(reason).isEmpty)
        }
    }

    func testInAppDeliveryProjectsAsSuccess() {
        let state = HUDViewState(
            dictationState: .completed(UUID(), CompletionSummary(insertion: .deliveredInApp))
        )
        XCTAssertEqual(state.title, "Inserted")
    }

    // MARK: - Symbol tones, elapsed format, announcements

    func testSymbolToneFollowsColourSemantics() {
        XCTAssertEqual(HUDViewState(phase: .recording(HUDRecordingState())).symbolTone, .accent)
        XCTAssertEqual(HUDViewState(phase: .transcribing).symbolTone, .secondary)
        XCTAssertEqual(HUDViewState(phase: .processingAI(HUDProcessingAIState(mode: .polish))).symbolTone, .secondary)
        XCTAssertEqual(HUDViewState(phase: .completed(HUDCompletionState(kind: .success))).symbolTone, .success)
        XCTAssertEqual(HUDViewState(phase: .completed(HUDCompletionState(kind: .aiFallback))).symbolTone, .warning)
        XCTAssertEqual(HUDViewState(phase: .completed(HUDCompletionState(kind: .clipboardFallback))).symbolTone, .warning)
        XCTAssertEqual(HUDViewState(phase: .blocked(HUDBlockedState(code: "x", message: "y"))).symbolTone, .warning)
        XCTAssertEqual(HUDViewState(phase: .failed(HUDFailureState(code: "x", message: "y"))).symbolTone, .warning)
        XCTAssertEqual(
            HUDViewState(phase: .failed(HUDFailureState(code: "x", message: "y", isFatal: true))).symbolTone,
            .fatal
        )
    }

    func testElapsedFormatsAsMinutesAndSeconds() {
        XCTAssertEqual(HUDViewState.formatElapsed(.zero), "0:00")
        XCTAssertEqual(HUDViewState.formatElapsed(.seconds(7)), "0:07")
        XCTAssertEqual(HUDViewState.formatElapsed(.milliseconds(65_900)), "1:05")
        XCTAssertEqual(HUDViewState.formatElapsed(.seconds(600)), "10:00")
        XCTAssertEqual(HUDViewState.formatElapsed(.seconds(-3)), "0:00")
    }

    func testOnlyOutcomePhasesAnnounce() {
        XCTAssertEqual(HUDViewState(phase: .recording(HUDRecordingState())).accessibilityAnnouncement, "Recording. Release to stop")
        XCTAssertNil(HUDViewState(phase: .finalizing).accessibilityAnnouncement)
        XCTAssertNil(HUDViewState(phase: .transcribing).accessibilityAnnouncement)
        XCTAssertNil(HUDViewState(phase: .inserting).accessibilityAnnouncement)
        XCTAssertEqual(HUDViewState(phase: .completed(HUDCompletionState(kind: .success))).accessibilityAnnouncement, "Inserted")
        XCTAssertNotNil(HUDViewState(phase: .blocked(HUDBlockedState(code: "x", message: "Install a model."))).accessibilityAnnouncement)
    }

    // MARK: - Starting mic (2026-09-16)

    /// From key-down until the first captured buffer with signal the HUD
    /// says the microphone is starting; the projection from the controller
    /// snapshot carries the flag and the filter never drops it.
    func testStartingMicIsARecordingStateWithItsOwnTitleAndAccessibilityLabel() {
        let jobID = UUID()
        let starting = HUDViewState(
            dictationState: .recording(RecordingState(jobID: jobID, elapsed: .zero)),
            inputLevel: 0,
            captureStarted: false
        )
        guard case .recording(let startingState) = starting.phase else { return XCTFail("still a recording phase") }
        XCTAssertFalse(startingState.captureStarted)
        XCTAssertEqual(starting.title, "Starting mic…")
        XCTAssertEqual(starting.accessibilityTitle, "Starting microphone")
        XCTAssertEqual(starting.detail, "Release to stop", "the way out is unchanged")
        XCTAssertEqual(starting.accessibilityAnnouncement, "Starting microphone. Release to stop")
        XCTAssertEqual(startingState.inputLevel, 0)
        XCTAssertEqual(startingState.elapsed, .zero)
        XCTAssertEqual(starting.symbolTone, .accent, "same tone family; the view draws the dot hollow")

        let live = HUDViewState(
            dictationState: .recording(RecordingState(jobID: jobID, elapsed: .seconds(2))),
            inputLevel: 0.5,
            captureStarted: true
        )
        guard case .recording(let liveState) = live.phase else { return XCTFail("recording") }
        XCTAssertTrue(liveState.captureStarted)
        XCTAssertEqual(live.title, "Recording")
        XCTAssertEqual(live.accessibilityTitle, "Recording")
        XCTAssertEqual(live.accessibilityAnnouncement, "Recording. Release to stop")
        XCTAssertEqual(liveState.elapsed, .seconds(2))
        XCTAssertNotEqual(starting, live)
        XCTAssertEqual(starting.phase.kind, live.phase.kind, "not a phase change: no cross-fade, no re-announce of the panel")

        // The default keeps every existing construction site live.
        XCTAssertTrue(HUDRecordingState().captureStarted)
        XCTAssertEqual(HUDViewState(dictationState: .recording(RecordingState(jobID: jobID))).title, "Recording")

        // The filter carries the flag through both of its paths.
        var filter = HUDRecordingFeedbackFilter()
        let now = ContinuousClock.now
        let held = filter.apply(starting, now: now)
        guard case .recording(let heldState) = held.phase else { return XCTFail("recording") }
        XCTAssertFalse(heldState.captureStarted)
        let inside = filter.apply(live, now: now + .milliseconds(10))
        guard case .recording(let insideState) = inside.phase else { return XCTFail("recording") }
        XCTAssertTrue(insideState.captureStarted, "inside the meter budget the flag still flips at once")
        let settled = filter.apply(live, now: now + .milliseconds(100))
        guard case .recording(let settledState) = settled.phase else { return XCTFail("recording") }
        XCTAssertTrue(settledState.captureStarted)
    }

    func testPhaseKindIgnoresPayload() {
        let quiet = HUDViewState(phase: .recording(HUDRecordingState(inputLevel: 0.1, elapsed: .seconds(1))))
        let loud = HUDViewState(phase: .recording(HUDRecordingState(inputLevel: 0.9, elapsed: .seconds(2))))
        XCTAssertNotEqual(quiet, loud)
        XCTAssertEqual(quiet.phase.kind, loud.phase.kind)
    }

    // MARK: - D.5 recording feedback filter

    private func recording(level: Double, seconds: Double = 0) -> HUDViewState {
        HUDViewState(phase: .recording(HUDRecordingState(
            inputLevel: level,
            elapsed: .seconds(seconds)
        )))
    }

    private func level(of state: HUDViewState) -> Double {
        if case .recording(let recording) = state.phase { return recording.inputLevel }
        XCTFail("expected recording")
        return -1
    }

    func testFilterCoalescesMeterUpdatesToTwentyHertz() {
        var filter = HUDRecordingFeedbackFilter()
        let start = ContinuousClock.now
        let first = filter.apply(recording(level: 1.0), now: start)
        let tooSoon = filter.apply(recording(level: 0.0), now: start + .milliseconds(20))
        XCTAssertEqual(tooSoon, first, "an update inside the 50 ms budget repeats the last output")
        let later = filter.apply(recording(level: 0.0), now: start + .milliseconds(60))
        XCTAssertNotEqual(later, first)
    }

    func testFilterSmoothsWithFastAttackAndSlowRelease() {
        var filter = HUDRecordingFeedbackFilter()
        var now = ContinuousClock.now
        let rise = level(of: filter.apply(recording(level: 1.0), now: now))
        XCTAssertGreaterThan(rise, 0.5, "attack reaches more than half of a full-scale step in one update")
        XCTAssertLessThan(rise, 1.0, "but does not jump straight to the raw value")

        now += .milliseconds(60)
        let fall = level(of: filter.apply(recording(level: 0.0), now: now))
        XCTAssertGreaterThan(fall, rise * 0.7, "release keeps most of the level on the first silent update")
        XCTAssertLessThan(fall, rise)
    }

    func testFilterSettlesToAStableStateSoRendersCanBeSkipped() {
        var filter = HUDRecordingFeedbackFilter()
        var now = ContinuousClock.now
        _ = filter.apply(recording(level: 1.0), now: now)
        var previous: HUDViewState?
        var repeats = 0
        for _ in 0..<80 {
            now += .milliseconds(60)
            let output = filter.apply(recording(level: 0.0), now: now)
            if output == previous { repeats += 1 }
            previous = output
        }
        XCTAssertEqual(level(of: previous!), 0, "the decay reaches exactly zero rather than an asymptote")
        XCTAssertGreaterThan(repeats, 40, "once settled, consecutive outputs are equal")
    }

    func testFilterQuantisesElapsedToWholeSecondsAndResetsOutsideRecording() {
        var filter = HUDRecordingFeedbackFilter()
        var now = ContinuousClock.now
        let a = filter.apply(recording(level: 0, seconds: 3.2), now: now)
        now += .milliseconds(60)
        let b = filter.apply(recording(level: 0, seconds: 3.9), now: now)
        XCTAssertEqual(a, b, "sub-second elapsed changes do not produce a new render state")

        let transcribing = filter.apply(HUDViewState(phase: .transcribing), now: now)
        XCTAssertEqual(transcribing.phase, .transcribing)
        now += .milliseconds(60)
        let fresh = level(of: filter.apply(recording(level: 1.0), now: now))
        XCTAssertGreaterThan(fresh, 0, "a new recording starts from a reset filter")
    }

    // MARK: - ADR-021: in-recorder AI controls

    func testRecordingStateCarriesTheAIIndicatorAndOnlyWhileRecording() {
        let indicator = HUDAIIndicator(isEnabled: true, actionName: "Polish", shortcutBadge: "⌘1")
        let state = HUDViewState(
            dictationState: .recording(RecordingState(jobID: UUID(), elapsed: .seconds(2))),
            aiIndicator: indicator
        )
        guard case .recording(let recording) = state.phase else { return XCTFail("expected recording") }
        XCTAssertEqual(recording.ai, indicator)
        XCTAssertEqual(indicator.symbolName, "sparkles")
        XCTAssertEqual(HUDAIIndicator(isEnabled: false).symbolName, "sparkles.slash")
        XCTAssertEqual(indicator.accessibilityDescription, "AI on, Polish")
        XCTAssertEqual(HUDAIIndicator(isEnabled: false, actionName: "Shout").accessibilityDescription, "AI off, Shout")
        XCTAssertEqual(HUDAIIndicator(isEnabled: false).accessibilityDescription, "AI off")

        // The indicator is recording-only; the projection has nowhere to put
        // it for any other phase, and the announcement copy is unchanged.
        XCTAssertEqual(state.accessibilityAnnouncement, "Recording. Release to stop")
        let absent = HUDViewState(dictationState: .recording(RecordingState(jobID: UUID(), elapsed: .zero)))
        if case .recording(let recording) = absent.phase {
            XCTAssertNil(recording.ai, "no indicator unless the shell supplies one (the onboarding test)")
        }
    }

    func testFilterCarriesTheAIIndicatorAndDurationLimitThroughBothBranches() {
        var filter = HUDRecordingFeedbackFilter()
        let start = ContinuousClock.now
        let on = HUDAIIndicator(isEnabled: true, actionName: "Polish", shortcutBadge: "⌘1")
        let off = HUDAIIndicator(isEnabled: false, actionName: "Polish", shortcutBadge: "⌘1")
        func state(_ ai: HUDAIIndicator) -> HUDViewState {
            HUDViewState(phase: .recording(HUDRecordingState(inputLevel: 0.5, elapsed: .seconds(1), maximumDuration: nil, ai: ai)))
        }

        let first = filter.apply(state(on), now: start)
        // A key press lands inside the 50 ms meter budget: the meter is held,
        // the indicator is not.
        let toggled = filter.apply(state(off), now: start + .milliseconds(10))
        guard case .recording(let a) = first.phase, case .recording(let b) = toggled.phase else {
            return XCTFail("expected recording")
        }
        XCTAssertEqual(a.ai, on)
        XCTAssertEqual(b.ai, off, "the indicator must not wait for the next meter tick")
        XCTAssertEqual(b.inputLevel, a.inputLevel, "the meter is still rate-limited")
        XCTAssertNil(a.maximumDuration, "No limit survives the filter")
        XCTAssertNil(b.maximumDuration)
    }

    // MARK: - Controller re-render policy

    func testControllerSkipsUnchangedSnapshotsAndKeepsFrameStable() {
        let controller = HUDController(announce: { _ in })
        let state = HUDViewState(phase: .transcribing)
        controller.show(state)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.renderCount, 1)
        let frame = controller.panel?.frame

        controller.show(state)
        controller.show(state)
        XCTAssertEqual(controller.renderCount, 1, "the 60 ms poll must not re-render an unchanged snapshot")
        XCTAssertEqual(controller.panel?.frame, frame)

        controller.show(HUDViewState(phase: .inserting))
        XCTAssertEqual(controller.renderCount, 2)
        XCTAssertEqual(controller.panel?.frame, frame, "phases with the same shape keep the same panel frame")
        controller.dismiss()
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(controller.renderState, .idle)
    }

    func testControllerAnnouncesOnPhaseChangeNotOnMeterTicks() {
        var announcements: [String] = []
        let controller = HUDController(announce: { announcements.append($0) })
        controller.show(recording(level: 0.2, seconds: 1))
        controller.show(recording(level: 0.8, seconds: 1))
        controller.show(recording(level: 0.4, seconds: 2))
        XCTAssertEqual(announcements, ["Recording. Release to stop"])

        controller.show(HUDViewState(phase: .finalizing))
        controller.show(HUDViewState(phase: .transcribing))
        XCTAssertEqual(announcements.count, 1, "intermediate phases are silent")

        controller.show(HUDViewState(phase: .completed(HUDCompletionState(kind: .success))))
        XCTAssertEqual(announcements.last, "Inserted")
        controller.dismiss()
    }

    func testAutoDismissedStateIsNotReshownUntilStateChanges() async throws {
        let clock = ParkingClock()
        let controller = HUDController(announce: { _ in }, clock: clock)
        let done = HUDViewState(phase: .completed(HUDCompletionState(kind: .success)))
        let delay = try XCTUnwrap(done.autoDismissAfter(timings: controller.dismissTimings))
        XCTAssertEqual(delay, .milliseconds(900), "the compiled success exit")
        controller.show(done)
        XCTAssertTrue(controller.isVisible)

        await clock.waitForSleepers(1)
        XCTAssertEqual(clock.pendingDurations, [delay])
        let dismissal = try XCTUnwrap(controller.dismissalTask)
        clock.advance(by: delay - .milliseconds(1))
        XCTAssertTrue(controller.isVisible, "the panel stays up for the whole exit delay")
        clock.advance(by: .milliseconds(1))
        await awaitTask(dismissal, "the auto-dismiss timer never finished after its deadline")
        XCTAssertFalse(controller.isVisible, "success auto-hides after 900 ms")

        controller.show(done)
        XCTAssertFalse(controller.isVisible, "the shell re-sending the same terminal state must not flash the panel back")

        controller.show(HUDViewState(phase: .recording(HUDRecordingState())))
        XCTAssertTrue(controller.isVisible)
        controller.dismiss()
    }
}
