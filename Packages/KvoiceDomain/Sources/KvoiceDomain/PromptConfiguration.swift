import Foundation

public struct PromptConfiguration: Codable, Sendable, Equatable {
    public var polishPrompt: String
    public var polishPromptOrigin: PromptOrigin
    public var shippedDefaultVersion: Int
    public var lastEditedAt: Date?

    /// The prompt used for translate-behavior jobs.
    ///
    /// Stored rather than always taken from the shipped template, so a
    /// user-defined translate mode is honored the same way a polish mode is.
    /// Placeholder substitution still happens at request time.
    public var translatePrompt: String

    public init(
        polishPrompt: String = DefaultPrompts.polish,
        polishPromptOrigin: PromptOrigin = .shippedDefault,
        shippedDefaultVersion: Int = DefaultPrompts.polishVersion,
        lastEditedAt: Date? = nil,
        translatePrompt: String = DefaultPrompts.translate
    ) {
        self.polishPrompt = polishPrompt
        self.polishPromptOrigin = polishPromptOrigin
        self.shippedDefaultVersion = shippedDefaultVersion
        self.lastEditedAt = lastEditedAt
        self.translatePrompt = translatePrompt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case polishPrompt
        case polishPromptOrigin
        case shippedDefaultVersion
        case lastEditedAt
        case translatePrompt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        polishPrompt = try values.decodeIfPresent(String.self, forKey: .polishPrompt)
            ?? DefaultPrompts.polish
        polishPromptOrigin = try values.decodeIfPresent(
            PromptOrigin.self,
            forKey: .polishPromptOrigin
        ) ?? .shippedDefault
        shippedDefaultVersion = try values.decodeIfPresent(
            Int.self,
            forKey: .shippedDefaultVersion
        ) ?? DefaultPrompts.polishVersion
        lastEditedAt = try values.decodeIfPresent(Date.self, forKey: .lastEditedAt)
        // Absent in settings written before translate prompts were editable.
        translatePrompt = try values.decodeIfPresent(String.self, forKey: .translatePrompt)
            ?? DefaultPrompts.translate
    }

    /// Returns the system prompt for a job, with target-language placeholders
    /// resolved. The caller supplies the language; the prompt text itself is
    /// whatever the active mode set.
    public func systemPrompt(
        for mode: DictationMode,
        targetLanguage: TranslationLanguage? = nil
    ) -> String {
        switch mode {
        case .off:
            return ""
        case .polish:
            return polishPrompt
        case .translate:
            guard let targetLanguage else { return translatePrompt }
            return DefaultPrompts.substitutingLanguage(
                in: translatePrompt,
                language: targetLanguage
            )
        }
    }
}

public enum PromptOrigin: String, Codable, Sendable, Equatable {
    case shippedDefault
    case userEdited
}

public enum DefaultPrompts {
    public static let polishVersion = 1
    public static let translateVersion = 1

    public static var polish: String {
        guard let url = Bundle.module.url(
            forResource: "polish-default-v1",
            withExtension: "txt"
        ), let data = try? Data(contentsOf: url), let prompt = String(data: data, encoding: .utf8) else {
            preconditionFailure("Missing bundled polish-default-v1 prompt resource")
        }
        return prompt
    }

    public static var polishData: Data {
        Data(polish.utf8)
    }

    public static var translate: String {
        guard let url = Bundle.module.url(
            forResource: "translate-default-v1",
            withExtension: "txt"
        ), let data = try? Data(contentsOf: url), let prompt = String(data: data, encoding: .utf8) else {
            preconditionFailure("Missing bundled translate-default-v1 prompt resource")
        }
        return prompt
    }

    public static var translateData: Data {
        Data(translate.utf8)
    }

    public static func translatePrompt(for language: TranslationLanguage) -> String {
        substitutingLanguage(in: translate, language: language)
    }

    /// Resolves target-language placeholders in any translate prompt, shipped or
    /// user-written, so a custom mode can use the same tokens.
    public static func substitutingLanguage(
        in prompt: String,
        language: TranslationLanguage
    ) -> String {
        prompt
            .replacingOccurrences(of: "{targetLanguageDisplayName}", with: language.displayName)
            .replacingOccurrences(of: "{targetLanguageBCP47}", with: language.bcp47)
    }
}
