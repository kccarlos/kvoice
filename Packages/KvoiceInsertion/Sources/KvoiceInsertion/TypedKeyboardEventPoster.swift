import Foundation
import CoreGraphics

/// The production `KeyboardEventPosting` adapter (ADR-016).
///
/// This is the only file in the insertion module that may use `CGEvent`; the
/// source-scanning test in `AXTextInsertionServiceTests` enforces that, and
/// also enforces that this file never builds a paste chord or touches the
/// pasteboard.  What it does is small: create a key-down and a key-up event
/// carrying `chunk` as their Unicode string, clear every modifier flag so the
/// text cannot be read as a shortcut, and post both events to the target
/// process only.  Posting requires the Accessibility trust the service has
/// already confirmed; nothing here prompts for it.
public struct TypedKeyboardEventPoster: KeyboardEventPosting {
    public init() {}

    public func postUnicodeChunk(_ chunk: String, to processIdentifier: pid_t) throws {
        let units = Array(chunk.utf16)
        guard !units.isEmpty, units.count <= TypedTextChunker.maxUTF16UnitsPerChunk else {
            throw TypedKeyboardEventError.invalidChunk
        }

        // A private event source keeps the synthetic events isolated from the
        // hardware modifier state, so a key the user is still physically
        // holding cannot combine with the typed text.
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            throw TypedKeyboardEventError.eventCreationFailed
        }

        for event in [down, up] {
            event.flags = []
            units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
            event.postToPid(processIdentifier)
        }
    }

    /// Auto-send's Return: virtual key 36 (`kVK_Return`) with no modifiers,
    /// down then up, to the target PID only. Not a paste chord: the only
    /// key involved is Return, and the flags are cleared so a held modifier
    /// cannot turn it into Command-Return.
    public func postReturnKey(to processIdentifier: pid_t) throws {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        else {
            throw TypedKeyboardEventError.eventCreationFailed
        }
        for event in [down, up] {
            event.flags = []
            event.postToPid(processIdentifier)
        }
    }
}

/// The PostEvent privilege (ADR-026): what posting keyboard events to
/// another process needs, separate from full Accessibility trust. System
/// Settings lists it under Privacy & Security › Accessibility, but `tccutil`
/// knows it as its own service (`PostEvent`), and — unlike Accessibility — it
/// is available to a sandboxed app (Apple DTS on the developer forums,
/// threads 789896 and 820594). The App Store edition's insertion, auto-send
/// Return and permission card read this instead of `AXIsProcessTrusted()`,
/// which stays false in the sandbox.
///
/// Lives in this file with the rest of the Core Graphics event API so the
/// source-scanning test keeps one place to look.
public struct SystemEventPostingAccess: EventPostingAccessProviding {
    public init() {}

    public func isGranted() -> Bool {
        CGPreflightPostEventAccess()
    }

    /// Shows the system's alert once when access was never decided; returns
    /// the (possibly still false) state afterwards.
    public func request() -> Bool {
        CGRequestPostEventAccess()
    }
}
