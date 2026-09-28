import Foundation

/// Picks the AI action a transcript asks for by its opening words.
///
/// "Terminal, list the files here" with a Terminal action whose trigger words
/// include "terminal" runs Terminal on "list the files here" instead of the
/// default action. Pure and synchronous, so the controller's only involvement
/// is one call before it builds the request; nothing here knows how a request
/// is made.
public enum ActionTriggerResolver {
    public struct Match: Sendable, Equatable {
        /// The action whose trigger opened the transcript.
        public let action: PromptMode
        /// The transcript with the trigger phrase and its trailing
        /// punctuation removed.
        public let transcript: String
        /// The trigger phrase as it was written in the action, for diagnostics
        /// and tests. Never logged with the transcript.
        public let trigger: String
    }

    /// What the AI stage should run: the settings with the triggered action
    /// applied (or the input settings when nothing matched) and the
    /// transcript to send.
    public struct Outcome: Sendable, Equatable {
        public let settings: AIEndpointSettings
        public let transcript: String
        public let triggeredAction: PromptMode?

        public init(settings: AIEndpointSettings, transcript: String, triggeredAction: PromptMode?) {
            self.settings = settings
            self.transcript = transcript
            self.triggeredAction = triggeredAction
        }
    }

    /// The controller's entry point. Honors `actionTriggersEnabled`; when a
    /// trigger matches, returns settings with that action copied into the
    /// request fields exactly as choosing it from the menu would have, so the
    /// request path sees an ordinary polish or translate request.
    public static func resolve(transcript: String, settings: AIEndpointSettings) -> Outcome {
        guard settings.actionTriggersEnabled, settings.isEnabled,
              let match = match(transcript: transcript, actions: settings.promptModes)
        else {
            return Outcome(settings: settings, transcript: transcript, triggeredAction: nil)
        }
        var applied = settings
        applied.apply(promptMode: match.action)
        return Outcome(settings: applied, transcript: match.transcript, triggeredAction: match.action)
    }

    /// Finds the action whose trigger phrase opens the transcript.
    ///
    /// Matching is case-insensitive, ignores leading whitespace and
    /// punctuation, and requires a word boundary after the phrase so
    /// "terminal" does not match "terminally". The longest phrase wins when
    /// several match. The trigger, plus any punctuation and whitespace that
    /// follows it, is stripped; a transcript that is *only* a trigger does not
    /// match, because there would be nothing to process.
    public static func match(transcript: String, actions: [PromptMode]) -> Match? {
        let opening = transcript.drop { $0.isWhitespace || $0.isPunctuation }
        guard !opening.isEmpty else { return nil }
        let folded = opening.lowercased()

        var best: (action: PromptMode, trigger: String, remainder: Substring)?
        for action in actions where action.isUsable {
            for trigger in action.triggerWords {
                let phrase = normalizedPhrase(trigger)
                guard !phrase.isEmpty, folded.hasPrefix(phrase) else { continue }

                // `folded` and `opening` have the same character count only
                // when lowercasing did not change lengths; index by the
                // phrase's character count on the original to stay safe.
                let phraseLength = phrase.count
                guard opening.count >= phraseLength else { continue }
                let boundaryIndex = opening.index(opening.startIndex, offsetBy: phraseLength)
                if boundaryIndex < opening.endIndex {
                    let next = opening[boundaryIndex]
                    guard !next.isLetter, !next.isNumber else { continue }
                }
                let remainder = opening[boundaryIndex...].drop { $0.isWhitespace || $0.isPunctuation }
                guard !remainder.isEmpty else { continue }

                if let current = best, normalizedPhrase(current.trigger).count >= phraseLength { continue }
                best = (action, trigger, remainder)
            }
        }
        guard let best else { return nil }
        return Match(action: best.action, transcript: String(best.remainder), trigger: best.trigger)
    }

    private static func normalizedPhrase(_ trigger: String) -> String {
        trigger
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}
