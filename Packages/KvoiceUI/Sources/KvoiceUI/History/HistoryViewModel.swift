import AppKit
import Foundation
import KvoiceAppCore
import KvoiceDomain
import Observation

public enum HistoryViewLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case empty
    case error
}

/// Main-actor state for the History window.
///
/// The view model knows the `HistoryRepository` contract, an optional
/// `HistoryAudioStoring` for opt-in stored audio, a copy callback, and a
/// handful of closures the app shell wires (Retranscribe and Transcribe
/// File need the engine; Auto Daily Export needs the exporter).
///
/// ADR-022 slice 7 part B: `historyEnabled` is a projection over
/// `SettingsProjectionHost` — the last field this view model held as a
/// copy. It reads `host.settings.historyEnabled` live and every edit is one
/// `.setHistoryEnabled` intent with origin `.page(.history)`; a refusal
/// leaves the stored flag (and so the toggle) untouched, with the reducer's
/// note in `refusalNote`.
@Observable
@MainActor
public final class HistoryViewModel {
    public private(set) var entries: [HistoryEntry] = []
    public private(set) var loadState: HistoryViewLoadState = .idle
    public private(set) var errorMessage: String?
    /// A transient confirmation ("Final output copied."). Clears itself after
    /// `statusMessageDuration`; it used to stay on screen until the next
    /// action, so a stale "copied" could sit under the list indefinitely.
    public private(set) var statusMessage: String?
    /// True while an already-loaded list is being re-read in place. Unlike
    /// `loadState == .loading`, the rows stay on screen; the view only
    /// disables Refresh and shows a small spinner.
    public private(set) var isRefreshing = false
    public var selectedEntryID: HistoryEntryID?

    /// Local filter over raw and final text.  The view binds to it and calls
    /// `runSearch()`; nothing here ever leaves the process (FR-HIST-009).
    public var searchText = ""

    // MARK: Filters

    /// Time range and recording-length filters (reference-app parity). Combined with
    /// `searchText` into one repository read; `applyFilters()` re-reads.
    public var timeRange: HistoryTimeRange = .all
    public var durationBucket: HistoryDurationBucket?

    /// Whether `entries` currently holds a filtered result set (search, time
    /// range, or duration) rather than the newest-first page.
    public private(set) var isShowingSearchResults = false

    /// Total rows in the repository and the database size, independent of
    /// how many rows are loaded or filtered.  `nil` until first fetched or
    /// when the repository could not answer.
    public private(set) var entryCount: Int?
    public private(set) var storageSizeBytes: Int64?
    /// Bytes of stored audio, when an audio store is wired.
    public private(set) var audioSizeBytes: Int64?

    /// SQL aggregates over the rows matching the current filters, for the
    /// dashboard tiles.  `nil` until first fetched.
    public private(set) var statistics: HistoryStatistics?

    /// The most recent single-row deletion while its undo window is open
    /// (D.7: no confirmation, but Undo for ten seconds, in memory).
    public private(set) var pendingUndo: PendingDeletion?

    public struct PendingDeletion: Equatable, Sendable {
        public let entry: HistoryEntry
        /// Position the row had in `entries`, so undo puts it back in place.
        public let index: Int
        public let expiresAt: Date
    }

    // MARK: Multi-select

    /// Selection mode for bulk delete: rows show a check circle and taps
    /// toggle membership instead of changing the detail selection.
    public private(set) var isSelecting = false
    public private(set) var selectedEntryIDs: Set<HistoryEntryID> = []

    // MARK: Audio, Retranscribe, file transcription

    /// Peak-per-bin waveform of the selected entry's stored audio; empty when
    /// there is none or it has not loaded yet.
    public private(set) var waveform: [Float] = []
    public private(set) var waveformEntryID: HistoryEntryID?
    public let player = HistoryAudioPlayer()

    public private(set) var isRetranscribing = false
    /// A Retranscribe result awaiting the user's decision.
    public private(set) var retranscribeProposal: RetranscribeProposal?

    public struct RetranscribeProposal: Equatable, Sendable, Identifiable {
        public let entryID: HistoryEntryID
        public let newRawText: String
        public let previousRawText: String

        public var id: HistoryEntryID { entryID }
    }

    public private(set) var isTranscribingFile = false

    // MARK: Shell hooks

    /// Opt-in stored audio (decision #1).  Nil hides every audio affordance.
    @ObservationIgnored public var audioStore: (any HistoryAudioStoring)?
    /// Runs a stored recording through the current engine and returns the
    /// new raw text.  Nil hides Retranscribe.
    @ObservationIgnored public var retranscriber: (@Sendable (URL) async throws -> String)?
    /// Decodes and transcribes a media file for "Transcribe File…".  Nil
    /// hides the action.  `HistoryFileTranscription.transcriber(engine:)`
    /// builds one from the engine.
    @ObservationIgnored public var fileTranscriber: (@Sendable (URL) async throws -> FileTranscription)?
    /// Called after a row this view model wrote (file transcription) is
    /// committed, so the shell can feed Auto Daily Export.
    @ObservationIgnored public var onEntryAppended: (@Sendable (HistoryEntry) async -> Void)?
    /// "Show in Finder".  Replaceable for tests.
    @ObservationIgnored public var revealInFinder: @MainActor (URL) -> Void = { url in
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    /// P-M8 (2026-09-16): History no longer carries its own "Save History"
    /// toggle — the setting lives only in Data & Privacy (`historyEnabled`
    /// below stays a live read of the same projection, so the page's note
    /// is still correct without a control of its own). This hook is the
    /// note's "Data & Privacy" link; nil hides the link and leaves the
    /// sentence alone (previews and tests that do not wire navigation).
    @ObservationIgnored public var openDataPrivacy: (@MainActor () -> Void)?

    /// The typing speed the "Time saved" tile assumes.  Stated in the footer.
    public static let assumedTypingWordsPerMinute = 40

    /// The coordinator projection and the intent door.
    public let host: SettingsProjectionHost

    /// Visible history preference state, read straight from the stored
    /// settings. A refusal (settings not yet loaded, or termination in
    /// progress — never gated on a running dictation) leaves the flag where
    /// it was; `refusalNote` carries the reducer's sentence. P-M8: the
    /// History page no longer offers a control for this (Data & Privacy is
    /// the one door), but the setter stays public — Data & Privacy's own
    /// toggle binds through `HistoryViewModel.historyEnabled` too, since
    /// both pages read and write the same `AppSettings.historyEnabled`
    /// projection.
    public var historyEnabled: Bool {
        get { host.settings.historyEnabled }
        set {
            guard newValue != historyEnabled else { return }
            host.send(.setHistoryEnabled(newValue, origin: .page(.history)))
        }
    }

    /// Alias useful to callers that model the toggle as a generic enabled
    /// state while retaining the domain's `historyEnabled` vocabulary.
    public var isEnabled: Bool {
        get { historyEnabled }
        set { historyEnabled = newValue }
    }

    /// The last refusal's sentence, for the page footer; nil otherwise.
    public var refusalNote: String? { host.refusalNote }

    /// Whether another page is worth asking for.
    ///
    /// Exposed because the view previously guessed with `entries.count >= 50`,
    /// which left a "Load More" button on screen after the final page had
    /// already been fetched — pressing it did nothing.
    public var canLoadMore: Bool {
        loadedOnce && hasMorePages && !entries.isEmpty
    }

    /// Whether any read is in flight, for disabling Refresh.
    public var isLoading: Bool {
        loadState == .loading || isRefreshing
    }

    /// The trimmed query, or `nil` when there is nothing to filter by.
    public var activeSearchQuery: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The repository filter for the current controls.  Dates are resolved
    /// here so the repository never needs a clock.
    public var currentFilter: HistoryFilter {
        HistoryFilter(timeRange: timeRange, durationBucket: durationBucket, query: searchText, now: now())
    }

    public var isFiltered: Bool {
        !currentFilter.isEmpty
    }

    private let repository: any HistoryRepository
    private let copier: any HistoryCopying
    private let pageSize: Int
    private let undoWindow: Duration
    private let statusMessageDuration: Duration
    private let now: () -> Date
    private var hasMorePages = true
    private var loadedOnce = false
    private var undoExpiryTask: Task<Void, Never>?
    private var statusMessageTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?

    public init(
        repository: any HistoryRepository,
        copier: (any HistoryCopying)? = nil,
        audioStore: (any HistoryAudioStoring)? = nil,
        host: SettingsProjectionHost = .detached(),
        pageSize: Int = 50,
        undoWindow: Duration = .seconds(10),
        statusMessageDuration: Duration = .seconds(4),
        now: @escaping () -> Date = { Date() }
    ) {
        self.repository = repository
        self.copier = copier ?? PasteboardHistoryCopying()
        self.audioStore = audioStore
        self.host = host
        self.pageSize = max(1, min(pageSize, 100))
        self.undoWindow = undoWindow
        self.statusMessageDuration = statusMessageDuration
        self.now = now
    }

    /// Closure-based initializer for app shells that want to provide a copy
    /// callback without defining a `HistoryCopying` object.
    public convenience init(
        repository: any HistoryRepository,
        host: SettingsProjectionHost = .detached(),
        pageSize: Int = 50,
        onCopy: @escaping @MainActor (String) -> Void
    ) {
        self.init(
            repository: repository,
            copier: ClosureHistoryCopying(action: onCopy),
            host: host,
            pageSize: pageSize
        )
    }

    public var selectedEntry: HistoryEntry? {
        guard let selectedEntryID else { return nil }
        return entries.first { $0.id == selectedEntryID }
    }

    public func loadIfNeeded() async {
        guard !loadedOnce else { return }
        await load()
    }

    /// What the view runs when it appears. The first time this is a full
    /// load; afterwards it re-reads in place so a window reopened after a
    /// few dictations shows them without a manual Refresh, and without the
    /// rows blinking through the loading state.
    public func refresh() async {
        guard loadedOnce else {
            await load()
            return
        }
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let filter = currentFilter
            let fetched = try await repository.entries(matching: filter, before: nil, limit: pageSize)
            entries = fetched
            isShowingSearchResults = !filter.isEmpty
            hasMorePages = fetched.count == pageSize
            reconcileSelection()
            loadState = fetched.isEmpty ? .empty : .loaded
            errorMessage = nil
        } catch {
            // The rows already on screen are still the best information the
            // user has; keep them and say the re-read failed.
            errorMessage = Self.safeErrorMessage(for: error)
        }
        await refreshStatistics()
    }

    public func load() async {
        loadState = .loading
        errorMessage = nil
        clearStatusMessage()

        do {
            let filter = currentFilter
            let fetched = try await repository.entries(matching: filter, before: nil, limit: pageSize)
            entries = fetched
            isShowingSearchResults = !filter.isEmpty
            loadedOnce = true
            hasMorePages = fetched.count == pageSize
            reconcileSelection()
            loadState = fetched.isEmpty ? .empty : .loaded
        } catch {
            loadedOnce = false
            loadState = .error
            errorMessage = Self.safeErrorMessage(for: error)
        }
        await refreshStatistics()
    }

    /// Applies `searchText` together with the other filters.
    public func runSearch() async {
        await load()
    }

    /// Re-reads after a time-range or duration change.
    public func applyFilters() async {
        await load()
    }

    public func clearSearch() async {
        searchText = ""
        await runSearch()
    }

    public func clearFilters() async {
        searchText = ""
        timeRange = .all
        durationBucket = nil
        await load()
    }

    /// Re-reads the row count, database size, and dashboard aggregates.
    /// Failure leaves the previous figures alone; the numbers are
    /// informational and must never turn a working list into an error state.
    public func refreshStatistics() async {
        if let count = try? await repository.count() {
            entryCount = count
        }
        if let size = try? await repository.storageSizeBytes() {
            storageSizeBytes = size
        }
        if let audioStore, let size = try? await audioStore.totalSizeBytes() {
            audioSizeBytes = size
        }
        if let aggregates = try? await repository.statistics(matching: currentFilter) {
            statistics = aggregates
        }
    }

    public func loadNextPage() async {
        guard loadedOnce, hasMorePages, let oldest = entries.last else { return }

        do {
            let fetched = try await repository.entries(matching: currentFilter, before: oldest.createdAt, limit: pageSize)
            let knownIDs = Set(entries.map(\.id))
            entries.append(contentsOf: fetched.filter { !knownIDs.contains($0.id) })
            hasMorePages = fetched.count == pageSize
            loadState = entries.isEmpty ? .empty : .loaded
        } catch {
            loadState = .error
            errorMessage = Self.safeErrorMessage(for: error)
        }
    }

    // MARK: Dashboard

    /// Figures derived from `statistics`, formatted by the view.
    public struct Dashboard: Equatable, Sendable {
        public let sessions: Int
        public let words: Int
        /// Words per minute of recording, or `nil` when no row has a
        /// recording duration.
        public let wordsPerMinute: Double?
        /// Characters of final text.
        public let keystrokesSaved: Int
        /// Mean AI request time, or `nil` when no row has one.
        public let averageAIMilliseconds: Int?
        /// Typing time at `assumedTypingWordsPerMinute` minus the time spent
        /// recording; never negative.
        public let timeSavedSeconds: Double

        public static let empty = Dashboard(sessions: 0, words: 0, wordsPerMinute: nil, keystrokesSaved: 0, averageAIMilliseconds: nil, timeSavedSeconds: 0)
    }

    public var dashboard: Dashboard {
        guard let statistics else { return .empty }
        let minutes = Double(statistics.recordingMilliseconds) / 60_000
        let wordsPerMinute: Double? = minutes > 0 ? Double(statistics.wordCount) / minutes : nil
        let averageAI: Int? = statistics.aiSessionCount > 0
            ? statistics.aiMilliseconds / statistics.aiSessionCount
            : nil
        let typingSeconds = Double(statistics.wordCount) / Double(Self.assumedTypingWordsPerMinute) * 60
        let recordingSeconds = Double(statistics.recordingMilliseconds) / 1_000
        return Dashboard(
            sessions: statistics.sessionCount,
            words: statistics.wordCount,
            wordsPerMinute: wordsPerMinute,
            keystrokesSaved: statistics.characterCount,
            averageAIMilliseconds: averageAI,
            timeSavedSeconds: max(0, typingSeconds - recordingSeconds)
        )
    }

    // MARK: Deletion

    /// Deletes without confirmation and opens the undo window.  Only one
    /// deletion is undoable at a time; deleting again forfeits the earlier
    /// one, which is the in-memory contract D.7 asks for.  A stored audio
    /// file is kept until the undo window closes, so Undo restores it too.
    public func delete(_ entry: HistoryEntry) async {
        do {
            try await repository.delete(id: entry.id)
            let index = entries.firstIndex { $0.id == entry.id } ?? entries.count
            entries.removeAll { $0.id == entry.id }
            selectedEntryIDs.remove(entry.id)
            if selectedEntryID == entry.id {
                selectedEntryID = entries.first?.id
            }
            loadState = entries.isEmpty ? .empty : .loaded
            clearStatusMessage()
            errorMessage = nil
            await openUndoWindow(for: entry, at: index)
        } catch {
            loadState = .error
            errorMessage = Self.safeErrorMessage(for: error)
        }
        await refreshStatistics()
    }

    public func delete(id: HistoryEntryID) async {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        await delete(entry)
    }

    public func deleteSelected() async {
        guard let selectedEntry else { return }
        await delete(selectedEntry)
    }

    /// Re-appends the most recently deleted row while its window is open.
    public func undoDelete() async {
        guard let pending = pendingUndo else { return }
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        pendingUndo = nil

        do {
            try await repository.append(pending.entry)
            if !entries.contains(where: { $0.id == pending.entry.id }) {
                let index = min(pending.index, entries.count)
                entries.insert(pending.entry, at: index)
            }
            selectedEntryID = pending.entry.id
            loadState = .loaded
            showStatusMessage(String(localized: "Deletion undone.", bundle: .module))
            errorMessage = nil
        } catch {
            errorMessage = Self.safeErrorMessage(for: error)
        }
        await refreshStatistics()
    }

    /// Forfeits the pending undo immediately (the bar's Dismiss action); the
    /// row's audio file goes with it.  Async so callers (and tests) can await
    /// the file removal instead of racing an unstructured task.
    public func dismissUndo() async {
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        guard let pending = pendingUndo else { return }
        pendingUndo = nil
        await removeAudioFile(of: pending.entry)
    }

    /// Shows a transient confirmation and schedules its removal. A newer
    /// message restarts the clock.
    private func showStatusMessage(_ message: String) {
        statusMessageTask?.cancel()
        statusMessage = message
        statusMessageTask = Task { [weak self, statusMessageDuration] in
            try? await Task.sleep(for: statusMessageDuration)
            guard !Task.isCancelled, let self, self.statusMessage == message else { return }
            self.statusMessage = nil
            self.statusMessageTask = nil
        }
    }

    private func clearStatusMessage() {
        statusMessageTask?.cancel()
        statusMessageTask = nil
        statusMessage = nil
    }

    private func openUndoWindow(for entry: HistoryEntry, at index: Int) async {
        undoExpiryTask?.cancel()
        if let forfeited = pendingUndo, forfeited.entry.id != entry.id {
            await removeAudioFile(of: forfeited.entry)
        }
        let seconds = TimeInterval(undoWindow.components.seconds)
            + TimeInterval(undoWindow.components.attoseconds) / 1e18
        let pending = PendingDeletion(entry: entry, index: index, expiresAt: now().addingTimeInterval(seconds))
        pendingUndo = pending
        undoExpiryTask = Task { [weak self, undoWindow] in
            try? await Task.sleep(for: undoWindow)
            guard !Task.isCancelled, let self, self.pendingUndo == pending else { return }
            self.pendingUndo = nil
            self.undoExpiryTask = nil
            await self.removeAudioFile(of: pending.entry)
        }
    }

    private func removeAudioFile(of entry: HistoryEntry) async {
        guard let audioStore, let path = entry.audioPath else { return }
        try? await audioStore.delete(relativePath: path)
        if let size = try? await audioStore.totalSizeBytes() {
            audioSizeBytes = size
        }
    }

    public func clearAll() async {
        do {
            try await repository.deleteAll()
            undoExpiryTask?.cancel()
            undoExpiryTask = nil
            pendingUndo = nil
            if let audioStore {
                try? await audioStore.deleteAll()
            }
            entries.removeAll()
            selectedEntryID = nil
            selectedEntryIDs.removeAll()
            isSelecting = false
            hasMorePages = false
            loadedOnce = true
            loadState = .empty
            showStatusMessage(String(localized: "History cleared.", bundle: .module))
            errorMessage = nil
        } catch {
            loadState = .error
            errorMessage = Self.safeErrorMessage(for: error)
        }
        await refreshStatistics()
    }

    public func clearAllHistory() async {
        await clearAll()
    }

    // MARK: Multi-select and bulk delete

    public func setSelecting(_ selecting: Bool) {
        isSelecting = selecting
        if !selecting {
            selectedEntryIDs.removeAll()
        }
    }

    public func toggleSelection(_ id: HistoryEntryID) {
        if selectedEntryIDs.contains(id) {
            selectedEntryIDs.remove(id)
        } else {
            selectedEntryIDs.insert(id)
        }
    }

    public func selectAllLoaded() {
        selectedEntryIDs = Set(entries.map(\.id))
    }

    public var selectedEntries: [HistoryEntry] {
        entries.filter { selectedEntryIDs.contains($0.id) }
    }

    /// Removes every checked row in one transaction, with their audio files.
    /// Confirmed by the view (it says how many); not undoable.
    public func deleteSelectedEntries() async {
        let doomed = selectedEntries
        guard !doomed.isEmpty else { return }
        do {
            try await repository.delete(ids: doomed.map(\.id))
            let doomedIDs = Set(doomed.map(\.id))
            entries.removeAll { doomedIDs.contains($0.id) }
            if let selectedEntryID, doomedIDs.contains(selectedEntryID) {
                self.selectedEntryID = entries.first?.id
            }
            selectedEntryIDs.removeAll()
            isSelecting = false
            loadState = entries.isEmpty ? .empty : .loaded
            errorMessage = nil
            for entry in doomed {
                await removeAudioFile(of: entry)
            }
            showStatusMessage(doomed.count == 1 ? String(localized: "1 item deleted.", bundle: .module) : String(localized: "\(doomed.count) items deleted.", bundle: .module))
        } catch {
            loadState = .error
            errorMessage = Self.safeErrorMessage(for: error)
        }
        await refreshStatistics()
    }

    // MARK: Copy

    @discardableResult
    public func copy(_ entry: HistoryEntry) -> Bool {
        copyFinal(entry)
    }

    @discardableResult
    public func copyFinal(_ entry: HistoryEntry) -> Bool {
        copier.copy(entry.finalText)
        showStatusMessage(String(localized: "Final output copied.", bundle: .module))
        return true
    }

    @discardableResult
    public func copyRaw(_ entry: HistoryEntry) -> Bool {
        copier.copy(entry.rawText)
        showStatusMessage(String(localized: "Raw transcript copied.", bundle: .module))
        return true
    }

    public func setHistoryEnabled(_ enabled: Bool) {
        historyEnabled = enabled
    }

    public func setEnabled(_ enabled: Bool) {
        setHistoryEnabled(enabled)
    }

    // MARK: Export

    public enum SelectionExportFormat: String, CaseIterable, Sendable {
        case markdown
        case text

        public var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .text: return "txt"
            }
        }
    }

    /// Every row matching the current filters, oldest last, read page by
    /// page so an export is not limited to what is on screen.
    public func allFilteredEntries() async throws -> [HistoryEntry] {
        var all: [HistoryEntry] = []
        var cursor: Date?
        let filter = currentFilter
        while true {
            let page = try await repository.entries(matching: filter, before: cursor, limit: 200)
            guard !page.isEmpty else { break }
            all.append(contentsOf: page)
            cursor = page.last?.createdAt
        }
        return all
    }

    /// One CSV file of every visible (filtered) row.
    public func exportCSV(to url: URL) async {
        do {
            let rows = try await allFilteredEntries()
            try await Self.write([(url, HistoryExportFormatter.csv(rows))])
            showStatusMessage(rows.count == 1 ? String(localized: "Exported 1 item.", bundle: .module) : String(localized: "Exported \(rows.count) items.", bundle: .module))
        } catch {
            errorMessage = String(localized: "The export could not be written.", bundle: .module)
        }
    }

    /// The subfolder a manual daily export writes into, so it can never
    /// overwrite a `YYYY-MM-DD.md` the user already has in the chosen folder
    /// (an Auto Daily Export target, for instance).
    public static func dailyExportFolderName(now: Date) -> String {
        "kvoice-export-" + HistoryExportFormatter.dayString(now)
    }

    /// One `YYYY-MM-DD.md` per day for every visible row, inside a new
    /// `kvoice-export-<today>/` folder under `folder`.  Exporting twice on
    /// the same day replaces that folder's files and nothing else.
    @discardableResult
    public func exportDailyMarkdown(into folder: URL) async -> URL? {
        do {
            let rows = try await allFilteredEntries()
            let byDay = HistoryExportFormatter.groupedByDay(rows)
            let destination = folder.appendingPathComponent(Self.dailyExportFolderName(now: now()), isDirectory: true)
            var files: [(URL, String)] = []
            for (day, dayRows) in byDay {
                guard let first = dayRows.first else { continue }
                let document = HistoryExportFormatter.markdownDay(first.createdAt, entries: dayRows)
                files.append((destination.appendingPathComponent("\(day).md", isDirectory: false), document))
            }
            try await Self.write(files, creating: destination)
            showStatusMessage(byDay.count == 1 ? String(localized: "Exported 1 day.", bundle: .module) : String(localized: "Exported \(byDay.count) days.", bundle: .module))
            return destination
        } catch {
            errorMessage = String(localized: "The export could not be written.", bundle: .module)
            return nil
        }
    }

    /// Saves the given rows (the checked ones, or the selected one) as one
    /// Markdown or plain-text file.
    public func save(_ rows: [HistoryEntry], as format: SelectionExportFormat, to url: URL) async {
        let document: String
        switch format {
        case .markdown: document = HistoryExportFormatter.markdown(rows)
        case .text: document = HistoryExportFormatter.plainText(rows)
        }
        do {
            try await Self.write([(url, document)])
            showStatusMessage(rows.count == 1 ? String(localized: "Saved 1 item.", bundle: .module) : String(localized: "Saved \(rows.count) items.", bundle: .module))
        } catch {
            errorMessage = String(localized: "The file could not be written.", bundle: .module)
        }
    }

    /// File writes happen off the main actor: a user-chosen folder can sit
    /// on a slow or unmounted volume, and the window must not freeze on it.
    private nonisolated static func write(_ files: [(URL, String)], creating directory: URL? = nil) async throws {
        try await Task.detached(priority: .utility) {
            if let directory {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            for (url, contents) in files {
                try Data(contents.utf8).write(to: url, options: [.atomic])
            }
        }.value
    }

    /// The rows an export of "selected" means: the checked rows in selection
    /// mode, otherwise the detail selection.
    public var rowsForSelectionExport: [HistoryEntry] {
        if isSelecting, !selectedEntryIDs.isEmpty { return selectedEntries }
        return selectedEntry.map { [$0] } ?? []
    }

    // MARK: Stored audio

    public func hasStoredAudio(_ entry: HistoryEntry) -> Bool {
        audioStore != nil && entry.audioPath != nil
    }

    public func audioURL(for entry: HistoryEntry) -> URL? {
        guard let audioStore, let path = entry.audioPath else { return nil }
        return audioStore.fileURL(forRelativePath: path)
    }

    /// Loads the player and waveform for the selection (or clears them).
    /// The view calls this when the selected entry changes.
    public func prepareAudio(for entry: HistoryEntry?) {
        waveformTask?.cancel()
        waveformTask = nil
        guard let entry, let url = audioURL(for: entry) else {
            player.load(nil)
            waveform = []
            waveformEntryID = nil
            return
        }
        guard waveformEntryID != entry.id || player.loadedURL != url else { return }
        player.load(url)
        waveform = []
        waveformEntryID = entry.id
        waveformTask = Task { [weak self] in
            let bins = (try? await MediaFileDecoder.decode(url)).map { MediaFileDecoder.waveform(of: $0, bins: 160) } ?? []
            guard !Task.isCancelled, let self, self.waveformEntryID == entry.id else { return }
            self.waveform = bins
        }
    }

    public func revealAudio(for entry: HistoryEntry) {
        guard let url = audioURL(for: entry) else { return }
        revealInFinder(url)
    }

    // MARK: Retranscribe

    public var canRetranscribe: Bool {
        retranscriber != nil
    }

    /// Runs the stored recording through the current engine and proposes the
    /// result; nothing is written until `acceptRetranscription()`.
    public func retranscribe(_ entry: HistoryEntry) async {
        guard let retranscriber, let url = audioURL(for: entry), !isRetranscribing else { return }
        isRetranscribing = true
        defer { isRetranscribing = false }
        errorMessage = nil
        do {
            let text = try await retranscriber(url)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = String(localized: "The recording produced no transcript.", bundle: .module)
                return
            }
            retranscribeProposal = RetranscribeProposal(entryID: entry.id, newRawText: text, previousRawText: entry.rawText)
        } catch {
            errorMessage = String(localized: "Retranscription failed. The saved transcript is unchanged.", bundle: .module)
        }
    }

    public func acceptRetranscription() async {
        guard let proposal = retranscribeProposal,
              let entry = entries.first(where: { $0.id == proposal.entryID })
        else {
            retranscribeProposal = nil
            return
        }
        let updated = entry.replacingRawText(proposal.newRawText)
        do {
            try await repository.replace(updated)
            if let index = entries.firstIndex(where: { $0.id == updated.id }) {
                entries[index] = updated
            }
            retranscribeProposal = nil
            showStatusMessage(String(localized: "Transcript replaced.", bundle: .module))
            errorMessage = nil
        } catch {
            errorMessage = Self.safeErrorMessage(for: error)
        }
        await refreshStatistics()
    }

    public func dismissRetranscription() {
        retranscribeProposal = nil
    }

    // MARK: Transcribe a file

    public var canTranscribeFiles: Bool {
        fileTranscriber != nil
    }

    /// Decodes and transcribes a media file and records it as a history row
    /// with `targetClass == "file"`; nothing is inserted anywhere.
    @discardableResult
    public func transcribeFile(at url: URL) async -> HistoryEntry? {
        guard let fileTranscriber, !isTranscribingFile else { return nil }
        // FR-HIST-001: a file transcription *is* a history row, and this is
        // also the Dock-drop path, so the switch must hold here too.
        guard historyEnabled else {
            errorMessage = String(localized: "Turn on Save History to transcribe files.", bundle: .module)
            return nil
        }
        isTranscribingFile = true
        defer { isTranscribingFile = false }
        errorMessage = nil
        do {
            let result = try await fileTranscriber(url)
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = String(localized: "No speech was found in \(url.lastPathComponent).", bundle: .module)
                return nil
            }
            let entry = HistoryEntry(
                createdAt: now(),
                rawText: result.text,
                finalText: result.text,
                mode: .off,
                insertionOutcome: .deliveredInApp,
                modelID: result.modelID,
                sttDurationMilliseconds: result.sttDurationMilliseconds,
                aiStatus: .off,
                targetClass: HistoryEntry.fileTargetClass,
                appVersion: Self.appVersion,
                recordingDurationMilliseconds: result.recordingDurationMilliseconds
            )
            try await repository.append(entry)
            if let onEntryAppended {
                // Detached: the exporter may touch a slow volume and must
                // never hold up the row appearing in the list.
                Task { await onEntryAppended(entry) }
            }
            if currentFilter.matches(entry) {
                entries.insert(entry, at: 0)
                loadState = .loaded
            }
            selectedEntryID = entry.id
            showStatusMessage(String(localized: "Transcribed \(url.lastPathComponent).", bundle: .module))
            await refreshStatistics()
            return entry
        } catch let error as MediaFileDecoder.DecodeError {
            switch error {
            case .noAudioTrack: errorMessage = String(localized: "\(url.lastPathComponent) has no audio track.", bundle: .module)
            case .empty: errorMessage = String(localized: "\(url.lastPathComponent) contains no audio.", bundle: .module)
            case .unreadable: errorMessage = String(localized: "\(url.lastPathComponent) could not be read.", bundle: .module)
            }
            return nil
        } catch let error as KVoiceError where error.code == .appBusy {
            // The shell's transcriber refuses while a dictation owns the
            // resident engine (one model, one inference at a time).
            errorMessage = String(localized: "Finish the current dictation first, then try again.", bundle: .module)
            return nil
        } catch {
            errorMessage = String(localized: "Transcribing \(url.lastPathComponent) failed.", bundle: .module)
            return nil
        }
    }

    private static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (version, build) {
        case (let version?, let build?): return "\(version) (\(build))"
        case (let version?, nil): return version
        default: return "development"
        }
    }()

    private func reconcileSelection() {
        if let selectedEntryID,
           !entries.contains(where: { $0.id == selectedEntryID }) {
            self.selectedEntryID = entries.first?.id
        } else if selectedEntryID == nil {
            selectedEntryID = entries.first?.id
        }
        selectedEntryIDs = selectedEntryIDs.filter { id in entries.contains { $0.id == id } }
    }

    private static func safeErrorMessage(for _: Error) -> String {
        String(localized: "History is unavailable. Dictation can continue without saving new items.", bundle: .module)
    }
}

/// Clipboard access is injected so History UI tests never need to mutate the
/// process pasteboard.  The app shell can replace this callback if it owns a
/// different copy surface.
@MainActor
public protocol HistoryCopying: AnyObject {
    func copy(_ text: String)
}

@MainActor
public final class PasteboardHistoryCopying: HistoryCopying {
    public init() {}

    public func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
private final class ClosureHistoryCopying: HistoryCopying {
    private let action: @MainActor (String) -> Void

    init(action: @escaping @MainActor (String) -> Void) {
        self.action = action
    }

    func copy(_ text: String) {
        action(text)
    }
}
