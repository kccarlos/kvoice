import Foundation
import XCTest
import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceAppCore

/// The history write path with the History and data additions: opt-in stored
/// audio (decision #1), the recording/AI durations on the row, and the
/// append observer that feeds Auto Daily Export.
final class DictationControllerHistoryDataTests: XCTestCase {
    private let target = TargetApplicationSnapshot(
        processIdentifier: 42,
        bundleIdentifier: "com.example.editor",
        localizedName: "Editor",
        capturedAt: Date()
    )

    func testAudioIsStoredOnlyWhenOptedInAndTheRowCarriesThePath() async {
        let history = InMemoryHistoryRepository()
        let audioStore = SpyAudioStore()
        let recording = AudioRecording(
            samples: ContiguousArray(repeating: 0.2, count: 32_000),
            duration: .seconds(2),
            peakLevelDBFS: -10,
            clippedFrameCount: 0
        )
        let controller = DictationController(
            audio: FakeAudioCaptureService(recording: recording),
            transcription: FakeTranscriptionEngine(result: transcript("kept audio")),
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: AppSettings(
                historyEnabled: true,
                audioStorage: AudioStorageSettings(keepRecordings: true, retentionDays: 7)
            )),
            history: history
        )
        await controller.setHistoryAudioStore(audioStore)

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let entries = await history.entries
        XCTAssertEqual(entries.count, 1)
        let stored = await audioStore.stored
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.entryID, entries.first?.id, "the file is keyed by the row's id")
        XCTAssertEqual(stored.first?.recording, recording, "the exact recording that was transcribed")
        XCTAssertEqual(entries.first?.audioPath, "Audio/\(entries.first!.id.uuidString).wav")
        XCTAssertEqual(entries.first?.recordingDurationMilliseconds, 2_000)
        XCTAssertNil(entries.first?.aiDurationMilliseconds, "AI was off")
    }

    func testAudioIsNotStoredByDefault() async {
        let history = InMemoryHistoryRepository()
        let audioStore = SpyAudioStore()
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("no audio")),
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: AppSettings(historyEnabled: true)),
            history: history
        )
        await controller.setHistoryAudioStore(audioStore)

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let entries = await history.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries.first?.audioPath)
        let stored = await audioStore.stored
        XCTAssertTrue(stored.isEmpty, "off by default: nothing is written")
        XCTAssertNotNil(entries.first?.recordingDurationMilliseconds, "the duration is a scalar and is always kept")
    }

    func testAudioStoreFailureStillWritesTheRowWithoutAudio() async {
        let history = InMemoryHistoryRepository()
        let audioStore = SpyAudioStore(failure: KVoiceError(code: .historyWriteFailed))
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("row survives")),
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: AppSettings(
                historyEnabled: true,
                audioStorage: AudioStorageSettings(keepRecordings: true)
            )),
            history: history
        )
        await controller.setHistoryAudioStore(audioStore)

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let entries = await history.entries
        XCTAssertEqual(entries.map(\.rawText), ["row survives"])
        XCTAssertNil(entries.first?.audioPath)
    }

    func testAIDurationIsRecordedOnSuccessAndObserverSeesTheRow() async {
        let history = InMemoryHistoryRepository()
        let observed = ObservedEntries()
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("raw words")),
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: AppSettings(
                ai: AIEndpointSettings(
                    mode: .polish,
                    baseURL: URL(string: "http://127.0.0.1:11434/v1"),
                    modelID: "fixture-model"
                ),
                historyEnabled: true
            )),
            ai: FakeAIProcessingClient(
                result: AIProcessResult(text: "Polished words.", requestDuration: .milliseconds(1_250), responseID: nil)
            ),
            history: history
        )
        await controller.setHistoryAppendObserver { entry in
            await observed.record(entry)
        }

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let entries = await history.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.aiStatus, .succeeded)
        XCTAssertEqual(entries.first?.aiDurationMilliseconds, 1_250)
        XCTAssertTrue(entries.first?.hasDistinctEnhancedText ?? false)
        let seen = await observed.entries
        XCTAssertEqual(seen, entries, "the observer receives exactly the committed row")
    }

    /// The onboarding test field writes no history row, so it must not
    /// leave a WAV on disk either, even with stored audio opted in.
    func testInAppDeliveryStoresNoAudioAndNoRow() async {
        let history = InMemoryHistoryRepository()
        let audioStore = SpyAudioStore()
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("test phrase")),
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: AppSettings(
                historyEnabled: true,
                audioStorage: AudioStorageSettings(keepRecordings: true)
            )),
            history: history
        )
        await controller.setHistoryAudioStore(audioStore)

        let state = await controller.startRecording(delivery: .inApp)
        XCTAssertEqual(state.kind, .recording)
        _ = await controller.stopRecording()
        await controller.waitForCompletion()

        let delivered = await controller.inAppDeliveredText
        XCTAssertEqual(delivered?.text, "test phrase")
        let entries = await history.entries
        XCTAssertTrue(entries.isEmpty, "the in-app test never writes history")
        let stored = await audioStore.stored
        XCTAssertTrue(stored.isEmpty, "no row, no recording")
    }

    /// The WAV is written before the row so a row never points at a missing
    /// file; the converse must hold too — a row that fails to append must
    /// not leave an orphan recording behind.
    func testFailedRowAppendRemovesTheJustWrittenAudio() async {
        let history = FailingHistoryRepository()
        let audioStore = SpyAudioStore()
        let controller = DictationController(
            audio: FakeAudioCaptureService(),
            transcription: FakeTranscriptionEngine(result: transcript("lost row")),
            insertion: FakeTextInsertionService(target: target),
            settings: FakeSettingsRepository(settings: AppSettings(
                historyEnabled: true,
                audioStorage: AudioStorageSettings(keepRecordings: true)
            )),
            history: history
        )
        await controller.setHistoryAudioStore(audioStore)

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let attempts = await history.appendAttempts
        XCTAssertEqual(attempts, 1)
        let written = await audioStore.storeCalls
        XCTAssertEqual(written, 1, "the file was written first")
        let stored = await audioStore.stored
        XCTAssertTrue(stored.isEmpty, "and removed again when the row failed")
        let state = await controller.state
        XCTAssertEqual(state.kind, .completed, "history is best effort; the dictation still completed")
    }

    // MARK: Helpers

    private func transcript(_ text: String) -> TranscriptionResult {
        let now = ContinuousClock().now
        return TranscriptionResult(
            text: text,
            detectedLanguage: nil,
            segments: [],
            timings: TranscriptionTimings(
                requestStart: now,
                inferenceStart: now,
                inferenceEnd: now,
                runtimeReportedRealTimeFactor: nil
            ),
            modelID: "fixture"
        )
    }
}

private actor SpyAudioStore: HistoryAudioStoring {
    struct Stored: Equatable {
        let entryID: HistoryEntryID
        let recording: AudioRecording
    }

    private(set) var stored: [Stored] = []
    private(set) var storeCalls = 0
    private let failure: KVoiceError?

    init(failure: KVoiceError? = nil) {
        self.failure = failure
    }

    func store(_ recording: AudioRecording, for entryID: HistoryEntryID) throws -> String {
        storeCalls += 1
        if let failure { throw failure }
        stored.append(Stored(entryID: entryID, recording: recording))
        return "Audio/\(entryID.uuidString).wav"
    }

    nonisolated func fileURL(forRelativePath path: String) -> URL {
        URL(fileURLWithPath: "/tmp/kvoice-test-history").appendingPathComponent(path)
    }

    func exists(relativePath path: String) -> Bool {
        stored.contains { "Audio/\($0.entryID.uuidString).wav" == path }
    }

    func delete(relativePath path: String) throws {
        stored.removeAll { "Audio/\($0.entryID.uuidString).wav" == path }
    }

    func deleteAll() throws {
        stored.removeAll()
    }

    func totalSizeBytes() throws -> Int64 {
        0
    }
}

/// Every append fails, as a full disk or a degraded store would.
private actor FailingHistoryRepository: HistoryRepository {
    private(set) var appendAttempts = 0

    func migrateIfNeeded() throws {}
    func append(_: HistoryEntry) throws {
        appendAttempts += 1
        throw KVoiceError(code: .historyWriteFailed)
    }
    func fetchPage(before _: Date?, limit _: Int) throws -> [HistoryEntry] { [] }
    func delete(id _: HistoryEntryID) throws {}
    func deleteAll() throws {}
    func count() throws -> Int { 0 }
    func storageSizeBytes() throws -> Int64 { 0 }
    func search(_: String, limit _: Int) throws -> [HistoryEntry] { [] }
}

private actor ObservedEntries {
    private(set) var entries: [HistoryEntry] = []

    func record(_ entry: HistoryEntry) {
        entries.append(entry)
    }
}
