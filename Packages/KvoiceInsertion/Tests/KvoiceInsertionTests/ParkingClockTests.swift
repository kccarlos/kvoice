import XCTest
import KvoiceTestSupport

/// The parking clock is what makes the executor-timeout tests deterministic,
/// so its own contract is pinned here, next to its first consumer: a sleep
/// resumes only once `advance(by:)` reaches its deadline, and a cancelled
/// sleep throws and leaves the clock at once.
final class ParkingClockTests: XCTestCase {
    func testSleepResumesOnlyWhenTheDeadlineIsReached() async throws {
        let clock = ParkingClock()
        let start = clock.now
        let sleeper = Task { try await clock.sleep(for: .milliseconds(30)) }

        await clock.waitForSleepers(1)
        XCTAssertEqual(clock.pendingDurations, [.milliseconds(30)])
        clock.advance(by: .milliseconds(29))
        XCTAssertEqual(clock.pendingSleepCount, 1)
        clock.advance(by: .milliseconds(1))
        try await sleeper.value

        XCTAssertEqual(clock.pendingSleepCount, 0)
        XCTAssertEqual(start.duration(to: clock.now), .milliseconds(30))
    }

    func testAdvanceResumesOnlyTheSleepersThatAreDue() async throws {
        let clock = ParkingClock()
        let short = Task { try await clock.sleep(for: .milliseconds(10)) }
        await clock.waitForSleepers(1)
        let long = Task { try await clock.sleep(for: .milliseconds(50)) }
        await clock.waitForSleepers(2)

        clock.advance(by: .milliseconds(20))
        try await short.value
        XCTAssertEqual(clock.pendingDurations, [.milliseconds(50)])

        clock.advance(by: .milliseconds(30))
        try await long.value
        XCTAssertEqual(clock.pendingSleepCount, 0)
    }

    func testCancellingAParkedSleepThrowsAndRemovesIt() async {
        let clock = ParkingClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(1)) }
        await clock.waitForSleepers(1)

        sleeper.cancel()
        do {
            try await sleeper.value
            XCTFail("a cancelled sleep must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(clock.pendingSleepCount, 0)
    }

    func testASleepCancelledBeforeItParksNeverParks() async {
        let clock = ParkingClock()
        let sleeper = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(for: .seconds(1))
        }
        do {
            try await sleeper.value
            XCTFail("a cancelled sleep must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(clock.pendingSleepCount, 0)
    }

    func testANonPositiveSleepReturnsAtOnce() async throws {
        let clock = ParkingClock()
        try await clock.sleep(for: .zero)
        XCTAssertEqual(clock.pendingSleepCount, 0)
    }
}
