import Foundation
import XCTest
import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceAppCore

/// Coverage for the dictation-loop behaviors reconciled against the spec on
/// 2026-09-13: start prerequisites (C.5 step 3), AI-fallback completion context
/// (D.4), the hard duration cap (FR-AUD-009), in-app delivery for the onboarding
/// test (C.2 step 9), the live history flag (FR-HIST-001), the aborted row at
/// termination (FR-LIFE-009), Escape during credential load, and the busy pulse
/// counter (C.6).
final class DictationControllerSpecGapTests: XCTestCase {
    private let target = TargetApplicationSnapshot(
        processIdentifier: 7,
        bundleIdentifier: "com.apple.TextEdit",
        localizedName: "TextEdit",
        capturedAt: Date(timeIntervalSince1970: 1)
    )

    // MARK: Prerequisites

    func testBlockedPrerequisiteShowsBlockedStateWithoutStartingCapture() async {
        let audio = FakeAudioCaptureService()
        let controller = DictationController(
            audio: audio,
            transcription: FakeTranscriptionEngine(result: transcript("x")),
            insertion: FakeTextInsertionService(target: target),
            prerequisiteChecker: { .blocked(.microphonePermission) }
        )

        let state = await controller.handleShortcut(.keyDown, mode: .pushToTalk)

        guard case .blocked(let reason) = state else {
            return XCTFail("expected blocked, got \(state)")
        }
        XCTAssertEqual(reason, .microphonePermission)
        let recording = await audio.isRecording
        XCTAssertFalse(recording)
        let job = await controller.activeJob
        XCTAssertNil(job)

        // The key-up of the same press must not do anything, and a dismiss
        // (Escape, auto-dismiss, or the menu) returns to idle.
        let afterKeyUp = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        XCTAssertEqual(afterKeyUp.kind, .blocked)
        let idle = await controller.handle(.dismiss)
        XCTAssertEqual(idle.kind, .idle)
    }

    func testPassedPrerequisiteStartsNormally() async {
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("x")),
            insertion: FakeTextInsertionService(target: target),
            prerequisiteChecker: { .passed }
        )
        let state = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        XCTAssertEqual(state.kind, .recording)
    }

    // MARK: AI fallback context

    func testAIFailureCompletionCarriesFallbackReasonForTheHUD() async {
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("raw text")),
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: aiSettings(mode: .polish)),
            ai: FakeAIProcessingClient(failure: KVoiceError(code: .aiTimeout))
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let state = await controller.state
        guard case .completed(_, let summary) = state else {
            return XCTFail("expected completed, got \(state)")
        }
        XCTAssertEqual(summary.insertion, .inserted(method: .selectedTextAttribute))
        XCTAssertEqual(summary.aiFallback, .aiTimeout)
        XCTAssertEqual(summary.warningMessage, KVoiceErrorCode.aiTimeout.userFacingMessage)
    }

    func testAISuccessCompletionHasNoFallbackContext() async {
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("raw text")),
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: aiSettings(mode: .polish)),
            ai: FakeAIProcessingClient(
                result: AIProcessResult(text: "Polished.", requestDuration: .zero, responseID: nil)
            )
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let successState = await controller.state
        guard case .completed(_, let summary) = successState else {
            return XCTFail("expected completed")
        }
        XCTAssertNil(summary.aiFallback)
        XCTAssertNil(summary.warningMessage)
    }

    // MARK: Hard duration cap

    func testDurationCapStopsAndProcessesWithoutAKeyUp() async {
        let audio = CapReportingAudioDouble()
        let insertion = FakeTextInsertionService(target: target)
        let controller = DictationController(
            audio: audio,
            transcription: FakeTranscriptionEngine(result: transcript("long dictation")),
            insertion: insertion
        )

        let started = await controller.handleShortcut(.keyDown, mode: .toggle)
        XCTAssertEqual(started.kind, .recording)

        await audio.reportCap()
        await waitUntilTerminal(controller)
        await controller.waitForCompletion()

        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["long dictation"])
        let cappedState = await controller.state
        guard case .completed(_, let summary) = cappedState else {
            return XCTFail("expected completed")
        }
        XCTAssertTrue(summary.durationCapReached)
        XCTAssertEqual(summary.warningMessage, "Recording stopped at the 10-minute limit.")

        // A late key-up (push-to-talk release after the cap) is inert.
        let afterKeyUp = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        XCTAssertEqual(afterKeyUp.kind, .completed)
        let stops = await audio.stopCount
        XCTAssertEqual(stops, 1)
    }

    // MARK: In-app delivery

    func testInAppDeliveryShowsTranscriptWithoutInsertionClipboardOrHistory() async {
        let insertion = FakeTextInsertionService(target: target)
        let history = InMemoryHistoryRepository()
        let ai = FakeAIProcessingClient(
            result: AIProcessResult(text: "must not run", requestDuration: .zero, responseID: nil)
        )
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("test phrase")),
            insertion: insertion,
            settings: FakeSettingsRepository(settings: aiSettings(mode: .polish)),
            ai: ai,
            history: history
        )

        let state = await controller.startRecording(delivery: .inApp)
        XCTAssertEqual(state.kind, .recording)
        _ = await controller.stopRecording()
        await controller.waitForCompletion()

        let delivered = await controller.inAppDeliveredText
        XCTAssertEqual(delivered?.text, "test phrase")
        let deliveredState = await controller.state
        guard case .completed(let jobID, let summary) = deliveredState else {
            return XCTFail("expected completed")
        }
        XCTAssertEqual(delivered?.jobID, jobID)
        XCTAssertEqual(summary.insertion, .deliveredInApp)

        let inserted = await insertion.insertedTexts
        let copied = await insertion.clipboardTexts
        let entries = await history.entries
        let requests = await ai.receivedRequests
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(requests.isEmpty, "the in-app test never processes with AI")
    }

    // MARK: History flag

    func testDisablingHistoryMidJobSuppressesThatJobsRow() async {
        let history = InMemoryHistoryRepository()
        let transcription = GatedTranscriptionDouble(result: transcript("late"))
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: transcription,
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: AppSettings(historyEnabled: true)),
            history: history
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await transcription.waitUntilStarted()
        await controller.setHistoryEnabled(false)
        await transcription.release()
        await controller.waitForCompletion()

        let entries = await history.entries
        XCTAssertTrue(entries.isEmpty)
        let finalKind = await controller.state.kind
        XCTAssertEqual(finalKind, .completed)
    }

    // MARK: Termination

    func testTerminationWithRawTranscriptWritesAbortedRowWhenHistoryEnabled() async {
        let history = InMemoryHistoryRepository()
        let ai = BlockingAIDouble()
        let insertion = FakeTextInsertionService(target: target)
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("almost done")),
            insertion: insertion,
            settings: FakeSettingsRepository(settings: aiSettings(mode: .polish, historyEnabled: true)),
            ai: ai,
            history: history
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await ai.waitUntilStarted()

        _ = await controller.terminate()
        await ai.release()
        await controller.waitForCompletion()

        let entries = await history.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.rawText, "almost done")
        XCTAssertEqual(entries.first?.insertionOutcome, .abortedAtTermination)
        let inserted = await insertion.insertedTexts
        XCTAssertTrue(inserted.isEmpty, "termination never performs a late insertion")
    }

    /// 2026-09-16 review: the shell bounds `terminate()` with a ~3 s
    /// deadline and exits either way, so the output volume must be restored
    /// *before* the aborted history row is written — a history store that
    /// stalls (a `HistoryRepository` cannot suspend inside `append`, so the
    /// stall is modelled as the order of the two calls) can then never
    /// leave the user muted after a quit.
    func testTerminationRestoresTheOutputVolumeBeforeWritingTheAbortedRow() async {
        let order = CallOrder()
        let history = OrderRecordingHistoryRepository(order: order)
        let muter = OrderRecordingOutputMuter(order: order)
        let ai = BlockingAIDouble()
        var settings = aiSettings(mode: .polish, historyEnabled: true)
        settings.recordingFeedback.muteSystemAudioDuringRecording = true
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("almost done")),
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: settings),
            ai: ai,
            history: history,
            outputMuter: muter
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await ai.waitUntilStarted()
        _ = await controller.terminate()
        await ai.release()
        await controller.waitForCompletion()

        XCTAssertEqual(order.calls, ["mute", "restore", "historyAppend"], "the volume comes back before anything that could stall")
        let appended = await history.appended
        XCTAssertEqual(appended.first?.insertionOutcome, .abortedAtTermination, "the aborted row is still written")
    }

    func testTerminationWithHistoryDisabledDiscardsTranscript() async {
        let history = InMemoryHistoryRepository()
        let ai = BlockingAIDouble()
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("discard me")),
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: aiSettings(mode: .polish, historyEnabled: false)),
            ai: ai,
            history: history
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await ai.waitUntilStarted()
        _ = await controller.terminate()
        await ai.release()
        await controller.waitForCompletion()

        let entries = await history.entries
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: Escape cancels the AI child task

    func testEscapeCancelsTheAIChildTaskSoALateProviderResultIsDiscarded() async {
        let ai = BlockingAIDouble()
        let insertion = FakeTextInsertionService(target: target)
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("raw wins")),
            insertion: insertion,
            settings: FakeSettingsRepository(settings: aiSettings(mode: .polish)),
            ai: ai,
            secrets: FakeSecretsRepository(settings: SecretSettings(apiKey: "k"))
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await ai.waitUntilStarted()

        _ = await controller.cancel()
        await controller.waitForCompletion()

        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["raw wins"])
        let cancelled = await ai.observedCancellation
        XCTAssertTrue(cancelled, "the provider task must observe cooperative cancellation")
    }

    // MARK: Busy pulse

    func testShortcutWhileProcessingIncrementsBusyCountWithoutQueuing() async {
        let transcription = GatedTranscriptionDouble(result: transcript("busy"))
        let audio = FakeAudioCaptureService()
        let controller = DictationController(
            audio: audio,
            transcription: transcription,
            insertion: FakeTextInsertionService(target: target)
        )

        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        _ = await controller.handleShortcut(.keyUp, mode: .toggle)
        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        _ = await controller.handleShortcut(.keyUp, mode: .toggle)
        await transcription.waitUntilStarted()

        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        _ = await controller.handleShortcut(.keyUp, mode: .toggle)
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)

        let busy = await controller.busyShortcutCount
        XCTAssertEqual(busy, 2)
        await transcription.release()
        await controller.waitForCompletion()
        let busyFinalKind = await controller.state.kind
        XCTAssertEqual(busyFinalKind, .completed)
        let starts = await audio.isRecording
        XCTAssertFalse(starts)
    }

    // MARK: Snapshot stream

    func testSnapshotStreamDeliversCurrentStateThenEveryLifecycleChange() async {
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("streamed")),
            insertion: FakeTextInsertionService(target: target)
        )
        let stream = await controller.snapshots()
        var iterator = stream.makeAsyncIterator()

        let first = await iterator.next()
        XCTAssertEqual(first?.state.kind, .idle)

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        // Newest-value buffering: a slow consumer still ends on the terminal
        // state rather than a backlog of intermediate ones.
        var latest: DictationController.Snapshot?
        for _ in 0..<20 {
            guard let next = await iterator.next() else { break }
            latest = next
            if next.state.kind == .completed { break }
        }
        XCTAssertEqual(latest?.state.kind, .completed)
    }

    func testLevelUpdatesAreCoalescedToTwentyHertz() async {
        let audio = LevelBurstAudioDouble()
        let controller = DictationController(
            audio: audio,
            transcription: FakeTranscriptionEngine(result: transcript("x")),
            insertion: FakeTextInsertionService(target: target)
        )
        let stream = await controller.snapshots()
        let collector = SnapshotCollector()
        let consumer = Task {
            for await snapshot in stream {
                await collector.append(snapshot)
            }
        }

        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        // Ten level events with no time passing between them: only the first
        // may reach the HUD; the rest are coalesced.
        await audio.burst(levels: Array(repeating: -20, count: 10))
        await Task.yield()
        let level = await controller.hudInputLevel
        XCTAssertEqual(level, (60 - 20) / 60, accuracy: 0.0001)

        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        await controller.waitForCompletion()
        consumer.cancel()

        let levelChanges = await collector.snapshots.map(\.inputLevel)
        let distinct = Set(levelChanges.map { ($0 * 1_000).rounded() })
        XCTAssertLessThanOrEqual(distinct.count, 3, "one burst must not fan out into ten HUD updates")
    }

    // MARK: Silence gate (FR-AUD-008)

    private func recording(peak: Float) -> AudioRecording {
        AudioRecording(
            samples: ContiguousArray(repeating: 0.01, count: 16_000),
            duration: .seconds(1),
            peakLevelDBFS: peak,
            clippedFrameCount: 0
        )
    }

    func testNearSilentRecordingNeverReachesTheModel() async {
        let insertion = FakeTextInsertionService(target: target)
        let controller = DictationController(
            audio: FakeAudioCaptureService(recording: recording(peak: -70)),
            transcription: FakeTranscriptionEngine(result: transcript("Thank you.")),
            insertion: insertion
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let state = await controller.state
        guard case .failed(_, let failure) = state else {
            return XCTFail("expected failed, got \(state)")
        }
        XCTAssertEqual(failure.code, KVoiceErrorCode.audioNoSamples.rawValue)
        let inserted = await insertion.insertedTexts
        XCTAssertTrue(inserted.isEmpty)
    }

    func testQuietRecordingWithHallucinationPhraseIsRejected() async {
        let insertion = FakeTextInsertionService(target: target)
        let controller = DictationController(
            audio: FakeAudioCaptureService(recording: recording(peak: -40)),
            transcription: FakeTranscriptionEngine(result: transcript("Thank you.")),
            insertion: insertion
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let state = await controller.state
        guard case .failed(_, let failure) = state else {
            return XCTFail("expected failed, got \(state)")
        }
        XCTAssertEqual(failure.code, KVoiceErrorCode.sttEmpty.rawValue)
        let inserted = await insertion.insertedTexts
        XCTAssertTrue(inserted.isEmpty)
    }

    func testLoudRecordingSayingThankYouIsInserted() async {
        let insertion = FakeTextInsertionService(target: target)
        let controller = DictationController(
            audio: FakeAudioCaptureService(recording: recording(peak: -10)),
            transcription: FakeTranscriptionEngine(result: transcript("Thank you.")),
            insertion: insertion
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["Thank you."])
    }

    /// 2026-09-13 user report: speech, then the key held over a silent tail.
    /// The recording as a whole is loud, so the whole-recording gates above
    /// do not apply; the tail is trimmed from the model's input and a
    /// trailing "Thank you." segment over the quiet remainder is dropped,
    /// while history keeps the recorded length.
    func testHeldKeyOverASilentTailDoesNotInsertThankYou() async {
        let rate = 16_000
        let speech = ContiguousArray((0..<(2 * rate)).map { Float(sin(Double($0) / 16_000 * 2 * .pi * 220)) * 0.3 })
        let quietTail = ContiguousArray(repeating: Float(0.001), count: 2 * rate) // -60 dBFS
        let recording = AudioRecording(
            samples: speech + quietTail,
            duration: .seconds(4),
            peakLevelDBFS: -10,
            clippedFrameCount: 0
        )
        let segments = [
            TranscriptSegment(start: .zero, end: .seconds(2), text: " Hello there."),
            // Whisper pads to 30 s, so the hallucinated tail segment overruns
            // the real audio; the check clamps it.
            TranscriptSegment(start: .seconds(2), end: .seconds(30), text: " Thank you.")
        ]
        let engine = FakeTranscriptionEngine(
            result: transcript(" Hello there. Thank you.", segments: segments)
        )
        let insertion = FakeTextInsertionService(target: target)
        let history = InMemoryHistoryRepository()
        let logger = RecordingDiagnosticLogger()
        let controller = DictationController(
            audio: FakeAudioCaptureService(recording: recording),
            transcription: engine,
            insertion: insertion,
            settings: FakeSettingsRepository(settings: AppSettings(historyEnabled: true)),
            history: history,
            diagnosticLogger: logger
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["Hello there."])

        let handed = await engine.receivedAudioSampleCounts
        XCTAssertEqual(handed.count, 1)
        XCTAssertEqual(handed.first ?? 0, Int(2.4 * Double(rate)), accuracy: rate / 10,
                       "the model sees the speech plus about 0.4 s of tail")

        let entries = await history.entries
        XCTAssertEqual(entries.first?.rawText, "Hello there.")
        XCTAssertEqual(entries.first?.recordingDurationMilliseconds, 4_000, "history reports the recorded length")

        let dropped = await logger.events.filter { $0.name == .sttSegmentsDropped }
        XCTAssertEqual(dropped.count, 1)
        XCTAssertEqual(dropped.first?.attributes.reason?.rawValue, "trailingHallucinationDropped")
        XCTAssertEqual(dropped.first?.attributes.segmentCount, 1)
        XCTAssertEqual(dropped.first?.result, .warning)
    }

    // MARK: Helpers

    private func waitUntilTerminal(_ controller: DictationController) async {
        for _ in 0..<2_000 {
            let kind = await controller.state.kind
            if kind == .completed || kind == .failed || kind == .idle { return }
            await Task.yield()
        }
    }

    private func aiSettings(mode: DictationMode, historyEnabled: Bool = true) -> AppSettings {
        AppSettings(
            ai: AIEndpointSettings(
                mode: mode,
                baseURL: mode == .off ? nil : URL(string: "http://127.0.0.1:11434/v1"),
                modelID: mode == .off ? "" : "fixture-model",
                translationLanguage: .init(bcp47: "en", displayName: "English")
            ),
            historyEnabled: historyEnabled
        )
    }

    private func transcript(_ text: String, segments: [TranscriptSegment] = []) -> TranscriptionResult {
        let now = ContinuousClock().now
        return TranscriptionResult(
            text: text,
            detectedLanguage: nil,
            segments: segments,
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

/// Models the recorder at the hard cap: it parks the finished recording and
/// then reports `.warning(.durationCap)`, exactly as `AVAudioCaptureService`
/// does, so `stop` must find the completed recording.
private actor CapReportingAudioDouble: AudioCaptureService {
    private(set) var isRecording = false
    private(set) var stopCount = 0
    private var sink: (@Sendable (AudioCaptureEvent) async -> Void)?
    private var parked: AudioRecording?

    func start(jobID _: JobID, events: @escaping @Sendable (AudioCaptureEvent) async -> Void) async throws {
        isRecording = true
        sink = events
        await events(.elapsed(.zero))
    }

    func stop(jobID _: JobID) async throws -> AudioRecording {
        stopCount += 1
        isRecording = false
        if let parked {
            self.parked = nil
            return parked
        }
        return DomainFixtures.audio()
    }

    func cancel(jobID _: JobID) async {
        isRecording = false
    }

    func runMicrophoneTest(
        duration: Duration,
        levels _: (@Sendable (AudioCaptureEvent) async -> Void)?
    ) async throws -> MicrophoneTestResult {
        MicrophoneTestResult(duration: duration, peakLevelDBFS: -20, capturedSamples: 0)
    }

    func reportCap() async {
        parked = DomainFixtures.audio(duration: .seconds(600))
        isRecording = false
        await sink?(.warning(.durationCap))
    }
}

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

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor BlockingAIDouble: AIProcessingClient {
    private var started = false
    private var released = false
    private(set) var observedCancellation = false
    private var continuation: CheckedContinuation<Void, Never>?

    func validateConfiguration(_: AIEndpointSettings) throws {}

    func process(_: AIProcessRequest, settings _: AIEndpointSettings) async throws -> AIProcessResult {
        started = true
        if !released {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        if Task.isCancelled {
            observedCancellation = true
            throw CancellationError()
        }
        return AIProcessResult(text: "late provider text", requestDuration: .zero, responseID: nil)
    }

    func testConfiguration(_: AIEndpointSettings) async throws {}

    func cancel(jobID _: JobID) async {
        release()
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor SnapshotCollector {
    private(set) var snapshots: [DictationController.Snapshot] = []

    func append(_ snapshot: DictationController.Snapshot) {
        snapshots.append(snapshot)
    }
}

/// Feeds a burst of level events through the capture sink on demand.
private actor LevelBurstAudioDouble: AudioCaptureService {
    private(set) var isRecording = false
    private var sink: (@Sendable (AudioCaptureEvent) async -> Void)?

    func start(jobID _: JobID, events: @escaping @Sendable (AudioCaptureEvent) async -> Void) async throws {
        isRecording = true
        sink = events
        await events(.elapsed(.zero))
    }

    func stop(jobID _: JobID) async throws -> AudioRecording {
        isRecording = false
        return DomainFixtures.audio()
    }

    func cancel(jobID _: JobID) async {
        isRecording = false
    }

    func runMicrophoneTest(
        duration: Duration,
        levels _: (@Sendable (AudioCaptureEvent) async -> Void)?
    ) async throws -> MicrophoneTestResult {
        MicrophoneTestResult(duration: duration, peakLevelDBFS: -20, capturedSamples: 0)
    }

    func burst(levels: [Float]) async {
        for level in levels {
            await sink?(.level(rmsDBFS: level, peakDBFS: level))
        }
    }
}

/// The order in which the termination path touched its collaborators. A
/// lock, not an actor, so a synchronous `HistoryRepository.append` can
/// record its turn in place.
private final class CallOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ call: String) {
        lock.lock()
        storage.append(call)
        lock.unlock()
    }
}

private actor OrderRecordingOutputMuter: SystemOutputMuting {
    private let order: CallOrder

    init(order: CallOrder) { self.order = order }

    func mute() async { order.record("mute") }
    func restore() async { order.record("restore") }
}

/// Records every appended row and where in the call order it landed.
private actor OrderRecordingHistoryRepository: HistoryRepository {
    private let order: CallOrder
    private(set) var appended: [HistoryEntry] = []

    init(order: CallOrder) { self.order = order }

    func migrateIfNeeded() throws {}
    func append(_ entry: HistoryEntry) throws {
        appended.append(entry)
        order.record("historyAppend")
    }
    func fetchPage(before _: Date?, limit _: Int) throws -> [HistoryEntry] { [] }
    func delete(id _: HistoryEntryID) throws {}
    func deleteAll() throws {}
    func count() throws -> Int { 0 }
    func storageSizeBytes() throws -> Int64 { 0 }
    func search(_: String, limit _: Int) throws -> [HistoryEntry] { [] }
}
