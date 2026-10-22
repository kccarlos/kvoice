import SwiftUI
import KvoiceAppCore
import KvoiceDomain

/// The Dictionary section (Dictation group, ADR-018), drawn to Window.dc
/// (UI v2 fidelity F3b): the "Terms" card — an "Add a name or term…" field
/// with a primary Add over the terms as wrapping chips with ✕ — the "What
/// the model sees" card with the live token counter against the resident
/// model's budget, and Import/Export as plain text. A chip edits in place
/// (Return, double-click, or VoiceOver's Edit), as the table's cells did.
/// Panels go through the view model's hooks, so nothing here opens a
/// window in a test.
@MainActor
public struct DictionarySectionView: View {
    @Bindable private var model: DictionaryViewModel
    /// ADR-022 item 3: the `.dictionary` row — the editor is disabled, with
    /// the reason, while the resident model takes no prompt. The stored list
    /// is untouched; a model that takes a prompt sends it again.
    private let availability: SettingsAvailabilityModel
    @State private var confirmingRemoveAll = false
    /// Q3 leftover (b): several chips at once (⌘/⇧-click, ⌘A), removed
    /// together by Delete or the header's Remove Selected.
    @State private var selection = ChipSelection<DictionaryEntry.ID>()
    @FocusState private var focus: DictionaryFocus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        model: DictionaryViewModel = .init(),
        availability: SettingsAvailabilityModel = .init()
    ) {
        self.model = model
        self.availability = availability
    }

    public var body: some View {
        KVCardPage {
            termsSection
            budgetSection
            fileSection
        }
    }

    // MARK: Terms

    private var termsSection: some View {
        KVBlockSection(padding: 12) {
            VStack(alignment: .leading, spacing: 12) {
                addRow
                if !model.entries.isEmpty {
                    chips
                }
                if let message = model.message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kv.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text("Dictionary note", bundle: .module))
                        .accessibilityValue(Text(verbatim: message))
                }
            }
            // The whole card is one view, so the `.task` and the dialog sit
            // on a single view.
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
            // Remove All… is not drawn in Window.dc; it stays as a quiet
            // header link (F3's "Reset to Default" pattern).
            KVHeaderRow("Terms") {
                if !selection.isEmpty {
                    Button {
                        removeSelection()
                    } label: {
                        Text("Remove Selected (\(selection.count))", bundle: .module)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kv.errInk)
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .accessibilityHint(Text("Removes the selected terms.", bundle: .module))
                }
                if !model.entries.isEmpty {
                    Button("Remove All…", role: .destructive) { confirmingRemoveAll = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kv.errInk)
                        .accessibilityHint("Removes every term after you confirm.")
                }
            }
        } footer: {
            if let reason = availability.disabledReason(.dictionary) {
                Text(reason)
            }
        }
        .disabled(!availability.isEnabled(.dictionary))
    }

    /// Window.dc: a 30 pt field (radius 7, `line` border on the window
    /// ground, 13 pt) and the primary Add beside it.
    private var addRow: some View {
        HStack(spacing: 8) {
            TextField(text: $model.draftTerm, prompt: Text("Add a name or term…", bundle: .module)) {
                Text("New term", bundle: .module)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Color.kv.text)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.kv.bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focus == .add ? Color.kv.cursor : Color.kv.line, lineWidth: focus == .add ? 2 : 1)
            }
            .focused($focus, equals: .add)
            .onSubmit { addDraft() }
            .accessibilityLabel(Text("New term", bundle: .module))
            Button("Add") { addDraft() }
                .buttonStyle(KVButtonStyle(.primary, height: 30, fontSize: 13, horizontalPadding: 14))
                .disabled(model.isCounting || DictionarySettings.normalizedTerm(model.draftTerm) == nil)
                .accessibilityHint("Adds the term when it fits the token budget.")
        }
    }

    private var chips: some View {
        KVFlowLayout(spacing: 6) {
            ForEach(model.entries) { entry in
                DictionaryChip(
                    entry: entry,
                    isEditing: model.editingID == entry.id,
                    isSelected: selection.contains(entry.id),
                    text: $model.editingText,
                    focus: $focus,
                    onClick: { kind in
                        selection.click(entry.id, kind, order: model.entries.map(\.id))
                        focus = .chip(entry.id)
                    },
                    onSelectAll: { selection.selectAll(model.entries.map(\.id)) },
                    onClearSelection: { selection.clear() },
                    onEdit: { beginEditing(entry.id) },
                    onCommit: { commitEditing() },
                    onCancel: { cancelEditing(entry.id) },
                    onRemove: { remove(entry.id) },
                    onDeleteKey: { removeTargets(focused: entry.id) }
                )
                .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.8), value: model.entries.map(\.id))
        .onChange(of: model.entries.map(\.id)) { _, ids in selection.keep(only: ids) }
        // Typing in the Add field (⌘⌫ included) is about the field, not the
        // chips: leaving the chips for it ends the selection.
        .onChange(of: focus) { _, new in if new == .add { selection.clear() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Dictionary terms", bundle: .module))
    }

    private func addDraft() {
        Task {
            if await model.add() {
                focus = .add
            }
        }
    }

    private func beginEditing(_ id: DictionaryEntry.ID) {
        selection.clear()
        Task {
            // Finish another chip's edit first; a refused one stays open.
            guard await model.commitEditing() else { return }
            model.beginEditing(id)
            focus = .editor(id)
        }
    }

    private func commitEditing() {
        guard let id = model.editingID else { return }
        Task {
            if await model.commitEditing() {
                // The edited chip may come back under a new identity.
                if model.entries.contains(where: { $0.id == id }) { focus = .chip(id) }
            } else {
                focus = .editor(id)
            }
        }
    }

    private func cancelEditing(_ id: DictionaryEntry.ID) {
        model.cancelEditing()
        focus = .chip(id)
    }

    private func remove(_ id: DictionaryEntry.ID) {
        if model.editingID == id { model.cancelEditing() }
        Task { await model.remove(ids: [id]) }
    }

    /// Delete on a chip: the selection when the chip is in it, else the chip.
    private func removeTargets(focused id: DictionaryEntry.ID) {
        let ids = selection.removalTargets(focused: id)
        guard !ids.isEmpty else { return }
        if let editing = model.editingID, ids.contains(editing) { model.cancelEditing() }
        selection.clear()
        focus = .add
        Task { await model.remove(ids: ids) }
    }

    private func removeSelection() {
        let ids = selection.removalTargets(focused: nil)
        guard !ids.isEmpty else { return }
        if let editing = model.editingID, ids.contains(editing) { model.cancelEditing() }
        selection.clear()
        Task { await model.remove(ids: ids) }
    }

    // MARK: What the model sees

    private var budgetSection: some View {
        KVBlockSection(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                if let phrases = model.phraseUsage {
                    // ADR-025: Apple Speech takes the terms as recognition
                    // hints, not as a prompt — a count, no token budget.
                    let over = model.terms.count > phrases.limit
                    figureRow(String(localized: "Terms sent as hints", bundle: .module), String(localized: "\(phrases.sent) of \(phrases.limit)", bundle: .module), tone: over ? .err : nil)
                    DictionaryBudgetBar(fraction: phrases.limit > 0 ? min(1, Double(phrases.sent) / Double(phrases.limit)) : 1, tone: over ? .err : nil)
                    if over {
                        attention(String(localized: "Only the first \(phrases.limit) terms are sent; the rest are kept for another model.", bundle: .module))
                    }
                    hint
                } else if let usage = model.usage {
                    let tone: KVTone? = usage.isOverBudget ? .err : usage.isNearBudget ? .warn : nil
                    figureRow(String(localized: "Tokens used", bundle: .module), usage.figure, tone: usage.isOverBudget ? .err : nil)
                    DictionaryBudgetBar(fraction: usage.fraction, tone: tone)
                    if usage.isOverBudget {
                        attention(String(localized: "Over the current model's budget: the model only sees the first \(usage.budget.promptTokenLimit) tokens. Remove terms until the counter is under \(usage.budget.budget).", bundle: .module))
                    }
                    hint
                    if let preview = model.promptPreview {
                        // The label sits on a container: on the selectable
                        // text itself it recursed (see HistoryView's
                        // transcriptBox).
                        VStack(alignment: .leading, spacing: 0) {
                            Text(preview)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.kv.text2)
                                .lineLimit(3)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(Text("Prompt preview", bundle: .module))
                    }
                } else {
                    // The projection's reason when the resident model takes
                    // no prompt; otherwise the budget is simply not known yet.
                    Text(availability.disabledReason(.dictionary)
                        ?? String(localized: "The token budget appears once a speech model is set up.", bundle: .module))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.kv.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("What the model sees", bundle: .module)
        } footer: {
            Text(budgetFooter)
        }
    }

    private func figureRow(_ title: String, _ figure: String, tone: KVTone?) -> some View {
        HStack {
            Text(verbatim: title)
            Spacer(minLength: 8)
            Text(verbatim: figure)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(tone?.ink.color ?? Color.kv.text)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .timingCurve(0.34, 1.4, 0.64, 1, duration: 0.32), value: figure)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.kv.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: figure))
    }

    private var hint: some View {
        Text("Sent as a spelling hint with every dictation. It nudges the spelling; it can’t guarantee it.", bundle: .module)
            .font(.system(size: 11))
            .foregroundStyle(Color.kv.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func attention(_ text: String) -> some View {
        StatusLabel(text, symbol: "exclamationmark.triangle.fill", tone: .attention)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
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
        KVCardSection {
            LabeledContent {
                HStack(spacing: 6) {
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
            } label: {
                Text("Plain text, one term per line", bundle: .module)
            }
        } header: {
            Text("Import and Export")
        } footer: {
            Text("Import adds to the list; duplicates are skipped.", bundle: .module)
        }
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

/// Where keyboard focus is on the Dictionary page.
/// A chip click's kind from the modifier keys held: ⌘ toggles, ⇧ extends,
/// anything else selects only that chip.
enum DictionaryChipClick {
    static func kind(for flags: NSEvent.ModifierFlags) -> ChipSelection<DictionaryEntry.ID>.Click {
        if flags.contains(.command) { return .toggle }
        if flags.contains(.shift) { return .extend }
        return .plain
    }
}

enum DictionaryFocus: Hashable {
    case add
    case chip(DictionaryEntry.ID)
    case editor(DictionaryEntry.ID)
}

/// One term chip (Window.dc: 26 pt, radius 13, `fill`, 12 pt, padding
/// 0 6 0 10, a 16 pt ✕). It takes keyboard focus: Return edits, Delete
/// removes. While editing it becomes a field in the same shape, committed
/// by Return or focus loss and abandoned by Escape. VoiceOver reads one
/// element named by the term, with Edit and Remove actions.
private struct DictionaryChip: View {
    let entry: DictionaryEntry
    let isEditing: Bool
    let isSelected: Bool
    @Binding var text: String
    var focus: FocusState<DictionaryFocus?>.Binding
    let onClick: (ChipSelection<DictionaryEntry.ID>.Click) -> Void
    let onSelectAll: () -> Void
    let onClearSelection: () -> Void
    let onEdit: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void
    let onDeleteKey: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if isEditing {
            editor
        } else {
            chip
        }
    }

    private var chipFocused: Bool { focus.wrappedValue == .chip(entry.id) }

    private var chip: some View {
        HStack(spacing: 6) {
            Text(verbatim: entry.term)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.kv.cursorInk : Color.kv.text)
                .lineLimit(1)
            Button(action: onRemove) {
                Text(verbatim: "✕")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kv.text2)
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(Text("Remove “\(entry.term)”", bundle: .module))
            .accessibilityHidden(true)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 26)
        .background(isSelected ? Color.kv.cursorSoft : Color.kv.fill, in: Capsule(style: .continuous))
        .overlay {
            if chipFocused || isSelected || contrast == .increased {
                Capsule(style: .continuous)
                    .strokeBorder(
                        chipFocused || isSelected ? Color.kv.cursor : Color.kv.text2,
                        lineWidth: chipFocused ? 2 : 1
                    )
            }
        }
        .contentShape(Capsule(style: .continuous))
        .focusable(isEnabled)
        .focused(focus, equals: .chip(entry.id))
        .focusEffectDisabled()
        .onTapGesture(count: 2) { onEdit() }
        .onTapGesture { onClick(DictionaryChipClick.kind(for: NSEvent.modifierFlags)) }
        .onKeyPress(.return) {
            onEdit()
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            onDeleteKey()
            return .handled
        }
        // ⌘A arrives as the Edit menu's Select All when the window has a
        // menu, as a key press otherwise; both select every chip.
        .onCommand(#selector(NSResponder.selectAll(_:))) { onSelectAll() }
        .onKeyPress(characters: ["a"]) { press in
            guard press.modifiers == .command else { return .ignored }
            onSelectAll()
            return .handled
        }
        .onExitCommand { onClearSelection() }
        .contextMenu {
            Button("Edit…") { onEdit() }
            Button("Remove", role: .destructive) { onRemove() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: entry.term))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(Text(verbatim: KVAccessibility.selectionValue(isSelected)))
        .accessibilityHint(Text("Press Return or double-click to edit. Press Delete to remove. Command-click or Shift-click to select several.", bundle: .module))
        .accessibilityAction { onEdit() }
        .accessibilityAction(named: Text("Edit", bundle: .module)) { onEdit() }
        .accessibilityAction(named: isSelected ? Text("Deselect", bundle: .module) : Text("Select", bundle: .module)) {
            onClick(.toggle)
        }
        .accessibilityAction(named: Text("Remove", bundle: .module)) { onRemove() }
    }

    private var editor: some View {
        TextField(text: $text) {
            Text("Term", bundle: .module)
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(Color.kv.text)
        .fixedSize()
        .frame(minWidth: 60)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Color.kv.surface, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous).strokeBorder(Color.kv.cursor, lineWidth: 2)
        }
        .focused(focus, equals: .editor(entry.id))
        .focusEffectDisabled()
        .onSubmit { onCommit() }
        .onExitCommand { onCancel() }
        .onChange(of: focus.wrappedValue) { old, new in
            // Clicking elsewhere commits, like the table cell did.
            if old == .editor(entry.id), new != .editor(entry.id) { onCommit() }
        }
        .accessibilityLabel(Text("Edit term", bundle: .module))
    }
}

/// Window.dc's 6 pt budget bar: a `fill` track, the used share in `cursor`
/// (warn near the budget, err over it). The width eases 300 ms; no
/// count-up on appear.
private struct DictionaryBudgetBar: View {
    let fraction: Double
    let tone: KVTone?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.kv.fill)
                Capsule()
                    .fill(tone?.solid.color ?? Color.kv.cursor)
                    .frame(width: max(fraction > 0 ? 6 : 0, proxy.size.width * fraction))
            }
        }
        .frame(height: 6)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: fraction)
        .accessibilityHidden(true)
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
