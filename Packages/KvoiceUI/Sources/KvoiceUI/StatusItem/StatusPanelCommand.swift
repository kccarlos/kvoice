import Foundation
import KvoiceDomain

/// Every command the status panel (P-D4) can send, one case per selector
/// the status menu already has. The panel adds no behaviour: the shell
/// installs one handler (`StatusPanelModel.handler`) that maps each case
/// onto the same `@objc` method the corresponding `NSMenuItem` calls, so a
/// command does exactly what its menu row does whichever surface sent it.
/// The comment on each case names that selector.
public enum StatusPanelCommand: Equatable, Sendable {
    // Dictation
    /// `toggleDictation` — Start / Stop Recording, or Dismiss an outcome.
    case toggleDictation
    /// `cancelCurrentDictation` — Cancel Current Dictation / Use Raw Transcript Now.
    case cancelCurrentDictation
    /// `copyFailedTranscript` — Copy Transcript (ADR-022 item 6).
    case copyTranscript
    /// `insertFailedTranscriptAgain` — Insert Transcript Again (ADR-022 item 6).
    case insertTranscriptAgain
    /// `copyLastTranscription`.
    case copyLastTranscription
    /// `openStatusTarget` — the Status row and Fix in Speech Models… / Permissions….
    case openStatusTarget
    /// `unloadModelForMemoryPressure` — Unload Model Now.
    case unloadModel
    // Transcription
    /// `selectSpeechModel(_:)` with the entry's id.
    case selectModel(ModelID)
    /// `openModels` — Manage Models….
    case openModels
    /// `selectTranscriptionLanguage(_:)`; nil is Auto-detect.
    case selectLanguage(String?)
    /// `selectAudioInputDevice(_:)` with the device uid, or
    /// `selectSystemDefaultAudioInput` for nil.
    case selectMicrophone(uid: String?)
    /// `openAudioInput` — Microphone Settings….
    case openAudioInput
    // AI
    /// `toggleAI` — Use AI Actions.
    case toggleAI
    /// `selectPromptMode(_:)` with the action's id.
    case selectDefaultAction(UUID)
    /// `selectProviderConfiguration(_:)` with the configuration's id.
    case selectConfiguration(UUID)
    /// `openAIActions` — the Configuration chooser's "add one" row.
    case openAIActions
    // App
    /// `openHistory` (⌘H).
    case openHistory
    /// `openSettings` (⌘,).
    case openSettings
    /// `openSetup` — Setup Guide….
    case openSetup
    /// `openHelp` — Help.
    case openHelp
    /// `showAbout` — About.
    case showAbout
    /// `quit` (⌘Q).
    case quit

    /// Whether the panel closes *before* the command runs. Two reasons a
    /// command needs the panel gone first:
    ///
    /// - it opens a window, which activates the app; a transient popover
    ///   under an activating window is a stray;
    /// - it inserts text (`insertTranscriptAgain`): the panel's window is
    ///   key while open (`StatusPanelController`), and ADR-016's third tier
    ///   posts typed events to the key window, so the panel must resign
    ///   before any insertion can run. Stop Recording is handled by the
    ///   shell on the lifecycle edge for the same reason, whether the panel
    ///   or the hotkey stopped the job.
    ///
    /// Everything else keeps the panel open, so a pick in a chooser or the
    /// AI switch shows its result in place, and Start Recording leaves the
    /// meter visible (the reason for the panel).
    public var closesPanelFirst: Bool {
        switch self {
        case .openStatusTarget, .openModels, .openAudioInput, .openAIActions,
             .openHistory, .openSettings, .openSetup, .openHelp, .showAbout, .quit,
             .insertTranscriptAgain:
            return true
        case .toggleDictation, .cancelCurrentDictation, .copyTranscript, .copyLastTranscription,
             .unloadModel, .selectModel, .selectLanguage, .selectMicrophone, .toggleAI,
             .selectDefaultAction, .selectConfiguration:
            return false
        }
    }
}

/// One entry of a chooser (the panel's form of a submenu): a title, whether
/// it is the current pick, whether it can be picked, and the command a pick
/// sends. `command` nil is an informational row the submenu also shows
/// disabled ("Prioritized List in Use", a model's status).
public struct StatusPanelChoice: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var isSelected: Bool
    public var isEnabled: Bool
    public var help: String?
    public var command: StatusPanelCommand?
    /// A separator follows this choice, where the submenu draws one
    /// (after Auto-detect in Language; after System Default in Microphone
    /// when devices follow).
    public var separatorAfter: Bool

    public init(
        id: String,
        title: String,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        help: String? = nil,
        command: StatusPanelCommand?,
        separatorAfter: Bool = false
    ) {
        self.id = id
        self.title = title
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.help = help
        self.command = command
        self.separatorAfter = separatorAfter
    }
}

/// The items a value row offers when clicked — the same list, in the same
/// order, with the same enabled states, as the menu's submenu for that
/// row. `choices` are the pickable items (drawn with a checkmark on the
/// current one); `footer` follows a separator (Manage Models…, Microphone
/// Settings…). Built by the shell from the same facts as the submenu
/// filler, next to it.
public struct StatusPanelChooser: Equatable, Sendable {
    public var choices: [StatusPanelChoice]
    public var footer: [StatusPanelChoice]

    public init(choices: [StatusPanelChoice] = [], footer: [StatusPanelChoice] = []) {
        self.choices = choices
        self.footer = footer
    }

    public var isEmpty: Bool { choices.isEmpty && footer.isEmpty }
}
