import SwiftUI
import KvoiceDomain

/// The Privacy & About surface (spec D.6 § 6): where data goes, what is
/// logged, versions, licenses, and Copy Diagnostics. Kept as a standalone
/// form for previews and tests; the main window embeds the same sections
/// through `PrivacyAboutSections` in Settings › Data & Privacy.
@MainActor
public struct PrivacyAboutView: View {
    private let viewModel: PrivacyAboutViewModel

    @State private var isShowingLicenses = false

    public init(viewModel: PrivacyAboutViewModel = .init()) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            PrivacyAboutSections(viewModel: viewModel) {
                isShowingLicenses = true
            }
            // P-M14: kept here too so this standalone "Privacy & About" form
            // (previews and tests only; the app hosts the two halves
            // separately in Data & Privacy and Help) still shows every
            // section its title promises.
            AboutSections(viewModel: viewModel) {
                isShowingLicenses = true
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Privacy & About")
        .task {
            await viewModel.refreshHistoryMetrics()
        }
        .sheet(isPresented: $isShowingLicenses) {
            LicensesSheet(viewModel: viewModel, isPresented: $isShowingLicenses)
        }
    }
}

/// The privacy, network, log, and data sections, for placing inside any
/// grouped `Form`. P-M14 (2026-09-16): the fifth section, About, moved to
/// Help (`AboutSections` below) — this page keeps only its privacy/network
/// content (M14). `onShowLicenses` is the host's sheet trigger; both hosts
/// (Data & Privacy and Help) own their own sheet so the same notices are
/// reachable from either page. The host also runs
/// `viewModel.refreshHistoryMetrics()` from its own `.task`, because a
/// modifier on a `Section` stops `Form` treating it as one.
@MainActor
struct PrivacyAboutSections: View {
    let viewModel: PrivacyAboutViewModel
    let onShowLicenses: @MainActor () -> Void

    var body: some View {
        privacySection
        networkSection
        logSection
        dataSection
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            Label {
                Text("Audio is captured only while you dictate and is transcribed on this Mac by the local Whisper model. No recording is saved and nothing is uploaded.")
            } icon: {
                Image(systemName: "lock.fill")
            }
            Label {
                Text("AI polish and translation are off by default. When you turn one on, only the transcript text is sent to the endpoint you configured.")
            } icon: {
                Image(systemName: "text.bubble")
            }
            Label {
                Text("There is no account, telemetry, or background recording.")
            } icon: {
                Image(systemName: "person.crop.circle.badge.xmark")
            }
        } header: {
            Text("Local Audio and Transcription")
        }
    }

    // MARK: Network matrix

    private var networkSection: some View {
        Section {
            networkRow(
                "AI Off",
                "No network I/O during dictation once the model is installed."
            )
            networkRow(
                "Polish or Translate",
                "Transcript text only, to the configured endpoint. Never audio, history, clipboard, or the target app's content."
            )
            networkRow(
                "Model download",
                viewModel.modelRepositoryHost.map { "Only from \($0), the repository named in the bundled manifest." }
                    ?? "Only from the repository named in the bundled manifest."
            )
        } header: {
            Text("Network Behavior")
        }
    }

    private func networkRow(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Logs

    private var logSection: some View {
        Section {
            Text("Diagnostics record scalars only: state names, error codes, timings, and byte counts. Transcript text, audio, and API keys are never written to a log, and Copy Diagnostics below is redacted the same way.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Copy Diagnostics") {
                    viewModel.copyDiagnostics()
                }
                .accessibilityHint("Copies versions, permission and model status, and settings flags as plain text. No transcript, key, or endpoint path is included.")

                if let copiedAt = viewModel.lastCopiedAt {
                    Text("Copied at \(copiedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Log Policy")
        }
    }

    // MARK: Data

    private var dataSection: some View {
        Section {
            if let folder = viewModel.dataFolderURL {
                SettingsPathRow("Data folder", folder)
                Button("Open Data Folder") {
                    viewModel.openDataFolder()
                }
                .accessibilityHint("Reveals the folder holding settings, history, diagnostics, and the managed model in Finder.")
            } else {
                SettingsFactRow("Data folder", "Unavailable in this session")
            }

            if let metrics = viewModel.historyMetricsDescription {
                SettingsFactRow("History", metrics)
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Everything KVoice stores lives in this folder: settings, history, diagnostics, and the managed model. Nothing is kept anywhere else.")
        }
    }

}

/// The About group — Version, Runtime, Model manifest, Bundle, Open-Source
/// Licenses… — moved here from Data & Privacy (P-M14, 2026-09-16): it is
/// facts about the app, not about privacy, and Help is where the rest of
/// "about kvoice" already lives (Guides, Feedback, Acknowledgments). The
/// status-menu "About kvoice" item is unchanged — it still opens the
/// standard `NSApplication` About panel, not this page. `onShowLicenses` is
/// the host's own sheet trigger, same contract as `PrivacyAboutSections`.
@MainActor
struct AboutSections: View {
    let viewModel: PrivacyAboutViewModel
    let onShowLicenses: @MainActor () -> Void

    var body: some View {
        Section {
            SettingsFactRow("Version", viewModel.versionDescription)
            SettingsFactRow("Runtime", PrivacyAboutViewModel.runtimeDescription)
            SettingsFactRow("Model manifest", viewModel.modelManifestDescription ?? "Not bundled")
            SettingsFactRow("Bundle", PrivacyAboutViewModel.bundleIdentifier)

            Button("Open-Source Licenses…") {
                onShowLicenses()
            }
            .accessibilityHint("Shows the third-party notices for the libraries linked into KVoice.")
        } header: {
            Text("About")
        }
    }
}

/// The third-party notices, as a sheet with a Done bar. Reads the notices
/// on first appearance; `loadLicenses()` is a no-op after that.
@MainActor
struct LicensesSheet: View {
    let viewModel: PrivacyAboutViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(viewModel.licensesText ?? "The third-party notices file is not bundled with this build. See THIRD_PARTY_NOTICES.md in the source repository.")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .accessibilityLabel("Open-source licenses")
            }
            Divider()
            SheetButtonBar(
                confirmTitle: "Done",
                isConfirmEnabled: true,
                onCancel: { isPresented = false },
                onConfirm: { isPresented = false }
            )
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 360, idealHeight: 520)
        .task {
            viewModel.loadLicenses()
        }
    }
}
