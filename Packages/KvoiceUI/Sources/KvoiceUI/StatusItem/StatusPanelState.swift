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
            case cancel, copyTranscript, insertTranscriptAgain, fix, copyLastTranscription, unloadModel, pauseDownload
            // Dictation value rows
            case model, language, microphone
            // AI
            case aiSwitch, defaultAction, configuration
            // UI v2 fidelity F1: the idle card's "Set Shortcut…" link
            case setShortcut
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
        /// UI v2: the word on the row's button in the top card ("Cancel",
        /// "Copy", "Insert Again"); nil uses `title`. VoiceOver keeps
        /// reading the full `title`.
        public let shortTitle: String?
        /// UI v2: how the row's button in the top card is drawn.
        public let emphasis: Emphasis

        public enum Emphasis: Equatable, Sendable {
            /// Outlined, on the surface.
            case plain
            /// Cursor-blue fill: the one thing to do next.
            case primary
            /// Warn-soft fill with warn ink: the fix for a blocked prerequisite.
            case warn
        }

        /// The word drawn on the button.
        public var buttonTitle: String { shortTitle ?? title }

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
            chooser: StatusPanelChooser? = nil,
            shortTitle: String? = nil,
            emphasis: Emphasis = .plain
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
            self.shortTitle = shortTitle
            self.emphasis = emphasis
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
        /// The progress bar under "Downloading <model>…", with the percent
        /// drawn apart (`percentText`); nil is indeterminate.
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

    /// UI v2: the top card's ground — voice while a recording is live, warn
    /// while a prerequisite blocks the next one, an err edge when a job
    /// ended without inserting; plain otherwise.
    public enum CardTone: Equatable, Sendable {
        case plain
        case voice
        case warn
        case err
    }

    /// UI v2: the idle card's preview of the newest history entry.
    public typealias LastTranscription = StatusPanelContext.LastTranscription

    public let header: StatusMenuHeaderState
    public let primaryGlyph: PrimaryGlyph
    /// After a job: the recorder's own glyph for the outcome (cursor check,
    /// amber clipboard, red mark), so the panel and the HUD say it the same
    /// way. Nil before and during a job.
    public let outcomeGlyph: HUDGlyph?
    public let cardTone: CardTone
    /// The readiness line as a `StatusPill` in this tone, or nil for plain
    /// secondary text (recording, finishing: the card already says it).
    public let readinessTone: KVTone?
    /// Idle and not blocked, with a saved transcription to show.
    public let lastTranscription: LastTranscription?
    /// UI v2 fidelity F1: the words the card shows under the title after a
    /// job — what went in ("Inserted"), or the kept transcript ("Not
    /// inserted — transcript kept"). Nil otherwise.
    public let resultText: String?
    /// UI v2 fidelity F1: "Set Shortcut…" — the idle card's link to the
    /// Shortcuts page while no shortcut works. Nil otherwise.
    public let shortcutLink: Row?
    /// The card's title: the header's verb ("Start Recording", "Stop
    /// Recording", "Finishing…"), except after a job, where the design
    /// names the outcome ("Inserted", "Copied to clipboard", "Not inserted
    /// — transcript kept") and the click still dismisses
    /// (`primaryActionTitle`).
    public let primaryTitle: String
    /// The verb the primary control performs — the header's title, which
    /// the right-click menu's header row also shows ("Dismiss").
    public var primaryActionTitle: String { header.title }
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
        outcomeGlyph: HUDGlyph? = nil,
        cardTone: CardTone = .plain,
        readinessTone: KVTone? = nil,
        lastTranscription: LastTranscription? = nil,
        primaryTitle: String? = nil,
        resultText: String? = nil,
        shortcutLink: Row? = nil,
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
        self.outcomeGlyph = outcomeGlyph
        self.cardTone = cardTone
        self.readinessTone = readinessTone
        self.lastTranscription = lastTranscription
        self.primaryTitle = primaryTitle ?? header.title
        self.resultText = resultText
        self.shortcutLink = shortcutLink
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

    /// `hud` is the recorder's rendered state, the one `header` was
    /// projected from; it only supplies the outcome glyph after a job.
    public init(
        header: StatusMenuHeaderState,
        headerContext: StatusMenuHeaderContext,
        context: StatusPanelContext,
        hud: HUDViewState = .idle
    ) {
        let kind = headerContext.dictationKind
        let terminating = headerContext.isTerminating
        let idle = kind == .idle

        // The feed is the header's trailing slot: `.meter` only for a live
        // recording, `.download` only while idle with an install running.
        // The card draws the percent apart from the words, so the label is
        // the header's without the figure.
        let feed: Feed
        switch header.trailing {
        case .meter(let level, let elapsed):
            feed = .meter(level: level, elapsed: elapsed)
        case .download(let label, let fraction):
            let words = headerContext.modelInstall.map {
                StatusMenuHeaderState.downloadLabel(.init(modelName: $0.modelName, fraction: nil))
            } ?? label
            feed = .download(label: words, fraction: fraction)
        case .none, .shortcut, .note:
            feed = .none
        }

        let glyph: PrimaryGlyph
        let headerReadiness: String
        var readinessIsAttention = false
        switch header.indicator {
        case .idle:
            glyph = .start
            if kind == .terminating {
                headerReadiness = ""
            } else if context.isBlocked {
                headerReadiness = context.readinessTitle
                readinessIsAttention = true
            } else {
                headerReadiness = Self.joined(context.readinessTitle, context.modelName)
            }
        case .attention where idle:
            glyph = .attention
            headerReadiness = context.readinessTitle
            readinessIsAttention = true
        case .starting:
            glyph = .starting
            headerReadiness = context.microphoneName
        case .live:
            glyph = .stop
            headerReadiness = Self.joined(String(localized: "Recording", bundle: .module), context.microphoneName)
        case .working:
            glyph = .working
            if case .processingAI(let ai) = hud.phase {
                // The design names the step and the action: "Polishing
                // with Clean Up…", "Translating to French…". The action is
                // the running job's (the recorder's ⌘digit switches it for
                // this job only, Q2b), the same name the recorder's badge
                // shows; the saved default only when the HUD names none.
                if ai.mode != .translate, let action = hud.processingBadge ?? context.ai.defaultActionName {
                    headerReadiness = String(localized: "Polishing with \(action)…", bundle: .module)
                } else {
                    headerReadiness = String(localized: "\(hud.title)…", bundle: .module)
                }
            } else if case .note(let word) = header.trailing {
                headerReadiness = String(localized: "\(word)…", bundle: .module)
            } else {
                headerReadiness = ""
            }
        case .done, .attention:
            glyph = header.indicator == .done ? .done : .attention
            if case .note(let note) = header.trailing {
                headerReadiness = note
            } else {
                headerReadiness = ""
            }
        }

        // UI v2: the card's ground and the readiness line's tone.
        var outcomeGlyph: HUDGlyph?
        var cardTone = CardTone.plain
        var readinessTone: KVTone?
        var readiness = headerReadiness
        var title = header.title
        var resultText: String?
        switch kind {
        case .idle:
            if readinessIsAttention {
                // A download is the fix happening: amber words, plain card.
                if case .download = feed {} else { cardTone = .warn }
                readinessTone = .warn
            } else if context.memoryPressure != nil, !context.isBlocked {
                // Advisory, not blocking: the design's amber subtitle.
                readiness = String(localized: "Memory pressure — dictation may be slower", bundle: .module)
                readinessTone = .warn
            } else if !readiness.isEmpty {
                readinessTone = .ok
            }
        case .recording:
            cardTone = glyph == .stop ? .voice : .plain
        case .completed, .failed, .blocked:
            switch hud.phase {
            case .completed, .failed, .blocked:
                outcomeGlyph = hud.glyph
            default:
                outcomeGlyph = nil
            }
            let tone = outcomeGlyph?.tone ?? (glyph == .done ? .cursor : .warn)
            if tone == .err { cardTone = .err }
            readinessTone = tone == .warn || tone == .err ? tone : .neutral
            // UI v2 fidelity F1: the outcome is the title; the subtitle
            // says what went where (or why not), the card shows the words.
            if !hud.title.isEmpty, outcomeGlyph != nil {
                title = hud.title
                let result = context.jobResult
                switch hud.phase {
                case .completed(let completion):
                    switch completion.kind {
                    case .success, .aiFallback:
                        if completion.kind == .aiFallback || completion.durationCapReached,
                           let warning = hud.detail, !warning.isEmpty {
                            readiness = warning
                        } else {
                            readiness = Self.insertedLine(words: result?.wordCount, app: result?.appName) ?? ""
                        }
                        resultText = result?.text
                    case .clipboardFallback:
                        // F5: the recorder's line — why, and the one key
                        // that finishes the job — so the two never differ.
                        readiness = HUDViewState.clipboardLine(completion.clipboardReason)
                    }
                case .blocked:
                    // "KVoice needs attention" is the title; the reason
                    // ("Microphone access is off") is the subtitle.
                    readiness = hud.detail ?? ""
                case .failed:
                    readiness = hud.detail ?? ""
                    resultText = hud.recoverableTranscript.map {
                        StatusPanelContext.LastTranscription(text: $0, createdAt: .distantPast).text
                    }
                default:
                    break
                }
            }
        case .finalizing, .transcribing, .processingAI, .inserting, .terminating:
            break
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
                command: .cancelCurrentDictation,
                // The design's "Cancel  ⎋" while recording (plain "Cancel"
                // while the mic comes up): Escape cancels a recording once
                // the panel is closed.
                shortTitle: kind == .processingAI
                    ? nil
                    : kind == .recording && header.indicator == .live
                        ? String(localized: "Cancel", bundle: .module) + "  ⎋"
                        : String(localized: "Cancel", bundle: .module)
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
                command: .copyTranscript,
                shortTitle: String(localized: "Copy", bundle: .module)
            ))
            rows.append(Row(
                id: .insertTranscriptAgain,
                symbol: "text.insert",
                title: String(localized: "Insert Transcript Again", bundle: .module),
                isEnabled: !terminating,
                help: String(localized: "Inserts the kept transcript into the app that is in front now.", bundle: .module),
                command: .insertTranscriptAgain,
                shortTitle: String(localized: "Insert Again", bundle: .module),
                emphasis: .primary
            ))
        }
        if context.isBlocked {
            rows.append(Row(
                id: .fix,
                symbol: "wrench.and.screwdriver",
                title: context.fixTitle,
                isEnabled: !terminating,
                isAttention: true,
                command: .openStatusTarget,
                emphasis: .warn
            ))
        } else if idle {
            // Request: Copy Last Transcription stays reachable here.
            rows.append(Row(
                id: .copyLastTranscription,
                symbol: "doc.on.doc",
                title: String(localized: "Copy Last Transcription", bundle: .module),
                isEnabled: context.canCopyLastTranscription && !terminating,
                help: context.copyLastTranscriptionHelp,
                command: .copyLastTranscription,
                shortTitle: String(localized: "Copy", bundle: .module)
            ))
        }
        // UI v2: Pause, only while bytes are flowing — the shell sets
        // `pausableDownload` for that and nothing else (cancelling a
        // verification or a first load throws the work away; cancelling a
        // download pauses it, and Speech Models offers Resume).
        if idle, case .download = feed, let id = context.pausableDownload {
            rows.append(Row(
                id: .pauseDownload,
                symbol: "pause.circle",
                title: String(localized: "Pause Download", bundle: .module),
                isEnabled: !terminating,
                help: String(localized: "Pauses the download; resume it in Speech Models.", bundle: .module),
                command: .pauseModelDownload(id),
                shortTitle: String(localized: "Pause", bundle: .module)
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

        // UI v2 fidelity F1: the caps only on a card that can start now —
        // not while blocked (the fix is the one thing to do).
        let shortcutKeys = idle && !context.isBlocked ? Self.keyCaps(headerContext.shortcutGlyphs) : []
        let shortcutNote = idle && !context.isBlocked && headerContext.shortcutGlyphs == nil ? headerContext.shortcutNote : nil
        let shortcutLink = shortcutNote.map { note in
            Row(
                id: .setShortcut,
                title: String(localized: "Set Shortcut…", bundle: .module),
                isEnabled: !terminating,
                help: note,
                command: .openShortcuts
            )
        }

        let ai = context.ai
        let none = String(localized: "None", bundle: .module)
        let lastTranscription = idle && !context.isBlocked
            ? context.lastTranscription
            : nil

        self.init(
            header: header,
            primaryGlyph: glyph,
            outcomeGlyph: outcomeGlyph,
            cardTone: cardTone,
            readinessTone: readinessTone,
            lastTranscription: lastTranscription,
            primaryTitle: title,
            resultText: resultText,
            shortcutLink: shortcutLink,
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
                // UI v2 fidelity F1: the switch is drawn as the "Off" chip,
                // so it acts only while AI is on (an Off that is already
                // lit has nothing to do).
                command: ai.isOn ? .toggleAI : nil,
                shortTitle: String(localized: "Off", bundle: .module)
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

    /// "38 words → Notes" — the recorder's line (`HUDViewState.insertedLine`).
    static func insertedLine(words: Int?, app: String?) -> String? {
        HUDViewState.insertedLine(words: words, app: app)
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
        case .download(let label, let fraction):
            parts.append(label)
            if let percent = Self.percentText(fraction) { parts.append(percent) }
        case .none: break
        }
        // After a job the title names the outcome; the control's verb
        // ("Dismiss") is still what a click does, so VoiceOver says it.
        if primaryActionTitle != primaryTitle, primaryIsEnabled {
            parts.append(primaryActionTitle)
        }
        return parts.joined(separator: ", ")
    }

    /// "42%", floored like the header's label; nil while indeterminate.
    public static func percentText(_ fraction: Double?) -> String? {
        guard let fraction else { return nil }
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        return "\(percent)%"
    }

    /// "2 min ago", "now" — in the interface language, short units, from an
    /// injected `now` so a render is deterministic.
    public static func relativeTime(_ date: Date, now: Date, locale: Locale = LanguageNames.interfaceLocale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        // Under a minute reads "now", not a ticking seconds count.
        let interval = min(date.timeIntervalSince(now), 0)
        return formatter.localizedString(fromTimeInterval: interval > -60 ? 0 : interval)
    }

    /// The Default Action chips: the saved actions, in their order.
    public var aiChips: [StatusPanelChoice] {
        defaultActionRow.chooser?.choices ?? []
    }

    /// Every row in the panel's reading and focus order: the primary
    /// control first, then the dictation rows, the value rows, the AI
    /// block, and the foot. `StatusPanelModel.moveFocus` walks the enabled
    /// ones.
    public var rowsInOrder: [Row] {
        (shortcutLink.map { [$0] } ?? []) + dictationRows + [modelRow, languageRow, microphoneRow, aiSwitch, defaultActionRow, configurationRow] + footRows
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
        public let cardTone: CardTone
        public let hasLastTranscription: Bool
        public let hasResultText: Bool
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
            rows: rowsInOrder.map(\.id),
            cardTone: cardTone,
            hasLastTranscription: lastTranscription != nil,
            hasResultText: resultText != nil
        )
    }

    /// True while the panel shows a level: the testable form of the
    /// no-meter-outside-a-recording rule at the panel's seam.
    public var showsMeter: Bool {
        if case .meter = feed { return true }
        return false
    }
}
