import Foundation
import KvoiceDomain
import KvoiceTestSupport
import XCTest
@testable import KvoiceAppCore

/// The bounded quit (2026-09-16): the shutdown steps run in order and the
/// handshake returns either when they finish or when the deadline fires,
/// naming the step that was still running.
final class TerminationHandshakeTests: XCTestCase {
    func testStepsRunInOrderAndCompleteBeforeTheDeadline() async {
        let clock = GatedClock()
        let order = Recorder()
        let handshake = TerminationHandshake(deadline: .seconds(3), clock: clock)

        let outcome = await handshake.run([
            .init("dictationController") { order.append("dictationController"); clock.advance(by: .milliseconds(100)) },
            .init("modelInstallation") { order.append("modelInstallation"); clock.advance(by: .milliseconds(100)) },
            .init("transcriptionEngine") { order.append("transcriptionEngine"); clock.advance(by: .milliseconds(100)) },
        ])

        XCTAssertEqual(outcome, .completed(duration: .milliseconds(300)))
        XCTAssertEqual(order.values, ["dictationController", "modelInstallation", "transcriptionEngine"])
    }

    func testDeadlineNamesTheStalledStepAndStillReturns() async {
        let clock = GatedClock()
        let order = Recorder()
        let handshake = TerminationHandshake(deadline: .seconds(3), clock: clock)

        let outcome = await handshake.run([
            .init("dictationController") { order.append("dictationController"); clock.advance(by: .milliseconds(100)) },
            .init("transcriptionEngine") {
                order.append("transcriptionEngine")
                // Let the deadline fire only once this step is the one
                // being awaited, then stall until the handshake cancels us.
                clock.wake()
                try? await Task.sleep(for: .seconds(3600))
            },
            .init("neverReached") { order.append("neverReached") },
        ])

        XCTAssertEqual(outcome, .timedOut(step: "transcriptionEngine", duration: .milliseconds(100)))
        XCTAssertEqual(order.values, ["dictationController", "transcriptionEngine"], "the steps after the stalled one never run")
    }

    func testNoStepsCompletesAtOnce() async {
        let handshake = TerminationHandshake(deadline: .seconds(3), clock: GatedClock())
        let outcome = await handshake.run([])
        XCTAssertEqual(outcome, .completed(duration: .zero))
    }

    func testOutcomeDurationIsTheSameForBothCases() {
        XCTAssertEqual(TerminationHandshake.Outcome.completed(duration: .seconds(1)).duration, .seconds(1))
        XCTAssertEqual(TerminationHandshake.Outcome.timedOut(step: "x", duration: .seconds(2)).duration, .seconds(2))
    }

    // MARK: Doubles

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ value: String) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }
    }

    /// `now` moves only by `advance(by:)`; `sleep` parks until `wake()` (or
    /// cancellation), so the test decides whether the deadline fires and
    /// exactly when.
    private final class GatedClock: KvoiceClock, @unchecked Sendable {
        private let lock = NSLock()
        private var current: ContinuousClock.Instant = ContinuousClock().now
        private var sleepers: [CheckedContinuation<Void, Error>] = []
        private var woken = false

        var now: ContinuousClock.Instant {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        func advance(by duration: Duration) {
            lock.lock()
            current = current + duration
            lock.unlock()
        }

        func wake() {
            lock.lock()
            woken = true
            let sleepers = self.sleepers
            self.sleepers = []
            lock.unlock()
            for sleeper in sleepers { sleeper.resume() }
        }

        func sleep(for _: Duration) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    if woken {
                        lock.unlock()
                        continuation.resume()
                        return
                    }
                    // Cancelled before the continuation registered: the
                    // `onCancel` handler has already run and found no
                    // sleeper, so it would park here forever.
                    if Task.isCancelled {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    sleepers.append(continuation)
                    lock.unlock()
                }
            } onCancel: {
                lock.lock()
                let sleepers = self.sleepers
                self.sleepers = []
                lock.unlock()
                for sleeper in sleepers { sleeper.resume(throwing: CancellationError()) }
            }
        }
    }
}
