import XCTest
import KvoiceDomain
import KvoiceTestSupport

/// The diagnostics double both insertion suites wait on. A satisfied wait's
/// hang guard is cancelled; it must not then release a later waiter early.
final class RecordingDiagnosticLogTests: XCTestCase {
    /// Two waits parked on one log: satisfying the first cancels its hang
    /// guard, and that cancelled guard must not release the second one.
    func testTwoWaitsOnOneLogEachGetTheirFullCount() async {
        let log = RecordingDiagnosticLog()
        let first = Task { await log.events(named: .insertionUncertain) }
        await waitForPendingWaits(1, on: log)
        let second = Task { await log.events(named: .insertionFailed, count: 2) }
        await waitForPendingWaits(2, on: log)

        await log.log(DiagnosticEvent(name: .insertionUncertain))
        let firstEvents = await first.value
        XCTAssertEqual(firstEvents.count, 1)
        // Give the first wait's cancelled guard every chance to run.
        for _ in 0..<500 { await Task.yield() }
        await XCTAssertEqualAsync(await log.pendingWaitCount, 1, "the second wait is still parked")

        await log.log(DiagnosticEvent(name: .insertionFailed))
        await log.log(DiagnosticEvent(name: .insertionFailed))
        let secondEvents = await second.value
        XCTAssertEqual(secondEvents.count, 2, "the second wait returned before its count arrived")
    }

    /// A later wait on the same log, after the first one was satisfied.
    func testSequentialWaitsOnOneLogEachGetTheirFullCount() async {
        let log = RecordingDiagnosticLog()
        let first = Task { await log.events(named: .insertionUncertain) }
        await waitForPendingWaits(1, on: log)
        await log.log(DiagnosticEvent(name: .insertionUncertain))
        _ = await first.value

        let second = Task { await log.events(named: .insertionFailed, count: 2) }
        await waitForPendingWaits(1, on: log)
        for _ in 0..<500 { await Task.yield() }
        await log.log(DiagnosticEvent(name: .insertionFailed))
        await log.log(DiagnosticEvent(name: .insertionFailed))
        let secondEvents = await second.value
        XCTAssertEqual(secondEvents.count, 2)
    }

    private func waitForPendingWaits(_ count: Int, on log: RecordingDiagnosticLog) async {
        let deadline = ContinuousClock.now + .seconds(30)
        while await log.pendingWaitCount < count {
            guard ContinuousClock.now < deadline else {
                return XCTFail("the wait never parked")
            }
            await Task.yield()
        }
    }

    func testAWaitAlreadySatisfiedReturnsAtOnce() async {
        let log = RecordingDiagnosticLog()
        await log.log(DiagnosticEvent(name: .insertionCompleted))
        let events = await log.events(named: .insertionCompleted)
        XCTAssertEqual(events.map(\.name), [.insertionCompleted])
    }
}
