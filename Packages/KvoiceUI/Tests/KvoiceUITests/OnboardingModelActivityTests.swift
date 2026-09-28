import XCTest
@testable import KvoiceDomain
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

    func testLoadingIsIndeterminateAndWarnsAboutDuration() {
        let model = OnboardingViewModel()
        model.setModelState(.loading)

        XCTAssertTrue(model.modelIsBusy)
        // Indeterminate: the runtime load reports no counted work, so the view
        // must fall back to a spinner rather than a zero-valued bar.
        XCTAssertNil(model.modelProgress)
        let description = model.modelActivityDescription ?? ""
        XCTAssertTrue(
            description.lowercased().contains("first load"),
            "loading copy should set the expectation that it takes a while, got: \(description)"
        )
    }

    private static var summary: InstalledModelSummary {
        InstalledModelSummary(
            modelID: "whisper-large-v3-turbo-coreml-uncompressed",
            revision: "04e5c42d80a522518023727e8c7e68d4bb391b28",
            ownership: .externalReadOnly
        )
    }
}
