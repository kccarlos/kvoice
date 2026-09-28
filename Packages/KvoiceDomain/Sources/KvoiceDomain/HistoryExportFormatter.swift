import Foundation

/// Text renderings of history rows for export.  Pure functions over
/// `HistoryEntry`; file placement belongs to whoever calls them.
///
/// Times are rendered in the given time zone (the user's, by default) with
/// fixed ISO-style formats so an export reads the same on every Mac and sorts
/// as text.
public enum HistoryExportFormatter {
    /// Header row of the CSV export, in column order.
    public static let csvColumns = [
        "date", "time", "duration_seconds", "mode", "ai_status", "model",
        "insertion", "word_count", "original", "enhanced"
    ]

    /// One CSV document (RFC 4180: comma separated, CRLF rows, fields quoted
    /// when they contain a comma, quote, or line break) for the given rows.
    public static func csv(_ entries: [HistoryEntry], timeZone: TimeZone = .current) -> String {
        var lines = [csvColumns.joined(separator: ",")]
        for entry in entries {
            let fields: [String] = [
                dayString(entry.createdAt, timeZone: timeZone),
                timeString(entry.createdAt, timeZone: timeZone),
                entry.recordingDurationMilliseconds.map { String(format: "%.1f", Double($0) / 1_000) } ?? "",
                entry.mode.rawValue,
                entry.aiStatus.rawValue,
                entry.modelID,
                insertionLabel(entry.insertionOutcome),
                String(entry.wordCount),
                entry.rawText,
                entry.finalText
            ]
            lines.append(fields.map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func insertionLabel(_ outcome: InsertionOutcome) -> String {
        switch outcome {
        case .inserted(let method): return "inserted:\(method.rawValue)"
        case .copiedToClipboard(let reason): return "copied:\(reason.rawValue)"
        case .deliveredInApp: return "inApp"
        case .abortedAtTermination: return "aborted"
        }
    }

    static func csvField(_ value: String) -> String {
        let needsQuotes = value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Markdown heading for a day's file.
    public static func markdownDayHeader(_ day: Date, timeZone: TimeZone = .current) -> String {
        "# Dictations — \(dayString(day, timeZone: timeZone))\n"
    }

    /// One entry as a Markdown section: a time heading, the final text, and
    /// the original transcript in a collapsed block when AI changed it.
    public static func markdownSection(_ entry: HistoryEntry, timeZone: TimeZone = .current) -> String {
        var heading = "## \(timeString(entry.createdAt, timeZone: timeZone))"
        var badges: [String] = []
        if let milliseconds = entry.recordingDurationMilliseconds {
            badges.append(durationLabel(milliseconds: milliseconds))
        }
        if entry.mode != .off {
            badges.append(entry.mode.rawValue.capitalized)
        }
        if !badges.isEmpty {
            heading += " · " + badges.joined(separator: " · ")
        }
        var section = heading + "\n\n" + entry.finalText.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        if entry.hasDistinctEnhancedText {
            section += "\n<details><summary>Original transcript</summary>\n\n"
                + entry.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n</details>\n"
        }
        return section
    }

    /// A whole day's Markdown file: header plus every entry, oldest first.
    public static func markdownDay(_ day: Date, entries: [HistoryEntry], timeZone: TimeZone = .current) -> String {
        var document = markdownDayHeader(day, timeZone: timeZone)
        for entry in entries.sorted(by: { $0.createdAt < $1.createdAt }) {
            document += "\n" + markdownSection(entry, timeZone: timeZone)
        }
        return document
    }

    /// Groups rows by calendar day in `timeZone`, keyed by the file name
    /// (`YYYY-MM-DD`).
    public static func groupedByDay(_ entries: [HistoryEntry], timeZone: TimeZone = .current) -> [String: [HistoryEntry]] {
        Dictionary(grouping: entries) { dayString($0.createdAt, timeZone: timeZone) }
    }

    /// Plain-text rendering of selected rows: final text separated by blank
    /// lines, each preceded by its timestamp.
    public static func plainText(_ entries: [HistoryEntry], timeZone: TimeZone = .current) -> String {
        entries.sorted(by: { $0.createdAt < $1.createdAt }).map { entry in
            "[\(dayString(entry.createdAt, timeZone: timeZone)) \(timeString(entry.createdAt, timeZone: timeZone))]\n"
                + entry.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .joined(separator: "\n\n") + "\n"
    }

    /// Markdown for a selection (not a whole day): one section per row.
    public static func markdown(_ entries: [HistoryEntry], timeZone: TimeZone = .current) -> String {
        entries.sorted(by: { $0.createdAt < $1.createdAt })
            .map { markdownSection($0, timeZone: timeZone) }
            .joined(separator: "\n")
    }

    /// `YYYY-MM-DD`, the daily file's name.
    public static func dayString(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter(timeZone, "yyyy-MM-dd").string(from: date)
    }

    public static func timeString(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter(timeZone, "HH:mm:ss").string(from: date)
    }

    static func durationLabel(milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private static func formatter(_ timeZone: TimeZone, _ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
