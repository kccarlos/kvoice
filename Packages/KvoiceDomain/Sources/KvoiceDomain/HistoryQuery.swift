import Foundation

// MARK: - Filters

/// The time-range choices in the History window.
public enum HistoryTimeRange: String, Codable, Sendable, Equatable, CaseIterable {
    case last24Hours
    case last7Days
    case last14Days
    case last30Days
    case last90Days
    case last180Days
    case lastYear
    case all

    public var displayName: String {
        switch self {
        case .last24Hours: return "Last 24 hours"
        case .last7Days: return "Last 7 days"
        case .last14Days: return "Last 14 days"
        case .last30Days: return "Last 30 days"
        case .last90Days: return "Last 90 days"
        case .last180Days: return "Last 180 days"
        case .lastYear: return "Last year"
        case .all: return "All time"
        }
    }

    /// Seconds covered, or `nil` for everything.
    public var interval: TimeInterval? {
        switch self {
        case .last24Hours: return 86_400
        case .last7Days: return 7 * 86_400
        case .last14Days: return 14 * 86_400
        case .last30Days: return 30 * 86_400
        case .last90Days: return 90 * 86_400
        case .last180Days: return 180 * 86_400
        case .lastYear: return 365 * 86_400
        case .all: return nil
        }
    }

    public func startDate(now: Date) -> Date? {
        interval.map { now.addingTimeInterval(-$0) }
    }
}

/// Recording-length buckets.  Rows written before the recording duration was
/// stored (schema v1) never match a bucket.
public enum HistoryDurationBucket: String, Codable, Sendable, Equatable, CaseIterable {
    case under15Seconds
    case from15SecondsTo1Minute
    case from1To5Minutes
    case over5Minutes

    public var displayName: String {
        switch self {
        case .under15Seconds: return "Under 15 seconds"
        case .from15SecondsTo1Minute: return "15 seconds to 1 minute"
        case .from1To5Minutes: return "1 to 5 minutes"
        case .over5Minutes: return "Over 5 minutes"
        }
    }

    /// Half-open `[lower, upper)` in milliseconds; `upper` is `nil` for the
    /// last bucket.
    public var milliseconds: (lower: Int, upper: Int?) {
        switch self {
        case .under15Seconds: return (0, 15_000)
        case .from15SecondsTo1Minute: return (15_000, 60_000)
        case .from1To5Minutes: return (60_000, 300_000)
        case .over5Minutes: return (300_000, nil)
        }
    }

    public func contains(milliseconds value: Int?) -> Bool {
        guard let value else { return false }
        let bounds = milliseconds
        if value < bounds.lower { return false }
        if let upper = bounds.upper, value >= upper { return false }
        return true
    }
}

/// What a History query narrows to.  Values are concrete (`since` is a
/// date, not a range name) so the repository never needs a clock.
public struct HistoryFilter: Sendable, Equatable {
    /// Rows created at or after this instant; `nil` for all time.
    public var since: Date?
    /// Inclusive lower bound on `recordingDurationMilliseconds`.
    public var minimumDurationMilliseconds: Int?
    /// Exclusive upper bound on `recordingDurationMilliseconds`.
    public var maximumDurationMilliseconds: Int?
    /// Substring over raw and final text (case-folded); whitespace-only is
    /// treated as no query.  Never leaves the process (FR-HIST-009).
    public var query: String

    public static let all = HistoryFilter()

    public init(
        since: Date? = nil,
        minimumDurationMilliseconds: Int? = nil,
        maximumDurationMilliseconds: Int? = nil,
        query: String = ""
    ) {
        self.since = since
        self.minimumDurationMilliseconds = minimumDurationMilliseconds
        self.maximumDurationMilliseconds = maximumDurationMilliseconds
        self.query = query
    }

    public init(
        timeRange: HistoryTimeRange,
        durationBucket: HistoryDurationBucket?,
        query: String = "",
        now: Date
    ) {
        since = timeRange.startDate(now: now)
        if let durationBucket {
            let bounds = durationBucket.milliseconds
            minimumDurationMilliseconds = bounds.lower
            maximumDurationMilliseconds = bounds.upper
        } else {
            minimumDurationMilliseconds = nil
            maximumDurationMilliseconds = nil
        }
        self.query = query
    }

    /// The trimmed query, or `nil` when there is nothing to search for.
    public var normalizedQuery: String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public var restrictsDuration: Bool {
        minimumDurationMilliseconds != nil || maximumDurationMilliseconds != nil
    }

    public var isEmpty: Bool {
        since == nil && !restrictsDuration && normalizedQuery == nil
    }

    /// In-memory evaluation, used by the default repository implementation
    /// and by fakes.  The SQLite store evaluates the same rules in SQL.
    public func matches(_ entry: HistoryEntry) -> Bool {
        if let since, entry.createdAt < since { return false }
        if restrictsDuration {
            guard let duration = entry.recordingDurationMilliseconds else { return false }
            if let lower = minimumDurationMilliseconds, duration < lower { return false }
            if let upper = maximumDurationMilliseconds, duration >= upper { return false }
        }
        if let needle = normalizedQuery {
            let haystackMatches = entry.rawText.localizedCaseInsensitiveContains(needle)
                || entry.finalText.localizedCaseInsensitiveContains(needle)
            if !haystackMatches { return false }
        }
        return true
    }
}

// MARK: - Aggregates

/// SQL aggregates over a filtered set of rows, for the dashboard tiles.
/// Everything derived (words per minute, time saved) is computed by the view
/// model from these sums so the repository stays a plain counter.
public struct HistoryStatistics: Sendable, Equatable {
    public var sessionCount: Int
    public var wordCount: Int
    /// Characters of final text; the "keystrokes saved" figure.
    public var characterCount: Int
    /// Sum of `recordingDurationMilliseconds` over rows that have one.
    public var recordingMilliseconds: Int
    /// Rows with a stored AI duration, and their sum.
    public var aiSessionCount: Int
    public var aiMilliseconds: Int

    public static let empty = HistoryStatistics()

    public init(
        sessionCount: Int = 0,
        wordCount: Int = 0,
        characterCount: Int = 0,
        recordingMilliseconds: Int = 0,
        aiSessionCount: Int = 0,
        aiMilliseconds: Int = 0
    ) {
        self.sessionCount = sessionCount
        self.wordCount = wordCount
        self.characterCount = characterCount
        self.recordingMilliseconds = recordingMilliseconds
        self.aiSessionCount = aiSessionCount
        self.aiMilliseconds = aiMilliseconds
    }

    /// Folds one entry in; the default repository implementation and fakes
    /// use this so their figures agree with the SQL.
    public mutating func add(_ entry: HistoryEntry) {
        sessionCount += 1
        wordCount += entry.wordCount
        // Unicode scalars, not graphemes: SQLite's LENGTH() on TEXT counts
        // code points, and the SQL and in-memory figures must agree.
        characterCount += entry.finalText.unicodeScalars.count
        recordingMilliseconds += entry.recordingDurationMilliseconds ?? 0
        if let ai = entry.aiDurationMilliseconds {
            aiSessionCount += 1
            aiMilliseconds += ai
        }
    }

    public static func aggregate(_ entries: some Sequence<HistoryEntry>) -> HistoryStatistics {
        var statistics = HistoryStatistics()
        for entry in entries {
            statistics.add(entry)
        }
        return statistics
    }
}

/// Result of an age-based cleanup pass over rows.
public struct HistoryCleanupResult: Sendable, Equatable {
    public var deletedEntryCount: Int
    /// Relative audio paths that belonged to the deleted rows, so the caller
    /// can remove the files.  The repository never touches audio files.
    public var releasedAudioPaths: [String]

    public init(deletedEntryCount: Int = 0, releasedAudioPaths: [String] = []) {
        self.deletedEntryCount = deletedEntryCount
        self.releasedAudioPaths = releasedAudioPaths
    }
}

// MARK: - Word counting

public enum TranscriptMetrics {
    /// Words as the text system segments them, which handles scripts without
    /// spaces (CJK) instead of splitting on whitespace.
    public static func wordCount(of text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }
}
