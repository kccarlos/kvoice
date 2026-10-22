import Foundation
import XCTest
@testable import KvoiceDomain
@testable import KvoiceUI

/// UI v2 wave 5a: the Home page's figures, recent rows and hero copy.
@MainActor
final class HomeSummaryTests: XCTestCase {
    /// Tuesday 2023-11-14 22:13:20 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    func testWindowIsTheCalendarDayAndTheCalendarWeek() {
        let window = HomeSummary.Window(now: now, calendar: calendar)
        XCTAssertEqual(window.startOfToday, Date(timeIntervalSince1970: 1_699_920_000), "Tue 00:00 UTC")
        XCTAssertEqual(window.startOfWeek, Date(timeIntervalSince1970: 1_699_833_600), "Mon 00:00 UTC (first weekday)")
    }

    func testRefreshHomeReadsTodayAndThisWeekFromTheRepositoryNotThePageFilters() async throws {
        let window = HomeSummary.Window(now: now, calendar: calendar)
        let today = entry(at: now.addingTimeInterval(-60), text: "one two three four", ms: 60_000, ai: .succeeded)
        let earlierThisWeek = entry(at: window.startOfToday.addingTimeInterval(-3_600), text: "five six", ms: 30_000)
        let lastWeek = entry(at: window.startOfWeek.addingTimeInterval(-3_600), text: "a b c d e", ms: 30_000)
        let older = entry(at: now.addingTimeInterval(-40 * 86_400), text: "old", ms: 1_000)
        let older2 = entry(at: now.addingTimeInterval(-41 * 86_400), text: "older", ms: 1_000)
        let repository = TestHistoryRepository(entries: [today, earlierThisWeek, lastWeek, older, older2])
        let model = HistoryViewModel(repository: repository, now: { [now] in now })
        // A History filter must not leak into Home.
        model.searchText = "five"
        model.onlyWithAI = true

        await model.refreshHome(calendar: calendar)

        let home = try XCTUnwrap(model.home)
        XCTAssertEqual(home.today.sessionCount, 1)
        XCTAssertEqual(home.today.wordCount, 4)
        XCTAssertEqual(home.week.sessionCount, 2)
        XCTAssertEqual(home.week.wordCount, 6)
        XCTAssertEqual(home.recent.map(\.id), [today.id, earlierThisWeek.id, lastWeek.id, older.id], "newest four")
        XCTAssertFalse(home.isEmpty)

        let tiles = home.tiles
        XCTAssertEqual(tiles.map(\.id), [.today, .week, .timeSaved, .pace])
        XCTAssertEqual(tiles[0].value, 4.formatted())
        XCTAssertEqual(tiles[1].value, 6.formatted())
        XCTAssertTrue(tiles[1].hint.contains("2"), tiles[1].hint)
        // 6 words over 90 s of recording: 4 wpm, and no time saved (typing
        // 6 words at 40 wpm takes 9 s) — the History strip's own formula.
        XCTAssertEqual(tiles[3].value, "4")
        XCTAssertEqual(home.weekDashboard, HistoryViewModel.Dashboard(statistics: home.week))
        XCTAssertEqual(home.weekDashboard.timeSavedSeconds, 0)
        XCTAssertEqual(tiles[2].value, HomeSummary.compactDuration(0))
    }

    func testAnEmptyHistoryIsEmptyAndHasNoPace() async throws {
        let model = HistoryViewModel(repository: TestHistoryRepository(), now: { [now] in now })
        await model.refreshHome(calendar: calendar)
        let home = try XCTUnwrap(model.home)
        XCTAssertTrue(home.isEmpty)
        XCTAssertEqual(home.recent, [])
        XCTAssertEqual(home.tiles.last?.value, "—", "no recording time, no pace")
    }

    func testHeroVerbFollowsTheTriggerAndTheAIChipSaysOffHonestly() {
        func hero(_ interaction: RecordingInteraction, ai: HomeHeroState.AI, keys: [String] = ["⌃", "Space"]) -> HomeHeroState {
            HomeHeroState(
                readiness: MainWindowReadiness(title: "Ready", needsAttention: false, shortcutKeys: keys),
                interaction: interaction, modelName: "M", microphoneName: "Mic", ai: ai
            )
        }
        XCTAssertEqual(hero(.pushToTalk, ai: .off).verb, "Hold")
        XCTAssertEqual(hero(.toggle, ai: .off).verb, "Press")
        XCTAssertEqual(hero(.hybrid, ai: .off).verb, "Hold or press")
        XCTAssertEqual(hero(.pushToTalk, ai: .off).aiChipTitle, "AI off")
        XCTAssertFalse(hero(.pushToTalk, ai: .off).aiIsOn)
        XCTAssertEqual(hero(.pushToTalk, ai: .on(action: "Clean Up", configuration: "Local Ollama")).aiChipTitle, "Clean Up · Local Ollama")
        XCTAssertEqual(hero(.pushToTalk, ai: .on(action: "Clean Up", configuration: nil)).aiChipTitle, "Clean Up")
        XCTAssertEqual(hero(.pushToTalk, ai: .on(action: nil, configuration: nil)).aiChipTitle, "AI on")
        XCTAssertTrue(hero(.pushToTalk, ai: .off).hasShortcut)
        XCTAssertFalse(hero(.pushToTalk, ai: .off, keys: []).hasShortcut, "no shortcut: the hero offers Shortcuts")
        XCTAssertEqual(hero(.pushToTalk, ai: .off).accessibilitySentence, "Ready. Hold ⌃Space and speak.")
    }

    func testHistoryWithAIFilterIsPartOfTheCurrentFilterAndIsCleared() async {
        let model = HistoryViewModel(repository: TestHistoryRepository(), now: { [now] in now })
        XCTAssertFalse(model.isFiltered)
        model.onlyWithAI = true
        XCTAssertTrue(model.currentFilter.onlyWithAI)
        XCTAssertTrue(model.isFiltered)
        await model.clearFilters()
        XCTAssertFalse(model.onlyWithAI)
        XCTAssertFalse(model.isFiltered)
    }

    private func entry(at date: Date, text: String, ms: Int, ai: HistoryAIStatus = .off) -> HistoryEntry {
        HistoryEntry(
            createdAt: date,
            rawText: text,
            finalText: text,
            mode: ai == .off ? .off : .polish,
            insertionOutcome: .inserted(method: .selectedTextAttribute),
            aiStatus: ai,
            recordingDurationMilliseconds: ms
        )
    }
}
