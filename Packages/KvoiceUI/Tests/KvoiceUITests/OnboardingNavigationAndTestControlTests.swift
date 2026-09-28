import XCTest
@testable import KvoiceDomain
@testable import KvoiceUI

/// The setup flow was forward-only and its dictation test had no stop control:
/// once recording started, the only exits were the global shortcut or the
/// recorder's duration cap.
@MainActor
final class OnboardingNavigationAndTestControlTests: XCTestCase {
    func testBackIsUnavailableOnTheFirstStage() {
        let model = OnboardingViewModel()

        XCTAssertEqual(model.stage, .welcome)
        XCTAssertFalse(model.canGoBack)

        model.goBack()
        XCTAssertEqual(model.stage, .welcome, "goBack must be inert on the first stage")
    }

    func testBackReturnsToThePreviousStage() {
        let model = OnboardingViewModel()

        model.advance()
        XCTAssertEqual(model.stage, .speechModel)
        XCTAssertTrue(model.canGoBack)

        model.goBack()
        XCTAssertEqual(model.stage, .welcome)
        XCTAssertFalse(model.canGoBack)
    }

    func testBackReachesTheModelStageAfterSkippingPastIt() {
        let model = OnboardingViewModel()

        model.advance()            // welcome -> model
        model.handleModelAction(.skip)
        XCTAssertEqual(model.stage, .microphone)

        model.goBack()
        XCTAssertEqual(
            model.stage,
            .speechModel,
            "a user who skipped the model step must be able to return to it"
        )
    }

    func testBackIsUnavailableOnceFinished() {
        let model = OnboardingViewModel()

        // finishOnboarding() only applies on the ready stage.
        model.advance()                    // welcome -> model
        model.handleModelAction(.skip)     // -> microphone
        model.skipMicrophone()             // -> accessibility
        model.skipAccessibility()          // -> shortcut
        model.skipShortcut()               // -> ready
        XCTAssertEqual(model.stage, .ready)

        model.finishOnboarding()
        XCTAssertTrue(model.isFinished)
        XCTAssertFalse(model.canGoBack, "a completed flow must not navigate back")

        model.goBack()
        XCTAssertEqual(model.stage, .ready)
    }

    func testStopDictationTestEmitsOnlyWhileRecording() {
        var intents: [OnboardingIntent] = []
        let model = OnboardingViewModel(onIntent: { intents.append($0) })

        // Not recording: stop must not emit.
        model.stopDictationTest()
        XCTAssertTrue(intents.isEmpty)

        model.setDictationTestRecording(true)
        model.stopDictationTest()
        XCTAssertEqual(intents, [.stopDictationTest])
    }

    func testCoordinatorReportedRecordingStateDrivesTheStopControl() {
        let model = OnboardingViewModel()
        XCTAssertFalse(model.dictationTestIsRecording)

        // The coordinator polls the real recorder, so the control tracks
        // recording started by the global shortcut too.
        model.setDictationTestRecording(true)
        XCTAssertTrue(model.dictationTestIsRecording)

        model.setDictationTestRecording(false)
        XCTAssertFalse(model.dictationTestIsRecording)
    }
}
