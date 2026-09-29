import XCTest
@testable import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceUI

/// The model step showed only a readiness label, so a multi-minute verify or
/// CoreML load was indistinguishable from "no model configured". These cover
/// the activity/progress surface that reports in-flight work.
@MainActor
final class OnboardingModelActivityTests: XCTestCase {
    func testIdleStatesReportNoActivity() {
        let model = OnboardingViewModel()

        let idle: [ModelLifecycleState] = [
            .absent,
            .ready(Self.summary),
            .inference(Self.summary, jobID: JobID())
        ]
        for state in idle {
            model.setModelState(state)
            XCTAssertFalse(model.modelIsBusy, "\(state) must not be busy")
            XCTAssertNil(model.modelActivityDescription, "\(state) must not describe activity")
            XCTAssertNil(model.modelProgress)
        }
    }

    func testInFlightStatesAreBusyAndDescribed() {
        let model = OnboardingViewModel()

        let inFlight: [ModelLifecycleState] = [
            .validatingExternal,
            .downloading(completed: 1_000, total: 4_000),
            .verifying(completedFiles: 2, totalFiles: 4),
            .installing,
            .loading,
            .deleting(Self.summary)
        ]

        for state in inFlight {
            model.setModelState(state)
            XCTAssertTrue(model.modelIsBusy, "\(state) must be busy")
            XCTAssertNotNil(
                model.modelActivityDescription,
                "\(state) must describe what is happening"
            )
        }
    }

    func testCountedStatesExposeDeterminateProgress() {
        let model = OnboardingViewModel()

        model.setModelState(.downloading(completed: 1_000, total: 4_000))
        XCTAssertEqual(model.modelProgress, 0.25)

        model.setModelState(.verifying(completedFiles: 3, totalFiles: 4))
        XCTAssertEqual(model.modelProgress, 0.75)
    }

    /// 2026-09-29: a cached load is plain "Loading…" — the "first time"
    /// warning belongs to `.optimizing` only.
    func testACachedLoadIsIndeterminateAndMakesNoFirstTimeClaim() {
        let model = OnboardingViewModel()
        model.setModelState(.loading)

        XCTAssertTrue(model.modelIsBusy)
        // Indeterminate: the runtime load reports no counted work, so the view
        // must fall back to a spinner rather than a zero-valued bar.
        XCTAssertNil(model.modelProgress)
        let description = model.modelActivityDescription ?? ""
        XCTAssertEqual(description, "Loading the model…")
        XCTAssertFalse(description.lowercased().contains("first time"))
    }

    /// Owner decision 2: the first Core ML build says what it is, how long,
    /// that it is once, and that setup can go on — with no percentage.
    func testTheFirstCompileIsIndeterminateAndSaysFirstTimeOnly() {
        let model = OnboardingViewModel()
        model.setModelState(.optimizing)

        XCTAssertTrue(model.modelIsBusy)
        XCTAssertNil(model.modelProgress, "Core ML reports no progress; never a made-up percentage")
        XCTAssertNil(model.modelProgressPercentDescription)
        XCTAssertNil(model.modelPrimaryAction, "nothing to press while it compiles")
        XCTAssertEqual(
            model.modelActivityDescription,
            "Optimizing for your Mac — first time only, this can take a few minutes. You can continue setup meanwhile."
        )
        XCTAssertEqual(model.actionBar.primaryTitle, "Continue", "setup is not held hostage by the compile")
        XCTAssertEqual(model.readiness.model, .notReady)
    }

    /// 2026-09-29: a Download the shell refused (a launch load was running
    /// before the first state report landed) says why on the card, and the
    /// note goes once the state moves on.
    func testARefusedModelActionExplainsItselfUntilTheStateMoves() {
        let model = OnboardingViewModel(clock: ParkingClock())
        model.handleModelAction(.download)
        XCTAssertTrue(model.modelActionPending)

        model.showModelNotice("The speech model is loading. Model changes are available when it finishes.")
        XCTAssertEqual(model.modelNotice, "The speech model is loading. Model changes are available when it finishes.")
        XCTAssertFalse(model.modelActionPending, "the spinner stops: nothing was started")

        model.setModelState(.absent)
        XCTAssertNotNil(model.modelNotice, "an unchanged state keeps the note")
        model.setModelState(.optimizing)
        XCTAssertNil(model.modelNotice)
    }

    private static var summary: InstalledModelSummary {
        InstalledModelSummary(
            modelID: "whisper-large-v3-turbo-coreml-uncompressed",
            revision: "04e5c42d80a522518023727e8c7e68d4bb391b28",
            ownership: .externalReadOnly
        )
    }
}
