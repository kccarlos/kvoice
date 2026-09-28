import AppKit
import Foundation

/// ADR-021: what a key press meant to the in-recorder AI controls.
public enum RecordingAIControl: Equatable, Sendable {
    /// ⌘1–⌘9 and ⌘0: run the n-th saved AI action for the current job
    /// (0 is the tenth, as in the AI Actions grid).
    case action(shortcutNumber: Int)
    /// ⌘⇧A: AI on/off for the current job.
    case toggleAIEnabled
}

/// A paired local/global observer for the in-recorder AI controls, built on
/// the same seam and with the same degradation as `ActiveJobEscapeMonitor`:
/// the shell starts it when a job enters `.recording` and stops it the moment
/// the job leaves that phase, so outside kvoice's own recording no key is
/// ever looked at. The global observer needs Accessibility trust exactly as
/// Escape's does; without it the status is `.degraded` and the controls
/// only work while kvoice itself is frontmost.
///
/// The local observer swallows an accepted chord (it returns nil) — inside
/// kvoice's own windows ⌘1 has no other meaning — while the global observer
/// cannot swallow anything by construction, so another app's ⌘1 still
/// reaches it. Every other key passes through untouched.
@MainActor
public final class RecordingAIControlMonitor {
    public private(set) var status: EscapeMonitorStatus = .inactive

    private let factory: any EscapeMonitorFactory
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var handler: (@MainActor (RecordingAIControl) -> Void)?

    public init(factory: any EscapeMonitorFactory = NSEventEscapeMonitorFactory()) {
        self.factory = factory
    }

    public var isActive: Bool {
        status == .active
    }

    isolated deinit {
        stop()
    }

    @discardableResult
    public func start(handler: @escaping @MainActor (RecordingAIControl) -> Void) -> EscapeMonitorStatus {
        stop()
        self.handler = handler

        localMonitor = factory.addLocalMonitor { [weak self] event in
            guard let control = Self.control(for: event) else { return event }
            self?.handler?(control)
            return nil
        }

        globalMonitor = factory.addGlobalMonitor { [weak self] event in
            guard let control = Self.control(for: event) else { return }
            self?.handler?(control)
        }

        status = Self.status(localMonitor: localMonitor, globalMonitor: globalMonitor)
        if status == .inactive {
            self.handler = nil
        }
        return status
    }

    public func stop() {
        if let localMonitor {
            factory.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            factory.removeMonitor(globalMonitor)
        }
        self.localMonitor = nil
        self.globalMonitor = nil
        handler = nil
        status = .inactive
    }

    /// Pure event predicate used by both observers and by deterministic
    /// tests. `characters` is the event's `charactersIgnoringModifiers`, so
    /// the digits are layout-independent the same way the main window's
    /// ⌘digit handler is; the modifier set must be exactly ⌘ (digits) or
    /// ⌘⇧ (A) once the keypad, caps-lock and function bits are ignored, so
    /// ⌥⌘1 or ⌃⌘1 belong to whoever else claims them.
    public static func control(
        characters: String?,
        modifierFlags: NSEvent.ModifierFlags,
        isRepeat: Bool = false
    ) -> RecordingAIControl? {
        guard !isRepeat, let characters, characters.count == 1 else { return nil }
        let modifiers = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .capsLock, .function])
        if modifiers == .command, let digit = Int(characters), (0...9).contains(digit) {
            return .action(shortcutNumber: digit)
        }
        if modifiers == [.command, .shift], characters.lowercased() == "a" {
            return .toggleAIEnabled
        }
        return nil
    }

    private static func control(for event: NSEvent) -> RecordingAIControl? {
        guard event.type == .keyDown else { return nil }
        return control(
            characters: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags,
            isRepeat: event.isARepeat
        )
    }

    private static func status(localMonitor: Any?, globalMonitor: Any?) -> EscapeMonitorStatus {
        switch (localMonitor != nil, globalMonitor != nil) {
        case (true, true): return .active
        case (true, false), (false, true): return .degraded
        case (false, false): return .inactive
        }
    }
}
