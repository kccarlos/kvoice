import Foundation
import KvoiceDomain

/// What the shell knows about the drop-down beyond the header row's
/// `StatusMenuHeaderContext`: the readiness line, the three value rows
/// and their choosers, the AI block, and the state-dependent rows the
/// menu shows or hides. `AppDelegate.updateMenu(for:)` fills one of these
/// at its end — after every plain item has been retitled from the same
/// facts — so the panel can never disagree with the menu.
public struct StatusPanelContext: Equatable, Sendable {
    public struct AI: Equatable, Sendable {
        /// `AIEndpointSettings.isEnabled`: the switch's position.
        public var isOn: Bool
        /// The menu's `isEnabled` on Use AI Actions: idle and not terminating.
        public var canToggle: Bool
        /// The menu's tooltip for the switch in this state.
        public var help: String?
        /// The active action's name, or nil for none.
        public var defaultActionName: String?
        /// "⌘1" … "⌘0" for the active action's slot, nil beyond the tenth.
        public var defaultActionBadge: String?
        /// The active configuration's name, or nil for none.
        public var configurationName: String?
        /// The two chooser rows' `isEnabled`: idle and not terminating.
        public var canChoose: Bool
        public var defaultActions: StatusPanelChooser
        public var configurations: StatusPanelChooser

        public init(
            isOn: Bool = false,
            canToggle: Bool = true,
            help: String? = nil,
            defaultActionName: String? = nil,
            defaultActionBadge: String? = nil,
            configurationName: String? = nil,
            canChoose: Bool = true,
            defaultActions: StatusPanelChooser = StatusPanelChooser(),
            configurations: StatusPanelChooser = StatusPanelChooser()
        ) {
            self.isOn = isOn
            self.canToggle = canToggle
            self.help = help
            self.defaultActionName = defaultActionName
            self.defaultActionBadge = defaultActionBadge
            self.configurationName = configurationName
            self.canChoose = canChoose
            self.defaultActions = defaultActions
            self.configurations = configurations
        }
    }

    /// Later waves: memory-pressure warnings — the Unload Model Now row,
    /// present only under critical pressure, like the menu item.
    public struct MemoryPressure: Equatable, Sendable {
        public var canUnloadNow: Bool
        public var isUnloading: Bool

        public init(canUnloadNow: Bool, isUnloading: Bool) {
            self.canUnloadNow = canUnloadNow
            self.isUnloading = isUnloading
        }
    }

    /// UI v2: the newest history entry's final text, cut to a preview, and
    /// when it was made — for the idle card. Transcript text: shown in the
    /// panel, never logged (this type is not a diagnostic).
    public struct LastTranscription: Equatable, Sendable {
        /// The card shows two lines; the context keeps at most this many
        /// characters so the whole entry never sits in the panel's state.
        public static let previewLimit = 240

        public let text: String
        public let createdAt: Date

        public init(text: String, createdAt: Date) {
            let collapsed = text
                .split(whereSeparator: \.isNewline)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.text = collapsed.count > Self.previewLimit
                ? String(collapsed.prefix(Self.previewLimit)) + "…"
                : collapsed
            self.createdAt = createdAt
        }
    }

    /// UI v2 fidelity F1: what the job that just ended put where — the
    /// Inserted card's "38 words → Notes" and its text, the clipboard
    /// card's "This field doesn't accept typing — press ⌘V". The shell fills it from the
    /// controller's snapshot (`recoverableTranscript`, the job's target
    /// name) while a job is completed or failed, and clears it otherwise.
    /// Shown in the panel only; never logged, never written to history.
    public struct JobResult: Equatable, Sendable {
        /// The text, cut to the card's preview like `LastTranscription`.
        public let text: String?
        /// Counted on the whole text, before the preview cut.
        public let wordCount: Int?
        /// The target app as the system names it ("Notes").
        public let appName: String?

        public init(text: String?, appName: String?) {
            self.text = text.map { LastTranscription(text: $0, createdAt: .distantPast).text }
            self.wordCount = text.map(Self.wordCount)
            self.appName = appName.flatMap { $0.isEmpty ? nil : $0 }
        }

        /// Words as the language counts them (`.byWords`), so a Chinese
        /// sentence is not one word because it has no spaces.
        public static func wordCount(_ text: String) -> Int {
            var count = 0
            text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
                count += 1
            }
            return count
        }
    }

    /// `statusSummary.title` — "Ready", "Model not ready", "Microphone
    /// denied", … — and whether it blocks or degrades the next dictation.
    public var readinessTitle: String
    public var isBlocked: Bool
    /// "Fix in Speech Models…" / "Fix in Permissions…": the row shown while
    /// blocked, carrying `openStatusTarget` like the menu's Fix item.
    public var fixTitle: String

    /// The value rows, from the same sources the menu titles use: the
    /// default model's display name, the transcription language's name,
    /// the microphone in use (`AudioInputViewModel.currentDeviceName`).
    public var modelName: String
    public var modelChooser: StatusPanelChooser
    public var languageName: String
    public var languageChooser: StatusPanelChooser
    public var microphoneName: String
    public var microphoneChooser: StatusPanelChooser
    /// The three rows' `isEnabled`: the menu disables them only while
    /// terminating (the choices inside carry their own idle gate).
    public var canOpenChoosers: Bool

    public var ai: AI

    /// Copy Last Transcription: disabled while history is degraded or the
    /// app terminates, with the menu's tooltip.
    public var canCopyLastTranscription: Bool
    public var copyLastTranscriptionHelp: String?
    /// ADR-022 item 6: Copy Transcript / Insert Transcript Again exist only
    /// while a failed job keeps its transcript.
    public var canRecoverFailedInsertion: Bool
    public var memoryPressure: MemoryPressure?
    /// UI v2: the model whose download is moving bytes right now — the
    /// one case where cancelling pauses it (resumable). Nil while verifying,
    /// installing or optimizing, where a cancel would throw work away.
    public var pausableDownload: ModelID?
    public var lastTranscription: LastTranscription?
    /// The job that just ended; nil before and during a job.
    public var jobResult: JobResult?

    /// "History" or "History (unavailable)", with the degraded tooltip.
    public var historyTitle: String
    public var historyHelp: String?

    public init(
        readinessTitle: String = "Ready",
        isBlocked: Bool = false,
        fixTitle: String = "",
        modelName: String = "",
        modelChooser: StatusPanelChooser = StatusPanelChooser(),
        languageName: String = "",
        languageChooser: StatusPanelChooser = StatusPanelChooser(),
        microphoneName: String = "",
        microphoneChooser: StatusPanelChooser = StatusPanelChooser(),
        canOpenChoosers: Bool = true,
        ai: AI = AI(),
        canCopyLastTranscription: Bool = true,
        copyLastTranscriptionHelp: String? = nil,
        canRecoverFailedInsertion: Bool = false,
        memoryPressure: MemoryPressure? = nil,
        pausableDownload: ModelID? = nil,
        lastTranscription: LastTranscription? = nil,
        historyTitle: String = "History",
        historyHelp: String? = nil
    ) {
        self.readinessTitle = readinessTitle
        self.isBlocked = isBlocked
        self.fixTitle = fixTitle
        self.modelName = modelName
        self.modelChooser = modelChooser
        self.languageName = languageName
        self.languageChooser = languageChooser
        self.microphoneName = microphoneName
        self.microphoneChooser = microphoneChooser
        self.canOpenChoosers = canOpenChoosers
        self.ai = ai
        self.canCopyLastTranscription = canCopyLastTranscription
        self.copyLastTranscriptionHelp = copyLastTranscriptionHelp
        self.canRecoverFailedInsertion = canRecoverFailedInsertion
        self.memoryPressure = memoryPressure
        self.pausableDownload = pausableDownload
        self.lastTranscription = lastTranscription
        self.historyTitle = historyTitle
        self.historyHelp = historyHelp
    }
}
