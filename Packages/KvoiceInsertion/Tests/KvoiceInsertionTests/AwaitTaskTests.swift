import XCTest
import KvoiceTestSupport

/// `awaitTask` is the hang guard the timer tests use after advancing a
/// `ParkingClock`: it must return as soon as the task does, and turn a task
/// that never finishes into a failure rather than a hung suite.
final class AwaitTaskTests: XCTestCase {
    func testAFinishedTaskWinsTheRace() async {
        let task = Task<Void, Never> {}
        let finished = await taskFinishes(task, within: .seconds(30))
        XCTAssertTrue(finished)
        await awaitTask(task, "a finished task must not fail")
    }

    func testATaskThatNeverFinishesLosesToTheGuard() async {
        let clock = ParkingClock()
        // Parks until cancelled: nothing advances the clock.
        let stuck = Task<Void, Never> { try? await clock.sleep(for: .seconds(1)) }
        await clock.waitForSleepers(1)
        let finished = await taskFinishes(stuck, within: .milliseconds(20))
        XCTAssertFalse(finished, "the guard must end the wait, not hang on the task")
        stuck.cancel()
    }
}
