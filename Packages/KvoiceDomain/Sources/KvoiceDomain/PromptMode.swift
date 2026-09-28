import Foundation

/// A named prompt the user can switch to from the menu bar — an "AI action"
/// in the product's language.
///
/// A mode is a system prompt plus the request semantics it needs. `behavior`
/// decides which of the two request shapes runs — editing the transcript in
/// place, or translating it — so adding a mode never requires touching the
/// request path. Shipped modes carry a `builtInKey`, which is how the app can
/// tell an untouched default from one the user has revised and can offer to
/// reset it.
///
/// The request path never reads a `PromptMode`. `AIEndpointSettings.apply`
/// copies `effectiveSystemPrompt` — the instructions, optionally wrapped in
/// the house template, plus the addenda the mode settings ask for — into the
/// one system prompt the client sends.
public struct PromptMode: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var behavior: AIMode
    /// The instructions. A complete system prompt when
    /// `usesSystemInstructionsTemplate` is off; the task text alone when it
    /// is on and the house template supplies the rest.
    public var prompt: String
    /// Stable identifier for a shipped mode; `nil` for a user-created one.
    public var builtInKey: String?
    /// Only meaningful when `behavior == .translate`.
    public var translationLanguage: TranslationLanguage?

    // MARK: AI actions

    /// One line shown under the name in the action grid.
    public var summary: String
    /// An emoji shown in the action grid; empty means a generic symbol.
    public var icon: String
    /// Phrases that select this action when a transcript begins with one
    /// and action triggers are on. Matched case-insensitively.
    public var triggerWords: [String]
    /// Wrap `prompt` in the shipped `<SYSTEM_INSTRUCTIONS>` template. Off for
    /// the shipped modes, whose prompts already carry the full house style;
    /// on by default for a new action so the user writes only the task.
    public var usesSystemInstructionsTemplate: Bool
    /// Context awareness opt-ins (product decision #2). Off by default.
    public var includesClipboardText: Bool
    public var includesSelectedText: Bool
    /// Per-mode settings that append shipped instruction blocks.
    public var options: PromptModeOptions

    public init(
        id: UUID = UUID(),
        name: String,
        behavior: AIMode,
        prompt: String,
        builtInKey: String? = nil,
        translationLanguage: TranslationLanguage? = nil,
        summary: String = "",
        icon: String = "",
        triggerWords: [String] = [],
        usesSystemInstructionsTemplate: Bool = false,
        includesClipboardText: Bool = false,
        includesSelectedText: Bool = false,
        options: PromptModeOptions = .init()
    ) {
        self.id = id
        self.name = name
        self.behavior = behavior
        self.prompt = prompt
        self.builtInKey = builtInKey
        self.translationLanguage = translationLanguage
        self.summary = summary
        self.icon = icon
        self.triggerWords = triggerWords
        self.usesSystemInstructionsTemplate = usesSystemInstructionsTemplate
        self.includesClipboardText = includesClipboardText
        self.includesSelectedText = includesSelectedText
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, behavior, prompt, builtInKey, translationLanguage
        // MARK: AI actions
        case summary, icon, triggerWords, usesSystemInstructionsTemplate
        case includesClipboardText, includesSelectedText, options
    }

    /// Explicit so a mode written before the action fields existed still loads.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        behavior = try values.decode(AIMode.self, forKey: .behavior)
        prompt = try values.decode(String.self, forKey: .prompt)
        builtInKey = try values.decodeIfPresent(String.self, forKey: .builtInKey)
        translationLanguage = try values.decodeIfPresent(TranslationLanguage.self, forKey: .translationLanguage)
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        icon = try values.decodeIfPresent(String.self, forKey: .icon) ?? ""
        triggerWords = try values.decodeIfPresent([String].self, forKey: .triggerWords) ?? []
        usesSystemInstructionsTemplate = try values.decodeIfPresent(Bool.self, forKey: .usesSystemInstructionsTemplate) ?? false
        includesClipboardText = try values.decodeIfPresent(Bool.self, forKey: .includesClipboardText) ?? false
        includesSelectedText = try values.decodeIfPresent(Bool.self, forKey: .includesSelectedText) ?? false
        options = try values.decodeIfPresent(PromptModeOptions.self, forKey: .options) ?? .init()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(behavior, forKey: .behavior)
        try container.encode(prompt, forKey: .prompt)
        try container.encodeIfPresent(builtInKey, forKey: .builtInKey)
        try container.encodeIfPresent(translationLanguage, forKey: .translationLanguage)
        if !summary.isEmpty { try container.encode(summary, forKey: .summary) }
        if !icon.isEmpty { try container.encode(icon, forKey: .icon) }
        if !triggerWords.isEmpty { try container.encode(triggerWords, forKey: .triggerWords) }
        if usesSystemInstructionsTemplate {
            try container.encode(usesSystemInstructionsTemplate, forKey: .usesSystemInstructionsTemplate)
        }
        if includesClipboardText { try container.encode(includesClipboardText, forKey: .includesClipboardText) }
        if includesSelectedText { try container.encode(includesSelectedText, forKey: .includesSelectedText) }
        if options != PromptModeOptions() { try container.encode(options, forKey: .options) }
    }

    public var isBuiltIn: Bool { builtInKey != nil }

    /// True when a shipped mode's text no longer matches what shipped, so the
    /// UI can offer to reset it. Mode settings (`options`) and context opt-ins
    /// are preferences, not text, and do not count.
    public var isRevisedBuiltIn: Bool {
        guard let builtInKey,
              let shipped = BuiltInPromptModes.shipped(forKey: builtInKey)
        else {
            return false
        }
        return shipped.prompt != prompt
            || shipped.name != name
            || shipped.summary != summary
            || shipped.icon != icon
            || shipped.triggerWords != triggerWords
            || shipped.usesSystemInstructionsTemplate != usesSystemInstructionsTemplate
    }

    /// Puts a shipped mode's text back, keeping the user's mode settings,
    /// context opt-ins, and translation language.
    public mutating func resetToShippedText() {
        guard let builtInKey,
              let shipped = BuiltInPromptModes.shipped(forKey: builtInKey)
        else {
            return
        }
        prompt = shipped.prompt
        name = shipped.name
        summary = shipped.summary
        icon = shipped.icon
        triggerWords = shipped.triggerWords
        usesSystemInstructionsTemplate = shipped.usesSystemInstructionsTemplate
    }

    public var isUsable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var menuTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? behavior.rawValue.capitalized : trimmed
    }

    /// The system prompt a request carries for this mode: the instructions,
    /// wrapped in the house template when asked, followed by the addenda the
    /// mode settings turn on. Translate placeholders are left for the request
    /// path to resolve; the second-translation placeholders are resolved here
    /// because the request path knows only one target language.
    public var effectiveSystemPrompt: String {
        var text = usesSystemInstructionsTemplate
            ? PromptTemplate.wrapping(instructions: prompt)
            : prompt
        for addendum in options.addenda(for: behavior) {
            text = text.trimmingTrailingNewlines() + "\n\n" + addendum
        }
        return text
    }

    /// Which optional settings card the UI shows for this action.
    public var settingsFamily: PromptModeSettingsFamily {
        switch behavior {
        case .translate:
            return .translate
        case .polish:
            if builtInKey == BuiltInPromptModes.Key.questionAnswer { return .questionAnswer }
            if builtInKey == BuiltInPromptModes.Key.polish { return .polish }
            return .none
        }
    }

    /// Sanitizes a typed trigger list: trimmed, non-empty, distinct
    /// case-insensitively, order kept.
    public static func normalizedTriggerWords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.compactMap { word in
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }
}

/// The Mode Settings card a built-in action gets; user actions get none.
public enum PromptModeSettingsFamily: Sendable, Equatable {
    case none
    case polish
    case translate
    case questionAnswer
}

/// Per-mode settings. Each one appends a shipped instruction block to the
/// effective prompt rather than editing the prompt text, so Reset never
/// discards them and the user can combine them freely.
public struct PromptModeOptions: Codable, Sendable, Equatable, Hashable {
    /// Polish: append the formal-writing rules.
    public var formalWriting: Bool
    /// Polish: append the professional (high-EQ) rules.
    public var professionalTone: Bool
    /// Translate: also translate into this second language.
    public var secondTranslationLanguage: TranslationLanguage?
    /// Translate: append the cleaned source text after the translation.
    public var showsOriginalTranscript: Bool
    /// Q&A: put the question above the answer.
    public var showsQuestionBeforeAnswer: Bool

    public init(
        formalWriting: Bool = false,
        professionalTone: Bool = false,
        secondTranslationLanguage: TranslationLanguage? = nil,
        showsOriginalTranscript: Bool = false,
        showsQuestionBeforeAnswer: Bool = false
    ) {
        self.formalWriting = formalWriting
        self.professionalTone = professionalTone
        self.secondTranslationLanguage = secondTranslationLanguage
        self.showsOriginalTranscript = showsOriginalTranscript
        self.showsQuestionBeforeAnswer = showsQuestionBeforeAnswer
    }

    private enum CodingKeys: String, CodingKey {
        case formalWriting, professionalTone, secondTranslationLanguage
        case showsOriginalTranscript, showsQuestionBeforeAnswer
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formalWriting = try values.decodeIfPresent(Bool.self, forKey: .formalWriting) ?? false
        professionalTone = try values.decodeIfPresent(Bool.self, forKey: .professionalTone) ?? false
        secondTranslationLanguage = try values.decodeIfPresent(
            TranslationLanguage.self,
            forKey: .secondTranslationLanguage
        )
        showsOriginalTranscript = try values.decodeIfPresent(Bool.self, forKey: .showsOriginalTranscript) ?? false
        showsQuestionBeforeAnswer = try values.decodeIfPresent(Bool.self, forKey: .showsQuestionBeforeAnswer) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if formalWriting { try container.encode(formalWriting, forKey: .formalWriting) }
        if professionalTone { try container.encode(professionalTone, forKey: .professionalTone) }
        try container.encodeIfPresent(secondTranslationLanguage, forKey: .secondTranslationLanguage)
        if showsOriginalTranscript { try container.encode(showsOriginalTranscript, forKey: .showsOriginalTranscript) }
        if showsQuestionBeforeAnswer { try container.encode(showsQuestionBeforeAnswer, forKey: .showsQuestionBeforeAnswer) }
    }

    /// The shipped blocks to append for a behavior, in a fixed order.
    func addenda(for behavior: AIMode) -> [String] {
        var blocks: [String] = []
        switch behavior {
        case .polish:
            if formalWriting { blocks.append(PromptTemplate.addendum(.formalWriting)) }
            if professionalTone { blocks.append(PromptTemplate.addendum(.professional)) }
            if showsQuestionBeforeAnswer { blocks.append(PromptTemplate.addendum(.showQuestion)) }
        case .translate:
            if let second = secondTranslationLanguage {
                blocks.append(
                    PromptTemplate.addendum(.secondTranslation)
                        .replacingOccurrences(of: "{secondTargetLanguageDisplayName}", with: second.displayName)
                        .replacingOccurrences(of: "{secondTargetLanguageBCP47}", with: second.bcp47)
                )
            }
            if showsOriginalTranscript { blocks.append(PromptTemplate.addendum(.showOriginal)) }
        }
        return blocks
    }
}

/// The shipped `<SYSTEM_INSTRUCTIONS>` template and the mode-settings addenda.
public enum PromptTemplate {
    public static let version = 1

    public enum Addendum: String, CaseIterable, Sendable {
        case formalWriting = "addendum-formal-writing-v1"
        case professional = "addendum-professional-v1"
        case secondTranslation = "addendum-second-translation-v1"
        case showOriginal = "addendum-show-original-v1"
        case showQuestion = "addendum-show-question-v1"
    }

    /// The house template with `{instructions}` unresolved.
    public static var systemInstructionsTemplate: String {
        BuiltInPromptModes.loadPrompt("system-instructions-template-v1")
    }

    /// Wraps user instructions in the house template.
    public static func wrapping(instructions: String) -> String {
        systemInstructionsTemplate.replacingOccurrences(
            of: "{instructions}",
            with: instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public static func addendum(_ addendum: Addendum) -> String {
        BuiltInPromptModes.loadPrompt(addendum.rawValue).trimmingTrailingNewlines()
    }
}

/// The prompts kvoice ships.
///
/// Each entry has a fixed identifier and a fixed UUID so a selection survives
/// relaunches and so a revised copy can still be matched back to its original.
public enum BuiltInPromptModes {
    public static let version = 3

    public enum Key {
        public static let clean = "builtin.clean.v2"
        public static let polish = "builtin.polish.v2"
        public static let email = "builtin.email.v2"
        public static let notes = "builtin.notes.v2"
        public static let promptRewrite = "builtin.prompt.v2"
        public static let translate = "builtin.translate.v2"
        // MARK: AI actions
        public static let writing = "builtin.writing.v2"
        public static let emailDraft = "builtin.emaildraft.v2"
        public static let summarize = "builtin.summarize.v2"
        public static let todo = "builtin.todo.v2"
        public static let questionAnswer = "builtin.qa.v2"
        public static let terminal = "builtin.terminal.v2"
        public static let translate2 = "builtin.translate2.v2"
    }

    /// Deterministic so identifiers are stable across launches and machines.
    static func identifier(for key: String) -> UUID {
        // A fixed namespace hashed with the key; UUID(uuidString:) on a derived
        // hex string keeps this dependency-free and reproducible.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        var second: UInt64 = 0x9e37_79b9_7f4a_7c15 ^ hash
        second = (second ^ (second >> 30)) &* 0xbf58_476d_1ce4_e5b9
        let hex = String(format: "%016lx%016lx", hash, second)
        let formatted = [
            hex.prefix(8),
            hex.dropFirst(8).prefix(4),
            hex.dropFirst(12).prefix(4),
            hex.dropFirst(16).prefix(4),
            hex.dropFirst(20).prefix(12)
        ].joined(separator: "-")
        // The derived string is always a valid UUID shape.
        return UUID(uuidString: formatted) ?? UUID()
    }

    private static let english = TranslationLanguage(bcp47: "en", displayName: "English")

    /// Shipped order is the ⌘1–⌘0 order for a fresh install.
    public static var all: [PromptMode] {
        [
            mode(
                key: Key.clean, name: "Clean Up", behavior: .polish, resource: "clean-default-v2",
                summary: "Minimal cleanup: remove fillers and false starts; keep wording, tone, and structure.",
                icon: "🧹"
            ),
            mode(
                key: Key.polish, name: "Polish", behavior: .polish, resource: "polish-default-v2",
                summary: "Improve clarity and flow, fix grammar and recognition slips; keep the language mix.",
                icon: "✨"
            ),
            mode(
                key: Key.email, name: "Message", behavior: .polish, resource: "email-default-v2",
                summary: "Rewrite as a clear, courteous message ready to send.",
                icon: "💬"
            ),
            mode(
                key: Key.notes, name: "Notes", behavior: .polish, resource: "notes-default-v2",
                summary: "Restructure spoken thinking into short, grouped notes.",
                icon: "📝"
            ),
            mode(
                key: Key.promptRewrite, name: "Prompt", behavior: .polish, resource: "prompt-default-v2",
                summary: "Turn a spoken request into a precise prompt for an AI assistant.",
                icon: "🧠"
            ),
            mode(
                key: Key.writing, name: "Writing", behavior: .polish, resource: "writing-default-v2",
                summary: "Formal rewrite: polite, concise, fixes homophone and recognition slips, keeps details.",
                icon: "✍️",
                triggerWords: ["formal writing"]
            ),
            mode(
                key: Key.emailDraft, name: "Email Draft", behavior: .polish, resource: "email-draft-default-v2",
                summary: "Polite, concise email with greeting and sign-off; facts intact.",
                icon: "✉️",
                triggerWords: ["draft email", "email draft"]
            ),
            mode(
                key: Key.summarize, name: "Summarize", behavior: .polish, resource: "summarize-default-v2",
                summary: "Concise bullets that keep every decision, number, and name.",
                icon: "📋",
                triggerWords: ["summarize", "summarise"]
            ),
            mode(
                key: Key.todo, name: "TODO List", behavior: .polish, resource: "todo-default-v2",
                summary: "Turn speech into a checklist of actionable tasks; skip cancelled items.",
                icon: "☑️",
                triggerWords: ["todo list", "to-do list", "to do list"]
            ),
            mode(
                key: Key.questionAnswer, name: "Q&A", behavior: .polish, resource: "qa-default-v2",
                summary: "Answer the dictated question directly; steps or code only when needed.",
                icon: "❓",
                triggerWords: ["question", "quick question"]
            ),
            mode(
                key: Key.terminal, name: "Terminal", behavior: .polish, resource: "terminal-default-v2",
                summary: "Speech to one safe shell command. Nothing is executed.",
                icon: "⌨️",
                triggerWords: ["terminal", "shell command"]
            ),
            mode(
                key: Key.translate, name: "Translate", behavior: .translate, resource: "translate-default-v2",
                summary: "Lightly clean the speech and translate it into the target language.",
                icon: "🌐",
                triggerWords: ["translate"],
                translationLanguage: english
            ),
            mode(
                key: Key.translate2, name: "Translate 2", behavior: .translate, resource: "translate2-default-v2",
                summary: "A second translation target for two-way conversations without switching back and forth.",
                icon: "🔁",
                triggerWords: ["translate two", "translate 2"],
                translationLanguage: TranslationLanguage(bcp47: "zh-Hans", displayName: "Chinese, Simplified")
            )
        ]
    }

    public static func shipped(forKey key: String) -> PromptMode? {
        all.first { $0.builtInKey == key }
    }

    private static func mode(
        key: String,
        name: String,
        behavior: AIMode,
        resource: String,
        summary: String,
        icon: String,
        triggerWords: [String] = [],
        translationLanguage: TranslationLanguage? = nil
    ) -> PromptMode {
        PromptMode(
            id: identifier(for: key),
            name: name,
            behavior: behavior,
            prompt: loadPrompt(resource),
            builtInKey: key,
            translationLanguage: translationLanguage,
            summary: summary,
            icon: icon,
            triggerWords: triggerWords
        )
    }

    static func loadPrompt(_ resource: String) -> String {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "txt"),
              let data = try? Data(contentsOf: url),
              let prompt = String(data: data, encoding: .utf8)
        else {
            preconditionFailure("Missing bundled prompt resource: \(resource)")
        }
        return prompt
    }
}

extension String {
    func trimmingTrailingNewlines() -> String {
        var text = Substring(self)
        while let last = text.last, last == "\n" || last == "\r" {
            text.removeLast()
        }
        return String(text)
    }
}
