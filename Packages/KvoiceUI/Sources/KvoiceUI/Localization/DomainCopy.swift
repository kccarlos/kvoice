import Foundation
import KvoiceDomain
import SwiftUI

/// The localization seam between `KvoiceDomain` and the screen.
///
/// The domain composes plain English and knows nothing about bundles
/// (`DomainUserFacingCopy` in KvoiceDomain explains the contract). Every
/// surface that shows a domain string — the HUD, the status menu, a picker of
/// domain enum names — passes it through `DomainCopy.localized(_:)`, which
/// looks the English up as a key in KvoiceUI's `DomainCopy.xcstrings` table.
/// An unknown string comes back unchanged, so a new domain sentence is never
/// lost; it is merely shown in English until it is added to the table (the
/// `DomainCopyTests` coverage test fails until then).
///
/// Composition: `CompletionSummary.attaching` joins several sentences with a
/// space and fills the recording-cap format with a duration. Rather than
/// teaching the domain about localization, `localized(_:)` recognises those
/// shapes — an exact key first, then the cap line, then a greedy split into
/// known sentences — and localizes each piece.
public enum DomainCopy {
    public static let table = "DomainCopy"

    /// Where translations come from. The default reads the `DomainCopy`
    /// table of KvoiceUI's resource bundle (compiled by Xcode into
    /// `<lang>.lproj`); tests inject a dictionary parsed from the catalog,
    /// because `swift build` copies `.xcstrings` files without compiling them,
    /// so no `.lproj` exists under SwiftPM.
    public struct Table: Sendable {
        public let lookup: @Sendable (String) -> String?

        public init(lookup: @escaping @Sendable (String) -> String?) {
            self.lookup = lookup
        }

        /// A sentinel `value:` distinguishes "not in the table" from "the
        /// translation happens to equal the key" (English resolving to
        /// English).
        public static func bundle(_ bundle: Bundle, table name: String = DomainCopy.table) -> Table {
            let missing = "\u{0}kvoice.missing\u{0}"
            return Table { key in
                let value = bundle.localizedString(forKey: key, value: missing, table: name)
                return value == missing ? nil : value
            }
        }

        public static func dictionary(_ entries: [String: String]) -> Table {
            Table { entries[$0] }
        }

        public static let module = Table.bundle(KvoiceUIResources.bundle)
    }

    /// Localizes one domain string for the current language.
    public static func localized(_ english: String, table: Table = .module) -> String {
        if let exact = table.lookup(english) {
            return exact
        }
        if let cap = localizedRecordingCap(english, table: table) {
            return cap
        }
        if let composed = localizedComposition(english, table: table) {
            return composed
        }
        return english
    }

    // MARK: Pieces

    /// "Recording stopped at the 10-minute limit." — the one domain line
    /// with a value inside it. The unit format ("%lld-minute") is a key of
    /// its own so a translation can reorder or drop the hyphen.
    private static let capParts: (prefix: String, suffix: String) = {
        let parts = DomainUserFacingCopy.recordingCapFormat.components(separatedBy: "%@")
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }()

    /// The `(count, unit)` of a cap line, or nil when `english` is not one.
    private static func parseRecordingCap(_ english: String) -> (count: Int, unit: String)? {
        guard english.hasPrefix(capParts.prefix), english.hasSuffix(capParts.suffix),
              english.count > capParts.prefix.count + capParts.suffix.count else { return nil }
        let middle = english.dropFirst(capParts.prefix.count).dropLast(capParts.suffix.count)
        let pieces = middle.split(separator: "-", maxSplits: 1)
        guard pieces.count == 2, let count = Int(pieces[0]),
              DomainUserFacingCopy.limitUnitFormats.contains("%lld-\(pieces[1])") else { return nil }
        return (count, String(pieces[1]))
    }

    private static func localizedRecordingCap(_ english: String, table: Table) -> String? {
        guard let (count, unit) = parseRecordingCap(english) else { return nil }
        let unitKey = "%lld-\(unit)"
        let unitText = String(format: table.lookup(unitKey) ?? unitKey, locale: nil, count)
        let line = table.lookup(DomainUserFacingCopy.recordingCapFormat)
            ?? DomainUserFacingCopy.recordingCapFormat
        return String(format: line, locale: nil, unitText)
    }

    /// Splits "A. B. C." into the known sentences it was joined from (longest
    /// match first, separated by single spaces) and localizes each. Nil when
    /// any piece is unknown, so a genuinely new sentence stays intact.
    private static func localizedComposition(_ english: String, table: Table) -> String? {
        var remainder = Substring(english)
        var pieces: [String] = []
        while !remainder.isEmpty {
            guard let piece = knownSentences.first(where: { sentence in
                remainder.hasPrefix(sentence)
                    && (remainder.count == sentence.count || remainder.dropFirst(sentence.count).first == " ")
            }) ?? capLinePrefix(of: remainder) else {
                return nil
            }
            // Resolve the piece directly (never through `localized`, which
            // would recurse into this splitter for a single known sentence).
            pieces.append(table.lookup(piece) ?? localizedRecordingCap(piece, table: table) ?? piece)
            remainder = remainder.dropFirst(piece.count)
            if remainder.first == " " { remainder = remainder.dropFirst() }
        }
        return pieces.count > 1 ? pieces.joined(separator: " ") : nil
    }

    private static func capLinePrefix(of text: Substring) -> String? {
        guard let end = text.range(of: capParts.suffix) else { return nil }
        let candidate = String(text[..<end.upperBound])
        return parseRecordingCap(candidate) == nil ? nil : candidate
    }

    /// Longest first so "No usable speech was recorded. Try again." wins over
    /// a shorter sentence that shares its opening.
    private static let knownSentences: [String] = DomainUserFacingCopy.messages
        .filter { !$0.contains("%") }
        .sorted { $0.count > $1.count }
}

public extension Text {
    /// A domain string (an enum `displayName`, a HUD message) shown through
    /// the `DomainCopy` seam. `Text(someString)` alone would show the English.
    init(domain english: String) {
        self.init(verbatim: DomainCopy.localized(english))
    }
}
