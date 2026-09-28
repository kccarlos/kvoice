import Foundation
import KvoiceDomain

/// What the shell knows about the drop-down that the header row shows
/// besides the recorder feed: the lifecycle kind, the readiness flags, the
/// shortcut readout, the blocked reason and a model install in progress.
/// The shell fills one of these in `updateMenu(for:)` — the same call that
/// retitles every plain item — so the row can never disagree with them.
public struct StatusMenuHeaderContext: Equatable, Sendable {
    /// A model package being downloaded or installed by the library
    /// (`ModelActivity.downloading` / `.installing`). `fraction` is nil while
    /// the byte total is unknown or the phase has no progress (verify,
    /// install), which draws an indeterminate bar.
    public struct ModelInstall: Equatable, Sendable {
        public var modelName: String
        public var fraction: Double?

        public init(modelName: String, fraction: Double?) {
            self.modelName = modelName
            self.fraction = fraction.map { min(max($0, 0), 1) }
        }
    }

    public var dictationKind: DictationStateKind
    /// `AppDelegate.modelReady`: Start Recording is disabled without it.
    public var modelReady: Bool
    /// `AppDelegate.terminationInProgress`: everything is disabled.
    public var isTerminating: Bool
    /// The confirmed shortcut as key-equivalent glyphs ("⌃⇧Space"), the
    /// menu's readout of the global hotkey; nil when none is confirmed.
    public var shortcutGlyphs: String?
    /// The not-working readout when `shortcutGlyphs` is nil ("No Shortcut",
    /// "Shortcut Unavailable"), spelled the way the plain item spells it.
    public var shortcutNote: String?
    /// `statusSummary.title` while `statusSummary.blocked`: the one reason
    /// the next dictation would be blocked or degraded. The Status row
    /// carries it in full; the header summarises it in the trailing slot.
    public var attention: String?
    public var modelInstall: ModelInstall?

    public init(
        dictationKind: DictationStateKind = .idle,
        modelReady: Bool = true,
        isTerminating: Bool = false,
        shortcutGlyphs: String? = nil,
        shortcutNote: String? = nil,
        attention: String? = nil,
        modelInstall: ModelInstall? = nil
    ) {
        self.dictationKind = dictationKind
        self.modelReady = modelReady
        self.isTerminating = isTerminating
        self.shortcutGlyphs = shortcutGlyphs
        self.shortcutNote = shortcutNote
        self.attention = attention
        self.modelInstall = modelInstall
    }
}

/// The header row of the status menu's Dictation group (P-D3, 2026-09-16):
/// a pure projection of the shell's `StatusMenuHeaderContext` and the HUD's
/// rendered `HUDViewState`, rendered by `StatusMenuHeaderView`. Equatable so
/// tests pin every state and so the model skips unchanged updates.
///
/// The one rule attached to the design's approval: **the meter and the
/// clock exist only while a job is recording** — `.meter` is produced for
/// `.recording` with `captureStarted`, and for nothing else. The row has no
/// level source of its own: the level arrives inside the HUD's rendered
/// state, which the filter only fills for a recording, and the microphone
/// is opened by `DictationController` for a job and never for the menu.
public struct StatusMenuHeaderState: Equatable, Sendable {
    /// The leading slot, where a plain item would draw its checkmark.
    public enum Indicator: Equatable, Sendable {
        /// Hollow ring in a secondary tint: nothing is recording.
        case idle
        /// Hollow accent ring, pulsing (static under Reduce Motion): the
        /// input route is coming up ("Starting mic…").
        case starting
        /// Solid accent dot: the recording is live.
        case live
        /// Spinner (hourglass under Reduce Motion): a job is finishing.
        case working
        /// The warning triangle: a prerequisite is missing or the job ended
        /// without inserting.
        case attention
        /// The checkmark: the last job inserted; the row dismisses it.
        case done
    }

    /// The trailing slot, where a plain item draws its key equivalent.
    public enum Trailing: Equatable, Sendable {
        case none
        /// The shortcut glyphs, secondary, right-aligned like a key equivalent.
        case shortcut(String)
        /// Secondary text: a blocked reason, the shortcut note, the finishing
        /// phase word, the outcome word.
        case note(String)
        /// The five-bar meter and the m:ss clock — recording only.
        case meter(level: Double, elapsed: Duration)
        /// A thin progress bar with "Downloading <model>… 42%"; `fraction`
        /// nil draws it indeterminate.
        case download(label: String, fraction: Double?)
    }

    public let indicator: Indicator
    /// The command the row is: "Start Recording", "Stop Recording",
    /// "Finishing…", "Dismiss", "Stopping…" — the plain item's verb, never
    /// a status sentence, so the row still reads as the thing you click.
    public let title: String
    public let isEnabled: Bool
    /// ADR-022 item 7: "1 finishing" beside the title while older jobs are
    /// still finishing behind the one shown, as on the HUD.
    public let finishingBadge: String?
    public let trailing: Trailing

    public init(
        indicator: Indicator,
        title: String,
        isEnabled: Bool,
        finishingBadge: String? = nil,
        trailing: Trailing = .none
    ) {
        self.indicator = indicator
        self.title = title
        self.isEnabled = isEnabled
        self.finishingBadge = finishingBadge
        self.trailing = trailing
    }

    /// The projection. `hud` is the HUD's *rendered* state — after
    /// `HUDRecordingFeedbackFilter` — so the meter is the HUD's own feed.
    public init(context: StatusMenuHeaderContext, hud: HUDViewState) {
        let enabled = !context.isTerminating
        switch context.dictationKind {
        case .idle:
            let indicator: Indicator = context.attention == nil ? .idle : .attention
            self.init(
                indicator: indicator,
                title: String(localized: "Start Recording", bundle: .module),
                isEnabled: enabled && context.modelReady,
                trailing: Self.idleTrailing(context)
            )
        case .recording:
            // The meter exists only here, and only once the HUD's rendered
            // state carries a live recording. Before that (the input route
            // coming up, or the HUD's first snapshot still in flight) the
            // row reads as starting, with no meter and no clock.
            var live: HUDRecordingState?
            if case .recording(let state) = hud.phase, state.captureStarted {
                live = state
            }
            self.init(
                indicator: live == nil ? .starting : .live,
                title: live == nil
                    ? String(localized: "Starting mic…", bundle: .module)
                    : String(localized: "Stop Recording", bundle: .module),
                isEnabled: enabled,
                finishingBadge: hud.finishingBadge,
                trailing: live.map { .meter(level: $0.inputLevel, elapsed: $0.elapsed) } ?? .none
            )
        case .finalizing, .transcribing, .processingAI, .inserting:
            self.init(
                indicator: .working,
                title: String(localized: "Finishing…", bundle: .module),
                isEnabled: false,
                finishingBadge: hud.finishingBadge,
                trailing: Self.phaseWord(for: context.dictationKind, hud: hud).map(Trailing.note) ?? .none
            )
        case .completed:
            let inserted: Bool
            if case .completed(let completion) = hud.phase {
                inserted = completion.kind == .success
            } else {
                inserted = true
            }
            self.init(
                indicator: inserted ? .done : .attention,
                title: String(localized: "Dismiss", bundle: .module),
                isEnabled: enabled,
                trailing: hud.title.isEmpty ? .none : .note(hud.title)
            )
        case .failed, .blocked:
            self.init(
                indicator: .attention,
                title: String(localized: "Dismiss", bundle: .module),
                isEnabled: enabled,
                trailing: hud.title.isEmpty ? .none : .note(hud.title)
            )
        case .terminating:
            self.init(
                indicator: .idle,
                title: String(localized: "Stopping…", bundle: .module),
                isEnabled: false
            )
        }
    }

    /// Idle, by priority: an install in progress is the fix happening, so it
    /// wins over the reason it fixes; then the blocked reason; then the
    /// shortcut's not-working note; then the shortcut itself.
    private static func idleTrailing(_ context: StatusMenuHeaderContext) -> Trailing {
        if let install = context.modelInstall {
            return .download(label: Self.downloadLabel(install), fraction: install.fraction)
        }
        if let attention = context.attention {
            return .note(attention)
        }
        if let glyphs = context.shortcutGlyphs {
            return .shortcut(glyphs)
        }
        if let note = context.shortcutNote {
            return .note(note)
        }
        return .none
    }

    /// "Downloading Nemotron… 42%" — or without the figure while the total
    /// is unknown.
    static func downloadLabel(_ install: StatusMenuHeaderContext.ModelInstall) -> String {
        if let fraction = install.fraction {
            let percent = Int((fraction * 100).rounded(.down))
            return String(localized: "Downloading \(install.modelName)… \(percent)%", bundle: .module)
        }
        return String(localized: "Downloading \(install.modelName)…", bundle: .module)
    }

    /// The one word for the finishing phase — the HUD's title says
    /// "Transcribing locally" and "Translating to French"; a menu row has
    /// room for the verb only.
    static func phaseWord(for kind: DictationStateKind, hud: HUDViewState) -> String? {
        switch kind {
        case .finalizing:
            return String(localized: "Preparing", bundle: .module)
        case .transcribing:
            return String(localized: "Transcribing", bundle: .module)
        case .processingAI:
            if case .processingAI(let state) = hud.phase, state.mode == .translate {
                return String(localized: "Translating", bundle: .module)
            }
            return String(localized: "Polishing", bundle: .module)
        case .inserting:
            return String(localized: "Inserting", bundle: .module)
        default:
            return nil
        }
    }

    /// Whether the leading ring animates: only the starting ring pulses,
    /// and not under Reduce Motion (`motion.md`: respect the setting; the
    /// HUD's ring follows the same rule).
    public func indicatorPulses(reduceMotion: Bool) -> Bool {
        indicator == .starting && !reduceMotion
    }

    /// What VoiceOver would read for the row if the view were exposed: the
    /// command, then the trailing information. The shell keeps the menu
    /// item's own title in step, which is what VoiceOver reads in practice
    /// (`StatusMenuHeaderItemView` hides the view from accessibility).
    public var accessibilityLabel: String {
        var parts = [title]
        if let finishingBadge {
            parts.append(finishingBadge)
        }
        switch trailing {
        case .none:
            break
        case .shortcut(let glyphs):
            parts.append(glyphs)
        case .note(let note):
            parts.append(note)
        case .meter(_, let elapsed):
            parts.append(HUDViewState.formatElapsed(elapsed))
        case .download(let label, _):
            parts.append(label)
        }
        return parts.joined(separator: ", ")
    }

    public static let idle = Self(context: StatusMenuHeaderContext(), hud: .idle)
}
