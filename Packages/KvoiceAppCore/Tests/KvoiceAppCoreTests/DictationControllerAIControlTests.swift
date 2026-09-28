import Foundation
import XCTest
import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceAppCore

/// ADR-021: the in-recorder AI controls. `setAIAction(id:)` and
/// `setAIEnabled(_:)` rewrite the *current* job's AI snapshot while it is
/// still being captured, publish a new controller snapshot for the HUD, and
/// never touch the persisted settings.
final class DictationControllerAIControlTests: XCTestCase {
    private let target = TargetApplicationSnapshot(
        processIdentifier: 7,
        bundleIdentifier: "com.apple.TextEdit",
        localizedName: "TextEdit",
        capturedAt: Date(timeIntervalSince1970: 1)
    )
    private let polish = PromptMode(name: "Polish", behavior: .polish, prompt: "Tidy it up.")
    private let shout = PromptMode(name: "Shout", behavior: .polish, prompt: "SHOUT IT.")

    // MARK: Accepted while recording

    func testActionSwitchWhileRecordingRewritesTheJobSnapshotAndPublishesIt() async {
        let fixture = makeFixture()
        let stream = await fixture.controller.snapshots()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        _ = await fixture.controller.startRecording()
        var job = await fixture.controller.activeJob
        XCTAssertEqual(job?.aiSettingsSnapshot?.activePromptModeID, polish.id)

        let applied = await fixture.controller.setAIAction(id: shout.id)

        XCTAssertTrue(applied)
        job = await fixture.controller.activeJob
        XCTAssertEqual(job?.aiSettingsSnapshot?.activePromptModeID, shout.id)
        XCTAssertEqual(job?.aiSettingsSnapshot?.promptConfiguration.polishPrompt, shout.effectiveSystemPrompt)
        XCTAssertEqual(job?.modeSnapshot, .polish)

        // The HUD renders from the published snapshot's `activeSettings`.
        var published: DictationController.Snapshot?
        for _ in 0..<10 {
            guard let next = await iterator.next() else { break }
            published = next
            if next.activeSettings?.ai.activePromptModeID == shout.id { break }
        }
        XCTAssertEqual(published?.activeSettings?.ai.activePromptModeID, shout.id)
        XCTAssertEqual(published?.state.kind, .recording)

        let persisted = await fixture.settingsRepository.settings
        XCTAssertEqual(persisted.ai.activePromptModeID, polish.id, "the persisted default action is never written")
        _ = await fixture.controller.cancel()
    }

    func testTheAIStageOfThatJobRunsTheSwitchedAction() async {
        let fixture = makeFixture()
        _ = await fixture.controller.startRecording()
        _ = await fixture.controller.setAIAction(id: shout.id)

        _ = await fixture.controller.stopRecording()
        await fixture.controller.waitForCompletion()

        let requests = await fixture.aiClient.receivedRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.mode, .polish)
        XCTAssertEqual(requests.first?.polishPrompt, shout.effectiveSystemPrompt, "the request carries the switched action's prompt")
        let state = await fixture.controller.state
        XCTAssertEqual(state.kind, .completed)
        let persisted = await fixture.settingsRepository.settings
        XCTAssertEqual(persisted.ai.activePromptModeID, polish.id)
    }

    func testSwitchingAnActionWhileTheSwitchIsOffTurnsItOnForThisJobOnly() async {
        var settings = enabledSettings()
        settings.ai.isEnabled = false
        let fixture = makeFixture(settings: settings)
        _ = await fixture.controller.startRecording()
        var job = await fixture.controller.activeJob
        XCTAssertEqual(job?.modeSnapshot, .off)

        let applied = await fixture.controller.setAIAction(id: shout.id)

        XCTAssertTrue(applied)
        job = await fixture.controller.activeJob
        XCTAssertEqual(job?.aiSettingsSnapshot?.isEnabled, true, "choosing an action mid-dictation is an explicit request, as the ADR-020 override is")
        XCTAssertEqual(job?.modeSnapshot, .polish)
        let persisted = await fixture.settingsRepository.settings
        XCTAssertFalse(persisted.ai.isEnabled)
        _ = await fixture.controller.cancel()
    }

    func testToggleWhileRecordingFlipsTheJobSwitchAndSkipsTheAIStageWhenOff() async {
        let fixture = makeFixture()
        _ = await fixture.controller.startRecording()

        let disabled = await fixture.controller.setAIEnabled(false)
        XCTAssertTrue(disabled)
        var job = await fixture.controller.activeJob
        XCTAssertEqual(job?.modeSnapshot, .off)
        XCTAssertEqual(job?.aiSettingsSnapshot?.isEnabled, false)
        XCTAssertEqual(job?.aiSettingsSnapshot?.activePromptModeID, polish.id, "the chosen action is remembered while off")

        let unchanged = await fixture.controller.setAIEnabled(false)
        XCTAssertFalse(unchanged, "no change reports false so the shell does not re-render for nothing")

        let enabled = await fixture.controller.setAIEnabled(true)
        XCTAssertTrue(enabled)
        job = await fixture.controller.activeJob
        XCTAssertEqual(job?.modeSnapshot, .polish)

        _ = await fixture.controller.setAIEnabled(false)
        _ = await fixture.controller.stopRecording()
        await fixture.controller.waitForCompletion()
        let requests = await fixture.aiClient.receivedRequests
        XCTAssertTrue(requests.isEmpty, "AI off for this job means no request")
        let inserted = await fixture.insertion.insertedTexts
        XCTAssertEqual(inserted, ["hello"])
        let persisted = await fixture.settingsRepository.settings
        XCTAssertTrue(persisted.ai.isEnabled)
    }

    func testControlsAreAcceptedWhileFinalizingAndTheAIStageUsesTheSwitchedAction() async {
        let audio = GatedAudioCaptureDouble()
        let fixture = makeFixture(audio: audio)
        _ = await fixture.controller.startRecording()
        let stopping = Task { await fixture.controller.stopRecording() }
        await audio.waitUntilStopping()
        let state = await fixture.controller.state
        XCTAssertEqual(state.kind, .finalizing)

        let switched = await fixture.controller.setAIAction(id: shout.id)
        XCTAssertTrue(switched, "a push-to-talk release lands here ms after the key press; the switch must not be lost")
        let disabled = await fixture.controller.setAIEnabled(false)
        XCTAssertTrue(disabled)
        let enabled = await fixture.controller.setAIEnabled(true)
        XCTAssertTrue(enabled)
        let job = await fixture.controller.activeJob
        XCTAssertEqual(job?.aiSettingsSnapshot?.activePromptModeID, shout.id)

        await audio.release()
        _ = await stopping.value
        await fixture.controller.waitForCompletion()
        let requests = await fixture.aiClient.receivedRequests
        XCTAssertEqual(requests.map(\.polishPrompt), [shout.effectiveSystemPrompt])
        let persisted = await fixture.settingsRepository.settings
        XCTAssertEqual(persisted.ai.activePromptModeID, polish.id)
    }

    // MARK: Refused outside recording

    func testControlsAreRefusedWhileIdleAndAfterTheRecordingEnded() async {
        let fixture = makeFixture()
        let idleAction = await fixture.controller.setAIAction(id: shout.id)
        let idleToggle = await fixture.controller.setAIEnabled(false)
        XCTAssertFalse(idleAction)
        XCTAssertFalse(idleToggle)
        let idleJob = await fixture.controller.activeJob
        XCTAssertNil(idleJob)

        let engine = GatedTranscriptionDouble(result: transcript("hello"))
        let gated = makeFixture(engine: engine)
        _ = await gated.controller.startRecording()
        _ = await gated.controller.stopRecording()
        await engine.waitUntilStarted()
        let state = await gated.controller.state
        XCTAssertEqual(state.kind, .transcribing)

        let lateAction = await gated.controller.setAIAction(id: shout.id)
        let lateToggle = await gated.controller.setAIEnabled(false)

        XCTAssertFalse(lateAction)
        XCTAssertFalse(lateToggle)
        let job = await gated.controller.activeJob
        XCTAssertEqual(job?.aiSettingsSnapshot?.activePromptModeID, polish.id)
        await engine.release()
        await gated.controller.waitForCompletion()
    }

    func testUnknownOrUnusableActionsAndAMissingEndpointAreRefused() async {
        let fixture = makeFixture()
        _ = await fixture.controller.startRecording()
        let unknown = await fixture.controller.setAIAction(id: UUID())
        XCTAssertFalse(unknown)
        let job = await fixture.controller.activeJob
        XCTAssertEqual(job?.aiSettingsSnapshot?.activePromptModeID, polish.id)
        _ = await fixture.controller.cancel()

        var noEndpoint = enabledSettings()
        noEndpoint.ai.baseURL = nil
        let offline = makeFixture(settings: noEndpoint)
        _ = await offline.controller.startRecording()
        let switched = await offline.controller.setAIAction(id: shout.id)
        let enabled = await offline.controller.setAIEnabled(true)
        XCTAssertFalse(switched, "no endpoint: the indicator must not read on while nothing can run")
        XCTAssertFalse(enabled)
        let offlineJob = await offline.controller.activeJob
        XCTAssertEqual(offlineJob?.modeSnapshot, .off)
        _ = await offline.controller.cancel()
    }

    func testTheOnboardingInAppTestNeverGetsAnAIAction() async {
        let fixture = makeFixture()
        _ = await fixture.controller.startRecording(delivery: .inApp)

        let applied = await fixture.controller.setAIAction(id: shout.id)

        XCTAssertFalse(applied)
        let job = await fixture.controller.activeJob
        XCTAssertEqual(job?.modeSnapshot, .off)
        _ = await fixture.controller.cancel()
    }

    // MARK: Fixture

    private struct Fixture {
        let controller: DictationController
        let insertion: FakeTextInsertionService
        let settingsRepository: FakeSettingsRepository
        let aiClient: FakeAIProcessingClient
    }

    private func enabledSettings() -> AppSettings {
        var settings = DomainFixtures.settings()
        settings.ai.baseURL = URL(string: "http://127.0.0.1:11434/v1")
        settings.ai.promptModes = [polish, shout]
        settings.ai.apply(promptMode: polish)
        settings.ai.isEnabled = true
        return settings
    }

    private func makeFixture(
        settings: AppSettings? = nil,
        engine: (any TranscriptionEngine)? = nil,
        audio: (any AudioCaptureService)? = nil
    ) -> Fixture {
        let insertion = FakeTextInsertionService(target: target)
        let settingsRepository = FakeSettingsRepository(settings: settings ?? enabledSettings())
        let aiClient = FakeAIProcessingClient(
            result: AIProcessResult(text: "HELLO", requestDuration: .zero, responseID: nil)
        )
        let controller = DictationController(
            audio: audio ?? FakeAudioCaptureService(),
            transcription: engine ?? FakeTranscriptionEngine(result: transcript("hello")),
            insertion: insertion,
            settings: settingsRepository,
            ai: aiClient,
            clock: ManualClock()
        )
        return Fixture(
            controller: controller,
            insertion: insertion,
            settingsRepository: settingsRepository,
            aiClient: aiClient
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
/// Holds `transcribe` open until released, so a test can observe the
/// controller mid-pipeline without sleeping.
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

/// Holds `stop` open until released, so the controller sits in
/// `.finalizing` for as long as a test needs without sleeping.
private actor GatedAudioCaptureDouble: AudioCaptureService {
    private(set) var isRecording = false
    private var stopping = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func start(
        jobID _: JobID,
        events: @escaping @Sendable (AudioCaptureEvent) async -> Void
    ) async throws {
        isRecording = true
        await events(.elapsed(.zero))
    }

    func stop(jobID _: JobID) async throws -> AudioRecording {
        stopping = true
        if !released {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        isRecording = false
        return DomainFixtures.audio()
    }

    func cancel(jobID _: JobID) async {
        isRecording = false
        release()
    }

    func runMicrophoneTest(
        duration: Duration,
        levels _: (@Sendable (AudioCaptureEvent) async -> Void)?
    ) async throws -> MicrophoneTestResult {
        MicrophoneTestResult(duration: duration, peakLevelDBFS: -20, capturedSamples: 0)
    }

    func waitUntilStopping() async {
        while !stopping { await Task.yield() }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
