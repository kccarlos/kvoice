import KvoiceDomain
import SwiftUI

/// The body of the "AI Actions" section (hosted by `AIActionsSectionView`): one place for the master switch, the saved AI
/// configurations, the default action grid, the selected action's mode
/// settings, the Selection Action slots, the user profile, action triggers,
/// and the ⌘1–⌘0 explanation. It replaces the separate AI and Modes tabs.
///
/// Two view models back it, as the settings-list pattern prescribes: the
/// configurations half (`AISettingsViewModel`) and the actions half
/// (`PromptModeSettingsViewModel`). Both are injected by the app shell, so
/// they are `@Bindable`, never `@StateObject`.
@MainActor
public struct AIActionsForm: View {
    @Bindable private var configurations: AISettingsViewModel
    @Bindable private var actions: PromptModeSettingsViewModel
    /// ADR-022 item 3: the `.aiActionSettings` row (master switch off, or no
    /// endpoint). Applied to the Action Triggers group, whose footnote
    /// already said so; the default action, its mode settings and the
    /// profile stay editable while AI is off because product decision #6
    /// promises the choice is remembered (KNOWN_ISSUES, wave 3).
    private let availability: SettingsAvailabilityModel

    @State private var configurationSheet: ConfigurationSheetTarget?
    @State private var configurationDraft = AISettingsViewModel.Draft()
    @State private var configurationPendingDeletion: AIConfiguration?

    @State private var editing: ActionEditorTarget?
    @State private var actionDraft = PromptModeDraft()
    @State private var actionPendingDeletion: PromptMode?
    @State private var isConfirmingResetAll = false
    @State private var isShortcutsExpanded = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum ConfigurationSheetTarget: Identifiable {
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

    private enum ActionEditorTarget: Identifiable {
        case new
        case existing(UUID)

        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let id): return id.uuidString
            }
        }
    }

    public init(
        configurations: AISettingsViewModel = .init(),
        actions: PromptModeSettingsViewModel = .init(),
        availability: SettingsAvailabilityModel = .init()
    ) {
        self.configurations = configurations
        self.actions = actions
        self.availability = availability
    }

    public var body: some View {
        Form {
            enableSection
            configurationsSection
            defaultActionSection
            modeSettingsSection
            selectionActionSection
            userProfileSection
            triggersSection
            shortcutsSection
        }
        .formStyle(.grouped)
        // Sizing belongs to the host window, not the section content.
        .navigationTitle("AI Actions")
        .animation(reduceMotion ? nil : .default, value: actions.modes)
        .onSubmit { flush() }
        .onDisappear { flush() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            flush()
        }
        // The draft rule (ADR-022 slice 7): a change from another door (an
        // Import, Restore Previous Settings) replaces the draft rather than
        // being silently overwritten by it at the next flush. Watches the
        // raw stored value, not `actions.settings` — that already overlays
        // the draft, so watching it would never fire (`discardStaleDrafts()`
        // on the model is the seam that actually protects a commit; this is
        // only what keeps the on-screen field in step while the page is open).
        .onChange(of: actions.host.settings.ai.userProfile) { _, newValue in
            actions.userProfile = newValue
        }
        .sheet(item: $configurationSheet) { target in
            AIConfigurationSheet(
                viewModel: configurations,
                draft: $configurationDraft,
                editingID: target.editingID,
                availability: availability,
                onDismiss: { configurationSheet = nil }
            )
        }
        .sheet(item: $editing) { target in
            AIActionEditorView(
                viewModel: actions,
                draft: $actionDraft,
                isBuiltIn: isBuiltIn(target),
                availability: availability,
                onSave: { saveAction(target) },
                onCancel: {
                    actions.clearPreview()
                    editing = nil
                }
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
                configurations.deleteConfiguration(id: configuration.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its saved API key is removed with it. Your other configurations and your actions are kept.")
        }
        .confirmationDialog(
            "Delete “\(actionPendingDeletion?.menuTitle ?? "")”?",
            isPresented: Binding(
                get: { actionPendingDeletion != nil },
                set: { if !$0 { actionPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: actionPendingDeletion
        ) { action in
            Button("Delete Action", role: .destructive) {
                actions.deleteMode(id: action.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its instructions are removed and cannot be restored. Built-in actions, your other actions, and your AI configurations are kept.")
        }
        .confirmationDialog(
            "Reset all built-in actions?",
            isPresented: $isConfirmingResetAll,
            titleVisibility: .visible
        ) {
            Button("Reset Built-in Actions", role: .destructive) {
                actions.resetAllBuiltIns()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every built-in action goes back to its shipped title, instructions, and trigger words, and any that was missing is added. Your own actions, mode settings, and configurations are kept.")
        }
    }

    private func flush() {
        // `configurations`' drafts (the endpoint fields) are never bound in
        // this form — they are only ever written by `selectConfiguration` /
        // `addConfiguration` / `updateConfiguration` /
        // `updateActiveConfigurationFromFields`, each of which commits
        // itself — so there is nothing here for `configurations
        // .flushPendingChanges()` to flush; calling it anyway used to risk
        // committing whatever those drafts happened to hold (see
        // `AISettingsViewModel.discardStaleDrafts()` for why that is now
        // safe even so — this omission is belt and suspenders).
        actions.flushPendingChanges()
    }

    // MARK: Enable

    private var enableSection: some View {
        Section {
            Toggle("Enable AI Actions", isOn: $actions.isEnabled)
                .accessibilityHint("When on, the default action runs after each transcription.")

            if !actions.canEnableProcessing {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add an AI configuration to get started.")
                            .font(.callout.weight(.medium))
                        Text("AI Actions need an endpoint and a model, or Apple Intelligence on this Mac. Nothing runs until one is configured and set as active.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Add Configuration…") { presentNewConfiguration() }
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            } else if let active = actions.activeMode {
                Text(actions.isEnabled
                    ? "Only one action is active at a time. It auto-applies after each transcription while AI Actions is on. Current: \(active.icon) \(active.menuTitle)."
                    : "AI Actions is off. The default action (\(active.icon) \(active.menuTitle)) is remembered for when it is turned on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Choose a default action below. Nothing runs until one is selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("AI Actions")
        } footer: {
            // Both models write the same `AIEndpointSettings` block through
            // one `.setAI` each, gated the same way — whichever one just
            // attempted a send carries the note.
            SettingsFooter(note: configurations.refusalNote ?? actions.refusalNote) {
                Text("Use AI to enhance, translate, or transform your transcriptions. Only the transcript — and any context an action opts into — is sent to your configured endpoint; audio, history, and target-app data stay local.")
            }
        }
    }

    // MARK: Configurations

    private func presentNewConfiguration() {
        configurationDraft = AISettingsViewModel.Draft()
        configurationSheet = .new
    }

    private func presentEdit(_ configuration: AIConfiguration) {
        configurationDraft = AISettingsViewModel.Draft(
            configuration: configuration,
            apiKey: configurations.apiKey(for: configuration.id)
        )
        configurationSheet = .existing(configuration.id)
    }

    private var configurationsSection: some View {
        Section {
            if configurations.configurations.isEmpty {
                Text("No AI configurations yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(configurations.configurations) { configuration in
                    configurationRow(configuration)
                }
            }

            // Add and Test share a line when there is room; a long failure
            // message drops the test control under the button instead of
            // squeezing it.
            ViewThatFits(in: .horizontal) {
                HStack {
                    addConfigurationButton
                    Spacer()
                    testConfigurationControl
                }
                VStack(alignment: .leading, spacing: 8) {
                    addConfigurationButton
                    testConfigurationControl
                }
            }
        } header: {
            Text("AI Configurations")
        } footer: {
            Text("Each configuration stores a provider, endpoint, model, and its own key — or uses an Apple model with none of those: on this Mac, or on Apple's Private Cloud Compute. The active one is used by every action; switch from here or the menu bar.")
        }
    }

    private var addConfigurationButton: some View {
        Button("Add Configuration…") { presentNewConfiguration() }
            .accessibilityHint("Choose a provider and name a new AI configuration.")
    }

    private func configurationRow(_ configuration: AIConfiguration) -> some View {
        let isActive = configuration.id == configurations.activeConfigurationID
        // Name and buttons on one line when there is room; the buttons move
        // under the name when the pane is narrow, so a long model ID never
        // pushes them out of view.
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
        .accessibilityLabel(isActive ? String(localized: "\(configuration.menuTitle), active", bundle: .module) : configuration.menuTitle)
    }

    private func configurationIdentity(_ configuration: AIConfiguration, isActive: Bool) -> some View {
        HStack {
            Image(systemName: isActive ? "largecircle.filled.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.menuTitle)
                Text(configurationSubtitle(configuration))
                    .font(.caption)
                    .foregroundStyle(subtitleNeedsAttention(configuration) ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Provider and model for an endpoint; for the on-device kind (ADR-024)
    /// the availability the environment last observed — the reason while
    /// unavailable, otherwise that it runs here; for Private Cloud Compute
    /// (ADR-027) the reason, else the quota line, else that it runs on
    /// Apple's servers.
    private func configurationSubtitle(_ configuration: AIConfiguration) -> String {
        switch configuration.kind.transport {
        case .appleIntelligence:
            return unavailableReason(configuration)
                ?? String(localized: "Apple Intelligence · runs on this Mac", bundle: .module)
        case .privateCloudCompute:
            return unavailableReason(configuration)
                ?? availability.privateCloudComputeQuotaLine
                ?? String(localized: "Apple Intelligence · runs on Private Cloud Compute (sends the transcript to Apple)", bundle: .module)
        case .openAICompatible:
            return DomainCopy.localized(configuration.kind.displayName)
                + (configuration.modelID.isEmpty ? "" : " · \(configuration.modelID)")
        }
    }

    private func subtitleNeedsAttention(_ configuration: AIConfiguration) -> Bool {
        if unavailableReason(configuration) != nil { return true }
        return configuration.kind.transport == .privateCloudCompute
            && availability.privateCloudComputeQuotaLine != nil
    }

    /// The Apple rows' reason (`.aiAppleIntelligenceConfiguration`,
    /// `.aiPrivateCloudComputeConfiguration`); nil for an endpoint.
    private func unavailableReason(_ configuration: AIConfiguration) -> String? {
        switch configuration.kind.transport {
        case .appleIntelligence:
            return availability.disabledReason(.aiAppleIntelligenceConfiguration)
        case .privateCloudCompute:
            return availability.disabledReason(.aiPrivateCloudComputeConfiguration)
        case .openAICompatible:
            return nil
        }
    }

    @ViewBuilder
    private func configurationButtons(_ configuration: AIConfiguration, isActive: Bool) -> some View {
        if !isActive {
            Button("Set as Active") { configurations.selectConfiguration(id: configuration.id) }
                .disabled(unavailableReason(configuration) != nil)
                .help(Text(verbatim: unavailableReason(configuration) ?? String()))
                .accessibilityLabel("Set \(configuration.menuTitle) as active")
        }
        // ADR-027: Apple's own "raise your limit" UI, only when offered.
        if configuration.kind.transport == .privateCloudCompute,
           availability.privateCloudComputeQuota?.canRequestIncrease == true,
           availability.privateCloudComputeQuotaLine != nil {
            Button("Show Options…") { AIActionsHooks.showPrivateCloudComputeQuotaOptions() }
                .help("Apple's options for a higher Private Cloud Compute limit.")
        }
        Button("Edit") { presentEdit(configuration) }
            .accessibilityLabel("Edit \(configuration.menuTitle)")
        Button(role: .destructive) {
            configurationPendingDeletion = configuration
        } label: {
            Image(systemName: "trash")
        }
        .help("Delete \(configuration.menuTitle)")
        .accessibilityLabel("Delete \(configuration.menuTitle)")
    }

    @ViewBuilder
    private var testConfigurationControl: some View {
        HStack(spacing: 8) {
            Button("Test Active Configuration") {
                configurations.flushPendingChanges()
                Task { await configurations.testConfiguration() }
            }
            .disabled(!configurations.canTestConfiguration || configurations.testState == .testing)
            .accessibilityHint("Sends one harmless test request. It is never sent automatically during dictation.")

            switch configurations.testState {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView().controlSize(.small).accessibilityHidden(true)
            case .succeeded:
                StatusLabel(String(localized: "Works", bundle: .module), symbol: "checkmark.circle.fill", tone: .positive)
                    .labelStyle(.titleAndIcon)
            case .failed(let message):
                StatusLabel(message, symbol: "exclamationmark.triangle.fill", tone: .attention)
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(reduceMotion ? nil : .default, value: configurations.testState)
    }

    // MARK: Default action

    private var defaultActionSection: some View {
        Section {
            AIActionGrid(
                actions: actions.modes,
                defaultID: actions.activeModeID,
                badge: { actions.shortcutBadge(for: $0.id) },
                onSelect: { actions.selectMode(id: $0.id) },
                onEdit: { presentEdit($0) },
                onDuplicate: { actions.duplicateMode(id: $0.id) },
                onDelete: { actionPendingDeletion = $0 },
                onReset: { actions.resetBuiltIn(id: $0.id) }
            )

            ViewThatFits(in: .horizontal) {
                HStack {
                    addActionButton
                    Spacer()
                    resetBuiltInActionsButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    addActionButton
                    resetBuiltInActionsButton
                }
            }
        } header: {
            Text("Default Action")
        } footer: {
            Text("Click to set the default; double-click to edit; right-click for more. Built-in actions can be edited but not deleted. Reset anytime to restore the original text and trigger words.")
        }
    }

    private var addActionButton: some View {
        Button("Add Action…") {
            actionDraft = PromptModeDraft()
            editing = .new
        }
    }

    private var resetBuiltInActionsButton: some View {
        Button("Reset Built-in Actions…") { isConfirmingResetAll = true }
            .accessibilityHint("Restores every shipped action's text and trigger words and adds back any that is missing.")
    }

    private func presentEdit(_ action: PromptMode) {
        actionDraft = PromptModeDraft(mode: action)
        actions.clearPreview()
        editing = .existing(action.id)
    }

    private func isBuiltIn(_ target: ActionEditorTarget) -> Bool {
        switch target {
        case .new:
            return false
        case .existing(let id):
            return actions.modes.first { $0.id == id }?.isBuiltIn ?? false
        }
    }

    private func saveAction(_ target: ActionEditorTarget) {
        switch target {
        case .new:
            _ = actions.addMode(actionDraft)
        case .existing(let id):
            actions.updateMode(id: id, from: actionDraft)
        }
        actions.clearPreview()
        editing = nil
    }

    // MARK: Mode settings

    @ViewBuilder
    private var modeSettingsSection: some View {
        if let action = actions.activeMode {
            Section {
                AIActionModeSettingsView(action: action) { options in
                    actions.updateOptions(id: action.id, options)
                }
            } header: {
                Text("Mode Settings · \(action.menuTitle)")
            } footer: {
                Text("Settings for the default action. Each one appends a shipped instruction block; the action's own text is untouched.")
            }
        }
    }

    // MARK: Selection action

    private var selectionActionSection: some View {
        Section {
            ForEach(0..<AIEndpointSettings.selectionActionSlotCount, id: \.self) { slot in
                selectionSlotRow(slot)
            }
            // On the rows, not the Section: the footer's link must stay live.
            .disabled(!availability.isEnabled(.selectionAction))
        } header: {
            Text("Selection Action")
        } footer: {
            // ADR-026: the App Store edition cannot read another app's
            // selection; the reason replaces the description, with the
            // pointer to the full edition under it.
            if let reason = availability.disabledReason(.selectionAction) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reason)
                    FullEditionLink(url: availability.fullEditionLink)
                }
            } else {
                Text("Select text in any app, press a slot's shortcut, and KVoice runs that action on the selection and inserts the result in its place through Accessibility — never a simulated paste. Experimental.")
            }
        }
    }

    private func selectionSlotRow(_ slot: Int) -> some View {
        // Picker and recorder side by side when there is room; the recorder
        // drops under the picker in a narrow pane.
        ViewThatFits(in: .horizontal) {
            HStack {
                selectionSlotPicker(slot)
                Spacer()
                AIActionsHooks.selectionActionShortcutRecorder(slot)
            }
            VStack(alignment: .leading, spacing: 6) {
                selectionSlotPicker(slot)
                AIActionsHooks.selectionActionShortcutRecorder(slot)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(AIActionsHooks.selectionActionShortcutDescription(slot) ?? String(localized: "No shortcut", bundle: .module))
    }

    private func selectionSlotPicker(_ slot: Int) -> some View {
        Picker(
            "Slot \(slot + 1)",
            selection: Binding(
                get: { actions.selectionActionSlots[slot] },
                set: { actions.bindSelectionAction($0, slot: slot) }
            )
        ) {
            Text("None").tag(UUID?.none)
            ForEach(actions.modes.filter(\.isUsable)) { action in
                Text("\(action.icon) \(action.menuTitle)").tag(UUID?.some(action.id))
            }
        }
        .frame(maxWidth: 320)
    }

    // MARK: User profile

    private var userProfileSection: some View {
        Section {
            TextEditor(text: $actions.userProfile)
                .frame(minHeight: 80)
                .accessibilityLabel("User profile")
            HStack(alignment: .firstTextBaseline) {
                Text("Optional. Name, role, industry, tech stack, communication style, languages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text("\(actions.userProfile.count) / \(AIEndpointSettings.userProfileMaximumCharacters)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } header: {
            Text("User Profile")
        } footer: {
            Text("Included in every AI Action request as a separate <USER_PROFILE> block. Stored in settings, never in the secrets file.")
        }
    }

    // MARK: Triggers

    private var triggersSection: some View {
        Section {
            Toggle("Enable Action Triggers", isOn: $actions.actionTriggersEnabled)
            let triggered = actions.modes.filter { !$0.triggerWords.isEmpty }
            if triggered.isEmpty {
                Text("No action has trigger words yet. Add them in an action's editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(triggered) { action in
                    LabeledContent("\(action.icon) \(action.menuTitle)") {
                        Text(action.triggerWords.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        } header: {
            Text("Action Triggers")
        } footer: {
            // The projection's reason (switch off, or no endpoint) replaces
            // the sentence this footer used to compose itself.
            Text(availability.disabledReason(.aiActionSettings)
                ?? String(localized: "When enabled, a transcript that begins with an action's trigger word runs that action instead of the default. The trigger phrase is removed from the text.", bundle: .module))
        }
        .disabled(!availability.isEnabled(.aiActionSettings))
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        Section {
            DisclosureGroup("AI Action Shortcuts", isExpanded: $isShortcutsExpanded) {
                Text("Switch between your saved actions with ⌘1–⌘0, in the order they are saved. The shortcut works while a dictation is in progress, and on this page when the KVoice window is focused.")
                    .font(.callout)
                let listed = Array(actions.modes.prefix(10))
                ForEach(listed) { action in
                    LabeledContent("\(action.icon) \(action.menuTitle)") {
                        Text(actions.shortcutBadge(for: action.id) ?? "")
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// The per-action Mode Settings card. Which toggles appear depends on the
/// action's family; every change is a button press and commits at once.
@MainActor
struct AIActionModeSettingsView: View {
    let action: PromptMode
    let onChange: (PromptModeOptions) -> Void

    @State private var secondTargetName: String = ""
    @State private var secondTargetCode: String = ""

    var body: some View {
        switch action.settingsFamily {
        case .polish:
            Toggle("Formal Writing Mode", isOn: binding(\.formalWriting))
            Text("Rewrite into formal, concise, polite written style suitable for professional communication.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Professional Mode (High-EQ)", isOn: binding(\.professionalTone))
            Text("Transform into diplomatic, tactful, emotionally intelligent workplace communication.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .translate:
            LabeledContent("Translation target") {
                Text(action.translationLanguage.map { "\($0.displayName) (\($0.bcp47))" } ?? "—")
                    .foregroundStyle(.secondary)
            }
            Text("Change the target language in the action's editor.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(
                "Enable Second Translation",
                isOn: Binding(
                    get: { action.options.secondTranslationLanguage != nil },
                    set: { enabled in
                        var options = action.options
                        options.secondTranslationLanguage = enabled
                            ? TranslationLanguage(bcp47: "zh-Hans", displayName: "Chinese, Simplified")
                            : nil
                        onChange(options)
                    }
                )
            )
            Text("Also produce the translation in a second target language.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let second = action.options.secondTranslationLanguage {
                HStack {
                    TextField("Second target language", text: $secondTargetName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Code", text: $secondTargetCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Button("Apply") {
                        let name = secondTargetName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let code = secondTargetCode.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty, !code.isEmpty else { return }
                        var options = action.options
                        options.secondTranslationLanguage = TranslationLanguage(bcp47: code, displayName: name)
                        onChange(options)
                    }
                    .disabled(secondTargetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || secondTargetCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .onAppear {
                    secondTargetName = second.displayName
                    secondTargetCode = second.bcp47
                }
            }
            Toggle("Show original transcript", isOn: binding(\.showsOriginalTranscript))
            Text("Add the original text below the translation output.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .questionAnswer:
            Toggle("Show question before answer", isOn: binding(\.showsQuestionBeforeAnswer))
            Text("Include the original question above the answer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .none:
            Text("This action has no extra settings. Edit it to change its instructions, trigger words, or context awareness.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<PromptModeOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { action.options[keyPath: keyPath] },
            set: { value in
                var options = action.options
                options[keyPath: keyPath] = value
                onChange(options)
            }
        )
    }
}
