import Foundation
import XCTest
import KvoiceAppCore
@testable import KvoiceDomain
@testable import KvoiceUI

/// ADR-018: the Dictionary section's view model against a fake tokenizer —
/// a projection over the settings coordinator (ADR-022 slice 7), so every
/// edit is a `.setDictionary` intent and the list the table shows is always
/// the stored one.
@MainActor
final class DictionaryViewModelTests: XCTestCase {
    private var harness = SettingsProjectionTestHarness()

    /// The `.setDictionary` lists the model sent, in order.
    private var emitted: [DictionarySettings] {
        harness.sent.compactMap { intent in
            if case .setDictionary(let settings, _) = intent { return settings }
            return nil
        }
    }

    /// One token per whitespace-separated word, so counts are predictable:
    /// "Glossary: a, b." is three tokens. Limit 10 → reserve 1 → budget 9.
    private func makeModel(
        terms: [String] = [],
        counter: WordCounter? = WordCounter(limit: .tokens(10)),
        catalogLimit: Int? = 224
    ) -> DictionaryViewModel {
        harness = SettingsProjectionTestHarness(settings: AppSettings(dictionary: DictionarySettings(terms: terms)))
        return DictionaryViewModel(
            host: harness.host,
            counter: counter,
            catalogPromptTokenLimit: catalogLimit
        )
    }

    func testAddTrimsDeduplicatesRefusesEmptyAndSendsTheList() async {
        let model = makeModel()

        let added = await model.add("  kvoice ")
        XCTAssertTrue(added)
        XCTAssertEqual(model.terms, ["kvoice"])
        XCTAssertEqual(harness.sent, [.setDictionary(DictionarySettings(terms: ["kvoice"]), origin: .page(.dictionary))])
        XCTAssertEqual(harness.settings.dictionary.terms, ["kvoice"])
        XCTAssertEqual(harness.effects, [.persist])
        XCTAssertNil(model.message)

        let duplicate = await model.add("KVOICE")
        XCTAssertFalse(duplicate)
        XCTAssertEqual(model.message, "“KVOICE” is already in the dictionary.")

        model.draftTerm = "   "
        let empty = await model.add()
        XCTAssertFalse(empty)
        XCTAssertEqual(model.message, "Enter a term first.")
        XCTAssertEqual(emitted.count, 1, "refusals emit nothing")

        model.draftTerm = "Cosima"
        let fromDraft = await model.add()
        XCTAssertTrue(fromDraft)
        XCTAssertEqual(model.draftTerm, "", "an accepted draft is cleared")
        XCTAssertEqual(emitted.last?.terms, ["kvoice", "Cosima"])
    }

    func testAddIsRefusedExactlyPastTheBudgetAndTheListIsAlwaysCountedWhole() async {
        // Budget 9 with the word counter: "Glossary:" + 8 one-word terms = 9.
        let model = makeModel(terms: ["a", "b", "c", "d", "e", "f", "g"])
        await model.refresh()
        XCTAssertEqual(model.usage?.count, 8)
        XCTAssertEqual(model.usage?.budget.budget, 9)
        XCTAssertEqual(model.usage?.isExact, true)

        let atBoundary = await model.add("h")
        XCTAssertTrue(atBoundary, "exactly the budget is allowed")
        XCTAssertEqual(model.usage?.count, 9)
        XCTAssertEqual(model.usage?.isNearBudget, true)
        XCTAssertEqual(model.usage?.isOverBudget, false)
        XCTAssertEqual(model.usage?.label, "9 / 9 tokens")

        model.draftTerm = "i"
        let pastBoundary = await model.add()
        XCTAssertFalse(pastBoundary)
        XCTAssertEqual(model.terms.count, 8, "the list is unchanged")
        XCTAssertEqual(model.draftTerm, "i", "the refused draft is kept")
        XCTAssertEqual(
            model.message,
            "Adding this term would need 10 tokens; the dictionary can use 9 of the model's 10. Shorten or remove a term first."
        )
    }

    func testEstimateStandsInUntilTheModelIsResidentThenTheExactCountTakesOver() async {
        let counter = WordCounter(limit: nil) // nothing loaded yet
        let model = makeModel(terms: ["kvoice", "WhisperKit"], counter: counter, catalogLimit: 224)
        await model.refresh()

        let estimate = model.usage
        XCTAssertEqual(estimate?.isExact, false)
        XCTAssertEqual(estimate?.budget, DictionaryTokenBudget(promptTokenLimit: 224, isFromResidentModel: false))
        // "Glossary: kvoice, WhisperKit." is 29 Latin characters → 8.
        XCTAssertEqual(estimate?.count, DictionaryPrompt.estimatedTokenCount(of: "Glossary: kvoice, WhisperKit."))
        XCTAssertEqual(estimate?.count, 8)
        XCTAssertEqual(estimate?.label, "≈ 8 / 201 tokens")
        XCTAssertFalse(model.promptUnsupported)

        counter.limit = .tokens(111)
        await model.refresh()
        XCTAssertEqual(model.usage, DictionaryTokenUsage(
            count: 3,
            isExact: true,
            budget: DictionaryTokenBudget(promptTokenLimit: 111, isFromResidentModel: true)
        ))
        XCTAssertEqual(model.usage?.label, "3 / 99 tokens")
    }

    func testUnsupportedModelHidesTheCounterKeepsTheListAndNeverRefuses() async {
        let model = makeModel(terms: ["kvoice"], counter: WordCounter(limit: .unsupported))
        await model.refresh()

        XCTAssertNil(model.usage)
        XCTAssertTrue(model.promptUnsupported)
        XCTAssertEqual(model.terms, ["kvoice"], "the list is kept for a model that takes a prompt")
        let added = await model.add("anything at all goes here because nothing is sent")
        XCTAssertTrue(added)
        XCTAssertEqual(emitted.count, 1)

        // A catalog entry without a limit while nothing is loaded is also "no prompt",
        // but not confirmed by a model.
        let unknown = makeModel(terms: [], counter: WordCounter(limit: nil), catalogLimit: nil)
        await unknown.refresh()
        XCTAssertNil(unknown.usage)
        XCTAssertFalse(unknown.promptUnsupported)
    }

    /// ADR-019: a Parakeet default has no catalog limit and, once resident,
    /// reports `.unsupported` — the section shows its "no dictionary" state
    /// and keeps the list for a Whisper model.
    func testAParakeetDefaultShowsTheUnsupportedStateOnceResident() async {
        let counter = WordCounter(limit: nil)
        let model = makeModel(terms: ["kvoice"], counter: counter, catalogLimit: nil)
        await model.refresh()
        XCTAssertNil(model.usage, "no catalog limit and nothing resident: no counter yet")
        XCTAssertFalse(model.promptUnsupported)

        counter.limit = .unsupported
        await model.refresh()
        XCTAssertNil(model.usage)
        XCTAssertTrue(model.promptUnsupported)
        XCTAssertEqual(model.terms, ["kvoice"])

        // Switching the default back to Whisper (catalog 224, engine 111)
        // brings the counter back without touching the list.
        model.catalogPromptTokenLimit = 224
        counter.limit = .tokens(111)
        await model.refresh()
        XCTAssertFalse(model.promptUnsupported)
        XCTAssertEqual(model.usage?.budget, DictionaryTokenBudget(promptTokenLimit: 111, isFromResidentModel: true))
    }

    func testAShrunkBudgetFlagsTheListInsteadOfTruncatingIt() async {
        let counter = WordCounter(limit: .tokens(100))
        let model = makeModel(terms: ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"], counter: counter)
        await model.refresh()
        XCTAssertEqual(model.usage?.isOverBudget, false)

        // The default model changed to one whose runtime allows 5 prompt tokens.
        counter.limit = .tokens(5)
        await model.refresh()
        XCTAssertEqual(model.usage?.isOverBudget, true)
        XCTAssertEqual(model.usage?.fraction, 1, "the bar is full, not broken")
        XCTAssertEqual(model.terms.count, 10, "nothing is removed for the user")

        let added = await model.add("k")
        XCTAssertFalse(added, "but nothing more is accepted")
        let removed: Void = await model.remove(ids: Set(model.entries.prefix(9).map(\.id)))
        _ = removed
        XCTAssertEqual(model.terms, ["j"])
        XCTAssertEqual(model.usage?.isOverBudget, false)
    }

    func testUpdateEditsRemovesOnEmptyAndRefusesDuplicatesAndOverBudget() async {
        let model = makeModel(terms: ["kvoice", "Cosima"])
        let first = model.entries[0].id

        let renamed = await model.update(id: first, term: "  Kvoice  ")
        XCTAssertTrue(renamed)
        XCTAssertEqual(model.terms, ["Kvoice", "Cosima"])
        XCTAssertEqual(model.entries[0].id, first, "an edited row keeps its identity")

        let duplicate = await model.update(id: first, term: "cosima")
        XCTAssertFalse(duplicate)
        XCTAssertEqual(model.terms, ["Kvoice", "Cosima"], "the row keeps its text")

        let tooLong = await model.update(id: first, term: "one two three four five six seven eight nine")
        XCTAssertFalse(tooLong)
        XCTAssertNotNil(model.message)

        let unchanged = await model.update(id: first, term: "Kvoice")
        XCTAssertTrue(unchanged)

        let cleared = await model.update(id: first, term: "")
        XCTAssertTrue(cleared)
        XCTAssertEqual(model.terms, ["Cosima"], "an emptied row is removed")
        XCTAssertEqual(emitted.map(\.terms), [["Kvoice", "Cosima"], ["Cosima"]])
    }

    func testImportExportRoundTripSkipsDuplicatesAndStopsAtTheBudget() async throws {
        let model = makeModel(terms: ["kvoice"])

        await model.importTerms(from: "KVOICE\nWhisperKit\n\n  Cosima  \nAlpha\nBeta\nGamma\nDelta\nEpsilon\nZeta\n")
        // Budget 9 = "Glossary:" + 8 terms: kvoice + 7 imported; Zeta is left out.
        XCTAssertEqual(model.terms, ["kvoice", "WhisperKit", "Cosima", "Alpha", "Beta", "Gamma", "Delta", "Epsilon"])
        XCTAssertEqual(model.message, "Imported 7 terms. 1 already present. 1 left out: they would exceed the token budget.")
        XCTAssertEqual(emitted.count, 1)

        XCTAssertEqual(model.exportText, "kvoice\nWhisperKit\nCosima\nAlpha\nBeta\nGamma\nDelta\nEpsilon\n")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("dictionary.txt")

        model.chooseExportFile = { file }
        model.exportToPanel()
        XCTAssertEqual(model.message, "Exported 8 terms.")

        let exportedTerms = model.terms
        let reimport = makeModel(counter: WordCounter(limit: .tokens(224)))
        reimport.chooseImportFile = { file }
        await reimport.importFromPanel()
        XCTAssertEqual(reimport.terms, exportedTerms, "export → import round-trips")
        XCTAssertEqual(reimport.message, "Imported 8 terms.")

        await reimport.importTerms(from: "\n\n")
        XCTAssertEqual(reimport.message, "The file contains no terms.")
        await reimport.importTerms(from: "kvoice\n")
        XCTAssertEqual(reimport.message, "Every term in the file is already in the dictionary.")

        let cancelled = makeModel()
        cancelled.chooseImportFile = { nil }
        await cancelled.importFromPanel()
        XCTAssertTrue(cancelled.terms.isEmpty)
        XCTAssertNil(cancelled.message, "a cancelled panel is not an error")
    }

    func testAChangeFromAnotherDoorShowsWithoutHydrationAndKeepsRowIdentity() async {
        let model = makeModel(terms: ["kvoice", "Cosima"])
        let cosimaID = model.entries[1].id

        harness.commitFromElsewhere(.setDictionary(DictionarySettings(terms: ["Cosima", "WhisperKit"]), origin: .import))
        XCTAssertEqual(model.terms, ["Cosima", "WhisperKit"])
        XCTAssertEqual(model.entries[0].id, cosimaID, "a surviving term keeps its row so a selection survives")
        XCTAssertTrue(harness.sent.isEmpty, "a change from elsewhere is not an edit")
        XCTAssertEqual(model.promptPreview, "Glossary: Cosima, WhisperKit.")
        XCTAssertEqual(model.usage?.isExact, false, "the exact count was for the old list; the estimate stands in until refresh")
        await model.refresh()
        XCTAssertEqual(model.usage?.isExact, true)

        harness.commitFromElsewhere(.setDictionary(DictionarySettings(), origin: .import))
        XCTAssertNil(model.promptPreview)
        XCTAssertEqual(model.usage?.count, 0)
    }

    /// ADR-018 under the reducer's idle gate: a running job keeps the list
    /// it started with, so an edit mid-job is refused — the table keeps the
    /// stored list, the note is shown, and the add field keeps its draft.
    func testARefusalKeepsTheStoredListShowsTheNoteAndKeepsTheDraft() async {
        let model = makeModel(terms: ["kvoice"])
        harness.startJob()

        model.draftTerm = "mid-job"
        let added = await model.add()
        XCTAssertFalse(added)
        XCTAssertEqual(model.terms, ["kvoice"])
        XCTAssertEqual(model.draftTerm, "mid-job", "the draft is kept for a retry")
        XCTAssertEqual(model.message, "Finish the current dictation first — a running dictation keeps the list it started with.")
        XCTAssertEqual(harness.sent.count, 1, "the intent was sent and refused by the reducer")
        XCTAssertTrue(harness.effects.isEmpty)

        let removed: Void = await model.removeAll()
        _ = removed
        XCTAssertEqual(model.terms, ["kvoice"])

        harness.endJob()
        let retried = await model.add()
        XCTAssertTrue(retried)
        XCTAssertEqual(model.terms, ["kvoice", "mid-job"])
        XCTAssertNil(model.message)
        XCTAssertEqual(model.draftTerm, "")
    }

    func testRowReconciliationKeepsSurvivingAndEditedRows() {
        let a = DictionaryEntry(term: "a")
        let b = DictionaryEntry(term: "b")
        let c = DictionaryEntry(term: "c")

        let edited = DictionaryViewModel.reconcile([a, b, c], with: ["a", "B", "c"])
        XCTAssertEqual(edited.map(\.id), [a.id, b.id, c.id], "an edited term takes the row that went away")
        XCTAssertEqual(edited.map(\.term), ["a", "B", "c"])

        let reordered = DictionaryViewModel.reconcile([a, b, c], with: ["c", "a"])
        XCTAssertEqual(reordered.map(\.id), [c.id, a.id])

        let grown = DictionaryViewModel.reconcile([a], with: ["a", "d"])
        XCTAssertEqual(grown[0].id, a.id)
        XCTAssertNotEqual(grown[1].id, a.id, "a genuinely new term gets a fresh row")
        XCTAssertTrue(DictionaryViewModel.reconcile([], with: []).isEmpty)
    }
}

/// A `PromptTokenCounting` that counts whitespace-separated words and lets a
/// test move the "resident model" between nothing, a limit, and unsupported.
@MainActor
private final class WordCounter: PromptTokenCounting {
    var limit: PromptTokenLimit?

    init(limit: PromptTokenLimit?) {
        self.limit = limit
    }

    nonisolated func promptTokenLimit() async -> PromptTokenLimit? {
        await limit
    }

    nonisolated func promptTokenCount(of text: String) async -> Int? {
        guard await limit?.tokens != nil else { return nil }
        return text.split(whereSeparator: \.isWhitespace).count
    }
}
