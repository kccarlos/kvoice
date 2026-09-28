import Foundation
import XCTest
import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceAppCore

/// The per-job timing line (2026-09-16): one `dictation.completed` per job
/// that reaches `.completed`, the timing scalars measured so far on every
/// `dictation.failed`, and nothing on a cancelled job. Every duration comes
/// from the controller's injected clock, which the doubles below advance by
/// a known amount at each service call, so the expected numbers are exact.
final class DictationControllerDiagnosticsTests: XCTestCase {
    private let target = TargetApplicationSnapshot(
        processIdentifier: 7,
        bundleIdentifier: "com.apple.TextEdit",
        localizedName: "TextEdit",
        capturedAt: Date(timeIntervalSince1970: 1)
    )

    // MARK: dictation.completed

    func testSuccessfulPolishJobEmitsOneCompletedLineWithEveryPhaseTiming() async throws {
        let clock = ManualClock()
        let logger = RecordingDiagnosticLogger()
        let audio = TimedAudioCaptureService(clock: clock, engineStartLatency: .milliseconds(250), stopLatency: .milliseconds(40), recording: recording(seconds: 3, leadingAmplitude: 0.1, amplitude: 0.5))
        let controller = DictationController(
            audio: audio,
            transcription: TimedTranscriptionEngine(clock: clock, latency: .milliseconds(600), text: "the quick brown fox"),
            insertion: TimedTextInsertionService(clock: clock, latency: .milliseconds(30), target: target),
            settings: FakeSettingsRepository(settings: AppSettings(
                selectedModel: .managed(modelID: "whisper-large-v3-turbo", revision: "1"),
                ai: AIEndpointSettings(mode: .polish, baseURL: URL(string: "http://127.0.0.1:11434/v1"), modelID: "fixture-model")
            )),
            ai: TimedAIProcessingClient(clock: clock, latency: .milliseconds(900), text: "The quick brown fox."),
            diagnosticLogger: logger,
            clock: clock
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        await audio.deliverFirstSignal(after: .milliseconds(180))
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let state = await controller.state
        XCTAssertEqual(state.kind, DictationStateKind.completed)
        let completed = await logger.events.filter { $0.name == .dictationCompleted }
        XCTAssertEqual(completed.count, 1, "exactly one timing line per job")
        let event = try XCTUnwrap(completed.first)
        XCTAssertEqual(event.result, .success)
        XCTAssertEqual(event.jobID, state.jobID)
        let attributes = event.attributes
        XCTAssertEqual(attributes.engineStartMilliseconds, 250, "start command to audioService.start returning")
        XCTAssertEqual(attributes.captureStartMilliseconds, 430, "start command to the first buffer with signal; the silent buffer at the floor does not count")
        XCTAssertEqual(attributes.leadingPeakDBFS, -20.0, "the first 0.5 s peaks at 0.1 full scale, not the -6 dBFS of the rest")
        XCTAssertEqual(attributes.recordingSeconds, 3.0)
        XCTAssertEqual(attributes.sttMilliseconds, 600)
        XCTAssertEqual(attributes.realTimeFactor, 0.2, "600 ms of STT over 3 s of audio")
        XCTAssertEqual(attributes.aiMilliseconds, 900)
        XCTAssertEqual(attributes.insertionMilliseconds, 30)
        XCTAssertEqual(event.durationMilliseconds, 40 + 600 + 900 + 30, "stop edge to inserted: finalize + STT + AI + insertion")
        XCTAssertEqual(attributes.modelID?.rawValue, "whisper-large-v3-turbo")
        XCTAssertEqual(attributes.mode, .polish)
        XCTAssertEqual(attributes.strategy, .selectedTextAttribute, "the same vocabulary as insertion.completed")
        XCTAssertEqual(attributes.streaming, false)
        XCTAssertNil(attributes.reason)
        XCTAssertNil(attributes.fallbackKind)

        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(encoded.contains("quick brown fox"), "never the transcript, raw or polished")
        XCTAssertFalse(encoded.contains("TextEdit"), "never the target")

        let failed = await logger.events.filter { $0.name == .dictationFailed }
        XCTAssertTrue(failed.isEmpty)
    }

    /// ADR-024: the on-device client's refusal carries two scalars —
    /// `endpointClass: onDevice` and, behind `aiInputTooLong`, the input
    /// token count — and the `ai.fallback.used` line keeps them. Never text.
    func testOnDeviceInputTooLongFallbackLineCarriesTheTokenCountAndEndpointClass() async throws {
        let clock = ManualClock()
        let logger = RecordingDiagnosticLogger()
        let audio = TimedAudioCaptureService(clock: clock, engineStartLatency: .milliseconds(10), stopLatency: .milliseconds(10), recording: recording(seconds: 3, leadingAmplitude: 0.1, amplitude: 0.5))
        var settings = AppSettings(selectedModel: .managed(modelID: "whisper-large-v3-turbo", revision: "1"))
        let onDevice = AIConfiguration(name: "On this Mac", kind: .appleIntelligence)
        settings.ai.configurations = [onDevice]
        settings.ai.apply(configuration: onDevice)
        settings.ai.isEnabled = true
        var metadata = DiagnosticAttributes()
        metadata.endpointClass = .onDevice
        metadata.tokenCount = 5_120
        let refusal = KVoiceError(code: .aiInputTooLong, retryable: false, metadata: metadata)
        let controller = DictationController(
            audio: audio,
            transcription: TimedTranscriptionEngine(clock: clock, latency: .milliseconds(10), text: "the quick brown fox"),
            insertion: TimedTextInsertionService(clock: clock, latency: .milliseconds(10), target: target),
            settings: FakeSettingsRepository(settings: settings),
            ai: FakeAIProcessingClient(failure: refusal),
            diagnosticLogger: logger,
            clock: clock
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        await audio.deliverFirstSignal(after: .milliseconds(10))
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let fallbacks = await logger.events.filter { $0.name == .aiFallbackUsed }
        XCTAssertEqual(fallbacks.count, 1)
        let line = try XCTUnwrap(fallbacks.first)
        XCTAssertEqual(line.errorCode, .aiInputTooLong)
        XCTAssertEqual(line.attributes.endpointClass, .onDevice)
        XCTAssertEqual(line.attributes.tokenCount, 5_120)
        XCTAssertEqual(line.attributes.site?.rawValue, "processAI")
        let encoded = String(decoding: try JSONEncoder().encode(line), as: UTF8.self)
        XCTAssertFalse(encoded.contains("quick brown fox"))

        // The next job's fallback starts clean: a code-only failure carries
        // neither scalar.
        let plain = DictationController(
            audio: TimedAudioCaptureService(clock: clock, engineStartLatency: .milliseconds(10), stopLatency: .milliseconds(10), recording: recording(seconds: 3, leadingAmplitude: 0.1, amplitude: 0.5)),
            transcription: TimedTranscriptionEngine(clock: clock, latency: .milliseconds(10), text: "again"),
            insertion: TimedTextInsertionService(clock: clock, latency: .milliseconds(10), target: target),
            settings: FakeSettingsRepository(settings: settings),
            ai: FakeAIProcessingClient(failure: KVoiceError(code: .aiProviderUnavailable, retryable: false)),
            diagnosticLogger: logger,
            clock: clock
        )
        _ = await plain.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await plain.handleShortcut(.keyUp, mode: .pushToTalk)
        await plain.waitForCompletion()
        let second = await logger.events.filter { $0.name == .aiFallbackUsed }.last
        XCTAssertEqual(second?.errorCode, .aiProviderUnavailable)
        XCTAssertNil(second?.attributes.tokenCount)
    }

    func testAIOffJobHasNilAIMillisecondsAndModeOff() async throws {
        let clock = ManualClock()
        let logger = RecordingDiagnosticLogger()
        let audio = TimedAudioCaptureService(clock: clock, engineStartLatency: .milliseconds(10), recording: DomainFixtures.audio(duration: .milliseconds(1_250)))
        let controller = DictationController(
            audio: audio,
            transcription: TimedTranscriptionEngine(clock: clock, latency: .milliseconds(500), text: "hello"),
            insertion: TimedTextInsertionService(clock: clock, latency: .milliseconds(5), target: target),
            settings: FakeSettingsRepository(settings: DomainFixtures.settings()),
            ai: TimedAIProcessingClient(clock: clock, latency: .seconds(9), text: "never called"),
            diagnosticLogger: logger,
            clock: clock
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        await audio.deliverFirstSignal(after: .zero)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let completed = await logger.events.filter { $0.name == .dictationCompleted }
        XCTAssertEqual(completed.count, 1)
        let attributes = try XCTUnwrap(completed.first?.attributes)
        XCTAssertNil(attributes.aiMilliseconds, "the job never entered processingAI")
        XCTAssertEqual(attributes.mode, .off)
        XCTAssertEqual(attributes.engineStartMilliseconds, 10)
        XCTAssertEqual(attributes.captureStartMilliseconds, 10, "signal in the first buffer after the engine came up")
        XCTAssertEqual(attributes.leadingPeakDBFS, -160.0, "the fixture's samples are zeros: the SpeechGate floor, never nil for a recording that exists")
        XCTAssertEqual(attributes.recordingSeconds, 1.3, "rounded to 0.1 s")
        XCTAssertEqual(attributes.sttMilliseconds, 500)
        XCTAssertEqual(attributes.realTimeFactor, 0.4, "500 ms over 1.25 s")
        XCTAssertEqual(attributes.insertionMilliseconds, 5)
        XCTAssertEqual(completed.first?.durationMilliseconds, 505)
    }

    func testClipboardFallbackCompletesAsAWarningWithTheFallbackKind() async throws {
        let clock = ManualClock()
        let logger = RecordingDiagnosticLogger()
        let insertion = TimedTextInsertionService(clock: clock, latency: .milliseconds(20), target: target)
        await insertion.setOutcome(.copiedToClipboard(reason: .noFocusedElement))
        let controller = DictationController(
            audio: TimedAudioCaptureService(clock: clock),
            transcription: TimedTranscriptionEngine(clock: clock, latency: .milliseconds(100), text: "hello"),
            insertion: insertion,
            settings: FakeSettingsRepository(settings: DomainFixtures.settings()),
            diagnosticLogger: logger,
            clock: clock
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let completed = await logger.events.filter { $0.name == .dictationCompleted }
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.result, .warning)
        XCTAssertNil(completed.first?.attributes.strategy)
        XCTAssertEqual(completed.first?.attributes.fallbackKind?.rawValue, "noFocusedElement")
        XCTAssertEqual(completed.first?.attributes.insertionMilliseconds, 20)
    }

    // MARK: dictation.failed

    func testFailedInsertionEmitsOneFailedLineWithTheSiteAndTheTimingSoFar() async throws {
        let clock = ManualClock()
        let logger = RecordingDiagnosticLogger()
        let insertion = TimedTextInsertionService(clock: clock, latency: .milliseconds(75), target: target)
        await insertion.setFailure(KVoiceError(code: .accessibilityVerifyFailed, retryable: false))
        let controller = DictationController(
            audio: TimedAudioCaptureService(clock: clock, engineStartLatency: .milliseconds(15), recording: DomainFixtures.audio(duration: .seconds(2))),
            transcription: TimedTranscriptionEngine(clock: clock, latency: .milliseconds(400), text: "secret words"),
            insertion: insertion,
            settings: FakeSettingsRepository(settings: DomainFixtures.settings()),
            diagnosticLogger: logger,
            clock: clock
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let state = await controller.state
        XCTAssertEqual(state.kind, DictationStateKind.failed)
        let failed = await logger.events.filter { $0.name == .dictationFailed }
        XCTAssertEqual(failed.count, 1, "ADR-022 item 9: one line per failure that reached the HUD")
        let event = try XCTUnwrap(failed.first)
        XCTAssertEqual(event.result, .failure)
        XCTAssertEqual(event.errorCode, .accessibilityVerifyFailed)
        XCTAssertEqual(event.attributes.site?.rawValue, "insert")
        XCTAssertEqual(event.attributes.reason?.rawValue, "clipboardFailure")
        XCTAssertEqual(event.attributes.engineStartMilliseconds, 15)
        XCTAssertNil(event.attributes.captureStartMilliseconds, "no buffer above the floor was delivered")
        XCTAssertEqual(event.attributes.recordingSeconds, 2.0)
        XCTAssertEqual(event.attributes.sttMilliseconds, 400)
        XCTAssertEqual(event.attributes.realTimeFactor, 0.2)
        XCTAssertNil(event.attributes.aiMilliseconds)
        XCTAssertEqual(event.attributes.insertionMilliseconds, 75, "the failed attempt is still timed")
        XCTAssertEqual(event.durationMilliseconds, 475)
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret words"), "never the transcript")

        let completed = await logger.events.filter { $0.name == .dictationCompleted }
        XCTAssertTrue(completed.isEmpty, "a failed job has no completed line")
    }

    func testInsertAgainCompletesWithTheRetryReasonAndNoTotal() async throws {
        let clock = ManualClock()
        let logger = RecordingDiagnosticLogger()
        let insertion = TimedTextInsertionService(clock: clock, latency: .milliseconds(50), target: target)
        await insertion.setFailure(KVoiceError(code: .accessibilityVerifyFailed, retryable: false))
        let controller = DictationController(
            audio: TimedAudioCaptureService(clock: clock),
            transcription: TimedTranscriptionEngine(clock: clock, latency: .milliseconds(300), text: "try again"),
            insertion: insertion,
            settings: FakeSettingsRepository(settings: DomainFixtures.settings()),
            diagnosticLogger: logger,
            clock: clock
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        // The user reads the HUD for a while, then clicks Insert Again.
        clock.advance(by: .seconds(20))
        await insertion.setFailure(nil)
        let result = await controller.retryInsertion()
        guard case .success(let final) = result else { return XCTFail("expected the retry to run, got \(result)") }
        XCTAssertEqual(final.kind, .completed)

        let completed = await logger.events.filter { $0.name == .dictationCompleted }
        XCTAssertEqual(completed.count, 1)
        let event = try XCTUnwrap(completed.first)
        XCTAssertEqual(event.attributes.reason?.rawValue, "retryInsertion")
        XCTAssertNil(event.durationMilliseconds, "the 20 s wait was the user's, not the pipeline's")
        XCTAssertEqual(event.attributes.insertionMilliseconds, 50, "the retry's own insertion")
        XCTAssertEqual(event.attributes.sttMilliseconds, 300, "the job's STT phase is still a fact")
        let failed = await logger.events.filter { $0.name == .dictationFailed }
        XCTAssertEqual(failed.count, 1)
    }

    func testCaptureStartIsNilWhenNoBufferEverCarriesSignal() async throws {
        let clock = ManualClock()
        let logger = RecordingDiagnosticLogger()
        let controller = DictationController(
            audio: TimedAudioCaptureService(clock: clock, engineStartLatency: .milliseconds(700)),
            transcription: TimedTranscriptionEngine(clock: clock, latency: .milliseconds(100), text: "hello"),
            insertion: TimedTextInsertionService(clock: clock, latency: .zero, target: target),
            settings: FakeSettingsRepository(settings: DomainFixtures.settings()),
            diagnosticLogger: logger,
            clock: clock
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let completed = await logger.events.filter { $0.name == .dictationCompleted }
        let attributes = try XCTUnwrap(completed.first?.attributes)
        XCTAssertEqual(attributes.engineStartMilliseconds, 700, "the engine came up")
        XCTAssertNil(attributes.captureStartMilliseconds, "but no buffer above the floor ever arrived: absent, not zero")
        XCTAssertEqual(attributes.leadingPeakDBFS, -160.0)
    }

    // MARK: Cancellation and streaming

    func testEscapeWhileTranscribingEmitsNeitherCompletedNorFailed() async throws {
        let clock = ManualClock()
        let logger = RecordingDiagnosticLogger()
        let controller = DictationController(
            audio: TimedAudioCaptureService(clock: clock),
            transcription: TimedTranscriptionEngine(clock: clock, latency: .milliseconds(100), text: "hello"),
            insertion: TimedTextInsertionService(clock: clock, latency: .zero, target: target),
            settings: FakeSettingsRepository(settings: DomainFixtures.settings()),
            diagnosticLogger: logger,
            clock: clock
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        let idle = await controller.cancel()
        XCTAssertEqual(idle.kind, .idle)
        await controller.waitForCompletion()

        let names = await logger.events.map(\.name)
        XCTAssertFalse(names.contains(.dictationCompleted))
        XCTAssertFalse(names.contains(.dictationFailed))
    }

    func testStreamingFlagIsSetWhenALiveSessionRanDuringTheRecording() async throws {
        let clock = ManualClock()
        let logger = RecordingDiagnosticLogger()
        let audio = FakeStreamingAudioCaptureService()
        let engine = FakeStreamingTranscriptionEngine(result: streamingTranscript("hello"))
        let controller = DictationController(
            audio: audio,
            transcription: engine,
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: AppSettings(
                ai: AIEndpointSettings(mode: .off, modelID: "kvoice-fixture"),
                speechModelModes: ["fixture-model": .streaming]
            )),
            diagnosticLogger: logger,
            clock: clock
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let completed = await logger.events.filter { $0.name == .dictationCompleted }
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.attributes.streaming, true)
    }

    // MARK: JobTimeline

    func testMeasurementLeavesUnenteredPhasesNilAndRoundsTheScalars() {
        let clock = ManualClock()
        let start = clock.now
        var timeline = JobTimeline(jobID: DomainFixtures.jobID, startCommandAt: start)
        timeline.recordEngineStarted(at: start + .milliseconds(90), for: DomainFixtures.jobID)
        timeline.recordEngineStarted(at: start + .seconds(4), for: DomainFixtures.jobID)
        timeline.recordCaptureStarted(at: start + .milliseconds(120), for: DomainFixtures.jobID)
        timeline.recordCaptureStarted(at: start + .seconds(5), for: DomainFixtures.jobID)
        timeline.recordCaptureStarted(at: start + .seconds(6), for: DomainFixtures.alternateJobID)
        timeline.recordRecording(recording(seconds: 2.349, leadingAmplitude: 0.0333, amplitude: 1), for: DomainFixtures.jobID)
        timeline.recordStopped(at: start + .seconds(3), streaming: true)
        timeline.recordTranscribing(at: start + .milliseconds(3_050))
        timeline.recordTranscribed(at: start + .milliseconds(3_755), aiStarted: false)

        let measured = timeline.measure(at: start + .milliseconds(3_800))
        XCTAssertEqual(measured.engineStartMilliseconds, 90, "only the first return counts")
        XCTAssertEqual(measured.captureStartMilliseconds, 120, "only the first buffer with signal counts, and only for this job")
        XCTAssertEqual(measured.leadingPeakDBFS, -29.6, "20·log10(0.0333) rounded to 0.1; the full-scale tail is outside the window")
        XCTAssertEqual(measured.recordingSeconds, 2.3)
        XCTAssertEqual(measured.sttMilliseconds, 705)
        XCTAssertEqual(measured.realTimeFactor, 0.3, "0.705 / 2.349 rounded to two decimals")
        XCTAssertNil(measured.aiMilliseconds)
        XCTAssertEqual(measured.insertionMilliseconds, 45)
        XCTAssertEqual(measured.totalMilliseconds, 800)
        XCTAssertTrue(measured.streaming)

        let bare = JobTimeline(jobID: DomainFixtures.jobID, startCommandAt: start).measure(at: start + .seconds(1))
        XCTAssertEqual(bare, JobTimeline.Measurement(streaming: false), "a job that reached no phase reports nothing, never zeros")
    }

    // MARK: Helpers

    /// Mono 16 kHz audio whose first 0.5 s sits at `leadingAmplitude` and the
    /// rest at `amplitude`, so the leading-window peak is known.
    private func recording(seconds: Double, leadingAmplitude: Float, amplitude: Float) -> AudioRecording {
        let total = Int(seconds * 16_000)
        let leading = min(total, 8_000)
        var samples = ContiguousArray<Float>(repeating: leadingAmplitude, count: leading)
        samples.append(contentsOf: repeatElement(amplitude, count: total - leading))
        return AudioRecording(
            samples: samples,
            duration: .milliseconds(Int(seconds * 1_000)),
            peakLevelDBFS: 20 * log10(max(leadingAmplitude, amplitude)),
            clippedFrameCount: 0
        )
    }

    private func streamingTranscript(_ text: String) -> TranscriptionResult {
        let now = ContinuousClock().now
        return TranscriptionResult(
            text: text,
            detectedLanguage: nil,
            segments: [],
            timings: TranscriptionTimings(requestStart: now, inferenceStart: now, inferenceEnd: now, runtimeReportedRealTimeFactor: nil),
            modelID: "fixture"
        )
    }
}

// MARK: - Clock-advancing doubles

/// Each call moves the shared `ManualClock` by a fixed latency before it
/// answers, so a phase measured by the controller has a known length.

private actor TimedAudioCaptureService: AudioCaptureService {
    private(set) var isRecording = false
    private let clock: ManualClock
    private let engineStartLatency: Duration
    private let stopLatency: Duration
    private let recording: AudioRecording
    private var events: (@Sendable (AudioCaptureEvent) async -> Void)?

    /// `engineStartLatency` is spent before `start` returns (the Bluetooth
    /// route switch). Like the real recorder, `start` reports `.elapsed(.zero)`
    /// and then only zeros — a `.level` at the meter's floor — until the test
    /// calls `deliverFirstSignal(after:)`, which is when a buffer with
    /// signal arrives. A test that never calls it models a route that only
    /// ever delivered zeros.
    init(
        clock: ManualClock,
        engineStartLatency: Duration = .zero,
        stopLatency: Duration = .zero,
        recording: AudioRecording = DomainFixtures.audio()
    ) {
        self.clock = clock
        self.engineStartLatency = engineStartLatency
        self.stopLatency = stopLatency
        self.recording = recording
    }

    func start(jobID _: JobID, events: @escaping @Sendable (AudioCaptureEvent) async -> Void) async throws {
        clock.advance(by: engineStartLatency)
        isRecording = true
        self.events = events
        await events(.elapsed(.zero))
        await events(.level(rmsDBFS: -120, peakDBFS: -120))
    }

    /// The first tap buffer that carried signal, `latency` after the last
    /// clock advance.
    func deliverFirstSignal(after latency: Duration) async {
        clock.advance(by: latency)
        await events?(.level(rmsDBFS: -32, peakDBFS: -20))
    }

    func stop(jobID _: JobID) async throws -> AudioRecording {
        clock.advance(by: stopLatency)
        isRecording = false
        return recording
    }

    func cancel(jobID _: JobID) async {
        isRecording = false
    }

    func runMicrophoneTest(duration: Duration, levels _: (@Sendable (AudioCaptureEvent) async -> Void)?) async throws -> MicrophoneTestResult {
        MicrophoneTestResult(duration: duration, peakLevelDBFS: recording.peakLevelDBFS, capturedSamples: recording.samples.count)
    }
}

private actor TimedTranscriptionEngine: TranscriptionEngine {
    let capabilities = TranscriptionCapabilities(
        supportsBatch: true,
        supportsStreaming: false,
        supportsCancellation: true,
        supportedSampleRate: 16_000,
        supportedChannelCount: 1
    )
    private(set) var loadedModelID: ModelID?
    private let clock: ManualClock
    private let latency: Duration
    private let text: String

    init(clock: ManualClock, latency: Duration, text: String) {
        self.clock = clock
        self.latency = latency
        self.text = text
    }

    func load(_ package: InstalledModelPackage) async throws {
        loadedModelID = package.manifest.modelID
    }

    func unload() async {
        loadedModelID = nil
    }

    func transcribe(_ request: TranscriptionRequest, events _: @escaping @Sendable (TranscriptionEvent) async -> Void) async throws -> TranscriptionResult {
        clock.advance(by: latency)
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
}

private actor TimedAIProcessingClient: AIProcessingClient {
    private let clock: ManualClock
    private let latency: Duration
    private let text: String

    init(clock: ManualClock, latency: Duration, text: String) {
        self.clock = clock
        self.latency = latency
        self.text = text
    }

    func validateConfiguration(_: AIEndpointSettings) throws {}

    func process(_: AIProcessRequest, settings _: AIEndpointSettings) async throws -> AIProcessResult {
        clock.advance(by: latency)
        return AIProcessResult(text: text, requestDuration: latency, responseID: nil)
    }

    func testConfiguration(_: AIEndpointSettings) async throws {}
    func cancel(jobID _: JobID) async {}
}

private actor TimedTextInsertionService: TextInsertionService {
    private let clock: ManualClock
    private let latency: Duration
    private let target: TargetApplicationSnapshot?
    private var outcome: InsertionOutcome = .inserted(method: .selectedTextAttribute)
    private var failure: KVoiceError?

    init(clock: ManualClock, latency: Duration, target: TargetApplicationSnapshot?) {
        self.clock = clock
        self.latency = latency
        self.target = target
    }

    func setOutcome(_ outcome: InsertionOutcome) {
        self.outcome = outcome
    }

    func setFailure(_ failure: KVoiceError?) {
        self.failure = failure
    }

    func captureTargetApplication() async -> TargetApplicationSnapshot? {
        target
    }

    func copyToClipboard(_: String, jobID _: JobID) async throws {}

    func insert(_: String, into _: TargetApplicationSnapshot, jobID _: JobID) async throws -> InsertionOutcome {
        clock.advance(by: latency)
        if let failure {
            throw failure
        }
        return outcome
    }
}

private actor RecordingDiagnosticLogger: DiagnosticLogging {
    private(set) var events: [DiagnosticEvent] = []

    func log(_ event: DiagnosticEvent) async {
        events.append(event)
    }
}
