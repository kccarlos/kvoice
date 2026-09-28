import AppIntents

/// The App Shortcuts kvoice offers without any setup: each appears in the
/// Shortcuts app's kvoice page and in Spotlight, and its phrases work with
/// Siri when Siri is on. Phrases must contain `\(.applicationName)` — that is
/// how the system disambiguates apps — and are localized through
/// `Resources/AppShortcuts.xcstrings`, the catalog Xcode's App Intents
/// metadata step reads for phrases (the ordinary `Shell` table does not
/// apply to them).
struct KvoiceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "Start dictation with \(.applicationName)",
                "Start \(.applicationName) dictation",
                "Start recording with \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("Start Dictation", table: "Shell"),
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopDictationIntent(),
            phrases: [
                "Stop \(.applicationName) dictation",
                "Stop recording with \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("Stop Dictation", table: "Shell"),
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: ToggleDictationIntent(),
            phrases: [
                "Toggle \(.applicationName) dictation",
                "Toggle recording with \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("Toggle Dictation", table: "Shell"),
            systemImageName: "mic.badge.plus"
        )
        AppShortcut(
            intent: CancelDictationIntent(),
            phrases: [
                "Cancel \(.applicationName) dictation",
                "Dismiss \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("Cancel Dictation", table: "Shell"),
            systemImageName: "xmark.circle"
        )
        AppShortcut(
            intent: GetLastTranscriptionIntent(),
            phrases: [
                "Get my last \(.applicationName) transcription",
                "What did I last dictate with \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("Last Transcription", table: "Shell"),
            systemImageName: "text.quote"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}
