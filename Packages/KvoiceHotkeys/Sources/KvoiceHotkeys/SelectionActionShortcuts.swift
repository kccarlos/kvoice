import AppKit
import Foundation
import KeyboardShortcuts
import KvoiceDomain
import SwiftUI

/// The three Selection Action shortcut slots (product decisions #2/#4).
///
/// Each slot is a `KeyboardShortcuts.Name`; the library stores the recorded
/// combination itself, so nothing about the key reaches `AppSettings`. Which
/// action a slot runs is `AIEndpointSettings.selectionActionSlots`. The
/// `KeyboardShortcuts` types stay inside this file: the shell gets a handler
/// keyed by slot index, and the settings UI gets a ready-made recorder view.
@MainActor
public enum SelectionActionShortcuts {
    public static let slotCount = AIEndpointSettings.selectionActionSlotCount

    /// No shortcut is recorded by default: a global key combination that the
    /// user did not choose would collide with other apps.
    static let names: [KeyboardShortcuts.Name] = (0..<slotCount).map { slot in
        KeyboardShortcuts.Name("kvoice.selectionAction.\(slot + 1)")
    }

    private static var handler: (@MainActor (Int) -> Void)?
    private static var handlersInstalled = false

    /// Routes a press of any slot to `handler(slot)` (0-based). Calling
    /// again replaces the handler; the library registration is done once.
    /// Fires on key-up, like the recording shortcut's toggle edge, so the
    /// combination is fully released before the selection is read.
    public static func install(handler: @escaping @MainActor (Int) -> Void) {
        self.handler = handler
        guard !handlersInstalled else { return }
        handlersInstalled = true
        for (slot, name) in names.enumerated() {
            KeyboardShortcuts.onKeyUp(for: name) { @MainActor in
                Self.handler?(slot)
            }
        }
    }

    /// Stops routing. The recorded shortcuts stay stored for next launch.
    public static func uninstall() {
        handler = nil
        for name in names {
            KeyboardShortcuts.removeHandler(for: name)
        }
        handlersInstalled = false
    }

    /// Temporarily stops the slots from firing (for example while a
    /// dictation job is running) without forgetting them.
    public static func setEnabled(_ enabled: Bool) {
        if enabled {
            KeyboardShortcuts.enable(names)
        } else {
            KeyboardShortcuts.disable(names)
        }
    }

    /// "⌥⇧1"-style description of a slot's recorded shortcut, or `nil`.
    public static func shortcutDescription(slot: Int) -> String? {
        guard names.indices.contains(slot) else { return nil }
        return KeyboardShortcuts.getShortcut(for: names[slot])?.description
    }

    /// True when the slot has a recorded combination.
    public static func hasShortcut(slot: Int) -> Bool {
        shortcutDescription(slot: slot) != nil
    }

    /// The library's recorder control for a slot, for the AI Actions section
    /// (`AIActionsHooks.selectionActionShortcutRecorder`).
    public static func recorder(slot: Int) -> AnyView {
        guard names.indices.contains(slot) else { return AnyView(EmptyView()) }
        return AnyView(
            KeyboardShortcuts.Recorder(for: names[slot])
                .accessibilityLabel("Selection Action \(slot + 1) shortcut")
        )
    }
}
