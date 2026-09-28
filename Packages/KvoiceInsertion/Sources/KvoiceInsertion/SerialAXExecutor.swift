import Foundation
import KvoiceDomain

/// A single queue for all native Accessibility messages.
///
/// AXUIElement messaging is synchronous IPC.  Keeping every operation on one
/// private serial queue makes ordering deterministic and prevents two
/// concurrent insertion attempts from interleaving reads and writes.  The
/// timeout races the queue operation from a separate task sleeping on the
/// injected `KvoiceClock` (production: `SystemKvoiceClock`, the continuous
/// clock; tests: a clock they advance by hand, so a timeout fires when the
/// test says and never because the machine was slow).  Native AX calls also
/// receive the same bound in `NativeAXElementClient`.
public final class SerialAXExecutor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let timeoutNanoseconds: UInt64
    private let clock: any KvoiceClock

    public init(
        label: String = "io.github.kccarlos.kvoice.accessibility",
        timeout: Duration = .seconds(1),
        clock: any KvoiceClock = SystemKvoiceClock()
    ) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        timeoutNanoseconds = Self.nanoseconds(for: timeout)
        self.clock = clock
    }

    public var timeout: Duration {
        .nanoseconds(Int64(min(timeoutNanoseconds, UInt64(Int64.max))))
    }

    /// Runs one operation and returns a bounded timeout even when an injected
    /// adapter is stuck.  A native AX message is separately bounded by the
    /// messaging timeout configured by `NativeAXElementClient`.
    public func run<T: Sendable>(
        gate: AXOperationGate? = nil,
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let state = InvocationState<T>()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)

                let workItem = DispatchWorkItem {
                    guard !state.isFinished else { return }
                    do {
                        state.finish(.success(try operation()))
                    } catch {
                        state.finish(.failure(error))
                    }
                }
                state.install(workItem)
                queue.async(execute: workItem)

                // Do not put the timer on the AX queue: a blocked native
                // message must not prevent the timeout from being delivered.
                // The timer is a detached task, so it runs on the concurrency
                // pool whatever the AX queue is doing.
                let clock = self.clock
                let timeout = self.timeout
                let timeoutTask = Task.detached(priority: .utility) {
                    do {
                        try await clock.sleep(for: timeout)
                    } catch {
                        // Cancelled: the invocation finished first.
                        return
                    }
                    // Invalidate before publishing timeout.  The operation may
                    // remain on the serial queue after this caller returns,
                    // but every later mutation attempt will now be rejected.
                    _ = state.finishIfUnfinished(.failure(AXExecutionError.timeout)) {
                        gate?.invalidateForTimeout()
                    }
                }
                state.installTimeout(timeoutTask)
            }
        }, onCancel: {
            // Cancellation has the same fence semantics as timeout: a
            // blocked synchronous AX call is not forcefully interruptible.
            _ = state.finishIfUnfinished(.failure(CancellationError())) {
                gate?.invalidateForCancellation()
            }
            state.cancelWorkItem()
        })
    }

    /// Retries only the native `cannotComplete` result, and only once.  A
    /// timeout or any other AX error is never retried.  Once a mutation has
    /// started, retrying could apply the same insertion twice, so the gate
    /// also makes that boundary explicit.
    public func runWithCannotCompleteRetry<T: Sendable>(
        gate: AXOperationGate? = nil,
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        do {
            return try await run(gate: gate, operation)
        } catch AXClientError.cannotComplete {
            guard gate?.isMutationStarted != true else {
                throw AXClientError.cannotComplete
            }
            return try await run(gate: gate, operation)
        }
    }

    private static func nanoseconds(for duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let attoseconds = max(0, components.attoseconds)
        let nanosFromSeconds = seconds > UInt64.max / 1_000_000_000
            ? UInt64.max
            : seconds * 1_000_000_000
        let nanosFromAttoseconds = UInt64(attoseconds / 1_000_000_000)
        return min(UInt64.max, nanosFromSeconds &+ nanosFromAttoseconds)
    }

}

private final class InvocationState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var workItem: DispatchWorkItem?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
    }

    func install(_ workItem: DispatchWorkItem) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else {
            workItem.cancel()
            return
        }
        self.workItem = workItem
    }

    func installTimeout(_ timeoutTask: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else {
            timeoutTask.cancel()
            return
        }
        self.timeoutTask = timeoutTask
    }

    func cancelWorkItem() {
        lock.lock()
        let workItem = self.workItem
        lock.unlock()
        workItem?.cancel()
    }

    @discardableResult
    func finishIfUnfinished(
        _ result: Result<Value, Error>,
        beforeFinish: (() -> Void)? = nil
    ) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        // The callback runs while the invocation lock is held. Timeout and
        // cancellation therefore invalidate the mutation gate in the same
        // winner-critical section as `finished = true`; a late timer cannot
        // poison a completed retry, and a work item cannot claim a mutation
        // in the gap between timeout publication and gate invalidation.
        beforeFinish?()
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let workItem = self.workItem
        self.workItem = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        workItem?.cancel()
        timeoutTask?.cancel()

        switch result {
        case .success(let value): continuation?.resume(returning: value)
        case .failure(let error): continuation?.resume(throwing: error)
        }
        return true
    }

    func finish(_ result: Result<Value, Error>) {
        _ = finishIfUnfinished(result)
    }
}
