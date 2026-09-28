import KvoiceDomain
import SwiftUI

/// The action editor sheet: title, description, icon, instructions, the
/// system-instructions template toggle, trigger words, context awareness, and
/// a collapsible Test Prompt box that runs a sample through the live endpoint.
@MainActor
struct AIActionEditorView: View {
    @Bindable var viewModel: PromptModeSettingsViewModel
    @Binding var draft: PromptModeDraft
    let isBuiltIn: Bool
    /// ADR-026: the edition's refusal for the selected-text context and the
    /// pointer to the full edition. The default (everything enabled) is what
    /// the Actions tab, previews and the gallery see.
    var availability: SettingsAvailabilityModel = .init()
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var isTestExpanded = false
    @State private var isTemplatePreviewExpanded = false
    @State private var newTriggerWord = ""

    var body: some View {
        Form {
            identitySection
            instructionsSection
            triggerSection
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
                disabledReason: String(localized: "Give the action a title and instructions.", bundle: .module),
                onCancel: onCancel,
                onConfirm: onSave
            )
        }
        // The ideal is the old fixed minimum; the minimum is what fits over
        // the main window at its 820×540 floor. The grouped form scrolls, so
        // a shorter sheet loses nothing.
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 680)
    }

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
