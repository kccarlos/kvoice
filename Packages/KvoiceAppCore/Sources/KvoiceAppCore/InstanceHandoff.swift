import Foundation
import KvoiceDomain

/// Another running process of this bundle, as the shell sees it through
/// `NSRunningApplication` (the AppKit lookup stays in the shell; this is
/// the seam the tests drive with a fake).
public protocol RunningInstance: AnyObject {
    var processIdentifier: Int32 { get }
    var isTerminated: Bool { get }
    /// Asks the instance to quit (`NSRunningApplication.terminate()`);
    /// returns whether the request was delivered.
    @discardableResult func terminate() -> Bool
    /// Kills the instance (`NSRunningApplication.forceTerminate()`);
    /// returns whether the request was delivered.
    @discardableResult func forceTerminate() -> Bool
}

public protocol RunningInstanceLookup {
    /// Every running instance of this bundle other than the current process.
    @MainActor func otherInstances() -> [any RunningInstance]
}

/// The launch-side half of the restart handshake (2026-09-16).
///
/// Help › Restart and the language change's "Relaunch Now" launch a second
/// instance of this bundle and *then* terminate the current one, so two
/// instances briefly coexist by design (`Info.plist` deliberately has no
/// `LSMultipleInstancesProhibited`; adding one would make the restart fail
/// to launch). The new instance must not register the global hotkey while
/// the old one still holds it, and if the old one stalls on the way out
/// (`TerminationHandshake` bounds that, but a hard hang can still ignore
/// it) the user ends up with two KVoice menu-bar items, which happened.
///
/// `run` waits up to `waitFor` for the other instance to exit on its own,
/// then — because a restart is an explicit user intent, so removing the
/// old process is what the user asked for — sends `terminate()`, waits a
/// further `terminateGrace`, and finally `forceTerminate()`. The shell calls
/// it before the part of `applicationDidFinishLaunching` that registers the
/// hotkey, and only when the lookup reports another instance (a normal
/// launch pays nothing). The loop is bounded by a poll count, not by the
/// clock's reading, so a test clock whose `sleep` returns at once still
/// terminates it.
///
/// **Only the process the restart names may be terminated** (2026-09-16
/// review). `restartApp()` launches the new instance with
/// `--replaces-pid <pid>`; the handoff then waits on and, if it must,
/// terminates that one process and no other. Without the argument — a
/// Bench or DerivedData build launched beside the installed app (they share
/// the bundle id), or two instances launched by hand — the handoff still
/// waits `waitFor` for the others to leave but never terminates anything,
/// and reports `stillRunning` if they did not: killing every process with
/// the bundle id would have quit the installed app five seconds after a
/// test build started, and two launches would have killed each other.
@MainActor
public struct InstanceHandoff {
    /// The launch argument `restartApp()` passes, followed by the PID of the
    /// instance being replaced.
    public static let replacesProcessArgument = "--replaces-pid"

    /// The PID after `--replaces-pid` in `arguments`, or nil when the launch
    /// did not come from a restart (or the value is not a PID).
    public static func replacedProcessIdentifier(in arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(of: replacesProcessArgument),
              arguments.indices.contains(index + 1)
        else { return nil }
        return Int32(arguments[index + 1])
    }

    public struct Outcome: Equatable, Sendable {
        /// How many other instances were found at the start.
        public var instanceCount: Int
        /// Wall time on the injected clock from the first poll to the return.
        public var waited: Duration
        /// `terminate()` had to be sent (the instances did not exit within `waitFor`).
        public var terminateRequested: Bool
        /// `forceTerminate()` had to be sent (an instance survived `terminate()`).
        public var forceTerminateRequested: Bool
        /// Instances still alive when `run` returned; 0 unless even `forceTerminate` failed.
        public var remaining: Int

        public init(
            instanceCount: Int,
            waited: Duration,
            terminateRequested: Bool,
            forceTerminateRequested: Bool,
            remaining: Int
        ) {
            self.instanceCount = instanceCount
            self.waited = waited
            self.terminateRequested = terminateRequested
            self.forceTerminateRequested = forceTerminateRequested
            self.remaining = remaining
        }

        /// The bounded token the diagnostics line carries as `reason`.
        public var reason: String {
            if remaining > 0 { return "stillRunning" }
            if forceTerminateRequested { return "forceTerminated" }
            if terminateRequested { return "terminated" }
            return "exited"
        }
    }

    private let lookup: any RunningInstanceLookup
    private let clock: any KvoiceClock
    /// The one process this launch replaces; nil means "wait, never
    /// terminate".
    public let replacesProcessIdentifier: Int32?
    public let waitFor: Duration
    public let terminateGrace: Duration
    public let pollInterval: Duration

    /// `waitFor` (about 5 s) must exceed `TerminationHandshake.deadline`
    /// (about 3 s) so a slow-but-healthy old instance is never killed
    /// mid-shutdown; `terminateGrace` is the further wait after
    /// `terminate()` before `forceTerminate()`.
    public init(
        lookup: any RunningInstanceLookup,
        replacesProcessIdentifier: Int32? = nil,
        clock: any KvoiceClock = SystemKvoiceClock(),
        waitFor: Duration = .seconds(5),
        terminateGrace: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(100)
    ) {
        self.lookup = lookup
        self.replacesProcessIdentifier = replacesProcessIdentifier
        self.clock = clock
        self.waitFor = waitFor
        self.terminateGrace = terminateGrace
        self.pollInterval = pollInterval
    }

    /// True when an instance this launch must wait for is running right
    /// now; the shell's cheap synchronous check that decides whether `run`
    /// is needed at all.
    public var isAnotherInstanceRunning: Bool {
        !candidates().isEmpty
    }

    /// The live instances this launch waits on: the one named by
    /// `--replaces-pid` when the launch is a restart, otherwise every other
    /// instance of the bundle.
    private func candidates() -> [any RunningInstance] {
        let others = lookup.otherInstances().filter { !$0.isTerminated }
        guard let replacesProcessIdentifier else { return others }
        return others.filter { $0.processIdentifier == replacesProcessIdentifier }
    }

    public func run() async -> Outcome {
        let started = clock.now
        let instances = candidates()
        var outcome = Outcome(
            instanceCount: instances.count,
            waited: .zero,
            terminateRequested: false,
            forceTerminateRequested: false,
            remaining: 0
        )
        guard !instances.isEmpty else { return outcome }

        if await waitUntilTerminated(instances, for: waitFor) {
            outcome.waited = clock.now - started
            return outcome
        }
        guard replacesProcessIdentifier != nil else {
            // Not a restart: nothing here is ours to remove. Report and
            // carry on; the hotkey may be contested.
            outcome.remaining = instances.filter { !$0.isTerminated }.count
            outcome.waited = clock.now - started
            return outcome
        }

        outcome.terminateRequested = true
        for instance in instances where !instance.isTerminated {
            instance.terminate()
        }
        if await waitUntilTerminated(instances, for: terminateGrace) {
            outcome.waited = clock.now - started
            return outcome
        }

        outcome.forceTerminateRequested = true
        for instance in instances where !instance.isTerminated {
            instance.forceTerminate()
        }
        // One last short wait so `isTerminated` can observe the kill.
        _ = await waitUntilTerminated(instances, for: terminateGrace)
        outcome.remaining = instances.filter { !$0.isTerminated }.count
        outcome.waited = clock.now - started
        return outcome
    }

    /// Polls `isTerminated` up to `duration / pollInterval` times (at least
    /// once), sleeping `pollInterval` after each miss; true once every
    /// instance is gone.
    private func waitUntilTerminated(_ instances: [any RunningInstance], for duration: Duration) async -> Bool {
        let polls = max(1, Int(duration / pollInterval))
        for _ in 0..<polls {
            if instances.allSatisfy(\.isTerminated) { return true }
            try? await clock.sleep(for: pollInterval)
        }
        return instances.allSatisfy(\.isTerminated)
    }
}
