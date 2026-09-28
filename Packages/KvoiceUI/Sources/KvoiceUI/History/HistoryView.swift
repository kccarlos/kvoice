import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KvoiceDomain

/// Native SwiftUI History surface.  App-shell routing and settings
/// persistence remain outside this view; `HistoryViewModel` exposes the
/// repository, audio store, engine, and enable-toggle seams the shell wires.
@MainActor
public struct HistoryView: View {
    @Bindable private var viewModel: HistoryViewModel
    @State private var isClearConfirmationPresented = false
    @State private var isBulkDeleteConfirmationPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(viewModel: HistoryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            HistoryDashboardView(dashboard: viewModel.dashboard, isFiltered: viewModel.isFiltered)
            Divider()
            // `columnVisibility: .constant(.all)` (user report, 2026-09-16):
            // without an explicit binding this nested split view manages its
            // own visibility, and — being itself inside the outer window's
            // `NavigationSplitView` detail pane rather than a top-level one —
            // could silently collapse to `.detailOnly` while the window was
            // dragged narrower, with nothing here able to notice or reopen
            // it. Pinning both columns open always trades away the automatic
            // collapse this view never wanted in the first place (the list
            // is core navigation, not an optional sidebar).
            NavigationSplitView(columnVisibility: .constant(.all)) {
                sidebar
                    // The outer window's sidebar can take up to 240 of an
                    // 820-wide window, so this list must fit the remainder
                    // with room for the detail pane beside it.
                    .navigationSplitViewColumnWidth(min: 260, ideal: 360, max: 520)
            } detail: {
                detail
            }
        }
        // No fixed frame here. This view is hosted both by its own window and by
        // a Settings tab; the host decides the size.
        .task {
            // A full load the first time; a quiet in-place re-read after
            // that, so reopening the window shows the latest dictations
            // without a manual Refresh.
            await viewModel.refresh()
        }
        // Typing re-runs the local filter after a short pause. The task is
        // cancelled and restarted on every keystroke, so only the final query
        // reaches the repository.
        .task(id: viewModel.searchText) {
            guard viewModel.activeSearchQuery != nil || viewModel.isShowingSearchResults else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await viewModel.runSearch()
        }
        .task(id: viewModel.selectedEntryID) {
            viewModel.prepareAudio(for: viewModel.selectedEntry)
        }
        .confirmationDialog(
            "Clear all history?",
            isPresented: $isClearConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                Task { await viewModel.clearAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every saved transcript and any stored recordings. Your settings, shortcut, and the local model are kept.")
        }
        .confirmationDialog(
            bulkDeleteTitle,
            isPresented: $isBulkDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(bulkDeleteTitle.replacingOccurrences(of: "?", with: ""), role: .destructive) {
                Task { await viewModel.deleteSelectedEntries() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The checked transcripts and their stored recordings are removed. Everything else stays. This cannot be undone.")
        }
        .sheet(item: retranscribeBinding) { proposal in
            RetranscribeProposalSheet(proposal: proposal, viewModel: viewModel)
        }
    }

    private var bulkDeleteTitle: String {
        let count = viewModel.selectedEntryIDs.count
        return count == 1 ? String(localized: "Delete 1 item?", bundle: .module) : String(localized: "Delete \(count) items?", bundle: .module)
    }

    private var retranscribeBinding: Binding<HistoryViewModel.RetranscribeProposal?> {
        Binding(
            get: { viewModel.retranscribeProposal },
            set: { if $0 == nil { viewModel.dismissRetranscription() } }
        )
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            header

            if let errorMessage = viewModel.errorMessage {
                errorBanner(errorMessage)
            }

            contentList

            if viewModel.isSelecting {
                selectionBar
            }

            if let pending = viewModel.pendingUndo {
                undoBar(pending)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            footer
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.pendingUndo)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            // M8a: no inner "History" title — the section header above this
            // view already says History, and a page is titled once.
            HStack(alignment: .firstTextBaseline) {
                Spacer()
                // Inline rather than in a `.toolbar`. This view is also hosted in
                // a Settings tab, which has no window toolbar for items to land
                // in, so toolbar-only actions would be unreachable there.
                actions
            }

            if !viewModel.historyEnabled {
                // P-M8 (2026-09-16): the "Save History" toggle itself moved
                // to Data & Privacy — this is now the one setting's one
                // home (M8/settings.md › "Minimize the number of
                // settings"). J.5 still applies: disabling stops future
                // writes and does not delete existing rows, and the state
                // stays discoverable and one tap from fixable here.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Save History is off. New dictations are not saved. Items already saved stay here until you clear them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let openDataPrivacy = viewModel.openDataPrivacy {
                        Button("Data & Privacy") {
                            openDataPrivacy()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .accessibilityHint("Opens Data & Privacy, where Save dictation history is turned on.")
                    }
                }
            }

            searchField
            filters
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .animation(reduceMotion ? nil : .default, value: viewModel.historyEnabled)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search transcripts", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search history")
                .accessibilityHint("Filters saved transcripts by raw or final text. Searching stays on this Mac.")
            if !viewModel.searchText.isEmpty {
                Button {
                    Task { await viewModel.clearSearch() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
    }

    /// Time range and duration pickers. Pickers commit at once (no debounce).
    private var filters: some View {
        HStack(spacing: 8) {
            Picker("Time range", selection: $viewModel.timeRange) {
                ForEach(HistoryTimeRange.allCases, id: \.self) { range in
                    Text(domain: range.displayName).tag(range)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Time range")
            .onChange(of: viewModel.timeRange) { _, _ in
                Task { await viewModel.applyFilters() }
            }

            Picker("Duration", selection: $viewModel.durationBucket) {
                Text("Any length").tag(HistoryDurationBucket?.none)
                ForEach(HistoryDurationBucket.allCases, id: \.self) { bucket in
                    Text(domain: bucket.displayName).tag(HistoryDurationBucket?.some(bucket))
                }
            }
            .labelsHidden()
            .accessibilityLabel("Recording length")
            .onChange(of: viewModel.durationBucket) { _, _ in
                Task { await viewModel.applyFilters() }
            }
        }
        .controlSize(.small)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            // The spinner stands in for the Refresh glyph while a read is in
            // flight, so the button both shows its state and cannot be
            // pressed twice.
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20, height: 20)
                    .accessibilityLabel("Refreshing history")
            } else {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .frame(width: 20, height: 20)
                }
                .keyboardShortcut("r", modifiers: [.command])
                .help("Refresh history (⌘R)")
                .accessibilityLabel("Refresh history")
            }

            if viewModel.canTranscribeFiles {
                if viewModel.isTranscribingFile {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 20, height: 20)
                        .accessibilityLabel("Transcribing file")
                } else {
                    Button {
                        chooseFileToTranscribe()
                    } label: {
                        Label("Transcribe File…", systemImage: "doc.badge.plus")
                            .labelStyle(.iconOnly)
                            .frame(width: 20, height: 20)
                    }
                    // FR-HIST-001: the result is a history row, so the
                    // switch gates it.
                    .disabled(!viewModel.historyEnabled)
                    .help(viewModel.historyEnabled
                        ? "Transcribe an audio or video file…"
                        : "Turn on Save History to transcribe files")
                    .accessibilityLabel("Transcribe an audio or video file")
                }
            }

            exportMenu

            Button {
                viewModel.setSelecting(!viewModel.isSelecting)
            } label: {
                Label(viewModel.isSelecting ? "Done" : "Select", systemImage: viewModel.isSelecting ? "checkmark.circle.fill" : "checkmark.circle")
                    .labelStyle(.iconOnly)
                    .frame(width: 20, height: 20)
            }
            .disabled(viewModel.entries.isEmpty && !viewModel.isSelecting)
            .help(viewModel.isSelecting ? "Leave selection mode" : "Select several items")
            .accessibilityLabel(viewModel.isSelecting ? "Leave selection mode" : "Select several items")

            Button {
                isClearConfirmationPresented = true
            } label: {
                Label("Clear All", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .frame(width: 20, height: 20)
            }
            .disabled(viewModel.isLoading || (viewModel.entryCount ?? viewModel.entries.count) == 0)
            .help("Clear all history…")
            .accessibilityLabel("Clear all history")
        }
        .buttonStyle(.borderless)
    }

    private var exportMenu: some View {
        Menu {
            Button("Export CSV…") { exportCSV() }
                .disabled((viewModel.entryCount ?? 0) == 0)
            Button("Export Daily Markdown Folder…") { exportDailyMarkdown() }
                .disabled((viewModel.entryCount ?? 0) == 0)
            Divider()
            Button("Save Selected as Markdown…") { saveSelected(.markdown) }
                .disabled(viewModel.rowsForSelectionExport.isEmpty)
            Button("Save Selected as Text…") { saveSelected(.text) }
                .disabled(viewModel.rowsForSelectionExport.isEmpty)
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .labelStyle(.iconOnly)
                .frame(width: 20, height: 20)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Export…")
        .accessibilityLabel("Export")
    }

    @ViewBuilder
    private var contentList: some View {
        switch viewModel.loadState {
        case .idle:
            loadingView
        case .loading where viewModel.entries.isEmpty:
            loadingView
        case .empty where viewModel.isShowingSearchResults:
            ContentUnavailableView {
                Label("No Matching Items", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(viewModel.activeSearchQuery.map { "Nothing matches “\($0)” in this range." } ?? "Nothing was recorded in this range.")
            } actions: {
                Button("Clear Filters") {
                    Task { await viewModel.clearFilters() }
                }
            }
        case .empty:
            ContentUnavailableView {
                Label("No History Yet", systemImage: "text.book.closed")
            } description: {
                Text(viewModel.historyEnabled
                    ? "Completed dictations appear here."
                    : "Turn on Save History to keep completed dictations here.")
            }
        case .error where viewModel.entries.isEmpty:
            ContentUnavailableView {
                Label("History Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(viewModel.errorMessage ?? String(localized: "Dictation can continue without saving new items.", bundle: .module))
            } actions: {
                Button("Retry") {
                    Task { await viewModel.load() }
                }
                .keyboardShortcut(.defaultAction)
            }
        default:
            List(selection: $viewModel.selectedEntryID) {
                ForEach(viewModel.entries) { entry in
                    HistoryRow(
                        entry: entry,
                        hasAudio: viewModel.hasStoredAudio(entry),
                        isSelecting: viewModel.isSelecting,
                        isChecked: viewModel.selectedEntryIDs.contains(entry.id),
                        onToggleCheck: { viewModel.toggleSelection(entry.id) }
                    )
                    .tag(entry.id)
                    .contextMenu {
                        rowActions(for: entry)
                    }
                }
                .onDelete { offsets in
                    let toDelete = offsets.compactMap { index in
                        viewModel.entries.indices.contains(index) ? viewModel.entries[index] : nil
                    }
                    for entry in toDelete {
                        Task { await viewModel.delete(entry) }
                    }
                }

                if viewModel.canLoadMore {
                    Button("Load More History") {
                        Task { await viewModel.loadNextPage() }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityHint("Loads older history items")
                }
            }
            .listStyle(.inset)
            // The Delete key removes the selected row when the list has focus
            // (with Undo, per D.7). This is the macOS list idiom; binding a
            // button to a bare Delete key equivalent would also swallow
            // Backspace in the search field.
            .onDeleteCommand {
                Task { await viewModel.deleteSelected() }
            }
            .overlay(alignment: .bottom) {
                if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8)
                        .transition(.opacity)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.statusMessage)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text(viewModel.selectedEntryIDs.count == 1 ? "1 selected" : "\(viewModel.selectedEntryIDs.count) selected")
                .font(.callout.monospacedDigit())
            Button("Select All") { viewModel.selectAllLoaded() }
                .disabled(viewModel.selectedEntryIDs.count == viewModel.entries.count)
            Spacer()
            Button("Delete…", role: .destructive) {
                isBulkDeleteConfirmationPresented = true
            }
            .disabled(viewModel.selectedEntryIDs.isEmpty)
            .help("Delete the checked items…")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection")
    }

    /// Row count, database size, and stored audio size.  These come from the
    /// repository, not from the loaded page, so they stay right while paging
    /// or filtering.
    private var footer: some View {
        HStack(spacing: 6) {
            if let count = viewModel.entryCount {
                Text(count == 1 ? "1 item" : "\(count) items")
            }
            if let size = viewModel.storageSizeBytes, size > 0 {
                Text("·")
                Text(size.formatted(.byteCount(style: .file)))
            }
            if let audio = viewModel.audioSizeBytes, audio > 0 {
                Text("·")
                Text("audio \(audio.formatted(.byteCount(style: .file)))")
            }
            Spacer()
            if viewModel.isShowingSearchResults {
                Text("\(viewModel.entries.count) matching")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func undoBar(_ pending: HistoryViewModel.PendingDeletion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Deleted “\(pending.entry.finalText.oneLinePreview)”")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button("Undo") {
                Task { await viewModel.undoDelete() }
            }
            .keyboardShortcut("z", modifiers: [.command])
            .help("Restore the deleted item")
            Button {
                Task { await viewModel.dismissUndo() }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Item deleted. Undo available for ten seconds.")
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading History…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading History")
    }

    private func errorBanner(_ message: String) -> some View {
        StatusLabel(message, symbol: "exclamationmark.triangle.fill", tone: .attention)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.1))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("History error. \(message)")
    }

    @ViewBuilder
    private func rowActions(for entry: HistoryEntry) -> some View {
        Button("Copy Final Output") {
            _ = viewModel.copyFinal(entry)
        }
        Button("Copy Raw Transcript") {
            _ = viewModel.copyRaw(entry)
        }
        if viewModel.hasStoredAudio(entry) {
            Button("Show Recording in Finder") {
                viewModel.revealAudio(for: entry)
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            Task { await viewModel.delete(entry) }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = viewModel.selectedEntry {
            HistoryDetailView(entry: entry, viewModel: viewModel)
        } else {
            ContentUnavailableView {
                Label("Select a History Item", systemImage: "text.cursor")
            } description: {
                Text("Choose an item to inspect or copy its transcript.")
            }
        }
    }

    // MARK: File dialogs

    private func chooseFileToTranscribe() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Transcribe File", bundle: .module)
        panel.message = String(localized: "Choose an audio or video file to transcribe with the local model.", bundle: .module)
        panel.allowedContentTypes = MediaFileDecoder.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await viewModel.transcribeFile(at: url) }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export History as CSV", bundle: .module)
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "kvoice-history.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await viewModel.exportCSV(to: url) }
    }

    private func exportDailyMarkdown() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Export Daily Markdown", bundle: .module)
        panel.message = String(localized: "Choose a folder. A new kvoice-export-<date> folder is created inside it with one Markdown file per day.", bundle: .module)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await viewModel.exportDailyMarkdown(into: url) }
    }

    private func saveSelected(_ format: HistoryViewModel.SelectionExportFormat) {
        let rows = viewModel.rowsForSelectionExport
        guard !rows.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = format == .markdown ? String(localized: "Save as Markdown", bundle: .module) : String(localized: "Save as Text", bundle: .module)
        panel.allowedContentTypes = [format == .markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .plainText]
        let day = HistoryExportFormatter.dayString(rows.first?.createdAt ?? Date())
        panel.nameFieldStringValue = "kvoice-\(day).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await viewModel.save(rows, as: format, to: url) }
    }
}

// MARK: - Dashboard

/// The tiles across the top: sessions, words, words per minute, keystrokes
/// saved, average AI time, and time saved against typing.  Every figure is
/// a SQL aggregate over the current filters; the footer states the typing
/// speed the last tile assumes.
struct HistoryDashboardView: View {
    let dashboard: HistoryViewModel.Dashboard
    let isFiltered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                tile("Sessions Recorded", dashboard.sessions.formatted(), systemImage: "waveform")
                tile("Words Dictated", dashboard.words.formatted(), systemImage: "text.word.spacing")
                tile("Words / min", dashboard.wordsPerMinute.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—", systemImage: "speedometer")
                tile("Keystrokes Saved", dashboard.keystrokesSaved.formatted(), systemImage: "keyboard")
                tile("Avg AI Time", dashboard.averageAIMilliseconds.map(Self.seconds) ?? "—", systemImage: "wand.and.stars")
                tile("Time Saved", Self.timeSaved(dashboard.timeSavedSeconds), systemImage: "clock.arrow.circlepath")
            }
            Text(isFiltered
                ? "Figures cover the current filters. Time saved assumes typing at \(HistoryViewModel.assumedTypingWordsPerMinute) words per minute."
                : "Time saved assumes typing at \(HistoryViewModel.assumedTypingWordsPerMinute) words per minute.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dashboard")
    }

    private func tile(_ title: String, _ value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    static func seconds(_ milliseconds: Int) -> String {
        (Double(milliseconds) / 1_000).formatted(.number.precision(.fractionLength(1))) + " s"
    }

    static func timeSaved(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return String(localized: "\(total) s", bundle: .module) }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        return hours > 0 ? String(localized: "\(hours) h \(minutes) m", bundle: .module) : String(localized: "\(minutes) m", bundle: .module)
    }
}

// MARK: - Rows

private struct HistoryRow: View {
    let entry: HistoryEntry
    let hasAudio: Bool
    let isSelecting: Bool
    let isChecked: Bool
    let onToggleCheck: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isSelecting {
                Button(action: onToggleCheck) {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isChecked ? "Checked" : "Not checked")
                .accessibilityHint("Toggles this item for bulk actions")
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.finalText.oneLinePreview)
                        .lineLimit(2)
                        .font(.body)
                    Spacer(minLength: 8)
                    Text(entry.createdAt.historyRowLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(entry.isFileTranscription ? String(localized: "File", bundle: .module) : entry.mode.displayName)
                    Text("·")
                    Text(entry.insertionOutcome.displayName(isFile: entry.isFileTranscription))
                    if let milliseconds = entry.recordingDurationMilliseconds {
                        Text("·")
                        Text(Self.durationLabel(milliseconds))
                    }
                    if hasAudio {
                        Image(systemName: "waveform.circle")
                            .accessibilityLabel("Recording kept")
                    }
                    if entry.isFallback {
                        FallbackBadge()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.accessibilitySummary)
    }

    static func durationLabel(_ milliseconds: Int) -> String {
        Duration.milliseconds(milliseconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
    }
}

/// D.7's "fallback badge": the row did not take the happy path, either
/// because AI failed or was cancelled, or because insertion went to the
/// clipboard.
private struct FallbackBadge: View {
    var body: some View {
        Label {
            Text("Fallback")
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Color.orange.opacity(0.15), in: Capsule())
        .accessibilityLabel("Fallback")
    }
}

// MARK: - Detail

private struct HistoryDetailView: View {
    enum TranscriptTab: String, CaseIterable {
        case original = "Original"
        case enhanced = "Enhanced"
    }

    let entry: HistoryEntry
    let viewModel: HistoryViewModel
    @State private var tab: TranscriptTab = .enhanced

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Title and timestamp on one line when there is room; the
                // timestamp drops under the title in a narrow detail pane.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("History Detail")
                            .font(.title2.weight(.semibold))
                        Spacer()
                        timestamp
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("History Detail")
                            .font(.title2.weight(.semibold))
                        timestamp
                    }
                }

                HStack(spacing: 10) {
                    Label(entry.isFileTranscription ? String(localized: "Transcribed file", bundle: .module) : entry.mode.displayName,
                          systemImage: entry.isFileTranscription ? "doc.badge.plus" : entry.mode.symbolName)
                    if let milliseconds = entry.recordingDurationMilliseconds {
                        DurationBadge(milliseconds: milliseconds)
                    }
                    if entry.isFallback {
                        FallbackBadge()
                    }
                }
                .foregroundStyle(.secondary)

                transcriptTabs

                if viewModel.hasStoredAudio(entry) {
                    audioSection
                }

                if let fallbackSummary = entry.aiFallbackSummary {
                    // D.10: what happened and what kvoice did with the text.
                    // The code itself lives in the details grid, not here.
                    StatusLabel(fallbackSummary, symbol: "exclamationmark.triangle.fill", tone: .attention)
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }

                metadata

                HStack {
                    Spacer()
                    Button("Delete", role: .destructive) {
                        Task { await viewModel.delete(entry) }
                    }
                    // Command-Delete, as in Finder. A bare Delete equivalent on
                    // a button also fires while typing in the search field.
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .help("Delete this item (⌘⌫). Undo is available for ten seconds.")
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(28)
        }
        .accessibilityElement(children: .contain)
        .onChange(of: entry.id, initial: true) { _, _ in
            tab = entry.hasDistinctEnhancedText ? .enhanced : .original
        }
    }

    private var timestamp: some View {
        HStack(spacing: 6) {
            Text(entry.createdAt, style: .date)
            Text(entry.createdAt, style: .time)
        }
        .foregroundStyle(.secondary)
    }

    /// Original / Enhanced.  The Enhanced tab exists only when AI succeeded
    /// and changed the text; otherwise there is one transcript and no tabs.
    @ViewBuilder
    private var transcriptTabs: some View {
        if entry.hasDistinctEnhancedText {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Transcript", selection: $tab) {
                        ForEach(TranscriptTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Transcript version")
                    Spacer()
                    // Neither shortcut is plain Command-C. The transcripts
                    // are selectable, and claiming Command-C would hijack it.
                    if tab == .original {
                        Button("Copy Original") { _ = viewModel.copyRaw(entry) }
                            .keyboardShortcut("c", modifiers: [.command, .option])
                    } else {
                        Button("Copy Enhanced") { _ = viewModel.copyFinal(entry) }
                            .keyboardShortcut("c", modifiers: [.command, .shift])
                    }
                }
                transcriptBox(tab == .original ? entry.rawText : entry.finalText, title: tab.rawValue)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Transcript")
                        .font(.headline)
                    Spacer()
                    Button("Copy Transcript") { _ = viewModel.copyFinal(entry) }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                }
                transcriptBox(entry.finalText, title: "Transcript")
            }
        }
    }

    private func transcriptBox(_ text: String, title: String) -> some View {
        Text(text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("\(title): \(text)")
    }

    /// Waveform strip with play/pause and scrub, Show in Finder, and
    /// Retranscribe.  Only shown when the row has a stored recording.
    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recording")
                    .font(.headline)
                Spacer()
                Button("Show in Finder") { viewModel.revealAudio(for: entry) }
                if viewModel.canRetranscribe {
                    if viewModel.isRetranscribing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Retranscribe") {
                            Task { await viewModel.retranscribe(entry) }
                        }
                        .help("Run the recording through the current model again and choose whether to replace the transcript")
                    }
                }
            }
            AudioPlaybackStrip(player: viewModel.player, waveform: viewModel.waveform)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording")
    }

    /// Scalar facts about the job.  Nothing here names the target application
    /// or reproduces its text; `targetClass` is a role class only.
    private var metadata: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            metadataRow("Model", entry.modelID.isEmpty ? String(localized: "Unknown", bundle: .module) : entry.modelID)
            metadataRow("AI", entry.aiStatus.displayName)
            if let milliseconds = entry.aiDurationMilliseconds {
                metadataRow("AI time", Duration.milliseconds(milliseconds).formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))
            }
            metadataRow("Insertion", entry.insertionOutcome.detailName(isFile: entry.isFileTranscription))
            if let target = entry.translationTarget, !target.isEmpty {
                metadataRow("Translated to", target)
            }
            if let milliseconds = entry.sttDurationMilliseconds {
                metadataRow("Transcription time", Duration.milliseconds(milliseconds).formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))
            }
            if let targetClass = entry.targetClass, !targetClass.isEmpty {
                metadataRow("Target", targetClass)
            }
            if let errorCode = entry.errorCode {
                metadataRow("Error code", errorCode.rawValue)
            }
            if !entry.appVersion.isEmpty {
                metadataRow("App version", entry.appVersion)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details")
    }

    private func metadataRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

private struct DurationBadge: View {
    let milliseconds: Int

    var body: some View {
        Label(
            Duration.milliseconds(milliseconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)),
            systemImage: "timer"
        )
        .font(.caption.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(.quinary, in: Capsule())
        .accessibilityLabel("Recording length")
    }
}

/// Waveform bars with a progress overlay; click or drag to scrub.
struct AudioPlaybackStrip: View {
    @Bindable var player: HistoryAudioPlayer
    let waveform: [Float]

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18, height: 18)
            }
            .disabled(player.failedToLoad || player.loadedURL == nil)
            .keyboardShortcut(.space, modifiers: [.command])
            .help(player.isPlaying ? "Pause (⌘Space)" : "Play (⌘Space)")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    WaveformShape(bins: waveform)
                        .fill(Color.secondary.opacity(0.35))
                    WaveformShape(bins: waveform)
                        .fill(Color.accentColor)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geometry.size.width * player.progress)
                        }
                    if waveform.isEmpty {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            player.seek(toProgress: value.location.x / max(1, geometry.size.width))
                        }
                )
            }
            .frame(height: 40)
            .accessibilityElement()
            .accessibilityLabel("Waveform")
            .accessibilityValue("\(Int(player.progress * 100)) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: player.seek(toProgress: player.progress + 0.05)
                case .decrement: player.seek(toProgress: player.progress - 0.05)
                @unknown default: break
                }
            }

            Text(Self.clock(player.currentTime) + " / " + Self.clock(player.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .overlay(alignment: .bottomLeading) {
            if player.failedToLoad {
                StatusLabel(String(localized: "The recording could not be opened.", bundle: .module), symbol: "exclamationmark.triangle.fill", tone: .attention)
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .offset(y: 14)
            }
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Mirrored bars, one per bin.
struct WaveformShape: Shape {
    let bins: [Float]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !bins.isEmpty else { return path }
        let barWidth = rect.width / CGFloat(bins.count)
        let gap = barWidth * 0.3
        let midY = rect.midY
        for (index, bin) in bins.enumerated() {
            let height = max(2, CGFloat(bin) * rect.height)
            let x = rect.minX + CGFloat(index) * barWidth
            path.addRoundedRect(
                in: CGRect(x: x + gap / 2, y: midY - height / 2, width: max(1, barWidth - gap), height: height),
                cornerSize: CGSize(width: 1, height: 1)
            )
        }
        return path
    }
}

/// "Replace the transcript?" after Retranscribe: shows both versions so the
/// user decides; nothing is written until Replace.
private struct RetranscribeProposalSheet: View {
    let proposal: HistoryViewModel.RetranscribeProposal
    let viewModel: HistoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Replace the transcript?")
                .font(.title3.weight(.semibold))
            Text("The recording was transcribed again with the current model. Replacing keeps the recording, timing, and AI result; only the original transcript changes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                column("Current", proposal.previousRawText)
                column("New", proposal.newRawText)
            }
            SheetButtonBar(
                confirmTitle: "Replace",
                isConfirmEnabled: true,
                onCancel: { viewModel.dismissRetranscription() },
                onConfirm: { Task { await viewModel.acceptRetranscription() } }
            )
            .padding(.horizontal, -20)
            .padding(.bottom, -20)
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 620)
    }

    private func column(_ title: LocalizedStringKey, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 260)
            .padding(10)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(text)")
    }
}

/// Optional standard window host for menu-bar applications.
@MainActor
public final class HistoryWindowController: NSWindowController {
    public init(viewModel: HistoryViewModel) {
        let rootView = HistoryView(viewModel: viewModel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "History"
        window.isReleasedWhenClosed = false
        // The minimum lives on the window rather than in the view, so the same
        // view can also be hosted in a narrower Settings tab.
        window.contentMinSize = NSSize(width: 800, height: 520)
        window.contentView = NSHostingView(rootView: rootView)
        super.init(window: window)
        window.center()
        // After `center()`: a frame saved from an earlier launch replaces the
        // centred default, so the window reopens where the user left it.
        window.setFrameAutosaveName("kvoice.history")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HistoryWindowController does not support NSCoder construction")
    }
}

private extension DictationMode {
    var displayName: String {
        switch self {
        case .off: return String(localized: "Off", bundle: .module)
        case .polish: return String(localized: "Polish", bundle: .module)
        case .translate: return String(localized: "Translate", bundle: .module)
        }
    }

    var symbolName: String {
        switch self {
        case .off: return "waveform"
        case .polish: return "wand.and.stars"
        case .translate: return "globe"
        }
    }
}

private extension HistoryAIStatus {
    var displayName: String {
        switch self {
        case .off: return String(localized: "Off", bundle: .module)
        case .succeeded: return String(localized: "Succeeded", bundle: .module)
        case .failed: return String(localized: "Failed, raw transcript used", bundle: .module)
        case .cancelledFallback: return String(localized: "Cancelled, raw transcript used", bundle: .module)
        }
    }
}

private extension InsertionOutcome {
    func displayName(isFile: Bool) -> String {
        switch self {
        case .inserted: return String(localized: "Inserted", bundle: .module)
        case .copiedToClipboard: return String(localized: "Copied to Clipboard", bundle: .module)
        case .deliveredInApp: return isFile ? String(localized: "Not inserted", bundle: .module) : String(localized: "Shown in Setup", bundle: .module)
        case .abortedAtTermination: return String(localized: "Aborted at Quit", bundle: .module)
        }
    }

    func detailName(isFile: Bool) -> String {
        switch self {
        case .inserted(let method):
            switch method {
            case .selectedTextAttribute: return String(localized: "Inserted via Accessibility", bundle: .module)
            case .textEditValueSplice: return String(localized: "Inserted via Accessibility (value splice)", bundle: .module)
            case .typedKeyboardEvents: return String(localized: "Typed into the application", bundle: .module)
            }
        case .copiedToClipboard(let reason):
            return String(localized: "Copied to Clipboard (\(reason.displayName))", bundle: .module)
        case .deliveredInApp:
            return isFile ? String(localized: "Transcribed from a file; nothing was inserted", bundle: .module) : String(localized: "Shown in the Setup window", bundle: .module)
        case .abortedAtTermination:
            return String(localized: "KVoice quit before the text was inserted", bundle: .module)
        }
    }
}

private extension ClipboardFallbackReason {
    var displayName: String {
        switch self {
        case .noFrontmostApplication: return String(localized: "no frontmost app", bundle: .module)
        case .targetApplicationChanged: return String(localized: "app changed", bundle: .module)
        case .noFocusedElement: return String(localized: "no focused field", bundle: .module)
        case .notEditable: return String(localized: "field not editable", bundle: .module)
        case .secureTarget: return String(localized: "secure field", bundle: .module)
        case .unsupportedValueType: return String(localized: "unsupported field", bundle: .module)
        case .setFailed: return String(localized: "insertion refused", bundle: .module)
        case .verifyFailed: return String(localized: "insertion not verified", bundle: .module)
        case .timeout: return String(localized: "timed out", bundle: .module)
        case .permissionNotGranted: return String(localized: "permission missing", bundle: .module)
        case .textTooLarge: return String(localized: "too long to type", bundle: .module)
        }
    }
}

private extension String {
    var oneLinePreview: String {
        replacingOccurrences(of: "\n", with: " ")
    }
}

private extension Date {
    /// Clock time for today, a short date for anything older.
    ///
    /// Rows used to show the time alone, which made a list spanning several days
    /// a column of ambiguous times with no way to tell yesterday from last week.
    var historyRowLabel: String {
        Calendar.current.isDateInToday(self)
            ? formatted(date: .omitted, time: .shortened)
            : formatted(date: .abbreviated, time: .shortened)
    }
}

private extension HistoryEntry {
    /// The D.10 sentence for a row whose AI stage did not complete: what
    /// happened and what kvoice did with the text. Nil on the happy path.
    var aiFallbackSummary: String? {
        switch aiStatus {
        case .failed:
            return String(localized: "AI did not respond. The raw transcript was used instead.", bundle: .module)
        case .cancelledFallback:
            return String(localized: "AI processing was cancelled. The raw transcript was used instead.", bundle: .module)
        case .off, .succeeded:
            return errorCode == nil ? nil : String(localized: "AI reported a problem. The raw transcript was used instead.", bundle: .module)
        }
    }

    var accessibilitySummary: String {
        var parts = [finalText.oneLinePreview, isFileTranscription ? String(localized: "File", bundle: .module) : mode.displayName, insertionOutcome.displayName(isFile: isFileTranscription)]
        if isFallback {
            parts.append("Fallback")
        }
        parts.append(createdAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: ". ")
    }
}
