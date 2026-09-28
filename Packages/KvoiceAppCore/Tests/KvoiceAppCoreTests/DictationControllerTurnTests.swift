import Foundation
import XCTest
import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceAppCore

/// The engine and insertion turns once quitting has begun
/// (`DictationController+Turns.swift`). `terminate()` sets `terminating`
/// before the first runner quits; from then on no turn is granted, so a job
/// queued behind the quitting one can never start a new pass after quit
/// began. These drive the turns directly, with no pipeline and no
/// scheduling in the assertions.
final class DictationControllerTurnTests: XCTestCase {
    func testAQueuedEngineWaitIsNotGrantedOnceQuittingBeganAndIsAbandoned() async {
        let controller = makeController()
        let first = UUID()
        let second = UUID()
        let firstHolds = await controller.acquireEngine(for: first)
        XCTAssertTrue(firstHolds)
        let secondWait = Task { await controller.acquireEngine(for: second) }
        await waitForEngineWaiters(controller, count: 1)

        await controller.beginTerminatingForTesting()
        await controller.releaseEngine(for: first)

        let holder = await controller.engineHolder
        XCTAssertNil(holder, "the released turn is not handed to the queued job")
        let queued = await controller.engineWaiters.count
        XCTAssertEqual(queued, 1, "still queued, not granted")
        // The queued job has no runner in `.transcribing` (its runner quit),
        // so the next runner change abandons its wait.
        await controller.runnerDidChange()
        let granted = await secondWait.value
        XCTAssertFalse(granted)
        let left = await controller.engineWaiters.count
        XCTAssertEqual(left, 0)
    }

    /// The control: without quitting, the same release hands the turn over.
    func testWithoutQuittingTheReleasedEngineTurnGoesToTheQueuedJob() async {
        let controller = makeController()
        let first = UUID()
        let second = UUID()
        _ = await controller.acquireEngine(for: first)
        let secondWait = Task { await controller.acquireEngine(for: second) }
        await waitForEngineWaiters(controller, count: 1)

        await controller.releaseEngine(for: first)

        let granted = await secondWait.value
        XCTAssertTrue(granted)
        let holder = await controller.engineHolder
        XCTAssertEqual(holder, second)
    }

    func testOnceQuittingBeganNeitherTurnIsGrantedEvenWhenFree() async {
        let controller = makeController()
        await controller.beginTerminatingForTesting()

        let engine = await controller.acquireEngine(for: UUID())
        let insertion = await controller.acquireInsertionTurn(for: UUID())

        XCTAssertFalse(engine)
        XCTAssertFalse(insertion)
        let engineHolder = await controller.engineHolder
        let insertionHolder = await controller.insertionHolder
        XCTAssertNil(engineHolder)
        XCTAssertNil(insertionHolder)
    }

    // MARK: Helpers

    private func makeController() -> DictationController {
        let now = ContinuousClock().now
        return DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: TranscriptionResult(
                text: "x",
                detectedLanguage: nil,
                segments: [],
                timings: TranscriptionTimings(
                    requestStart: now,
                    inferenceStart: now,
                    inferenceEnd: now,
                    runtimeReportedRealTimeFactor: nil
                ),
                modelID: "fixture"
            )),
            insertion: FakeTextInsertionService(target: nil)
        )
    }

    private func waitForEngineWaiters(
        _ controller: DictationController,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var yields = 0
        while await controller.engineWaiters.count < count {
            yields += 1
            if yields > testYieldBudget {
                let observed = await controller.engineWaiters.count
                return XCTFail("\(observed) engine waiters after \(testYieldBudget) yields, expected \(count)", file: file, line: line)
            }
            await Task.yield()
        }
    }
}

extension DictationController {
    /// What `terminate()` does first, without quitting any runner.
    func beginTerminatingForTesting() {
        terminating = true
    }
}
