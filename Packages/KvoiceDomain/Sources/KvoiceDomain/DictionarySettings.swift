import Foundation

// MARK: Dictionary (ADR-018)

/// The user's dictionary: terms the speech model tends to misspell (product
/// names, personal names, jargon), fed to the model as its initial prompt on
/// every transcription path. Terms only — there is no correction map; the
/// prompt *biases* the decoder toward these spellings, it does not guarantee
/// them (ADR-018).
///
/// One global, ordered list. Entries are trimmed, never empty, and unique
/// case-insensitively; `normalizedTerm` and `containsTerm` are the two rules
/// every editor (the view model, an import) applies so the stored list is
/// always clean.
public struct DictionarySettings: Codable, Sendable, Equatable {
    public var terms: [String]

    public init(terms: [String] = []) {
        self.terms = Self.deduplicated(terms.compactMap(Self.normalizedTerm))
    }

    private enum CodingKeys: String, CodingKey {
        case terms
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try values.decodeIfPresent([String].self, forKey: .terms) ?? []
        terms = Self.deduplicated(stored.compactMap(Self.normalizedTerm))
    }

    /// Whitespace-trimmed, or `nil` for an entry that is empty once trimmed.
    /// Interior whitespace is kept (a term may be two words), but runs of it
    /// collapse to one space so "Whisper  Kit" and "Whisper Kit" are the same
    /// entry.
    public static func normalizedTerm(_ raw: String) -> String? {
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Case-insensitive membership, the dedupe rule.
    public func containsTerm(_ term: String) -> Bool {
        Self.contains(terms, term)
    }

    /// One term per line, the Import/Export file format. Blank lines and
    /// duplicates are dropped; order is kept.
    public static func parse(fileContents: String) -> [String] {
        deduplicated(
            fileContents
                .components(separatedBy: .newlines)
                .compactMap(normalizedTerm)
        )
    }

    /// The Export file: one term per line with a trailing newline.
    public var fileContents: String {
        terms.isEmpty ? "" : terms.joined(separator: "\n") + "\n"
    }

    /// Case-insensitive membership of `term` in an arbitrary list, for
    /// editors that check a candidate list before it becomes settings.
    public static func contains(_ terms: [String], _ term: String) -> Bool {
        terms.contains { $0.caseInsensitiveCompare(term) == .orderedSame }
    }

    /// First occurrence wins, compared case-insensitively.
    public static func deduplicated(_ terms: [String]) -> [String] {
        var kept: [String] = []
        for term in terms where !contains(kept, term) {
            kept.append(term)
        }
        return kept
    }
}

/// Renders the dictionary as the initial prompt Whisper sees.
///
/// Whisper's prompt is conditioning text the decoder treats as the preceding
/// transcript, so it should read like something a person would have said or
/// written: a short lead-in and a comma-separated list is the shape that
/// biases spellings reliably in practice (and the one WhisperKit's own CLI
/// documents). The exact template is a constant so a test can pin it and a
/// future model can be given another one in one place.
public enum DictionaryPrompt {
    /// "Glossary: kvoice, WhisperKit, Cosima."
    public static let leadIn = "Glossary: "
    public static let separator = ", "
    public static let terminator = "."

    /// `nil` when there are no terms, so an empty dictionary sends no prompt
    /// at all (a bare lead-in would bias the model toward ending early).
    public static func render(terms: [String]) -> String? {
        let clean = terms.compactMap(DictionarySettings.normalizedTerm)
        guard !clean.isEmpty else { return nil }
        return leadIn + clean.joined(separator: separator) + terminator
    }

    public static func render(_ settings: DictionarySettings) -> String? {
        render(terms: settings.terms)
    }

    /// ADR-025: the inverse of `render(terms:)`, for a runtime that takes
    /// the dictionary as a phrase list rather than as text (Apple Speech's
    /// contextual strings). The engines receive only the rendered prompt
    /// (`TranscriptionRequest.initialPrompt`, `beginStreaming`'s
    /// `initialPrompt`), so the phrase-list runtime recovers the terms from
    /// it here instead of widening every engine's signature. Lossy by
    /// design where the rendering is: a term containing `", "` comes back
    /// as two phrases — still usable recognition hints (a term ending in
    /// `"."` keeps it: the render appends its own terminator, and only
    /// that one is stripped). Anything that is not a rendered
    /// prompt (no lead-in) is returned as one phrase, so a caller never
    /// loses a hint to a format change; `nil` and empty give `[]`.
    public static func terms(fromRendered prompt: String?) -> [String] {
        guard var body = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return [] }
        guard body.hasPrefix(leadIn) else { return [body] }
        body.removeFirst(leadIn.count)
        if body.hasSuffix(terminator) { body.removeLast(terminator.count) }
        return body
            .components(separatedBy: separator)
            .compactMap(DictionarySettings.normalizedTerm)
    }

    /// A tokenizer-free estimate for when no model is resident, labelled "≈"
    /// in the UI. Whisper's byte-pair tokenizer averages about one token per
    /// four Latin characters (including the space before a word) and about
    /// 1.5 tokens per CJK ideograph (most Han characters are two or three
    /// UTF-8 bytes and split across one or two merges). Deliberately
    /// pessimistic on the CJK side so a list built without a model still
    /// fits once the real tokenizer counts it; the 10 % reserve in
    /// `DictionaryTokenBudget` covers the rest of the drift.
    public static func estimatedTokenCount(of text: String) -> Int {
        var latinCharacters = 0
        var cjkCharacters = 0
        for scalar in text.unicodeScalars {
            if Self.isCJK(scalar) {
                cjkCharacters += 1
            } else {
                latinCharacters += 1
            }
        }
        let latin = Int((Double(latinCharacters) / 4.0).rounded(.up))
        let cjk = Int((Double(cjkCharacters) * 1.5).rounded(.up))
        return latin + cjk
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xAC00...0xD7AF, // Hangul syllables
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0x20000...0x2FFFF: // CJK Extensions B–F
            return true
        default:
            return false
        }
    }
}

/// How the resident model takes an initial prompt. Reported by the engine
/// for whatever is loaded, so a future runtime with a different context — or
/// none — plugs in without touching the UI (ADR-018).
public enum PromptTokenLimit: Sendable, Equatable {
    /// The model or runtime accepts no prompt; the Dictionary section says so
    /// and hides its counter.
    case unsupported
    /// The *effective* cap the runtime enforces on the prompt's own tokens,
    /// before any special tokens it adds itself.
    case tokens(Int)
    /// ADR-025: the runtime takes the dictionary not as conditioning text
    /// but as a list of contextual phrases (Apple Speech's
    /// `AnalysisContext.contextualStrings`), at most `count` of them. There
    /// is no token budget: the section shows a phrase count instead and the
    /// engine sends the first `count` terms.
    case phrases(Int)

    public var tokens: Int? {
        if case let .tokens(count) = self { return count }
        return nil
    }

    /// The phrase cap for a `.phrases` runtime, nil otherwise.
    public var phrases: Int? {
        if case let .phrases(count) = self { return count }
        return nil
    }
}

/// Counts prompt tokens with the resident model's own tokenizer and reports
/// the resident model's prompt limit. Implemented by the transcription engine
/// (`WhisperTranscriptionEngine` over WhisperKit's tokenizer); the Dictionary
/// view model falls back to `DictionaryPrompt.estimatedTokenCount` and the
/// catalog's `promptTokenLimit` while nothing is loaded.
public protocol PromptTokenCounting: Sendable {
    /// `nil` while no model is resident.
    func promptTokenLimit() async -> PromptTokenLimit?
    /// Tokens of `text` as the resident runtime will encode it, or `nil` while
    /// no model is resident.
    func promptTokenCount(of text: String) async -> Int?
}

/// The user-facing budget derived from a prompt limit: the limit minus a
/// reserve. The reserve exists because the counter is an estimate while no
/// model is resident and the estimate must err on the safe side, and because
/// the limit is what the runtime *truncates* at — a list that sits exactly on
/// it leaves the decoder no slack when a term tokenizes worse than expected.
/// Ten percent (rounded up) is the documented choice: 224 → 201, 111 → 99.
public struct DictionaryTokenBudget: Sendable, Equatable {
    /// The compiled reserve (`DeveloperDefaults.dictionaryReserveFraction`).
    public static let reserveFraction = 0.10

    /// The effective prompt limit the budget was derived from.
    public let promptTokenLimit: Int
    /// Whether the limit came from the resident runtime (`true`) or from the
    /// catalog's entry for the default model while nothing is loaded.
    public let isFromResidentModel: Bool
    /// The share held back, from the developer defaults (ADR-022 slice 5).
    public let reserveFraction: Double

    public init(promptTokenLimit: Int, isFromResidentModel: Bool, reserveFraction: Double = DictionaryTokenBudget.reserveFraction) {
        self.promptTokenLimit = max(0, promptTokenLimit)
        self.isFromResidentModel = isFromResidentModel
        self.reserveFraction = min(0.9, max(0, reserveFraction))
    }

    public var reserve: Int {
        Int((Double(promptTokenLimit) * reserveFraction).rounded(.up))
    }

    /// The number the counter shows as its ceiling ("137 / 201 tokens").
    public var budget: Int {
        max(0, promptTokenLimit - reserve)
    }

    /// Combines the two sources of truth. The resident runtime wins when a
    /// model is loaded (it is what will actually truncate); the catalog's
    /// value stands in while nothing is resident, capped by the resident
    /// limit when both are known so a model whose runtime enforces less than
    /// the model's own context (WhisperKit: 111 of Whisper's 224) is never
    /// shown the larger number. `nil` means "no prompt": the resident model
    /// reports `.unsupported`, or nothing is resident and the catalog entry
    /// carries no limit.
    public static func resolve(
        catalogLimit: Int?,
        residentLimit: PromptTokenLimit?,
        reserveFraction: Double = DictionaryTokenBudget.reserveFraction
    ) -> DictionaryTokenBudget? {
        switch residentLimit {
        case .unsupported, .phrases:
            // No prompt, or no *token* budget: a phrase-list runtime
            // (ADR-025) is presented by count, not by tokens.
            return nil
        case let .tokens(runtimeLimit):
            let limit = catalogLimit.map { min($0, runtimeLimit) } ?? runtimeLimit
            return DictionaryTokenBudget(promptTokenLimit: limit, isFromResidentModel: true, reserveFraction: reserveFraction)
        case nil:
            guard let catalogLimit else { return nil }
            return DictionaryTokenBudget(promptTokenLimit: catalogLimit, isFromResidentModel: false, reserveFraction: reserveFraction)
        }
    }
}
