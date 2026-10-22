import Foundation

/// The sidebar groups of the one main window, top to bottom (product
/// decision #7, regrouped by the owner on 2026-10-21 for UI v2): an
/// untitled top group (Home, History), what dictation does, the optional AI
/// layer, and the app itself (Data & Privacy, Permissions, General, Help).
public enum MainWindowSectionGroup: String, CaseIterable, Sendable, Identifiable {
    /// Home and History, with no heading above them.
    case top
    case dictation
    case ai
    case app

    public var id: Self { self }

    /// The heading over the group; nil for the untitled top group, which
    /// the sidebar draws without a header.
    public var title: String? {
        switch self {
        case .top: return nil
        case .dictation: return String(localized: "Dictation", bundle: .module)
        case .ai: return String(localized: "AI", bundle: .module)
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
    // Top (untitled)
    /// UI v2 wave 5a: the readiness hero, this week's figures and the
    /// newest dictations. Where the window opens (`opening`).
    case home
    case history
    // Dictation
    case shortcuts
    case recording
    case models
    case audioInput
    /// The user dictionary fed to the model as its initial prompt (ADR-018).
    case dictionary
    // AI
    case aiActions
    // App
    case dataPrivacy
    case permissions
    case general
    case help

    public var id: Self { self }

    /// The section a persisted value that is nil or unknown decodes to.
    public static let `default`: MainWindowSection = .home

    /// Where a newly created window opens when no entry point asked for a
    /// particular page (owner decision 2026-10-21: Home is the page the
    /// window opens on). Reopening the window within the same launch keeps
    /// the page it last showed.
    public static func opening(requested: MainWindowSection?) -> MainWindowSection {
        requested ?? .home
    }

    /// Where "Settings…" (⌘,) lands: the first settings page in the sidebar.
    /// Settings are spread over the Dictation and App groups, so the menu
    /// item opens the top of that range rather than a page named Settings.
    public static let settingsEntry: MainWindowSection = .shortcuts

    public var group: MainWindowSectionGroup {
        switch self {
        case .home, .history: return .top
        case .shortcuts, .recording, .models, .audioInput, .dictionary: return .dictation
        case .aiActions: return .ai
        case .dataPrivacy, .permissions, .general, .help: return .app
        }
    }

    public var title: String {
        switch self {
        case .home: return String(localized: "Home", bundle: .module)
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
        case .home: return "house"
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

    /// UI v2: the colour of the section's icon tile in the sidebar and the
    /// page header, by meaning — ink for Home and what KVoice kept (History); voice
    /// for sound (Recording, Speech Models, Microphone); cursor for text
    /// (Dictionary, AI Actions); ok for safety and grants (Data & Privacy,
    /// Permissions); grey for system settings (Shortcuts, General, Help).
    public var tileFill: KVColorToken {
        switch self {
        case .home, .history: return .ink
        case .recording, .models, .audioInput: return .voice
        case .dictionary, .aiActions: return .cursor
        case .dataPrivacy, .permissions: return .ok
        case .shortcuts, .general, .help: return .grey
        }
    }

    /// UI v2 fidelity F2: the design's own 16-grid tile glyph (Window.dc),
    /// drawn by `KVGlyphTile` in the sidebar and the page header.
    var designGlyph: String {
        switch self {
        case .home: return KVGlyphs.home
        case .history: return KVGlyphs.clock
        case .shortcuts: return KVGlyphs.keys
        case .recording: return KVGlyphs.rec
        case .models: return KVGlyphs.wave
        case .audioInput: return KVGlyphs.mic
        case .dictionary: return KVGlyphs.book
        case .aiActions: return KVGlyphs.spark
        case .dataPrivacy: return KVGlyphs.lock
        case .permissions: return KVGlyphs.shield
        case .general: return KVGlyphs.gear
        case .help: return KVGlyphs.help
        }
    }

    /// The design draws no page header on Home: the hero is the page's top.
    var showsPageHeader: Bool { self != .home }

    /// The drawn sidebar's arrow keys: the section `step` rows away in
    /// sidebar order, clamped at both ends (no wrap, like a list).
    static func sidebarNeighbour(of section: MainWindowSection, step: Int) -> MainWindowSection {
        let order = MainWindowSectionGroup.allCases.flatMap(\.sections)
        guard let index = order.firstIndex(of: section) else { return section }
        return order[min(max(index + step, 0), order.count - 1)]
    }

    /// The drawn sidebar's type-to-select: the first section, in sidebar
    /// order starting after `current`, whose title starts with `prefix`
    /// (case- and diacritic-insensitive). A one-letter prefix cycles through
    /// the matches, as a list does; nil when nothing matches.
    static func typeSelect(_ prefix: String, from current: MainWindowSection) -> MainWindowSection? {
        let needle = prefix.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !needle.isEmpty else { return nil }
        let order = MainWindowSectionGroup.allCases.flatMap(\.sections)
        let start = (order.firstIndex(of: current) ?? -1) + (prefix.count == 1 ? 1 : 0)
        let rotated = (0..<order.count).map { order[(start + $0 + order.count) % order.count] }
        return rotated.first {
            $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).hasPrefix(needle)
        }
    }

    /// One sentence under the title saying what the section is for.
    public var purpose: String {
        switch self {
        case .home: return String(localized: "Your shortcut, your setup, and what you dictated this week.", bundle: .module)
        case .shortcuts: return String(localized: "The keys and buttons that start, stop, and cancel a dictation.", bundle: .module)
        case .recording: return String(localized: "What happens while you record and how the finished text is inserted.", bundle: .module)
        case .models: return String(localized: "Every model runs on this Mac. Pick by what you dictate.", bundle: .module)
        case .dictionary: return String(localized: "Names and jargon the model should spell your way.", bundle: .module)
        case .audioInput: return String(localized: "Which microphone KVoice listens to while you dictate.", bundle: .module)
        case .aiActions: return String(localized: "Optional polish and translation. Off by default; only transcript text is ever sent.", bundle: .module)
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
