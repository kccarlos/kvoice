import Foundation
import XCTest
import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceAppCore

/// The trigger options behind the controller (product decisions #5 and #10):
/// Hybrid tap/hold, double-press auto-send, the middle-mouse trigger, the
/// recording side effects (cues, output muting, clipboard
/// copy), and the per-job capture configuration. Time is a `ManualClock`, so
/// nothing here waits.
final class DictationControllerTriggerTests: XCTestCase {
    private let target = TargetApplicationSnapshot(
        processIdentifier: 7,
        bundleIdentifier: "com.apple.TextEdit",
        localizedName: "TextEdit",
        capturedAt: Date(timeIntervalSince1970: 1)
    )

    // MARK: Hybrid

    func testHybridTapKeepsRecordingUntilTheNextPress() async {
        let clock = ManualClock()
        let insertion = FakeTextInsertionService(target: target)
        let controller = makeController(insertion: insertion, clock: clock)

        var state = await controller.handleShortcut(.keyDown, mode: .hybrid, at: clock.now)
        XCTAssertEqual(state.kind, .recording)
        clock.advance(by: .milliseconds(120))
        state = await controller.handleShortcut(.keyUp, mode: .hybrid, at: clock.now)
        XCTAssertEqual(state.kind, .recording, "a tap leaves the recording running hands-free")

        clock.advance(by: .seconds(3))
        state = await controller.handleShortcut(.keyDown, mode: .hybrid, at: clock.now)
        XCTAssertNotEqual(state.kind, .recording)
        _ = await controller.handleShortcut(.keyUp, mode: .hybrid, at: clock.now)
        await controller.waitForCompletion()
        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["hello"])
    }

    func testHybridHoldStopsOnRelease() async {
        let clock = ManualClock()
        let insertion = FakeTextInsertionService(target: target)
        let controller = makeController(insertion: insertion, clock: clock)

        _ = await controller.handleShortcut(.keyDown, mode: .hybrid, at: clock.now)
        clock.advance(by: .seconds(1))
        let state = await controller.handleShortcut(.keyUp, mode: .hybrid, at: clock.now)
        XCTAssertNotEqual(state.kind, .recording, "a hold is push-to-talk")
        await controller.waitForCompletion()
        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["hello"])
    }

    // MARK: Auto-send

    func testDoublePressArmsAutoSendAndReturnFollowsASuccessfulInsertion() async {
        let clock = ManualClock()
        let returnSender = FakeReturnKeySender()
        var settings = DomainFixtures.settings()
        settings.recordingInteraction = .toggle
        settings.triggers.autoSendEnabled = true
        let controller = makeController(
            insertion: FakeTextInsertionService(target: target),
            settings: settings,
            clock: clock,
            returnKeySender: returnSender
        )

        _ = await controller.handleShortcut(.keyDown, mode: .toggle, at: clock.now)
        _ = await controller.handleShortcut(.keyUp, mode: .toggle, at: clock.now)
        clock.advance(by: .milliseconds(150))
        let armed = await controller.handleShortcut(.keyDown, mode: .toggle, at: clock.now)
        XCTAssertEqual(armed.kind, .recording, "the second press of a double-press is consumed, not a stop")
        let job = await controller.activeJob
        XCTAssertEqual(job?.options.autoSend, true)
        _ = await controller.handleShortcut(.keyUp, mode: .toggle, at: clock.now)

        clock.advance(by: .seconds(2))
        let stopped = await controller.handleShortcut(.keyDown, mode: .toggle, at: clock.now)
        XCTAssertNotEqual(stopped.kind, .recording)
        _ = await controller.handleShortcut(.keyUp, mode: .toggle, at: clock.now)
        await controller.waitForCompletion()
        let sent = await returnSender.targets
        XCTAssertEqual(sent, [target])
    }

    func testAutoSendIsNeverAppliedAfterAClipboardFallbackOrWhenOff() async {
        let clock = ManualClock()
        // Off: a double-press is an ordinary stop.
        let offSender = FakeReturnKeySender()
        var settings = DomainFixtures.settings()
        settings.recordingInteraction = .toggle
        let off = makeController(
            insertion: FakeTextInsertionService(target: target),
            settings: settings,
            clock: clock,
            returnKeySender: offSender
        )
        _ = await off.handleShortcut(.keyDown, mode: .toggle, at: clock.now)
        _ = await off.handleShortcut(.keyUp, mode: .toggle, at: clock.now)
        clock.advance(by: .milliseconds(100))
        let stopped = await off.handleShortcut(.keyDown, mode: .toggle, at: clock.now)
        XCTAssertNotEqual(stopped.kind, .recording)
        await off.waitForCompletion()
        let offSent = await offSender.targets
        XCTAssertTrue(offSent.isEmpty)

        // On, but the insertion fell back to the clipboard: no Return.
        let sender = FakeReturnKeySender()
        settings.triggers.autoSendEnabled = true
        let insertion = FakeTextInsertionService(target: target)
        await insertion.setOutcome(.copiedToClipboard(reason: .notEditable))
        let fallback = makeController(insertion: insertion, settings: settings, clock: clock, returnKeySender: sender)
        _ = await fallback.handleShortcut(.keyDown, mode: .toggle, at: clock.now)
        _ = await fallback.handleShortcut(.keyUp, mode: .toggle, at: clock.now)
        clock.advance(by: .milliseconds(100))
        _ = await fallback.handleShortcut(.keyDown, mode: .toggle, at: clock.now)
        _ = await fallback.handleShortcut(.keyUp, mode: .toggle, at: clock.now)
        clock.advance(by: .seconds(2))
        _ = await fallback.handleShortcut(.keyDown, mode: .toggle, at: clock.now)
        await fallback.waitForCompletion()
        let sent = await sender.targets
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: Middle mouse

    func testMiddleMouseTriggerTogglesWhateverTheKeyboardModeIs() async {
        let insertion = FakeTextInsertionService(target: target)
        let controller = makeController(insertion: insertion)

        var state = await controller.handleShortcut(.keyDown, mode: .pushToTalk, trigger: .middleMouse)
        XCTAssertEqual(state.kind, .recording)
        state = await controller.handleShortcut(.keyUp, mode: .pushToTalk, trigger: .middleMouse)
        XCTAssertEqual(state.kind, .recording, "release does not stop: a mouse button is not held to talk")
        state = await controller.handleShortcut(.keyDown, mode: .pushToTalk, trigger: .middleMouse)
        XCTAssertNotEqual(state.kind, .recording)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk, trigger: .middleMouse)
        await controller.waitForCompletion()
        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["hello"])
    }

    // MARK: Recording side effects

    func testCuesAndOutputMutingFollowEveryExitPath() async {
        var settings = DomainFixtures.settings()
        settings.recordingFeedback.muteSystemAudioDuringRecording = true

        // Stop: start, stop, pasted cues; mute then restore.
        let player = FakeFeedbackPlayer()
        let muter = FakeOutputMuter()
        let controller = makeController(
            insertion: FakeTextInsertionService(target: target),
            settings: settings,
            feedbackPlayer: player,
            outputMuter: muter
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        var muterCalls = await muter.calls
        XCTAssertEqual(muterCalls, ["mute"])
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()
        var cues = await player.cues
        XCTAssertEqual(cues, [.start, .stop, .pasted])
        muterCalls = await muter.calls
        XCTAssertEqual(muterCalls, ["mute", "restore"])

        // Escape while recording: the cancel cue, and the volume comes back.
        let cancelPlayer = FakeFeedbackPlayer()
        let cancelMuter = FakeOutputMuter()
        let cancelled = makeController(
            insertion: FakeTextInsertionService(target: target),
            settings: settings,
            feedbackPlayer: cancelPlayer,
            outputMuter: cancelMuter
        )
        let recording = await cancelled.handleShortcut(.keyDown, mode: .toggle)
        guard let jobID = recording.jobID else { return XCTFail("expected a job") }
        _ = await cancelled.handle(.escape(jobID: jobID))
        cues = await cancelPlayer.cues
        XCTAssertEqual(cues, [.start, .cancel])
        muterCalls = await cancelMuter.calls
        XCTAssertEqual(muterCalls, ["mute", "restore"])

        // Quit while recording: no cue, but never a stranded mute.
        let quitMuter = FakeOutputMuter()
        let quitPlayer = FakeFeedbackPlayer()
        let quitting = makeController(
            insertion: FakeTextInsertionService(target: target),
            settings: settings,
            feedbackPlayer: quitPlayer,
            outputMuter: quitMuter
        )
        _ = await quitting.handleShortcut(.keyDown, mode: .toggle)
        _ = await quitting.handle(.quit)
        muterCalls = await quitMuter.calls
        XCTAssertEqual(muterCalls, ["mute", "restore"])
        cues = await quitPlayer.cues
        XCTAssertEqual(cues, [.start])
    }

    // MARK: Start cue on the first buffer with signal (2026-09-16)

    func testStartCueAndMuteWaitForTheFirstBufferWithSignal() async {
        var settings = DomainFixtures.settings()
        settings.recordingFeedback.muteSystemAudioDuringRecording = true
        settings.recordingFeedback.cueSet = .system(name: "Glass")
        let audio = FakeAudioCaptureService(deliversSignalOnStart: false)
        let player = FakeFeedbackPlayer()
        let muter = FakeOutputMuter()
        let controller = DictationController(
            audio: audio,
            transcription: FakeTranscriptionEngine(result: transcript("hello")),
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: settings),
            clock: ManualClock(),
            feedbackPlayer: player,
            outputMuter: muter
        )

        // The engine is up and the route has delivered one silent buffer:
        // nothing audible yet, and the HUD is still "starting".
        let state = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        XCTAssertEqual(state.kind, .recording, "the reducer state is unchanged: recording from key-down")
        var cues = await player.cues
        XCTAssertTrue(cues.isEmpty, "no cue while the route may still be switching")
        var muterCalls = await muter.calls
        XCTAssertTrue(muterCalls.isEmpty, "the mute follows the cue, so not yet either")
        var snapshot = await controller.snapshot
        XCTAssertFalse(snapshot.captureStarted)
        XCTAssertEqual(snapshot.state.kind, .recording)

        // The first buffer with signal: cue, then mute, exactly once.
        await audio.deliverSignal()
        cues = await player.cues
        XCTAssertEqual(cues, [.start])
        let sets = await player.sets
        XCTAssertEqual(sets, [.system(name: "Glass")], "the job's snapshot chooses the set")
        muterCalls = await muter.calls
        XCTAssertEqual(muterCalls, ["mute"])
        snapshot = await controller.snapshot
        XCTAssertTrue(snapshot.captureStarted)

        await audio.deliverSignal()
        await audio.deliverSilence()
        cues = await player.cues
        XCTAssertEqual(cues, [.start], "detected once per job")
        muterCalls = await muter.calls
        XCTAssertEqual(muterCalls, ["mute"])

        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        snapshot = await controller.snapshot
        XCTAssertFalse(snapshot.captureStarted, "false in every state but recording")
        await controller.waitForCompletion()
        cues = await player.cues
        XCTAssertEqual(cues, [.start, .stop, .pasted])
        muterCalls = await muter.calls
        XCTAssertEqual(muterCalls, ["mute", "restore"])
    }

    func testAJobReleasedBeforeAnySignalNeverPlaysTheStartCue() async {
        var settings = DomainFixtures.settings()
        settings.recordingFeedback.muteSystemAudioDuringRecording = true
        let audio = FakeAudioCaptureService(deliversSignalOnStart: false)
        let player = FakeFeedbackPlayer()
        let muter = FakeOutputMuter()
        let controller = DictationController(
            audio: audio,
            transcription: FakeTranscriptionEngine(result: transcript("hello")),
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: settings),
            clock: ManualClock(),
            feedbackPlayer: player,
            outputMuter: muter
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        // Push-to-talk released while the headset is still switching.
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()
        let cues = await player.cues
        XCTAssertEqual(cues.first, .stop, "the stop cue still marks the release")
        XCTAssertFalse(cues.contains(.start), "the start cue is never played after the fact")
        let muterCalls = await muter.calls
        XCTAssertTrue(muterCalls.isEmpty, "never muted, so nothing to restore")
        let snapshot = await controller.snapshot
        XCTAssertFalse(snapshot.captureStarted)

        // Escape before any signal: the cancel cue, and still no start.
        let escapedPlayer = FakeFeedbackPlayer()
        let escapedAudio = FakeAudioCaptureService(deliversSignalOnStart: false)
        let escaped = DictationController(
            audio: escapedAudio,
            transcription: FakeTranscriptionEngine(result: transcript("hello")),
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: settings),
            clock: ManualClock(),
            feedbackPlayer: escapedPlayer,
            outputMuter: FakeOutputMuter()
        )
        let recording = await escaped.handleShortcut(.keyDown, mode: .toggle)
        guard let jobID = recording.jobID else { return XCTFail("expected a job") }
        _ = await escaped.handle(.escape(jobID: jobID))
        let escapedCues = await escapedPlayer.cues
        XCTAssertEqual(escapedCues, [.cancel])
    }

    func testElapsedClockHoldsAtZeroUntilTheFirstBufferWithSignal() async {
        let audio = FakeAudioCaptureService(deliversSignalOnStart: false)
        let controller = DictationController(
            audio: audio,
            transcription: FakeTranscriptionEngine(result: transcript("hello")),
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: DomainFixtures.settings()),
            clock: ManualClock()
        )
        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        await audio.deliverElapsed(.seconds(2))
        var state = await controller.state
        XCTAssertEqual(elapsed(of: state), .zero, "the switch is not recording time")
        await audio.deliverSignal()
        await audio.deliverElapsed(.milliseconds(300))
        state = await controller.state
        XCTAssertEqual(elapsed(of: state), .milliseconds(300), "the recorder restarts its clock at the signal; the HUD shows that")
        _ = await controller.handleShortcut(.keyDown, mode: .toggle)
        await controller.waitForCompletion()
    }

    func testEachJobPlaysItsOwnSnapshotsCueSet() async {
        var settings = DomainFixtures.settings()
        settings.recordingFeedback.cueSet = .systemClassic
        let player = FakeFeedbackPlayer()
        let controller = makeController(
            insertion: FakeTextInsertionService(target: target),
            settings: settings,
            feedbackPlayer: player
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()
        let cues = await player.cues
        XCTAssertEqual(cues, [.start, .stop, .pasted])
        let sets = await player.sets
        XCTAssertEqual(sets, [.systemClassic, .systemClassic, .systemClassic])
    }

    func testSoundFeedbackOffPlaysNothingAndMuteOffLeavesTheVolumeAlone() async {
        var settings = DomainFixtures.settings()
        settings.recordingFeedback.soundFeedbackEnabled = false
        let player = FakeFeedbackPlayer()
        let muter = FakeOutputMuter()
        let controller = makeController(
            insertion: FakeTextInsertionService(target: target),
            settings: settings,
            feedbackPlayer: player,
            outputMuter: muter
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()
        let cues = await player.cues
        XCTAssertTrue(cues.isEmpty)
        let calls = await muter.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testPreserveTranscriptInClipboardCopiesOnlyWhenOptedIn() async {
        let insertion = FakeTextInsertionService(target: target)
        let controller = makeController(insertion: insertion)
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()
        var copied = await insertion.clipboardTexts
        XCTAssertTrue(copied.isEmpty, "FR-AX-009: success never touches the pasteboard by default")

        var settings = DomainFixtures.settings()
        settings.recordingFeedback.preserveTranscriptInClipboard = true
        let optedIn = FakeTextInsertionService(target: target)
        let preserving = makeController(insertion: optedIn, settings: settings)
        _ = await preserving.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await preserving.handleShortcut(.keyUp, mode: .pushToTalk)
        await preserving.waitForCompletion()
        copied = await optedIn.clipboardTexts
        XCTAssertEqual(copied, ["hello"])
        let inserted = await optedIn.insertedTexts
        XCTAssertEqual(inserted, ["hello"], "the insertion itself is unchanged")
    }

    // MARK: Capture configuration

    func testEachJobAppliesTheDurationLimitAndInputSelectionToTheCapture() async {
        var settings = DomainFixtures.settings()
        settings.recordingDurationLimit = .thirtyMinutes
        settings.audioInput = AudioInputSettings(mode: .customDevice, customDeviceUID: "usb")
        let audio = ConfigurableAudioDouble()
        let controller = DictationController(
            audio: audio,
            transcription: FakeTranscriptionEngine(result: transcript("hello")),
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: settings)
        )
        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        let cap = await audio.maximumDuration
        XCTAssertEqual(cap, .seconds(1_800))
        let input = await audio.inputSettings
        XCTAssertEqual(input, settings.audioInput)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()
    }

    // MARK: Helpers

    private func makeController(
        insertion: FakeTextInsertionService,
        settings: AppSettings = DomainFixtures.settings(),
        history: InMemoryHistoryRepository? = nil,
        clock: any KvoiceClock = ManualClock(),
        feedbackPlayer: (any RecordingFeedbackPlaying)? = nil,
        outputMuter: (any SystemOutputMuting)? = nil,
        returnKeySender: (any ReturnKeySending)? = nil
    ) -> DictationController {
        DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("hello")),
            insertion: insertion,
            settings: FakeSettingsRepository(settings: settings),
            history: history,
            clock: clock,
            feedbackPlayer: feedbackPlayer,
            outputMuter: outputMuter,
            returnKeySender: returnKeySender
        )
    }

    private func elapsed(of state: DictationState) -> Duration? {
        if case .recording(let recording) = state { return recording.elapsed }
        return nil
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

// MARK: - Doubles

private actor FakeReturnKeySender: ReturnKeySending {
    private(set) var targets: [TargetApplicationSnapshot] = []

    func sendReturnKey(to target: TargetApplicationSnapshot, jobID _: JobID) async throws {
        targets.append(target)
    }
}

private actor FakeFeedbackPlayer: RecordingFeedbackPlaying {
    private(set) var cues: [RecordingFeedbackCue] = []
    private(set) var sets: [RecordingFeedbackCueSet] = []

    func play(_ cue: RecordingFeedbackCue, using set: RecordingFeedbackCueSet) async {
        cues.append(cue)
        sets.append(set)
    }
}

private actor FakeOutputMuter: SystemOutputMuting {
    private(set) var calls: [String] = []

    func mute() async { calls.append("mute") }
    func restore() async { calls.append("restore") }
}

/// A capture service that also accepts the per-job configuration.
private actor ConfigurableAudioDouble: AudioCaptureService, AudioCaptureConfiguring {
    private(set) var isRecording = false
    private(set) var maximumDuration: Duration?
    private(set) var inputSettings: AudioInputSettings?

    func setMaximumRecordingDuration(_ duration: Duration) async {
        maximumDuration = duration
    }

    func setInputSelection(_ settings: AudioInputSettings) async {
        inputSettings = settings
    }

    func start(jobID _: JobID, events: @escaping @Sendable (AudioCaptureEvent) async -> Void) async throws {
        isRecording = true
        await events(.elapsed(.zero))
    }

    func stop(jobID _: JobID) async throws -> AudioRecording {
        isRecording = false
        return DomainFixtures.audio()
    }

    func cancel(jobID _: JobID) async {
        isRecording = false
    }

    func setStreamingChunkSink(jobID _: JobID, _: (@Sendable (AudioSampleChunk) async -> Void)?) async {}

    func runMicrophoneTest(
        duration: Duration,
        levels _: (@Sendable (AudioCaptureEvent) async -> Void)?
    ) async throws -> MicrophoneTestResult {
        MicrophoneTestResult(duration: duration, peakLevelDBFS: -20, capturedSamples: 0)
    }
}
