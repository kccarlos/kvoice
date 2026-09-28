import Foundation
import XCTest
import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceAppCore

/// ADR-022 item 7, wave-3 slice 6: overlapping jobs behind the
/// `overlappingJobs` developer flag, and the coordinator / runner split
/// underneath it. Every test drives the public controller API with the
/// fakes in `KvoiceTestSupport` plus the gated doubles at the bottom of
/// this file (an engine, an AI client and an insertion service that hold a
/// call until the test releases it), so ordering is proven rather than
/// timed. The flag-off cases pin today's behaviour; the split itself is
/// covered by every pre-existing controller test passing unchanged.
final class DictationControllerOverlapTests: XCTestCase {
    private let target = TargetApplicationSnapshot(
        processIdentifier: 7,
        bundleIdentifier: "com.apple.TextEdit",
        localizedName: "TextEdit",
        capturedAt: Date(timeIntervalSince1970: 1)
    )

    private static let on = Resolved(true, Provenance.override)
    private static let off = Resolved(false, Provenance.default)

    // MARK: Flag off: unchanged busy pulse

    func testFlagOffASecondPressWhileTranscribingIsTheBusyPulseAndNothingOverlaps() async {
        let engine = GatedEngine(results: ["first", "second"])
        let audio = FakeAudioCaptureService()
        let logger = RecordingDiagnosticLogger()
        let controller = DictationController(
            audio: audio,
            transcription: engine,
            insertion: FakeTextInsertionService(target: target),
            diagnosticLogger: logger,
            overlappingJobs: Self.off
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await engine.waitUntilStarted(count: 1)

        let second = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        XCTAssertEqual(second.kind, .transcribing, "flag off: the press is ignored, not queued")
        let snapshot = await controller.snapshot
        XCTAssertEqual(snapshot.busyShortcutCount, 1)
        XCTAssertEqual(snapshot.finishingCount, 0)
        XCTAssertNil(snapshot.overlapPausedReason)
        let recording = await audio.isRecording
        XCTAssertFalse(recording)
        let inFlight = await controller.jobIDsInStartOrder
        XCTAssertEqual(inFlight.count, 1)

        await engine.release()
        await controller.waitForCompletion()
        let events = await logger.events
        XCTAssertTrue(events.contains { $0.attributes.reason?.rawValue == "startWhileBusy" })
        XCTAssertFalse(events.contains { $0.name == .dictationOverlapStarted || $0.name == .dictationOverlapRefused })
    }

    // MARK: Flag on: a second recording, a third press refused

    func testFlagOnASecondPressStartsRecordingWithOneFinishingAndAThirdIsRefused() async {
        let engine = GatedEngine(results: ["first", "second", "third"])
        let audio = FakeAudioCaptureService()
        let insertion = FakeTextInsertionService(target: target)
        let logger = RecordingDiagnosticLogger()
        let controller = DictationController(
            audio: audio,
            transcription: engine,
            insertion: insertion,
            diagnosticLogger: logger,
            overlappingJobs: Self.on
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await engine.waitUntilStarted(count: 1)
        guard case .transcribing(let firstID) = await controller.state else {
            return XCTFail("setup: the first job must be transcribing")
        }

        // Second press: a new recording behind the finishing job.
        let second = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        guard case .recording(let recording) = second else {
            return XCTFail("flag on: the press must start a new recording, got \(second)")
        }
        let secondID = recording.jobID
        XCTAssertNotEqual(secondID, firstID)
        var snapshot = await controller.snapshot
        XCTAssertEqual(snapshot.finishingCount, 1, "the HUD badge: one job finishing behind the recorder")
        XCTAssertEqual(snapshot.busyShortcutCount, 0)
        XCTAssertTrue(snapshot.captureStarted)
        let firstState = await controller.jobState(firstID)
        XCTAssertEqual(firstState?.kind, .transcribing, "the older job is untouched")

        // Its release: finalizing → transcribing, queued behind the engine.
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await settle(until: { await controller.jobState(secondID)?.kind == .transcribing })
        let started = await engine.startedCount
        XCTAssertEqual(started, 1, "one engine: the second pass waits for the first")
        snapshot = await controller.snapshot
        XCTAssertEqual(snapshot.state.kind, .transcribing)
        XCTAssertEqual(snapshot.state.jobID, firstID, "with nothing recording the HUD shows the oldest job")
        XCTAssertEqual(snapshot.finishingCount, 1, "the second job is finishing behind the shown one")

        // Third press: two finishing already — the busy pulse, no recorder.
        let third = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        XCTAssertEqual(third.kind, .transcribing)
        snapshot = await controller.snapshot
        XCTAssertEqual(snapshot.busyShortcutCount, 1, "a third press gets the busy pulse")
        let jobs = await controller.jobIDsInStartOrder
        XCTAssertEqual(jobs, [firstID, secondID])

        // Both finish, in order.
        await engine.release()
        await settle(until: { await controller.jobState(firstID)?.kind == .completed })
        await engine.waitUntilStarted(count: 2)
        _ = await controller.handle(.dismiss)
        await engine.release()
        await controller.waitForCompletion()
        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["first", "second"])

        let events = await logger.events
        let startedLine = events.first { $0.name == .dictationOverlapStarted }
        XCTAssertEqual(startedLine?.jobID, secondID)
        XCTAssertEqual(startedLine?.attributes.finishingCount, 1)
        let refused = events.first { $0.name == .dictationOverlapRefused }
        XCTAssertEqual(refused?.attributes.reason?.rawValue, "queueFull")
        XCTAssertEqual(refused?.attributes.finishingCount, 2)
    }

    // MARK: Transcriptions serialized in job order

    func testTranscriptionsRunOneAtATimeInRecordingOrder() async {
        let engine = GatedEngine(results: ["first", "second"])
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: engine,
            insertion: FakeTextInsertionService(target: target),
            overlappingJobs: Self.on
        )

        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        _ = await controller.handleShortcut(.keyUp, mode: .toggle)
        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        _ = await controller.handleShortcut(.keyUp, mode: .toggle)
        await engine.waitUntilStarted(count: 1)
        let firstID = await controller.state.jobID

        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        _ = await controller.handleShortcut(.keyUp, mode: .toggle)
        let secondID = await controller.jobIDsInStartOrder.last
        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        _ = await controller.handleShortcut(.keyUp, mode: .toggle)
        await settle(until: { await controller.jobState(secondID!)?.kind == .transcribing })

        // Yielding many times does not let the second pass start.
        for _ in 0..<50 { await Task.yield() }
        let startedBeforeRelease = await engine.startedJobIDs
        XCTAssertEqual(startedBeforeRelease, [firstID])

        await engine.release()
        await engine.waitUntilStarted(count: 2)
        let startedAfterRelease = await engine.startedJobIDs
        XCTAssertEqual(startedAfterRelease, [firstID, secondID])
        await engine.release()
        await controller.waitForCompletion()
    }

    // MARK: Insertion order when the newer job's AI finishes first

    func testInsertionsLandInRecordingOrderEvenWhenTheNewerJobsAIFinishesFirst() async {
        let engine = GatedEngine(results: ["first", "second"], gated: false)
        let ai = PerJobGatedAI()
        let insertion = FakeTextInsertionService(target: target)
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: engine,
            insertion: insertion,
            settings: FakeSettingsRepository(settings: aiSettings(mode: .polish)),
            ai: ai,
            overlappingJobs: Self.on
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        guard let firstID = await waitForAIStart(ai, controller: controller) else { return }

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        guard let secondID = await controller.jobIDsInStartOrder.last, secondID != firstID else {
            return XCTFail("setup: a second job")
        }
        await ai.waitUntilStarted(jobID: secondID)

        // The newer job's AI returns first: it must wait in `.inserting`.
        await ai.release(jobID: secondID)
        await settle(until: { await controller.jobState(secondID)?.kind == .inserting })
        for _ in 0..<50 { await Task.yield() }
        var inserted = await insertion.insertedTexts
        XCTAssertTrue(inserted.isEmpty, "the second job must not insert before the first")
        let firstState = await controller.jobState(firstID)
        XCTAssertEqual(firstState?.kind, .processingAI, "the first job's AI was not cancelled by the second recording")

        await ai.release(jobID: firstID)
        await controller.waitForCompletion()
        inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["polished first", "polished second"])
    }

    // MARK: A new recording never cancels the previous job's AI; Escape does

    func testANewRecordingDoesNotCancelThePreviousAIStepButEscapeOnItDoes() async {
        let engine = GatedEngine(results: ["first", "second"], gated: false)
        let ai = PerJobGatedAI()
        let insertion = FakeTextInsertionService(target: target)
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: engine,
            insertion: insertion,
            settings: FakeSettingsRepository(settings: aiSettings(mode: .polish)),
            ai: ai,
            overlappingJobs: Self.on
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        guard let firstID = await waitForAIStart(ai, controller: controller) else { return }

        let second = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        XCTAssertEqual(second.kind, .recording)
        for _ in 0..<20 { await Task.yield() }
        let cancelledByStart = await ai.observedCancellation(jobID: firstID)
        XCTAssertFalse(cancelledByStart)
        let firstState = await controller.jobState(firstID)
        XCTAssertEqual(firstState?.kind, .processingAI)

        // Escape goes to the recording job first…
        _ = await controller.cancel()
        let afterFirstEscape = await controller.state
        XCTAssertEqual(afterFirstEscape.kind, .processingAI, "the recording was discarded; the older job is now shown")
        XCTAssertEqual(afterFirstEscape.jobID, firstID)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)

        // …then to the oldest job in flight: AI cancelled, raw text inserted.
        _ = await controller.cancel()
        await controller.waitForCompletion()
        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["first"], "Escape during AI inserts the raw transcript")
        let cancelledByEscape = await ai.observedCancellation(jobID: firstID)
        XCTAssertTrue(cancelledByEscape)
    }

    // MARK: Escape targets the recording job, then the oldest

    func testEscapeDiscardsTheRecordingJobFirstAndThenTheOldestFinishingJob() async {
        let engine = GatedEngine(results: ["first"])
        let audio = FakeAudioCaptureService()
        let controller = DictationController(
            audio: audio,
            transcription: engine,
            insertion: FakeTextInsertionService(target: target),
            overlappingJobs: Self.on
        )

        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        _ = await controller.handleShortcut(.keyUp, mode: .toggle)
        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        _ = await controller.handleShortcut(.keyUp, mode: .toggle)
        await engine.waitUntilStarted(count: 1)
        let firstID = await controller.state.jobID
        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        _ = await controller.handleShortcut(.keyUp, mode: .toggle)
        let recordingBefore = await audio.isRecording
        XCTAssertTrue(recordingBefore)

        _ = await controller.cancel()
        let recordingAfter = await audio.isRecording
        XCTAssertFalse(recordingAfter, "Escape discarded the recording")
        let shown = await controller.state
        XCTAssertEqual(shown.kind, .transcribing)
        XCTAssertEqual(shown.jobID, firstID, "the older job is still transcribing")
        let jobs = await controller.jobIDsInStartOrder
        XCTAssertEqual(jobs, [firstID])

        _ = await controller.cancel()
        let idle = await controller.state
        XCTAssertEqual(idle, .idle)
        await engine.release()
        await controller.waitForCompletion()
    }

    // MARK: A failed job kept behind the recorder: Copy and Insert Again

    func testCopyAndInsertAgainStillActOnAFailedJobWhileAnotherRecords() async {
        let engine = GatedEngine(results: ["first", "second"], gated: false)
        let insertion = GatedInsertionService(target: target)
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: engine,
            insertion: insertion,
            overlappingJobs: Self.on
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await insertion.waitUntilInsertStarted(count: 1)
        let firstID = await controller.state.jobID

        let second = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        XCTAssertEqual(second.kind, .recording)
        // The first job's insertion now fails, behind the recorder.
        await insertion.fail(with: KVoiceError(code: .accessibilityVerifyFailed, retryable: false))
        await settle(until: { await controller.jobState(firstID!)?.kind == .failed })

        let snapshot = await controller.snapshot
        XCTAssertEqual(snapshot.state.kind, .recording, "the recorder stays on screen")
        XCTAssertTrue(snapshot.canRecoverFailedInsertion, "the menu can still offer Copy / Insert Again")

        let copied = await controller.copyRetainedTranscript()
        XCTAssertNil(copied)
        let clipboard = await insertion.clipboardTexts
        XCTAssertEqual(clipboard, ["first"])

        // `retryInsertion` awaits its own insertion, which the double holds.
        let retryTask = Task { await controller.retryInsertion() }
        await insertion.waitUntilInsertStarted(count: 2)
        await insertion.release()
        let retry = await retryTask.value
        guard case .success = retry else { return XCTFail("Insert Again refused: \(retry)") }
        await settle(until: { await controller.jobState(firstID!) == nil })
        let afterRetry = await controller.snapshot
        XCTAssertEqual(afterRetry.state.kind, .recording, "a completion the HUD cannot show is dismissed at once")
        XCTAssertFalse(afterRetry.canRecoverFailedInsertion)

        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await insertion.waitUntilInsertStarted(count: 3)
        await insertion.release()
        await controller.waitForCompletion()
        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["first", "second"])
        let final = await controller.state
        XCTAssertEqual(final.kind, .completed)
    }

    // MARK: History rows keep recording order

    func testHistoryRowsKeepRecordingOrderWhenCompletionOrderDiffers() async throws {
        let engine = GatedEngine(results: ["first", "second"], gated: false)
        let insertion = GatedInsertionService(target: target)
        let history = InMemoryHistoryRepository()
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: engine,
            insertion: insertion,
            settings: FakeSettingsRepository(settings: AppSettings(historyEnabled: true)),
            history: history,
            overlappingJobs: Self.on
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await insertion.waitUntilInsertStarted(count: 1)
        let firstID = await controller.state.jobID
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        await insertion.fail(with: KVoiceError(code: .accessibilityVerifyFailed, retryable: false))
        await settle(until: { await controller.jobState(firstID!)?.kind == .failed })

        // The second job completes first (its row is written first).
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await insertion.waitUntilInsertStarted(count: 2)
        await insertion.release()
        await settle(until: { await controller.jobIDsInStartOrder.count == 1 })
        await controller.waitForCompletion()
        var rows = try await history.fetchPage(before: nil, limit: 10)
        XCTAssertEqual(rows.map(\.finalText), ["second"])

        // Insert Again on the first job writes its row later, yet it sorts
        // as the older dictation.
        let retryTask = Task { await controller.retryInsertion() }
        await insertion.waitUntilInsertStarted(count: 3)
        await insertion.release()
        let retry = await retryTask.value
        guard case .success = retry else { return XCTFail("Insert Again refused: \(retry)") }
        await controller.waitForCompletion()
        rows = try await history.fetchPage(before: nil, limit: 10)
        XCTAssertEqual(rows.map(\.finalText), ["second", "first"], "newest first: the first dictation is the older row")
        XCTAssertLessThan(rows[1].createdAt, rows[0].createdAt)
    }

    // MARK: The environment turned the flag off

    func testWhenTheEnvironmentForcesTheFlagOffThePressIsRefusedWithTheReason() async {
        let engine = GatedEngine(results: ["first"])
        let audio = FakeAudioCaptureService()
        let logger = RecordingDiagnosticLogger()
        let controller = DictationController(
            audio: audio,
            transcription: engine,
            insertion: FakeTextInsertionService(target: target),
            diagnosticLogger: logger,
            overlappingJobs: Resolved(false, .limitedBy(SettingsResolver.memoryPressureFact))
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await engine.waitUntilStarted(count: 1)

        let refused = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        XCTAssertEqual(refused.kind, .transcribing)
        var snapshot = await controller.snapshot
        XCTAssertEqual(snapshot.busyShortcutCount, 1, "the busy pulse, as with the flag off")
        XCTAssertEqual(snapshot.overlapPausedReason, .memoryPressure, "plus the one note saying why")
        XCTAssertEqual(snapshot.finishingCount, 0)
        let recording = await audio.isRecording
        XCTAssertFalse(recording)

        let line = await logger.events.first { $0.name == .dictationOverlapRefused }
        XCTAssertEqual(line?.attributes.reason?.rawValue, "limitedBy:memoryPressure")
        XCTAssertEqual(line?.attributes.finishingCount, 1)

        // The shell pushes the re-resolved row; the next press overlaps.
        await controller.setOverlappingJobs(Self.on)
        let admitted = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        XCTAssertEqual(admitted.kind, .recording)
        snapshot = await controller.snapshot
        XCTAssertNil(snapshot.overlapPausedReason, "cleared by the admitted start")
        _ = await controller.cancel()
        await engine.release()
        await controller.waitForCompletion()
        _ = await controller.handle(.dismiss)
        let idle = await controller.snapshot
        XCTAssertEqual(idle.state, .idle)
        XCTAssertNil(idle.overlapPausedReason)
    }

    func testEveryLimitingFactHasAPauseReasonAndAScalarToken() {
        for reason in OverlapPauseReason.allCases {
            XCTAssertEqual(OverlapPauseReason(limitingFact: reason.limitingFact), reason)
            XCTAssertNotNil(DiagnosticToken(rawValue: "limitedBy:\(reason.rawValue)"), "the reason must be a diagnostics token")
        }
        XCTAssertNil(OverlapPauseReason(limitingFact: SettingsResolver.enginePromptCapFact))
    }

    // MARK: Reentrancy across the runner / coordinator boundary

    func testAStaleJobsLateCallbacksCannotTouchANewerJob() async {
        let engine = GatedEngine(results: ["first", "second"], gated: false)
        let insertion = FakeTextInsertionService(target: target)
        let controller = DictationController(
            audio: FakeAudioCaptureService(deliversSignalOnStart: false),
            transcription: engine,
            insertion: insertion,
            overlappingJobs: Self.on
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        let firstID = await controller.state.jobID!
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()
        let firstDone = await controller.state
        XCTAssertEqual(firstDone.kind, .completed)

        // Restart: the terminal HUD is dismissed and a new job records.
        let second = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        guard case .recording(let recording) = second else { return XCTFail("expected a recording") }
        let secondID = recording.jobID
        let gone = await controller.jobState(firstID)
        XCTAssertNil(gone)

        // Pattern 1: a completion-side callback for the finished job — a
        // late partial, a late final text — finds no runner and changes
        // nothing about the job now recording.
        await controller.receiveTranscriptionEvent(.partialText("late words"), for: firstID)
        await controller.recordFinalText("late provider text", for: firstID)
        await controller.recordRawTranscript("late raw", for: firstID)
        var snapshot = await controller.snapshot
        XCTAssertNil(snapshot.partialTranscript)
        XCTAssertNil(snapshot.recoverableTranscript)
        let job = await controller.activeJob
        XCTAssertEqual(job?.id, secondID)
        XCTAssertNil(job?.rawTranscript)

        // Pattern 2: a capture-side callback carrying the stale job id is
        // dropped even though a recording is live; the live job's own
        // events still land.
        await controller.receiveAudioEvent(.level(rmsDBFS: -20, peakDBFS: -10), for: firstID)
        await controller.receiveAudioEvent(.elapsed(.seconds(9)), for: firstID)
        snapshot = await controller.snapshot
        XCTAssertFalse(snapshot.captureStarted, "the stale id must not flip the live job's capture state")
        XCTAssertEqual(snapshot.state, .recording(RecordingState(jobID: secondID, elapsed: .zero)))
        await controller.receiveAudioEvent(.level(rmsDBFS: -20, peakDBFS: -10), for: secondID)
        await controller.receiveAudioEvent(.elapsed(.seconds(2)), for: secondID)
        snapshot = await controller.snapshot
        XCTAssertTrue(snapshot.captureStarted)
        XCTAssertEqual(snapshot.state, .recording(RecordingState(jobID: secondID, elapsed: .seconds(2))))

        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()
        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["first", "second"])
    }

    func testAHiddenCompletionIsDismissedAndTheRecorderKeepsTheHUD() async {
        let engine = GatedEngine(results: ["first", "second"])
        let insertion = FakeTextInsertionService(target: target)
        let logger = RecordingDiagnosticLogger()
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: engine,
            insertion: insertion,
            diagnosticLogger: logger,
            overlappingJobs: Self.on
        )
        // Unbounded and read once the controller is quiescent: the kinds
        // asserted below are every published snapshot, not whichever ones a
        // consumer task happened to see (`PublishedSnapshots`).
        let published = await PublishedSnapshots(controller)

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await engine.waitUntilStarted(count: 1)
        let firstID = await controller.state.jobID!
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)

        await engine.release()
        await settle(until: { await controller.jobState(firstID) == nil })
        let snapshot = await controller.snapshot
        XCTAssertEqual(snapshot.state.kind, .recording)
        XCTAssertEqual(snapshot.finishingCount, 0, "the badge goes away with the finished job")
        let completed = await logger.events.first { $0.name == .dictationCompleted }
        XCTAssertEqual(completed?.jobID, firstID, "the timing line is still written")
        let rowWritten = await logger.events.contains { $0.attributes.reason?.rawValue == "hiddenCompletionDismissed" }
        XCTAssertTrue(rowWritten)

        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await engine.waitUntilStarted(count: 2)
        await engine.release()
        await controller.waitForCompletion()
        let kinds = await published.kinds(of: controller)
        XCTAssertFalse(kinds.contains(.completed) && kinds.firstIndex(of: .completed)! < kinds.lastIndex(of: .recording)!,
                       "the first job's completion never replaced the recorder, got \(kinds)")
        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["first", "second"])
    }

    // MARK: Diagnostics stay scalar

    func testOverlapDiagnosticsCarryNoTranscriptOrTarget() async throws {
        let engine = GatedEngine(results: ["the secret sentence", "another"])
        let logger = RecordingDiagnosticLogger()
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: engine,
            insertion: FakeTextInsertionService(target: target),
            diagnosticLogger: logger,
            overlappingJobs: Self.on
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await engine.waitUntilStarted(count: 1)
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await engine.release()
        await engine.waitUntilStarted(count: 2)
        await engine.release()
        await controller.waitForCompletion()

        let events = await logger.events.filter { $0.name == .dictationOverlapStarted || $0.name == .dictationOverlapRefused }
        XCTAssertEqual(events.count, 2)
        let encoder = JSONEncoder()
        for event in events {
            let json = String(decoding: try encoder.encode(event), as: UTF8.self)
            XCTAssertFalse(json.contains("secret"), json)
            XCTAssertFalse(json.contains("TextEdit"), json)
            XCTAssertTrue(json.contains("finishingCount"), json)
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

    private func waitForAIStart(_ ai: PerJobGatedAI, controller: DictationController) async -> JobID? {
        await settle(until: { await controller.state.kind == .processingAI })
        guard let jobID = await controller.state.jobID else {
            XCTFail("setup: the first job must be processing AI")
            return nil
        }
        await ai.waitUntilStarted(jobID: jobID)
        return jobID
    }

    /// Yields until the condition holds; fails instead of hanging.
    /// Polls `condition` until it holds, for at most `testYieldBudget`
    /// yields (a count, never time; the old 20,000 expired on a loaded
    /// machine while the controller was still on its way).
    private func settle(
        until condition: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var yields = 0
        while await !condition() {
            yields += 1
            if yields > testYieldBudget {
                return XCTFail("condition still false after \(testYieldBudget) yields", file: file, line: line)
            }
            await Task.yield()
        }
    }
}

// MARK: - Gated doubles

/// A transcription engine that answers requests in call order and, when
/// gated, holds each request until `release()`. Records which jobs reached
/// it, in order — the proof that passes are serialized.
private actor GatedEngine: TranscriptionEngine {
    let capabilities = TranscriptionCapabilities(
        supportsBatch: true,
        supportsStreaming: false,
        supportsCancellation: true,
        supportedSampleRate: 16_000,
        supportedChannelCount: 1
    )
    private(set) var loadedModelID: ModelID?
    private var results: [String]
    private let gated: Bool
    private(set) var startedJobIDs: [JobID] = []
    /// Requests that returned (normally or by cancellation), in order.
    private(set) var finishedJobIDs: [JobID] = []
    private var waiters: [(jobID: JobID, continuation: CheckedContinuation<Void, Never>)] = []

    init(results: [String], gated: Bool = true) {
        self.results = results
        self.gated = gated
    }

    var startedCount: Int { startedJobIDs.count }

    func load(_ package: InstalledModelPackage) async throws {
        loadedModelID = package.manifest.modelID
    }

    func unload() async {}

    func transcribe(
        _ request: TranscriptionRequest,
        events _: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> TranscriptionResult {
        startedJobIDs.append(request.jobID)
        let text = results.isEmpty ? "extra" : results.removeFirst()
        defer {
            finishedJobIDs.append(request.jobID)
        }
        if gated {
            // Like the real engines, a held pass returns on cancellation.
            let jobID = request.jobID
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume()
                    } else {
                        waiters.append((jobID, continuation))
                    }
                }
            } onCancel: {
                Task { await self.releaseOnCancel(jobID: jobID) }
            }
        }
        try Task.checkCancellation()
        let now = ContinuousClock().now
        return TranscriptionResult(
            text: text,
            detectedLanguage: nil,
            segments: [],
            timings: TranscriptionTimings(requestStart: now, inferenceStart: now, inferenceEnd: now, runtimeReportedRealTimeFactor: nil),
            modelID: "fixture"
        )
    }

    /// Returns once `count` requests reached the engine.
    func waitUntilStarted(count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        var yields = 0
        while startedJobIDs.count < count {
            yields += 1
            if yields > testYieldBudget {
                return XCTFail("waitUntilStarted: `startedJobIDs.count < count` still held after \(testYieldBudget) yields; startedJobIDs.count = \(startedJobIDs.count)", file: file, line: line)
            }
            await Task.yield()
        }
    }

    /// Returns once `count` requests returned (normally or cancelled).
    /// A cancelled job's runner can leave the controller before its held
    /// pass has returned, so `waitForCompletion()` does not cover it.
    func waitUntilFinished(count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        var yields = 0
        while finishedJobIDs.count < count {
            yields += 1
            if yields > testYieldBudget {
                return XCTFail("waitUntilFinished: `finishedJobIDs.count < count` still held after \(testYieldBudget) yields; finishedJobIDs.count = \(finishedJobIDs.count)", file: file, line: line)
            }
            await Task.yield()
        }
    }


    /// Lets the oldest held request return.
    func release() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    private func releaseOnCancel(jobID: JobID) {
        guard let index = waiters.firstIndex(where: { $0.jobID == jobID }) else { return }
        waiters.remove(at: index).continuation.resume()
    }
}

/// An AI client that holds each job's request until that job is released,
/// so a test can decide which job's AI finishes first.
private actor PerJobGatedAI: AIProcessingClient {
    private var started: Set<JobID> = []
    private var released: Set<JobID> = []
    private var cancelled: Set<JobID> = []
    private var waiters: [JobID: CheckedContinuation<Void, Never>] = [:]

    func validateConfiguration(_: AIEndpointSettings) throws {}

    func process(_ request: AIProcessRequest, settings _: AIEndpointSettings) async throws -> AIProcessResult {
        started.insert(request.jobID)
        if !released.contains(request.jobID) {
            await withCheckedContinuation { continuation in
                waiters[request.jobID] = continuation
            }
        }
        if Task.isCancelled {
            cancelled.insert(request.jobID)
            throw CancellationError()
        }
        return AIProcessResult(text: "polished \(request.rawTranscript)", requestDuration: .zero, responseID: nil)
    }

    func testConfiguration(_: AIEndpointSettings) async throws {}

    func cancel(jobID: JobID) async {
        release(jobID: jobID)
    }

    /// Returns once the job's request reached the client.
    func waitUntilStarted(jobID: JobID, file: StaticString = #filePath, line: UInt = #line) async {
        var yields = 0
        while !started.contains(jobID) {
            yields += 1
            if yields > testYieldBudget {
                return XCTFail("waitUntilStarted: `!started.contains(jobID)` still held after \(testYieldBudget) yields; started = \(started)", file: file, line: line)
            }
            await Task.yield()
        }
    }

    func observedCancellation(jobID: JobID) -> Bool {
        cancelled.contains(jobID)
    }

    func release(jobID: JobID) {
        released.insert(jobID)
        waiters.removeValue(forKey: jobID)?.resume()
    }
}

/// An insertion service that holds every `insert` until released, and can
/// be told to fail the held one instead.
private actor GatedInsertionService: TextInsertionService {
    private let target: TargetApplicationSnapshot
    private(set) var insertedTexts: [String] = []
    private(set) var clipboardTexts: [String] = []
    private var startedCount = 0
    private var waiters: [(jobID: JobID, continuation: CheckedContinuation<KVoiceError?, Never>)] = []
    /// When set, `captureTargetApplication` holds until `releaseCapture()`.
    private let gatedCapture: Bool
    private var captureStartedCount = 0
    private var captureWaiters: [CheckedContinuation<Void, Never>] = []

    init(target: TargetApplicationSnapshot, gatedCapture: Bool = false) {
        self.target = target
        self.gatedCapture = gatedCapture
    }

    func captureTargetApplication() async -> TargetApplicationSnapshot? {
        captureStartedCount += 1
        if gatedCapture {
            await withCheckedContinuation { continuation in
                captureWaiters.append(continuation)
            }
        }
        return target
    }

    /// Returns once `count` target captures have begun.
    func waitUntilCaptureStarted(count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        var yields = 0
        while captureStartedCount < count {
            yields += 1
            if yields > testYieldBudget {
                return XCTFail("waitUntilCaptureStarted: `captureStartedCount < count` still held after \(testYieldBudget) yields; captureStartedCount = \(captureStartedCount)", file: file, line: line)
            }
            await Task.yield()
        }
    }


    func releaseCapture() {
        guard !captureWaiters.isEmpty else { return }
        captureWaiters.removeFirst().resume()
    }

    func copyToClipboard(_ text: String, jobID _: JobID) async throws {
        clipboardTexts.append(text)
    }

    func insert(_ text: String, into _: TargetApplicationSnapshot, jobID: JobID) async throws -> InsertionOutcome {
        startedCount += 1
        // Like the real service's AX executor, a held insert returns on
        // cancellation without claiming anything.
        let failure = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<KVoiceError?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: KVoiceError(code: .appCancelled))
                } else {
                    waiters.append((jobID, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelHeldInsert(jobID: jobID) }
        }
        try Task.checkCancellation()
        if let failure { throw failure }
        insertedTexts.append(text)
        return .inserted(method: .selectedTextAttribute)
    }

    /// Returns once `count` inserts have begun.
    func waitUntilInsertStarted(count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        var yields = 0
        while startedCount < count {
            yields += 1
            if yields > testYieldBudget {
                return XCTFail("waitUntilInsertStarted: `startedCount < count` still held after \(testYieldBudget) yields; startedCount = \(startedCount)", file: file, line: line)
            }
            await Task.yield()
        }
    }

    func release() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume(returning: nil)
    }

    func fail(with error: KVoiceError) {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume(returning: error)
    }

    private func cancelHeldInsert(jobID: JobID) {
        guard let index = waiters.firstIndex(where: { $0.jobID == jobID }) else { return }
        waiters.remove(at: index).continuation.resume(returning: KVoiceError(code: .appCancelled))
    }
}

private actor RecordingDiagnosticLogger: DiagnosticLogging {
    private(set) var events: [DiagnosticEvent] = []

    func log(_ event: DiagnosticEvent) async {
        events.append(event)
    }
}

extension DictationControllerOverlapTests {
    // MARK: A job completing while the next start is still capturing its target

    /// Reviewer, 2026-09-16: the press is admitted before `startRecording`
    /// awaits the target capture; a job that completes in that window is
    /// still the shown one, so `runnerPipelineDidFinish` keeps it — and it
    /// would then sit as "Inserted" over the new job's phases. The sweep at
    /// admission dismisses it.
    func testAJobThatCompletesWhileTheNextStartCapturesItsTargetIsDismissedOnAdmission() async {
        let engine = GatedEngine(results: ["first", "second"], gated: false)
        let insertion = GatedInsertionService(target: target, gatedCapture: true)
        let logger = RecordingDiagnosticLogger()
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: engine,
            insertion: insertion,
            diagnosticLogger: logger,
            overlappingJobs: Resolved(true, .override)
        )
        // Unbounded and read once the controller is quiescent: the kinds
        // asserted below are every published snapshot, not whichever ones a
        // consumer task happened to see (`PublishedSnapshots`).
        let published = await PublishedSnapshots(controller)

        // A: its own capture, then held at the insert.
        let firstStart = Task { await controller.handleShortcut(.keyDown, mode: .pushToTalk) }
        await insertion.waitUntilCaptureStarted(count: 1)
        await insertion.releaseCapture()
        _ = await firstStart.value
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await insertion.waitUntilInsertStarted(count: 1)
        let firstID = await controller.state.jobID!

        // B: admitted, held at its target capture.
        let secondStart = Task { await controller.handleShortcut(.keyDown, mode: .pushToTalk) }
        await insertion.waitUntilCaptureStarted(count: 2)
        // A lands while B's capture is held: A is still the shown job.
        await insertion.release()
        await settle(until: { await controller.jobState(firstID)?.kind == .completed })
        let shownBeforeAdmission = await controller.state
        XCTAssertEqual(shownBeforeAdmission.kind, .completed)

        await insertion.releaseCapture()
        let second = await secondStart.value
        guard case .recording(let recording) = second else { return XCTFail("expected B recording, got \(second)") }
        let jobs = await controller.jobIDsInStartOrder
        XCTAssertEqual(jobs, [recording.jobID], "the completed job was swept at admission")
        let gone = await controller.jobState(firstID)
        XCTAssertNil(gone)
        let dismissed = await logger.events.contains { $0.jobID == firstID && $0.attributes.reason?.rawValue == "hiddenCompletionDismissed" }
        XCTAssertTrue(dismissed)
        let started = await logger.events.first { $0.name == .dictationOverlapStarted }
        XCTAssertEqual(started?.attributes.finishingCount, 0, "nothing was finishing once the completed job was swept")

        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await insertion.waitUntilInsertStarted(count: 2)
        await insertion.release()
        await controller.waitForCompletion()
        let kinds = await published.kinds(of: controller)
        let recordingIndex = kinds.lastIndex(of: .recording)!
        let completedAfterRecording = kinds[recordingIndex...].filter { $0 == .completed }
        XCTAssertEqual(completedAfterRecording.count, 1, "only B's own completion follows B's recording, got \(kinds)")
        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["first", "second"])
    }

    // MARK: Abandoned waiters: every queued continuation is resumed exactly once

    func testEscapeOnTheQueuedJobThenTheHeldJobLeavesNoWaiterBehind() async {
        let engine = GatedEngine(results: ["first", "second"])
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: engine,
            insertion: FakeTextInsertionService(target: target),
            overlappingJobs: Resolved(true, .override)
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await engine.waitUntilStarted(count: 1)
        let firstID = await controller.state.jobID!
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        let secondID = await controller.jobIDsInStartOrder.last!
        await settle(until: { await controller.jobState(secondID)?.kind == .transcribing })

        // B, queued on the engine, is escaped by id: its wait is abandoned.
        _ = await controller.cancel(for: secondID)
        var jobs = await controller.jobIDsInStartOrder
        XCTAssertEqual(jobs, [firstID])
        // A, holding the engine, is escaped: the held pass returns on
        // cancellation and the turn is released.
        _ = await controller.cancel()
        await controller.waitForCompletion()
        jobs = await controller.jobIDsInStartOrder
        XCTAssertTrue(jobs.isEmpty)
        // A's runner leaves on Escape; its held pass returns on the
        // cancellation a moment later, outside `waitForCompletion()`.
        await engine.waitUntilFinished(count: 1)
        let started = await engine.startedJobIDs
        XCTAssertEqual(started, [firstID], "the abandoned job never reached the engine")
        let finished = await engine.finishedJobIDs
        XCTAssertEqual(finished, [firstID])
        let idle = await controller.state
        XCTAssertEqual(idle, .idle)
    }

    func testEscapeOnTheHeldJobHandsTheEngineToTheQueuedJob() async {
        let engine = GatedEngine(results: ["first", "second"])
        let insertion = FakeTextInsertionService(target: target)
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: engine,
            insertion: insertion,
            overlappingJobs: Resolved(true, .override)
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await engine.waitUntilStarted(count: 1)
        let firstID = await controller.state.jobID!
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        let secondID = await controller.jobIDsInStartOrder.last!
        await settle(until: { await controller.jobState(secondID)?.kind == .transcribing })

        _ = await controller.cancel()   // A: the shown (oldest) job
        await engine.waitUntilStarted(count: 2)
        let started = await engine.startedJobIDs
        XCTAssertEqual(started, [firstID, secondID], "B got the engine once A's pass returned")
        await engine.release()
        await controller.waitForCompletion()
        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["second"])
        let jobs = await controller.jobIDsInStartOrder
        XCTAssertEqual(jobs, [secondID])
    }

    func testTerminateWithAJobQueuedOnTheEngineResumesItAndReturns() async {
        let engine = GatedEngine(results: ["first", "second"])
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: engine,
            insertion: FakeTextInsertionService(target: target),
            overlappingJobs: Resolved(true, .override)
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await engine.waitUntilStarted(count: 1)
        let firstID = await controller.state.jobID!
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        let secondID = await controller.jobIDsInStartOrder.last!
        await settle(until: { await controller.jobState(secondID)?.kind == .transcribing })

        _ = await controller.terminate()
        await controller.waitForCompletion()
        let first = await controller.jobState(firstID)
        let second = await controller.jobState(secondID)
        XCTAssertEqual(first, .terminating(firstID))
        XCTAssertEqual(second, .terminating(secondID))
        let started = await engine.startedJobIDs
        XCTAssertEqual(started, [firstID], "the queued job never reached the engine after quit")
    }

    func testTerminateWithAJobQueuedOnTheInsertionTurnResumesItAndReturns() async {
        let engine = GatedEngine(results: ["first", "second"], gated: false)
        let insertion = GatedInsertionService(target: target)
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: engine,
            insertion: insertion,
            overlappingJobs: Resolved(true, .override)
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await insertion.waitUntilInsertStarted(count: 1)
        let firstID = await controller.state.jobID!
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        let secondID = await controller.jobIDsInStartOrder.last!
        // B transcribed at once and now waits for A's insertion turn.
        await settle(until: { await controller.jobState(secondID)?.kind == .inserting })
        for _ in 0..<50 { await Task.yield() }
        var inserted = await insertion.insertedTexts
        XCTAssertTrue(inserted.isEmpty)

        _ = await controller.terminate()
        await controller.waitForCompletion()
        let first = await controller.jobState(firstID)
        let second = await controller.jobState(secondID)
        XCTAssertEqual(first, .terminating(firstID))
        XCTAssertEqual(second, .terminating(secondID))
        inserted = await insertion.insertedTexts
        XCTAssertTrue(inserted.isEmpty, "termination never performs a late insertion")
    }

    /// The reducer refused `.start` from `.terminating`; with no runner left
    /// after `.quit`, the coordinator has to remember that itself.
    func testNoStartIsAdmittedAfterQuit() async throws {
        let audio = FakeAudioCaptureService()
        let controller = DictationController(
            audio: audio,
            transcription: FakeTranscriptionEngine(result: nil),
            insertion: FakeTextInsertionService(target: target),
            overlappingJobs: Resolved(true, .override)
        )
        _ = await controller.terminate()
        let terminated = await controller.state
        XCTAssertEqual(terminated, .terminating(nil))

        let pressed = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        XCTAssertEqual(pressed, .terminating(nil))
        let recording = await audio.isRecording
        XCTAssertFalse(recording)
        let applied = try await controller.apply(.start(jobID: UUID(), prerequisites: .passed))
        XCTAssertEqual(applied, .terminating(nil))
        let jobs = await controller.jobIDsInStartOrder
        XCTAssertTrue(jobs.isEmpty)
    }
}
