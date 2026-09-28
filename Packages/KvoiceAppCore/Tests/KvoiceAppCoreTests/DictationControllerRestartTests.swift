import Foundation
import XCTest
import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceAppCore

/// ADR-022 item 6 amendment (2026-09-16): a terminal HUD (`.completed`,
/// `.failed`, `.blocked`) lingers on screen for its auto-dismiss window
/// (`HUDViewState.autoDismissAfter`: 3.5 s for failure/blocked, 0.9 s for
/// success). Before this change, a shortcut press during that window was
/// swallowed by the controller's idle-only start guard — logged as
/// `logIgnoredStart` and surfaced to the shell as the C.6 busy pulse — so the
/// user had to wait out the timer before pressing again. The user's instinct
/// after a failure is to press again immediately.
///
/// `DictationController.startRecording` now treats a press in one of the
/// three terminal kinds as "dismiss and go again": it applies `.dismiss`
/// (terminal -> idle) and then the ordinary start (idle -> recording) — two
/// reducer-applied snapshots, never a direct terminal -> recording edge.
/// The public `snapshots()` stream keeps only the newest value, so a slow
/// observer may coalesce the two; these tests read an unbounded stream to
/// assert that both were published. Processing states (`finalizing`, `transcribing`, `processingAI`,
/// `inserting`) are unchanged by this file: still ignored with the busy
/// pulse (ADR-022 item 6, the C.6 slice).
final class DictationControllerRestartTests: XCTestCase {
    private let target = TargetApplicationSnapshot(
        processIdentifier: 7,
        bundleIdentifier: "com.apple.TextEdit",
        localizedName: "TextEdit",
        capturedAt: Date(timeIntervalSince1970: 1)
    )

    // MARK: Failed, with a retained recoverable transcript (push-to-talk)

    func testKeyDownInFailedDismissesAndStartsANewRecordingDiscardingTheRetainedText() async {
        let insertion = FakeTextInsertionService(target: target)
        await insertion.setFailure(KVoiceError(code: .accessibilityVerifyFailed, retryable: false))
        let logger = RecordingDiagnosticLogger()
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("hello")),
            insertion: insertion,
            diagnosticLogger: logger
        )
        // Unbounded, and read only once the controller is quiescent: every
        // published snapshot is asserted, none depends on when a consumer
        // task happens to run (the newest-only default drops transients).
        let published = await PublishedSnapshots(controller)

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let failedState = await controller.state
        guard case .failed(let failedJobID?, _) = failedState else {
            return XCTFail("expected a failed job, got \(failedState)")
        }
        let canRecoverBefore = await controller.canRecoverFailedInsertion
        XCTAssertTrue(canRecoverBefore, "setup: a retained transcript, or there is nothing to discard")

        // The next attempt succeeds, so the restarted job can finish.
        await insertion.setFailure(nil)

        let restarted = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        XCTAssertEqual(restarted.kind, .recording)
        XCTAssertNotEqual(restarted.jobID, failedJobID, "a fresh job, not the failed one resumed")

        let canRecoverAfter = await controller.canRecoverFailedInsertion
        XCTAssertFalse(canRecoverAfter, "the retained text was discarded, not carried to the new job")
        let retainedAfter = await controller.exactFinalTextForFallback
        XCTAssertNil(retainedAfter)

        let busyCount = await controller.busyShortcutCount
        XCTAssertEqual(busyCount, 0, "a restart is admitted, not the busy/ignored path")
        let ignored = await logger.events.filter { $0.attributes.reason?.rawValue == "startWhileBusy" }
        XCTAssertTrue(ignored.isEmpty, "the press must not be logged as an ignored start")

        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()
        let finalKind = await controller.state.kind
        XCTAssertEqual(finalKind, .completed)

        let kinds = await published.kinds(of: controller)
        guard let failedIndex = kinds.firstIndex(of: .failed) else {
            return XCTFail("expected the failed snapshot to be observed, got \(kinds)")
        }
        guard let idleIndex = kinds[failedIndex...].firstIndex(of: .idle) else {
            return XCTFail("expected an idle snapshot between failed and recording, got \(kinds)")
        }
        XCTAssertNotNil(
            kinds[idleIndex...].firstIndex(of: .recording),
            "expected failed -> idle -> recording, never a direct jump, got \(kinds)"
        )
    }

    // MARK: Completed (toggle)

    func testKeyDownInCompletedDismissesAndStartsANewRecording() async {
        let insertion = FakeTextInsertionService(target: target)
        let logger = RecordingDiagnosticLogger()
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("hello")),
            insertion: insertion,
            diagnosticLogger: logger
        )
        // Unbounded, and read only once the controller is quiescent: every
        // published snapshot is asserted, none depends on when a consumer
        // task happens to run (the newest-only default drops transients).
        let published = await PublishedSnapshots(controller)

        // Toggle: keyDown starts, keyUp is a no-op (it only clears the
        // physical-key latch), a second keyDown/keyUp pair stops.
        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        _ = await controller.handleShortcut(.keyUp, mode: .toggle)
        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        _ = await controller.handleShortcut(.keyUp, mode: .toggle)
        await controller.waitForCompletion()
        let completedState = await controller.state
        guard case .completed(let completedJobID, _) = completedState else {
            return XCTFail("expected completed, got \(completedState)")
        }

        let restarted = await controller.handleShortcut(.keyDown, mode: .toggle)
        XCTAssertEqual(restarted.kind, .recording)
        XCTAssertNotEqual(restarted.jobID, completedJobID)
        let busyCount = await controller.busyShortcutCount
        XCTAssertEqual(busyCount, 0)
        let ignored = await logger.events.filter { $0.attributes.reason?.rawValue == "startWhileBusy" }
        XCTAssertTrue(ignored.isEmpty)

        _ = await controller.handleShortcut(.keyUp, mode: .toggle)
        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        _ = await controller.handleShortcut(.keyUp, mode: .toggle)
        await controller.waitForCompletion()

        let kinds = await published.kinds(of: controller)
        guard let completedIndex = kinds.firstIndex(of: .completed) else {
            return XCTFail("expected the completed snapshot to be observed, got \(kinds)")
        }
        guard let idleIndex = kinds[completedIndex...].firstIndex(of: .idle) else {
            return XCTFail("expected an idle snapshot between completed and recording, got \(kinds)")
        }
        XCTAssertNotNil(
            kinds[idleIndex...].firstIndex(of: .recording),
            "expected completed -> idle -> recording, never a direct jump, got \(kinds)"
        )
    }

    // MARK: Blocked (hybrid)

    func testKeyDownInBlockedDismissesAndStartsANewRecordingOncePrerequisitesPass() async {
        let clock = ManualClock()
        let prerequisites = PrerequisiteBox(.blocked(.microphonePermission))
        let logger = RecordingDiagnosticLogger()
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("hello")),
            insertion: FakeTextInsertionService(target: target),
            diagnosticLogger: logger,
            prerequisiteChecker: { await prerequisites.check() },
            clock: clock
        )

        let blocked = await controller.handleShortcut(.keyDown, mode: .hybrid, at: clock.now)
        guard case .blocked(let reason) = blocked else {
            return XCTFail("expected blocked, got \(blocked)")
        }
        XCTAssertEqual(reason, .microphonePermission)
        clock.advance(by: .milliseconds(50))
        _ = await controller.handleShortcut(.keyUp, mode: .hybrid, at: clock.now)

        // The permission is granted between the failed attempt and the retry.
        await prerequisites.set(.passed)

        let restarted = await controller.handleShortcut(.keyDown, mode: .hybrid, at: clock.now)
        XCTAssertEqual(restarted.kind, .recording, "the dismissed block must not stop the retried start")
        let busyCount = await controller.busyShortcutCount
        XCTAssertEqual(busyCount, 0)
        let ignored = await logger.events.filter { $0.attributes.reason?.rawValue == "startWhileBusy" }
        XCTAssertTrue(ignored.isEmpty)

        // A hold, so the release stops the new recording cleanly.
        clock.advance(by: .seconds(1))
        _ = await controller.handleShortcut(.keyUp, mode: .hybrid, at: clock.now)
        await controller.waitForCompletion()
        let finalKind = await controller.state.kind
        XCTAssertEqual(finalKind, .completed)
    }

    // MARK: A failure's restart can be re-blocked

    func testKeyDownInFailedThatIsStillBlockedShowsBlockedNotADirectRecording() async {
        let prerequisites = PrerequisiteBox(.passed)
        let insertion = FakeTextInsertionService(target: target)
        await insertion.setFailure(KVoiceError(code: .accessibilityVerifyFailed, retryable: false))
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("hello")),
            insertion: insertion,
            prerequisiteChecker: { await prerequisites.check() }
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()
        let failedKind = await controller.state.kind
        XCTAssertEqual(failedKind, .failed)

        // Whatever the pipeline needs (a model, say) went away in the meantime.
        await prerequisites.set(.blocked(.modelUnavailable))

        let restarted = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        guard case .blocked(let reason) = restarted else {
            return XCTFail("expected the still-true prerequisite to surface as blocked, got \(restarted)")
        }
        XCTAssertEqual(reason, .modelUnavailable)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
    }

    // MARK: Processing states are unchanged (regression)

    func testKeyDownWhileTranscribingIsStillIgnored() async {
        let transcription = GatedTranscriptionDouble(result: transcript("hello"))
        let logger = RecordingDiagnosticLogger()
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: transcription,
            insertion: FakeTextInsertionService(target: target),
            diagnosticLogger: logger
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        // The pipeline is parked in `.transcribing` until the gate is released.
        await transcription.waitUntilStarted()
        let busyKind = await controller.state.kind
        XCTAssertEqual(busyKind, .transcribing, "setup: the job must still be busy")

        let stillIgnored = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        XCTAssertEqual(stillIgnored.kind, .transcribing, "unchanged: a busy press is still swallowed")
        let busyCount = await controller.busyShortcutCount
        XCTAssertEqual(busyCount, 1)
        let ignored = await logger.events.filter { $0.attributes.reason?.rawValue == "startWhileBusy" }
        XCTAssertEqual(ignored.count, 1)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)

        await transcription.release()
        await controller.waitForCompletion()
        let finalKind = await controller.state.kind
        XCTAssertEqual(finalKind, .completed)
    }

    // MARK: Helpers

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

// MARK: - Doubles

private actor RecordingDiagnosticLogger: DiagnosticLogging {
    private(set) var events: [DiagnosticEvent] = []

    func log(_ event: DiagnosticEvent) async {
        events.append(event)
    }
}

/// A mutable prerequisite result, so a test can flip the outcome between the
/// original attempt and the restart (a permission granted, a model that
/// became unavailable).
private actor PrerequisiteBox {
    private var value: StartPrerequisites

    init(_ value: StartPrerequisites) {
        self.value = value
    }

    func set(_ value: StartPrerequisites) {
        self.value = value
    }

    func check() async -> StartPrerequisites {
        value
    }
}

/// A transcription engine that parks the pipeline in `.transcribing` until
/// the test releases it, so a keyDown while genuinely busy can be exercised
/// deterministically (no real time, no polling on a clock). Mirrors
/// `GatedTranscriptionDouble` in `DictationControllerSpecGapTests`.
private actor GatedTranscriptionDouble: TranscriptionEngine {
    let capabilities = TranscriptionCapabilities(
        supportsBatch: true,
        supportsStreaming: false,
        supportsCancellation: true,
        supportedSampleRate: 16_000,
        supportedChannelCount: 1
    )
    private(set) var loadedModelID: ModelID?
    private let result: TranscriptionResult
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(result: TranscriptionResult) {
        self.result = result
    }

    func load(_ package: InstalledModelPackage) async throws {
        loadedModelID = package.manifest.modelID
    }

    func unload() async {}

    func transcribe(
        _: TranscriptionRequest,
        events _: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> TranscriptionResult {
        started = true
        if !released {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        try Task.checkCancellation()
        return result
    }

    /// Returns once `transcribe` has been entered (never real time; fails
    /// after `testYieldBudget` yields).
    func waitUntilStarted(file: StaticString = #filePath, line: UInt = #line) async {
        var yields = 0
        while !started {
            yields += 1
            if yields > testYieldBudget {
                return XCTFail("waitUntilStarted: `!started` still held after \(testYieldBudget) yields; started = \(started)", file: file, line: line)
            }
            await Task.yield()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
