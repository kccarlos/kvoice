import Foundation
import KvoiceDomain

/// The two Manage Models options that shape the text handed to the insertion
/// tiers (`AppSettings.addSpaceAfterInsertion`, `.automaticTextFormatting`).
///
/// Pure and applied in exactly one place, `DictationController.performInsertion`,
/// so the transcript stored in history and shown for an in-app delivery stays
/// the model's (or the AI's) verbatim output: only what is typed into the
/// target changes. Kept deliberately conservative: "formatting" is whitespace
/// normalisation only. It never adds punctuation or changes case, because the
/// same text may be inserted into a terminal (ADR-016), where `Ls` or a
/// trailing period turns a command into an error; capitalisation and
/// punctuation are the model's and the AI actions' job (KNOWN_ISSUES,
/// accepted deviations).
public enum InsertionTextPreparation {
    /// Applies the options in order: formatting first, then the trailing
    /// space, so the space is never trimmed away or duplicated.
    public static func prepare(_ text: String, settings: AppSettings) -> String {
        var result = text
        if settings.automaticTextFormatting {
            result = format(result)
        }
        if settings.addSpaceAfterInsertion, let last = result.last, !last.isWhitespace {
            result += " "
        }
        return result
    }

    /// "Automatic text formatting": trims the ends and collapses runs of
    /// spaces and tabs inside a line (newlines are kept; the typed tier turns
    /// them into spaces itself).
    static func format(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
    }
}
