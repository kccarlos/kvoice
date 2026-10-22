import KvoiceDomain
import SwiftUI

/// The body of the "AI Actions" section (hosted by `AIActionsSectionView`).
/// Q3's information architecture (design-v2 `qa/q3-ai-actions-ia.md`), in
/// the order a user asks: (1) is AI on and what will a dictation do — the
/// master switch and its status line; (2) where AI runs — the
/// configurations; (3) which action runs — the grid, the default strip,
/// and one action detail sheet holding everything per action; (4) More —
/// the global settings (trigger words, ⌘1–⌘0, Selection Action, user
/// profile). It replaces the separate AI and Modes tabs.
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
        KVCardPage {
            enableSection
            configurationsSection
            actionsSection
            moreSection
        }
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
                context: detailContext(target),
                onSetDefault: { savedAction(target).map { actions.selectMode(id: $0.id) } },
                onDuplicate: { duplicateFromDetail(target) },
                onReset: { resetFromDetail(target) },
                onDelete: { deleteFromDetail(target) },
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
            "Delete “\(actionPendingDeletion?.displayTitle ?? "")”?",
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

    // MARK: 1 · Use AI Actions

    /// Q3: the headerless top card — the master switch and one status line
    /// saying what a dictation does right now (`AIActionsStatus`: the same
    /// "action · configuration" words as Home's chip, "tested OK" only
    /// after a test). The get-started prompt stays while nothing is set up.
    private var enableSection: some View {
        let status = AIActionsStatus(
            settings: actions.settings,
            configurationName: .some(configurations.configurations.first { $0.id == configurations.activeConfigurationID }?.menuTitle),
            test: configurations.testState
        )
        return KVCardSection {
            Toggle(isOn: $actions.isEnabled) {
                Text("Use AI Actions", bundle: .module)
                Text(verbatim: status.line)
                    .foregroundStyle(status.tone == .attention ? Color.kv.warnInk : Color.kv.text2)
            }
            .accessibilityHint("When on, the default action runs after each transcription.")

            if !actions.canEnableProcessing {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.kv.cursorInk)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add an AI configuration to get started.")
                            .font(.system(size: 13, weight: .semibold))
                        Text("AI Actions need an endpoint and a model, or Apple Intelligence on this Mac. Nothing runs until one is configured and set as active.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.kv.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Add Configuration…") { presentNewConfiguration() }
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        } footer: {
            // Both models write the same `AIEndpointSettings` block through
            // one `.setAI` each, gated the same way — whichever one just
            // attempted a send carries the note.
            if let note = configurations.refusalNote ?? actions.refusalNote {
                Text(verbatim: note)
            }
        }
    }
    // MARK: 2 · Where AI runs

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

    /// Window.dc "Where AI runs": radio rows (name, sub-line, This Mac /
    /// Cloud chip, Edit) and a footer row with Add Configuration… and Test
    /// Active, the test's result at the header's right.
    private var configurationsSection: some View {
        KVBlockSection(padding: nil) {
            VStack(alignment: .leading, spacing: 0) {
                if configurations.configurations.isEmpty {
                    Text("No AI configurations yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.kv.text2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(configurations.configurations.enumerated()), id: \.element.id) { index, configuration in
                        if index > 0 { KVRowDivider() }
                        AIConfigurationRow(
                            configuration: configuration,
                            isActive: configuration.id == configurations.activeConfigurationID,
                            subtitle: configurationSubtitle(configuration),
                            subtitleNeedsAttention: subtitleNeedsAttention(configuration),
                            unavailableReason: unavailableReason(configuration),
                            showsQuotaOptions: configuration.kind.transport == .privateCloudCompute
                                && availability.privateCloudComputeQuota?.canRequestIncrease == true
                                && availability.privateCloudComputeQuotaLine != nil,
                            onSelect: { configurations.selectConfiguration(id: configuration.id) },
                            onEdit: { presentEdit(configuration) },
                            onDelete: { configurationPendingDeletion = configuration }
                        )
                    }
                }
                KVRowDivider()
                HStack(spacing: 8) {
                    addConfigurationButton
                    Spacer(minLength: 8)
                    Button {
                        configurations.flushPendingChanges()
                        Task { await configurations.testConfiguration() }
                    } label: {
                        Text("Test Active", bundle: .module)
                    }
                    .buttonStyle(KVButtonStyle(.standard, height: 26))
                    .disabled(!configurations.canTestConfiguration || configurations.testState == .testing)
                    .accessibilityHint("Sends one harmless test request. It is never sent automatically during dictation.")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if case .failed(let message) = configurations.testState {
                    StatusLabel(message, symbol: "exclamationmark.triangle.fill", tone: .attention)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }
        } header: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Where AI runs", bundle: .module)
                Spacer(minLength: 8)
                testStatus
            }
        } footer: {
            Text("Each configuration stores a provider, endpoint, model, and its own key — or uses an Apple model with none of those: on this Mac, or on Apple's Private Cloud Compute. The active one is used by every action; switch from here or the menu bar.")
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: configurations.testState)
    }

    /// Window.dc draws "Active configuration works" permanently; it is
    /// shown only after a test of the active configuration succeeded (the
    /// app never checks on its own), and says so when the test failed.
    @ViewBuilder
    private var testStatus: some View {
        switch configurations.testState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Testing…", bundle: .module)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.kv.text2)
        case .succeeded:
            statusDot(Text("Active configuration works", bundle: .module), tone: .ok)
        case .failed:
            statusDot(Text("Active configuration failed", bundle: .module), tone: .err)
        }
    }

    private func statusDot(_ text: Text, tone: KVTone) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tone.solid.color).frame(width: 7, height: 7)
            text
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tone.ink.color)
        .accessibilityElement(children: .combine)
    }

    private var addConfigurationButton: some View {
        Button("Add Configuration…") { presentNewConfiguration() }
            .buttonStyle(KVButtonStyle(.standard, height: 26))
            .accessibilityHint("Choose a provider and name a new AI configuration.")
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

    // MARK: 3 · Actions

    /// Q3: "Actions" over the 4-column grid (Window.dc), the default strip
    /// under it, and the footnote with Reset Built-in Actions…. A click
    /// makes a tile the default (a radio choice, like the panel's chips and
    /// the menu's Default Action); double-click, Return, Edit… or the
    /// strip's Edit… opens the action detail.
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Actions", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.kv.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button("Add Action…") { presentNewAction() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kv.cursorInk)
            }
            .padding(.horizontal, 2)

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

            defaultStrip
                .padding(.top, 4)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Click an action to make it the default. Double-click it, or press Edit…, to open everything it does.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Reset Built-in Actions…") { isConfirmingResetAll = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.kv.cursorInk)
                    .accessibilityHint("Restores every shipped action's text and trigger words and adds back any that is missing.")
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.kv.text2)
            .padding(.horizontal, 2)
        }
    }

    /// The default action at a glance — what runs after each transcription,
    /// its behaviour, mode settings, trigger words and shortcut — and the
    /// visible door to its detail. Says so when none is chosen.
    @ViewBuilder
    private var defaultStrip: some View {
        KVCard {
            if let action = actions.activeMode {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: "\(action.icon.isEmpty ? "" : action.icon + " ")\(action.displayTitle)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.kv.text)
                            Text("Default action", bundle: .module)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.kv.cursorInk)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.kv.cursorSoft, in: Capsule())
                        }
                        Text(verbatim: AIActionFacts.line(for: action, badge: actions.shortcutBadge(for: action.id), triggersOn: actions.actionTriggersEnabled))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.kv.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button {
                        presentEdit(action)
                    } label: {
                        Text("Edit…", bundle: .module)
                    }
                    .buttonStyle(KVButtonStyle(.standard, height: 26))
                    .accessibilityLabel(Text("Edit \(action.displayTitle)", bundle: .module))
                    .accessibilityHint("Opens the action's details: instructions, mode settings, trigger words and shortcut.")
                }
                .accessibilityElement(children: .contain)
            } else {
                Text(actions.modes.isEmpty
                    ? "No actions. Add one, or reset the built-in actions."
                    : "No default action. Click an action above to choose what runs after each transcription.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kv.warnInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func presentNewAction() {
        actionDraft = PromptModeDraft()
        actions.clearPreview()
        editing = .new
    }

    private func presentEdit(_ action: PromptMode) {
        actionDraft = PromptModeDraft(mode: action)
        actions.clearPreview()
        editing = .existing(action.id)
    }

    private func savedAction(_ target: ActionEditorTarget) -> PromptMode? {
        guard case .existing(let id) = target else { return nil }
        return actions.modes.first { $0.id == id }
    }

    private func isBuiltIn(_ target: ActionEditorTarget) -> Bool {
        savedAction(target)?.isBuiltIn ?? false
    }

    private func detailContext(_ target: ActionEditorTarget) -> AIActionDetailContext {
        guard let saved = savedAction(target) else { return AIActionDetailContext() }
        let slots = actions.selectionActionSlots.enumerated().compactMap { slot, id in
            id == saved.id
                ? AIActionDetailContext.SelectionSlotBinding(slot: slot, shortcut: AIActionsHooks.selectionActionShortcutDescription(slot))
                : nil
        }
        return AIActionDetailContext(
            saved: saved,
            isDefault: saved.id == actions.activeModeID,
            shortcutBadge: actions.shortcutBadge(for: saved.id),
            selectionSlots: slots
        )
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

    /// Duplicate from the detail: the copy opens in its place.
    private func duplicateFromDetail(_ target: ActionEditorTarget) {
        guard let saved = savedAction(target), let copy = actions.duplicateMode(id: saved.id) else { return }
        actions.clearPreview()
        actionDraft = PromptModeDraft(mode: copy)
        editing = .existing(copy.id)
    }

    /// Reset from the detail commits at once and reloads the draft, so a
    /// later Save cannot write the old text back.
    private func resetFromDetail(_ target: ActionEditorTarget) {
        guard let saved = savedAction(target) else { return }
        actions.resetBuiltIn(id: saved.id)
        if let reset = actions.modes.first(where: { $0.id == saved.id }) {
            actionDraft = PromptModeDraft(mode: reset)
        }
    }

    private func deleteFromDetail(_ target: ActionEditorTarget) {
        guard let saved = savedAction(target) else { return }
        actions.clearPreview()
        editing = nil
        actions.deleteMode(id: saved.id)
    }

    // MARK: 4 · More

    /// Q3: every global AI setting in one card, each row with its one-line
    /// explanation — trigger words, the ⌘1–⌘0 switch, the Selection Action
    /// slots, the user profile. Per-action settings live in the detail.
    private var moreSection: some View {
        KVCardSection {
            triggersRow
            shortcutsRow
            selectionActionRow
            userProfileRow
        } header: {
            Text("More", bundle: .module)
        }
    }

    private func rowTitle(_ title: LocalizedStringKey, _ detail: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title, bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.kv.text)
            detail
                .font(.system(size: 11))
                .foregroundStyle(Color.kv.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var triggersRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The switch's name is only "Trigger words": the sentence is a
            // caption and the VoiceOver hint, so the name stays short.
            let explanation = availability.disabledReason(.aiActionSettings)
                ?? String(localized: "When on, a dictation that begins with an action's trigger word runs that action instead of the default; the trigger word is removed from the text.", bundle: .module)
            Toggle(isOn: $actions.actionTriggersEnabled) {
                Text("Trigger words", bundle: .module)
            }
            .accessibilityHint(Text(verbatim: explanation))
            Text(verbatim: explanation)
                .font(.system(size: 11))
                .foregroundStyle(Color.kv.text2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            let triggered = actions.modes.filter { !$0.triggerWords.isEmpty }
            if triggered.isEmpty {
                Text("No action has trigger words yet. Add them in an action's details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(triggered) { action in
                    LabeledContent("\(action.icon) \(action.displayTitle)") {
                        Text(action.triggerWords.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .disabled(!availability.isEnabled(.aiActionSettings))
    }

    private var shortcutsRow: some View {
        DisclosureGroup(isExpanded: $isShortcutsExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(actions.modes.prefix(10))) { action in
                    LabeledContent("\(action.icon) \(action.displayTitle)") {
                        Text(actions.shortcutBadge(for: action.id) ?? "")
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            rowTitle("Action shortcuts ⌘1–⌘0", Text("Switch between your actions by their place in the grid. Works while a dictation is in progress, and on this page when the KVoice window is focused.", bundle: .module))
        }
    }

    private var selectionActionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ADR-026: the App Store edition cannot read another app's
            // selection; the reason replaces the description, with the
            // pointer to the full edition under it.
            if let reason = availability.disabledReason(.selectionAction) {
                rowTitle("Selection Action", Text(verbatim: reason))
                FullEditionLink(url: availability.fullEditionLink)
                    .font(.system(size: 11))
            } else {
                rowTitle("Selection Action", Text("Select text in any app, press a slot's shortcut, and KVoice runs that action on the selection and inserts the result in its place through Accessibility — never a simulated paste. Experimental.", bundle: .module))
            }
            Group {
                ForEach(0..<AIEndpointSettings.selectionActionSlotCount, id: \.self) { slot in
                    selectionSlotRow(slot)
                }
            }
            // On the rows, not the title: the full-edition link stays live.
            .disabled(!availability.isEnabled(.selectionAction))
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
                Text("\(action.icon) \(action.displayTitle)").tag(UUID?.some(action.id))
            }
        }
        .frame(maxWidth: 320)
    }

    private var userProfileRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            rowTitle("User profile", Text("Optional. Name, role, industry, tech stack, communication style, languages. Sent with every AI Action request as a separate <USER_PROFILE> block; stored in settings, never in the secrets file.", bundle: .module))
            TextEditor(text: $actions.userProfile)
                .font(.system(size: 12))
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color.kv.bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.kv.line))
                .accessibilityLabel("User profile")
            HStack {
                Spacer()
                Text("\(actions.userProfile.count) / \(AIEndpointSettings.userProfileMaximumCharacters)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

/// An action's mode settings (Q3: in the action detail, on the draft, saved
/// by its Save). Which toggles appear depends on the action's family.
@MainActor
struct AIActionModeSettingsView: View {
    let family: PromptModeSettingsFamily
    /// The draft's target language, shown for a Translate action.
    let translationLanguage: TranslationLanguage?
    @Binding var options: PromptModeOptions

    var body: some View {
        switch family {
        case .polish:
            Toggle("Formal Writing Mode", isOn: $options.formalWriting)
            Text("Rewrite into formal, concise, polite written style suitable for professional communication.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Professional Mode (High-EQ)", isOn: $options.professionalTone)
            Text("Transform into diplomatic, tactful, emotionally intelligent workplace communication.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .translate:
            LabeledContent("Translation target") {
                Text(translationLanguage.map { "\($0.displayName) (\($0.bcp47))" } ?? "—")
                    .foregroundStyle(.secondary)
            }
            Toggle(
                "Enable Second Translation",
                isOn: Binding(
                    get: { options.secondTranslationLanguage != nil },
                    set: { enabled in
                        options.secondTranslationLanguage = enabled
                            ? TranslationLanguage(bcp47: "zh-Hans", displayName: "Chinese, Simplified")
                            : nil
                    }
                )
            )
            Text("Also produce the translation in a second target language.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let second = options.secondTranslationLanguage {
                HStack {
                    TextField("Second target language", text: Binding(
                        get: { second.displayName },
                        set: { options.secondTranslationLanguage = TranslationLanguage(bcp47: second.bcp47, displayName: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    TextField("Code", text: Binding(
                        get: { second.bcp47 },
                        set: { options.secondTranslationLanguage = TranslationLanguage(bcp47: $0, displayName: second.displayName) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                }
            }
            Toggle("Show original transcript", isOn: $options.showsOriginalTranscript)
            Text("Add the original text below the translation output.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .questionAnswer:
            Toggle("Show question before answer", isOn: $options.showsQuestionBeforeAnswer)
            Text("Include the original question above the answer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .none:
            EmptyView()
        }
    }
}
