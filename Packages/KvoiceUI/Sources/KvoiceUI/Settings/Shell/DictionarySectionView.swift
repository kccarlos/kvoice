import SwiftUI
import KvoiceAppCore
import KvoiceDomain

/// The Dictionary section (Dictation group, ADR-018): the term table with
/// add/edit/delete, the live token counter against the resident model's
/// budget, and Import/Export as plain text. Panels go through the view
/// model's hooks, so nothing here opens a window in a test.
@MainActor
public struct DictionarySectionView: View {
    @Bindable private var model: DictionaryViewModel
    /// ADR-022 item 3: the `.dictionary` row — the editor is disabled, with
    /// the reason, while the resident model takes no prompt. The stored list
    /// is untouched; a model that takes a prompt sends it again.
    private let availability: SettingsAvailabilityModel
    @State private var selection: Set<DictionaryEntry.ID> = []
    @State private var confirmingRemoveAll = false
    @FocusState private var addFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        model: DictionaryViewModel = .init(),
        availability: SettingsAvailabilityModel = .init()
    ) {
        self.model = model
        self.availability = availability
    }

    public var body: some View {
        Form {
            termsSection
            budgetSection
            fileSection
        }
        .formStyle(.grouped)
    }

    // MARK: Terms

    private var termsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Table(model.entries, selection: $selection) {
                    TableColumn("Term") { entry in
                        DictionaryTermCell(entry: entry) { text in
                            Task { await model.update(id: entry.id, term: text) }
                        }
                    }
                }
                .frame(minHeight: 160, idealHeight: 220)
                .onDeleteCommand {
                    removeSelection()
                }
                .accessibilityLabel("Dictionary terms")
                .accessibilityHint("Double-click a term to edit it. Press Delete to remove the selected terms.")

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { addControls; Spacer(); removeControls }
                    VStack(alignment: .leading, spacing: 8) { addControls; removeControls }
                }

                if let message = model.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Dictionary note")
                }
            }
            // The whole group is one row, so the `.task` and the dialog sit
            // on a single view rather than on every row of the Section.
            .task { await pollWhileVisible() }
            .confirmationDialog(
                "Remove every term from the dictionary?",
                isPresented: $confirmingRemoveAll,
                titleVisibility: .visible
            ) {
                Button("Remove All", role: .destructive) {
                    Task { await model.removeAll() }
                }
            } message: {
                Text("Your settings, history, and models are kept. Export first if you want a copy.")
            }
        } header: {
            Text("Terms")
        } footer: {
            Text(availability.footnote(
                .dictionary,
                base: String(localized: "Names and jargon the model tends to misspell. They are sent to the speech model as a hint with every dictation, streaming pass, and transcribed file — it nudges the spelling, it cannot guarantee it. One list for every language.", bundle: .module)
            ))
        }
        .disabled(!availability.isEnabled(.dictionary))
    }

    private var addControls: some View {
        HStack(spacing: 8) {
            TextField("New term", text: $model.draftTerm)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, idealWidth: 240)
                .focused($addFieldFocused)
                .onSubmit { addDraft() }
                .accessibilityLabel("New term")
            Button("Add") { addDraft() }
                .disabled(model.isCounting || DictionarySettings.normalizedTerm(model.draftTerm) == nil)
                .accessibilityHint("Adds the term when it fits the token budget.")
        }
    }

    private var removeControls: some View {
        HStack(spacing: 8) {
            Button("Remove") { removeSelection() }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(selection.isEmpty)
                .accessibilityHint("Removes the selected terms.")
            Button("Remove All…", role: .destructive) { confirmingRemoveAll = true }
                .disabled(model.entries.isEmpty)
        }
    }

    private func addDraft() {
        Task {
            if await model.add() {
                addFieldFocused = true
            }
        }
    }

    private func removeSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        selection = []
        Task { await model.remove(ids: ids) }
    }

    // MARK: Budget

    private var budgetSection: some View {
        Section {
            if let phrases = model.phraseUsage {
                // ADR-025: Apple Speech takes the terms as recognition hints,
                // not as a prompt — a count, no tokenizer, no token budget.
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Terms sent as hints") {
                        Text("\(phrases.sent) of \(phrases.limit)")
                            .monospacedDigit()
                            .foregroundStyle(model.terms.count > phrases.limit ? .red : .primary)
                    }
                    .accessibilityLabel("Terms sent as hints")
                    .accessibilityValue("\(phrases.sent) of \(phrases.limit)")
                    if model.terms.count > phrases.limit {
                        StatusLabel(
                            String(localized: "Only the first \(phrases.limit) terms are sent; the rest are kept for another model.", bundle: .module),
                            symbol: "exclamationmark.triangle.fill",
                            tone: .attention
                        )
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if let usage = model.usage {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Tokens used") {
                        Text(usage.label)
                            .monospacedDigit()
                            .foregroundStyle(usage.isOverBudget ? .red : .primary)
                    }
                    .accessibilityLabel("Tokens used")
                    .accessibilityValue(usage.label)
                    ProgressView(value: usage.fraction)
                        .tint(usage.isOverBudget ? .red : usage.isNearBudget ? .orange : .accentColor)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: usage.fraction)
                        .accessibilityHidden(true)
                    if usage.isOverBudget {
                        StatusLabel(
                            String(localized: "Over the current model's budget: the model only sees the first \(usage.budget.promptTokenLimit) tokens. Remove terms until the counter is under \(usage.budget.budget).", bundle: .module),
                            symbol: "exclamationmark.triangle.fill",
                            tone: .attention
                        )
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if let preview = model.promptPreview {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                            .accessibilityLabel("Prompt preview")
                    }
                }
            } else {
                // The projection's reason when the resident model takes no
                // prompt; otherwise the budget is simply not known yet.
                Text(availability.disabledReason(.dictionary)
                    ?? String(localized: "The token budget appears once a speech model is set up.", bundle: .module))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Token Budget")
        } footer: {
            Text(budgetFooter)
        }
    }

    private var budgetFooter: String {
        if let phrases = model.phraseUsage {
            return String(localized: "Apple Speech takes the dictionary as recognition hints rather than a prompt: up to \(phrases.limit) short terms, ideally one or two words each. Whether a term is recognized is up to the model.", bundle: .module)
        }
        guard let usage = model.usage else {
            return String(localized: "Whisper models take a short prompt before the audio; other models may take none.", bundle: .module)
        }
        let source = usage.budget.isFromResidentModel
            ? String(localized: "the loaded model's limit of \(usage.budget.promptTokenLimit) tokens", bundle: .module)
            : String(localized: "the default model's limit of \(usage.budget.promptTokenLimit) tokens", bundle: .module)
        let exactness = usage.isExact
            ? String(localized: "Counted with the model's own tokenizer.", bundle: .module)
            : String(localized: "≈ is an estimate (about one token per four letters, more for Chinese, Japanese, and Korean) until the model is loaded.", bundle: .module)
        let base = String(localized: "The dictionary may use \(usage.budget.budget) of \(source); the rest is kept in reserve. \(exactness)", bundle: .module)
        guard let cap = model.host.effective.dictionaryBudgetEngineCap else { return base }
        return base + " " + String(localized: "Using the loaded model's cap of \(cap) tokens, which is lower than the model's own limit.", bundle: .module)
    }

    // MARK: Import / Export

    private var fileSection: some View {
        Section {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { fileButtons }
                VStack(alignment: .leading, spacing: 8) { fileButtons }
            }
        } header: {
            Text("Import and Export")
        } footer: {
            Text("Plain text, one term per line. Import adds to the list — duplicates are skipped and anything past the budget is left out and reported.")
        }
    }

    @ViewBuilder
    private var fileButtons: some View {
        Button("Import…") {
            Task { await model.importFromPanel() }
        }
        .disabled(model.isCounting)
        .accessibilityHint("Choose a text file with one term per line.")
        Button("Export…") {
            model.exportToPanel()
        }
        .disabled(model.entries.isEmpty)
        .accessibilityHint("Save the dictionary as a text file.")
    }

    /// Flips the counter from ≈ to exact once the model is resident and
    /// follows a default-model change. Once a second while visible; the view
    /// model drops unchanged values so this never re-renders a quiet section.
    private func pollWhileVisible() async {
        while !Task.isCancelled {
            await model.refresh()
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }
}

/// One editable table cell. Local text so a half-typed edit does not touch
/// the settings; commits on Return or focus loss, and follows the row when
/// the shell re-applies settings.
private struct DictionaryTermCell: View {
    let entry: DictionaryEntry
    let commit: (String) -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(entry: DictionaryEntry, commit: @escaping (String) -> Void) {
        self.entry = entry
        self.commit = commit
        _text = State(initialValue: entry.term)
    }

    var body: some View {
        TextField("Term", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { commitIfChanged() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commitIfChanged() }
            }
            .onChange(of: entry.term) { _, newTerm in
                text = newTerm
            }
            .accessibilityLabel("Term")
    }

    private func commitIfChanged() {
        guard text != entry.term else { return }
        commit(text)
    }
}

#if DEBUG
#Preview("Dictionary") {
    DictionarySectionView(
        model: DictionaryViewModel(
            host: .detached(settings: AppSettings(dictionary: DictionarySettings(terms: ["kvoice", "WhisperKit", "Ada Lovelace"]))),
            catalogPromptTokenLimit: 224
        )
    )
    .frame(width: 640, height: 560)
}
#endif
