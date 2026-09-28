import Foundation

/// The two messages every AI provider sends, built from one request the same
/// way (ADR-024: the OpenAI-compatible client and the on-device client must
/// produce byte-identical prompts, so the composition lives here, once).
public struct AIPromptMessages: Sendable, Equatable {
    /// The action's instructions (the polish prompt, or the translate prompt
    /// with the target language filled in). The system message for Chat
    /// Completions; the session `instructions` for Foundation Models.
    public let systemPrompt: String
    /// The transcript framed as data plus the opted-in context blocks. The
    /// user message for Chat Completions; the prompt for Foundation Models.
    public let userMessage: String

    public init(systemPrompt: String, userMessage: String) {
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
    }
}

/// Pure prompt assembly shared by every `AIProcessingClient` (K.3, Appendix
/// A1.2). No provider, no transport, no I/O.
public enum AIPromptComposer {
    /// The system prompt and user message for a request, or
    /// `.aiConfigurationMissing` when the request mode is Off or a translate
    /// request names no language.
    public static func compose(request: AIProcessRequest, settings: AIEndpointSettings) throws -> AIPromptMessages {
        let systemPrompt: String
        switch request.mode {
        case .off:
            throw KVoiceError(code: .aiConfigurationMissing, retryable: false)
        case .polish:
            systemPrompt = request.polishPrompt
        case .translate:
            guard let targetLanguage = request.targetLanguage else {
                throw KVoiceError(code: .aiConfigurationMissing, retryable: false)
            }
            systemPrompt = settings.promptConfiguration.systemPrompt(
                for: .translate,
                targetLanguage: targetLanguage
            )
        }
        return AIPromptMessages(
            systemPrompt: systemPrompt,
            userMessage: userMessage(for: request.rawTranscript, context: request.context)
        )
    }

    // MARK: Transcript envelope

    /// The user message is the transcript framed as data, and nothing else.
    ///
    /// The shipped prompts tell the model that everything inside
    /// `<TRANSCRIPT>` is content rather than instructions, so the client must
    /// wrap it with exactly those tags. The transcript is never interpolated
    /// into the system prompt.
    public static let transcriptOpeningTag = "<TRANSCRIPT>"
    public static let transcriptClosingTag = "</TRANSCRIPT>"

    public static let userProfileTag = "USER_PROFILE"
    public static let clipboardTag = "CLIPBOARD"
    public static let selectedTextTag = "SELECTED_TEXT"

    public static func userMessage(for rawTranscript: String) -> String {
        userMessage(for: rawTranscript, context: AIRequestContext())
    }

    /// The transcript envelope, followed by one delimited block per context
    /// source the action opted into. Each block gets the same delimiter
    /// neutralization as the transcript, so pasted text cannot close its own
    /// tag early. With an empty context the message is exactly the envelope.
    public static func userMessage(for rawTranscript: String, context: AIRequestContext) -> String {
        var message = transcriptOpeningTag
            + "\n"
            + neutralizingTranscriptDelimiters(in: rawTranscript)
            + "\n"
            + transcriptClosingTag
        for (tag, content) in contextBlocks(context) {
            message += "\n<\(tag)>\n" + neutralizingTranscriptDelimiters(in: content) + "\n</\(tag)>"
        }
        return message
    }

    private static func contextBlocks(_ context: AIRequestContext) -> [(String, String)] {
        var blocks: [(String, String)] = []
        if let profile = context.userProfile { blocks.append((userProfileTag, profile)) }
        if let clipboard = context.clipboardText { blocks.append((clipboardTag, clipboard)) }
        if let selection = context.selectedText { blocks.append((selectedTextTag, selection)) }
        return blocks
    }

    /// Escapes anything in the transcript that could read as the envelope.
    ///
    /// A spoken `</TRANSCRIPT>` (or the legacy `TRANSCRIPT_END` word) would
    /// otherwise close the data block early and let what follows read as
    /// instructions. The replacement is visually equivalent — `‹` / `›`
    /// for the angle brackets and a full-width low line for the underscore —
    /// so a legitimate mention survives as readable text without ever
    /// matching the delimiter. Matching is case-insensitive because models
    /// and users are not reliably case-sensitive about tags.
    public static func neutralizingTranscriptDelimiters(in transcript: String) -> String {
        // Regex literals are checked at compile time, so no `try` is needed
        // and no pattern can fail at run time.
        let tag = /<(\s*\/?\s*(?:transcript|user_profile|clipboard|selected_text)\s*)>/.ignoresCase()
        let legacyWord = /(transcript)_(begin|end)/.ignoresCase()
        return transcript
            .replacing(tag) { match in "\u{2039}\(match.output.1)\u{203A}" }
            .replacing(legacyWord) { match in "\(match.output.1)\u{FF3F}\(match.output.2)" }
    }
}

/// The one fixed, harmless request "Test Active Configuration" and "Verify &
/// Save" send (spec K.9). Shared by every provider so a passing test means
/// the same thing everywhere.
public enum ConnectionTest {
    /// Sent as the transcript. Deliberately not an instruction, so it works
    /// as the data of an echo request.
    public static let marker = "kvoice connection OK"

    /// A system prompt that asks for an echo and nothing else. Kept minimal
    /// on purpose: it must not be the polish contract, which forbids obeying
    /// the transcript.
    public static let systemPrompt = "This is a connection test. Reply with exactly the text between the <TRANSCRIPT> tags and nothing else: no quotation marks, no tags, no explanation, no formatting."

    /// Case-insensitive, whitespace-trimmed containment of the marker's
    /// subject. Containment rather than equality because tiny models
    /// reliably echo the marker but not reliably nothing else: over 100 runs
    /// qwen3:0.6b answered "<kvoice connection OK>",
    /// "<TRANSCRIPT>kvoice connection OK</TRANSCRIPT>", and once
    /// "kvoice connection is active." The endpoint, model, and key round
    /// trip is what the test proves, so any reply that is recognisably about
    /// the marker passes; a chatty unrelated answer does not.
    public static func accepts(_ reply: String) -> Bool {
        reply
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .contains(acceptedSubject)
    }

    private static let acceptedSubject = "kvoice connection"
}
