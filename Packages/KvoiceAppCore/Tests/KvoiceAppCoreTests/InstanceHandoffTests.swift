import Foundation
import KvoiceDomain
import KvoiceTestSupport
import XCTest
@testable import KvoiceAppCore

/// The relaunched instance waits for the old one (2026-09-16): on its own
/// first, then `terminate()`, then `forceTerminate()`, each step bounded.
@MainActor
final class InstanceHandoffTests: XCTestCase {
    private let clock = AdvancingClock()

    /// A restart's handoff by default (`replaces` names the old instance);
    /// pass nil for a plain launch beside other instances.
    private func makeHandoff(_ instances: [FakeInstance], replaces: Int32? = 4242) -> InstanceHandoff {
        InstanceHandoff(
            lookup: FakeLookup(instances: instances),
            replacesProcessIdentifier: replaces,
            clock: clock,
            waitFor: .seconds(5),
            terminateGrace: .seconds(1),
            pollInterval: .milliseconds(100)
        )
    }

    func testNoOtherInstanceReturnsAtOnce() async {
        let handoff = makeHandoff([])
        XCTAssertFalse(handoff.isAnotherInstanceRunning)

        let outcome = await handoff.run()

        XCTAssertEqual(outcome, .init(instanceCount: 0, waited: .zero, terminateRequested: false, forceTerminateRequested: false, remaining: 0))
        XCTAssertEqual(outcome.reason, "exited")
        XCTAssertEqual(clock.sleeps, 0, "a normal launch pays nothing")
    }

    func testAnInstanceAlreadyGoneIsNotCounted() async {
        let gone = FakeInstance(clock: clock, exitsAfter: .zero)
        let handoff = makeHandoff([gone])
        XCTAssertFalse(handoff.isAnotherInstanceRunning)

        let outcome = await handoff.run()

        XCTAssertEqual(outcome.instanceCount, 0)
        XCTAssertEqual(outcome.reason, "exited")
    }

    func testWaitsForTheOldInstanceToExitOnItsOwn() async {
        let old = FakeInstance(clock: clock, exitsAfter: .milliseconds(250))
        let handoff = makeHandoff([old])
        XCTAssertTrue(handoff.isAnotherInstanceRunning)

        let outcome = await handoff.run()

        XCTAssertEqual(outcome, .init(instanceCount: 1, waited: .milliseconds(300), terminateRequested: false, forceTerminateRequested: false, remaining: 0))
        XCTAssertEqual(outcome.reason, "exited")
        XCTAssertEqual(old.terminateCalls, 0)
        XCTAssertEqual(old.forceTerminateCalls, 0)
    }

    func testTerminatesAnInstanceThatOutlivesTheWait() async {
        let old = FakeInstance(clock: clock, exitsAfter: nil, exitsOnTerminate: true)
        let handoff = makeHandoff([old])

        let outcome = await handoff.run()

        XCTAssertEqual(outcome, .init(instanceCount: 1, waited: .seconds(5), terminateRequested: true, forceTerminateRequested: false, remaining: 0))
        XCTAssertEqual(outcome.reason, "terminated")
        XCTAssertEqual(old.terminateCalls, 1)
        XCTAssertEqual(old.forceTerminateCalls, 0)
    }

    func testForceTerminatesAnInstanceThatIgnoresTerminate() async {
        let old = FakeInstance(clock: clock, exitsAfter: nil, exitsOnTerminate: false, exitsOnForceTerminate: true)
        let handoff = makeHandoff([old])

        let outcome = await handoff.run()

        XCTAssertEqual(outcome, .init(instanceCount: 1, waited: .seconds(6), terminateRequested: true, forceTerminateRequested: true, remaining: 0))
        XCTAssertEqual(outcome.reason, "forceTerminated")
        XCTAssertEqual(old.terminateCalls, 1)
        XCTAssertEqual(old.forceTerminateCalls, 1)
    }

    func testReportsAnInstanceThatSurvivesEverything() async {
        let old = FakeInstance(clock: clock, exitsAfter: nil, exitsOnTerminate: false, exitsOnForceTerminate: false)
        let handoff = makeHandoff([old])

        let outcome = await handoff.run()

        XCTAssertEqual(outcome, .init(instanceCount: 1, waited: .seconds(7), terminateRequested: true, forceTerminateRequested: true, remaining: 1))
        XCTAssertEqual(outcome.reason, "stillRunning")
    }

    func testOnlyTheSurvivorsAreTerminated() async {
        let quick = FakeInstance(clock: clock, exitsAfter: .milliseconds(100))
        let stuck = FakeInstance(clock: clock, exitsAfter: nil, exitsOnTerminate: true)
        let handoff = makeHandoff([quick, stuck])

        let outcome = await handoff.run()

        XCTAssertEqual(outcome.instanceCount, 2)
        XCTAssertEqual(outcome.reason, "terminated")
        XCTAssertEqual(quick.terminateCalls, 0, "an instance that exited is left alone")
        XCTAssertEqual(stuck.terminateCalls, 1)
    }

    // MARK: The `--replaces-pid` scope (2026-09-16 review)

    /// A Bench / DerivedData build shares the bundle id: a restart must
    /// wait on and terminate the process it replaces, and leave any other
    /// instance alone.
    func testARestartTouchesOnlyTheProcessItReplaces() async {
        let old = FakeInstance(clock: clock, exitsAfter: nil, exitsOnTerminate: true, processIdentifier: 4242)
        let benchBuild = FakeInstance(clock: clock, exitsAfter: nil, processIdentifier: 5555)
        let handoff = makeHandoff([benchBuild, old], replaces: 4242)
        XCTAssertTrue(handoff.isAnotherInstanceRunning)

        let outcome = await handoff.run()

        XCTAssertEqual(outcome.instanceCount, 1, "only the replaced process counts")
        XCTAssertEqual(outcome.reason, "terminated")
        XCTAssertEqual(old.terminateCalls, 1)
        XCTAssertEqual(benchBuild.terminateCalls, 0)
        XCTAssertEqual(benchBuild.forceTerminateCalls, 0)
    }

    func testARestartWhoseOldProcessIsAlreadyGoneWaitsForNothing() async {
        let other = FakeInstance(clock: clock, exitsAfter: nil, processIdentifier: 5555)
        let handoff = makeHandoff([other], replaces: 4242)
        XCTAssertFalse(handoff.isAnotherInstanceRunning)

        let outcome = await handoff.run()

        XCTAssertEqual(outcome.instanceCount, 0)
        XCTAssertEqual(clock.sleeps, 0)
    }

    /// Two instances launched by hand, or a test build beside the installed
    /// app: each waits for the other to leave but neither terminates the
    /// other — before this rule they would have killed each other at t=5 s.
    func testAPlainLaunchWaitsButNeverTerminates() async {
        let other = FakeInstance(clock: clock, exitsAfter: nil, exitsOnTerminate: true, exitsOnForceTerminate: true, processIdentifier: 5555)
        let handoff = makeHandoff([other], replaces: nil)
        XCTAssertTrue(handoff.isAnotherInstanceRunning)

        let outcome = await handoff.run()

        XCTAssertEqual(outcome, .init(instanceCount: 1, waited: .seconds(5), terminateRequested: false, forceTerminateRequested: false, remaining: 1))
        XCTAssertEqual(outcome.reason, "stillRunning")
        XCTAssertEqual(other.terminateCalls, 0)
        XCTAssertEqual(other.forceTerminateCalls, 0)
    }

    func testAPlainLaunchStillWaitsForAnInstanceThatIsLeaving() async {
        let leaving = FakeInstance(clock: clock, exitsAfter: .milliseconds(250), processIdentifier: 5555)
        let handoff = makeHandoff([leaving], replaces: nil)

        let outcome = await handoff.run()

        XCTAssertEqual(outcome.reason, "exited")
        XCTAssertEqual(outcome.waited, .milliseconds(300))
    }

    func testReplacedProcessIdentifierIsReadFromTheLaunchArguments() {
        XCTAssertEqual(InstanceHandoff.replacedProcessIdentifier(in: ["kvoice", "--replaces-pid", "4242"]), 4242)
        XCTAssertNil(InstanceHandoff.replacedProcessIdentifier(in: ["kvoice"]), "a normal launch")
        XCTAssertNil(InstanceHandoff.replacedProcessIdentifier(in: ["kvoice", "--replaces-pid"]), "no value")
        XCTAssertNil(InstanceHandoff.replacedProcessIdentifier(in: ["kvoice", "--replaces-pid", "not-a-pid"]))
        XCTAssertEqual(InstanceHandoff.replacesProcessArgument, "--replaces-pid", "the string restartApp() passes")
    }

    // MARK: Doubles

    private struct FakeLookup: RunningInstanceLookup {
        let instances: [FakeInstance]
        func otherInstances() -> [any RunningInstance] { instances }
    }

    /// Exits on the fake clock at `exitsAfter` (never when nil), and on
    /// `terminate()` / `forceTerminate()` only when told to.
    private final class FakeInstance: RunningInstance {
        let processIdentifier: Int32
        private let clock: AdvancingClock
        private let exitsAt: ContinuousClock.Instant?
        private let exitsOnTerminate: Bool
        private let exitsOnForceTerminate: Bool
        private var killed = false
        private(set) var terminateCalls = 0
        private(set) var forceTerminateCalls = 0

        init(
            clock: AdvancingClock,
            exitsAfter: Duration?,
            exitsOnTerminate: Bool = false,
            exitsOnForceTerminate: Bool = false,
            processIdentifier: Int32 = 4242
        ) {
            self.clock = clock
            self.processIdentifier = processIdentifier
            exitsAt = exitsAfter.map { clock.now + $0 }
            self.exitsOnTerminate = exitsOnTerminate
            self.exitsOnForceTerminate = exitsOnForceTerminate
        }

        var isTerminated: Bool {
            if killed { return true }
            guard let exitsAt else { return false }
            return clock.now >= exitsAt
        }

        func terminate() -> Bool {
            terminateCalls += 1
            if exitsOnTerminate { killed = true }
            return true
        }

        func forceTerminate() -> Bool {
            forceTerminateCalls += 1
            if exitsOnForceTerminate { killed = true }
            return true
        }
    }
}
