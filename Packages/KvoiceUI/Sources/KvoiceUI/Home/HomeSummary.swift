import Foundation
import KvoiceDomain

/// UI v2 wave 5a: what the Home page shows below the hero — today's and this
/// week's figures (the same `HistoryStatistics` aggregates the History
/// page's strip reads) and the newest saved dictations.
public struct HomeSummary: Equatable, Sendable {
    public let today: HistoryStatistics
    public let week: HistoryStatistics
    /// Newest first. Only the final text, date, length and AI action are
    /// shown; history stores no app name.
    public let recent: [HistoryEntry]

    public init(today: HistoryStatistics, week: HistoryStatistics, recent: [HistoryEntry]) {
        self.today = today
        self.week = week
        self.recent = recent
    }

    /// Nothing was ever saved (or nothing is left): the page shows the
    /// empty state instead of zeros.
    public var isEmpty: Bool { recent.isEmpty && week.sessionCount == 0 && today.sessionCount == 0 }

    /// The week's derived figures, by the History strip's own formula.
    public var weekDashboard: HistoryViewModel.Dashboard { HistoryViewModel.Dashboard(statistics: week) }

    /// The time windows the two aggregates cover. "This week" is the
    /// calendar week in the user's locale (its first weekday), not a rolling
    /// seven days, so the tile's label is literally true.
    public struct Window: Equatable, Sendable {
        public let startOfToday: Date
        public let startOfWeek: Date

        public init(now: Date, calendar: Calendar) {
            startOfToday = calendar.startOfDay(for: now)
            startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        }
    }

    /// One stat tile: a label, a figure and a hint, all display-ready.
    public struct Tile: Equatable, Sendable, Identifiable {
        public enum ID: String, Sendable { case today, week, timeSaved, pace }
        public let id: ID
        public let label: String
        public let value: String
        public let hint: String
    }

    /// The four tiles, in the design's order: Today, This week, Time saved,
    /// Your pace.
    @MainActor public var tiles: [Tile] {
        let dashboard = weekDashboard
        let pace = dashboard.wordsPerMinute.map { String(Int($0.rounded())) } ?? "—"
        return [
            Tile(
                id: .today,
                label: String(localized: "Today", bundle: .module),
                value: today.wordCount.formatted(),
                hint: String(localized: "words dictated", bundle: .module)
            ),
            Tile(
                id: .week,
                label: String(localized: "This week", bundle: .module),
                value: week.wordCount.formatted(),
                hint: String(localized: "words across \(week.sessionCount) dictations", bundle: .module)
            ),
            Tile(
                id: .timeSaved,
                label: String(localized: "Time saved", bundle: .module),
                value: Self.compactDuration(dashboard.timeSavedSeconds),
                hint: String(localized: "vs. typing at \(HistoryViewModel.assumedTypingWordsPerMinute) wpm", bundle: .module)
            ),
            Tile(
                id: .pace,
                label: String(localized: "Your pace", bundle: .module),
                value: pace,
                hint: String(localized: "words per minute spoken", bundle: .module)
            )
        ]
    }

    /// Home.dc's tile figure: "2h 31m", "31m", "45s" — tight, so the
    /// monospaced 26 pt figure reads as one value (the History strip keeps
    /// its spaced "2 h 31 m").
    static func compactDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return String(localized: "\(total)s", bundle: .module) }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        return hours > 0
            ? String(localized: "\(hours)h \(minutes)m", bundle: .module)
            : String(localized: "\(minutes)m", bundle: .module)
    }
}
