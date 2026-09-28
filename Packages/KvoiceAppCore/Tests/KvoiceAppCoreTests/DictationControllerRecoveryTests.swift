import Foundation
import XCTest
import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceAppCore

/// ADR-022 items 6 and 9: one-click recovery on the failure HUD (Copy,
/// Insert Again) and the one-scalar-line-per-failure diagnostics rule.
final class DictationControllerRecoveryTests: XCTestCase {
    private let target = TargetApplicationSnapshot(
        processIdentifier: 7,
        bundleIdentifier: "com.apple.TextEdit",
        localizedName: "TextEdit",
        capturedAt: Date(timeIntervalSince1970: 1)
    )
    private let otherTarget = TargetApplicationSnapshot(
        processIdentifier: 9,
        bundleIdentifier: "com.apple.Notes",
        localizedName: "Notes",
        capturedAt: Date(timeIntervalSince1970: 2)
    )

    // MARK: Insert Again

    func testInsertAgainRunsTheTiersOverTheRetainedTextIntoTheCurrentFrontmostApp() async throws {
        let insertion = FakeTextInsertionService(target: target)
        await insertion.setFailure(KVoiceError(code: .accessibilityVerifyFailed, retryable: false))
        let history = InMemoryHistoryRepository()
        let logger = RecordingDiagnosticLogger()
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("hello again")),
            insertion: insertion,
            settings: FakeSettingsRepository(settings: AppSettings(historyEnabled: true)),
            history: history,
            diagnosticLogger: logger
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        var state = await controller.state
        guard case .failed(let jobID?, let failure) = state else {
            return XCTFail("expected a failed job, got \(state)")
        }
        XCTAssertEqual(failure.code, KVoiceErrorCode.accessibilityVerifyFailed.rawValue)
        let retained = await controller.exactFinalTextForFallback
        XCTAssertEqual(retained, "hello again")
        let canRecover = await controller.canRecoverFailedInsertion
        XCTAssertTrue(canRecover)
        let snapshot = await controller.snapshot
        XCTAssertTrue(snapshot.canRecoverFailedInsertion, "the one scalar the HUD buttons and the menu items read")
        XCTAssertEqual(snapshot.recoverableTranscript, "hello again")
        var rows = await history.entries
        XCTAssertTrue(rows.isEmpty, "the failed attempt wrote no row")

        // The user clicks into another app, then Insert Again.
        await insertion.setFailure(nil)
        await insertion.setTarget(otherTarget)
        let result = await controller.retryInsertion()
        guard case .success(let final) = result else {
            return XCTFail("expected the retry to run, got \(result)")
        }
        XCTAssertEqual(final.kind, .completed)
        state = await controller.state
        if case .completed(let completedID, let summary) = state {
            XCTAssertEqual(completedID, jobID, "the job aggregate is reused")
            XCTAssertEqual(summary.insertion, .inserted(method: .selectedTextAttribute))
        } else {
            XCTFail("expected completed, got \(state)")
        }
        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["hello again"], "the retained text, through the ordinary insert path")
        let targets = await insertion.insertedTargets
        XCTAssertEqual(targets.map(\.processIdentifier), [9], "re-captured now, not the recording-start target")
        let job = await controller.activeJob
        XCTAssertEqual(job?.target?.processIdentifier, 9)
        XCTAssertEqual(job?.historyRowWritten, true)
        rows = await history.entries
        XCTAssertEqual(rows.count, 1, "the row the original attempt never wrote")
        XCTAssertEqual(rows.first?.finalText, "hello again")

        // ADR-022 item 9: exactly one failure line for the throw that
        // reached the HUD, naming the stage and the reducer event.
        let failures = await logger.events.filter { $0.name == .dictationFailed }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.jobID, jobID)
        XCTAssertEqual(failures.first?.errorCode, .accessibilityVerifyFailed)
        XCTAssertEqual(failures.first?.attributes.site?.rawValue, "insert")
        XCTAssertEqual(failures.first?.attributes.reason?.rawValue, "clipboardFailure")
        let encoded = try JSONEncoder().encode(failures.first)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("hello again"), "never the transcript")
    }

    func testInsertAgainThatFailsAgainKeepsTheTranscriptAndLogsOnceMore() async throws {
        let insertion = FakeTextInsertionService(target: target)
        await insertion.setFailure(KVoiceError(code: .accessibilityVerifyFailed, retryable: false))
        let logger = RecordingDiagnosticLogger()
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("keep me")),
            insertion: insertion,
            diagnosticLogger: logger
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let result = await controller.retryInsertion()
        guard case .success(let final) = result else { return XCTFail("expected the retry to run") }
        XCTAssertEqual(final.kind, .failed)
        let retained = await controller.exactFinalTextForFallback
        XCTAssertEqual(retained, "keep me", "a second failure keeps the text for another try or a copy")
        let canRecover = await controller.canRecoverFailedInsertion
        XCTAssertTrue(canRecover)
        let failures = await logger.events.filter { $0.name == .dictationFailed }
        XCTAssertEqual(failures.count, 2, "one line per failure that reached the HUD")

        // Escape still dismisses the failed job and drops the text.
        let idle = await controller.cancel()
        XCTAssertEqual(idle.kind, .idle)
        let afterEscape = await controller.exactFinalTextForFallback
        XCTAssertNil(afterEscape)
    }

    func testInsertAgainWithNothingFrontmostEndsInTheClipboardFallback() async throws {
        let insertion = FakeTextInsertionService(target: target)
        await insertion.setFailure(KVoiceError(code: .accessibilityVerifyFailed, retryable: false))
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("to clipboard")),
            insertion: insertion
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        await insertion.setFailure(nil)
        await insertion.setTarget(nil)
        let result = await controller.retryInsertion()
        guard case .success(let final) = result else { return XCTFail("expected the retry to run") }
        if case .completed(_, let summary) = final {
            XCTAssertEqual(summary.insertion, .copiedToClipboard(reason: .noFrontmostApplication))
        } else {
            XCTFail("expected a clipboard-fallback completion, got \(final)")
        }
        let copied = await insertion.clipboardTexts
        XCTAssertEqual(copied, ["to clipboard"])
        let inserted = await insertion.insertedTexts
        XCTAssertTrue(inserted.isEmpty)
    }

    func testRecoveryIsRefusedOutsideAFailedJobWithRetainedText() async throws {
        let insertion = FakeTextInsertionService(target: target)
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: nil), // throws sttEmpty
            insertion: insertion
        )
        // Idle.
        var retry = await controller.retryInsertion()
        XCTAssertEqual(retry, .failure(.notFailed))
        var copy = await controller.copyRetainedTranscript()
        XCTAssertEqual(copy, .notFailed)
        var canRecover = await controller.canRecoverFailedInsertion
        XCTAssertFalse(canRecover)

        // Failed without any transcript (nothing heard): nothing to recover.
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()
        let state = await controller.state
        XCTAssertEqual(state.kind, .failed)
        retry = await controller.retryInsertion()
        XCTAssertEqual(retry, .failure(.noRetainedText))
        copy = await controller.copyRetainedTranscript()
        XCTAssertEqual(copy, .noRetainedText)
        canRecover = await controller.canRecoverFailedInsertion
        XCTAssertFalse(canRecover)
        let inserted = await insertion.insertedTexts
        XCTAssertTrue(inserted.isEmpty)
        let copied = await insertion.clipboardTexts
        XCTAssertTrue(copied.isEmpty)
        let still = await controller.state
        XCTAssertEqual(still.kind, .failed, "a refusal changes nothing")
    }

    // MARK: Copy

    func testCopyWritesTheExactRetainedTextAndKeepsTheFailureOnScreen() async throws {
        let insertion = FakeTextInsertionService(target: target)
        await insertion.setFailure(KVoiceError(code: .accessibilityVerifyFailed, retryable: false))
        let logger = RecordingDiagnosticLogger()
        // `addSpaceAfterInsertion` shapes what reaches the target, never the
        // retained text (Architecture.md, "Inserted-text options").
        var settings = AppSettings()
        settings.addSpaceAfterInsertion = true
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("exact text")),
            insertion: insertion,
            settings: FakeSettingsRepository(settings: settings),
            diagnosticLogger: logger
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let copy = await controller.copyRetainedTranscript()
        XCTAssertNil(copy)
        let copied = await insertion.clipboardTexts
        XCTAssertEqual(copied, ["exact text"], "the exact retained text, not the prepared one")
        let state = await controller.state
        XCTAssertEqual(state.kind, .failed, "Copy leaves the HUD up: Insert Again and Escape still apply")
        let retained = await controller.exactFinalTextForFallback
        XCTAssertEqual(retained, "exact text")
        let copies = await logger.events.filter { $0.attributes.reason?.rawValue == "recoveryCopy" }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(copies.first?.attributes.site?.rawValue, "failureHUD")

        // A second copy is fine; a copy that cannot write says so.
        let again = await controller.copyRetainedTranscript()
        XCTAssertNil(again)
    }

    func testInAppTestJobIsNeverRecoverable() async throws {
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("test")),
            insertion: FakeTextInsertionService(target: target)
        )
        _ = await controller.startRecording(delivery: .inApp)
        _ = await controller.stopRecording()
        await controller.waitForCompletion()
        let state = await controller.state
        XCTAssertEqual(state.kind, .completed, "in-app delivery cannot fail at insertion")
        let retry = await controller.retryInsertion()
        XCTAssertEqual(retry, .failure(.notFailed))
        let snapshot = await controller.snapshot
        XCTAssertFalse(snapshot.canRecoverFailedInsertion)

        // Even a reducer-injected failure on an in-app job with retained
        // text is not recoverable: the snapshot scalar follows the same
        // delivery check the commands make, so the HUD shows no buttons.
        let injected = DictationController(
            initialState: .idle,
            audioService: FakeAudioCaptureService(),
            transcriptionEngine: FakeTranscriptionEngine(result: transcript("test")),
            insertionService: FakeTextInsertionService(target: target)
        )
        let jobID = UUID()
        let job = DictationJob(
            id: jobID, startedAt: Date(), target: target, modeSnapshot: .off,
            translationTargetSnapshot: nil, modelIDSnapshot: "fixture",
            delivery: .inApp, rawTranscript: "kept", finalText: "kept"
        )
        _ = try await injected.apply(.start(jobID: jobID, prerequisites: .passed), job: job)
        _ = try await injected.apply(.captureFailure(jobID: jobID, code: .audioEngineStartFailed))
        let injectedSnapshot = await injected.snapshot
        XCTAssertEqual(injectedSnapshot.state.kind, .failed)
        XCTAssertEqual(injectedSnapshot.recoverableTranscript, "kept")
        XCTAssertFalse(injectedSnapshot.canRecoverFailedInsertion, "a kept transcript on an in-app job never offers Copy / Insert Again")
        let injectedRetry = await injected.retryInsertion()
        XCTAssertEqual(injectedRetry, .failure(.noRetainedText))
    }

    // MARK: Diagnostics rule (ADR-022 item 9): one line per HUD-reaching throw

    func testEveryPipelineFailureThatReachesTheHUDLogsExactlyOneLineNamingItsSite() async throws {
        // Capture: the recorder cannot start.
        do {
            let logger = RecordingDiagnosticLogger()
            let controller = DictationController(
                audio: FakeAudioCaptureService(failure: KVoiceError(code: .audioEngineStartFailed)),
                transcription: FakeTranscriptionEngine(result: transcript("x")),
                insertion: FakeTextInsertionService(target: target),
                diagnosticLogger: logger
            )
            let state = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
            XCTAssertEqual(state.kind, .failed)
            let failures = await logger.events.filter { $0.name == .dictationFailed }
            XCTAssertEqual(failures.count, 1)
            XCTAssertEqual(failures.first?.attributes.site?.rawValue, "capture")
            XCTAssertEqual(failures.first?.attributes.reason?.rawValue, "captureFailure")
            XCTAssertEqual(failures.first?.errorCode, .audioEngineStartFailed)
        }
        // Finalize: the recording is empty.
        do {
            let logger = RecordingDiagnosticLogger()
            let empty = AudioRecording(samples: [], duration: .zero, peakLevelDBFS: -160, clippedFrameCount: 0)
            let controller = DictationController(
                audio: FakeAudioCaptureService(recording: empty),
                transcription: FakeTranscriptionEngine(result: transcript("x")),
                insertion: FakeTextInsertionService(target: target),
                diagnosticLogger: logger
            )
            _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
            _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
            await controller.waitForCompletion()
            let failures = await logger.events.filter { $0.name == .dictationFailed }
            XCTAssertEqual(failures.count, 1)
            XCTAssertEqual(failures.first?.attributes.site?.rawValue, "finalize")
            XCTAssertEqual(failures.first?.attributes.reason?.rawValue, "invalidAudio")
            XCTAssertEqual(failures.first?.errorCode, .audioNoSamples)
        }
        // Transcribe: the engine throws.
        do {
            let logger = RecordingDiagnosticLogger()
            let controller = DictationController(
                audio: FakeAudioCaptureService(),
                transcription: FakeTranscriptionEngine(failure: KVoiceError(code: .sttFailed)),
                insertion: FakeTextInsertionService(target: target),
                diagnosticLogger: logger
            )
            _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
            _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
            await controller.waitForCompletion()
            let failures = await logger.events.filter { $0.name == .dictationFailed }
            XCTAssertEqual(failures.count, 1)
            XCTAssertEqual(failures.first?.attributes.site?.rawValue, "transcribe")
            XCTAssertEqual(failures.first?.attributes.reason?.rawValue, "transcriptionFailure")
            XCTAssertEqual(failures.first?.errorCode, .sttFailed)
        }
        // AI: the request fails and the raw transcript is inserted — the
        // HUD shows the fallback, so the line is `ai.fallback.used`.
        do {
            let logger = RecordingDiagnosticLogger()
            let controller = DictationController(
                audio: FakeAudioCaptureService(),
                transcription: FakeTranscriptionEngine(result: transcript("raw")),
                insertion: FakeTextInsertionService(target: target),
                settings: FakeSettingsRepository(settings: aiSettings(mode: .polish)),
                ai: FakeAIProcessingClient(failure: KVoiceError(code: .aiTimeout)),
                diagnosticLogger: logger
            )
            _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
            _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
            await controller.waitForCompletion()
            let state = await controller.state
            XCTAssertEqual(state.kind, .completed)
            let fallbacks = await logger.events.filter { $0.name == .aiFallbackUsed }
            XCTAssertEqual(fallbacks.count, 1)
            XCTAssertEqual(fallbacks.first?.attributes.site?.rawValue, "processAI")
            XCTAssertEqual(fallbacks.first?.attributes.reason?.rawValue, "aiFailure")
            XCTAssertEqual(fallbacks.first?.errorCode, .aiTimeout)
            XCTAssertEqual(fallbacks.first?.result, .warning)
            let failures = await logger.events.filter { $0.name == .dictationFailed }
            XCTAssertTrue(failures.isEmpty, "an AI fallback is a completion, not a failure")
        }
        // A clean success logs no failure line at all.
        do {
            let logger = RecordingDiagnosticLogger()
            let controller = DictationController(
                audio: FakeAudioCaptureService(),
                transcription: FakeTranscriptionEngine(result: transcript("fine")),
                insertion: FakeTextInsertionService(target: target),
                diagnosticLogger: logger
            )
            _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
            _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
            await controller.waitForCompletion()
            let lines = await logger.events.filter { $0.name == .dictationFailed || $0.name == .aiFallbackUsed }
            XCTAssertTrue(lines.isEmpty)
        }
    }

    // MARK: Helpers

    private func aiSettings(mode: DictationMode) -> AppSettings {
        AppSettings(
            ai: AIEndpointSettings(
                mode: mode,
                baseURL: URL(string: "http://127.0.0.1:11434/v1"),
                modelID: "fixture-model",
                translationLanguage: .init(bcp47: "en", displayName: "English")
            )
        )
    }

    private func transcript(_ text: String) -> TranscriptionResult {
        let now = ContinuousClock().now
        return TranscriptionResult(
            text: text,
            detectedLanguage: nil,
            segments: [],
            timings: TranscriptionTimings(
                requestStart: now,
                inferenceStart: now,
                inferenceEnd: now,
                runtimeReportedRealTimeFactor: nil
            ),
            modelID: "fixture"
        )
    }
}

private actor RecordingDiagnosticLogger: DiagnosticLogging {
    private(set) var events: [DiagnosticEvent] = []

    func log(_ event: DiagnosticEvent) async {
        events.append(event)
    }
}
