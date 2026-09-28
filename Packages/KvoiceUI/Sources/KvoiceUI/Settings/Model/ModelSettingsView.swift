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

    public var body: some View {
        @Bindable var speechModels = speechModels
        Form {
            defaultModelSection
            RuntimeCardView(viewModel: viewModel.runtime, memoryPressure: viewModel.memoryPressure)
            catalogSection
            packageDetailsSection
        }
        .formStyle(.grouped)
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

    // MARK: Default model and language (ADR-017)

    @ViewBuilder
    private var defaultModelSection: some View {
        Section {
            if let card = speechModels.defaultCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(card.entry.fullDisplayName)
                            .font(.headline)
                        Spacer()
                        if card.isResident {
                            StatusLabel(card.statusDescription, symbol: "checkmark.circle.fill", tone: .positive)
                                .font(.callout)
                                .labelStyle(.titleAndIcon)
                        } else {
                            Text(card.statusDescription)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(card.entry.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Current model: \(card.entry.fullDisplayName). \(card.statusDescription)")

                if card.entry.supportsStreaming {
                    modePicker(for: card)
                }

                Picker("Transcription language", selection: Binding(
                    get: { speechModels.transcriptionLanguage ?? "" },
                    set: { speechModels.setTranscriptionLanguage($0.isEmpty ? nil : $0) }
                )) {
                    Text("Auto-detect").tag("")
                    Divider()
                    ForEach(speechModels.languageOptions) { language in
                        Text(verbatim: LanguageNames.transcriptionLanguageName(forCode: language.code)).tag(language.code)
                    }
                }
                .accessibilityHint("Auto-detect keeps mixed-language dictation as spoken; a fixed language is a hint to the model.")

                if let warning = speechModels.languageCoverageWarning {
                    Label {
                        Text(warning)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .accessibilityLabel("Language not supported: \(warning)")
                }

                // P-M6 (2026-09-16): the package's live status, merged in
                // from the former separate "Status" group — same rows
                // (`SettingsFactRow`s), just without their own header now
                // that this group already shows the badge above.
                statusRows
            } else {
                Text(speechModels.isAvailable
                     ? "No speech model is available in this version."
                     : "The speech model catalog is not connected in this build.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Current Model")
        } footer: {
            // The language and mode pickers above are the settings-only
            // rows SpeechModelsViewModel projects (ADR-022 slice 7 part B);
            // a refusal (settings not yet loaded, or terminating — never a
            // running dictation) shows here.
            SettingsFooter(note: speechModels.refusalNote) {
                Text("Dictation uses the current model and is Ready only when the status above is Ready. Streaming shows live text; the inserted text comes from the full pass.")
            }
        }
    }

    private func modePicker(for card: ModelCardState) -> some View {
        Picker("Mode", selection: Binding(
            get: { speechModels.mode(for: card.id) },
            set: { speechModels.setMode($0, for: card.id) }
        )) {
            ForEach(card.entry.availableModes) { mode in
                Text(domain: mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Transcription mode for \(card.entry.fullDisplayName)")
    }

    // MARK: Catalog cards (ADR-017)

    @ViewBuilder
    private var catalogSection: some View {
        @Bindable var speechModels = speechModels
        Section {
            if speechModels.filteredCards.isEmpty {
                Text("No models to show.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(speechModels.filteredCards) { card in
                ModelCardRow(
                    card: card,
                    viewModel: speechModels,
                    reduceMotion: reduceMotion,
                    onDelete: { cardPendingDelete = card }
                )
            }
        } header: {
            // Title, filter, and gear on one line; the controls drop under
            // the title when the pane is narrow.
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Models")
                    Spacer()
                    catalogHeaderControls
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Models")
                    HStack { catalogHeaderControls }
                }
            }
        } footer: {
            Text("Every model runs on this Mac and is verified against the catalog bundled with this release before it is loaded. Only the current model is kept in memory.")
        }
    }

    @ViewBuilder
    private var catalogHeaderControls: some View {
        @Bindable var speechModels = speechModels
        // Explicit spacing plus a fixed size on both controls: the picker
        // otherwise reports a flexible width the HStack can compress, which
        // let the gear button's frame slide over the picker's last segment
        // at 700–900 pt wide (screenshot, 2026-09-16).
        HStack(spacing: 8) {
            Picker("Show", selection: $speechModels.filter) {
                ForEach(ModelCardFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 200)
            .fixedSize()
            .accessibilityLabel("Show recommended or all models")
            Button {
                speechModels.isShowingManagePanel = true
            } label: {
                Label("Manage Models", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .accessibilityLabel("Manage Models")
            .accessibilityHint("Opens the voice activity detection option for streaming.")
        }
    }

    // MARK: Package Details (M6/N12: identity + Advanced, collapsed)

    /// The single-model tab's legacy: the package's identity facts and its
    /// lifecycle actions, folded into one collapsed `DisclosureGroup` so the
    /// page reads shorter without losing a row or a button (M6). The Status
    /// rows live under Default Model since P-M6 (2026-09-16).
    private var packageDetailsSection: some View {
        Section {
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

// MARK: - One catalog card

@MainActor
private struct ModelCardRow: View {
    let card: ModelCardState
    let viewModel: SpeechModelsViewModel
    let reduceMotion: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(card.entry.fullDisplayName)
                    .font(.headline)
                if card.entry.isRecommended {
                    Text("Recommended")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                if card.isDefault {
                    Text("Default")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15), in: Capsule())
                }
                Spacer()
                StatusLabel(card.statusDescription, symbol: statusSymbol, tone: statusTone)
                    .font(.callout)
                    .labelStyle(.titleAndIcon)
                    .multilineTextAlignment(.trailing)
            }

            // Badges and the language coverage on one line when there is
            // room (four badges since ADR-019), otherwise the coverage
            // drops under the badges rather than clipping.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    badgeRow
                    languageSummary
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) { badgeRow }
                    languageSummary
                }
            }

            Text(card.entry.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let license = card.licenseLine {
                Text(license)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("License: \(license)")
            }

            if let progress = card.progress {
                ProgressView(value: progress)
                    .animation(reduceMotion ? nil : .linear(duration: 0.25), value: progress)
                    .accessibilityLabel("\(card.entry.fullDisplayName) progress")
                    .accessibilityValue("\(Int(progress * 100)) percent")
            }

            if !card.actions.isEmpty || card.isInstalled {
                // Buttons and the mode picker share a line when there is
                // room; the picker drops under the buttons when the pane is
                // narrow.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        actionButtons
                        Spacer()
                        modePicker
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) { actionButtons }
                        modePicker
                    }
                }
            }

            if let reason = viewModel.mutationDisabledReason(for: card), !card.actions.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .animation(reduceMotion ? nil : .default, value: card.actions)
    }

    @ViewBuilder
    private var actionButtons: some View {
        ForEach(card.actions) { action in
            Button(role: action.isDestructive ? .destructive : nil) {
                if action == .delete {
                    onDelete()
                } else {
                    viewModel.perform(action, on: card)
                }
            } label: {
                Text(card.title(for: action))
            }
            .disabled(!viewModel.isEnabled(action, for: card))
            .accessibilityLabel("\(card.title(for: action)) \(card.entry.fullDisplayName)")
        }
        if viewModel.isPending(card.id) {
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var modePicker: some View {
        if card.isInstalled, card.entry.supportsStreaming, card.entry.supportsBatch {
            Picker("Mode", selection: Binding(
                get: { viewModel.mode(for: card.id) },
                set: { viewModel.setMode($0, for: card.id) }
            )) {
                ForEach(card.entry.availableModes) { mode in
                    Text(domain: mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 190)
            .accessibilityLabel("Transcription mode for \(card.entry.fullDisplayName)")
        }
    }

    private var badgeRow: some View {
        ForEach(card.badges, id: \.self) { badge in
            Text(badge)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }

    private var languageSummary: some View {
        Text(card.entry.languageSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var statusSymbol: String {
        guard let state = card.state else { return "circle" }
        switch state {
        case .ready: return card.isDefault && !card.isResident ? "circle" : "checkmark.circle.fill"
        case .corrupt, .incompatible, .error: return "exclamationmark.triangle.fill"
        default: return "circle"
        }
    }

    private var statusTone: StatusTone {
        guard let state = card.state else { return .neutral }
        switch state {
        case .ready: return card.isDefault && !card.isResident ? .neutral : .positive
        case .corrupt, .incompatible, .error: return .attention
        default: return .neutral
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
