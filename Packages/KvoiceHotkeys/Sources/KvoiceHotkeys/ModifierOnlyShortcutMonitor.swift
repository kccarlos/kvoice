import AppKit
import ApplicationServices
import Foundation
import KvoiceDomain

/// AppKit event-monitor seam shared by the modifier-only shortcut and the
/// middle mouse trigger. The production implementation delegates to
/// `NSEvent`; tests hand back tokens and drive the handlers directly.
///
/// Global monitors only deliver events to an Accessibility-trusted process,
/// and they install without error either way, so `isAccessibilityTrusted` is
/// checked up front to turn "silently never fires" into a registration error
/// the settings UI can show.
@MainActor
public protocol InputEventMonitorFactory: AnyObject {
    var isAccessibilityTrusted: Bool { get }
    /// The modifier keys held right now, read from the window server rather
    /// than from an event (`NSEvent.modifierFlags`). Device-independent bits
    /// only in practice (probed 2026-10-20: Right Option held reads 0x80000,
    /// without the 0x40 device bit). The modifier-only monitor polls it while
    /// a hold is open, to notice a release whose `flagsChanged` it never saw.
    var currentModifierFlags: UInt { get }
    func addLocalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any?
    func addGlobalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> Void
    ) -> Any?
    func removeMonitor(_ monitor: Any)
}

@MainActor
public final class NSEventInputMonitorFactory: InputEventMonitorFactory {
    public init() {}

    public var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    public var currentModifierFlags: UInt {
        NSEvent.modifierFlags.rawValue
    }

    public func addLocalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
    }

    public func addGlobalMonitor(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> Void
    ) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }

    public func removeMonitor(_ monitor: Any) {
        NSEvent.removeMonitor(monitor)
    }
}

/// Pure classification of a `flagsChanged` event for one modifier-only key.
///
/// The virtual key code says *which* physical key changed (left and right
/// Option are 58 and 61); the device-dependent flag bits say whether that key
/// is now down. Using the device bits rather than `.option` means a right
/// Option release is seen even while the left Option key is still held.
public enum ModifierKeyEdgeDetector {
    public static func keyCode(for key: ShortcutDefinition.ModifierOnlyKey) -> UInt16 {
        switch key {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .rightShift: return 60
        case .fn: return 63
        }
    }

    /// `NX_DEVICE*` masks from IOKit's `IOLLEvent.h`, which AppKit passes
    /// through in `modifierFlags` below `deviceIndependentFlagsMask`.
    public static func deviceFlagMask(for key: ShortcutDefinition.ModifierOnlyKey) -> UInt {
        switch key {
        case .rightOption: return 0x0000_0040
        case .rightCommand: return 0x0000_0010
        case .rightControl: return 0x0000_2000
        case .rightShift: return 0x0000_0004
        case .fn: return NSEvent.ModifierFlags.function.rawValue
        }
    }

    /// The device-independent flag of the key's family (`.option` for Right
    /// Option, and so on). Unlike the device bit it is present in
    /// `NSEvent.modifierFlags`, which is what the release poll reads.
    public static func familyFlagMask(for key: ShortcutDefinition.ModifierOnlyKey) -> UInt {
        switch key {
        case .rightOption: return NSEvent.ModifierFlags.option.rawValue
        case .rightCommand: return NSEvent.ModifierFlags.command.rawValue
        case .rightControl: return NSEvent.ModifierFlags.control.rawValue
        case .rightShift: return NSEvent.ModifierFlags.shift.rawValue
        case .fn: return NSEvent.ModifierFlags.function.rawValue
        }
    }

    /// True when `modifierFlags` proves `key` is not held: neither its own
    /// device bit nor any key of its family is down. Left Option held alone
    /// is not proof that Right Option was released, so it never counts.
    public static func provesReleased(_ key: ShortcutDefinition.ModifierOnlyKey, modifierFlags: UInt) -> Bool {
        modifierFlags & deviceFlagMask(for: key) == 0 && modifierFlags & familyFlagMask(for: key) == 0
    }

    /// The semantic edge for one event, or nil when the event is about a
    /// different key.
    public static func edge(
        keyCode: UInt16,
        modifierFlags: UInt,
        for key: ShortcutDefinition.ModifierOnlyKey
    ) -> ShortcutEvent? {
        guard keyCode == Self.keyCode(for: key) else { return nil }
        let isDown = modifierFlags & deviceFlagMask(for: key) != 0
        return isDown ? .keyDown : .keyUp
    }
}

/// Watches one modifier key on its own (Right Option and friends) through a
/// paired local + global `flagsChanged` monitor and reports semantic edges.
///
/// Carbon hot keys need a non-modifier key, which is why this path exists.
/// It is only usable when the process is Accessibility-trusted; otherwise the
/// global monitor installs but never fires, so `start` refuses instead.
///
/// A lost release must never leave the key dead (0.1.5 demo, 2026-10-20:
/// twice a release went unseen, the recording ran until Escape, and once the
/// key then did nothing). Three recoveries, each a release the monitor
/// *infers*:
/// - a second press with no release in between closes the open hold first,
///   so the press is never swallowed;
/// - any other `flagsChanged` whose flags prove the key is up
///   (`ModifierKeyEdgeDetector.provesReleased`) closes it;
/// - while a hold is open, the current modifier state is polled every
///   `releasePollInterval`; two readings in a row that prove the key is up
///   close it.
@MainActor
public final class ModifierOnlyShortcutMonitor {
    public static let releasePollInterval: Duration = .milliseconds(250)

    public private(set) var key: ShortcutDefinition.ModifierOnlyKey?
    public private(set) var isDown = false

    private let factory: any InputEventMonitorFactory
    private let sleep: KeyStateWatchdog.Sleep
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var onKeyDown: (@MainActor () -> Void)?
    private var onKeyUp: (@MainActor () -> Void)?
    private var pollTask: Task<Void, Never>?
    private var holdGeneration = 0
    private var releasedReadings = 0

    /// `sleep` paces the release poll; optional and resolved here for the
    /// same toolchain reason as `KeyboardShortcutsAdapter.init`.
    public init(
        factory: any InputEventMonitorFactory = NSEventInputMonitorFactory(),
        sleep: KeyStateWatchdog.Sleep? = nil
    ) {
        self.factory = factory
        self.sleep = sleep ?? KeyStateWatchdog.systemSleep
    }

    // No `isolated deinit`: the owning adapter calls `stop()` from its own
    // isolated deinit, and a nested isolated deinit inside that job aborted
    // the test process ("freed pointer was not the last allocation").

    public var isActive: Bool {
        localMonitor != nil || globalMonitor != nil
    }

    public func start(
        key: ShortcutDefinition.ModifierOnlyKey,
        onKeyDown: @escaping @MainActor () -> Void,
        onKeyUp: @escaping @MainActor () -> Void
    ) throws {
        stop()
        guard factory.isAccessibilityTrusted else {
            throw HotkeyAdapterError.accessibilityRequired
        }

        localMonitor = factory.addLocalMonitor(matching: .flagsChanged) { [weak self] event in
            self?.handle(keyCode: event.keyCode, modifierFlags: event.modifierFlags.rawValue)
            // Never swallowed: the app's own text fields still see the modifier.
            return event
        }
        globalMonitor = factory.addGlobalMonitor(matching: .flagsChanged) { [weak self] event in
            self?.handle(keyCode: event.keyCode, modifierFlags: event.modifierFlags.rawValue)
        }

        // The global monitor is the one that matters for a menu-bar app; the
        // local one only covers kvoice's own windows.
        guard globalMonitor != nil else {
            stop()
            throw HotkeyAdapterError.registrationFailed
        }

        self.key = key
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
    }

    public func stop() {
        if let localMonitor {
            factory.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            factory.removeMonitor(globalMonitor)
        }
        localMonitor = nil
        globalMonitor = nil
        key = nil
        isDown = false
        cancelPoll()
        onKeyDown = nil
        onKeyUp = nil
    }

    /// Forgets an open hold without reporting a release, for an owner that
    /// already ended it (the adapter's watchdog synthesized the key-up).
    public func forgetHold() {
        isDown = false
        cancelPoll()
    }

    /// Exposed for deterministic tests; the monitors call it with the raw
    /// scalar fields of the event and nothing else.
    public func handle(keyCode: UInt16, modifierFlags: UInt) {
        guard let key else { return }
        guard let edge = ModifierKeyEdgeDetector.edge(keyCode: keyCode, modifierFlags: modifierFlags, for: key) else {
            // Another modifier changed. Its flags still describe the whole
            // keyboard: if they prove the trigger is up, its release was lost.
            // The window server's current state must agree, so one event
            // with cleared flags from a remapper, a remote desktop or a VM
            // cannot cut a push-to-talk recording short while the key is
            // physically down.
            if isDown,
               ModifierKeyEdgeDetector.provesReleased(key, modifierFlags: modifierFlags),
               ModifierKeyEdgeDetector.provesReleased(key, modifierFlags: factory.currentModifierFlags) {
                endHold()
            }
            return
        }
        switch edge {
        case .keyDown:
            // `flagsChanged` never repeats, so a second press means the
            // release in between was lost: report it, then this press.
            if isDown { endHold() }
            beginHold()
        case .keyUp:
            guard isDown else { return }
            endHold()
        }
    }

    // MARK: Hold

    private func beginHold() {
        isDown = true
        startPoll()
        onKeyDown?()
    }

    private func endHold() {
        isDown = false
        cancelPoll()
        onKeyUp?()
    }

    private func startPoll() {
        cancelPoll()
        let generation = holdGeneration
        let sleep = sleep
        pollTask = Task { [weak self] in
            while true {
                do {
                    try await sleep(Self.releasePollInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self, self.pollStillHolding(generation: generation) else { return }
            }
        }
    }

    private func cancelPoll() {
        holdGeneration += 1
        releasedReadings = 0
        pollTask?.cancel()
        pollTask = nil
    }

    /// One poll reading. Returns whether the hold is still open.
    private func pollStillHolding(generation: Int) -> Bool {
        guard generation == holdGeneration, isDown, let key else { return false }
        guard ModifierKeyEdgeDetector.provesReleased(key, modifierFlags: factory.currentModifierFlags) else {
            releasedReadings = 0
            return true
        }
        releasedReadings += 1
        guard releasedReadings >= 2 else { return true }
        endHold()
        return false
    }
}

/// The middle mouse button as a toggle trigger.
///
/// The button has to stay down for `activationDelay` before it counts, so an
/// ordinary middle click (open in new tab, paste selection) passes through
/// untouched. Once activated, the button's release is reported as the
/// matching key-up. The caller treats the edges with toggle semantics.
@MainActor
public final class MiddleMouseTriggerMonitor {
    public static let middleButtonNumber = 2

    public private(set) var isActive = false
    public private(set) var isArmed = false

    private let factory: any InputEventMonitorFactory
    private let sleep: KeyStateWatchdog.Sleep
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var handler: (@MainActor (ShortcutEvent) -> Void)?
    private var activationDelay: Duration = .zero
    private var pressTask: Task<Void, Never>?
    private var generation = 0

    public init(
        factory: any InputEventMonitorFactory = NSEventInputMonitorFactory(),
        sleep: @escaping KeyStateWatchdog.Sleep = KeyStateWatchdog.systemSleep
    ) {
        self.factory = factory
        self.sleep = sleep
    }

    // No `isolated deinit`; see `ModifierOnlyShortcutMonitor`.

    public func start(
        activationDelay: Duration,
        handler: @escaping @MainActor (ShortcutEvent) -> Void
    ) throws {
        stop()
        guard factory.isAccessibilityTrusted else {
            throw HotkeyAdapterError.accessibilityRequired
        }
        let mask: NSEvent.EventTypeMask = [.otherMouseDown, .otherMouseUp]
        localMonitor = factory.addLocalMonitor(matching: mask) { [weak self] event in
            self?.handle(buttonNumber: event.buttonNumber, isDown: event.type == .otherMouseDown)
            return event
        }
        globalMonitor = factory.addGlobalMonitor(matching: mask) { [weak self] event in
            self?.handle(buttonNumber: event.buttonNumber, isDown: event.type == .otherMouseDown)
        }
        guard globalMonitor != nil else {
            stop()
            throw HotkeyAdapterError.registrationFailed
        }
        self.activationDelay = max(.zero, activationDelay)
        self.handler = handler
        isActive = true
    }

    public func stop() {
        pressTask?.cancel()
        pressTask = nil
        generation += 1
        if isArmed {
            isArmed = false
            handler?(.keyUp)
        }
        if let localMonitor {
            factory.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            factory.removeMonitor(globalMonitor)
        }
        localMonitor = nil
        globalMonitor = nil
        handler = nil
        isActive = false
    }

    /// Exposed for deterministic tests.
    public func handle(buttonNumber: Int, isDown: Bool) {
        guard isActive, buttonNumber == Self.middleButtonNumber else { return }
        if isDown {
            guard pressTask == nil, !isArmed else { return }
            generation += 1
            let generation = generation
            let delay = activationDelay
            let sleep = sleep
            pressTask = Task { [weak self] in
                do {
                    try await sleep(delay)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.activateIfCurrent(generation: generation)
            }
        } else {
            pressTask?.cancel()
            pressTask = nil
            guard isArmed else { return }
            isArmed = false
            handler?(.keyUp)
        }
    }

    private func activateIfCurrent(generation: Int) {
        guard self.generation == generation, isActive, !isArmed else { return }
        pressTask = nil
        isArmed = true
        handler?(.keyDown)
    }
}
