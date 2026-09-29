import Foundation
import XCTest

/// Awaits `task` with a hang guard: a timer task that a `ParkingClock`
/// advance should have finished, but did not (a dropped `cancel()`, a
/// deadline that moved), fails with `message` after `timeout` of real time
/// instead of hanging the suite. A passing wait returns as soon as the
/// task does; the 30 s bound is never reached on a pass, the same shape as
/// `ParkingClock.waitForSleepers`.
public func awaitTask(
    _ task: Task<Void, Never>,
    within timeout: Duration = .seconds(30),
    _ message: String = "the task never finished",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    if await !taskFinishes(task, within: timeout) {
        XCTFail("\(message) (waited \(timeout))", file: file, line: line)
    }
}

/// The race behind `awaitTask`: true when `task` finishes, false when
/// `timeout` of real time passes first. Split out so the guard's own test
/// can check the timeout path without recording a failure.
public func taskFinishes(_ task: Task<Void, Never>, within timeout: Duration) async -> Bool {
    let outcome = ResumeOnce()
    let hangGuard = Task {
        do { try await Task.sleep(for: timeout) } catch { return }
        outcome.resume(false)
    }
    Task {
        await task.value
        outcome.resume(true)
    }
    let finished = await withCheckedContinuation { outcome.install($0) }
    hangGuard.cancel()
    return finished
}

/// Resumes one continuation exactly once with the first result offered,
/// whether that result arrives before or after the continuation is installed.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    private var resumed = false

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let result {
            resumed = true
            lock.unlock()
            continuation.resume(returning: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: Bool) {
        lock.lock()
        guard !resumed, result == nil else {
            lock.unlock()
            return
        }
        guard let continuation else {
            result = value
            lock.unlock()
            return
        }
        resumed = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}
