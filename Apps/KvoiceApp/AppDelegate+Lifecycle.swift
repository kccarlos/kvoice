import AppKit
import KvoiceAppCore
import KvoiceDomain

/// The two halves of the restart handshake (2026-09-16), see
/// `TerminationHandshake` and `InstanceHandoff` in `KvoiceAppCore` for the
/// reasoning; this file is only the AppKit lookup and the diagnostics lines.
///
/// `restartApp()` (`AppDelegate+Settings.swift`) launches the new instance
/// first — with `--replaces-pid <this pid>` — and terminates this one
/// second, so for a moment two instances of the bundle run. The old one
/// bounds its quit to about 3 s and replies "terminate" either way; the new
/// one waits up to about 5 s for *that* process to exit before it registers
/// the global hotkey, and terminates it if it does not. A launch without
/// the argument waits for other instances but never terminates them.
/// `NSRunningApplication` already has the seam's four members (`pid_t` is
/// `Int32`); nothing about it leaves this file.
extension NSRunningApplication: @retroactive RunningInstance {}

extension AppDelegate {
    struct WorkspaceRunningInstanceLookup: RunningInstanceLookup {
        func otherInstances() -> [any RunningInstance] {
            guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return [] }
            let current = ProcessInfo.processInfo.processIdentifier
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { $0.processIdentifier != current }
        }
    }

    /// The launch-side handoff. Runs `continueLaunching` synchronously when
    /// no other instance exists (the normal launch, unchanged), otherwise
    /// after `InstanceHandoff.run()` has waited the old instance out.
    func performInstanceHandoff(then continueLaunching: @escaping @MainActor () -> Void) {
        let handoff = InstanceHandoff(
            lookup: WorkspaceRunningInstanceLookup(),
            // Set by `restartApp()`; absent on any other launch, in which
            // case the handoff waits but terminates nothing.
            replacesProcessIdentifier: InstanceHandoff.replacedProcessIdentifier(in: CommandLine.arguments)
        )
        guard handoff.isAnotherInstanceRunning else {
            continueLaunching()
            return
        }
        Task { @MainActor [weak self] in
            let outcome = await handoff.run()
            guard let self else { return }
            self.recordInstanceHandoff(outcome)
            continueLaunching()
        }
    }

    /// `app.instanceHandoff.completed`: scalars only — how long, how many,
    /// and how they went away (`Outcome.reason`).
    func recordInstanceHandoff(_ outcome: InstanceHandoff.Outcome) {
        let result: DiagnosticResult = if outcome.remaining > 0 {
            .failure
        } else if outcome.terminateRequested {
            .warning
        } else {
            .success
        }
        let event = DiagnosticEvent(
            name: .appInstanceHandoffCompleted,
            result: result,
            durationMilliseconds: outcome.waited.milliseconds,
            attributes: DiagnosticAttributes(reason: outcome.reason, instanceCount: outcome.instanceCount)
        )
        let diagnostics = composition.diagnostics
        Task { await diagnostics.log(event) }
    }

    /// `app.terminate.completed` / `app.terminate.timedOut`: the latter names
    /// the stalled step in `site` so the log says what hung. Built here,
    /// logged by `applicationShouldTerminate` — awaited (the process exits
    /// right after the reply, so a detached log task would be lost with it)
    /// but under its own short deadline, so a stuck logger cannot withhold
    /// the reply either.
    nonisolated static func terminationEvent(_ outcome: TerminationHandshake.Outcome) -> DiagnosticEvent {
        switch outcome {
        case let .completed(duration):
            DiagnosticEvent(
                name: .appTerminateCompleted,
                result: .success,
                durationMilliseconds: duration.milliseconds
            )
        case let .timedOut(step, duration):
            DiagnosticEvent(
                name: .appTerminateTimedOut,
                result: .warning,
                durationMilliseconds: duration.milliseconds,
                attributes: DiagnosticAttributes(site: step)
            )
        }
    }
}

private extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
