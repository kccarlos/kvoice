import SwiftUI
import KvoiceDomain

/// The Data & Privacy section: the history switch, then — when the shell
/// passes a `DataPrivacyViewModel` — transcript retention with "Run
/// Transcript Cleanup Now", opt-in stored audio with its own retention, and
/// Auto Daily Export with a folder that can be re-authorized when its
/// bookmark goes stale; then the privacy content (local audio and
/// transcription, network matrix, log policy with Copy Diagnostics, data
/// folder). One grouped form; its own sidebar section since 2026-09-13.
/// P-M14 (2026-09-16): the About group (Version, Runtime, Model manifest,
/// Bundle, Open-Source Licenses…) moved to Help — this page keeps only its
/// privacy and network content, per its own name.
///
/// The app shell depends only on this initializer; `dataPrivacy` is optional
/// so previews and tests that have no store to clean can still render the
/// section.
@MainActor
public struct DataPrivacySectionView: View {
    @Bindable private var history: HistoryViewModel
    private let dataPrivacy: DataPrivacyViewModel?
    private let privacy: PrivacyAboutViewModel

    @State private var isShowingLicenses = false

    public init(
        history: HistoryViewModel,
        dataPrivacy: DataPrivacyViewModel? = nil,
        privacy: PrivacyAboutViewModel = .init()
    ) {
        self.history = history
        self.dataPrivacy = dataPrivacy
        self.privacy = privacy
    }

    public var body: some View {
        Form {
            Section {
                Toggle("Save dictation history", isOn: $history.historyEnabled)
                    .accessibilityLabel("Save dictation history")
                    .accessibilityHint("When off, new dictations are not saved. Existing entries stay until you clear them in History.")
                if let metrics = dataPrivacy?.metricsDescription {
                    SettingsFactRow("Stored", metrics, systemImage: "internaldrive")
                }
            } header: {
                Text("History")
            } footer: {
                SettingsFooter(note: history.refusalNote) {
                    Text("Whether dictations are saved at all. History is stored only on this Mac. Turning it off stops new entries; it does not delete the ones already saved.")
                }
            }

            if let dataPrivacy {
                DataRetentionSections(viewModel: dataPrivacy)
            }

            PrivacyAboutSections(viewModel: privacy) {
                isShowingLicenses = true
            }
        }
        .formStyle(.grouped)
        .task {
            await privacy.refreshHistoryMetrics()
        }
        .sheet(isPresented: $isShowingLicenses) {
            LicensesSheet(viewModel: privacy, isPresented: $isShowingLicenses)
        }
    }
}

/// The retention, stored-audio, and export groups. Every control commits at
/// once; every destructive action confirms and says what is kept.
@MainActor
struct DataRetentionSections: View {
    @Bindable var viewModel: DataPrivacyViewModel
    @State private var isCleanupConfirmationPresented = false

    var body: some View {
        retentionSection
        audioSection
        exportSection
    }

    // MARK: Transcript retention

    private var retentionSection: some View {
        Section {
            Toggle("Automatically delete transcript history", isOn: $viewModel.autoDeleteEnabled)
            Picker("Delete transcripts older than", selection: $viewModel.textRetentionDays) {
                ForEach(HistoryRetentionSettings.retentionChoicesInDays, id: \.self) { days in
                    Text(days.retentionDaysLabel).tag(days)
                }
            }
            // The outcome sits beside the button when there is room and
            // under it when the pane is narrow.
            ViewThatFits(in: .horizontal) {
                HStack { cleanupControls }
                VStack(alignment: .leading, spacing: 6) { cleanupControls }
            }
            .confirmationDialog(
                "Delete transcripts older than \(viewModel.textRetentionDays.retentionDaysLabel) now?",
                isPresented: $isCleanupConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Run Cleanup", role: .destructive) {
                    Task { await viewModel.runCleanupNow() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Older transcripts and their recordings are removed, and recordings older than \(viewModel.audioRetentionDays.retentionDaysLabel) are removed from newer transcripts. Newer transcripts, your settings, and the local model are kept. This cannot be undone.")
            }
        } header: {
            Text("Transcript Retention")
        } footer: {
            SettingsFooter(note: viewModel.refusalNote) {
                Text(viewModel.autoDeleteEnabled
                    ? "Runs when KVoice launches and once a day. Transcripts older than \(viewModel.textRetentionDays.retentionDaysLabel) are removed with their recordings."
                    : "Off: transcripts are kept until you delete them. The picker sets what Run Cleanup Now removes.")
            }
        }
        .task {
            // The folder may have come or gone since the section last
            // looked, and the figures change with every dictation.
            await viewModel.refreshFolderAccess()
            await viewModel.refreshMetrics()
        }
    }

    @ViewBuilder
    private var cleanupControls: some View {
        HStack(spacing: 8) {
            Button("Run Transcript Cleanup Now…") {
                isCleanupConfirmationPresented = true
            }
            .disabled(viewModel.isRunningCleanup || viewModel.runCleanup == nil)
            if viewModel.isRunningCleanup {
                ProgressView()
                    .controlSize(.small)
            }
        }
        if let outcome = viewModel.lastCleanupDescription {
            Text(outcome)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Stored audio (opt-in)

    private var audioSection: some View {
        Section {
            Toggle("Keep audio recordings", isOn: $viewModel.keepRecordings)
                .controlSize(.mini)
                .accessibilityHint("Saves each dictation's recording next to its transcript for playback and Retranscribe.")
            Picker("Keep audio for", selection: $viewModel.audioRetentionDays) {
                ForEach(AudioStorageSettings.retentionChoicesInDays, id: \.self) { days in
                    Text(days.retentionDaysLabel).tag(days)
                }
            }
            .disabled(!viewModel.keepRecordings && (viewModel.metrics?.audioBytes ?? 0) == 0)
        } header: {
            Text("Audio Recordings")
        } footer: {
            SettingsFooter(note: viewModel.refusalNote) {
                Text(viewModel.keepRecordings
                    ? "Each dictation's audio is saved as a 16 kHz WAV in the KVoice data folder, readable only by your account, and removed after \(viewModel.audioRetentionDays.retentionDaysLabel). Recordings enable playback and Retranscribe in History. They are never included in diagnostics."
                    : "Off by default. When off, no audio is written; recordings already saved stay until their retention passes or you clear history.")
            }
        }
    }

    // MARK: Auto Daily Export

    private var exportSection: some View {
        Section {
            Toggle("Auto Daily Export", isOn: $viewModel.autoDailyExportEnabled)
                .disabled(viewModel.exportFolderAccess.url == nil && !viewModel.autoDailyExportEnabled)
            folderRow
        } header: {
            Text("Export")
        } footer: {
            SettingsFooter(note: viewModel.refusalNote) {
                Text("Appends each completed dictation to a Markdown file named for the day (YYYY-MM-DD.md) in the folder you choose.")
            }
        }
    }

    @ViewBuilder
    private var folderRow: some View {
        if viewModel.isCheckingFolderAccess {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Checking the export folder…")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            resolvedFolderRow
        }
    }

    @ViewBuilder
    private var resolvedFolderRow: some View {
        switch viewModel.exportFolderAccess {
        case .notConfigured:
            HStack {
                Text("No folder chosen")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose Folder…") { viewModel.chooseExportFolder() }
            }
        case .available(let url):
            HStack(alignment: .top) {
                SettingsPathRow("Folder", url)
                Spacer()
                Button("Change…") { viewModel.chooseExportFolder() }
                    .fixedSize()
            }
        case .needsReauthorization:
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    StatusLabel(String(localized: "Folder access was lost", bundle: .module), symbol: "exclamationmark.triangle.fill", tone: .attention)
                        .labelStyle(.titleAndIcon)
                    if let path = viewModel.exportFolderDisplayPath {
                        Text(path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Text("The folder was moved, deleted, or its permission expired. Exports are skipped until you choose it again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Re-authorize…") { viewModel.chooseExportFolder() }
                    .fixedSize()
            }
            .accessibilityElement(children: .combine)
        }
    }
}
