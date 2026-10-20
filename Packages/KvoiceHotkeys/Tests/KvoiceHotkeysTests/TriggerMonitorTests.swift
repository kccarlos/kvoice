import AppKit
import KeyboardShortcuts
import XCTest
@testable import KvoiceDomain
@testable import KvoiceHotkeys

/// The advanced triggers (product decision #5): a lone modifier key through
/// `flagsChanged`, the middle mouse button with its activation delay, the
/// secondary cancel/append registrations, and the Hybrid edge reducer.
@MainActor
final class TriggerMonitorTests: XCTestCase {
    // MARK: Modifier-only keys

    func testModifierKeyEdgeDetectorUsesTheDeviceBitOfTheNamedKey() {
        let rightOptionDown = NSEvent.ModifierFlags.option.rawValue | 0x40
        XCTAssertEqual(ModifierKeyEdgeDetector.edge(keyCode: 61, modifierFlags: rightOptionDown, for: .rightOption), .keyDown)
        XCTAssertEqual(ModifierKeyEdgeDetector.edge(keyCode: 61, modifierFlags: NSEvent.ModifierFlags.option.rawValue, for: .rightOption), .keyUp,
                       "left Option still held, right Option released")
        XCTAssertNil(ModifierKeyEdgeDetector.edge(keyCode: 58, modifierFlags: rightOptionDown, for: .rightOption), "left Option is a different key")
        XCTAssertEqual(ModifierKeyEdgeDetector.edge(keyCode: 63, modifierFlags: NSEvent.ModifierFlags.function.rawValue, for: .fn), .keyDown)
        XCTAssertEqual(ModifierKeyEdgeDetector.keyCode(for: .rightCommand), 54)
    }

    func testModifierOnlyMonitorRefusesWithoutAccessibilityAndReportsBalancedEdges() throws {
        let untrusted = FakeInputMonitorFactory(trusted: false)
        let refused = ModifierOnlyShortcutMonitor(factory: untrusted)
        XCTAssertThrowsError(try refused.start(key: .rightOption, onKeyDown: {}, onKeyUp: {})) { error in
            XCTAssertEqual(error as? HotkeyAdapterError, .accessibilityRequired)
        }
        XCTAssertEqual(untrusted.installed, 0)

        let factory = FakeInputMonitorFactory(trusted: true)
        let monitor = ModifierOnlyShortcutMonitor(factory: factory)
        var edges: [ShortcutEvent] = []
        try monitor.start(key: .rightOption, onKeyDown: { edges.append(.keyDown) }, onKeyUp: { edges.append(.keyUp) })
        XCTAssertTrue(monitor.isActive)
        XCTAssertEqual(factory.installed, 2, "one local and one global flagsChanged monitor")

        let down = NSEvent.ModifierFlags.option.rawValue | 0x40
        monitor.handle(keyCode: 61, modifierFlags: down)
        monitor.handle(keyCode: 58, modifierFlags: down)
        monitor.handle(keyCode: 61, modifierFlags: 0)
        monitor.handle(keyCode: 61, modifierFlags: 0)
        XCTAssertEqual(edges, [.keyDown, .keyUp], "an unmatched release is dropped")

        monitor.stop()
        XCTAssertFalse(monitor.isActive)
        XCTAssertEqual(factory.removed, 2)
    }

    func testAdapterRegistersAModifierOnlyKeyThroughTheMonitorNotCarbon() throws {
        let backend = FakeRegistrationBackend()
        let factory = FakeInputMonitorFactory(trusted: true)
        let adapter = KeyboardShortcutsAdapter(
            backend: backend,
            maximumHoldDuration: .seconds(60),
            sleep: { _ in },
            inputMonitorFactory: factory
        )
        var events: [ShortcutEvent] = []
        try adapter.register(.rightOption) { events.append($0) }
        XCTAssertEqual(adapter.registrationState, .registered(.rightOption))
        XCTAssertNil(backend.registeredShortcut, "Carbon cannot register a lone modifier")
        XCTAssertEqual(factory.installed, 2)

        // The real monitor hands the adapter an NSEvent; drive it the same way.
        let flags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)
        factory.emitFlagsChanged(keyCode: 61, modifierFlags: flags)
        factory.emitFlagsChanged(keyCode: 61, modifierFlags: [])
        XCTAssertEqual(events, [.keyDown, .keyUp])

        // Switching back to a combination tears the monitor down and uses Carbon.
        let combination = ShortcutDefinition(key: "space", modifiers: ["control"])
        try adapter.register(combination) { _ in }
        XCTAssertEqual(factory.removed, 2)
        XCTAssertEqual(backend.registeredShortcut, try combination.asKeyboardShortcut())
    }

    // MARK: Lost releases (0.1.5 demo, 2026-10-20)

    private static let rightOptionHeld = NSEvent.ModifierFlags.option.rawValue | 0x40

    func testASecondPressAfterALostReleaseIsNotSwallowed() throws {
        let monitor = ModifierOnlyShortcutMonitor(factory: FakeInputMonitorFactory(trusted: true), sleep: ManualSleeper().sleep)
        var edges: [ShortcutEvent] = []
        try monitor.start(key: .rightOption, onKeyDown: { edges.append(.keyDown) }, onKeyUp: { edges.append(.keyUp) })

        monitor.handle(keyCode: 61, modifierFlags: Self.rightOptionHeld)
        // The release never arrives. Before the fix this press was dropped,
        // so a toggle recording could not be stopped and the key seemed dead.
        monitor.handle(keyCode: 61, modifierFlags: Self.rightOptionHeld)
        XCTAssertEqual(edges, [.keyDown, .keyUp, .keyDown])
        monitor.handle(keyCode: 61, modifierFlags: 0)
        XCTAssertEqual(edges, [.keyDown, .keyUp, .keyDown, .keyUp])
        monitor.stop()
    }

    func testAnotherModifierWhoseFlagsProveTheKeyIsUpEndsTheHold() throws {
        let factory = FakeInputMonitorFactory(trusted: true)
        let monitor = ModifierOnlyShortcutMonitor(factory: factory, sleep: ManualSleeper().sleep)
        var edges: [ShortcutEvent] = []
        try monitor.start(key: .rightOption, onKeyDown: { edges.append(.keyDown) }, onKeyUp: { edges.append(.keyUp) })

        // Left Option (58) going down while Right Option is held: still held.
        monitor.handle(keyCode: 61, modifierFlags: Self.rightOptionHeld)
        monitor.handle(keyCode: 58, modifierFlags: Self.rightOptionHeld | 0x20)
        XCTAssertEqual(edges, [.keyDown])
        // Right Option's release is lost while Left Option stays down: the
        // next event's flags still carry `.option`, which is not proof.
        monitor.handle(keyCode: 58, modifierFlags: NSEvent.ModifierFlags.option.rawValue | 0x20)
        XCTAssertEqual(edges, [.keyDown], "Left Option held alone is not proof Right Option is up")
        // Shift pressed with no Option at all, and the system agrees: proof.
        factory.currentModifierFlags = NSEvent.ModifierFlags.shift.rawValue
        monitor.handle(keyCode: 56, modifierFlags: NSEvent.ModifierFlags.shift.rawValue | 0x02)
        XCTAssertEqual(edges, [.keyDown, .keyUp])
        XCTAssertFalse(monitor.isDown)
        monitor.stop()
    }

    func testClearedFlagsOnAnotherModifierDoNotEndAHoldTheSystemStillSees() throws {
        let factory = FakeInputMonitorFactory(trusted: true)
        let monitor = ModifierOnlyShortcutMonitor(factory: factory, sleep: ManualSleeper().sleep)
        var edges: [ShortcutEvent] = []
        try monitor.start(key: .rightOption, onKeyDown: { edges.append(.keyDown) }, onKeyUp: { edges.append(.keyUp) })

        monitor.handle(keyCode: 61, modifierFlags: Self.rightOptionHeld)
        // A remapper or remote session posts a Shift event with no Option,
        // while the window server still reports Option down.
        factory.currentModifierFlags = NSEvent.ModifierFlags.option.rawValue
        monitor.handle(keyCode: 56, modifierFlags: NSEvent.ModifierFlags.shift.rawValue | 0x02)
        XCTAssertEqual(edges, [.keyDown], "the event alone is not proof")
        XCTAssertTrue(monitor.isDown)

        // When the system agrees the key is up, the same event ends the hold.
        factory.currentModifierFlags = NSEvent.ModifierFlags.shift.rawValue
        monitor.handle(keyCode: 56, modifierFlags: NSEvent.ModifierFlags.shift.rawValue | 0x02)
        XCTAssertEqual(edges, [.keyDown, .keyUp])
        monitor.stop()
    }

    func testAWatchdogStopAlsoForgetsAnAuxiliaryModifierHold() throws {
        let factory = FakeInputMonitorFactory(trusted: true)
        let primary = FakeRegistrationBackend()
        let adapter = KeyboardShortcutsAdapter(
            backend: primary,
            maximumHoldDuration: .seconds(60),
            sleep: ManualSleeper().sleep,
            inputMonitorFactory: factory,
            modifierReleasePollSleep: ManualSleeper().sleep
        )
        try adapter.register(ShortcutDefinition(key: "space", modifiers: ["control"])) { _ in }
        var cancelEdges: [ShortcutEvent] = []
        try adapter.registerAuxiliaryShortcut(.cancel, .rightOption) { cancelEdges.append($0) }
        let held = NSEvent.ModifierFlags(rawValue: Self.rightOptionHeld)

        primary.emitKeyDown()
        factory.emitFlagsChanged(keyCode: 61, modifierFlags: held)
        XCTAssertEqual(cancelEdges, [.keyDown])
        // The watchdog ends the primary hold; the auxiliary hold is
        // forgotten too, without a synthetic release.
        adapter.applicationDidResignActive()
        XCTAssertEqual(cancelEdges, [.keyDown])
        // Its real release is then unmatched, and the next press counts.
        factory.emitFlagsChanged(keyCode: 61, modifierFlags: [])
        factory.emitFlagsChanged(keyCode: 61, modifierFlags: held)
        XCTAssertEqual(cancelEdges, [.keyDown, .keyDown])
        adapter.unregisterAuxiliaryShortcut(.cancel)
        XCTAssertEqual(cancelEdges, [.keyDown, .keyDown, .keyUp], "tear-down still reports a held key's release")
        adapter.unregister()
    }

    func testTheReleasePollEndsAHoldWhoseReleaseWasLost() async throws {
        let factory = FakeInputMonitorFactory(trusted: true)
        let clock = ManualSleeper()
        let monitor = ModifierOnlyShortcutMonitor(factory: factory, sleep: clock.sleep)
        var edges: [ShortcutEvent] = []
        try monitor.start(key: .rightOption, onKeyDown: { edges.append(.keyDown) }, onKeyUp: { edges.append(.keyUp) })

        factory.currentModifierFlags = NSEvent.ModifierFlags.option.rawValue
        monitor.handle(keyCode: 61, modifierFlags: Self.rightOptionHeld)
        await settle(until: { clock.parked == 1 })
        XCTAssertEqual(clock.lastDuration, ModifierOnlyShortcutMonitor.releasePollInterval)
        // Held: `NSEvent.modifierFlags` carries `.option` but no device bit.
        for _ in 0..<3 {
            await tick(clock)
        }
        XCTAssertEqual(edges, [.keyDown], "a held key is never released by the poll")

        // The key is up but its flagsChanged was lost.
        factory.currentModifierFlags = 0
        await tick(clock)
        XCTAssertEqual(edges, [.keyDown], "one reading is not enough")
        clock.resumeAll()
        await settle(until: { !monitor.isDown })
        XCTAssertEqual(edges, [.keyDown, .keyUp])
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(clock.parked, 0, "the poll ends with the hold")

        // The next press works.
        monitor.handle(keyCode: 61, modifierFlags: Self.rightOptionHeld)
        XCTAssertEqual(edges, [.keyDown, .keyUp, .keyDown])
        monitor.stop()
    }

    func testAPollReadingThatSeesTheKeyAgainResetsTheCount() async throws {
        let factory = FakeInputMonitorFactory(trusted: true)
        let clock = ManualSleeper()
        let monitor = ModifierOnlyShortcutMonitor(factory: factory, sleep: clock.sleep)
        var edges: [ShortcutEvent] = []
        try monitor.start(key: .rightOption, onKeyDown: { edges.append(.keyDown) }, onKeyUp: { edges.append(.keyUp) })
        monitor.handle(keyCode: 61, modifierFlags: Self.rightOptionHeld)
        await settle(until: { clock.parked == 1 })

        for flags in [0, NSEvent.ModifierFlags.option.rawValue, 0, NSEvent.ModifierFlags.option.rawValue] {
            factory.currentModifierFlags = flags
            await tick(clock)
        }
        XCTAssertEqual(edges, [.keyDown], "only two readings in a row count")

        // A real release cancels the poll.
        monitor.handle(keyCode: 61, modifierFlags: 0)
        XCTAssertEqual(edges, [.keyDown, .keyUp])
        await settle(until: { clock.parked == 0 })
        monitor.stop()
    }

    /// One poll period: wake the parked sleeper and wait until it reads and
    /// parks again.
    private func tick(_ clock: ManualSleeper, file: StaticString = #filePath, line: UInt = #line) async {
        clock.resumeAll()
        await settle(until: { clock.parked == 1 }, file: file, line: line)
    }

    func testAWatchdogStopDoesNotLeaveTheModifierKeyDead() throws {
        let factory = FakeInputMonitorFactory(trusted: true)
        let adapter = KeyboardShortcutsAdapter(
            backend: FakeRegistrationBackend(),
            maximumHoldDuration: .seconds(60),
            sleep: ManualSleeper().sleep,
            inputMonitorFactory: factory,
            modifierReleasePollSleep: ManualSleeper().sleep
        )
        var events: [ShortcutEvent] = []
        try adapter.register(.rightOption) { events.append($0) }
        let held = NSEvent.ModifierFlags(rawValue: Self.rightOptionHeld)

        factory.emitFlagsChanged(keyCode: 61, modifierFlags: held)
        adapter.applicationDidResignActive()
        XCTAssertEqual(events, [.keyDown, .keyUp], "the watchdog ends the hold")
        // The release arrives later and is not a second key-up.
        factory.emitFlagsChanged(keyCode: 61, modifierFlags: [])
        XCTAssertEqual(events, [.keyDown, .keyUp])
        // The next press starts again.
        factory.emitFlagsChanged(keyCode: 61, modifierFlags: held)
        XCTAssertEqual(events, [.keyDown, .keyUp, .keyDown])
        // A forced stop followed by a lost release: the next press still counts.
        adapter.applicationDidResignActive()
        factory.emitFlagsChanged(keyCode: 61, modifierFlags: held)
        XCTAssertEqual(events, [.keyDown, .keyUp, .keyDown, .keyUp, .keyDown])
        adapter.unregister()
    }

    func testReleaseProofNeedsBothTheDeviceBitAndTheFamilyFlagGone() {
        XCTAssertTrue(ModifierKeyEdgeDetector.provesReleased(.rightOption, modifierFlags: 0))
        XCTAssertTrue(ModifierKeyEdgeDetector.provesReleased(.rightOption, modifierFlags: NSEvent.ModifierFlags.shift.rawValue))
        XCTAssertFalse(ModifierKeyEdgeDetector.provesReleased(.rightOption, modifierFlags: NSEvent.ModifierFlags.option.rawValue))
        XCTAssertFalse(ModifierKeyEdgeDetector.provesReleased(.rightOption, modifierFlags: 0x40))
        XCTAssertFalse(ModifierKeyEdgeDetector.provesReleased(.rightCommand, modifierFlags: NSEvent.ModifierFlags.command.rawValue))
        XCTAssertFalse(ModifierKeyEdgeDetector.provesReleased(.fn, modifierFlags: NSEvent.ModifierFlags.function.rawValue))
        XCTAssertTrue(ModifierKeyEdgeDetector.provesReleased(.rightControl, modifierFlags: NSEvent.ModifierFlags.option.rawValue))
    }

    func testAdapterReportsAccessibilityForAModifierOnlyKeyWhenUntrusted() throws {
        let backend = FakeRegistrationBackend()
        let adapter = KeyboardShortcutsAdapter(
            backend: backend,
            sleep: { _ in },
            inputMonitorFactory: FakeInputMonitorFactory(trusted: false)
        )
        XCTAssertThrowsError(try adapter.register(.rightOption) { _ in }) { error in
            XCTAssertEqual(error as? HotkeyAdapterError, .accessibilityRequired)
        }
        XCTAssertEqual(adapter.registrationState, .failed(.permissionAccessibilityDenied))
        XCTAssertNil(adapter.registeredShortcut)
    }

    /// ADR-026: the App Store edition refuses the triggers that need a
    /// global monitor before installing anything, with its own sentence —
    /// not "grant Accessibility", which a sandboxed app cannot act on — and
    /// key combinations still register through Carbon.
    func testAppStoreEditionRefusesGlobalMonitorTriggersAndKeepsCombinations() throws {
        let backend = FakeRegistrationBackend()
        let factory = FakeInputMonitorFactory(trusted: true)
        let adapter = KeyboardShortcutsAdapter(
            backend: backend,
            sleep: { _ in },
            inputMonitorFactory: factory,
            globalInputMonitorsAvailable: false
        )
        XCTAssertThrowsError(try adapter.register(.rightOption) { _ in }) { error in
            XCTAssertEqual(error as? HotkeyAdapterError, .unavailableInAppStoreEdition)
        }
        XCTAssertEqual(factory.installed, 0)
        XCTAssertEqual(adapter.registrationState, .failed(.hotkeyRegistrationFailed))

        XCTAssertThrowsError(try adapter.setMiddleMouseTrigger(enabled: true, activationDelay: .zero) { _ in }) { error in
            XCTAssertEqual(error as? HotkeyAdapterError, .unavailableInAppStoreEdition)
        }
        XCTAssertEqual(factory.installed, 0)
        XCTAssertFalse(adapter.isMiddleMouseTriggerActive)
        // Turning it off is always accepted.
        XCTAssertNoThrow(try adapter.setMiddleMouseTrigger(enabled: false, activationDelay: .zero) { _ in })

        let combination = ShortcutDefinition(key: "space", modifiers: ["control"])
        try adapter.register(combination) { _ in }
        XCTAssertEqual(backend.registeredShortcut, try combination.asKeyboardShortcut())
        XCTAssertNotNil(HotkeyAdapterError.unavailableInAppStoreEdition.errorDescription)
    }

    // MARK: Auxiliary shortcuts

    func testAuxiliaryShortcutsRefuseConflictsAndCollapseRepeats() throws {
        let primaryBackend = FakeRegistrationBackend()
        let cancelBackend = FakeRegistrationBackend()
        let adapter = KeyboardShortcutsAdapter(
            backend: primaryBackend,
            sleep: { _ in },
            inputMonitorFactory: FakeInputMonitorFactory(trusted: true),
            auxiliaryBackendFactory: { _ in cancelBackend }
        )
        let primary = ShortcutDefinition(key: "space", modifiers: ["control"])
        let cancel = ShortcutDefinition(key: "escape", modifiers: ["command"])
        try adapter.register(primary) { _ in }

        XCTAssertThrowsError(try adapter.registerAuxiliaryShortcut(.cancel, primary) { _ in }) { error in
            XCTAssertEqual(error as? HotkeyAdapterError, .applicationConflict)
        }
        XCTAssertNil(adapter.auxiliaryShortcut(for: .cancel))

        var cancelEdges: [ShortcutEvent] = []
        try adapter.registerAuxiliaryShortcut(.cancel, cancel) { cancelEdges.append($0) }
        XCTAssertEqual(adapter.auxiliaryShortcut(for: .cancel), cancel)
        XCTAssertEqual(cancelBackend.registeredShortcut, try cancel.asKeyboardShortcut())
        cancelBackend.emitKeyDown()
        cancelBackend.emitKeyDown()
        cancelBackend.emitKeyUp()
        XCTAssertEqual(cancelEdges, [.keyDown, .keyUp])

        // Tearing down mid-hold synthesizes the release so the caller never
        // sees a hold without an end.
        cancelBackend.emitKeyDown()
        adapter.unregisterAuxiliaryShortcut(.cancel)
        XCTAssertEqual(cancelEdges, [.keyDown, .keyUp, .keyDown, .keyUp])
        XCTAssertNil(cancelBackend.registeredShortcut)
        XCTAssertNil(adapter.auxiliaryShortcut(for: .cancel))
    }

    // MARK: Middle mouse

    func testMiddleMouseTriggerArmsAfterTheDelayAndIgnoresShortClicks() async throws {
        let factory = FakeInputMonitorFactory(trusted: true)
        let gate = SleepGate()
        let monitor = MiddleMouseTriggerMonitor(factory: factory, sleep: { _ in await gate.wait() })
        var edges: [ShortcutEvent] = []
        try monitor.start(activationDelay: .milliseconds(300)) { edges.append($0) }
        XCTAssertTrue(monitor.isActive)

        // A click released before the delay elapses is an ordinary middle click.
        monitor.handle(buttonNumber: MiddleMouseTriggerMonitor.middleButtonNumber, isDown: true)
        monitor.handle(buttonNumber: MiddleMouseTriggerMonitor.middleButtonNumber, isDown: false)
        await gate.open()
        await Task.yield()
        XCTAssertEqual(edges, [])
        XCTAssertFalse(monitor.isArmed)

        // Other buttons are never the trigger.
        monitor.handle(buttonNumber: 3, isDown: true)
        XCTAssertFalse(monitor.isArmed)

        // Held past the delay: one key-down, and the release is the key-up.
        monitor.handle(buttonNumber: MiddleMouseTriggerMonitor.middleButtonNumber, isDown: true)
        await gate.open()
        await settle(until: { monitor.isArmed })
        XCTAssertEqual(edges, [.keyDown])
        monitor.handle(buttonNumber: MiddleMouseTriggerMonitor.middleButtonNumber, isDown: false)
        XCTAssertEqual(edges, [.keyDown, .keyUp])
        XCTAssertFalse(monitor.isArmed)

        monitor.stop()
        XCTAssertFalse(monitor.isActive)
        XCTAssertEqual(factory.removed, 2)
    }

    func testMiddleMouseTriggerNeedsAccessibilityAndTheAdapterExposesIt() throws {
        let untrusted = FakeInputMonitorFactory(trusted: false)
        let monitor = MiddleMouseTriggerMonitor(factory: untrusted, sleep: { _ in })
        XCTAssertThrowsError(try monitor.start(activationDelay: .zero) { _ in }) { error in
            XCTAssertEqual(error as? HotkeyAdapterError, .accessibilityRequired)
        }

        let adapter = KeyboardShortcutsAdapter(
            backend: FakeRegistrationBackend(),
            sleep: { _ in },
            inputMonitorFactory: FakeInputMonitorFactory(trusted: true)
        )
        XCTAssertFalse(adapter.isMiddleMouseTriggerActive)
        try adapter.setMiddleMouseTrigger(enabled: true, activationDelay: .milliseconds(300)) { _ in }
        XCTAssertTrue(adapter.isMiddleMouseTriggerActive)
        try adapter.setMiddleMouseTrigger(enabled: false, activationDelay: .milliseconds(300)) { _ in }
        XCTAssertFalse(adapter.isMiddleMouseTriggerActive)
    }

    // MARK: Hybrid reducer

    func testHybridReducerTreatsAQuickReleaseAsATapAndALongOneAsAHold() {
        var reducer = HotkeyEdgeReducer()
        let mode = RecordingInteraction.hybrid

        // Tap: the release is inert and the next press stops.
        XCTAssertEqual(reducer.consume(.keyDown, mode: mode, isRecording: false), .start)
        XCTAssertEqual(reducer.consume(.keyUp, mode: mode, isRecording: true, heldFor: .milliseconds(120)), .ignored(.hybridTap))
        XCTAssertEqual(reducer.consume(.keyDown, mode: mode, isRecording: true), .stop)
        XCTAssertEqual(reducer.consume(.keyUp, mode: mode, isRecording: false, heldFor: .milliseconds(50)), .ignored(.toggleKeyUp))

        // Hold: the release stops.
        XCTAssertEqual(reducer.consume(.keyDown, mode: mode, isRecording: false), .start)
        XCTAssertEqual(reducer.consume(.keyUp, mode: mode, isRecording: true, heldFor: .seconds(2)), .stop)

        // The tap window boundary is inclusive.
        XCTAssertEqual(reducer.consume(.keyDown, mode: mode, isRecording: false), .start)
        XCTAssertEqual(reducer.consume(.keyUp, mode: mode, isRecording: true, heldFor: TriggerSettings.hybridTapWindow), .ignored(.hybridTap))
        reducer.reset()
        XCTAssertFalse(reducer.isPhysicalKeyDown)
    }

    // MARK: Helpers

    /// Yields until `condition` holds. Bounded so a regression shows up as a
    /// failure, not a hang; nothing here waits on wall-clock time.
    private func settle(until condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
    }
}

/// A clock the test advances by hand: each `sleep` parks until
/// `resumeAll()`, and `parked` says how many are waiting. A cancelled
/// sleeper is resumed by throwing, as `Task.sleep` would.
private final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var duration: Duration?

    var parked: Int { lock.withLock { waiters.count } }
    var lastDuration: Duration? { lock.withLock { duration } }

    var sleep: KeyStateWatchdog.Sleep {
        { [self] requested in
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let cancelled = lock.withLock {
                        duration = requested
                        guard !Task.isCancelled else { return true }
                        waiters[id] = continuation
                        return false
                    }
                    if cancelled { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
                waiter?.resume(throwing: CancellationError())
            }
        }
    }

    func resumeAll() {
        let pending = lock.withLock {
            let all = Array(waiters.values)
            waiters.removeAll()
            return all
        }
        for waiter in pending {
            waiter.resume()
        }
    }
}

/// Suspends sleepers until the test opens it. An `open()` with nobody waiting
/// leaves one permit, so the test cannot race the sleeping task's arrival.
private actor SleepGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var permits = 0

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !waiters.isEmpty else {
            permits += 1
            return
        }
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

@MainActor
private final class FakeInputMonitorFactory: InputEventMonitorFactory {
    let isAccessibilityTrusted: Bool
    /// What `NSEvent.modifierFlags` would read; `emitFlagsChanged` keeps it
    /// in step with the last event, as the window server would.
    var currentModifierFlags: UInt = 0
    private(set) var installed = 0
    private(set) var removed = 0
    private var localHandlers: [NSEvent.EventTypeMask.RawValue: (NSEvent) -> NSEvent?] = [:]
    private var globalHandlers: [NSEvent.EventTypeMask.RawValue: (NSEvent) -> Void] = [:]

    init(trusted: Bool) {
        isAccessibilityTrusted = trusted
    }

    func addLocalMonitor(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        installed += 1
        localHandlers[mask.rawValue] = handler
        return NSObject()
    }

    func addGlobalMonitor(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any? {
        installed += 1
        globalHandlers[mask.rawValue] = handler
        return NSObject()
    }

    func removeMonitor(_: Any) {
        removed += 1
    }

    /// Delivers a real `flagsChanged` event to the global monitor, as AppKit would.
    func emitFlagsChanged(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        guard let event = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else {
            return XCTFail("could not build a flagsChanged event")
        }
        currentModifierFlags = modifierFlags.rawValue & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue
        globalHandlers[NSEvent.EventTypeMask.flagsChanged.rawValue]?(event)
    }
}

@MainActor
private final class FakeRegistrationBackend: HotkeyRegistrationBackend {
    var registeredShortcut: KeyboardShortcuts.Shortcut?
    private var keyDown: (@MainActor () -> Void)?
    private var keyUp: (@MainActor () -> Void)?

    func register(
        _ shortcut: KeyboardShortcuts.Shortcut,
        onKeyDown: @escaping @MainActor () -> Void,
        onKeyUp: @escaping @MainActor () -> Void
    ) throws {
        registeredShortcut = shortcut
        keyDown = onKeyDown
        keyUp = onKeyUp
    }

    func unregister() {
        registeredShortcut = nil
        keyDown = nil
        keyUp = nil
    }

    func presentRecorder() {}
    func emitKeyDown() { keyDown?() }
    func emitKeyUp() { keyUp?() }
}
