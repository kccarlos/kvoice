import Foundation
import KvoiceAppCore
import KvoiceDomain
import Observation

/// Main-actor state for the AI Actions half of the AI Actions section: the
/// master switch, the action list and its default, per-action mode settings,
/// trigger words, the Selection Action slots, and the user profile.
///
/// Deliberately separate from `AISettingsViewModel`, which owns the endpoint,
/// credentials, configurations, and discovery. Actions are an independent
/// concern with their own list, editor, and preview, so keeping them apart
/// means either can be read, tested, or changed without loading the other.
///
/// Like AI configurations, applying an action copies its values into the live
/// request fields; nothing here knows how a request is made.
///
/// ADR-022 slice 7 part B: a projection over `SettingsProjectionHost`.
/// `modes`, `isEnabled`, `actionTriggersEnabled`, the Selection Action slots,
/// and every list edit read `host.settings.ai` live and send one `.setAI`
/// with the whole block — built from that live value plus the one change, so
/// a concurrent edit from `AISettingsViewModel` (the endpoint half of the
/// same block) is never clobbered. `userProfile` is the one typed field: a
/// draft, committed by `flushPendingChanges()` (the view's `.onSubmit` /
/// focus-change / `.onDisappear` / resign-active hooks, unchanged) rather
/// than the debounce `Task` this used to schedule per keystroke.
///
/// **Staleness.** `userProfile` is seeded once (`init`) and never re-read
/// on its own, so it goes stale the moment the stored block moves without
/// this model's help — the same gap `AISettingsViewModel` documents
/// (`AppDelegate.init` runs before the coordinator's real load; an Import,
/// Restore Previous Settings, or the status menu can also move the block).
/// `discardStaleDrafts()` re-seeds it from `host.settings.ai.userProfile`
/// whenever that has moved since the draft was last seeded or committed,
/// and is called before every read or write that blends it into a commit.
@Observable
@MainActor
public final class PromptModeSettingsViewModel {
    /// The coordinator projection and the intent door.
    public let host: SettingsProjectionHost

    public var modes: [PromptMode] {
        get { host.settings.ai.promptModes }
        set {
            guard newValue != modes else { return }
            var next = settings
            next.promptModes = newValue
            commit(next)
        }
    }

    /// The default action's id.
    public var activeModeID: UUID? { host.settings.ai.activePromptModeID }

    /// Sample text the user types to try a prompt before committing to it.
    public var previewInput: String = ""
    public private(set) var previewOutput: String = ""
    public private(set) var previewState: PreviewState = .idle

    /// Free-text personal context sent with every request. A draft: typed
    /// into freely, clamped to the character limit as it changes, and
    /// committed by `flushPendingChanges()`.
    public var userProfile: String {
        didSet {
            if userProfile.count > AIEndpointSettings.userProfileMaximumCharacters {
                userProfile = String(userProfile.prefix(AIEndpointSettings.userProfileMaximumCharacters))
            }
        }
    }

    /// The last refusal's sentence, for the page footer; nil otherwise.
    public var refusalNote: String? { host.refusalNote }

    public enum PreviewState: Equatable, Sendable {
        case idle
        case running
        case succeeded
        case failed(String)
    }

    /// Runs a prompt against sample text using the app's configured endpoint.
    private let previewRunner: @MainActor (PromptMode, String) async throws -> String
    /// The stored block as of the last time `userProfile` was seeded or
    /// committed. `discardStaleDrafts()` compares this to the live
    /// `host.settings.ai`: equal means nothing else has touched the block,
    /// so an in-progress draft is left alone; different means the draft is
    /// stale and is re-seeded.
    private var draftBase: AIEndpointSettings

    public init(
        host: SettingsProjectionHost = .detached(),
        previewRunner: @escaping @MainActor (PromptMode, String) async throws -> String = { _, _ in "" }
    ) {
        self.host = host
        let settings = host.settings.ai
        draftBase = settings
        userProfile = settings.userProfile
        self.previewRunner = previewRunner
    }

    /// Re-seeds `userProfile` from `host.settings.ai` when it has moved
    /// since the draft was last seeded or committed. Called before every
    /// read or write that blends it into a commit (`settings`,
    /// `flushPendingChanges()`, `hasPendingChanges`); the shell also calls
    /// it once, explicitly, right after the coordinator's real settings
    /// load (`AppDelegate+Settings.swift`).
    public func discardStaleDrafts() {
        let stored = host.settings.ai
        guard stored.userProfile != draftBase.userProfile else { return }
        draftBase = stored
        userProfile = stored.userProfile
    }

    /// The stored block with the `userProfile` draft overlaid — the shape
    /// every commit below sends, so a field mid-edit is never dropped by an
    /// unrelated write (matches the pre-slice-7 behaviour, which always sent
    /// the same blend).
    public var settings: AIEndpointSettings {
        discardStaleDrafts()
        var updated = host.settings.ai
        updated.userProfile = userProfile
        return updated
    }

    public var activeMode: PromptMode? {
        guard let activeModeID else { return nil }
        return modes.first { $0.id == activeModeID }
    }

    // MARK: Master switch

    /// The "Enable AI Actions" toggle. Independent of which action is the
    /// default; choosing an action never flips it (product decision #6).
    public var isEnabled: Bool {
        get { host.settings.ai.isEnabled }
        set {
            guard newValue != isEnabled else { return }
            var next = settings
            next.isEnabled = newValue
            commit(next)
        }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    /// True when an endpoint is configured well enough to run a request.
    /// The section shows the "add a configuration" call-out when this is false.
    public var canEnableProcessing: Bool {
        host.settings.ai.canEnableProcessing
    }

    /// True when a request would actually be made after a transcription:
    /// the switch is on, an endpoint exists, and a usable default action is set.
    public var isProcessingEnabled: Bool {
        settings.mode != .off
    }

    /// Turns AI processing off without forgetting which action was chosen.
    public func disableProcessing() {
        isEnabled = false
    }

    // MARK: Selection

    /// Makes an action the default by copying its prompt and semantics into
    /// the request fields, exactly as selecting an AI configuration copies its
    /// endpoint. Does not touch the master switch.
    public func selectMode(id: UUID) {
        guard let mode = modes.first(where: { $0.id == id }) else { return }
        var next = settings
        next.promptModes = modes
        next.apply(promptMode: mode)
        commit(next)
    }

    /// ⌘1–⌘0: the n-th saved action, with 0 meaning the tenth. Returns the
    /// action that became the default, or `nil` when the slot is empty.
    @discardableResult
    public func selectDefaultAction(shortcutNumber number: Int) -> PromptMode? {
        guard let index = Self.actionIndex(forShortcutNumber: number),
              modes.indices.contains(index),
              modes[index].isUsable
        else {
            return nil
        }
        selectMode(id: modes[index].id)
        return modes[index]
    }

    /// The action ⌘n names, without selecting it: the in-recorder switch
    /// (ADR-021) resolves the key here and hands the id to the controller
    /// seam, so the persisted default never moves. Nil for an empty slot or
    /// an action that cannot run.
    public func action(forShortcutNumber number: Int) -> PromptMode? {
        guard let index = Self.actionIndex(forShortcutNumber: number),
              modes.indices.contains(index),
              modes[index].isUsable
        else { return nil }
        return modes[index]
    }

    /// The ⌘-badge for an action, by its position in the saved order:
    /// "⌘1" … "⌘9", "⌘0" for the tenth, nothing beyond that.
    public func shortcutBadge(for modeID: UUID) -> String? {
        guard let index = modes.firstIndex(where: { $0.id == modeID }), index < 10 else { return nil }
        return "⌘\(index == 9 ? 0 : index + 1)"
    }

    static func actionIndex(forShortcutNumber number: Int) -> Int? {
        switch number {
        case 1...9: return number - 1
        case 0: return 9
        default: return nil
        }
    }

    // MARK: Editing

    public func addMode(_ draft: PromptModeDraft) -> PromptMode? {
        guard draft.isComplete else { return nil }
        var mode = PromptMode(
            name: uniqueName(from: draft.name, excluding: nil),
            behavior: draft.behavior,
            prompt: draft.prompt,
            builtInKey: nil,
            translationLanguage: draft.behavior == .translate ? draft.translationLanguage : nil
        )
        draft.write(into: &mode)
        var next = settings
        next.promptModes.append(mode)
        if next.activePromptModeID == nil {
            next.apply(promptMode: mode)
        }
        commit(next)
        return mode
    }

    /// Saves an edit. A built-in keeps its key so it can still be reset.
    public func updateMode(id: UUID, from draft: PromptModeDraft) {
        guard draft.isComplete, modes.firstIndex(where: { $0.id == id }) != nil else { return }
        var next = settings
        guard let index = next.promptModes.firstIndex(where: { $0.id == id }) else { return }
        next.promptModes[index].name = uniqueName(from: draft.name, excluding: id)
        next.promptModes[index].behavior = draft.behavior
        next.promptModes[index].prompt = draft.prompt
        next.promptModes[index].translationLanguage = draft.behavior == .translate
            ? draft.translationLanguage
            : nil
        draft.write(into: &next.promptModes[index])
        if next.activePromptModeID == id {
            next.apply(promptMode: next.promptModes[index])
        }
        commit(next)
    }

    /// Changes the per-action mode settings (formal writing, second
    /// translation, …) without opening the editor.
    public func updateOptions(id: UUID, _ options: PromptModeOptions) {
        guard let index = modes.firstIndex(where: { $0.id == id }), modes[index].options != options else {
            return
        }
        var next = settings
        guard let nextIndex = next.promptModes.firstIndex(where: { $0.id == id }) else { return }
        next.promptModes[nextIndex].options = options
        if next.activePromptModeID == id {
            next.apply(promptMode: next.promptModes[nextIndex])
        }
        commit(next)
    }

    /// A copy the user can edit without touching the original. Never a
    /// built-in, so it can be deleted.
    @discardableResult
    public func duplicateMode(id: UUID) -> PromptMode? {
        guard let original = modes.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.builtInKey = nil
        copy.name = uniqueName(from: String(localized: "\(original.menuTitle) copy", bundle: .module), excluding: nil)
        copy.triggerWords = []
        var next = settings
        next.promptModes.append(copy)
        commit(next)
        return copy
    }

    /// Built-ins can be edited but not deleted; Reset restores them instead.
    public func canDelete(id: UUID) -> Bool {
        modes.first { $0.id == id }.map { !$0.isBuiltIn } ?? false
    }

    public func deleteMode(id: UUID) {
        guard let mode = modes.first(where: { $0.id == id }), !mode.isBuiltIn else { return }
        var next = settings
        next.promptModes.removeAll { $0.id == id }
        for slot in 0..<AIEndpointSettings.selectionActionSlotCount
        where next.selectionActionSlots[slot] == id {
            next.bindSelectionAction(nil, slot: slot)
        }
        if next.activePromptModeID == id {
            next.activePromptModeID = nil
        }
        commit(next)
    }

    /// Puts a revised built-in back to what shipped, keeping its mode
    /// settings and context opt-ins.
    public func resetBuiltIn(id: UUID) {
        guard let index = modes.firstIndex(where: { $0.id == id }), modes[index].isBuiltIn else {
            return
        }
        var next = settings
        guard let nextIndex = next.promptModes.firstIndex(where: { $0.id == id }) else { return }
        next.promptModes[nextIndex].resetToShippedText()
        if next.activePromptModeID == id {
            next.apply(promptMode: next.promptModes[nextIndex])
        }
        commit(next)
    }

    /// Kept for callers written against the earlier name.
    public func restoreBuiltIn(id: UUID) {
        resetBuiltIn(id: id)
    }

    /// Resets every built-in's text and adds back any that is missing, in
    /// one change. User-made actions are untouched.
    public func resetAllBuiltIns() {
        var next = settings
        for index in next.promptModes.indices where next.promptModes[index].isBuiltIn {
            next.promptModes[index].resetToShippedText()
        }
        Self.appendMissingBuiltIns(to: &next)
        if let activeID = next.activePromptModeID, let activeMode = next.promptModes.first(where: { $0.id == activeID }) {
            next.apply(promptMode: activeMode)
        }
        commit(next)
    }

    /// Adds any shipped action the user does not have, without touching their own.
    public func restoreMissingBuiltIns() {
        var next = settings
        let before = next.promptModes.count
        Self.appendMissingBuiltIns(to: &next)
        guard next.promptModes.count != before else { return }
        commit(next)
    }

    private static func appendMissingBuiltIns(to settings: inout AIEndpointSettings) {
        let present = Set(settings.promptModes.compactMap(\.builtInKey))
        let missing = BuiltInPromptModes.all.filter { mode in
            guard let key = mode.builtInKey else { return false }
            return !present.contains(key)
        }
        guard !missing.isEmpty else { return }
        settings.promptModes.append(contentsOf: missing)
    }

    private func uniqueName(from requested: String, excluding id: UUID?) -> String {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? String(localized: "Action", bundle: .module) : trimmed
        let taken = Set(modes.filter { $0.id != id }.map(\.name))
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    // MARK: Triggers

    public var actionTriggersEnabled: Bool {
        get { host.settings.ai.actionTriggersEnabled }
        set {
            guard newValue != actionTriggersEnabled else { return }
            var next = settings
            next.actionTriggersEnabled = newValue
            commit(next)
        }
    }

    // MARK: Selection Action

    public var selectionActionSlots: [UUID?] {
        host.settings.ai.selectionActionSlots
    }

    public func selectionAction(slot: Int) -> PromptMode? {
        guard selectionActionSlots.indices.contains(slot), let id = selectionActionSlots[slot] else {
            return nil
        }
        return modes.first { $0.id == id }
    }

    public func bindSelectionAction(_ modeID: UUID?, slot: Int) {
        guard selectionActionSlots.indices.contains(slot), selectionActionSlots[slot] != modeID else { return }
        var next = settings
        next.bindSelectionAction(modeID, slot: slot)
        commit(next)
    }

    // MARK: Preview

    public var canRunPreview: Bool {
        !previewInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && previewState != .running
    }

    /// Runs sample text through a draft prompt so the user can judge it before
    /// saving. Uses the ordinary request path, so what they see is what a real
    /// dictation would produce.
    public func runPreview(using draft: PromptModeDraft) async {
        let sample = previewInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return }
        guard draft.isComplete else {
            previewState = .failed(String(localized: "Give the action a name and instructions first.", bundle: .module))
            return
        }

        previewState = .running
        previewOutput = ""
        var candidate = PromptMode(
            name: draft.name,
            behavior: draft.behavior,
            prompt: draft.prompt,
            translationLanguage: draft.behavior == .translate ? draft.translationLanguage : nil
        )
        draft.write(into: &candidate)
        do {
            previewOutput = try await previewRunner(candidate, sample)
            previewState = .succeeded
        } catch {
            // Endpoint detail is never surfaced; the message stays generic.
            previewState = .failed(String(localized: "The request failed. Check the AI configuration.", bundle: .module))
        }
    }

    public func clearPreview() {
        previewOutput = ""
        previewState = .idle
    }

    // MARK: Change delivery

    /// Commits `userProfile` now, if it differs from the stored value. Safe
    /// to call when nothing is pending; the view's `.onSubmit`, focus-change,
    /// `.onDisappear`, and resign-active hooks all call this unchanged.
    public func flushPendingChanges() {
        discardStaleDrafts()
        guard hasPendingChanges else { return }
        commit(settings)
    }

    public var hasPendingChanges: Bool {
        discardStaleDrafts()
        return userProfile != host.settings.ai.userProfile
    }

    /// Sends the block as one `.setAI` intent and keeps `draftBase` in step
    /// with what was actually committed, so `discardStaleDrafts()` does not
    /// mistake this model's own accepted commit for a foreign write. A
    /// refusal leaves the stored block (and `draftBase`) untouched, so
    /// every read above already shows the truth; the host records the note
    /// in `refusalNote`.
    @discardableResult
    private func commit(_ next: AIEndpointSettings) -> Bool {
        guard host.send(.setAI(next, origin: .page(.aiActions))) == nil else { return false }
        draftBase = next
        return true
    }
}

/// The product's name for the same object.
public typealias AIActionsViewModel = PromptModeSettingsViewModel

/// Everything the action editor collects, for both new and existing actions.
public struct PromptModeDraft: Equatable, Sendable {
    public var name: String
    public var behavior: AIMode
    public var prompt: String
    public var translationLanguage: TranslationLanguage
    // MARK: AI actions
    public var summary: String
    public var icon: String
    public var triggerWords: [String]
    public var usesSystemInstructionsTemplate: Bool
    public var includesClipboardText: Bool
    public var includesSelectedText: Bool

    public init(
        name: String = "",
        behavior: AIMode = .polish,
        prompt: String = "",
        translationLanguage: TranslationLanguage = .init(bcp47: "en", displayName: "English"),
        summary: String = "",
        icon: String = "",
        triggerWords: [String] = [],
        // A new action is written as a task; the house template supplies
        // the rest. Shipped actions carry the full prompt and turn this off.
        usesSystemInstructionsTemplate: Bool = true,
        includesClipboardText: Bool = false,
        includesSelectedText: Bool = false
    ) {
        self.name = name
        self.behavior = behavior
        self.prompt = prompt
        self.translationLanguage = translationLanguage
        self.summary = summary
        self.icon = icon
        self.triggerWords = triggerWords
        self.usesSystemInstructionsTemplate = usesSystemInstructionsTemplate
        self.includesClipboardText = includesClipboardText
        self.includesSelectedText = includesSelectedText
    }

    public init(mode: PromptMode) {
        name = mode.name
        behavior = mode.behavior
        prompt = mode.prompt
        translationLanguage = mode.translationLanguage
            ?? .init(bcp47: "en", displayName: "English")
        summary = mode.summary
        icon = mode.icon
        triggerWords = mode.triggerWords
        usesSystemInstructionsTemplate = mode.usesSystemInstructionsTemplate
        includesClipboardText = mode.includesClipboardText
        includesSelectedText = mode.includesSelectedText
    }

    /// Starts a new action from a shipped one, which is easier than writing a
    /// prompt from nothing.
    public init(basedOn template: PromptMode, name: String) {
        self.init(mode: template)
        self.name = name
        triggerWords = []
    }

    public var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The system prompt this draft would send, for the editor's preview.
    public var effectiveSystemPrompt: String {
        var mode = PromptMode(name: name, behavior: behavior, prompt: prompt)
        write(into: &mode)
        return mode.effectiveSystemPrompt
    }

    /// Copies the action-only fields; name, behavior, prompt, and language are
    /// written by the caller because they carry validation.
    func write(into mode: inout PromptMode) {
        mode.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        mode.icon = Self.singleGrapheme(icon)
        mode.triggerWords = PromptMode.normalizedTriggerWords(triggerWords)
        mode.usesSystemInstructionsTemplate = usesSystemInstructionsTemplate
        mode.includesClipboardText = includesClipboardText
        mode.includesSelectedText = includesSelectedText
    }

    /// An icon is one emoji; anything longer keeps only its first character.
    public static func singleGrapheme(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }
        return String(first)
    }
}
