import Foundation

/// The AI Actions vocabulary every surface shares (Q3, 2026-10-22): the
/// panel, Home, the HUD, Data & Privacy and the AI Actions page say the same
/// words for the same thing, in English and in Simplified Chinese. A surface
/// that names AI's on/off state reads it from here rather than spelling it
/// itself, so the panel's "AI Off" and Home's "AI off" cannot drift apart
/// again (`AIActionsCopyTests`).
public enum AIActionsCopy {
    /// AI processing is off: dictation inserts the raw transcript.
    public static var aiOff: String { String(localized: "AI off", bundle: .module) }

    /// AI processing is on but no action name is known.
    public static var aiOn: String { String(localized: "AI on", bundle: .module) }

    /// "Clean Up · Local Ollama": what runs and where, joined the way Home's
    /// hero chip and the AI Actions page's status line both show it. Either
    /// part may be missing; with neither, "AI on".
    public static func summary(action: String?, configuration: String?) -> String {
        let parts = [action, configuration].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? aiOn : parts.joined(separator: " · ")
    }
}
