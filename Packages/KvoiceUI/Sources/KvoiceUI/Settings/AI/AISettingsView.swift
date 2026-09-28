import SwiftUI
import KvoiceDomain

/// The AI configurations half of the AI Actions section, on its own.
///
/// The wizard's Ready page links here ("Set up AI Actions"; the form was
/// embedded as an "Optional AI" step until 2026-09-16), so it keeps the
/// endpoint fields and the connection test without the action grid. Settings hosts
/// `AIActionsSectionView`, which composes this view model with the actions
/// view model in one section. The mode picker that used to live here is gone:
/// the master switch and the default action belong to AI Actions (P2 fold).
@MainActor
public struct AISettingsView: View {
    /// Injected by the app shell, so `@Bindable` rather than `@StateObject` —
    /// see the note in `GeneralSettingsView`.
    @Bindable private var viewModel: AISettingsViewModel

    @State private var configurationSheet: SheetTarget?
    @State private var draft = AISettingsViewModel.Draft()
    /// The configuration awaiting delete confirmation. Its key goes with it,
    /// so the dialog says what is kept.
    @State private var configurationPendingDeletion: AIConfiguration?

    /// Typed fields are drafts, committed by `flushPendingChanges()` on
    /// submit, focus change, and disappearance (ADR-022 slice 7's draft
    /// rule). Tracking focus lets the view commit the moment the user moves
    /// on, so Tab-and-quit never loses the last field.
    @FocusState private var focusedField: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Field: Hashable {
        case baseURL, modelID, apiKey
    }

    private enum SheetTarget: Identifiable {
        case new
        case existing(UUID)

        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let id): return id.uuidString
            }
        }

        var editingID: UUID? {
            if case .existing(let id) = self { return id }
            return nil
        }
    }

    public init(viewModel: AISettingsViewModel = .init()) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            enableSection
            configurationsSection
            endpointSection
            testSection
        }
        .formStyle(.grouped)
        // Sizing belongs to the host window, not the tab content.
        .navigationTitle("AI")
        .onSubmit { viewModel.flushPendingChanges() }
        .onChange(of: focusedField) { _, _ in viewModel.flushPendingChanges() }
        .onDisappear { viewModel.flushPendingChanges() }
        // Switching to another app is the other common way to leave a field
        // without submitting it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            viewModel.flushPendingChanges()
        }
        // The draft rule (ADR-022 slice 7): a change from another door (an
        // Import, the status menu's Configuration pick) replaces the drafts
        // rather than being silently overwritten by them at the next flush.
        // Harmless after this view's own commit too: the stored value then
        // already equals the draft.
        .onChange(of: viewModel.host.settings.ai) { _, newValue in
            viewModel.baseURLText = newValue.baseURL?.absoluteString ?? ""
            viewModel.modelID = newValue.modelID
            viewModel.polishPrompt = newValue.promptConfiguration.polishPrompt
            viewModel.translationBCP47 = newValue.translationLanguage.bcp47
            viewModel.translationLanguageName = newValue.translationLanguage.displayName
        }
        .sheet(item: $configurationSheet) { target in
            AIConfigurationSheet(
                viewModel: viewModel,
                draft: $draft,
                editingID: target.editingID,
                onDismiss: { configurationSheet = nil }
            )
        }
        .confirmationDialog(
            "Delete “\(configurationPendingDeletion?.menuTitle ?? "")”?",
            isPresented: Binding(
                get: { configurationPendingDeletion != nil },
                set: { if !$0 { configurationPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: configurationPendingDeletion
        ) { configuration in
            Button("Delete Configuration", role: .destructive) {
                viewModel.deleteConfiguration(id: configuration.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its saved API key is removed with it. The endpoint fields below, your other configurations, and your actions are kept.")
        }
    }

    private var enableSection: some View {
        Section {
            Toggle("Enable AI Actions", isOn: $viewModel.isEnabled)
                .accessibilityLabel("Enable AI Actions")
        } header: {
            Text("Processing")
        } footer: {
            Text("AI is optional and off by default. When enabled, the default action from Settings › AI Actions runs after each transcription; only the local transcript is sent to your configured endpoint.")
        }
    }

    /// Saved endpoints, switchable here and from the menu bar.
    private var configurationsSection: some View {
        Section {
            if viewModel.configurations.isEmpty {
                Text("No AI configurations yet. Add one to switch quickly from the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.configurations) { configuration in
                    configurationRow(configuration)
                }
            }

            Button("Add Configuration…") {
                draft = AISettingsViewModel.Draft()
                configurationSheet = .new
            }
            .accessibilityHint("Choose a provider and name a new AI configuration.")

            if viewModel.activeConfigurationID != nil {
                Button("Save Edits to Selected Configuration") {
                    viewModel.flushPendingChanges()
                    viewModel.updateActiveConfigurationFromFields()
                }
                // Dead until the fields actually differ from the selection, so
                // the button doubles as an "unsaved edits" indicator.
                .disabled(!viewModel.activeConfigurationHasUnsavedEdits || viewModel.baseURLValidationError != nil)
                .accessibilityHint("Copies the endpoint fields below into the selected configuration.")
            }
        } header: {
            Text("AI Configurations")
        } footer: {
            Text("Each configuration stores a provider, endpoint, model, and its own key. Pick one by name from the menu bar to switch.")
        }
    }

    private func configurationRow(_ configuration: AIConfiguration) -> some View {
        let isActive = configuration.id == viewModel.activeConfigurationID
        // Name and buttons share a line when there is room; the buttons move
        // under the name at the setup window's minimum width.
        return ViewThatFits(in: .horizontal) {
            HStack {
                configurationIdentity(configuration, isActive: isActive)
                Spacer()
                configurationButtons(configuration, isActive: isActive)
            }
            VStack(alignment: .leading, spacing: 6) {
                configurationIdentity(configuration, isActive: isActive)
                HStack {
                    Spacer(minLength: 0)
                    configurationButtons(configuration, isActive: isActive)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isActive ? String(localized: "\(configuration.menuTitle), selected", bundle: .module) : configuration.menuTitle)
    }

    private func configurationIdentity(_ configuration: AIConfiguration, isActive: Bool) -> some View {
        HStack {
            Image(systemName: isActive ? "largecircle.filled.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                // The user-chosen name leads, since that is what the menu shows.
                Text(configuration.menuTitle)
                Text(DomainCopy.localized(configuration.kind.displayName)
                    + (configuration.modelID.isEmpty ? "" : " · \(configuration.modelID)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func configurationButtons(_ configuration: AIConfiguration, isActive: Bool) -> some View {
        if !isActive {
            Button("Set as Active") { viewModel.selectConfiguration(id: configuration.id) }
                .accessibilityLabel("Set \(configuration.menuTitle) as active")
        }
        Button("Edit") {
            draft = AISettingsViewModel.Draft(
                configuration: configuration,
                apiKey: viewModel.apiKey(for: configuration.id)
            )
            configurationSheet = .existing(configuration.id)
        }
        .accessibilityLabel("Edit \(configuration.menuTitle)")
        Button(role: .destructive) {
            configurationPendingDeletion = configuration
        } label: {
            Image(systemName: "trash")
        }
        .help("Delete \(configuration.menuTitle)")
        .accessibilityLabel("Delete \(configuration.menuTitle)")
    }

    private var endpointSection: some View {
        Section {
            TextField("Base URL", text: $viewModel.baseURLText)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .baseURL)
                .accessibilityLabel("AI base URL")
                .help("For example, http://localhost:11434/v1 or https://api.openai.com/v1")

            // Shown before anything is persisted: a refused URL never reaches
            // settings.json, so the user learns why here rather than at request time.
            if let error = viewModel.baseURLValidationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Base URL error: \(error)")
            }

            HStack {
                TextField("Model ID", text: $viewModel.modelID)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .modelID)
                    .accessibilityLabel("AI model ID")

                Button("Discover") {
                    viewModel.flushPendingChanges()
                    Task { await viewModel.discoverModels() }
                }
                .disabled(!viewModel.canDiscoverModels || viewModel.discoveryState == .loading)
                .accessibilityHint("Ask the endpoint which models it serves.")
            }

            discoveryStatus

            if !viewModel.discoveredModels.isEmpty {
                Picker("Available models", selection: $viewModel.modelID) {
                    // The current value may not be in the list; keep it
                    // selectable so opening the picker cannot silently change it.
                    if !viewModel.discoveredModels.contains(viewModel.modelID) {
                        Text(viewModel.modelID.isEmpty ? "None" : viewModel.modelID)
                            .tag(viewModel.modelID)
                    }
                    ForEach(viewModel.discoveredModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .accessibilityLabel("Discovered models")
            }

            SecureField("Optional API key", text: $viewModel.apiKey)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .apiKey)
                .accessibilityLabel("Optional AI API key")
        } header: {
            Text("OpenAI-Compatible Endpoint")
        } footer: {
            Text("HTTPS is required for remote hosts. HTTP is permitted only for localhost, 127.0.0.1, or ::1. The key is stored separately from settings.json and is sent only in the provider's credential header.")
        }
    }

    @ViewBuilder
    private var discoveryStatus: some View {
        switch viewModel.discoveryState {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Asking the endpoint for its models…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .loaded(let count):
            Text(count == 0
                ? "The endpoint reported no models."
                : count == 1 ? "Found 1 model." : "Found \(count) models.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Text("Could not list models. Check the base URL and key, then try again.")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var testSection: some View {
        Section {
            HStack {
                Button("Test Configuration") {
                    viewModel.flushPendingChanges()
                    Task { await viewModel.testConfiguration() }
                }
                .disabled(!viewModel.canTestConfiguration || viewModel.testState == .testing)
                .accessibilityHint("Sends one harmless manual Chat Completions test request. It is never sent automatically during dictation.")

                switch viewModel.testState {
                case .idle:
                    EmptyView()
                case .testing:
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Testing…")
                        .foregroundStyle(.secondary)
                case .succeeded:
                    StatusLabel(String(localized: "Configuration works", bundle: .module), symbol: "checkmark.circle.fill", tone: .positive)
                        .labelStyle(.titleAndIcon)
                case .failed(let message):
                    StatusLabel(message, symbol: "exclamationmark.triangle.fill", tone: .attention)
                        .labelStyle(.titleAndIcon)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .animation(reduceMotion ? nil : .default, value: viewModel.testState)
        } header: {
            Text("Manual Test")
        } footer: {
            Text("A failed AI request never blocks local dictation; KVoice inserts the raw transcript instead.")
        }
    }
}

public typealias AISettingsScreen = AISettingsView
