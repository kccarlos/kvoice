import Foundation
import KvoiceDomain

/// The Control-Center-style status panel (P-D4, 2026-09-16) as a pure
/// projection of three inputs — the header row's projected
/// `StatusMenuHeaderState`, the `StatusMenuHeaderContext` behind it, and
/// the shell's `StatusPanelContext` — rendered by `StatusPanelView`.
/// Equatable so tests pin every phase and the view skips unchanged states.
///
/// The header row is *the same projection the menu's header row uses*: the
/// title, the indicator, the finishing badge, and the trailing slot, whose
/// `.meter` case is produced for `.recording` with capture started and for
/// nothing else. That is how the product rule reaches the panel — **the
/// meter and the clock exist only while a job is recording** — and why
/// this type takes a `StatusMenuHeaderState` rather than a level of its
/// own: there is no path by which an idle panel can show a level.
public struct StatusPanelState: Equatable, Sendable {
    /// A row of the panel: a command row (Copy Last Transcription, the
    /// foot rows), a value row with a chooser (Model, Language, …), or the
    /// AI switch. `id` is stable per role so the view and the focus order
    /// can address it.
    public struct Row: Equatable, Sendable, Identifiable {
        public enum ID: String, CaseIterable, Hashable, Sendable {
            // Under the header, in the menu's order
            case cancel, copyTranscript, insertTranscriptAgain, fix, copyLastTranscription, unloadModel
            // Dictation value rows
            case model, language, microphone
            // AI
            case aiSwitch, defaultAction, configuration
            // Foot, in the menu's App-group order
            case history, settings, setupGuide, help, about, quit
        }

        public let id: ID
        /// SF Symbol for the leading icon; nil for a text-only foot row.
        public let symbol: String?
        public let title: String
        /// The right-aligned value of a value row ("Whisper large-v3-turbo").
        public let value: String?
        /// A key-cap after the value or title: the foot rows' ⌘H / ⌘, / ⌘Q,
        /// the default action's ⌘1. Drawn, never a live key equivalent
        /// (`StatusPanelKeyEquivalents` routes the real keys).
        public let keyCap: String?
        public let isEnabled: Bool
        public let help: String?
        /// Orange tint: the row is a fix for a blocked prerequisite.
        public let isAttention: Bool
        /// What a click sends; nil for a chooser row, whose choices carry
        /// their own commands.
        public let command: StatusPanelCommand?
        public let chooser: StatusPanelChooser?

        public init(
            id: ID,
            symbol: String? = nil,
            title: String,
            value: String? = nil,
            keyCap: String? = nil,
            isEnabled: Bool = true,
            help: String? = nil,
            isAttention: Bool = false,
            command: StatusPanelCommand? = nil,
            chooser: StatusPanelChooser? = nil
        ) {
            self.id = id
            self.symbol = symbol
            self.title = title
            self.value = value
            self.keyCap = keyCap
            self.isEnabled = isEnabled
            self.help = help
            self.isAttention = isAttention
            self.command = command
            self.chooser = chooser
        }

        /// "Model, Whisper large-v3-turbo" — the VoiceOver label plus value,
        /// which is also what a menu item with the value in its title reads.
        public var accessibilityLabel: String {
            var parts = [title]
            if let value { parts.append(value) }
            if let keyCap { parts.append(keyCap) }
            return parts.joined(separator: ", ")
        }
    }

    /// The row under the primary control's title and readiness line.
    public enum Feed: Equatable, Sendable {
        case none
        /// The level bar and m:ss clock — recording with capture started only.
        case meter(level: Double, elapsed: Duration)
        /// The progress bar and "Downloading <model>… 42%"; nil is indeterminate.
        case download(label: String, fraction: Double?)
    }

    /// The primary control's icon and tint.
    public enum PrimaryGlyph: Equatable, Sendable {
        /// `mic.fill` on the accent: Start Recording.
        case start
        /// `mic.fill` on the accent, pulsing: the input route is coming up.
        case starting
        /// `stop.fill` on red: Stop Recording.
        case stop
        /// A spinner (hourglass under Reduce Motion): a job is finishing.
        case working
        /// `checkmark`: the last job inserted; the row dismisses it.
        case done
        /// `exclamationmark`: a prerequisite is missing or the job ended
        /// without inserting.
        case attention
    }

    public let header: StatusMenuHeaderState
    public let primaryGlyph: PrimaryGlyph
    /// "Start Recording", "Stop Recording", "Finishing…", "Dismiss", … — the
    /// header's title, i.e. the plain item's verb.
    public var primaryTitle: String { header.title }
    public var primaryIsEnabled: Bool { header.isEnabled }
    /// The line under the title: "Ready · Whisper large-v3-turbo",
    /// "Recording · MacBook Pro Microphone", "Model not ready", the phase
    /// word, the outcome.
    public let readiness: String
    /// Orange: the readiness line names a blocked prerequisite.
    public let readinessIsAttention: Bool
    /// The global shortcut as key-caps (["⌃", "⇧", "Space"]) while idle
    /// with a confirmed shortcut; empty otherwise.
    public let shortcutKeys: [String]
    /// "No Shortcut" / "Shortcut Unavailable" in the key-cap slot while
    /// idle without a confirmed shortcut.
    public let shortcutNote: String?
    public let feed: Feed
    /// The rows under the feed, in the menu's order: Cancel / Use Raw
    /// Transcript Now while a job runs, Copy Transcript and Insert
    /// Transcript Again while a failure keeps the text, Fix in … while
    /// blocked, Copy Last Transcription while idle, Unload Model Now under
    /// critical memory pressure.
    public let dictationRows: [Row]
    public let modelRow: Row
    public let languageRow: Row
    public let microphoneRow: Row
    /// Use AI Actions: the switch's row (title, help, enabled) and position.
    public let aiSwitch: Row
    public let aiIsOn: Bool
    public let defaultActionRow: Row
    public let configurationRow: Row
    public let footRows: [Row]

    public init(
        header: StatusMenuHeaderState,
        primaryGlyph: PrimaryGlyph,
        readiness: String,
        readinessIsAttention: Bool = false,
        shortcutKeys: [String] = [],
        shortcutNote: String? = nil,
        feed: Feed = .none,
        dictationRows: [Row] = [],
        modelRow: Row,
        languageRow: Row,
        microphoneRow: Row,
        aiSwitch: Row,
        aiIsOn: Bool,
        defaultActionRow: Row,
        configurationRow: Row,
        footRows: [Row]
    ) {
        self.header = header
        self.primaryGlyph = primaryGlyph
        self.readiness = readiness
        self.readinessIsAttention = readinessIsAttention
        self.shortcutKeys = shortcutKeys
        self.shortcutNote = shortcutNote
        self.feed = feed
        self.dictationRows = dictationRows
        self.modelRow = modelRow
        self.languageRow = languageRow
        self.microphoneRow = microphoneRow
        self.aiSwitch = aiSwitch
        self.aiIsOn = aiIsOn
        self.defaultActionRow = defaultActionRow
        self.configurationRow = configurationRow
        self.footRows = footRows
    }

    // MARK: Projection

    public init(header: StatusMenuHeaderState, headerContext: StatusMenuHeaderContext, context: StatusPanelContext) {
        let kind = headerContext.dictationKind
        let terminating = headerContext.isTerminating
        let idle = kind == .idle

        // The feed is the header's trailing slot: `.meter` only for a live
        // recording, `.download` only while idle with an install running.
        let feed: Feed
        switch header.trailing {
        case .meter(let level, let elapsed):
            feed = .meter(level: level, elapsed: elapsed)
        case .download(let label, let fraction):
            feed = .download(label: label, fraction: fraction)
        case .none, .shortcut, .note:
            feed = .none
        }

        let glyph: PrimaryGlyph
        let readiness: String
        var readinessIsAttention = false
        switch header.indicator {
        case .idle:
            glyph = .start
            if kind == .terminating {
                readiness = ""
            } else if context.isBlocked {
                readiness = context.readinessTitle
                readinessIsAttention = true
            } else {
                readiness = Self.joined(context.readinessTitle, context.modelName)
            }
        case .attention where idle:
            glyph = .attention
            readiness = context.readinessTitle
            readinessIsAttention = true
        case .starting:
            glyph = .starting
            readiness = context.microphoneName
        case .live:
            glyph = .stop
            readiness = Self.joined(String(localized: "Recording", bundle: .module), context.microphoneName)
        case .working:
            glyph = .working
            if case .note(let word) = header.trailing {
                readiness = String(localized: "\(word)…", bundle: .module)
            } else {
                readiness = ""
            }
        case .done, .attention:
            glyph = header.indicator == .done ? .done : .attention
            if case .note(let note) = header.trailing {
                readiness = note
            } else {
                readiness = ""
            }
        }

        // The rows under the feed, in the menu's order and with the menu's
        // visibility and enabled rules (`updateMenu(for:)`).
        var rows: [Row] = []
        switch kind {
        case .recording, .finalizing, .transcribing, .processingAI, .inserting:
            rows.append(Row(
                id: .cancel,
                symbol: "xmark.circle",
                title: kind == .processingAI
                    ? String(localized: "Use Raw Transcript Now", bundle: .module)
                    : String(localized: "Cancel Current Dictation", bundle: .module),
                isEnabled: kind != .inserting && !terminating,
                command: .cancelCurrentDictation
            ))
        case .idle, .completed, .failed, .blocked, .terminating:
            break
        }
        if context.canRecoverFailedInsertion {
            rows.append(Row(
                id: .copyTranscript,
                symbol: "doc.on.clipboard",
                title: String(localized: "Copy Transcript", bundle: .module),
                isEnabled: !terminating,
                help: String(localized: "Copies the transcript the last dictation kept after it could not be inserted.", bundle: .module),
                command: .copyTranscript
            ))
            rows.append(Row(
                id: .insertTranscriptAgain,
                symbol: "text.insert",
                title: String(localized: "Insert Transcript Again", bundle: .module),
                isEnabled: !terminating,
                help: String(localized: "Inserts the kept transcript into the app that is in front now.", bundle: .module),
                command: .insertTranscriptAgain
            ))
        }
        if context.isBlocked {
            rows.append(Row(
                id: .fix,
                symbol: "wrench.and.screwdriver",
                title: context.fixTitle,
                isEnabled: !terminating,
                isAttention: true,
                command: .openStatusTarget
            ))
        } else if idle {
            // Request: Copy Last Transcription stays reachable here.
            rows.append(Row(
                id: .copyLastTranscription,
                symbol: "doc.on.doc",
                title: String(localized: "Copy Last Transcription", bundle: .module),
                isEnabled: context.canCopyLastTranscription && !terminating,
                help: context.copyLastTranscriptionHelp,
                command: .copyLastTranscription
            ))
        }
        if let pressure = context.memoryPressure {
            rows.append(Row(
                id: .unloadModel,
                symbol: "memorychip",
                title: pressure.isUnloading
                    ? String(localized: "Unloading Model…", bundle: .module)
                    : String(localized: "Unload Model Now", bundle: .module),
                isEnabled: pressure.canUnloadNow && !terminating,
                command: .unloadModel
            ))
        }

        let shortcutKeys = idle ? Self.keyCaps(headerContext.shortcutGlyphs) : []
        let shortcutNote = idle && headerContext.shortcutGlyphs == nil ? headerContext.shortcutNote : nil

        let ai = context.ai
        let none = String(localized: "None", bundle: .module)
        self.init(
            header: header,
            primaryGlyph: glyph,
            readiness: readiness,
            readinessIsAttention: readinessIsAttention,
            shortcutKeys: shortcutKeys,
            shortcutNote: shortcutNote,
            feed: feed,
            dictationRows: rows,
            modelRow: Row(
                id: .model, symbol: "waveform",
                title: String(localized: "Model", bundle: .module),
                value: context.modelName,
                isEnabled: context.canOpenChoosers,
                chooser: context.modelChooser
            ),
            languageRow: Row(
                id: .language, symbol: "globe",
                title: String(localized: "Language", bundle: .module),
                value: context.languageName,
                isEnabled: context.canOpenChoosers,
                chooser: context.languageChooser
            ),
            microphoneRow: Row(
                id: .microphone, symbol: "mic",
                title: String(localized: "Microphone", bundle: .module),
                value: context.microphoneName,
                isEnabled: context.canOpenChoosers,
                chooser: context.microphoneChooser
            ),
            aiSwitch: Row(
                id: .aiSwitch, symbol: "sparkles",
                title: String(localized: "Use AI Actions", bundle: .module),
                isEnabled: ai.canToggle,
                help: ai.help,
                command: .toggleAI
            ),
            aiIsOn: ai.isOn,
            defaultActionRow: Row(
                id: .defaultAction, symbol: "text.badge.checkmark",
                title: String(localized: "Default Action", bundle: .module),
                value: ai.defaultActionName ?? none,
                keyCap: ai.defaultActionBadge,
                isEnabled: ai.canChoose,
                chooser: ai.defaultActions
            ),
            configurationRow: Row(
                id: .configuration, symbol: "server.rack",
                title: String(localized: "Configuration", bundle: .module),
                value: ai.configurationName ?? none,
                isEnabled: ai.canChoose,
                chooser: ai.configurations
            ),
            footRows: [
                Row(id: .history, title: context.historyTitle, keyCap: "⌘H", isEnabled: !terminating, help: context.historyHelp, command: .openHistory),
                Row(id: .settings, title: String(localized: "Settings…", bundle: .module), keyCap: "⌘,", isEnabled: !terminating, command: .openSettings),
                Row(id: .setupGuide, title: String(localized: "Setup Guide…", bundle: .module), isEnabled: !terminating, command: .openSetup),
                Row(id: .help, title: String(localized: "Help", bundle: .module), isEnabled: !terminating, command: .openHelp),
                Row(id: .about, title: String(localized: "About", bundle: .module), isEnabled: !terminating, command: .showAbout),
                Row(id: .quit, title: String(localized: "Quit KVoice", bundle: .module), keyCap: "⌘Q", isEnabled: true, command: .quit),
            ]
        )
    }

    /// "Ready · Whisper large-v3-turbo"; either side may be empty.
    static func joined(_ lead: String, _ trail: String) -> String {
        switch (lead.isEmpty, trail.isEmpty) {
        case (true, true): return ""
        case (false, true): return lead
        case (true, false): return trail
        case (false, false): return "\(lead) · \(trail)"
        }
    }

    /// "⌃⇧Space" → ["⌃", "⇧", "Space"]: each modifier glyph its own cap, the
    /// key the last. The glyph string is `GeneralSettingsViewModel.glyphs(for:)`'s
    /// (modifiers in Apple's fixed order, then the key; "fn" is the one
    /// multi-character modifier). A modifier-only shortcut ("Right Option")
    /// is one cap.
    static func keyCaps(_ glyphs: String?) -> [String] {
        guard let glyphs, !glyphs.isEmpty else { return [] }
        var caps: [String] = []
        var rest = Substring(glyphs)
        while let first = rest.first {
            if "⌃⌥⇧⌘⇪".contains(first) {
                caps.append(String(first))
                rest = rest.dropFirst()
            } else if rest.hasPrefix("fn"), rest.count > 2 {
                caps.append("fn")
                rest = rest.dropFirst(2)
            } else {
                break
            }
        }
        if !rest.isEmpty {
            caps.append(String(rest))
        }
        return caps
    }

    /// The whole header as one VoiceOver label — "Start Recording, Ready ·
    /// Whisper large-v3-turbo, ⌃⇧Space" — so the primary control reads its
    /// command, the readiness, and the shortcut in one pass.
    public var primaryAccessibilityLabel: String {
        var parts = [primaryTitle]
        if let badge = header.finishingBadge { parts.append(badge) }
        if !readiness.isEmpty { parts.append(readiness) }
        if !shortcutKeys.isEmpty { parts.append(shortcutKeys.joined()) }
        if let shortcutNote { parts.append(shortcutNote) }
        switch feed {
        case .meter(_, let elapsed): parts.append(HUDViewState.formatElapsed(elapsed))
        case .download(let label, _): parts.append(label)
        case .none: break
        }
        return parts.joined(separator: ", ")
    }

    /// Every row in the panel's reading and focus order: the primary
    /// control first, then the dictation rows, the value rows, the AI
    /// block, and the foot. `StatusPanelModel.moveFocus` walks the enabled
    /// ones.
    public var rowsInOrder: [Row] {
        dictationRows + [modelRow, languageRow, microphoneRow, aiSwitch, defaultActionRow, configurationRow] + footRows
    }

    /// Everything that changes the panel's *layout* — which rows exist,
    /// which feed row, the primary's shape — and nothing that ticks: the
    /// level and the clock are left out so the view's row animation is not
    /// retriggered 20 times a second while recording.
    public struct LayoutSignature: Equatable, Sendable {
        public let primaryGlyph: PrimaryGlyph
        public let primaryTitle: String
        public let hasReadiness: Bool
        public let feedKind: Int
        public let rows: [Row.ID]
    }

    public var layoutSignature: LayoutSignature {
        let feedKind: Int
        switch feed {
        case .none: feedKind = 0
        case .meter: feedKind = 1
        case .download: feedKind = 2
        }
        return LayoutSignature(
            primaryGlyph: primaryGlyph,
            primaryTitle: primaryTitle,
            hasReadiness: !readiness.isEmpty,
            feedKind: feedKind,
            rows: rowsInOrder.map(\.id)
        )
    }

    /// True while the panel shows a level: the testable form of the
    /// no-meter-outside-a-recording rule at the panel's seam.
    public var showsMeter: Bool {
        if case .meter = feed { return true }
        return false
    }
}
