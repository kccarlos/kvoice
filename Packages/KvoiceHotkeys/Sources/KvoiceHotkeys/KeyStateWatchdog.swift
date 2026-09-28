import Foundation

/// The reason a push-to-talk hold was ended without receiving the matching
/// shortcut key-up event.
public enum KeyStateWatchdogStopReason: String, Equatable, Sendable {
    case applicationDeactivated
    case displaySleep
    case maximumDuration
    case termination
    case shortcutRebound
}

/// Bounds the lifetime of a physical shortcut hold.
///
/// Keyboard event delivery is not guaranteed across sleep, application
/// deactivation, or shortcut re-registration.  The watchdog is deliberately
/// independent of audio: its only job is to tell the owner to synthesize the
/// matching semantic key-up event.  This keeps a lost hardware event from
/// turning into an indefinitely running recording.
@MainActor
public final class KeyStateWatchdog {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// Read when the watchdog arms, so a change applies to the next hold.
    /// Settable because the recording ceiling is a user setting now.
    public var maximumDuration: Duration {
        didSet {
            if maximumDuration <= .zero {
                maximumDuration = oldValue
            }
        }
    }
    public private(set) var isArmed = false

    private let sleep: Sleep
    public var onForcedStop: @MainActor (KeyStateWatchdogStopReason) -> Void
    private var task: Task<Void, Never>?
    private var generation = 0

    /// The production sleep, shared by every timer in this package.
    ///
    /// A named nonisolated function, never a closure literal in a default
    /// argument: on the Swift 6.3 toolchain the `KeyboardShortcutsAdapter`
    /// init's default `{ duration in try await Task.sleep(for: duration) }`
    /// aborted the test process in `swift_task_dealloc` ("freed pointer was
    /// not the last allocation") the moment `disarm()` cancelled it, while the
    /// same body injected explicitly did not (SE-0411 gives a default-value
    /// closure the callee's main-actor isolation, and the `@Sendable` sleep
    /// type says otherwise). `HotkeySemanticsTests` covers the cancel path.
    public nonisolated static func systemSleep(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    public init(
        maximumDuration: Duration = .seconds(600),
        sleep: @escaping Sleep = KeyStateWatchdog.systemSleep,
        onForcedStop: @escaping @MainActor (KeyStateWatchdogStopReason) -> Void
            = { _ in }
    ) {
        precondition(maximumDuration > .zero, "The watchdog duration must be positive")
        self.maximumDuration = maximumDuration
        self.sleep = sleep
        self.onForcedStop = onForcedStop
    }

    deinit {
        task?.cancel()
    }

    /// Arms (or rearms) the watchdog for a newly observed semantic key-down.
    public func arm() {
        generation += 1
        task?.cancel()
        isArmed = true

        let generation = generation
        let sleep = sleep
        let maximumDuration = maximumDuration
        // The sleep runs detached from the actor and the result is applied
        // by an explicit hop, so a slow or cancelled sleep never occupies the
        // main actor. See `systemSleep` for why the default sleep is a named
        // function.
        task = Task.detached { [weak self] in
            do {
                try await sleep(maximumDuration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.forceStopIfCurrent(
                    generation: generation,
                    reason: .maximumDuration
                )
            }
        }
    }

    /// Disarms the watchdog after the expected key-up arrives.
    public func keyUpReceived() {
        disarm()
    }

    /// Disarms without notifying the owner.  This is used when a job is
    /// cancelled or a shortcut is explicitly unregistered.
    public func disarm() {
        generation += 1
        task?.cancel()
        task = nil
        isArmed = false
    }

    /// App deactivation is an input-delivery boundary.  Stop immediately so a
    /// recording cannot survive a focus transition with no key-up.
    public func applicationDidResignActive() {
        forceStop(.applicationDeactivated)
    }

    /// Display sleep can drop Carbon key-up events, so it follows the same
    /// bounded-stop policy as app deactivation.
    public func displayWillSleep() {
        forceStop(.displaySleep)
    }

    /// Termination cleanup is observable by the owner but does not wait for a
    /// timer or attempt to emit any additional keyboard data.
    public func applicationWillTerminate() {
        forceStop(.termination)
    }

    /// Rebinding a shortcut invalidates the old physical hold.
    public func shortcutRebound() {
        forceStop(.shortcutRebound)
    }

    private func forceStop(_ reason: KeyStateWatchdogStopReason) {
        guard isArmed else { return }
        disarm()
        onForcedStop(reason)
    }

    private func forceStopIfCurrent(
        generation: Int,
        reason: KeyStateWatchdogStopReason
    ) {
        guard self.generation == generation, isArmed else { return }
        forceStop(reason)
    }
}
