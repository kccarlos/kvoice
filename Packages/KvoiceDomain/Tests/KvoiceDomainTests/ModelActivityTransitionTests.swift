import KvoiceDomain
import XCTest

/// ADR-022 item 5: the legal-transition table, every (current, requested)
/// pair. The library's own reentrancy tests (`SpeechModelLibraryTests`)
/// build on this; here the table is checked in isolation.
final class ModelActivityTransitionTests: XCTestCase {
    private let all = ModelActivityTransition.representativeActivities()
    private var activities: [ModelActivity] { all.filter { $0 != .idle } }

    func testOnlyIdleAcceptsANewActivityAndEveryPairIsCovered() {
        var pairs = 0
        for current in all {
            for requested in activities {
                pairs += 1
                let allowed = ModelActivityTransition.canBegin(requested, from: current)
                XCTAssertEqual(allowed, current == .idle, "\(requested.name) from \(current.name)")
                switch ModelActivityTransition.next(current, .begin(requested)) {
                case .success(let next):
                    XCTAssertEqual(current, .idle)
                    XCTAssertEqual(next, requested)
                case .failure(let refusal):
                    XCTAssertNotEqual(current, .idle)
                    XCTAssertEqual(refusal, ModelActivityRefusal(requested: requested, running: current))
                }
            }
        }
        XCTAssertEqual(pairs, 8 * 7, "eight states × seven requestable activities")
    }

    func testTwoOfTheSameActivityNeverOverlap() {
        for activity in activities {
            XCTAssertFalse(ModelActivityTransition.canBegin(activity, from: activity), activity.name)
        }
        // Same case, different package: still one at a time.
        XCTAssertFalse(ModelActivityTransition.canBegin(.downloading("b"), from: .downloading("a")))
    }

    func testBeginningIdleIsNeverLegal() {
        for current in all {
            XCTAssertFalse(ModelActivityTransition.canBegin(.idle, from: current), current.name)
            guard case .failure(let refusal) = ModelActivityTransition.next(current, .begin(.idle)) else {
                return XCTFail("begin(.idle) from \(current.name) must be refused")
            }
            XCTAssertEqual(refusal.requested, .idle)
            XCTAssertEqual(refusal.running, current)
        }
    }

    func testEveryActivityReturnsToIdleOnCompletionFailureOrCancellation() {
        for current in all {
            for event in [ModelActivityTransition.Event.completed, .failed, .cancelled] {
                XCTAssertEqual(
                    ModelActivityTransition.next(current, event), .success(.idle),
                    "\(current.name) on \(event)"
                )
            }
        }
    }

    func testNamesAreCaseTokensWithoutTheModelID() {
        XCTAssertEqual(all.map(\.name), [
            "idle", "downloading", "installing", "loading",
            "reloadingUnits", "testing", "transcribingFile", "unloading"
        ])
        for activity in all {
            XCTAssertFalse(activity.name.contains("model"), "\(activity.name) leaks the payload")
        }
        XCTAssertEqual(ModelActivity.downloading("x").modelID, "x")
        XCTAssertNil(ModelActivity.reloadingUnits.modelID)
        XCTAssertTrue(ModelActivity.idle.isIdle)
        XCTAssertFalse(ModelActivity.testing.isIdle)
    }

    /// The shortcut / App Intent start gate: the three engine-exercising
    /// activities beep; a package operation or a pressure unload/reload
    /// reaches the controller's prerequisite check as before.
    func testRefusesDictationStartIsExactlyTheThreeEngineExercises() {
        let refusing = all.filter(\.refusesDictationStart)
        XCTAssertEqual(refusing, [.reloadingUnits, .testing, .transcribingFile])
    }
}

/// 2026-09-29: the shell's admission policy for a user's model operation.
/// Only a download in its byte phase may be superseded (it pauses and
/// resumes); a load or verification is never cancelled — that is what
/// threw away the owner's 3.5-minute first compile — and a refusal always
/// carries a sentence.
final class ModelOperationAdmissionTests: XCTestCase {
    private let summary = InstalledModelSummary(modelID: "m", revision: "r", ownership: .managedByKvoice)

    func testIdleStarts() {
        XCTAssertEqual(ModelOperationAdmission.decide(running: .idle, runningModelState: nil), .start)
    }

    func testOnlyADownloadInItsBytePhaseIsSuperseded() {
        XCTAssertEqual(
            ModelOperationAdmission.decide(running: .downloading("m"), runningModelState: .downloading(completed: 1, total: 2)),
            .supersedeDownload
        )
        // The same install transaction past its bytes: verify, install, load.
        for state in [ModelLifecycleState.verifying(completedFiles: 1, totalFiles: 2), .installing, .loading] {
            XCTAssertEqual(
                ModelOperationAdmission.decide(running: .downloading("m"), runningModelState: state),
                .refuse(.modelLoadInProgress),
                "\(state)"
            )
        }
    }

    func testALoadOrVerificationIsRefusedNeverCancelled() {
        let states: [ModelLifecycleState?] = [nil, .verifying(completedFiles: 0, totalFiles: 1), .loading, .ready(summary)]
        for running in [ModelActivity.installing("m"), .loading("m")] {
            for state in states {
                XCTAssertEqual(
                    ModelOperationAdmission.decide(running: running, runningModelState: state),
                    .refuse(.modelLoadInProgress),
                    "\(running.name) \(String(describing: state))"
                )
            }
        }
    }

    func testTheFirstCompileSaysSo() {
        for running in [ModelActivity.installing("m"), .loading("m"), .downloading("m")] {
            XCTAssertEqual(
                ModelOperationAdmission.decide(running: running, runningModelState: .optimizing),
                .refuse(.modelOptimizing)
            )
        }
        XCTAssertTrue(SettingAvailabilityReason.modelOptimizing.message.contains("first time only"))
    }

    func testTheEngineActivitiesKeepTheirOwnReasons() {
        XCTAssertEqual(ModelOperationAdmission.decide(running: .reloadingUnits, runningModelState: nil), .refuse(.reloadingComputeUnits))
        XCTAssertEqual(ModelOperationAdmission.decide(running: .testing, runningModelState: nil), .refuse(.performanceTestRunning))
        XCTAssertEqual(ModelOperationAdmission.decide(running: .transcribingFile, runningModelState: nil), .refuse(.fileTranscriptionRunning))
        XCTAssertEqual(ModelOperationAdmission.decide(running: .unloading, runningModelState: nil), .refuse(.modelOperationInProgress))
    }

    func testEveryActivityHasADecisionAndEveryRefusalHasASentence() {
        for running in ModelActivityTransition.representativeActivities() {
            let decision = ModelOperationAdmission.decide(running: running, runningModelState: nil)
            if let reason = decision.refusalReason {
                XCTAssertFalse(reason.message.isEmpty, running.name)
            } else {
                XCTAssertEqual(running, .idle)
            }
        }
    }
}
