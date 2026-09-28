import Foundation
import KvoiceDomain

/// The bounded half of `applicationShouldTerminate` (2026-09-16).
///
/// The shell replies `.terminateLater` and runs a few asynchronous shutdown
/// steps (cancel the dictation, cancel a model install, unload the engine)
/// before `NSApp.reply(toApplicationShouldTerminate:)`. Until this type
/// existed those awaits were unbounded: a stalled step meant the process
/// never exited, kept its global hotkey, and — after Help › Restart or the
/// language change's "Relaunch Now", which launch the new instance *before*
/// terminating this one — the user saw two KVoice instances. Nothing in
/// the diagnostics said which step had stalled.
///
/// `run` executes the steps in order and races them against `deadline` on
/// the injected clock. Either way it returns, so the caller always replies
/// `true`; the outcome names the step that was running when the deadline
/// fired so the log can say what stalled. A step that never completes is
/// left to die with the process — cancelling it is attempted, waiting for
/// it is not, because a step that ignores cancellation is exactly the case
/// this exists for.
public struct TerminationHandshake: Sendable {
    /// One awaited shutdown step. `name` is a bounded diagnostic token
    /// (`DiagnosticToken` rules: ASCII letters, digits, `.`, `_`, `:`, `-`),
    /// never free text.
    public struct Step: Sendable {
        public let name: String
        public let run: @Sendable () async -> Void

        public init(_ name: String, run: @escaping @Sendable () async -> Void) {
            self.name = name
            self.run = run
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Every step returned before the deadline.
        case completed(duration: Duration)
        /// The deadline fired while `step` was still running.
        case timedOut(step: String, duration: Duration)

        public var duration: Duration {
            switch self {
            case let .completed(duration), let .timedOut(_, duration):
                duration
            }
        }
    }

    public let deadline: Duration
    private let clock: any KvoiceClock

    /// About 3 s in production: long enough for a cancelled capture and an
    /// engine unload on a busy machine, short enough that the relaunched
    /// instance (which waits up to `InstanceHandoff.waitFor` for this one)
    /// always outlasts it.
    public init(deadline: Duration = .seconds(3), clock: any KvoiceClock = SystemKvoiceClock()) {
        self.deadline = deadline
        self.clock = clock
    }

    public func run(_ steps: [Step]) async -> Outcome {
        let started = clock.now
        let current = CurrentStep()
        let race = Race()

        let work = Task {
            for step in steps {
                if Task.isCancelled { return }
                current.set(step.name)
                await step.run()
            }
            race.finish(.completed(duration: clock.now - started))
        }
        let timer = Task {
            try? await clock.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            race.finish(.timedOut(step: current.get(), duration: clock.now - started))
        }

        let outcome = await race.outcome()
        work.cancel()
        timer.cancel()
        return outcome
    }

    /// The name of the step being awaited, read by the timer when it fires.
    private final class CurrentStep: @unchecked Sendable {
        private let lock = NSLock()
        private var name = "none"

        func set(_ name: String) {
            lock.lock()
            self.name = name
            lock.unlock()
        }

        func get() -> String {
            lock.lock()
            defer { lock.unlock() }
            return name
        }
    }

    /// First finisher wins; the second `finish` is ignored. A continuation
    /// rather than a task group because a group would wait for the stalled
    /// step's child to end, which is the hang this type exists to bound.
    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Outcome?
        private var continuation: CheckedContinuation<Outcome, Never>?

        func finish(_ outcome: Outcome) {
            lock.lock()
            guard result == nil else {
                lock.unlock()
                return
            }
            result = outcome
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: outcome)
        }

        func outcome() async -> Outcome {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
