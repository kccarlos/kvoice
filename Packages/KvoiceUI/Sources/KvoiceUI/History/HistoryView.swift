import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KvoiceDomain

/// Native SwiftUI History surface, drawn to Window.dc (UI v2 fidelity F3b):
/// the stats strip, then one bordered container with the 300 pt list column
/// (search, ＋ / ⤴︎, filter chips, rows) beside the detail (title, Original
/// / Enhanced, the transcript, Copy, the recording, the facts). With nothing
/// saved the page is one empty card instead. App-shell routing and settings
/// persistence remain outside this view; `HistoryViewModel` exposes the
/// repository, audio store, engine, and enable-toggle seams the shell wires.
@MainActor
public struct HistoryView: View {
    @Bindable private var viewModel: HistoryViewModel
    @State private var isClearConfirmationPresented = false
    @State private var isBulkDeleteConfirmationPresented = false
    @FocusState private var listFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    /// Window.dc: the list column is 300 pt.
    static let listWidth: CGFloat = 300

    public init(viewModel: HistoryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            if let empty = viewModel.emptyState {
                HistoryEmptyCard(
                    state: empty,
                    onTestDictation: viewModel.startTestDictation,
                    onOpenDataPrivacy: viewModel.openDataPrivacy
                )
            } else {
                VStack(alignment: .leading, spacing: KVCardLayout.blockSpacing) {
                    HistoryDashboardView(dashboard: viewModel.dashboard, isFiltered: viewModel.isFiltered)
                    container
                }
            }
        }
        // Window.dc `main`: 36 pt sides, 24 pt bottom; 12 + the header's
        // 6 pt above.
        .padding(.horizontal, KVCardLayout.sidePadding)
        .padding(.top, KVSpacing.s)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        // UI v2 fidelity F3b: Window.dc's "Transcribe File…" header button.
        .mainWindowHeaderAction(.transcribeFile(
            canTranscribeFiles: viewModel.canTranscribeFiles,
            historyEnabled: viewModel.historyEnabled,
            isTranscribing: viewModel.isTranscribingFile
        ) { [viewModel] in
            Self.chooseFileToTranscribe(viewModel)
        })
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

    /// Window.dc: radius 12, a `line` ring, the list column and the detail
    /// split by a `line` rule.
    private var container: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                listColumn
                    .frame(width: Self.listColumnWidth(containerWidth: proxy.size.width))
                Rectangle()
                    .fill(Color.kv.line)
                    .frame(width: 1)
                    .accessibilityHidden(true)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.kv.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(contrast == .increased ? Color.kv.text2 : Color.kv.line, lineWidth: 1)
        }
    }

    /// Window.dc's 300 pt column, narrowed (never under 220) so the detail
    /// keeps at least 280 pt in the smallest window.
    static func listColumnWidth(containerWidth: CGFloat) -> CGFloat {
        guard containerWidth > 0 else { return listWidth }
        return min(listWidth, max(220, containerWidth - 1 - 280))
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            listHeader
            Rectangle().fill(Color.kv.line2).frame(height: 1).accessibilityHidden(true)

            if let errorMessage = viewModel.errorMessage {
                errorBanner(errorMessage)
            }

            contentList
                .frame(maxHeight: .infinity)

            if viewModel.isSelecting {
                selectionBar
            }

            if let pending = viewModel.pendingUndo {
                undoBar(pending)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }

            footer
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.pendingUndo)
    }

    /// Window.dc: padding 10, 8 pt between the search row and the chips.
    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                searchField
                actions
            }

            if !viewModel.historyEnabled {
                // P-M8 (2026-09-16): the "Save History" toggle itself moved
                // to Data & Privacy — this is now the one setting's one
                // home. J.5 still applies: disabling stops future writes
                // and does not delete existing rows, and the state stays
                // discoverable and one tap from fixable here.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save History is off. New dictations are not saved. Items already saved stay here until you clear them.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kv.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let openDataPrivacy = viewModel.openDataPrivacy {
                        Button("Data & Privacy") {
                            openDataPrivacy()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kv.cursorInk)
                        .accessibilityHint("Opens Data & Privacy, where Save dictation history is turned on.")
                    }
                }
            }

            filters
        }
        .padding(10)
        .animation(reduceMotion ? nil : .default, value: viewModel.historyEnabled)
    }

    /// Window.dc: 28 pt, radius 7, `fill`, 12 pt.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color.kv.text2)
                .accessibilityHidden(true)
            TextField("Search transcripts", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityLabel("Search history")
                .accessibilityHint("Filters saved transcripts by raw or final text. Searching stays on this Mac.")
            if !viewModel.searchText.isEmpty {
                Button {
                    Task { await viewModel.clearSearch() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.kv.text2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.kv.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// UI v2 wave 5a: the filters as chips — a time-range menu, a
    /// recording-length menu and a "With AI" toggle. Each menu holds every
    /// option the old pickers did; a chip turns cursor-blue while it narrows
    /// the list. Choices commit at once (no debounce).
    private var filters: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Time range", selection: $viewModel.timeRange) {
                    ForEach(HistoryTimeRange.allCases, id: \.self) { range in
                        Text(domain: range.displayName).tag(range)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HistoryFilterChip(isActive: viewModel.timeRange != .all, showsMenuIndicator: false) {
                    Text(domain: viewModel.timeRange.displayName)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Time range")
            .accessibilityValue(Text(domain: viewModel.timeRange.displayName))

            Menu {
                Picker("Duration", selection: $viewModel.durationBucket) {
                    Text("Any length").tag(HistoryDurationBucket?.none)
                    ForEach(HistoryDurationBucket.allCases, id: \.self) { bucket in
                        Text(domain: bucket.displayName).tag(HistoryDurationBucket?.some(bucket))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HistoryFilterChip(isActive: viewModel.durationBucket != nil, showsMenuIndicator: false) {
                    if let bucket = viewModel.durationBucket {
                        Text(domain: bucket.displayName)
                    } else {
                        Text("Any length")
                    }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Recording length")

            Button {
                viewModel.onlyWithAI.toggle()
            } label: {
                HistoryFilterChip(isActive: viewModel.onlyWithAI, showsMenuIndicator: false) {
                    Text("With AI")
                }
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("With AI")
            .accessibilityHint("Shows only dictations an AI action changed.")
            .accessibilityAddTraits(viewModel.onlyWithAI ? .isSelected : [])
            .accessibilityValue(Text(verbatim: KVAccessibility.selectionValue(viewModel.onlyWithAI)))
            Spacer(minLength: 0)
        }
        .onChange(of: viewModel.timeRange) { _, _ in
            Task { await viewModel.applyFilters() }
        }
        .onChange(of: viewModel.durationBucket) { _, _ in
            Task { await viewModel.applyFilters() }
        }
        .onChange(of: viewModel.onlyWithAI) { _, _ in
            Task { await viewModel.applyFilters() }
        }
    }

    /// Window.dc: ＋ (Transcribe file) and ⤴︎ (Export) as 28 pt icon
    /// buttons. Refresh, Select and Clear All — not drawn — sit in a third
    /// "More" menu; ⌘R still refreshes.
    private var actions: some View {
        HStack(spacing: 0) {
            if viewModel.canTranscribeFiles {
                if viewModel.isTranscribingFile {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                        .accessibilityLabel("Transcribing file")
                } else {
                    Button {
                        Self.chooseFileToTranscribe(viewModel)
                    } label: {
                        HistoryIconLabel(systemImage: "plus", size: 14)
                    }
                    .buttonStyle(.plain)
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

            Menu {
                Button("Refresh") {
                    Task { await viewModel.refresh() }
                }
                .disabled(viewModel.isLoading)
                Button(viewModel.isSelecting ? "Leave selection mode" : "Select several items") {
                    viewModel.setSelecting(!viewModel.isSelecting)
                }
                .disabled(viewModel.entries.isEmpty && !viewModel.isSelecting)
                Divider()
                Button("Clear All…", role: .destructive) {
                    isClearConfirmationPresented = true
                }
                .disabled(viewModel.isLoading || (viewModel.entryCount ?? viewModel.entries.count) == 0)
            } label: {
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                        .accessibilityLabel("Refreshing history")
                } else {
                    HistoryIconLabel(systemImage: "ellipsis", size: 13)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More history actions")

            // ⌘R, kept from the toolbar the design dropped.
            Button("Refresh history") {
                Task { await viewModel.refresh() }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(viewModel.isLoading)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
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
            HistoryIconLabel(systemImage: "square.and.arrow.up", size: 13)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
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
        case .empty where viewModel.isShowingSearchResults || viewModel.isFiltered:
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
            rows
        }
    }

    /// The drawn list (Window.dc `hist`). A focusable column like the
    /// drawn sidebar: click or Tab focuses it, ↑ / ↓ move the selection,
    /// Delete removes the selected row (with Undo, D.7); each row has the
    /// context menu, and VoiceOver reads a "History items" group of buttons
    /// with the selected one marked.
    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.entries) { entry in
                        HistoryRow(
                            entry: entry,
                            hasAudio: viewModel.hasStoredAudio(entry),
                            isSelected: viewModel.selectedEntryID == entry.id,
                            isFocused: listFocused && viewModel.selectedEntryID == entry.id,
                            isSelecting: viewModel.isSelecting,
                            isChecked: viewModel.selectedEntryIDs.contains(entry.id),
                            onToggleCheck: { viewModel.toggleSelection(entry.id) }
                        )
                        .id(entry.id)
                        .onTapGesture {
                            listFocused = true
                            viewModel.selectedEntryID = entry.id
                        }
                        .accessibilityAction { viewModel.selectedEntryID = entry.id }
                        .contextMenu {
                            rowActions(for: entry)
                        }
                    }

                    if viewModel.canLoadMore {
                        Button("Load More History") {
                            Task { await viewModel.loadNextPage() }
                        }
                        .buttonStyle(.kv)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .accessibilityHint("Loads older history items")
                    }
                }
            }
            .scrollIndicators(.automatic)
            .onChange(of: viewModel.selectedEntryID) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(id) }
            }
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            viewModel.selectNeighbour(step: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.selectNeighbour(step: 1)
            return .handled
        }
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
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kv.text2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 8)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.statusMessage)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("History items", bundle: .module))
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text(viewModel.selectedEntryIDs.count == 1 ? "1 selected" : "\(viewModel.selectedEntryIDs.count) selected")
                .font(.system(size: 12).monospacedDigit())
            Button("Select All") { viewModel.selectAllLoaded() }
                .disabled(viewModel.selectedEntryIDs.count == viewModel.entries.count)
            Spacer()
            Button("Delete…", role: .destructive) {
                isBulkDeleteConfirmationPresented = true
            }
            .disabled(viewModel.selectedEntryIDs.isEmpty)
            .help("Delete the checked items…")
        }
        .buttonStyle(.kv)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.kv.wash)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection")
    }

    /// Row count, database size, and stored audio size.  These come from the
    /// repository, not from the loaded page, so they stay right while paging
    /// or filtering. Not drawn in Window.dc; kept as the column's foot.
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
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(Color.kv.text2)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.kv.line2).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func undoBar(_ pending: HistoryViewModel.PendingDeletion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .foregroundStyle(Color.kv.text2)
                .accessibilityHidden(true)
            Text("Deleted “\(pending.entry.finalText.oneLinePreview)”")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button("Undo") {
                Task { await viewModel.undoDelete() }
            }
            .buttonStyle(.kv)
            .keyboardShortcut("z", modifiers: [.command])
            .help("Restore the deleted item")
            Button {
                Task { await viewModel.dismissUndo() }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.kv.wash)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Item deleted. Undo available for ten seconds.")
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading History…")
                .foregroundStyle(Color.kv.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading History")
    }

    private func errorBanner(_ message: String) -> some View {
        StatusLabel(message, symbol: "exclamationmark.triangle.fill", tone: .attention)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.kv.warnSoft)
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

    private static func chooseFileToTranscribe(_ viewModel: HistoryViewModel) {
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
