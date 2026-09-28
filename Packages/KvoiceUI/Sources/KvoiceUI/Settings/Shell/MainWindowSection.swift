import Foundation

/// The sidebar groups of the one main window, top to bottom (product
/// decision #7 as regrouped on 2026-09-13): what dictation does, the
/// optional AI layer, what kvoice keeps, and the app itself.
public enum MainWindowSectionGroup: String, CaseIterable, Sendable, Identifiable {
    case dictation
    case ai
    case data
    case app

    public var id: Self { self }

    public var title: String {
        switch self {
        case .dictation: return String(localized: "Dictation", bundle: .module)
        case .ai: return String(localized: "AI", bundle: .module)
        case .data: return String(localized: "Data", bundle: .module)
        case .app: return String(localized: "App", bundle: .module)
        }
    }

    /// The sections under this heading, in sidebar order.
    public var sections: [MainWindowSection] {
        MainWindowSection.allCases.filter { $0.group == self }
    }
}

/// The sidebar of the one main window, top to bottom. The raw value is what
/// `LocalState.mainWindowSection` stores, so renaming a case is a
/// persisted-settings change; `init(persisted:)` maps retired values.
///
/// `allCases` is the sidebar order, grouped by `group`; keep the two in step.
public enum MainWindowSection: String, CaseIterable, Codable, Sendable, Equatable, Identifiable {
    // Dictation
    case shortcuts
    case recording
    case models
    /// The user dictionary fed to the model as its initial prompt (ADR-018).
    case dictionary
    case audioInput
    // AI
    case aiActions
    // Data
    case history
    case dataPrivacy
    // App
    case general
    case permissions
    case help

    public var id: Self { self }

    /// The section opened when nothing has been chosen yet.
    public static let `default`: MainWindowSection = .history

    /// Where "Settings…" (⌘,) lands: the first settings page in the sidebar.
    /// Settings are spread over the Dictation and App groups, so the menu
    /// item opens the top of that range rather than a page named Settings.
    public static let settingsEntry: MainWindowSection = .shortcuts

    public var group: MainWindowSectionGroup {
        switch self {
        case .shortcuts, .recording, .models, .dictionary, .audioInput: return .dictation
        case .aiActions: return .ai
        case .history, .dataPrivacy: return .data
        case .general, .permissions, .help: return .app
        }
    }

    public var title: String {
        switch self {
        case .shortcuts: return String(localized: "Shortcuts", bundle: .module)
        case .recording: return String(localized: "Recording", bundle: .module)
        case .models: return String(localized: "Speech Models", bundle: .module)
        case .dictionary: return String(localized: "Dictionary", bundle: .module)
        case .audioInput: return String(localized: "Microphone", bundle: .module)
        case .aiActions: return String(localized: "AI Actions", bundle: .module)
        case .history: return String(localized: "History", bundle: .module)
        case .dataPrivacy: return String(localized: "Data & Privacy", bundle: .module)
        case .general: return String(localized: "General", bundle: .module)
        case .permissions: return String(localized: "Permissions", bundle: .module)
        case .help: return String(localized: "Help", bundle: .module)
        }
    }

    public var symbolName: String {
        switch self {
        case .shortcuts: return "keyboard"
        case .recording: return "record.circle"
        case .models: return "waveform"
        case .dictionary: return "character.book.closed"
        case .audioInput: return "mic"
        case .aiActions: return "sparkles"
        case .history: return "clock.arrow.circlepath"
        case .dataPrivacy: return "lock.shield"
        case .general: return "gearshape"
        case .permissions: return "checkmark.shield"
        case .help: return "questionmark.circle"
        }
    }

    /// One sentence under the title saying what the section is for.
    public var purpose: String {
        switch self {
        case .shortcuts: return String(localized: "The keys and buttons that start, stop, and cancel a dictation.", bundle: .module)
        case .recording: return String(localized: "What happens while you record and how the finished text is inserted.", bundle: .module)
        case .models: return String(localized: "The local speech models that transcribe your voice on this Mac.", bundle: .module)
        case .dictionary: return String(localized: "Names and jargon the model should spell your way. Sent as a hint with every dictation.", bundle: .module)
        case .audioInput: return String(localized: "Which microphone KVoice listens to while you dictate.", bundle: .module)
        case .aiActions: return String(localized: "Optional polish and translation, and the endpoint that runs them. Off by default.", bundle: .module)
        case .history: return String(localized: "Every dictation KVoice saved, newest first, with the raw and final text.", bundle: .module)
        case .dataPrivacy: return String(localized: "What KVoice keeps on this Mac, for how long, and where it is exported.", bundle: .module)
        case .general: return String(localized: "How KVoice appears on this Mac, the setup guide, and the reset tools.", bundle: .module)
        case .permissions: return String(localized: "What KVoice needs from macOS, and whether it has it right now.", bundle: .module)
        case .help: return String(localized: "Guides, feedback, and acknowledgments.", bundle: .module)
        }
    }

    /// Decodes a persisted raw value, mapping the raw values of retired
    /// sections to their closest replacement and falling back to the default
    /// section for nil or a value this build does not know.
    public init(persisted rawValue: String?) {
        guard let rawValue else {
            self = .default
            return
        }
        if let section = MainWindowSection(rawValue: rawValue) {
            self = section
        } else if let replacement = Self.retiredRawValues[rawValue] {
            self = replacement
        } else {
            self = .default
        }
    }

    /// Raw values older builds stored, and where they land now. "settings"
    /// was one page holding Shortcuts, Recording, General, and Data &
    /// Privacy; it opens on the first of those.
    static let retiredRawValues: [String: MainWindowSection] = [
        "settings": .shortcuts
    ]
}
