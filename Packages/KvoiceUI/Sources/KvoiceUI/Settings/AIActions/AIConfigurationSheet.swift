import KvoiceDomain
import SwiftUI

/// The add/edit sheet for an AI configuration.
///
/// Collects the type first (ADR-024: an OpenAI-compatible endpoint, or
/// Apple Intelligence on this Mac; ADR-027: or Apple Intelligence on
/// Private Cloud Compute), then the provider for an endpoint, then
/// only the fields that provider needs: a preset already knows its endpoint,
/// Azure wants a resource and a deployment, and `custom` must be given a
/// URL. The two Apple types have nothing to fill in but a name. "Verify &
/// Save" runs the connection test against the draft and stores it only on
/// success; "Save" stores it unverified for offline setups.
@MainActor
struct AIConfigurationSheet: View {
    @Bindable var viewModel: AISettingsViewModel
    @Binding var draft: AISettingsViewModel.Draft
    /// `nil` when adding; the configuration being edited otherwise.
    let editingID: UUID?
    /// ADR-024: the on-device row's availability, for the note under the
    /// type choice. The default is what a preview sees.
    var availability: SettingsAvailabilityModel = .init()
    let onDismiss: () -> Void

    /// Once the user types a name, changing provider must not overwrite it.
    @State private var nameWasEdited = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            providerSection
            switch draft.transport {
            case .appleIntelligence:
                onDeviceSection
            case .privateCloudCompute:
                privateCloudComputeSection
            case .openAICompatible:
                endpointSection
            }
            verificationSection
        }
        .formStyle(.grouped)
        .onAppear { viewModel.clearVerification() }
        .safeAreaInset(edge: .bottom) {
            // An explicit button bar, not `.toolbar`: a sheet has no window
            // toolbar of its own, and Return/Escape need explicit shortcuts.
            HStack(spacing: 12) {
                if let refusal = availability.savingRefusal(for: draft.transport) {
                    // ADR-027: this build can never use it; saving it would
                    // only leave a dead row behind.
                    Text(verbatim: refusal)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !draft.isComplete {
                    Text(draft.transport.needsEndpointFields ? "Fill in a name, endpoint, and model." : "Give the configuration a name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button(editingID == nil ? "Save Without Verifying" : "Save") {
                    save()
                }
                .disabled(!canSave)
                .help("Stores the configuration without sending a test request.")
                Button("Verify & Save") {
                    Task {
                        if await viewModel.verifyAndSave(draft, replacing: editingID) != nil {
                            onDismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .accessibilityHint("Sends one harmless test request, then saves if it succeeds.")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .frame(minWidth: 500, minHeight: 460)
    }

    /// Complete, not mid-test, and (ADR-027) not a Private Cloud Compute
    /// configuration this build is refused outright.
    private var canSave: Bool {
        draft.isComplete
            && viewModel.verificationState != .testing
            && availability.savingRefusal(for: draft.transport) == nil
    }

    private func save() {
        if let editingID {
            viewModel.updateConfiguration(id: editingID, from: draft)
        } else {
            viewModel.addConfiguration(draft)
        }
        onDismiss()
    }

    private var providerSection: some View {
        Section {
            // The type comes first because it decides everything below: an
            // endpoint asks for a provider, URL, model and key; the Apple
            // models ask for nothing. Three choices no longer fit a
            // segmented control at the sheet's width, so a radio group.
            Picker("Type", selection: $draft.transport) {
                Text("OpenAI-compatible endpoint").tag(AIProviderTransport.openAICompatible)
                Text("Apple Intelligence (on-device)").tag(AIProviderTransport.appleIntelligence)
                Text("Apple Intelligence (Private Cloud Compute)").tag(AIProviderTransport.privateCloudCompute)
            }
            .pickerStyle(.radioGroup)
            .accessibilityLabel("Configuration type")

            if draft.transport == .openAICompatible {
                Picker("Provider", selection: $draft.kind) {
                    ForEach(AIProviderKind.endpointKinds) { kind in
                        Text(domain: kind.displayName).tag(kind)
                    }
                }
                .onChange(of: draft.kind) { _, newKind in
                    draft.changeKind(to: newKind, nameWasEdited: nameWasEdited)
                }
            }

            TextField("Name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: draft.name) { _, _ in nameWasEdited = true }
                .accessibilityLabel("Configuration name")
                .help("Shown in the menu bar, so make it recognisable.")
        } header: {
            Text(editingID == nil ? "New AI Configuration" : "Edit AI Configuration")
        }
    }

    /// ADR-024: what the on-device type means, and whether this Mac can run
    /// it right now (the same availability row the configuration list shows).
    private var onDeviceSection: some View {
        Section {
            if let reason = availability.disabledReason(.aiAppleIntelligenceConfiguration) {
                StatusLabel(reason, symbol: "exclamationmark.triangle.fill", tone: .attention)
                    .labelStyle(.titleAndIcon)
            } else {
                StatusLabel(String(localized: "Available on this Mac", bundle: .module), symbol: "checkmark.circle.fill", tone: .positive)
                    .labelStyle(.titleAndIcon)
            }
        } header: {
            Text("On this Mac")
        } footer: {
            Text("Runs Apple's on-device language model through the Foundation Models framework (macOS 26 or later). No endpoint, no key, and nothing leaves this Mac. Expect cleanup-grade results — below cloud models — and a context window of about 4,000 tokens; a longer transcript is inserted unpolished.")
        }
    }

    /// ADR-027: what Private Cloud Compute means — above all, that the
    /// transcript leaves this Mac — and whether this build can use it. The
    /// status says only what is known: a refusal (edition, signature, OS,
    /// device) or the quota line; it never claims "available" before the
    /// framework has been asked, which happens only once such a
    /// configuration is saved and AI Actions is on.
    private var privateCloudComputeSection: some View {
        Section {
            if let reason = availability.disabledReason(.aiPrivateCloudComputeConfiguration) {
                StatusLabel(reason, symbol: "exclamationmark.triangle.fill", tone: .attention)
                    .labelStyle(.titleAndIcon)
            } else if let quota = availability.privateCloudComputeQuotaLine {
                StatusLabel(quota, symbol: "gauge.with.dots.needle.67percent", tone: .attention)
                    .labelStyle(.titleAndIcon)
            } else {
                Text("Verify & Save sends one short test request to Private Cloud Compute.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("On Apple's servers")
        } footer: {
            Text("Sends the transcript, the action's instructions and any context you turned on to Apple's Private Cloud Compute over the internet. Apple states that requests are used only to answer them, are not stored, and are not accessible to Apple. Dictation sends nothing here unless this configuration is active and AI Actions is on (Verify & Save and Test send one short test request), and KVoice never switches to it on its own. Requires macOS 27, the Mac App Store edition of KVoice and Apple Intelligence; each person has a daily request limit tied to their Apple Account.")
        }
    }

    @ViewBuilder
    private var endpointSection: some View {
        Section {
            if draft.kind.usesAzureAddressing {
                TextField("Resource name", text: $draft.azureResource)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Azure resource name")
                    .help("The <resource> in https://<resource>.openai.azure.com")
                TextField("Deployment name", text: $draft.azureDeployment)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Azure deployment name")
                TextField("API version", text: $draft.apiVersion)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Azure API version")
                if let url = draft.resolvedBaseURL {
                    LabeledContent("Endpoint") {
                        Text(url.absoluteString)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } else if draft.kind.requiresManualBaseURL {
                TextField("Base URL", text: $draft.baseURLText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Base URL")
                    .help("For example, http://localhost:8080/v1")
                Picker("Authentication", selection: $draft.authStyle) {
                    Text("Bearer token (Authorization header)").tag(AIProviderAuthStyle.bearer)
                    Text("api-key header").tag(AIProviderAuthStyle.apiKeyHeader)
                }
            } else {
                LabeledContent("Endpoint") {
                    Text(draft.baseURLText)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let error = draft.baseURLValidationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !draft.kind.usesAzureAddressing {
                if draft.kind.recommendedModels.isEmpty {
                    TextField("Model", text: $draft.modelID)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Model identifier")
                } else {
                    Picker("Recommended model", selection: $draft.modelID) {
                        if !draft.kind.recommendedModels.contains(draft.modelID) {
                            Text(draft.modelID.isEmpty ? "Custom…" : draft.modelID).tag(draft.modelID)
                        }
                        ForEach(draft.kind.recommendedModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    TextField("Model ID", text: $draft.modelID)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Model identifier")
                        .help("Any model the provider serves; the picker above only suggests.")
                }
            }

            if draft.kind.expectsAPIKey {
                SecureField("API key", text: $draft.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("API key")
                HStack {
                    if let hint = draft.kind.credentialHint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = draft.kind.apiKeyURL {
                        Link("Get API Key", destination: url)
                            .font(.caption)
                    }
                }
            } else if let hint = draft.kind.credentialHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(draft.kind.requiresManualBaseURL || draft.kind.usesAzureAddressing ? "Endpoint" : "Details")
        } footer: {
            Text("HTTPS is required for remote hosts. The key is stored separately from settings.json and sent only in the provider's credential header.")
        }
    }

    private var idleVerificationNote: LocalizedStringKey {
        switch draft.transport {
        case .openAICompatible: return "Verify & Save sends one short test request to the endpoint."
        case .appleIntelligence: return "Verify & Save runs one short test request on this Mac."
        case .privateCloudCompute: return "Verify & Save sends one short test request to Private Cloud Compute."
        }
    }

    private var verificationSection: some View {
        Section {
            HStack(spacing: 8) {
                switch viewModel.verificationState {
                case .idle:
                    Text(idleVerificationNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .testing:
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("Verifying…").foregroundStyle(.secondary)
                case .succeeded:
                    StatusLabel(String(localized: "Verified and saved", bundle: .module), symbol: "checkmark.circle.fill", tone: .positive)
                        .labelStyle(.titleAndIcon)
                case .failed(let message):
                    StatusLabel(message, symbol: "exclamationmark.triangle.fill", tone: .attention)
                        .labelStyle(.titleAndIcon)
                }
            }
            .animation(reduceMotion ? nil : .default, value: viewModel.verificationState)
        }
    }
}
