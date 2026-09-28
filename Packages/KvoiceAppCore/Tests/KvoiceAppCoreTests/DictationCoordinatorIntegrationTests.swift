import Foundation
import XCTest
import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceAppCore

/// Deterministic M1 integration coverage. These doubles model the four frozen
/// service boundaries without invoking AVAudioEngine, WhisperKit, Accessibility,
/// or a real clipboard.
final class DictationCoordinatorIntegrationTests: XCTestCase {
    private let jobID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    private let target = TargetApplicationSnapshot(
        processIdentifier: 101,
        bundleIdentifier: "com.apple.TextEdit",
        localizedName: "TextEdit",
        capturedAt: Date(timeIntervalSince1970: 100)
    )

    func testPushToTalkStartsOnKeyDownAndInsertsOnceOnKeyUp() async {
        let audio = CoordinatorAudioDouble()
        let transcription = CoordinatorTranscriptionDouble(result: result("hello local"))
        let insertion = CoordinatorInsertionDouble(target: target)
        let controller = makeController(audio: audio, transcription: transcription, insertion: insertion)

        let startedState = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        XCTAssertEqual(startedState.kind, .recording)
        let stoppingState = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        XCTAssertEqual(stoppingState.kind, .transcribing)
        await controller.waitForCompletion()

        let insertedTexts = await insertion.insertedTexts
        XCTAssertEqual(insertedTexts, ["hello local"])
        let state = await controller.state
        guard case .completed(_, let summary) = state else {
            return XCTFail("expected completed state, got \(state)")
        }
        XCTAssertEqual(summary.insertion, .inserted(method: .selectedTextAttribute))
    }

    func testToggleStartsOnFirstActivationAndStopsOnSecond() async {
        let audio = CoordinatorAudioDouble()
        let transcription = CoordinatorTranscriptionDouble(result: result("toggle result"))
        let insertion = CoordinatorInsertionDouble(target: target)
        let controller = makeController(audio: audio, transcription: transcription, insertion: insertion)

        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        _ = await controller.handleShortcut(.keyUp, mode: .toggle)
        let recordingState = await controller.state
        XCTAssertEqual(recordingState.kind, .recording)

        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        await controller.waitForCompletion()

        let insertedTexts = await insertion.insertedTexts
        let startCount = await audio.startCount
        let stopCount = await audio.stopCount
        XCTAssertEqual(insertedTexts, ["toggle result"])
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
    }

    func testStartSnapshotsTargetAndSettingsIntoOneJob() async {
        let settings = AppSettings(
            recordingInteraction: .toggle,
            selectedModel: .managed(modelID: "fixture-model", revision: "fixture-revision"),
            historyEnabled: false
        )
        let audio = CoordinatorAudioDouble()
        let transcription = CoordinatorTranscriptionDouble(result: result("snapshot"))
        let insertion = CoordinatorInsertionDouble(target: target)
        let deterministicJobID = jobID
        let controller = DictationController(
            audio: audio,
            transcription: transcription,
            insertion: insertion,
            settings: CoordinatorSettingsDouble(settings: settings),
            makeJobID: { deterministicJobID }
        )

        _ = await controller.startRecording()
        let job = await controller.activeJob
        let settingsSnapshot = await controller.activeSettingsSnapshot
        XCTAssertEqual(job?.target, target)
        XCTAssertEqual(job?.modelIDSnapshot, "fixture-model")
        XCTAssertEqual(job?.modeSnapshot, .off)
        XCTAssertEqual(settingsSnapshot, settings)
        let state = await controller.state
        XCTAssertEqual(state.kind, .recording)
        _ = await controller.terminate()
    }

    func testBusyAndRepeatedShortcutEventsDoNotCreateASecondJob() async {
        let audio = CoordinatorAudioDouble()
        let transcription = CoordinatorTranscriptionDouble(result: result("one job"), waitsForRelease: true)
        let insertion = CoordinatorInsertionDouble(target: target)
        let controller = makeController(audio: audio, transcription: transcription, insertion: insertion)

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        let transcribingState = await controller.state
        XCTAssertEqual(transcribingState.kind, .transcribing)

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        let startCount = await audio.startCount
        let stopCount = await audio.stopCount
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)

        await transcription.waitUntilWaiting()
        await transcription.release(result("one job"))
        await controller.waitForCompletion()
        let insertedTexts = await insertion.insertedTexts
        XCTAssertEqual(insertedTexts, ["one job"])
    }

    func testEscapeDuringTranscriptionSuppressesLateResult() async {
        let audio = CoordinatorAudioDouble()
        let transcription = CoordinatorTranscriptionDouble(result: result("late"), waitsForRelease: true)
        let insertion = CoordinatorInsertionDouble(target: target)
        let controller = makeController(audio: audio, transcription: transcription, insertion: insertion)

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        let transcribingState = await controller.state
        XCTAssertEqual(transcribingState.kind, .transcribing)

        await transcription.waitUntilWaiting()
        let cancelledState = await controller.cancel()
        XCTAssertEqual(cancelledState.kind, .idle)
        await transcription.release(result("late"))
        await controller.waitForCompletion()

        let insertedTexts = await insertion.insertedTexts
        let activeJob = await controller.activeJob
        XCTAssertTrue(insertedTexts.isEmpty)
        XCTAssertNil(activeJob)
    }

    func testAppSwitchIsDelegatedToInsertionAndClipboardOutcomeIsPreserved() async {
        let audio = CoordinatorAudioDouble()
        let transcription = CoordinatorTranscriptionDouble(result: result("copy me"))
        let insertion = CoordinatorInsertionDouble(
            target: target,
            outcome: .copiedToClipboard(reason: .targetApplicationChanged)
        )
        let controller = makeController(audio: audio, transcription: transcription, insertion: insertion)

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        guard case .completed(_, let summary) = await controller.state else {
            return XCTFail("expected clipboard completion")
        }
        XCTAssertEqual(
            summary.insertion,
            .copiedToClipboard(reason: .targetApplicationChanged)
        )
        let receivedTargets = await insertion.receivedTargets
        let finalText = await controller.exactFinalTextForFallback
        XCTAssertEqual(receivedTargets, [target])
        XCTAssertEqual(finalText, "copy me")
    }

    func testNilTargetCopiesExactTextOnceWithoutAXInsertion() async {
        let audio = CoordinatorAudioDouble()
        let transcription = CoordinatorTranscriptionDouble(
            result: result("copy without target")
        )
        let insertion = CoordinatorInsertionDouble(target: nil)
        let controller = makeController(
            audio: audio,
            transcription: transcription,
            insertion: insertion
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        guard case .completed(_, let summary) = await controller.state else {
            return XCTFail("expected clipboard completion")
        }
        XCTAssertEqual(
            summary.insertion,
            .copiedToClipboard(reason: .noFrontmostApplication)
        )
        let clipboardTexts = await insertion.clipboardTexts
        let clipboardCopyCount = await insertion.clipboardCopyCount
        let insertedTexts = await insertion.insertedTexts
        let receivedTargets = await insertion.receivedTargets
        XCTAssertEqual(clipboardTexts, ["copy without target"])
        XCTAssertEqual(clipboardCopyCount, 1)
        XCTAssertTrue(insertedTexts.isEmpty)
        XCTAssertTrue(receivedTargets.isEmpty)
    }

    func testNilTargetClipboardFailureRetainsExactTextForSelectableHUDRecovery() async {
        let audio = CoordinatorAudioDouble()
        let transcription = CoordinatorTranscriptionDouble(
            result: result("recover this transcript")
        )
        let insertion = CoordinatorInsertionDouble(
            target: nil,
            clipboardFailure: KVoiceError(code: .clipboardWriteFailed)
        )
        let controller = makeController(
            audio: audio,
            transcription: transcription,
            insertion: insertion
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let state = await controller.state
        guard case .failed(_, let failure) = state else {
            return XCTFail("expected clipboard failure, got \(state)")
        }
        XCTAssertEqual(failure.code, KVoiceErrorCode.clipboardWriteFailed.rawValue)
        let clipboardCopyCount = await insertion.clipboardCopyCount
        XCTAssertEqual(clipboardCopyCount, 1)
        let finalText = await controller.exactFinalTextForFallback
        XCTAssertEqual(finalText, "recover this transcript")
    }

    func testEmptyAudioAndEmptyTranscriptDoNotInsert() async {
        let emptyAudio = CoordinatorAudioDouble(
            recording: AudioRecording(
                samples: [],
                duration: .zero,
                peakLevelDBFS: -120,
                clippedFrameCount: 0
            )
        )
        let insertionForAudio = CoordinatorInsertionDouble(target: target)
        let audioController = makeController(
            audio: emptyAudio,
            transcription: CoordinatorTranscriptionDouble(result: result("unused")),
            insertion: insertionForAudio
        )
        _ = await audioController.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await audioController.handleShortcut(.keyUp, mode: .pushToTalk)
        let audioFailureState = await audioController.state
        let audioInsertedTexts = await insertionForAudio.insertedTexts
        XCTAssertEqual(audioFailureState.kind, .failed)
        XCTAssertTrue(audioInsertedTexts.isEmpty)

        let insertionForTranscript = CoordinatorInsertionDouble(target: target)
        let transcriptController = makeController(
            audio: CoordinatorAudioDouble(),
            transcription: CoordinatorTranscriptionDouble(result: result("   ")),
            insertion: insertionForTranscript
        )
        _ = await transcriptController.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await transcriptController.handleShortcut(.keyUp, mode: .pushToTalk)
        await transcriptController.waitForCompletion()
        let transcriptFailureState = await transcriptController.state
        let transcriptInsertedTexts = await insertionForTranscript.insertedTexts
        XCTAssertEqual(transcriptFailureState.kind, .failed)
        XCTAssertTrue(transcriptInsertedTexts.isEmpty)
    }

    func testTerminationCancelsCaptureAndLateWorkCannotInsert() async {
        let audio = CoordinatorAudioDouble()
        let transcription = CoordinatorTranscriptionDouble(result: result("never insert"), waitsForRelease: true)
        let insertion = CoordinatorInsertionDouble(target: target)
        let controller = makeController(audio: audio, transcription: transcription, insertion: insertion)

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        let terminatingState = await controller.terminate()
        let cancelCount = await audio.cancelCount
        let insertedBeforeRelease = await insertion.insertedTexts
        XCTAssertEqual(terminatingState.kind, .terminating)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertTrue(insertedBeforeRelease.isEmpty)

        // A non-cooperative runtime callback is deliberately released after
        // termination to prove JobID/state suppression, not cancellation luck.
        await transcription.release(result("never insert"))
        await controller.waitForCompletion()
        let insertedAfterRelease = await insertion.insertedTexts
        XCTAssertTrue(insertedAfterRelease.isEmpty)
    }

    func testTerminationDuringTranscriptionSuppressesLateResult() async {
        let audio = CoordinatorAudioDouble()
        let transcription = CoordinatorTranscriptionDouble(result: result("late termination"), waitsForRelease: true)
        let insertion = CoordinatorInsertionDouble(target: target)
        let controller = makeController(audio: audio, transcription: transcription, insertion: insertion)

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await transcription.waitUntilWaiting()

        let terminatingState = await controller.terminate()
        XCTAssertEqual(terminatingState.kind, .terminating)
        await transcription.release(result("late termination"))
        await controller.waitForCompletion()
        await Task.yield()

        let insertedTexts = await insertion.insertedTexts
        XCTAssertTrue(insertedTexts.isEmpty)
    }

    func testPolishSuccessInsertsProviderTextOnceAndSavesHistory() async {
        let ai = FakeAIProcessingClient(
            result: AIProcessResult(
                text: "Please move the review to Friday.",
                requestDuration: .milliseconds(20),
                responseID: "fixture"
            )
        )
        let history = InMemoryHistoryRepository()
        let insertion = CoordinatorInsertionDouble(target: target)
        let controller = makeController(
            audio: CoordinatorAudioDouble(),
            transcription: CoordinatorTranscriptionDouble(
                result: result("um, please, uh, move the review to Friday")
            ),
            insertion: insertion,
            settings: aiSettings(mode: .polish, historyEnabled: true),
            ai: ai,
            history: history
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let inserted = await insertion.insertedTexts
        let requests = await ai.receivedRequests
        let entries = await history.entries
        XCTAssertEqual(inserted, ["Please move the review to Friday."])
        XCTAssertEqual(requests.map(\.rawTranscript), ["um, please, uh, move the review to Friday"])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.rawText, "um, please, uh, move the review to Friday")
        XCTAssertEqual(entries.first?.finalText, "Please move the review to Friday.")
        XCTAssertNil(entries.first?.errorCode)
    }

    /// AI actions: a trigger phrase at the start of the transcript switches
    /// the request to that action and is stripped; the user profile and any
    /// opted-in context ride along as separate fields.
    func testTriggerWordSelectsAnotherActionAndContextIsAttachedPerOptIn() async {
        var settings = aiSettings(mode: .polish, historyEnabled: false)
        settings.ai.seedBuiltInPromptModesIfNeeded()
        settings.ai.apply(promptMode: settings.ai.promptModes.first { $0.builtInKey == BuiltInPromptModes.Key.polish }!)
        settings.ai.actionTriggersEnabled = true
        settings.ai.userProfile = "Role: tester"
        let translateIndex = settings.ai.promptModes.firstIndex { $0.builtInKey == BuiltInPromptModes.Key.translate }!
        settings.ai.promptModes[translateIndex].includesClipboardText = true
        let translate = settings.ai.promptModes[translateIndex]

        let ai = FakeAIProcessingClient(
            result: AIProcessResult(text: "Hallo Welt", requestDuration: .milliseconds(5), responseID: nil)
        )
        let insertion = CoordinatorInsertionDouble(target: target)
        let controller = makeController(
            audio: CoordinatorAudioDouble(),
            transcription: CoordinatorTranscriptionDouble(result: result("Translate, hello world")),
            insertion: insertion,
            settings: settings,
            ai: ai
        )
        await controller.setAIContextProvider(CoordinatorContextDouble(clipboard: "copied", selection: "chosen"))

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let requests = await ai.receivedRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.rawTranscript, "hello world", "the trigger phrase is stripped")
        XCTAssertEqual(requests.first?.mode, .translate, "the triggered action's shape runs")
        XCTAssertEqual(requests.first?.targetLanguage?.bcp47, translate.translationLanguage?.bcp47)
        XCTAssertEqual(requests.first?.context.userProfile, "Role: tester")
        XCTAssertEqual(requests.first?.context.clipboardText, "copied", "Translate opted into the clipboard")
        XCTAssertNil(requests.first?.context.selectedText, "but not into the selection")
        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["Hallo Welt"])
    }

    func testWithoutTriggersTheDefaultActionRunsOnTheWholeTranscript() async {
        var settings = aiSettings(mode: .polish, historyEnabled: false)
        settings.ai.seedBuiltInPromptModesIfNeeded()
        settings.ai.apply(promptMode: settings.ai.promptModes.first { $0.builtInKey == BuiltInPromptModes.Key.polish }!)
        let ai = FakeAIProcessingClient(
            result: AIProcessResult(text: "polished", requestDuration: .milliseconds(5), responseID: nil)
        )
        let controller = makeController(
            audio: CoordinatorAudioDouble(),
            transcription: CoordinatorTranscriptionDouble(result: result("Translate, hello world")),
            insertion: CoordinatorInsertionDouble(target: target),
            settings: settings,
            ai: ai
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let requests = await ai.receivedRequests
        XCTAssertEqual(requests.first?.rawTranscript, "Translate, hello world")
        XCTAssertEqual(requests.first?.mode, .polish)
        XCTAssertTrue(requests.first?.context.isEmpty ?? false, "no provider installed: no context")
    }

    func testAIFailureInsertsRawTranscriptOnceAndRecordsFallback() async {
        let ai = FakeAIProcessingClient(failure: KVoiceError(code: .aiAuthentication))
        let history = InMemoryHistoryRepository()
        let insertion = CoordinatorInsertionDouble(target: target)
        let controller = makeController(
            audio: CoordinatorAudioDouble(),
            transcription: CoordinatorTranscriptionDouble(result: result("exact raw text")),
            insertion: insertion,
            settings: aiSettings(mode: .translate, historyEnabled: true),
            ai: ai,
            history: history
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let inserted = await insertion.insertedTexts
        let entries = await history.entries
        XCTAssertEqual(inserted, ["exact raw text"])
        XCTAssertEqual(entries.first?.finalText, "exact raw text")
        XCTAssertEqual(entries.first?.errorCode, .aiAuthentication)
    }

    /// ADR-024: an on-device configuration has no base URL or model id, yet
    /// the AI stage runs (the transport is what makes it complete); its
    /// `inputTooLong` refusal is the ordinary fallback — raw transcript
    /// inserted once, the code in history.
    func testOnDeviceConfigurationRunsTheAIStageAndInputTooLongFallsBackToRawText() async {
        var settings = AppSettings(historyEnabled: true)
        let configuration = AIConfiguration(name: "On this Mac", kind: .appleIntelligence)
        settings.ai.configurations = [configuration]
        settings.ai.apply(configuration: configuration)
        settings.ai.isEnabled = true
        XCTAssertNil(settings.ai.baseURL)
        XCTAssertEqual(settings.ai.mode, .polish)

        let polished = FakeAIProcessingClient(result: AIProcessResult(text: "Polished.", requestDuration: .zero, responseID: nil))
        let history = InMemoryHistoryRepository()
        let insertion = CoordinatorInsertionDouble(target: target)
        let controller = makeController(
            audio: CoordinatorAudioDouble(),
            transcription: CoordinatorTranscriptionDouble(result: result("raw words")),
            insertion: insertion,
            settings: settings,
            ai: polished,
            history: history
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()
        let requests = await polished.receivedRequests
        XCTAssertEqual(requests.count, 1, "the on-device transport makes the request")
        XCTAssertEqual(requests.first?.modelID, "", "no model id travels for the on-device transport")
        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["Polished."])

        let refusing = FakeAIProcessingClient(failure: KVoiceError(code: .aiInputTooLong, retryable: false))
        let refusedInsertion = CoordinatorInsertionDouble(target: target)
        let refusedHistory = InMemoryHistoryRepository()
        let refusedController = makeController(
            audio: CoordinatorAudioDouble(),
            transcription: CoordinatorTranscriptionDouble(result: result("a very long raw transcript")),
            insertion: refusedInsertion,
            settings: settings,
            ai: refusing,
            history: refusedHistory
        )
        _ = await refusedController.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await refusedController.handleShortcut(.keyUp, mode: .pushToTalk)
        await refusedController.waitForCompletion()
        let rawInserted = await refusedInsertion.insertedTexts
        let entries = await refusedHistory.entries
        XCTAssertEqual(rawInserted, ["a very long raw transcript"])
        XCTAssertEqual(entries.first?.finalText, "a very long raw transcript")
        XCTAssertEqual(entries.first?.errorCode, .aiInputTooLong)
    }

    func testAIOffMakesNoRequestAndDisabledHistoryCreatesNoEntry() async {
        let ai = FakeAIProcessingClient(
            result: AIProcessResult(text: "must not be used", requestDuration: .zero, responseID: nil)
        )
        let history = InMemoryHistoryRepository()
        let insertion = CoordinatorInsertionDouble(target: target)
        let controller = makeController(
            audio: CoordinatorAudioDouble(),
            transcription: CoordinatorTranscriptionDouble(result: result("offline raw")),
            insertion: insertion,
            settings: aiSettings(mode: .off, historyEnabled: false),
            ai: ai,
            history: history
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let requests = await ai.receivedRequests
        let entries = await history.entries
        let inserted = await insertion.insertedTexts
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(inserted, ["offline raw"])
    }

    func testEscapeDuringAIInsertsRawTranscriptExactlyOnce() async {
        let ai = WaitingCoordinatorAIDouble()
        let history = InMemoryHistoryRepository()
        let insertion = CoordinatorInsertionDouble(target: target)
        let controller = makeController(
            audio: CoordinatorAudioDouble(),
            transcription: CoordinatorTranscriptionDouble(result: result("keep exact raw")),
            insertion: insertion,
            settings: aiSettings(mode: .polish, historyEnabled: true),
            ai: ai,
            history: history
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await ai.waitUntilStarted()
        let processingState = await controller.state
        XCTAssertEqual(processingState.kind, .processingAI)

        _ = await controller.cancel()
        await controller.waitForCompletion()

        let inserted = await insertion.insertedTexts
        let entries = await history.entries
        XCTAssertEqual(inserted, ["keep exact raw"])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.errorCode, .aiCancelled)
    }

    private func makeController(
        audio: CoordinatorAudioDouble,
        transcription: CoordinatorTranscriptionDouble,
        insertion: CoordinatorInsertionDouble,
        settings: AppSettings = AppSettings(),
        ai: (any AIProcessingClient)? = nil,
        history: (any HistoryRepository)? = nil
    ) -> DictationController {
        let settingsRepository = CoordinatorSettingsDouble(settings: settings)
        let deterministicJobID = jobID
        return DictationController(
            audio: audio,
            transcription: transcription,
            insertion: insertion,
            settings: settingsRepository,
            ai: ai,
            history: history,
            makeJobID: { deterministicJobID }
        )
    }

    private func aiSettings(mode: DictationMode, historyEnabled: Bool) -> AppSettings {
        AppSettings(
            ai: AIEndpointSettings(
                mode: mode,
                baseURL: mode == .off ? nil : URL(string: "http://127.0.0.1:11434/v1"),
                modelID: mode == .off ? "" : "gemma4:latest",
                translationLanguage: .init(bcp47: "en", displayName: "English")
            ),
            historyEnabled: historyEnabled
        )
    }

    private func result(_ text: String) -> TranscriptionResult {
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

private actor CoordinatorAudioDouble: AudioCaptureService {
    var recording: AudioRecording
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var isRecording = false

    init(recording: AudioRecording = AudioRecording(
        samples: ContiguousArray(repeating: 0, count: 16_000),
        duration: .seconds(1),
        peakLevelDBFS: -18,
        clippedFrameCount: 0
    )) {
        self.recording = recording
    }

    func start(
        jobID _: JobID,
        events: @escaping @Sendable (AudioCaptureEvent) async -> Void
    ) async throws {
        startCount += 1
        isRecording = true
        await events(.elapsed(.zero))
    }

    func stop(jobID _: JobID) async throws -> AudioRecording {
        stopCount += 1
        isRecording = false
        return recording
    }

    func cancel(jobID _: JobID) async {
        cancelCount += 1
        isRecording = false
    }

    func runMicrophoneTest(
        duration: Duration,
        levels _: (@Sendable (AudioCaptureEvent) async -> Void)?
    ) async throws -> MicrophoneTestResult {
        MicrophoneTestResult(
            duration: duration,
            peakLevelDBFS: recording.peakLevelDBFS,
            capturedSamples: recording.samples.count
        )
    }
}

private actor CoordinatorTranscriptionDouble: TranscriptionEngine {
    let capabilities = TranscriptionCapabilities(
        supportsBatch: true,
        supportsStreaming: false,
        supportsCancellation: true,
        supportedSampleRate: 16_000,
        supportedChannelCount: 1
    )
    private(set) var loadedModelID: ModelID?
    private var resultValue: TranscriptionResult?
    private let waitsForRelease: Bool
    private var continuation: CheckedContinuation<TranscriptionResult, Error>?
    private var isWaitingForRelease = false

    init(result: TranscriptionResult, waitsForRelease: Bool = false) {
        resultValue = result
        self.waitsForRelease = waitsForRelease
    }

    func load(_ package: InstalledModelPackage) async throws {
        loadedModelID = package.manifest.modelID
    }

    func unload() async {
        loadedModelID = nil
    }

    func transcribe(
        _: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> TranscriptionResult {
        await events(.phase(.finalizing))
        if waitsForRelease {
            isWaitingForRelease = true
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }
        return resultValue!
    }

    func release(_ result: TranscriptionResult) {
        continuation?.resume(returning: result)
        continuation = nil
        isWaitingForRelease = false
    }

    func waitUntilWaiting() async {
        while !isWaitingForRelease {
            await Task.yield()
        }
    }
}

private actor CoordinatorInsertionDouble: TextInsertionService {
    let target: TargetApplicationSnapshot?
    let outcome: InsertionOutcome
    let clipboardFailure: KVoiceError?
    private(set) var insertedTexts: [String] = []
    private(set) var receivedTargets: [TargetApplicationSnapshot] = []
    private(set) var clipboardCopyCount = 0
    private(set) var clipboardTexts: [String] = []

    init(
        target: TargetApplicationSnapshot?,
        outcome: InsertionOutcome = .inserted(method: .selectedTextAttribute),
        clipboardFailure: KVoiceError? = nil
    ) {
        self.target = target
        self.outcome = outcome
        self.clipboardFailure = clipboardFailure
    }

    func captureTargetApplication() async -> TargetApplicationSnapshot? {
        target
    }

    func copyToClipboard(_ text: String, jobID _: JobID) async throws {
        clipboardCopyCount += 1
        if let clipboardFailure {
            throw clipboardFailure
        }
        clipboardTexts.append(text)
    }

    func insert(
        _ text: String,
        into target: TargetApplicationSnapshot,
        jobID _: JobID
    ) async throws -> InsertionOutcome {
        insertedTexts.append(text)
        receivedTargets.append(target)
        return outcome
    }
}

private actor CoordinatorSettingsDouble: SettingsRepository {
    let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func load() throws -> AppSettings {
        settings
    }

    func save(_: AppSettings) throws {}
}

private actor WaitingCoordinatorAIDouble: AIProcessingClient {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func validateConfiguration(_: AIEndpointSettings) throws {}

    func process(
        _: AIProcessRequest,
        settings _: AIEndpointSettings
    ) async throws -> AIProcessResult {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        throw KVoiceError(code: .aiCancelled, retryable: false)
    }

    func testConfiguration(_: AIEndpointSettings) async throws {}

    func cancel(jobID _: JobID) async {
        continuation?.resume()
        continuation = nil
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }
}

private struct CoordinatorContextDouble: AIContextProviding {
    let clipboard: String?
    let selection: String?

    func clipboardText() async -> String? { clipboard }
    func selectedText() async -> String? { selection }
}
