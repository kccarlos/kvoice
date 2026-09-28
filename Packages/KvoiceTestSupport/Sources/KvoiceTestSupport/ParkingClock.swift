import Foundation
import KvoiceDomain
import XCTest

/// A clock whose sleeps park until the test moves time past their deadline.
///
/// `ManualClock.sleep` returns at once and `AdvancingClock.sleep` jumps time
/// forward, so neither can model a *timeout*: code that races an operation
/// against `clock.sleep(for: timeout)` would see the timeout win every time.
/// Here `sleep(for:)` records `deadline = now + duration` and suspends;
/// `advance(by:)` moves `now` and resumes exactly the sleepers whose deadline
/// has passed; cancelling a sleeper resumes it with `CancellationError` and
/// removes it at once. `waitForSleepers(_:)` is the synchronisation point: a
/// test parks there until the code under test has armed its timer, so an
/// advance never lands before the sleep it is meant to fire.
public final class ParkingClock: KvoiceClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: ContinuousClock.Instant = ContinuousClock().now
    private var nextID: UInt64 = 0
    private var sleepers: [UInt64: Sleeper] = [:]
    /// Sleeps cancelled before they parked; they resume as soon as they try.
    private var cancelledBeforeParking: Set<UInt64> = []
    private var waiters: [(id: UInt64, count: Int, continuation: CheckedContinuation<Bool, Never>)] = []

    public init() {}

    public var now: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// How many sleeps are parked right now.
    public var pendingSleepCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    /// The requested durations of the parked sleeps, in no particular order.
    public var pendingDurations: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.values.map(\.duration)
    }

    public func sleep(for duration: Duration) async throws {
        let id = lock.withLock { () -> UInt64 in
            nextID &+= 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelledBeforeParking.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if duration <= .zero {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers[id] = Sleeper(deadline: current + duration, duration: duration, continuation: continuation)
                let ready = takeReadyWaiters()
                lock.unlock()
                ready.forEach { $0.resume(returning: true) }
            }
        } onCancel: {
            lock.lock()
            if let sleeper = sleepers.removeValue(forKey: id) {
                lock.unlock()
                sleeper.continuation.resume(throwing: CancellationError())
            } else {
                // Not parked yet (or already resumed, in which case the
                // marker is never read again).
                cancelledBeforeParking.insert(id)
                lock.unlock()
            }
        }
    }

    /// Moves `now` forward and resumes every sleeper whose deadline is now
    /// reached, in deadline order.
    public func advance(by duration: Duration) {
        lock.lock()
        current = current + duration
        let due = sleepers.filter { $0.value.deadline <= current }
            .sorted { $0.value.deadline < $1.value.deadline }
        for (id, _) in due {
            sleepers.removeValue(forKey: id)
        }
        lock.unlock()
        for (_, sleeper) in due {
            sleeper.continuation.resume()
        }
    }

    /// Suspends until at least `count` sleeps are parked. No polling: the
    /// next `sleep` that reaches the count resumes it. The 30 s bound is a
    /// hang guard (real time, never reached on a pass): a regression where
    /// the timer is never armed fails with a message instead of hanging.
    public func waitForSleepers(
        _ count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let id = lock.withLock { () -> UInt64 in
            nextID &+= 1
            return nextID
        }
        let hangGuard = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.abandonWaiter(id)
        }
        let satisfied = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if sleepers.count >= count {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            waiters.append((id, count, continuation))
            lock.unlock()
        }
        hangGuard.cancel()
        if !satisfied {
            XCTFail("\(count) sleep(s) never parked on the clock (\(pendingSleepCount) did)", file: file, line: line)
        }
    }

    private func abandonWaiter(_ id: UInt64) {
        lock.lock()
        let index = waiters.firstIndex { $0.id == id }
        let waiter = index.map { waiters.remove(at: $0) }
        lock.unlock()
        waiter?.continuation.resume(returning: false)
    }

    /// Called with the lock held.
    private func takeReadyWaiters() -> [CheckedContinuation<Bool, Never>] {
        let ready = waiters.filter { sleepers.count >= $0.count }.map(\.continuation)
        waiters.removeAll { sleepers.count >= $0.count }
        return ready
    }
}
