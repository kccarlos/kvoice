import Foundation
import KvoiceDomain

/// UI v2 wave 5a: the Home page's ink hero — the shell's readiness line, how
/// to start a dictation with the real shortcut, and three chips naming the
/// speech model, the microphone and the AI action. The shell pushes it with
/// every status update, next to the sidebar pill (`MainWindowModel.home`).
public struct HomeHeroState: Equatable, Sendable {
    /// The optional AI layer as the chip states it: honestly off, or the
    /// default action and the configuration that runs it.
    public enum AI: Equatable, Sendable {
        case off
        case on(action: String?, configuration: String?)
    }

    public let readiness: MainWindowReadiness
    public let interaction: RecordingInteraction
    public let modelName: String
    public let microphoneName: String
    public let ai: AI

    public init(
        readiness: MainWindowReadiness,
        interaction: RecordingInteraction,
        modelName: String,
        microphoneName: String,
        ai: AI
    ) {
        self.readiness = readiness
        self.interaction = interaction
        self.modelName = modelName
        self.microphoneName = microphoneName
        self.ai = ai
    }

    /// The word before the keycaps: push-to-talk holds, toggle presses,
    /// hybrid does either.
    public var verb: String {
        switch interaction {
        case .pushToTalk: return String(localized: "Hold", bundle: .module)
        case .toggle: return String(localized: "Press", bundle: .module)
        case .hybrid: return String(localized: "Hold or press", bundle: .module)
        }
    }

    /// The words after the keycaps.
    public var trailer: String { String(localized: "and speak.", bundle: .module) }

    /// No recording shortcut is set: the hero offers Shortcuts instead of
    /// keycaps.
    public var hasShortcut: Bool { !readiness.shortcutKeys.isEmpty }

    public var aiIsOn: Bool {
        if case .on = ai { return true }
        return false
    }

    /// "Clean Up · Local Ollama", "Clean Up", "AI on", or "AI off".
    public var aiChipTitle: String {
        switch ai {
        case .off:
            return AIActionsCopy.aiOff
        case .on(let action, let configuration):
            return AIActionsCopy.summary(action: action, configuration: configuration)
        }
    }

    /// The whole call to action as one VoiceOver phrase.
    public var accessibilitySentence: String {
        guard hasShortcut else { return readiness.title }
        return "\(readiness.title). \(verb) \(readiness.shortcutKeys.joined()) \(trailer)"
    }

    /// A stand-in for previews and the offscreen renders.
    static let preview = HomeHeroState(
        readiness: .preview,
        interaction: .pushToTalk,
        modelName: "Whisper large-v3-turbo",
        microphoneName: "MacBook Pro Microphone",
        ai: .on(action: "Clean Up", configuration: "Local Ollama")
    )
}
