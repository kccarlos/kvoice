import AppKit
import Foundation
import KvoiceAppCore
import KvoiceDomain
import Observation
import UniformTypeIdentifiers

/// One row of the Dictionary table. The stable `id` exists only for the
/// table; settings store the plain strings.
public struct DictionaryEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var term: String

    public init(id: UUID = UUID(), term: String) {
        self.id = id
        self.term = term
    }
}

/// What the live counter shows (ADR-018).
public struct DictionaryTokenUsage: Sendable, Equatable {
    /// Tokens of the rendered prompt, exact when a model is resident, else
    /// the `DictionaryPrompt.estimatedTokenCount` estimate.
    public let count: Int
    public let isExact: Bool
    public let budget: DictionaryTokenBudget

    public init(count: Int, isExact: Bool, budget: DictionaryTokenBudget) {
        self.count = count
        self.isExact = isExact
        self.budget = budget
    }

    /// 0…1 of the budget, for the progress bar (clamped so an over-budget
    /// list shows a full bar, not a broken one).
    public var fraction: Double {
        guard budget.budget > 0 else { return 1 }
        return min(1, Double(count) / Double(budget.budget))
    }

    /// The bar turns amber above this share of the budget.
    public static let warningFraction = 0.8

    public var isNearBudget: Bool { fraction >= Self.warningFraction }
    public var isOverBudget: Bool { count > budget.budget }

    /// "137 / 201 tokens" or "≈ 137 / 201 tokens".
    public var label: String {
        isExact
            ? String(localized: "\(count) / \(budget.budget) tokens", bundle: .module)
            : String(localized: "≈ \(count) / \(budget.budget) tokens", bundle: .module)
    }
}

/// State for Dictation › Dictionary (ADR-018): the term list, the live token
/// counter against the resident model's budget, and Import/Export.
///
/// ADR-022 slice 7: a projection over `SettingsProjectionHost`. The stored
/// list is `host.settings.dictionary` read live; every edit sends one
/// `.setDictionary` intent with the next list, and a refusal (a job in
/// flight, ADR-018: the running job keeps the list it started with) leaves
/// the stored list — so the table — as it was, with the reducer's note in
/// `message`. `entries` gives the table stable row identities over that
/// list: a per-term cache (`@ObservationIgnored`, reconciled on read, never
/// a second source of truth) so a selection survives a change made from
/// another door. Adding is refused — with a message — when the list
/// *including the new term* would exceed the budget; a list that is already
/// over budget because the budget shrank (the default model changed) is kept
/// and flagged, never truncated here: the engine caps what it sends.
///
/// Counting is asynchronous because the exact count comes from the
/// transcription actor's tokenizer. `counter` is the resident engine; while
/// it reports nothing (no model loaded) the estimate stands in, labelled ≈.
/// `catalogPromptTokenLimit` is the default catalog entry's value, the
/// budget's source until a model is resident. The exact count is cached
/// against the terms it was taken for; a list changed underneath it reads
/// as the estimate until the next `refresh()`.
@Observable
@MainActor
public final class DictionaryViewModel {
    /// The coordinator projection and the intent door.
    public let host: SettingsProjectionHost
    /// Whether "no prompt" is known for sure (resident model says so) rather
    /// than nothing having been resolved yet.
    public private(set) var promptUnsupported = false
    /// ADR-025: the resident runtime takes the list as contextual phrases
    /// (Apple Speech), at most this many; nil for a token-budget runtime or
    /// while nothing is resident. The section shows a phrase count instead
    /// of the token counter.
    public private(set) var phraseLimit: Int?
    /// The last refusal or import note; cleared by the next successful edit.
    public private(set) var message: String?
    /// Set while an add or import is being counted, so the buttons disable.
    public private(set) var isCounting = false
    /// The text of the add field, owned here so a refused add keeps it. A
    /// draft in the slice-7 sense: local UI state, never a setting.
    public var draftTerm = ""

    // MARK: Shell hooks

    /// The resident engine's tokenizer and limit; nil (default) means the
    /// estimate and the catalog value are all the view model has.
    @ObservationIgnored public var counter: (any PromptTokenCounting)?
    /// The default catalog entry's `promptTokenLimit`; the shell sets it and
    /// updates it when the default model changes.
    @ObservationIgnored public var catalogPromptTokenLimit: Int?
    /// Presents the Import panel and returns the chosen file; replaceable so
    /// tests never open a panel.
    @ObservationIgnored public var chooseImportFile: @MainActor () -> URL? = DictionaryViewModel.presentImportPanel
    /// Presents the Export panel and returns the destination.
    @ObservationIgnored public var chooseExportFile: @MainActor () -> URL? = DictionaryViewModel.presentExportPanel

    /// ADR-022 slice 5: the reserve share from the developer defaults.
    @ObservationIgnored private let reserveFraction: Double
    /// Row identities for the terms last handed out, reconciled on every
    /// read of `entries`. Ignored by observation on purpose: the table
    /// re-renders because `host.settings` changed, not because this did.
    @ObservationIgnored private var rowCache: [DictionaryEntry] = []
    /// The exact (or estimated-with-model) usage from the last `refresh()`,
    /// with the terms it counted; stale for any other list.
    private var countedUsage: DictionaryTokenUsage?
    private var countedTerms: [String]?

    public init(
        host: SettingsProjectionHost = .detached(),
        counter: (any PromptTokenCounting)? = nil,
        catalogPromptTokenLimit: Int? = nil,
        reserveFraction: Double = DictionaryTokenBudget.reserveFraction
    ) {
        self.host = host
        self.counter = counter
        self.catalogPromptTokenLimit = catalogPromptTokenLimit
        self.reserveFraction = reserveFraction
    }

    /// The stored list.
    public var settings: DictionarySettings { host.settings.dictionary }

    public var terms: [String] { settings.terms }

    /// The stored terms with stable row identities (the table's `id`;
    /// settings store the plain strings). Unchanged terms keep their id
    /// across any change, from this page or another door.
    public var entries: [DictionaryEntry] {
        let terms = self.terms
        if rowCache.map(\.term) != terms {
            rowCache = Self.reconcile(rowCache, with: terms)
        }
        return rowCache
    }

    /// Row identities for `terms`: a term that is still present keeps its
    /// row; a term that is new takes the row of a term that went away (an
    /// edited row keeps its id and its selection), else a fresh one.
    static func reconcile(_ rows: [DictionaryEntry], with terms: [String]) -> [DictionaryEntry] {
        var remaining = rows
        var matched: [DictionaryEntry?] = terms.map { term in
            guard let index = remaining.firstIndex(where: { $0.term == term }) else { return nil }
            return remaining.remove(at: index)
        }
        for (index, term) in terms.enumerated() where matched[index] == nil {
            matched[index] = remaining.isEmpty
                ? DictionaryEntry(term: term)
                : DictionaryEntry(id: remaining.removeFirst().id, term: term)
        }
        return matched.compactMap { $0 }
    }

    /// What the live counter shows: the last exact count while it is for
    /// the current list, else the synchronous estimate so the section never
    /// renders blank. `nil` when the resident model (or, unloaded, the
    /// default catalog entry) takes no prompt: the section says so and
    /// hides the counter.
    public var usage: DictionaryTokenUsage? {
        if let countedTerms, countedTerms == terms { return countedUsage }
        return Self.estimatedUsage(for: terms, catalogLimit: catalogPromptTokenLimit, reserveFraction: reserveFraction)
    }

    /// The prompt the model will see, for the section's preview line.
    public var promptPreview: String? {
        DictionaryPrompt.render(terms: terms)
    }

    // MARK: Editing

    /// Adds `draftTerm` (or `raw`). Refuses an empty or duplicate term and a
    /// term that would push the list over the budget; the refusal is in
    /// `message` and the draft is kept. Returns whether the term was added.
    @discardableResult
    public func add(_ raw: String? = nil) async -> Bool {
        let candidate = raw ?? draftTerm
        guard let term = DictionarySettings.normalizedTerm(candidate) else {
            message = String(localized: "Enter a term first.", bundle: .module)
            return false
        }
        guard !settings.containsTerm(term) else {
            message = String(localized: "“\(term)” is already in the dictionary.", bundle: .module)
            return false
        }
        guard await fits(terms + [term], adding: 1) else { return false }
        guard await commit(terms + [term]) else { return false }
        draftTerm = ""
        return true
    }

    /// Replaces the term of one row. An empty edit removes the row; an edit
    /// that duplicates another row or breaks the budget is refused and the
    /// row keeps its previous text.
    @discardableResult
    public func update(id: DictionaryEntry.ID, term raw: String) async -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        guard let term = DictionarySettings.normalizedTerm(raw) else {
            await remove(ids: [id])
            return true
        }
        guard term != entries[index].term else { return true }
        let others = entries.enumerated().filter { $0.offset != index }.map(\.element.term)
        guard !DictionarySettings.contains(others, term) else {
            message = String(localized: "“\(term)” is already in the dictionary.", bundle: .module)
            return false
        }
        var candidate = terms
        candidate[index] = term
        guard await fits(candidate, adding: 0) else { return false }
        return await commit(candidate)
    }

    public func remove(ids: Set<DictionaryEntry.ID>) async {
        let kept = entries.filter { !ids.contains($0.id) }.map(\.term)
        guard kept.count != terms.count else { return }
        await commit(kept)
    }

    public func removeAll() async {
        guard !terms.isEmpty else { return }
        await commit([])
    }

    // MARK: Import / Export

    /// Presents the panel and imports the file it returns.
    public func importFromPanel() async {
        guard let url = chooseImportFile() else { return }
        await importFile(at: url)
    }

    public func importFile(at url: URL) async {
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            message = String(localized: "Could not read “\(url.lastPathComponent)”. The file must be UTF-8 text with one term per line.", bundle: .module)
            return
        }
        await importTerms(from: contents)
    }

    /// Merges one-term-per-line text into the list: duplicates of existing
    /// terms are skipped, and terms past the budget are refused as a group
    /// (everything that fits, in file order, is added).
    public func importTerms(from contents: String) async {
        let incoming = DictionarySettings.parse(fileContents: contents)
        let new = incoming.filter { !settings.containsTerm($0) }
        guard !new.isEmpty else {
            message = incoming.isEmpty
                ? String(localized: "The file contains no terms.", bundle: .module)
                : String(localized: "Every term in the file is already in the dictionary.", bundle: .module)
            return
        }
        isCounting = true
        defer { isCounting = false }
        var accepted: [String] = []
        for term in new {
            let candidate = terms + accepted + [term]
            guard await usage(for: candidate).map({ !$0.isOverBudget }) ?? true else { break }
            accepted.append(term)
        }
        guard !accepted.isEmpty else {
            message = String(localized: "No term from the file fits the remaining token budget.", bundle: .module)
            return
        }
        guard await commit(terms + accepted) else { return }
        let skipped = new.count - accepted.count
        let duplicates = incoming.count - new.count
        var parts = [
            accepted.count == 1
                ? String(localized: "Imported 1 term.", bundle: .module)
                : String(localized: "Imported \(accepted.count) terms.", bundle: .module)
        ]
        if duplicates > 0 { parts.append(String(localized: "\(duplicates) already present.", bundle: .module)) }
        if skipped > 0 { parts.append(String(localized: "\(skipped) left out: they would exceed the token budget.", bundle: .module)) }
        message = parts.joined(separator: " ")
    }

    /// Presents the panel and writes the list to the file it returns.
    public func exportToPanel() {
        guard let url = chooseExportFile() else { return }
        exportFile(to: url)
    }

    public func exportFile(to url: URL) {
        do {
            try exportText.write(to: url, atomically: true, encoding: .utf8)
            message = terms.count == 1
                ? String(localized: "Exported 1 term.", bundle: .module)
                : String(localized: "Exported \(terms.count) terms.", bundle: .module)
        } catch {
            message = String(localized: "Could not write “\(url.lastPathComponent)”.", bundle: .module)
        }
    }

    /// The Export file contents: one term per line.
    public var exportText: String {
        settings.fileContents
    }

    // MARK: Counting

    /// Re-resolves the budget and the count against the resident model. The
    /// section calls it while visible (once a second) so the counter flips
    /// from ≈ to exact when the model finishes loading; assignments are
    /// equality-guarded so the poll does not re-render an unchanged section.
    public func refresh() async {
        let counted = terms
        let resolved = await usage(for: counted)
        let residentLimit = await counter?.promptTokenLimit()
        let unsupported = resolved == nil && residentLimit == .unsupported
        if countedUsage != resolved || countedTerms != counted {
            countedUsage = resolved
            countedTerms = counted
        }
        if promptUnsupported != unsupported { promptUnsupported = unsupported }
        let phrases = residentLimit?.phrases
        if phraseLimit != phrases { phraseLimit = phrases }
    }

    /// ADR-025: "12 of 100" for a phrase-list runtime; the terms past the
    /// cap are kept in the list but not sent.
    public var phraseUsage: (sent: Int, limit: Int)? {
        phraseLimit.map { (min(terms.count, $0), $0) }
    }

    /// Counts `candidate` and refuses it when over budget. A budget of `nil`
    /// (no prompt) never refuses: the list is kept for a model that will use
    /// it, and nothing is sent meanwhile.
    private func fits(_ candidate: [String], adding: Int) async -> Bool {
        isCounting = true
        defer { isCounting = false }
        guard let usage = await usage(for: candidate) else { return true }
        guard usage.isOverBudget else { return true }
        message = usage.isExact
            ? String(localized: "Adding this term would need \(usage.count) tokens; the dictionary can use \(usage.budget.budget) of the model's \(usage.budget.promptTokenLimit). Shorten or remove a term first.", bundle: .module)
            : String(localized: "Adding this term would need about \(usage.count) tokens; the dictionary can use \(usage.budget.budget) of the model's \(usage.budget.promptTokenLimit). Shorten or remove a term first.", bundle: .module)
        return false
    }

    private func usage(for candidate: [String]) async -> DictionaryTokenUsage? {
        let residentLimit = await counter?.promptTokenLimit()
        guard let budget = DictionaryTokenBudget.resolve(
            catalogLimit: catalogPromptTokenLimit,
            residentLimit: residentLimit,
            reserveFraction: reserveFraction
        ) else { return nil }
        guard let prompt = DictionaryPrompt.render(terms: candidate) else {
            return DictionaryTokenUsage(count: 0, isExact: budget.isFromResidentModel, budget: budget)
        }
        if let exact = await counter?.promptTokenCount(of: prompt) {
            return DictionaryTokenUsage(count: exact, isExact: true, budget: budget)
        }
        return DictionaryTokenUsage(
            count: DictionaryPrompt.estimatedTokenCount(of: prompt),
            isExact: false,
            budget: budget
        )
    }

    private static func estimatedUsage(for terms: [String], catalogLimit: Int?, reserveFraction: Double) -> DictionaryTokenUsage? {
        guard let budget = DictionaryTokenBudget.resolve(catalogLimit: catalogLimit, residentLimit: nil, reserveFraction: reserveFraction) else {
            return nil
        }
        let count = DictionaryPrompt.render(terms: terms).map(DictionaryPrompt.estimatedTokenCount) ?? 0
        return DictionaryTokenUsage(count: count, isExact: false, budget: budget)
    }

    /// Sends the next list as one intent. A refusal leaves the stored list
    /// (and so `entries`) untouched and puts the reducer's note in
    /// `message`; an accepted list clears the message and recounts.
    @discardableResult
    private func commit(_ next: [String]) async -> Bool {
        if let refusal = host.send(.setDictionary(DictionarySettings(terms: next), origin: .page(.dictionary))) {
            message = SettingsProjectionHost.note(for: refusal)
            return false
        }
        message = nil
        await refresh()
        return true
    }

    // MARK: Panels

    public static func presentImportPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Dictionary", bundle: .module)
        panel.message = String(localized: "Choose a plain-text file with one term per line.", bundle: .module)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .text]
        panel.prompt = String(localized: "Import", bundle: .module)
        return panel.runModal() == .OK ? panel.url : nil
    }

    public static func presentExportPanel() -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Dictionary", bundle: .module)
        panel.message = String(localized: "The dictionary is written as plain text, one term per line.", bundle: .module)
        panel.nameFieldStringValue = "kvoice-dictionary.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export", bundle: .module)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
