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
