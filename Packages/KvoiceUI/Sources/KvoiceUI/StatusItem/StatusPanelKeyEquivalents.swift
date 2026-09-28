import Foundation

/// The keys the panel answers while it is open, as a pure table over the
/// scalars of a key-down event — so the shell's local monitor
/// (`StatusPanelController`) is one line and the routing is unit-tested.
///
/// A menu gets these for free; the panel builds them (design review
/// 2026-09-16 § 1, "Keyboard navigation" / "Key equivalents shown"):
///
/// - **Escape** closes the panel, as it closes a menu. It does not cancel a
///   recording: the job's Escape monitor (FR-LIFE-011) has a local half
///   that would otherwise see the key first, so the shell skips it while
///   the panel is shown (`AppDelegate.syncEscapeMonitoring`); the next
///   Escape — with the panel gone — reaches it as before, and the Cancel
///   row is the in-panel path.
/// - **⌘H, ⌘,, ⌘Q** run History, Settings… and Quit, the App-group key
///   equivalents the menu draws and fires.
/// - **↓ / ↑** move the focus through the rows, **Return** activates the
///   focused command row (`StatusPanelModel.activateFocusedRow`). Tab and
///   Shift-Tab are the system's (Full Keyboard Access) and are left alone.
///
/// Everything else is passed through to the panel's window.
public enum StatusPanelKeyEquivalents {
    public enum Action: Equatable, Sendable {
        case close
        case command(StatusPanelCommand)
        case focusNext
        case focusPrevious
        case activateFocused
    }

    /// The virtual key codes the router recognises (`NSEvent.keyCode`,
    /// ANSI layout-independent: Escape, Return, keypad Enter, ↓, ↑).
    public static let escapeKeyCode: UInt16 = 53
    public static let returnKeyCode: UInt16 = 36
    public static let keypadEnterKeyCode: UInt16 = 76
    public static let downArrowKeyCode: UInt16 = 125
    public static let upArrowKeyCode: UInt16 = 124

    /// `characters` are the event's `charactersIgnoringModifiers`;
    /// `command` is whether ⌘ was down without ⌃ or ⌥ (⇧ is ignored so a
    /// caps-locked "H" still routes). Nil means "not ours".
    public static func action(keyCode: UInt16, characters: String?, command: Bool) -> Action? {
        if command {
            switch characters?.lowercased() {
            case "h": return .command(.openHistory)
            case ",": return .command(.openSettings)
            case "q": return .command(.quit)
            default: return nil
            }
        }
        switch keyCode {
        case escapeKeyCode: return .close
        case downArrowKeyCode: return .focusNext
        case upArrowKeyCode: return .focusPrevious
        case returnKeyCode, keypadEnterKeyCode: return .activateFocused
        default: return nil
        }
    }
}

/// Which surface a click on the status item opens (P-D4, product decision
/// 2026-09-16): **left-click → the panel; right-click, ⌥-click or
/// ⌃-click → the `NSMenu`, unchanged**, as the keyboard / VoiceOver
/// fallback. Pure so the shell's button action is one line and the split
/// is tested.
public enum StatusItemClick {
    public enum Surface: Equatable, Sendable {
        case panel
        case menu
    }

    public static func surface(isRightButton: Bool, option: Bool, control: Bool) -> Surface {
        (isRightButton || option || control) ? .menu : .panel
    }
}
