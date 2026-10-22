import SwiftUI
import KvoiceDomain

/// The Speech Models section (spec D.6 § 3 as extended by ADR-017): the default
/// model and transcription language, one card per catalog model with
/// Download / Use / Delete and a Streaming-or-Batch picker, the Manage
/// Models gear panel, and — for the default model's package — the identity,
/// status, and lifecycle actions the single-model tab always had (Choose
/// Existing…, Reveal, Forget). Mutation is locked out with an explanation
/// while a job or a model operation is active (FR-MODEL-017).
@MainActor
public struct ModelSettingsView: View {
    private let viewModel: ModelSettingsViewModel

    @State private var isConfirmingDelete = false
    @State private var isConfirmingForget = false
    @State private var cardPendingDelete: ModelCardState?
    /// M6/N12: collapsed by default — the package identity and the
    /// lifecycle actions are the single-model tab's legacy and are rarely
    /// needed once a model is set up. `@State` (not derived) so the fold
    /// survives the view model's frequent re-renders.
    @State private var isPackageDetailsExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(viewModel: ModelSettingsViewModel = .init()) {
        self.viewModel = viewModel
    }

    private var speechModels: SpeechModelsViewModel { viewModel.speechModels }

    /// The header's "Runtime…": opens the sheet through the view model.
    static func runtimeHeaderAction(_ viewModel: ModelSettingsViewModel) -> MainWindowHeaderAction {
        .runtimeDetails { [viewModel] in viewModel.isShowingRuntimeDetails = true }
    }

    public var body: some View {
        @Bindable var speechModels = speechModels
        // UI v2 fidelity F3 (Models.dc): the "In use" card and the "More
        // models" grid; the Runtime card, the package status and Package
        // Details moved behind "Runtime details ›" (a sheet), unchanged.
        KVCardPage {
            ModelsInUseCard(
                speechModels: speechModels,
                runtime: viewModel.runtime,
                onRuntimeDetails: { viewModel.isShowingRuntimeDetails = true }
            )
            ModelsMoreSection(
                speechModels: speechModels,
                reduceMotion: reduceMotion,
                onDelete: { cardPendingDelete = $0 }
            )
        }
        .sheet(isPresented: Binding(
            get: { viewModel.isShowingRuntimeDetails },
            set: { viewModel.isShowingRuntimeDetails = $0 }
        )) {
            runtimeDetailsSheet
        }
        // UI v2 fidelity F3b: Window.dc's "Runtime…" header button opens
        // the same sheet as the in-card link.
        .mainWindowHeaderAction(Self.runtimeHeaderAction(viewModel))
        .navigationTitle("Speech Models")
        // Keyed rather than run once per appearance: free space changes after
        // a download, a delete, or an install, and the old figure would sit
        // there until the tab was reopened.
        .task(id: viewModel.spaceEstimateKey) {
            await viewModel.refreshSpaceEstimate()
        }
        // The catalog poll attaches to the section that consumes it and
        // stops when the section is hidden.
        .task {
            await speechModels.pollWhileVisible()
        }
        // The Runtime card's sampling loop: snapshot, memory every ~2 s,
        // CPU / GPU while the runtime is busy. Stops with the section.
        .task {
            await viewModel.runtime.pollWhileVisible()
        }
        .sheet(isPresented: $speechModels.isShowingManagePanel) {
            ManageModelsPanel(viewModel: speechModels)
        }
        .confirmationDialog(
            "Delete \(cardPendingDelete?.entry.fullDisplayName ?? "this model")?",
            isPresented: Binding(
                get: { cardPendingDelete != nil },
                set: { if !$0 { cardPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                if let card = cardPendingDelete {
                    speechModels.perform(.delete, on: card)
                }
                cardPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { cardPendingDelete = nil }
        } message: {
            Text("The downloaded package is removed from disk. Other models, your settings, history, and shortcut are kept.")
        }
    }

    // MARK: Runtime details sheet

    private var runtimeDetailsSheet: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: KVCardLayout.blockSpacing) {
                    Text("Runtime details")
                        .font(.system(size: 17, weight: .bold))
                    RuntimeCardView(viewModel: viewModel.runtime, memoryPressure: viewModel.memoryPressure)
                    KVCardSection {
                        statusRows
                    } header: {
                        Text("Status")
                    }
                    packageDetailsSection
                }
                .padding(22)
            }
            Rectangle().fill(Color.kv.line).frame(height: 1)
            HStack {
                Spacer()
                Button("Done") { viewModel.isShowingRuntimeDetails = false }
                    .buttonStyle(KVButtonStyle(.primary, height: 28, fontSize: 13))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 640)
        .background(Color.kv.bg)
        .confirmationDialog(
            "Delete the downloaded model?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                viewModel.perform(.delete)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The managed package is removed from disk. Dictation is Not Ready until a model is downloaded or chosen again. Your settings, history, and shortcut are kept.")
        }
        .confirmationDialog(
            "Forget the external model folder?",
            isPresented: $isConfirmingForget,
            titleVisibility: .visible
        ) {
            Button("Forget Folder", role: .destructive) {
                viewModel.perform(.forget)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("KVoice stops using the folder but does not delete it. Dictation is Not Ready until a model is downloaded or chosen again.")
        }
    }

    // MARK: Package Details (M6/N12: identity + Advanced, collapsed)

    /// The single-model tab's legacy: the package's identity facts and its
    /// lifecycle actions, folded into one collapsed `DisclosureGroup` so the
    /// page reads shorter without losing a row or a button (M6). The Status
    /// rows live under Default Model since P-M6 (2026-09-16).
    private var packageDetailsSection: some View {
        KVCardSection {
            DisclosureGroup("Package Details", isExpanded: $isPackageDetailsExpanded) {
                VStack(alignment: .leading, spacing: 18) {
                    packageIdentityRows
                    packageAdvancedRows
                }
                .padding(.top, 6)
            }
        } footer: {
            Text("The package behind the current model, and the actions that manage it. Verified against the manifest bundled with this release before it is loaded.")
        }
    }

    @ViewBuilder
    private var packageIdentityRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsFactRow("Model", viewModel.descriptor?.modelID ?? "Whisper large-v3-turbo")
            SettingsFactRow("Revision", viewModel.descriptor?.revision ?? String(localized: "Unknown", bundle: .module))
            SettingsFactRow("Source", viewModel.descriptor?.source.displayName ?? String(localized: "Unknown", bundle: .module))
            SettingsFactRow("Size", viewModel.sizeDescription)
            if let location = viewModel.descriptor?.source.location {
                SettingsPathRow("Location", location)
            }
            if let manifestVersion = viewModel.descriptor?.manifestSchemaVersion {
                SettingsFactRow("Manifest schema", "\(manifestVersion)")
            }
        }
    }

    // MARK: Status (P-M6: merged into Default Model, no header of its own)

    /// The rows the separate "Status" group used to hold: the live status
    /// (with a progress bar while busy) and the download-size preflight.
    /// Same content, same `SettingsFactRow`s — just placed beneath the
    /// Default Model picker instead of under their own header (M6/P-M6).
    @ViewBuilder
    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    if viewModel.progress == nil, viewModel.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }
                    StatusLabel(viewModel.statusDescription, symbol: statusSymbol, tone: statusTone)
                        .labelStyle(.titleAndIcon)
                        .multilineTextAlignment(.trailing)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Model status")
            .accessibilityValue(viewModel.statusDescription)

            if let progress = viewModel.progress {
                ProgressView(value: progress)
                    .animation(reduceMotion ? nil : .linear(duration: 0.25), value: progress)
                    .accessibilityLabel("Model progress")
                    .accessibilityValue("\(Int(progress * 100)) percent")
            }
        }
        .animation(reduceMotion ? nil : .default, value: viewModel.progress == nil)

        if let estimate = viewModel.spaceEstimateDescription {
            SettingsFactRow("Download size", estimate)
                .accessibilityLabel("Download size and free space: \(estimate)")
            if viewModel.spaceEstimate?.isSufficient == false {
                StatusLabel(
                    String(localized: "There may not be enough free space for the download. Free up space or choose an existing model folder.", bundle: .module),
                    symbol: "exclamationmark.triangle.fill",
                    tone: .attention
                )
                .font(.caption)
                .labelStyle(.titleAndIcon)
            }
        }
    }

    private var statusSymbol: String {
        switch viewModel.state {
        case .ready: return "checkmark.circle.fill"
        case .corrupt, .incompatible, .error: return "exclamationmark.triangle.fill"
        default: return "circle"
        }
    }

    private var statusTone: StatusTone {
        switch viewModel.state {
        case .ready: return .positive
        case .corrupt, .incompatible, .error: return .attention
        default: return .neutral
        }
    }

    // MARK: Advanced (default model's package actions)

    @ViewBuilder
    private var packageAdvancedRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Advanced")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            if viewModel.availableActions.isEmpty {
                Text(viewModel.mutationDisabledReason ?? String(localized: "No actions are available in this state.", bundle: .module))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // Buttons wrap rather than clip when the window is narrow.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(viewModel.availableActions) { action in
                        actionButton(action)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(reduceMotion ? nil : .default, value: viewModel.availableActions)

                if let reason = viewModel.mutationDisabledReason {
                    // A spinner while the shell is still reacting to a click;
                    // a lock when something else holds the model.
                    HStack(spacing: 6) {
                        if viewModel.pendingAction != nil {
                            ProgressView()
                                .controlSize(.mini)
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: "lock")
                                .accessibilityHidden(true)
                        }
                        Text(reason)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Model changes are locked: \(reason)")
                }
            }

            Text("Choosing an existing folder verifies it against the trusted manifest and never modifies it. Delete applies only to the package KVoice downloaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func actionButton(_ action: ModelSettingsAction) -> some View {
        Button(role: action.isDestructive ? .destructive : nil) {
            switch action {
            case .delete: isConfirmingDelete = true
            case .forget: isConfirmingForget = true
            default: viewModel.perform(action)
            }
        } label: {
            Text(action.title)
                .frame(maxWidth: .infinity)
        }
        .disabled(!viewModel.isEnabled(action))
        .accessibilityLabel(action.title)
        .accessibilityHint(hint(for: action))
    }

    private func hint(for action: ModelSettingsAction) -> String {
        switch action {
        case .download: return String(localized: "Downloads and verifies the supported model. The download can be cancelled and resumed.", bundle: .module)
        case .resume: return String(localized: "Continues the paused download.", bundle: .module)
        case .cancel: return String(localized: "Stops the download. Downloaded bytes are kept so it can be resumed.", bundle: .module)
        case .retry: return String(localized: "Tries the failed operation again.", bundle: .module)
        case .chooseExisting: return String(localized: "Choose a folder containing an already verified model package.", bundle: .module)
        case .revealInFinder: return String(localized: "Shows the managed package in Finder.", bundle: .module)
        case .delete: return String(localized: "Removes the downloaded package from disk after confirmation.", bundle: .module)
        case .forget: return String(localized: "Stops using the external folder without deleting it.", bundle: .module)
        }
    }
}

// MARK: - Manage Models panel

@MainActor
private struct ManageModelsPanel: View {
    @Bindable var viewModel: SpeechModelsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Toggle("Voice Activity Detection", isOn: $viewModel.voiceActivityDetectionEnabled)
                } header: {
                    Text("Streaming")
                } footer: {
                    SettingsFooter(note: viewModel.refusalNote) {
                        Text("Lets streaming cut its working window at silences. It only segments; recording never stops on its own. The inserted-text options (space after inserting, automatic formatting) are in Recording.")
                    }
                }
            }
            .formStyle(.grouped)
            SheetButtonBar(
                confirmTitle: "Done",
                isConfirmEnabled: true,
                onCancel: { viewModel.isShowingManagePanel = false },
                onConfirm: { viewModel.isShowingManagePanel = false }
            )
            .padding()
        }
        .frame(minWidth: 420, minHeight: 240)
        .navigationTitle("Manage Models")
    }
}
