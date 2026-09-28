import Foundation
import XCTest
import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceAppCore

/// ADR-020: the App Intents command service against the fakes. Every command
/// is exercised from idle, recording, a mid-pipeline state, and a terminal
/// HUD; the per-dictation AI action override lands in the job snapshot and
/// never in the persisted settings. Nothing here waits on real time — the
/// mid-pipeline state is held by a gated engine.
@MainActor
final class DictationCommandServiceTests: XCTestCase {
    private let target = TargetApplicationSnapshot(
        processIdentifier: 7,
        bundleIdentifier: "com.apple.TextEdit",
        localizedName: "TextEdit",
        capturedAt: Date(timeIntervalSince1970: 1)
    )

    // MARK: Start

    func testStartFromIdleRecordsAndLogsTheAppIntentReason() async {
        let logger = RecordingDiagnosticLogger()
        let fixture = makeFixture(diagnostics: logger)

        let outcome = await fixture.service.perform(.start(aiActionID: nil))

        XCTAssertEqual(outcome, .started)
        let state = await fixture.controller.state
        XCTAssertEqual(state.kind, .recording)
        let events = await logger.events
        let intentEvents = events.filter { $0.attributes.reason?.rawValue == "appIntent" }
        XCTAssertEqual(intentEvents.count, 1)
        XCTAssertEqual(intentEvents.first?.attributes.actionKind?.rawValue, "start")
        XCTAssertEqual(intentEvents.first?.attributes.behavior?.rawValue, "started")
        XCTAssertEqual(intentEvents.first?.jobID, state.jobID)
    }

    func testStartWhileRecordingReportsAlreadyRecordingAndChangesNothing() async {
        let fixture = makeFixture()
        _ = await fixture.service.perform(.start(aiActionID: nil))
        let firstJob = await fixture.controller.activeJob?.id

        let outcome = await fixture.service.perform(.start(aiActionID: nil))

        XCTAssertEqual(outcome, .alreadyRecording)
        let job = await fixture.controller.activeJob?.id
        XCTAssertEqual(job, firstJob)
        let state = await fixture.controller.state
        XCTAssertEqual(state.kind, .recording)
    }

    func testStartWhileTheLastDictationIsStillFinishingReportsBusy() async {
        let engine = GatedTranscriptionDouble(result: transcript("hello"))
        let fixture = makeFixture(engine: engine)
        _ = await fixture.service.perform(.start(aiActionID: nil))
        _ = await fixture.service.perform(.stop)
        await engine.waitUntilStarted()

        let outcome = await fixture.service.perform(.start(aiActionID: nil))
        XCTAssertEqual(outcome, .busy(.transcribing))

        await engine.release()
        await fixture.controller.waitForCompletion()
    }

    func testStartDismissesATerminalHUDBeforeStarting() async {
        let fixture = makeFixture()
        _ = await fixture.service.perform(.start(aiActionID: nil))
        _ = await fixture.service.perform(.stop)
        await fixture.controller.waitForCompletion()
        let terminal = await fixture.controller.state
        XCTAssertEqual(terminal.kind, .completed)

        let outcome = await fixture.service.perform(.start(aiActionID: nil))

        XCTAssertEqual(outcome, .started)
        let state = await fixture.controller.state
        XCTAssertEqual(state.kind, .recording)
    }

    func testStartSurfacesTheControllersBlockedReason() async {
        let fixture = makeFixture(prerequisites: .blocked(.microphonePermission))

        let outcome = await fixture.service.perform(.start(aiActionID: nil))

        XCTAssertEqual(outcome, .blocked(.microphonePermission))
        let state = await fixture.controller.state
        XCTAssertEqual(state.kind, .blocked)
    }

    func testStartHonoursTheShellsEngineGate() async {
        let fixture = makeFixture(startGate: { false })

        let outcome = await fixture.service.perform(.start(aiActionID: nil))

        XCTAssertEqual(outcome, .engineBusy)
        let state = await fixture.controller.state
        XCTAssertEqual(state.kind, .idle)
    }

    // MARK: Stop and toggle

    func testStopEndsARecordingAndIsANoOpWhenIdle() async {
        let fixture = makeFixture()
        let idle = await fixture.service.perform(.stop)
        XCTAssertEqual(idle, .idle)

        _ = await fixture.service.perform(.start(aiActionID: nil))
        let stopped = await fixture.service.perform(.stop)
        XCTAssertEqual(stopped, .stopped)
        await fixture.controller.waitForCompletion()
        let inserted = await fixture.insertion.insertedTexts
        XCTAssertEqual(inserted, ["hello"], "a stopped intent job inserts like a hotkey job")
    }

    func testToggleStartsWhenIdleAndStopsWhenRecording() async {
        let fixture = makeFixture()

        let first = await fixture.service.perform(.toggle)
        XCTAssertEqual(first, .started)
        let second = await fixture.service.perform(.toggle)
        XCTAssertEqual(second, .stopped)
        await fixture.controller.waitForCompletion()
        let state = await fixture.controller.state
        XCTAssertEqual(state.kind, .completed)
    }

    // MARK: Cancel

    func testCancelDiscardsARecordingDismissesATerminalHUDAndIsIdleOtherwise() async {
        let fixture = makeFixture()
        let idle = await fixture.service.perform(.cancel)
        XCTAssertEqual(idle, .idle)

        _ = await fixture.service.perform(.start(aiActionID: nil))
        let cancelled = await fixture.service.perform(.cancel)
        XCTAssertEqual(cancelled, .cancelled)
        var state = await fixture.controller.state
        XCTAssertEqual(state.kind, .idle)
        let inserted = await fixture.insertion.insertedTexts
        XCTAssertTrue(inserted.isEmpty, "a cancelled recording inserts nothing")

        _ = await fixture.service.perform(.start(aiActionID: nil))
        _ = await fixture.service.perform(.stop)
        await fixture.controller.waitForCompletion()
        let dismissed = await fixture.service.perform(.cancel)
        XCTAssertEqual(dismissed, .dismissed)
        state = await fixture.controller.state
        XCTAssertEqual(state.kind, .idle)
    }

    // MARK: AI action override

    func testAIActionOverrideLandsInTheJobSnapshotAndNeverInPersistedSettings() async {
        let action = PromptMode(name: "Shout", behavior: .polish, prompt: "SHOUT IT.")
        var settings = DomainFixtures.settings()
        settings.ai.baseURL = URL(string: "http://127.0.0.1:11434/v1")
        settings.ai.promptModes = [action]
        settings.ai.isEnabled = false
        settings.ai.activePromptModeID = nil
        let fixture = makeFixture(settings: settings)

        let outcome = await fixture.service.perform(.start(aiActionID: action.id))

        XCTAssertEqual(outcome, .started)
        let job = await fixture.controller.activeJob
        XCTAssertEqual(job?.aiSettingsSnapshot?.activePromptModeID, action.id)
        XCTAssertEqual(job?.aiSettingsSnapshot?.isEnabled, true)
        XCTAssertEqual(job?.modeSnapshot, .polish, "the override runs even while the master switch is off")
        XCTAssertEqual(job?.aiSettingsSnapshot?.promptConfiguration.polishPrompt, action.effectiveSystemPrompt)
        let persisted = await fixture.settingsRepository.settings
        XCTAssertNil(persisted.ai.activePromptModeID)
        XCTAssertFalse(persisted.ai.isEnabled)
    }

    func testAIActionOverrideIsRefusedForAnUnknownActionAndWarnsWithoutAnEndpoint() async {
        let action = PromptMode(name: "Shout", behavior: .polish, prompt: "SHOUT IT.")
        var settings = DomainFixtures.settings()
        settings.ai.promptModes = [action]
        settings.ai.baseURL = nil
        let fixture = makeFixture(settings: settings)

        let unknown = await fixture.service.perform(.start(aiActionID: UUID()))
        XCTAssertEqual(unknown, .unknownAIAction)
        var state = await fixture.controller.state
        XCTAssertEqual(state.kind, .idle, "an unknown action starts nothing")

        let noEndpoint = await fixture.service.perform(.start(aiActionID: action.id))
        XCTAssertEqual(noEndpoint, .startedWithoutAIAction)
        state = await fixture.controller.state
        XCTAssertEqual(state.kind, .recording)
        let job = await fixture.controller.activeJob
        XCTAssertEqual(job?.modeSnapshot, .off, "no endpoint means no request, whatever the override")
    }

    // MARK: AI action entity query

    func testAIActionsListUsableActionsByNameAndByID() {
        let shout = PromptMode(name: "Shout", behavior: .polish, prompt: "SHOUT IT.")
        let whisper = PromptMode(name: "Whisper", behavior: .polish, prompt: "quietly.")
        let blank = PromptMode(name: "Blank", behavior: .polish, prompt: "   ")
        var settings = DomainFixtures.settings()
        settings.ai.promptModes = [shout, whisper, blank]
        let fixture = makeFixture(settings: settings)

        XCTAssertEqual(fixture.service.aiActions().map(\.name), ["Shout", "Whisper"], "an unusable action is never offered")
        XCTAssertEqual(fixture.service.aiActions(matching: "  ").map(\.name), ["Shout", "Whisper"])
        XCTAssertEqual(fixture.service.aiActions(matching: "whis").map(\.name), ["Whisper"])
        XCTAssertEqual(fixture.service.aiActions(ids: [whisper.id, UUID(), shout.id]).map(\.name), ["Whisper", "Shout"])
    }

    // MARK: Get Last Transcription

    func testLastTranscriptionReturnsTheNewestRowOrWhyThereIsNone() async {
        let history = InMemoryHistoryRepository()
        var settings = DomainFixtures.settings()
        settings.historyEnabled = true
        let fixture = makeFixture(settings: settings, history: history)

        let empty = await fixture.service.lastTranscription()
        XCTAssertEqual(empty, .empty)

        try? await history.append(entry(text: "older", at: 10))
        try? await history.append(entry(text: "newest", at: 20))
        let newest = await fixture.service.lastTranscription()
        XCTAssertEqual(newest, .text("newest"))

        settings.historyEnabled = false
        let disabled = makeFixture(settings: settings, history: history)
        let off = await disabled.service.lastTranscription()
        XCTAssertEqual(off, .historyDisabled)

        let noStore = makeFixture(settings: DomainFixtures.settings(), history: nil)
        settings.historyEnabled = true
        let unavailable = await noStore.service.lastTranscription()
        XCTAssertEqual(unavailable, .unavailable)
    }

    // MARK: - Fixture

    private struct Fixture {
        let service: DictationCommandService
        let controller: DictationController
        let insertion: FakeTextInsertionService
        let settingsRepository: FakeSettingsRepository
    }

    private func makeFixture(
        settings: AppSettings = DomainFixtures.settings(),
        history: InMemoryHistoryRepository? = nil,
        engine: (any TranscriptionEngine)? = nil,
        prerequisites: StartPrerequisites = .passed,
        startGate: @escaping DictationCommandService.StartGate = { true },
        diagnostics: any DiagnosticLogging = NullDiagnosticLogger()
    ) -> Fixture {
        let insertion = FakeTextInsertionService(target: target)
        let settingsRepository = FakeSettingsRepository(settings: settings)
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: engine ?? FakeTranscriptionEngine(result: transcript("hello")),
            insertion: insertion,
            settings: settingsRepository,
            ai: FakeAIProcessingClient(result: AIProcessResult(text: "hello", requestDuration: .zero, responseID: nil)),
            history: history,
            prerequisiteChecker: { prerequisites },
            clock: ManualClock()
        )
        let service = DictationCommandService(
            controller: controller,
            history: history,
            settingsProvider: { settings },
            startGate: startGate,
            diagnosticLogger: diagnostics
        )
        return Fixture(
            service: service,
            controller: controller,
            insertion: insertion,
            settingsRepository: settingsRepository
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

    private func entry(text: String, at seconds: TimeInterval) -> HistoryEntry {
        HistoryEntry(
            createdAt: Date(timeIntervalSince1970: seconds),
            rawText: text,
            finalText: text,
            mode: .off,
            insertionOutcome: .inserted(method: .selectedTextAttribute)
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
