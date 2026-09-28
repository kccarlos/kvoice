import Foundation

/// Posts synthetic Unicode keyboard events to one process.
///
/// This is the ADR-016 third insertion tier: it exists for targets whose
/// Accessibility text attributes are read-only (terminal emulators) and is
/// used only after the writable-attribute tiers were found unavailable.  The
/// contract is deliberately narrow: one call posts one key-press pair (down
/// then up) carrying `chunk` as its Unicode string, addressed to
/// `processIdentifier` only.  It never posts modifier combinations, never
/// simulates a paste, and never touches the pasteboard.
///
/// The production implementation lives in `TypedKeyboardEventPoster.swift`,
/// the only file in this module permitted to use the event-posting API; a
/// source-scanning test enforces that.
public protocol KeyboardEventPosting: Sendable {
    /// `chunk` is at most `TypedTextChunker.maxUTF16UnitsPerChunk` UTF-16 code
    /// units and never empty.
    func postUnicodeChunk(_ chunk: String, to processIdentifier: pid_t) throws
    /// Auto-send: one Return key press and release, addressed to the target
    /// process only. The production poster uses the Return virtual key so
    /// hosts that read the key code (terminals, some editors) see a real
    /// Return; the default sends a carriage return as typed text.
    func postReturnKey(to processIdentifier: pid_t) throws
}

public extension KeyboardEventPosting {
    func postReturnKey(to processIdentifier: pid_t) throws {
        try postUnicodeChunk("\r", to: processIdentifier)
    }
}

/// Whether this process may post keyboard events to other processes — the
/// PostEvent privilege (ADR-026). Production: `SystemEventPostingAccess` in
/// `TypedKeyboardEventPoster.swift`.
public protocol EventPostingAccessProviding: Sendable {
    /// Non-prompting.
    func isGranted() -> Bool
    /// May show the system's alert; only on an explicit user action.
    func request() -> Bool
}

/// `AccessibilityTrustProviding` over the PostEvent privilege, for the
/// consumers that only post events (auto-send's Return) in the App Store
/// edition, where `AXIsProcessTrusted()` is never true.
public struct EventPostingTrustProvider: AccessibilityTrustProviding {
    private let access: any EventPostingAccessProviding

    public init(access: any EventPostingAccessProviding = SystemEventPostingAccess()) {
        self.access = access
    }

    public func isTrusted(prompt: Bool) -> Bool {
        prompt ? access.request() : access.isGranted()
    }
}

public enum TypedKeyboardEventError: Error, Sendable, Equatable {
    /// The chunk was empty or exceeded the per-event Unicode string limit.
    case invalidChunk
    /// The system refused to create an event.
    case eventCreationFailed
}

/// Which focused elements may receive typed insertion (ADR-016).
///
/// The decision is by role and subrole only — never by bundle identifier — so
/// that every terminal emulator that exposes a standard text role is covered
/// and no application is special-cased.  The allowlist is the set of AX roles
/// that denote a text-entry surface:
///
/// - `AXTextArea`: Terminal.app's terminal view, iTerm2's `PTYTextView`, and
///   the `<textarea>` xterm.js focuses inside VS Code's integrated terminal
///   all report this role with no subrole.  It is the motivating case.
/// - `AXTextField`, `AXTextView`, `AXSearchField`, `AXComboBox`: single-line
///   or legacy text-entry roles that some hosts use for command input.
/// - `AXWebArea`: an editable web document whose focused element is the
///   document itself (Electron/Chromium hosts).
///
/// `AXScrollArea` is deliberately absent.  A terminal's scroll area is the
/// *container* of its text view; the system-wide focused element is the text
/// view inside it, which reports `AXTextArea`.  If a host ever reports the
/// container as focused there is no evidence it accepts text, so it fails
/// closed to the clipboard like every other unknown role.
///
/// Secure fields are excluded twice: by role/subrole here and, earlier in the
/// pipeline, by `AXSecureMetadata`, which also rejects unknown roles before
/// this classification is consulted.
public enum TypedInsertionEligibility {
    public static let allowedRoles: Set<String> = [
        "AXTextArea",
        "AXTextField",
        "AXTextView",
        "AXSearchField",
        "AXComboBox",
        "AXWebArea"
    ]

    public static func isEligible(role: String?, subrole: String?) -> Bool {
        guard let role,
              allowedRoles.contains(role),
              NativeAXElementClient.classify(role: role, subrole: subrole) == .notSecure
        else {
            return false
        }
        return true
    }
}

/// Makes dictated text safe to *type* into a terminal (ADR-016).
///
/// A typed newline in a terminal executes the current line and a typed tab
/// triggers shell completion, so both are unacceptable as raw keystrokes.
/// Product decision: every run of line breaks and tabs collapses to a single
/// space.  Other C0/C1 control characters could begin an escape sequence when
/// written to a pty, so they are dropped outright.  Everything else — including
/// all printable Unicode — is preserved exactly.
///
/// This applies only to the typed tier.  The Accessibility tiers insert the
/// text verbatim because a text attribute assignment cannot execute anything.
public enum TypedTextSanitizer {
    public static func sanitize(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var inBreakRun = false
        for scalar in text.unicodeScalars {
            if isLineBreakOrTab(scalar) {
                if !inBreakRun {
                    output.append(" ")
                    inBreakRun = true
                }
                continue
            }
            inBreakRun = false
            if isDroppedControl(scalar) { continue }
            output.append(scalar)
        }
        return String(output)
    }

    /// LF, VT, FF, CR, NEL, LINE SEPARATOR, PARAGRAPH SEPARATOR, and TAB.
    private static func isLineBreakOrTab(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }

    /// Remaining C0 controls, DEL, and C1 controls.
    private static func isDroppedControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F, 0x80...0x9F:
            return true
        default:
            return false
        }
    }
}

/// Splits text into pieces small enough for one keyboard event.
///
/// A keyboard event carries at most 20 UTF-16 code units of Unicode string.
/// Chunks are cut on grapheme-cluster boundaries so a combining sequence or
/// emoji is delivered in one event; a single cluster larger than the limit
/// (pathological) is cut on UTF-16 boundaries without splitting a surrogate
/// pair.
public enum TypedTextChunker {
    public static let maxUTF16UnitsPerChunk = 20

    public static func chunks(of text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentUnits = 0

        func flush() {
            if !current.isEmpty {
                chunks.append(current)
                current = ""
                currentUnits = 0
            }
        }

        for character in text {
            let units = character.utf16.count
            if units > maxUTF16UnitsPerChunk {
                flush()
                chunks.append(contentsOf: splitOversizedCluster(character))
                continue
            }
            if currentUnits + units > maxUTF16UnitsPerChunk {
                flush()
            }
            current.append(character)
            currentUnits += units
        }
        flush()
        return chunks
    }

    private static func splitOversizedCluster(_ character: Character) -> [String] {
        let units = Array(String(character).utf16)
        var pieces: [String] = []
        var start = 0
        while start < units.count {
            var end = min(start + maxUTF16UnitsPerChunk, units.count)
            // Never end a piece on a high surrogate; its low surrogate must
            // travel in the same event or the text arrives corrupted.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) {
                end -= 1
            }
            pieces.append(String(decoding: units[start..<end], as: UTF16.self))
            start = end
        }
        return pieces
    }
}
