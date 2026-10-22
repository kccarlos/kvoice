import SwiftUI
import XCTest
import KvoiceDomain
@testable import KvoiceUI

/// UI v2 fidelity F3b: the seams behind the page-header action slot and the
/// redrawn Dictionary, AI Actions and History pages.
@MainActor
final class PagesFidelity2Tests: XCTestCase {
    // MARK: Header actions

    func testOnlySpeechModelsAndHistoryHaveAHeaderAction() {
        for section in MainWindowSection.allCases {
            switch section {
            case .models: XCTAssertEqual(section.headerActionKind, .runtimeDetails)
            case .history: XCTAssertEqual(section.headerActionKind, .transcribeFile)
            default: XCTAssertNil(section.headerActionKind, "\(section)")
            }
        }
    }

    func testAPublishedActionShowsOnlyOnItsOwnPage() {
        let runtime = MainWindowHeaderAction.runtimeDetails {}
        XCTAssertEqual(MainWindowSection.models.headerAction(from: runtime), runtime)
        // A stale preference from the previous page never leaks across.
        XCTAssertNil(MainWindowSection.history.headerAction(from: runtime))
        XCTAssertNil(MainWindowSection.dictionary.headerAction(from: runtime))
        XCTAssertNil(MainWindowSection.models.headerAction(from: nil))
    }

    func testTranscribeFileFollowsTheHistoryState() {
        XCTAssertNil(MainWindowHeaderAction.transcribeFile(canTranscribeFiles: false, historyEnabled: true, isTranscribing: false) {})

        let ready = MainWindowHeaderAction.transcribeFile(canTranscribeFiles: true, historyEnabled: true, isTranscribing: false) {}
        XCTAssertEqual(ready?.isEnabled, true)
        XCTAssertEqual(ready?.isBusy, false)

        let off = MainWindowHeaderAction.transcribeFile(canTranscribeFiles: true, historyEnabled: false, isTranscribing: false) {}
        XCTAssertEqual(off?.isEnabled, false)
        XCTAssertNotEqual(off?.help, ready?.help, "says why it is disabled")

        let running = MainWindowHeaderAction.transcribeFile(canTranscribeFiles: true, historyEnabled: true, isTranscribing: true) {}
        XCTAssertEqual(running?.isBusy, true)
        XCTAssertEqual(running?.isEnabled, false)
    }

    func testTheHeaderButtonRunsThePagesAction() {
        let counter = Counter()
        let action = MainWindowHeaderAction.runtimeDetails { counter.value += 1 }
        action.perform()
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(action.title, String(localized: "Runtime…", bundle: .module))
    }

    // MARK: History

    private func historyModel(entries: [HistoryEntry] = PreviewFixtures.historyEntries, enabled: Bool = true) async -> HistoryViewModel {
        var settings = AppSettings()
        settings.historyEnabled = enabled
        let model = HistoryViewModel(repository: PreviewHistoryRepository(entries: entries), host: .detached(settings: settings))
        await model.refresh()
        return model
    }

    func testTheWholePageEmptyCardOnlyWhenNothingIsSaved() async {
        let empty = await historyModel(entries: [])
        XCTAssertEqual(empty.emptyState, .noHistory)
        let off = await historyModel(entries: [], enabled: false)
        XCTAssertEqual(off.emptyState, .savingOff)
        let full = await historyModel()
        XCTAssertNil(full.emptyState)

        // An empty filtered result keeps the list and its own note.
        full.onlyWithAI = true
        full.timeRange = .last24Hours
        await full.applyFilters()
        if full.entries.isEmpty { XCTAssertNil(full.emptyState) }
    }

    func testArrowKeysMoveTheSelectionClampedAtBothEnds() async {
        let model = await historyModel()
        XCTAssertGreaterThan(model.entries.count, 1)
        model.selectedEntryID = nil
        model.selectNeighbour(step: 1)
        XCTAssertEqual(model.selectedEntryID, model.entries.first?.id)
        model.selectNeighbour(step: -1)
        XCTAssertEqual(model.selectedEntryID, model.entries.first?.id, "clamped at the top")
        model.selectNeighbour(step: 1)
        XCTAssertEqual(model.selectedEntryID, model.entries[1].id)
        for _ in 0..<10 { model.selectNeighbour(step: 1) }
        XCTAssertEqual(model.selectedEntryID, model.entries.last?.id, "clamped at the bottom")
    }

    func testANewSelectionOpensOnEnhanced() async {
        let model = await historyModel()
        model.selectedEntryID = model.entries.first?.id
        model.transcriptTab = .original
        model.selectedEntryID = model.entries.first?.id
        XCTAssertEqual(model.transcriptTab, .original, "re-selecting the same entry keeps the tab")
        model.selectedEntryID = model.entries.last?.id
        XCTAssertEqual(model.transcriptTab, .enhanced)
    }

    func testTheListColumnIsTheDesignsWidthUntilTheDetailWouldGetTooNarrow() {
        XCTAssertEqual(HistoryView.listColumnWidth(containerWidth: 1_000), 300)
        XCTAssertEqual(HistoryView.listColumnWidth(containerWidth: 527), 246)
        XCTAssertEqual(HistoryView.listColumnWidth(containerWidth: 400), 220)
        XCTAssertEqual(HistoryView.listColumnWidth(containerWidth: 0), 300)
    }

    func testTheWaveformAveragesItsBinsDownToWhatFits() {
        XCTAssertEqual(WaveformBars.resample([0, 1, 0, 1], to: 2), [0.5, 0.5])
        XCTAssertEqual(WaveformBars.resample([0.2, 0.4], to: 10), [0.2, 0.4], "never invents bins")
        XCTAssertEqual(WaveformBars.resample(Array(repeating: 0.5, count: 100), to: 48).count, 48)
    }

    func testTheRowAndDetailSayWhereTheTextWentNotTheApp() async {
        let model = await historyModel()
        for entry in model.entries {
            XCTAssertFalse(entry.rowTitle.isEmpty)
            XCTAssertTrue(entry.detailMeta.contains(entry.insertionOutcome.detailName(isFile: entry.isFileTranscription)))
        }
    }
}

@MainActor
private final class Counter {
    var value = 0
}
