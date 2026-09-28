import Foundation
import XCTest
import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceAppCore

/// The Selection Action pipeline with fakes: slot → selection → request →
/// insertion, and every way it declines to run.
final class SelectionActionRunnerTests: XCTestCase {
    private let target = TargetApplicationSnapshot(
        processIdentifier: 7,
        bundleIdentifier: "com.example.editor",
        localizedName: "Editor",
        capturedAt: Date(timeIntervalSince1970: 100)
    )

    private func settings(bindSlot slot: Int? = 0, isEnabled: Bool = false, endpoint: Bool = true) -> AppSettings {
        var ai = AIEndpointSettings(
            baseURL: endpoint ? URL(string: "https://provider.example/v1") : nil,
            modelID: endpoint ? "fixture-model" : "",
            isEnabled: isEnabled
        )
        ai.seedBuiltInPromptModesIfNeeded()
        ai.userProfile = "Role: tester"
        if let slot {
            ai.bindSelectionAction(ai.promptModes.first { $0.builtInKey == BuiltInPromptModes.Key.summarize }!.id, slot: slot)
        }
        return AppSettings(ai: ai)
    }

    private func makeRunner(
        settings: AppSettings,
        ai: FakeAIProcessingClient = FakeAIProcessingClient(
            result: AIProcessResult(text: "- summary", requestDuration: .milliseconds(5), responseID: nil)
        ),
        insertion: FakeTextInsertionService? = nil,
        selection: String? = "some selected words",
        clipboard: String? = nil
    ) -> (SelectionActionRunner, FakeAIProcessingClient, FakeTextInsertionService) {
        let insertionService = insertion ?? FakeTextInsertionService(target: target)
        let runner = SelectionActionRunner(
            settingsRepository: FakeSettingsRepository(settings: settings),
            secretsRepository: FakeSecretsRepository(settings: SecretSettings(apiKey: "fixture-secret")),
            aiClient: ai,
            insertionService: insertionService,
            selectionReader: StubSelectionReader(selection: selection),
            contextProvider: StubContextProvider(clipboard: clipboard, selection: selection)
        )
        return (runner, ai, insertionService)
    }

    func testRunsTheBoundActionOnTheSelectionAndInsertsTheResult() async {
        let (runner, ai, insertion) = makeRunner(settings: settings())

        let outcome = await runner.run(slot: 0)

        XCTAssertEqual(outcome, .inserted(.inserted(method: .selectedTextAttribute)))
        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["- summary"])
        let requests = await ai.receivedRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.rawTranscript, "some selected words")
        XCTAssertEqual(requests.first?.mode, .polish)
        XCTAssertEqual(requests.first?.context.userProfile, "Role: tester")
        XCTAssertNil(requests.first?.context.selectedText, "the selection is the transcript, not context")
        XCTAssertTrue(
            requests.first?.polishPrompt.contains("Summarizer") ?? false,
            "the slot's action prompt is what runs"
        )
        let clipboard = await insertion.clipboardTexts
        XCTAssertTrue(clipboard.isEmpty, "never the pasteboard on success")
    }

    func testRunsEvenWhenTheMasterSwitchIsOff() async {
        let (runner, _, insertion) = makeRunner(settings: settings(isEnabled: false))
        _ = await runner.run(slot: 0)
        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted.count, 1, "the shortcut is an explicit request; the switch governs auto-apply only")
    }

    func testDeclinesWithoutASlotBindingEndpointSelectionOrTarget() async {
        let (unbound, _, _) = makeRunner(settings: settings(bindSlot: nil))
        let noAction = await unbound.run(slot: 0)
        XCTAssertEqual(noAction, .noAction)

        let (other, _, _) = makeRunner(settings: settings(bindSlot: 2))
        let wrongSlot = await other.run(slot: 0)
        XCTAssertEqual(wrongSlot, .noAction)

        let (unconfigured, ai, _) = makeRunner(settings: settings(endpoint: false))
        let notConfigured = await unconfigured.run(slot: 0)
        XCTAssertEqual(notConfigured, .notConfigured)
        let requests = await ai.receivedRequests
        XCTAssertTrue(requests.isEmpty)

        let (nothingSelected, _, _) = makeRunner(settings: settings(), selection: nil)
        let noSelection = await nothingSelected.run(slot: 0)
        XCTAssertEqual(noSelection, .noSelection)

        let (noFront, _, _) = makeRunner(settings: settings(), insertion: FakeTextInsertionService(target: nil))
        let noTarget = await noFront.run(slot: 0)
        XCTAssertEqual(noTarget, .noTarget)
    }

    func testAIFailureInsertsNothing() async {
        let (runner, _, insertion) = makeRunner(
            settings: settings(),
            ai: FakeAIProcessingClient(failure: KVoiceError(code: .aiAuthentication))
        )
        let outcome = await runner.run(slot: 0)
        XCTAssertEqual(outcome, .failed(.aiAuthentication))
        let inserted = await insertion.insertedTexts
        XCTAssertTrue(inserted.isEmpty)
        let clipboard = await insertion.clipboardTexts
        XCTAssertTrue(clipboard.isEmpty)
    }

    func testClipboardContextIsAttachedOnlyWhenTheActionOptedIn() async {
        var settings = settings()
        let index = settings.ai.promptModes.firstIndex { $0.builtInKey == BuiltInPromptModes.Key.summarize }!
        settings.ai.promptModes[index].includesClipboardText = true
        let (runner, ai, _) = makeRunner(settings: settings, clipboard: "copied text")

        _ = await runner.run(slot: 0)

        let requests = await ai.receivedRequests
        XCTAssertEqual(requests.first?.context.clipboardText, "copied text")

        let (plain, plainAI, _) = makeRunner(settings: self.settings(), clipboard: "copied text")
        _ = await plain.run(slot: 0)
        let plainRequests = await plainAI.receivedRequests
        XCTAssertNil(plainRequests.first?.context.clipboardText)
    }

    func testASecondPressWhileRunningIsRefused() async {
        let waiting = WaitingAI()
        let runner = SelectionActionRunner(
            settingsRepository: FakeSettingsRepository(settings: settings()),
            aiClient: waiting,
            insertionService: FakeTextInsertionService(target: target),
            selectionReader: StubSelectionReader(selection: "text")
        )
        let first = Task { await runner.run(slot: 0) }
        await waiting.waitUntilStarted()
        let second = await runner.run(slot: 0)
        XCTAssertEqual(second, .busy)
        await waiting.release()
        _ = await first.value
    }

    // MARK: HUD copy

    /// The shell shows every outcome in the HUD; a plain insertion needs no
    /// sentence, every refusal does, and codes reuse the dictation catalog
    /// so the same failure reads the same in both places.
    func testOutcomeCopyDistinguishesSuccessFallbackAndRefusals() {
        XCTAssertNil(SelectionActionRunner.Outcome.inserted(.inserted(method: .selectedTextAttribute)).userFacingMessage)
        XCTAssertTrue(SelectionActionRunner.Outcome.inserted(.inserted(method: .selectedTextAttribute)).isSuccess)

        let fallback = SelectionActionRunner.Outcome.inserted(.copiedToClipboard(reason: .notEditable))
        XCTAssertEqual(fallback.userFacingMessage, KVoiceErrorCode.accessibilityNotEditable.userFacingMessage)
        XCTAssertTrue(fallback.isSuccess)

        XCTAssertFalse(SelectionActionRunner.Outcome.inserted(.abortedAtTermination).isSuccess)
        for refusal in [SelectionActionRunner.Outcome.noAction, .notConfigured, .noSelection, .noTarget, .busy] {
            XCTAssertFalse(refusal.isSuccess)
            XCTAssertFalse(refusal.userFacingMessage?.isEmpty ?? true, "\(refusal) needs a sentence")
        }
        XCTAssertEqual(
            SelectionActionRunner.Outcome.failed(.aiTimeout).userFacingMessage,
            KVoiceErrorCode.aiTimeout.userFacingMessage
        )
    }
}

private struct StubSelectionReader: SelectionReading {
    let selection: String?
    func readFocusedSelection() async -> String? { selection }
}

private struct StubContextProvider: AIContextProviding {
    let clipboard: String?
    let selection: String?
    func clipboardText() async -> String? { clipboard }
    func selectedText() async -> String? { selection }
}

private actor WaitingAI: AIProcessingClient {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func validateConfiguration(_: AIEndpointSettings) throws {}

    func process(_: AIProcessRequest, settings _: AIEndpointSettings) async throws -> AIProcessResult {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return AIProcessResult(text: "done", requestDuration: .zero, responseID: nil)
    }

    func testConfiguration(_: AIEndpointSettings) async throws {}
    func cancel(jobID _: JobID) async {}

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
