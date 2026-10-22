import AppKit
import XCTest
@testable import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceUI

/// UI v2 fidelity F5: the recorder's subtitle facts, the shared outcome
/// lines, the feedback filter carrying every field, live-word splitting,
/// the meter and the controller's entrance / exit seams.
@MainActor
final class HUDFidelityTests: XCTestCase {
    private let facts = HUDJobFacts(
        modelName: "Whisper large-v3-turbo", aiActionName: "Clean Up", aiProviderName: "Local Ollama",
        targetAppName: "Notes", wordCount: 38
    )

    func testProcessingSubtitlesNameTheModelTheActionAndTheApp() {
        XCTAssertEqual(HUDViewState(phase: .finalizing, facts: facts).subtitle?.text, "Whisper large-v3-turbo")
        XCTAssertEqual(HUDViewState(phase: .transcribing, facts: facts).subtitle?.text, "Whisper large-v3-turbo · on device")
        let polishing = HUDViewState(phase: .processingAI(HUDProcessingAIState(mode: .polish)), facts: facts)
        XCTAssertEqual(polishing.subtitle?.text, "Local Ollama")
        XCTAssertEqual(polishing.processingBadge, "Clean Up")
        XCTAssertNil(HUDViewState(phase: .transcribing, facts: facts).processingBadge, "the badge is the AI phase's")
        XCTAssertNil(
            HUDViewState(phase: .processingAI(HUDProcessingAIState(mode: .translate, targetLanguageDisplayName: "Japanese")), facts: facts).processingBadge,
            "the title already names the translation (as the panel)"
        )
        XCTAssertEqual(HUDViewState(phase: .inserting, facts: facts).subtitle?.text, "into Notes")
        XCTAssertNil(HUDViewState(phase: .transcribing).subtitle, "no facts, no line")
        XCTAssertEqual(
            HUDViewState(phase: .transcribing, busyHint: true, facts: facts).subtitle?.text,
            "Finishing previous dictation…", "the busy note outranks the facts"
        )
    }

    func testOutcomeSubtitlesAreTheDesignsShortLines() {
        let inserted = HUDViewState(phase: .completed(HUDCompletionState(kind: .success)), facts: facts)
        XCTAssertEqual(inserted.subtitle, HUDSubtitle("38 words → Notes"))

        let noAI = HUDViewState(phase: .completed(HUDCompletionState(
            kind: .aiFallback, warningMessage: KVoiceErrorCode.aiTimeout.userFacingMessage, aiFallback: .aiTimeout
        )), facts: facts)
        XCTAssertEqual(noAI.subtitle?.text, "Local Ollama didn’t answer · raw transcript used")
        XCTAssertEqual(
            noAI.spokenDetail, "Local Ollama didn’t answer · raw transcript used. \(KVoiceErrorCode.aiTimeout.userFacingMessage)",
            "VoiceOver keeps the full reason"
        )
        XCTAssertEqual(HUDViewState.aiFallbackLine(.aiUnreachable, provider: nil), "AI didn’t answer · raw transcript used")

        let copied = HUDViewState(phase: .completed(HUDCompletionState(kind: .clipboardFallback, clipboardReason: .setFailed)))
        XCTAssertEqual(copied.subtitle?.text, "This field doesn’t accept typing — press ⌘V")
        XCTAssertEqual(HUDViewState.clipboardLine(.secureTarget), "Secure fields can’t take dictation — press ⌘V")
        XCTAssertEqual(HUDViewState.clipboardLine(nil), "Press ⌘V to paste")

        let noSpeech = HUDViewState(phase: .failed(HUDFailureState(code: KVoiceErrorCode.sttEmpty.rawValue, message: "x")))
        XCTAssertEqual(noSpeech.subtitle, HUDSubtitle("No speech detected"))
        let other = HUDViewState(phase: .failed(HUDFailureState(code: KVoiceErrorCode.audioInterrupted.rawValue, message: "Long reason.")))
        XCTAssertEqual(other.subtitle, HUDSubtitle("Long reason.", wraps: true), "no short form: the sentence wraps")

        let mic = HUDViewState(phase: .blocked(HUDBlockedState(
            code: KVoiceErrorCode.permissionMicrophoneDenied.rawValue,
            message: KVoiceErrorCode.permissionMicrophoneDenied.userFacingMessage
        )))
        XCTAssertEqual(mic.subtitle?.text, "Microphone access is off")
    }

    func testModelUnavailableOffersTheSpeechModelsLinkAndOnlyIt() {
        let fatal = HUDViewState(phase: .failed(HUDFailureState(
            code: KVoiceErrorCode.modelLoadFailed.rawValue, message: "The model is unavailable.", isFatal: true
        )))
        XCTAssertEqual(fatal.subtitle, HUDSubtitle("Open Speech Models to reinstall", style: .link))
        XCTAssertTrue(fatal.offersSpeechModelsLink)
        XCTAssertEqual(fatal.spokenDetail, "The model is unavailable. Open Speech Models to reinstall")
        XCTAssertEqual(fatal.recoveryActions, [], "a link, not a third recovery button")
        XCTAssertFalse(HUDViewState(phase: .completed(HUDCompletionState(kind: .success))).offersSpeechModelsLink)

        let controller = HUDController(announce: { _ in })
        controller.show(fatal)
        XCTAssertEqual(controller.panel?.ignoresMouseEvents, false, "the link takes its click")
        controller.show(HUDViewState(phase: .transcribing))
        XCTAssertEqual(controller.panel?.ignoresMouseEvents, true)
        controller.dismiss()
    }

    func testFactsAreDroppedWhileIdle() {
        XCTAssertEqual(HUDViewState(phase: .idle, facts: facts).facts, HUDJobFacts())
        XCTAssertNil(HUDJobFacts(modelName: "  ").modelName)
    }

    func testDomainProjectionCarriesTheReasonsAndTheFacts() {
        let id = JobID()
        let copied = HUDViewState(
            dictationState: .completed(id, CompletionSummary(insertion: .copiedToClipboard(reason: .secureTarget))),
            facts: facts
        )
        guard case .completed(let completion) = copied.phase else { return XCTFail("not completed") }
        XCTAssertEqual(completion.clipboardReason, .secureTarget)
        XCTAssertEqual(copied.facts, facts)
    }

    func testTheFeedbackFilterKeepsTheFinishingBadgeAndTheFacts() {
        let controller = HUDController(announce: { _ in })
        let state = HUDViewState(phase: .recording(HUDRecordingState(inputLevel: 0.5, elapsed: .seconds(3))), finishingCount: 1, facts: facts)
        controller.show(state)
        XCTAssertEqual(controller.renderState.finishingBadge, "1 finishing", "the filter once dropped it")
        XCTAssertEqual(controller.renderState.facts, facts)
        // A second tick inside the meter budget holds the meter, keeps the rest.
        controller.show(HUDViewState(phase: .recording(HUDRecordingState(inputLevel: 0.9, elapsed: .seconds(3))), finishingCount: 1, facts: facts))
        XCTAssertEqual(controller.renderState.finishingCount, 1)
        controller.dismiss()
    }

    func testEachAppearanceIsAFreshPresentationAndTheExitWaitsForTheClock() async throws {
        let clock = ParkingClock()
        let controller = HUDController(announce: { _ in }, clock: clock, exitDelay: .milliseconds(240))
        controller.show(HUDViewState(phase: .transcribing))
        let first = controller.presentationID
        controller.show(HUDViewState(phase: .inserting))
        XCTAssertEqual(controller.presentationID, first, "a phase change is not a new appearance")

        controller.dismiss()
        XCTAssertFalse(controller.isVisible, "logically hidden at once")
        XCTAssertEqual(controller.panel?.isVisible, true, "still ordered in for the exit")
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(240))
        for _ in 0..<50 where controller.panel?.isVisible == true {
            await Task.yield()
        }
        XCTAssertEqual(controller.panel?.isVisible, false, "ordered out after the exit")

        controller.show(HUDViewState(phase: .transcribing))
        XCTAssertEqual(controller.presentationID, first + 1, "a new appearance enters anew")
        controller.dismiss()
    }

    func testTheShellsDismissalAfterTheAutoDismissalLetsTheExitFinish() async throws {
        let clock = ParkingClock()
        let controller = HUDController(announce: { _ in }, clock: clock, exitDelay: .milliseconds(240))
        let done = HUDViewState(phase: .completed(HUDCompletionState(kind: .success)))
        controller.show(done)
        await clock.waitForSleepers(1)
        let timer = try XCTUnwrap(controller.dismissalTask)
        clock.advance(by: .milliseconds(900))
        await timer.value
        XCTAssertFalse(controller.isVisible)
        // The shell's own D.4 timer lands a moment later and sends idle.
        controller.dismiss()
        XCTAssertEqual(controller.panel?.isVisible, true, "the exit keeps playing")
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(240))
        for _ in 0..<50 where controller.panel?.isVisible == true {
            await Task.yield()
        }
        XCTAssertEqual(controller.panel?.isVisible, false)
    }

    func testAShowDuringTheExitTakesThePanelBack() async {
        let clock = ParkingClock()
        let controller = HUDController(announce: { _ in }, clock: clock, exitDelay: .milliseconds(240))
        controller.show(HUDViewState(phase: .completed(HUDCompletionState(kind: .success))))
        controller.dismiss()
        await clock.waitForSleepers(1)
        controller.show(HUDViewState(phase: .recording(HUDRecordingState(captureStarted: false))))
        clock.advance(by: .milliseconds(240))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.panel?.isVisible, true, "the cancelled exit never orders the new recording out")
        controller.dismiss()
    }

    func testLiveWordsSplitByWordAndKeepSpacing() {
        XCTAssertEqual(HUDLiveWords.tokens("send the deck"), ["send ", "the ", "deck"])
        XCTAssertEqual(HUDLiveWords.tokens("…move it, now"), ["…move ", "it, ", "now"])
        XCTAssertEqual(HUDLiveWords.tokens("   "), [])
        let chinese = HUDLiveWords.tokens("我们把设计评审改到星期四")
        XCTAssertGreaterThan(chinese.count, 1, "a Chinese sentence is several words, not one block")
        XCTAssertEqual(chinese.joined(), "我们把设计评审改到星期四", "nothing lost")
    }

    func testWordFlowDropsTheOldestWordsUntilTheRestFit() {
        XCTAssertEqual(HUDWordFlow.lineCount([40, 40, 40], width: 100), 2)
        XCTAssertEqual(HUDWordFlow.firstVisible(widths: [40, 40, 40], width: 100, maxLines: 2), 0)
        XCTAssertEqual(HUDWordFlow.firstVisible(widths: [40, 40, 40], width: 100, maxLines: 1), 1, "newest kept")
    }

    func testMeterBarsFollowTheMotionFormula() {
        XCTAssertEqual(HUDMeter.barHeight(peak: 1, level: 1, live: true, boxHeight: 22), 22)
        XCTAssertEqual(HUDMeter.barHeight(peak: 0.45, level: 0, live: true, boxHeight: 22), 4, "silence: 4 pt")
        XCTAssertEqual(HUDMeter.barHeight(peak: 1, level: 1, live: false, boxHeight: 22), 6, "starting stubs")
    }

    func testFollowerStepsByRealTime() {
        var follower = KVLevelFollower()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        follower.follow(raw: 1, at: start)
        XCTAssertEqual(follower.lastTick, start)
        var reference = KVLevelFollower()
        reference.step(raw: 1, elapsed: 0.05)
        XCTAssertEqual(follower.level, reference.level, accuracy: 1e-12, "first call: 50 ms")
        follower.follow(raw: 1, at: start.addingTimeInterval(5))
        reference.step(raw: 1, elapsed: 0.2)
        XCTAssertEqual(follower.level, reference.level, accuracy: 1e-12, "gaps clamp to 200 ms")
    }

    func testThePillShapeIsACapsuleForOneRowAndRoundedBeyond() {
        let shape = HUDPillShape()
        let row = shape.path(in: CGRect(x: 0, y: 0, width: 316, height: 54)).boundingRect
        XCTAssertEqual(row.height, 54)
        XCTAssertEqual(HUDView.notchHeight(for: HUDViewState(phase: .transcribing)), 44)
        XCTAssertEqual(HUDView.notchHeight(for: HUDViewState(phase: .recording(HUDRecordingState()), partialTranscript: "")), 62)
        XCTAssertEqual(HUDView.notchHeight(for: HUDViewState(phase: .recording(HUDRecordingState(elapsed: .seconds(300))))), 58)
        XCTAssertEqual(HUDView.recoveryPanelWidth, 316, "the design's kept-transcript width")
    }
}
