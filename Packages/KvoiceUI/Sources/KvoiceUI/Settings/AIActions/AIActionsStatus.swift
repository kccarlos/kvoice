import KvoiceDomain

/// The one-line status under "Use AI Actions" on the AI Actions page (Q3):
/// what a dictation does right now. Built from the stored settings and the
/// session's last test, with the same "action · configuration" words Home's
/// hero chip uses, so the two cannot disagree (`AIActionsStatusTests`).
///
/// "Tested OK" appears only after a test of the active configuration in this
/// session succeeded: the app never sends a request on its own (F3b #1).
struct AIActionsStatus: Equatable {
    enum Tone: Equatable {
        /// AI runs after each dictation.
        case on
        /// Nothing runs: off, or waiting for a configuration or an action.
        case idle
        /// On, but something stops it from running.
        case attention
    }

    let tone: Tone
    let line: String

    /// `configurationName` defaults to the stored active configuration's
    /// name; the page passes the configurations model's, which is the same
    /// store in the app.
    init(settings ai: AIEndpointSettings, configurationName: String?? = nil, test: AISettingsViewModel.TestState) {
        let configurationName = configurationName ?? ai.activeConfiguration?.menuTitle
        let action = ai.activePromptMode
        let actionName = action.map { "\($0.icon.isEmpty ? "" : $0.icon + " ")\($0.menuTitle)" }
        if !ai.isEnabled {
            tone = .idle
            if let actionName {
                line = String(localized: "\(AIActionsCopy.aiOff) · dictation inserts the raw transcript · default action kept: \(actionName)", bundle: .module)
            } else {
                line = String(localized: "\(AIActionsCopy.aiOff) · dictation inserts the raw transcript", bundle: .module)
            }
            return
        }
        guard ai.canEnableProcessing else {
            tone = .attention
            line = String(localized: "On, but no configuration is set: dictation inserts the raw transcript. Add one below.", bundle: .module)
            return
        }
        guard !ai.awaitsDefaultActionChoice else {
            tone = .attention
            line = String(localized: "On, but no default action is chosen: click an action below.", bundle: .module)
            return
        }
        tone = .on
        var summary = AIActionsCopy.summary(action: actionName, configuration: configurationName)
        switch test {
        case .succeeded:
            summary += " · " + String(localized: "tested OK", bundle: .module)
        case .failed:
            summary += " · " + String(localized: "test failed", bundle: .module)
        case .idle, .testing:
            break
        }
        line = String(localized: "On · \(summary)", bundle: .module)
    }
}

/// The default strip's facts line (Q3): one action's behaviour, the mode
/// settings that are on, its trigger words and its ⌘ number, so the page
/// shows what runs without opening the detail. "Edits the transcript ·
/// formal writing · trigger words: “clean up” · ⌘1".
enum AIActionFacts {
    static func line(for action: PromptMode, badge: String?, triggersOn: Bool) -> String {
        var parts: [String] = []
        switch action.behavior {
        case .polish:
            parts.append(String(localized: "Edits the transcript", bundle: .module))
        case .translate:
            let target = action.translationLanguage?.displayName ?? "—"
            parts.append(String(localized: "Translates to \(target)", bundle: .module))
        }
        let options = action.options
        switch action.settingsFamily {
        case .polish:
            if options.formalWriting { parts.append(String(localized: "formal writing", bundle: .module)) }
            if options.professionalTone { parts.append(String(localized: "professional tone", bundle: .module)) }
        case .translate:
            if let second = options.secondTranslationLanguage {
                parts.append(String(localized: "also \(second.displayName)", bundle: .module))
            }
            if options.showsOriginalTranscript { parts.append(String(localized: "keeps the original", bundle: .module)) }
        case .questionAnswer:
            if options.showsQuestionBeforeAnswer { parts.append(String(localized: "question first", bundle: .module)) }
        case .none:
            break
        }
        if !action.triggerWords.isEmpty {
            let words = action.triggerWords.map { "“\($0)”" }.joined(separator: ", ")
            parts.append(triggersOn
                ? String(localized: "trigger words: \(words)", bundle: .module)
                : String(localized: "trigger words (off): \(words)", bundle: .module))
        }
        if let badge { parts.append(badge) }
        return parts.joined(separator: " · ")
    }
}
