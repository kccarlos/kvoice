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
@MainActor
public final class ModifierOnlyShortcutMonitor {
    public private(set) var key: ShortcutDefinition.ModifierOnlyKey?
    public private(set) var isDown = false

    private let factory: any InputEventMonitorFactory
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var onKeyDown: (@MainActor () -> Void)?
    private var onKeyUp: (@MainActor () -> Void)?

    public init(factory: any InputEventMonitorFactory = NSEventInputMonitorFactory()) {
        self.factory = factory
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
        onKeyDown = nil
        onKeyUp = nil
    }

    /// Exposed for deterministic tests; the monitors call it with the raw
    /// scalar fields of the event and nothing else.
    public func handle(keyCode: UInt16, modifierFlags: UInt) {
        guard let key,
              let edge = ModifierKeyEdgeDetector.edge(keyCode: keyCode, modifierFlags: modifierFlags, for: key)
        else { return }
        switch edge {
        case .keyDown:
            guard !isDown else { return }
            isDown = true
            onKeyDown?()
        case .keyUp:
            guard isDown else { return }
            isDown = false
            onKeyUp?()
        }
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
