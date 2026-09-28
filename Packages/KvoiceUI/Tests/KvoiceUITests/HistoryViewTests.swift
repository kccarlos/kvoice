import Foundation
import XCTest
import KvoiceAppCore
@testable import KvoiceDomain
@testable import KvoiceUI

@MainActor
final class HistoryViewTests: XCTestCase {
    func testViewModelLoadsCopiesDeletesAndClearsHistory() async {
        let first = makeEntry(createdAt: Date(timeIntervalSince1970: 2), rawText: "first")
        let second = makeEntry(createdAt: Date(timeIntervalSince1970: 1), rawText: "second")
        let repository = TestHistoryRepository(entries: [first, second])
        let copier = HistoryCopySpy()
        let harness = SettingsProjectionTestHarness()
        let model = HistoryViewModel(
            repository: repository,
            copier: copier,
            host: harness.host
        )

        await model.load()
        XCTAssertEqual(model.entries.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.loadState, .loaded)

        XCTAssertTrue(model.copyFinal(first))
        XCTAssertEqual(copier.copiedText, [first.finalText])
        XCTAssertTrue(model.copyRaw(first))
        XCTAssertEqual(copier.copiedText, [first.finalText, first.rawText])

        await model.delete(first)
        XCTAssertEqual(model.entries.map(\.id), [second.id])
        await model.clearAll()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(model.loadState, .empty)

        model.setHistoryEnabled(false)
        XCTAssertFalse(model.historyEnabled)
        XCTAssertEqual(harness.sent, [.setHistoryEnabled(false, origin: .page(.history))])
        XCTAssertFalse(harness.settings.historyEnabled)
    }

    /// ADR-022 slice 7 part B: `historyEnabled` is a projection — the
    /// toggle reads and writes the coordinator's stored flag directly, with
    /// no `onHistoryEnabledChange` callback in between.
    func testDisablingHistoryIsAnIntentAndDoesNotHideExistingEntries() async {
        let entry = makeEntry(createdAt: Date(), rawText: "keep me")
        let repository = TestHistoryRepository(entries: [entry])
        let harness = SettingsProjectionTestHarness(settings: AppSettings(historyEnabled: true))
        let model = HistoryViewModel(repository: repository, host: harness.host)

        await model.load()
        model.isEnabled = false

        XCTAssertFalse(model.historyEnabled)
        XCTAssertEqual(model.entries, [entry])
        XCTAssertEqual(harness.sent, [.setHistoryEnabled(false, origin: .page(.history))])
    }

    /// A refusal (settings not yet loaded — never gated on a running
    /// dictation) leaves the flag, and so the toggle, untouched and sets
    /// `refusalNote`.
    func testARefusalSnapsTheToggleBackWithTheNote() {
        let harness = SettingsProjectionTestHarness(settings: AppSettings(historyEnabled: true))
        let model = HistoryViewModel(repository: TestHistoryRepository(), host: harness.host)
        harness.startJob()
        model.historyEnabled = false
        XCTAssertFalse(model.historyEnabled, "a running job does not gate the History switch")
        XCTAssertNil(model.refusalNote)

        harness.gate = SettingsGate(settingsLoaded: false)
        model.historyEnabled = true
        XCTAssertFalse(model.historyEnabled)
        XCTAssertEqual(model.refusalNote, "Finish the current dictation first.")
    }

    /// A change from another door (the Backup import path) is shown with
    /// nothing sent.
    func testAChangeFromAnotherDoorRendersWithoutHydration() {
        let harness = SettingsProjectionTestHarness(settings: AppSettings(historyEnabled: true))
        let model = HistoryViewModel(repository: TestHistoryRepository(), host: harness.host)
        harness.commitFromElsewhere(.replaceAll(AppSettings(historyEnabled: false), origin: .import))
        XCTAssertFalse(model.historyEnabled)
        XCTAssertTrue(harness.sent.isEmpty)
    }

    func testRepositoryFailureIsSurfacedWithoutChangingLoadedResults() async {
        let entry = makeEntry(createdAt: Date(), rawText: "safe result")
        let repository = TestHistoryRepository(entries: [entry], shouldFail: true)
        let model = HistoryViewModel(repository: repository)

        await model.load()

        XCTAssertEqual(model.loadState, .error)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.errorMessage?.contains("Dictation can continue") == true)
    }

    func testViewCanBeConstructedForHistoryWindow() {
        let model = HistoryViewModel(repository: TestHistoryRepository())
        let view = HistoryView(viewModel: model)
        XCTAssertNotNil(view)
    }

    // MARK: Paging

    /// The view used to decide whether to offer "Load More" by checking
    /// `entries.count >= 50`, which left a dead button on screen once the last
    /// page had been fetched. `canLoadMore` has to reflect the repository.
    func testCanLoadMoreIsFalseWhenAFullPageWasNotReturned() async {
        let entries = (0..<3).map { index in
            makeEntry(createdAt: Date(timeIntervalSince1970: Double(100 - index)), rawText: "e\(index)")
        }
        let model = HistoryViewModel(repository: TestHistoryRepository(entries: entries), pageSize: 10)

        await model.load()

        XCTAssertEqual(model.entries.count, 3)
        XCTAssertFalse(model.canLoadMore, "a short page means there is nothing more to fetch")
    }

    func testCanLoadMoreIsTrueWhileFullPagesKeepArriving() async {
        let entries = (0..<6).map { index in
            makeEntry(createdAt: Date(timeIntervalSince1970: Double(100 - index)), rawText: "e\(index)")
        }
        let model = HistoryViewModel(repository: TestHistoryRepository(entries: entries), pageSize: 3)

        await model.load()
        XCTAssertTrue(model.canLoadMore, "a full page implies there may be more")

        await model.loadNextPage()
        XCTAssertEqual(model.entries.count, 6)

        // The final page is full too, so one more attempt is expected; it comes
        // back empty and settles the question.
        await model.loadNextPage()
        XCTAssertFalse(model.canLoadMore)
    }

    func testCanLoadMoreIsFalseBeforeTheFirstLoad() {
        let model = HistoryViewModel(repository: TestHistoryRepository())
        XCTAssertFalse(model.canLoadMore, "nothing has been fetched yet")
    }

    // MARK: Search (FR-HIST-009)

    func testSearchFiltersThroughTheRepositoryAndClearingRestoresThePage() async {
        let budget = makeEntry(createdAt: Date(timeIntervalSince1970: 3), rawText: "the Budget meeting")
        let lunch = makeEntry(createdAt: Date(timeIntervalSince1970: 2), rawText: "lunch order")
        let repository = TestHistoryRepository(entries: [budget, lunch])
        let model = HistoryViewModel(repository: repository, pageSize: 10)
        await model.load()
        model.selectedEntryID = lunch.id

        model.searchText = "  budget "
        await model.runSearch()

        XCTAssertEqual(model.entries.map(\.id), [budget.id])
        XCTAssertTrue(model.isShowingSearchResults)
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertFalse(model.canLoadMore, "one match is short of a page")
        XCTAssertEqual(model.selectedEntryID, budget.id, "a selection that fell out of the results moves to the first match")
        let queries = await repository.searchQueries
        XCTAssertEqual(queries, ["budget"], "the query is trimmed and goes to the repository, nowhere else")

        model.searchText = "zzz"
        await model.runSearch()
        XCTAssertEqual(model.entries, [])
        XCTAssertEqual(model.loadState, .empty)
        XCTAssertTrue(model.isShowingSearchResults)

        await model.clearSearch()
        XCTAssertEqual(model.searchText, "")
        XCTAssertFalse(model.isShowingSearchResults)
        XCTAssertEqual(model.entries.map(\.id), [budget.id, lunch.id])
    }

    func testBlankSearchOnAFreshModelLoadsThePage() async {
        let entry = makeEntry(createdAt: Date(), rawText: "hello")
        let model = HistoryViewModel(repository: TestHistoryRepository(entries: [entry]))

        model.searchText = "   "
        await model.runSearch()

        XCTAssertEqual(model.entries, [entry])
        XCTAssertFalse(model.isShowingSearchResults)
        XCTAssertNil(model.activeSearchQuery)
    }

    func testSearchFailureIsSurfacedSafely() async {
        let model = HistoryViewModel(repository: TestHistoryRepository(shouldFail: true))
        model.searchText = "anything"
        await model.runSearch()

        XCTAssertEqual(model.loadState, .error)
        XCTAssertTrue(model.errorMessage?.contains("Dictation can continue") == true)
    }

    // MARK: Statistics

    func testEntryCountAndSizeComeFromTheRepositoryAndFollowMutations() async {
        let entries = (0..<3).map { index in
            makeEntry(createdAt: Date(timeIntervalSince1970: Double(10 - index)), rawText: "e\(index)")
        }
        let model = HistoryViewModel(repository: TestHistoryRepository(entries: entries), pageSize: 2)

        await model.load()
        XCTAssertEqual(model.entries.count, 2, "one page loaded")
        XCTAssertEqual(model.entryCount, 3, "but the count is the whole repository")
        XCTAssertEqual(model.storageSizeBytes, 3 * 1_024)

        await model.delete(entries[0])
        XCTAssertEqual(model.entryCount, 2)
        XCTAssertEqual(model.storageSizeBytes, 2 * 1_024)

        await model.clearAll()
        XCTAssertEqual(model.entryCount, 0)
        XCTAssertEqual(model.storageSizeBytes, 0)
    }

    // MARK: Undo (D.7)

    func testDeleteOpensAnUndoWindowAndUndoRestoresTheRowInPlace() async {
        let first = makeEntry(createdAt: Date(timeIntervalSince1970: 3), rawText: "first")
        let second = makeEntry(createdAt: Date(timeIntervalSince1970: 2), rawText: "second")
        let third = makeEntry(createdAt: Date(timeIntervalSince1970: 1), rawText: "third")
        let repository = TestHistoryRepository(entries: [first, second, third])
        let model = HistoryViewModel(repository: repository, undoWindow: .seconds(60))
        await model.load()
        model.selectedEntryID = second.id

        await model.delete(second)

        XCTAssertEqual(model.entries.map(\.id), [first.id, third.id])
        XCTAssertEqual(model.pendingUndo?.entry, second)
        XCTAssertEqual(model.pendingUndo?.index, 1)
        XCTAssertEqual(model.selectedEntryID, first.id)
        let storedAfterDelete = await repository.storedIDs
        XCTAssertEqual(storedAfterDelete, [first.id, third.id], "the row is really gone from the repository")

        await model.undoDelete()

        XCTAssertNil(model.pendingUndo)
        XCTAssertEqual(model.entries.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(model.selectedEntryID, second.id)
        XCTAssertEqual(model.statusMessage, "Deletion undone.")
        let storedAfterUndo = await repository.storedIDs
        XCTAssertEqual(storedAfterUndo, [first.id, second.id, third.id], "undo re-appends the same entry")
        XCTAssertEqual(model.entryCount, 3)

        await model.undoDelete()
        XCTAssertEqual(model.entries.count, 3, "a second undo with nothing pending is a no-op")
    }

    func testUndoWindowExpiresOnItsOwn() async throws {
        let entry = makeEntry(createdAt: Date(), rawText: "fleeting")
        let model = HistoryViewModel(
            repository: TestHistoryRepository(entries: [entry]),
            undoWindow: .milliseconds(50)
        )
        await model.load()

        await model.delete(entry)
        XCTAssertNotNil(model.pendingUndo)
        let expiresIn = try XCTUnwrap(model.pendingUndo?.expiresAt.timeIntervalSinceNow)
        XCTAssertLessThanOrEqual(expiresIn, 0.05)

        let deadline = Date().addingTimeInterval(2)
        while model.pendingUndo != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.pendingUndo, "the window closes without user action")

        await model.undoDelete()
        XCTAssertTrue(model.entries.isEmpty, "an expired deletion cannot be undone")
    }

    func testANewDeleteReplacesThePendingUndoAndClearAllDismissesIt() async {
        let first = makeEntry(createdAt: Date(timeIntervalSince1970: 2), rawText: "first")
        let second = makeEntry(createdAt: Date(timeIntervalSince1970: 1), rawText: "second")
        let model = HistoryViewModel(
            repository: TestHistoryRepository(entries: [first, second]),
            undoWindow: .seconds(60)
        )
        await model.load()

        await model.delete(first)
        await model.delete(second)
        XCTAssertEqual(model.pendingUndo?.entry, second, "only the latest deletion is undoable")

        await model.undoDelete()
        XCTAssertEqual(model.entries.map(\.id), [second.id])

        await model.delete(second)
        XCTAssertNotNil(model.pendingUndo)
        await model.dismissUndo()
        XCTAssertNil(model.pendingUndo)

        await model.undoDelete()
        XCTAssertTrue(model.entries.isEmpty, "dismiss forfeits the undo")

        let other = makeEntry(createdAt: Date(), rawText: "other")
        let another = HistoryViewModel(
            repository: TestHistoryRepository(entries: [other]),
            undoWindow: .seconds(60)
        )
        await another.load()
        await another.delete(other)
        XCTAssertNotNil(another.pendingUndo)
        await another.clearAll()
        XCTAssertNil(another.pendingUndo, "Clear All is confirmed by the user, so nothing is left to undo")
    }

    func testFailedDeleteOpensNoUndoWindow() async {
        let entry = makeEntry(createdAt: Date(), rawText: "stuck")
        let repository = TestHistoryRepository(entries: [entry])
        let model = HistoryViewModel(repository: repository)
        await model.load()
        await repository.setShouldFail(true)

        await model.delete(entry)

        XCTAssertNil(model.pendingUndo)
        XCTAssertEqual(model.loadState, .error)
        XCTAssertEqual(model.entries, [entry], "a row that could not be deleted stays visible")
    }

    func testFallbackFlagCoversAIAndInsertionFallbacks() {
        let happy = makeEntry(createdAt: Date(), rawText: "ok")
        XCTAssertFalse(happy.isFallback)

        let clipboard = HistoryEntry(
            createdAt: Date(), rawText: "r", finalText: "r", mode: .off,
            insertionOutcome: .copiedToClipboard(reason: .notEditable)
        )
        XCTAssertTrue(clipboard.isFallback)

        let aiFailed = HistoryEntry(
            createdAt: Date(), rawText: "r", finalText: "r", mode: .polish,
            insertionOutcome: .inserted(method: .selectedTextAttribute), aiStatus: .failed
        )
        XCTAssertTrue(aiFailed.isFallback)

        let cancelled = HistoryEntry(
            createdAt: Date(), rawText: "r", finalText: "r", mode: .polish,
            insertionOutcome: .inserted(method: .selectedTextAttribute), aiStatus: .cancelledFallback
        )
        XCTAssertTrue(cancelled.isFallback)

        let legacyErrorOnly = HistoryEntry(
            createdAt: Date(), rawText: "r", finalText: "r", mode: .polish,
            insertionOutcome: .inserted(method: .selectedTextAttribute), errorCode: .aiUnreachable
        )
        XCTAssertTrue(legacyErrorOnly.isFallback, "an error code alone still marks the row")

        let succeeded = HistoryEntry(
            createdAt: Date(), rawText: "r", finalText: "polished", mode: .polish,
            insertionOutcome: .inserted(method: .selectedTextAttribute), aiStatus: .succeeded
        )
        XCTAssertFalse(succeeded.isFallback)
    }

    // MARK: Refresh on appear

    /// The view runs `refresh()` every time it appears. The first time it is
    /// the ordinary load; later it must pick up rows written since without
    /// dropping the list into the loading state or losing the selection.
    func testRefreshIsAFullLoadFirstAndAQuietReReadAfterwards() async {
        let older = makeEntry(createdAt: Date(timeIntervalSince1970: 1), rawText: "older")
        let repository = TestHistoryRepository(entries: [older])
        let model = HistoryViewModel(repository: repository)

        await model.refresh()
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.entries.map(\.id), [older.id])
        XCTAssertEqual(model.selectedEntryID, older.id)

        let newer = makeEntry(createdAt: Date(timeIntervalSince1970: 2), rawText: "newer")
        try? await repository.append(newer)
        await model.refresh()

        XCTAssertEqual(model.entries.map(\.id), [newer.id, older.id])
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.selectedEntryID, older.id, "The selection survives the re-read")
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.entryCount, 2)
    }

    func testRefreshFailureKeepsTheRowsAndReportsTheProblem() async {
        let entry = makeEntry(createdAt: Date(), rawText: "still here")
        let repository = TestHistoryRepository(entries: [entry])
        let model = HistoryViewModel(repository: repository)
        await model.load()

        await repository.setShouldFail(true)
        await model.refresh()

        XCTAssertEqual(model.entries, [entry])
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isRefreshing)
    }

    func testRefreshWhileFilteringRerunsTheSearch() async {
        let match = makeEntry(createdAt: Date(timeIntervalSince1970: 2), rawText: "alpha")
        let other = makeEntry(createdAt: Date(timeIntervalSince1970: 1), rawText: "beta")
        let repository = TestHistoryRepository(entries: [match, other])
        let model = HistoryViewModel(repository: repository)
        await model.load()
        model.searchText = "alpha"
        await model.runSearch()
        XCTAssertEqual(model.entries.map(\.id), [match.id])

        await model.refresh()

        XCTAssertTrue(model.isShowingSearchResults)
        XCTAssertEqual(model.entries.map(\.id), [match.id])
        let queries = await repository.searchQueries
        XCTAssertEqual(queries, ["alpha", "alpha"])
    }

    // MARK: Transient status

    func testStatusMessageClearsItselfAfterItsDuration() async throws {
        let entry = makeEntry(createdAt: Date(), rawText: "copy me")
        let model = HistoryViewModel(
            repository: TestHistoryRepository(entries: [entry]),
            copier: HistoryCopySpy(),
            statusMessageDuration: .milliseconds(40)
        )

        model.copyFinal(entry)
        XCTAssertEqual(model.statusMessage, "Final output copied.")

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(model.statusMessage)
    }

    func testANewerStatusMessageRestartsTheClock() async throws {
        let entry = makeEntry(createdAt: Date(), rawText: "copy me")
        let model = HistoryViewModel(
            repository: TestHistoryRepository(entries: [entry]),
            copier: HistoryCopySpy(),
            statusMessageDuration: .milliseconds(120)
        )

        model.copyFinal(entry)
        try await Task.sleep(for: .milliseconds(80))
        model.copyRaw(entry)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.statusMessage, "Raw transcript copied.", "The first timer must not clear the second message")

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(model.statusMessage)
    }

    private func makeEntry(createdAt: Date, rawText: String) -> HistoryEntry {
        HistoryEntry(
            createdAt: createdAt,
            rawText: rawText,
            finalText: "final \(rawText)",
            mode: .off,
            insertionOutcome: .inserted(method: .selectedTextAttribute)
        )
    }
}

@MainActor
private final class HistoryCopySpy: HistoryCopying {
    private(set) var copiedText: [String] = []

    func copy(_ text: String) {
        copiedText.append(text)
    }
}

actor TestHistoryRepository: HistoryRepository {
    private var storedEntries: [HistoryEntry]
    private var shouldFail: Bool

    init(entries: [HistoryEntry] = [], shouldFail: Bool = false) {
        self.storedEntries = entries
        self.shouldFail = shouldFail
    }

    func setShouldFail(_ value: Bool) {
        shouldFail = value
    }

    func migrateIfNeeded() throws {}

    func append(_ entry: HistoryEntry) throws {
        guard !shouldFail else { throw KVoiceError(code: .historyWriteFailed) }
        storedEntries.append(entry)
    }

    func fetchPage(before: Date?, limit: Int) throws -> [HistoryEntry] {
        guard !shouldFail else { throw KVoiceError(code: .historyOpenFailed) }
        let sorted = storedEntries.sorted { $0.createdAt > $1.createdAt }
        let filtered = before.map { date in sorted.filter { $0.createdAt < date } } ?? sorted
        return Array(filtered.prefix(max(0, limit)))
    }

    func delete(id: HistoryEntryID) throws {
        guard !shouldFail else { throw KVoiceError(code: .historyWriteFailed) }
        storedEntries.removeAll { $0.id == id }
    }

    func deleteAll() throws {
        guard !shouldFail else { throw KVoiceError(code: .historyWriteFailed) }
        storedEntries.removeAll()
    }

    func count() throws -> Int {
        guard !shouldFail else { throw KVoiceError(code: .historyOpenFailed) }
        return storedEntries.count
    }

    func storageSizeBytes() throws -> Int64 {
        guard !shouldFail else { throw KVoiceError(code: .historyOpenFailed) }
        return Int64(storedEntries.count) * 1_024
    }

    func search(_ query: String, limit: Int) throws -> [HistoryEntry] {
        guard !shouldFail else { throw KVoiceError(code: .historyOpenFailed) }
        searchQueries.append(query)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return try fetchPage(before: nil, limit: limit) }
        let matches = storedEntries
            .filter {
                $0.rawText.localizedCaseInsensitiveContains(needle)
                    || $0.finalText.localizedCaseInsensitiveContains(needle)
            }
            .sorted { $0.createdAt > $1.createdAt }
        return Array(matches.prefix(max(0, limit)))
    }

    /// The view model reads through the combined filter; a text query is
    /// recorded so tests can assert it reached the repository trimmed.
    func entries(matching filter: HistoryFilter, before: Date?, limit: Int) throws -> [HistoryEntry] {
        guard !shouldFail else { throw KVoiceError(code: .historyOpenFailed) }
        if let query = filter.normalizedQuery {
            searchQueries.append(query)
        }
        filters.append(filter)
        let sorted = storedEntries.sorted { $0.createdAt > $1.createdAt }
        let paged = before.map { date in sorted.filter { $0.createdAt < date } } ?? sorted
        return Array(paged.filter(filter.matches).prefix(max(0, limit)))
    }

    func delete(ids: [HistoryEntryID]) throws {
        guard !shouldFail else { throw KVoiceError(code: .historyWriteFailed) }
        bulkDeletes.append(ids)
        storedEntries.removeAll { ids.contains($0.id) }
    }

    func replace(_ entry: HistoryEntry) throws {
        guard !shouldFail else { throw KVoiceError(code: .historyWriteFailed) }
        storedEntries.removeAll { $0.id == entry.id }
        storedEntries.append(entry)
    }

    private(set) var searchQueries: [String] = []
    private(set) var filters: [HistoryFilter] = []
    private(set) var bulkDeletes: [[HistoryEntryID]] = []

    var stored: [HistoryEntry] {
        storedEntries.sorted { $0.createdAt > $1.createdAt }
    }

    var storedIDs: [HistoryEntryID] {
        storedEntries.sorted { $0.createdAt > $1.createdAt }.map(\.id)
    }
}
