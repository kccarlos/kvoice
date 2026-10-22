import KvoiceDomain
import SwiftUI

/// What the action detail knows about the saved action it edits (Q3). The
/// default value describes a new action: no default badge, no shortcut, no
/// Set as Default / Duplicate / Reset / Delete.
struct AIActionDetailContext {
    /// The action as saved; nil while adding a new one.
    var saved: PromptMode?
    var isDefault = false
    /// "⌘2", by the action's place in the grid; nil past the tenth.
    var shortcutBadge: String?
    /// The Selection Action slots (0-based) this action is bound to, each
    /// with its shortcut's description when one is recorded.
    var selectionSlots: [SelectionSlotBinding] = []

    struct SelectionSlotBinding: Hashable {
        let slot: Int
        let shortcut: String?
    }

    var isNew: Bool { saved == nil }
    var canSetDefault: Bool { saved?.isUsable == true && !isDefault }
    var canReset: Bool { saved?.isRevisedBuiltIn == true }
    var canDelete: Bool { saved.map { !$0.isBuiltIn } ?? false }

    /// The detail's buttons that act on the saved action at once rather
    /// than through Save. Duplicate is offered only without unsaved edits,
    /// so a copy never silently drops them.
    func canDuplicate(draft: PromptModeDraft) -> Bool {
        guard let saved else { return false }
        return draft == PromptModeDraft(mode: saved)
    }
}

/// The action detail sheet (Q3): everything that belongs to one action in
/// one place — name, icon and description, behaviour and target language,
/// its mode settings, instructions, trigger words, its shortcut, context
/// awareness, and a collapsible Test Prompt box that runs a sample through
/// the live endpoint. A draft: Save commits it, Cancel abandons it. Set as
/// Default, Duplicate, Reset to Shipped Text and Delete act on the saved action
/// at once and say so by being buttons, not fields.
@MainActor
struct AIActionEditorView: View {
    @Bindable var viewModel: PromptModeSettingsViewModel
    @Binding var draft: PromptModeDraft
    let isBuiltIn: Bool
    /// ADR-026: the edition's refusal for the selected-text context and the
    /// pointer to the full edition. The default (everything enabled) is what
    /// the Actions tab, previews and the gallery see.
    var availability: SettingsAvailabilityModel = .init()
    var context = AIActionDetailContext()
    var onSetDefault: () -> Void = {}
    var onDuplicate: () -> Void = {}
    var onReset: () -> Void = {}
    var onDelete: () -> Void = {}
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var isConfirmingDelete = false
    @State private var isTestExpanded = false
    @State private var isTemplatePreviewExpanded = false
    @State private var newTriggerWord = ""

    var body: some View {
        Form {
            headerSection
            identitySection
            modeSettingsSection
            instructionsSection
            triggerSection
            shortcutSection
            contextSection
            testSection
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            // See SheetButtonBar: a sheet has no toolbar, and Return/Escape
            // need explicit shortcuts.
            SheetButtonBar(
                confirmTitle: "Save",
                isConfirmEnabled: draft.isComplete,
                disabledReason: draft.hasCompleteSecondLanguage
                    ? String(localized: "Give the action a title and instructions.", bundle: .module)
                    : String(localized: "Give the second translation a language and a code.", bundle: .module),
                onCancel: onCancel,
                onConfirm: onSave
            ) {
                if !context.isNew { savedActionButtons }
            }
        }
        .confirmationDialog(
            "Delete “\(context.saved?.menuTitle ?? "")”?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Action", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its instructions are removed and cannot be restored. Built-in actions, your other actions, and your AI configurations are kept.")
        }
        // The ideal is the old fixed minimum; the minimum is what fits over
        // the main window at its 820×540 floor. The grouped form scrolls, so
        // a shorter sheet loses nothing.
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 680)
    }

    // MARK: Header

    /// The action's emoji and title as the grid shows them, and whether it
    /// is the default — the one state the page marks in blue.
    private var headerSection: some View {
        Section {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(context.isDefault ? Color.kv.cursor : Color.kv.grey)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Text(verbatim: draft.icon.isEmpty ? "✨" : draft.icon).font(.system(size: 15))
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: draft.name.isEmpty ? String(localized: "New Action", bundle: .module) : draft.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(statusLine)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kv.text2)
                }
                Spacer(minLength: 8)
                if context.isDefault {
                    Text("Default action", bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.kv.cursorInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.kv.cursorSoft, in: Capsule())
                } else if !context.isNew {
                    Button("Set as Default", action: onSetDefault)
                        .disabled(!context.canSetDefault)
                        .help(Text("Makes this the action that runs after each transcription. Saved at once.", bundle: .module))
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var statusLine: String {
        if context.isNew { return String(localized: "New action — saved when you press Save", bundle: .module) }
        if context.isDefault {
            return String(localized: "Runs after each transcription while AI Actions are on", bundle: .module)
        }
        return String(localized: "Runs when chosen: click it on the page, pick it in the menu bar, say a trigger word, or press its shortcut", bundle: .module)
    }

    @ViewBuilder
    private var savedActionButtons: some View {
        Button("Duplicate", action: onDuplicate)
            .disabled(!context.canDuplicate(draft: draft))
            .help(context.canDuplicate(draft: draft)
                ? Text("Adds an editable copy without trigger words and opens it.", bundle: .module)
                : Text("Save or cancel your changes first.", bundle: .module))
        if context.saved?.isBuiltIn == true {
            Button("Reset to Shipped Text", action: onReset)
                .disabled(!context.canReset)
                .help(Text("Restores the shipped title, instructions and trigger words. Saved at once.", bundle: .module))
        }
        if context.canDelete {
            Button("Delete…", role: .destructive) { isConfirmingDelete = true }
        }
    }

    // MARK: Mode settings

    @ViewBuilder
    private var modeSettingsSection: some View {
        let family = draft.settingsFamily
        if family != .none {
            Section {
                AIActionModeSettingsView(
                    family: family,
                    translationLanguage: draft.behavior == .translate ? draft.translationLanguage : nil,
                    options: $draft.options
                )
            } header: {
                Text("Mode Settings")
            } footer: {
                Text("Each setting appends a shipped instruction block; the instructions below are untouched.")
            }
        }
    }

    // MARK: Shortcut

    private var shortcutSection: some View {
        Section {
            LabeledContent("Switch shortcut") {
                Text(verbatim: context.shortcutBadge ?? "—")
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            Text(context.isNew
                ? "A new action gets the next free ⌘1–⌘0 number, by its place in the grid."
                : "Set by the action's place in the grid (⌘1–⌘0). Switches to this action while you dictate, and on the AI Actions page.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if context.selectionSlots.isEmpty {
                LabeledContent("Selection Action") {
                    Text("Not on a slot", bundle: .module).foregroundStyle(.secondary)
                }
            } else {
                ForEach(context.selectionSlots, id: \.slot) { binding in
                    LabeledContent("Selection Action") {
                        Text(verbatim: binding.shortcut.map {
                            String(localized: "Slot \(binding.slot + 1) · \($0)", bundle: .module)
                        } ?? String(localized: "Slot \(binding.slot + 1) · no shortcut", bundle: .module))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Shortcut")
        } footer: {
            Text("Selection Action slots and their shortcuts are set under More on the AI Actions page.")
        }
    }

    // MARK: Action

    private var identitySection: some View {
        Section {
            // Two rows, not one HStack sharing a single Form row: packing
            // the icon and title fields into one HStack made the Form
            // compute a single shared label column for both at once, which
            // wrapped "Icon" to "Ico n", squeezed the icon field to a
            // sliver, and left Title's field starting at a different x than
            // Description's below it. LabeledContent gives each its own
            // row, same as every other row in this sheet.
            LabeledContent("Icon") {
                TextField("", text: $draft.icon)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
                    .multilineTextAlignment(.center)
                    .onChange(of: draft.icon) { _, value in
                        let single = PromptModeDraft.singleGrapheme(value)
                        if single != value { draft.icon = single }
                    }
                    .accessibilityLabel("Icon")
                    .help("One emoji. Tip: ⌃⌘Space opens the emoji picker.")
            }
            LabeledContent("Title") {
                TextField("", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Action title")
                    .help("Shown in the grid and the menu bar, so make it recognisable.")
            }

            TextField("Description", text: $draft.summary)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Action description")
                .help("A brief description of what this action does.")

            Picker("Behavior", selection: $draft.behavior) {
                Text("Edit transcript").tag(AIMode.polish)
                Text("Translate").tag(AIMode.translate)
            }
            .accessibilityHint("Translate consolidates mixed languages; editing preserves them.")

            if draft.behavior == .translate {
                TextField(
                    "Target language",
                    text: Binding(
                        get: { draft.translationLanguage.displayName },
                        set: { newValue in
                            draft.translationLanguage = TranslationLanguage(
                                bcp47: draft.translationLanguage.bcp47,
                                displayName: newValue
                            )
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)

                TextField(
                    "Language code (BCP 47)",
                    text: Binding(
                        get: { draft.translationLanguage.bcp47 },
                        set: { newValue in
                            draft.translationLanguage = TranslationLanguage(
                                bcp47: newValue,
                                displayName: draft.translationLanguage.displayName
                            )
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)

                Text("Use {targetLanguageDisplayName} and {targetLanguageBCP47} in the instructions to refer to these.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isBuiltIn {
                Text("This is a built-in action. It can be edited but not deleted; Reset brings back the shipped text and trigger words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Action")
        }
    }

    private var instructionsSection: some View {
        Section {
            TextEditor(text: $draft.prompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .accessibilityLabel("Instructions")

            if !isBuiltIn, draft.prompt.isEmpty {
                Menu("Start with a Predefined Template") {
                    ForEach(BuiltInPromptModes.all) { template in
                        Button("\(template.icon) \(template.name)") {
                            let keptName = draft.name
                            draft = PromptModeDraft(basedOn: template, name: keptName)
                        }
                    }
                }
            }

            Toggle("Use System Instructions", isOn: $draft.usesSystemInstructionsTemplate)
                .accessibilityHint("Combines your instructions with the shipped safety and output template.")
            Text(draft.usesSystemInstructionsTemplate
                ? "Your instructions are combined with a general-purpose template that keeps the transcript as data, forbids commentary, and names the input tags."
                : "Your instructions are sent verbatim as the whole system prompt. Full control, for advanced users.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if draft.usesSystemInstructionsTemplate {
                DisclosureGroup("Show the prompt that will be sent", isExpanded: $isTemplatePreviewExpanded) {
                    Text(draft.effectiveSystemPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        } header: {
            Text("Instructions")
        } footer: {
            Text("The transcript is supplied separately, wrapped in <TRANSCRIPT> tags. Instruct the model to treat it as data, not instructions.")
        }
    }

    private var triggerSection: some View {
        Section {
            if draft.triggerWords.isEmpty {
                Text("No trigger words. Add one to let a dictation that begins with it pick this action automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(draft.triggerWords, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button {
                            draft.triggerWords.removeAll { $0 == word }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove trigger word \(word)")
                    }
                }
            }
            HStack {
                TextField("Add trigger word", text: $newTriggerWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTriggerWord)
                    .accessibilityLabel("New trigger word")
                Button("Add", action: addTriggerWord)
                    .disabled(newTriggerWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Trigger Words")
        } footer: {
            Text(viewModel.actionTriggersEnabled
                ? "When a transcript begins with one of these, this action runs instead of the default and the trigger phrase is removed."
                : "Action triggers are off in the AI Actions section, so these are inactive until you turn them on.")
        }
    }

    private func addTriggerWord() {
        let candidate = newTriggerWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        draft.triggerWords = PromptMode.normalizedTriggerWords(draft.triggerWords + [candidate])
        newTriggerWord = ""
    }

    private var contextSection: some View {
        Section {
            Toggle("Include clipboard text", isOn: $draft.includesClipboardText)
                .accessibilityHint("Sends the clipboard's text with each request for this action, in a separate tagged block.")
            // ADR-026 §6(b): held off in the App Store edition, which cannot
            // read another app's selection (a stored "on" from the other
            // edition is kept and ignored).
            Toggle(
                "Include selected text",
                isOn: availability.isEnabled(.selectedTextContext) ? $draft.includesSelectedText : .constant(false)
            )
                .disabled(!availability.isEnabled(.selectedTextContext))
                .accessibilityHint("Sends the focused field's selection with each request for this action, in a separate tagged block.")
        } header: {
            Text("Context Awareness")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Off by default. When on, the text is sent to your AI endpoint as reference material for this action only. KVoice never captures the screen.")
                if let reason = availability.disabledReason(.selectedTextContext) {
                    Text(reason)
                    FullEditionLink(url: availability.fullEditionLink)
                }
            }
        }
    }

    private var testSection: some View {
        // Collapsed by default so the editor stays about the instructions.
        Section(isExpanded: $isTestExpanded) {
            Text("Paste text as if it had just been dictated, then run it through these instructions using your active AI configuration.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $viewModel.previewInput)
                .frame(minHeight: 80)
                .accessibilityLabel("Sample text")

            HStack {
                Button("Run Test") {
                    Task { await viewModel.runPreview(using: draft) }
                }
                .disabled(!viewModel.canRunPreview)

                if viewModel.previewState == .running {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if !viewModel.previewOutput.isEmpty {
                    Button("Clear") { viewModel.clearPreview() }
                }
            }

            switch viewModel.previewState {
            case .idle, .running:
                EmptyView()
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            case .succeeded:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Result")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(viewModel.previewOutput)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        } header: {
            Text("Test Prompt")
        }
    }
}
