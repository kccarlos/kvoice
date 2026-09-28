import Foundation
import XCTest
import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceAppCore

/// ADR-017: the controller starts a streaming session only for a model set to
/// streaming mode, forwards captured chunks to the engine, publishes partials
/// in its snapshot only while the job is recording/finalizing/transcribing,
/// ends the session before the batch pass, and never publishes a partial
/// after Escape. The transcription-language setting reaches both paths.
final class DictationControllerStreamingTests: XCTestCase {
    private let target = TargetApplicationSnapshot(
        processIdentifier: 7,
        bundleIdentifier: "com.apple.TextEdit",
        localizedName: "TextEdit",
        capturedAt: Date(timeIntervalSince1970: 1)
    )

    func testStreamingModeStartsSessionForwardsChunksPublishesPartialsAndEndsBeforeBatch() async throws {
        let audio = FakeStreamingAudioCaptureService()
        let engine = FakeStreamingTranscriptionEngine(result: transcript("final words"))
        let controller = DictationController(
            audio: audio,
            transcription: engine,
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: settings(mode: .streaming, language: "zh"))
        )

        let state = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        XCTAssertEqual(state.kind, .recording)
        let jobID = try XCTUnwrap(state.jobID)

        let streaming = await engine.isStreaming
        XCTAssertTrue(streaming)
        let calls = await engine.calls
        XCTAssertEqual(calls, [.beginStreaming(jobID, languageHint: "zh")])
        let snapshot = await controller.snapshot
        XCTAssertEqual(snapshot.partialTranscript, "", "the HUD line is reserved from the start")
        let hasSink = await audio.hasSink
        XCTAssertTrue(hasSink)

        let delivered = await audio.pushChunk(AudioSampleChunk(samples: ContiguousArray(repeating: 0, count: 320)))
        XCTAssertTrue(delivered)
        let appended = await engine.appendedSampleCount
        XCTAssertEqual(appended, 320)

        let emitted = await engine.emitPartial("hello wor")
        XCTAssertTrue(emitted)
        let live = await controller.snapshot
        XCTAssertEqual(live.partialTranscript, "hello wor")
        XCTAssertEqual(live.state.kind, .recording)

        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let finalCalls = await engine.calls
        XCTAssertEqual(
            finalCalls,
            [
                .beginStreaming(jobID, languageHint: "zh"),
                .endStreaming(jobID),
                .transcribe(jobID, languageHint: "zh")
            ],
            "the session ends before the batch pass, and the language hint reaches both"
        )
        let done = await controller.snapshot
        XCTAssertEqual(done.state.kind, .completed)
        XCTAssertNil(done.partialTranscript, "an outcome never carries partial text")
        let job = await controller.activeJob
        XCTAssertEqual(job?.finalText, "final words", "only the batch result is ever inserted")
    }

    func testEscapeClearsPartialsImmediatelyAndALatePartialIsNotPublished() async throws {
        let audio = FakeStreamingAudioCaptureService()
        let engine = FakeStreamingTranscriptionEngine(result: transcript("never"))
        let controller = DictationController(
            audio: audio,
            transcription: engine,
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: settings(mode: .streaming, language: nil))
        )

        let state = await controller.handleShortcut(.keyDown, mode: .toggle)
        let jobID = try XCTUnwrap(state.jobID)
        await engine.emitPartial("some words")
        let before = await controller.snapshot
        XCTAssertEqual(before.partialTranscript, "some words")

        // Capture the engine's sink as a pass in flight would, then Escape.
        let capturedSink = await engine.captureEventSink()
        let lateSink = try XCTUnwrap(capturedSink)
        let escaped = await controller.cancel()
        XCTAssertEqual(escaped.kind, .idle)
        let after = await controller.snapshot
        XCTAssertNil(after.partialTranscript, "Escape drops the partial before any service is told")

        await lateSink(.partialText("late words"))
        let afterLate = await controller.snapshot
        XCTAssertNil(afterLate.partialTranscript, "a pass finishing after Escape publishes nothing")

        // The engine was told to end the session (asynchronously).
        for _ in 0..<50 where await engine.isStreaming {
            await Task.yield()
        }
        let ended = await engine.calls.contains(.endStreaming(jobID))
        XCTAssertTrue(ended)
        let batch = await engine.calls.contains { call in
            if case .transcribe = call { return true }
            return false
        }
        XCTAssertFalse(batch, "Escape while recording never transcribes")
    }

    func testBatchModeNeverStartsASessionAndPartialStaysNil() async throws {
        let audio = FakeStreamingAudioCaptureService()
        let engine = FakeStreamingTranscriptionEngine(result: transcript("batch text"))
        let controller = DictationController(
            audio: audio,
            transcription: engine,
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: settings(mode: .batch, language: "en"))
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        let streaming = await engine.isStreaming
        XCTAssertFalse(streaming)
        let hasSink = await audio.hasSink
        XCTAssertFalse(hasSink)
        let snapshot = await controller.snapshot
        XCTAssertNil(snapshot.partialTranscript)

        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()
        let calls = await engine.calls
        guard case .transcribe(_, let hint)? = calls.first, calls.count == 1 else {
            return XCTFail("expected exactly one batch pass, got \(calls)")
        }
        XCTAssertEqual(hint, "en", "the language setting is a hint on the batch path too")
    }

    func testStreamingIsSkippedWhenTheEngineCannotStreamOrTheSessionFailsToStart() async throws {
        // Capability off.
        let plainEngine = FakeStreamingTranscriptionEngine(result: transcript("x"), supportsStreaming: false)
        let plainController = DictationController(
            audio: FakeStreamingAudioCaptureService(),
            transcription: plainEngine,
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: settings(mode: .streaming, language: nil))
        )
        _ = await plainController.handleShortcut(.keyDown, mode: .pushToTalk)
        let plainSnapshot = await plainController.snapshot
        XCTAssertNil(plainSnapshot.partialTranscript)
        let plainCalls = await plainEngine.calls
        XCTAssertTrue(plainCalls.isEmpty)
        _ = await plainController.cancel()

        // Session refuses to start: the dictation continues on the batch path.
        let failingEngine = FakeStreamingTranscriptionEngine(result: transcript("still inserted"))
        await failingEngine.setBeginFailure(KVoiceError(code: .modelLoadFailed))
        let controller = DictationController(
            audio: FakeStreamingAudioCaptureService(),
            transcription: failingEngine,
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: settings(mode: .streaming, language: nil))
        )
        let state = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        XCTAssertEqual(state.kind, .recording)
        let snapshot = await controller.snapshot
        XCTAssertNil(snapshot.partialTranscript)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()
        let done = await controller.state
        XCTAssertEqual(done.kind, .completed)
    }

    // MARK: Helpers

    // MARK: Dictionary (ADR-018)

    func testTheJobsDictionaryReachesTheStreamingSessionAndTheBatchPass() async throws {
        let audio = FakeStreamingAudioCaptureService()
        let engine = FakeStreamingTranscriptionEngine(result: transcript("kvoice"))
        let settingsStore = FakeSettingsRepository(
            settings: settings(mode: .streaming, language: nil, terms: ["kvoice", "WhisperKit"])
        )
        let controller = DictationController(
            audio: audio,
            transcription: engine,
            insertion: FakeTextInsertionService(target: target),
            settings: settingsStore
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        // Edited mid-job: the job keeps its snapshot, so the batch pass must
        // still send the list the job started with.
        try await settingsStore.save(settings(mode: .streaming, language: nil, terms: ["changed"]))
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let prompts = await engine.receivedInitialPrompts
        XCTAssertEqual(prompts, ["Glossary: kvoice, WhisperKit.", "Glossary: kvoice, WhisperKit."])
    }

    func testAnEmptyDictionarySendsNoPrompt() async throws {
        let engine = FakeStreamingTranscriptionEngine(result: transcript("plain"))
        let controller = DictationController(
            audio: FakeStreamingAudioCaptureService(),
            transcription: engine,
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: settings(mode: .batch, language: nil))
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let prompts = await engine.receivedInitialPrompts
        XCTAssertEqual(prompts, [nil])
    }

    private func settings(mode: SpeechTranscriptionMode, language: String?, terms: [String] = []) -> AppSettings {
        AppSettings(
            ai: AIEndpointSettings(mode: .off, modelID: "kvoice-fixture"),
            transcriptionLanguage: language,
            speechModelModes: ["fixture-model": mode],
            dictionary: DictionarySettings(terms: terms)
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
            modelID: "fixture-model"
        )
    }
}
