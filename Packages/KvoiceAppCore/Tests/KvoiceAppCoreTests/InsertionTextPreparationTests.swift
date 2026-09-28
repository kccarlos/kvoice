import Foundation
import XCTest
import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceAppCore

/// The Manage Models insertion options (`addSpaceAfterInsertion`,
/// `automaticTextFormatting`) were stored since the speech-models workstream
/// but never applied; these pin the seam where they now take effect.
final class InsertionTextPreparationTests: XCTestCase {
    private let target = TargetApplicationSnapshot(
        processIdentifier: 7,
        bundleIdentifier: "com.apple.TextEdit",
        localizedName: "TextEdit",
        capturedAt: Date(timeIntervalSince1970: 1)
    )

    // MARK: Pure preparation

    func testDefaultsLeaveTextUntouched() {
        XCTAssertEqual(
            InsertionTextPreparation.prepare("  hello   world\n", settings: AppSettings()),
            "  hello   world\n"
        )
    }

    func testTrailingSpaceIsAppendedOnceAndNeverToEmptyText() {
        var settings = AppSettings()
        settings.addSpaceAfterInsertion = true
        XCTAssertEqual(InsertionTextPreparation.prepare("hello", settings: settings), "hello ")
        XCTAssertEqual(InsertionTextPreparation.prepare("hello ", settings: settings), "hello ")
        XCTAssertEqual(InsertionTextPreparation.prepare("hello\n", settings: settings), "hello\n")
        XCTAssertEqual(InsertionTextPreparation.prepare("", settings: settings), "")
    }

    func testFormattingNormalisesWhitespaceOnly() {
        var settings = AppSettings()
        settings.automaticTextFormatting = true
        XCTAssertEqual(
            InsertionTextPreparation.prepare("  hello   world\tagain ", settings: settings),
            "hello world again"
        )
        // Newlines survive (the typed tier flattens them itself); a command
        // for a terminal keeps its case and gains no trailing period.
        XCTAssertEqual(
            InsertionTextPreparation.prepare("ls -la\ncd ..", settings: settings),
            "ls -la\ncd .."
        )
        XCTAssertEqual(InsertionTextPreparation.prepare("谢谢", settings: settings), "谢谢")
        XCTAssertEqual(InsertionTextPreparation.prepare("   ", settings: settings), "")
    }

    func testFormattingRunsBeforeTheTrailingSpace() {
        var settings = AppSettings()
        settings.automaticTextFormatting = true
        settings.addSpaceAfterInsertion = true
        XCTAssertEqual(InsertionTextPreparation.prepare(" hello ", settings: settings), "hello ")
    }

    // MARK: Controller seam

    func testOptionsShapeTheInsertedTextButNotTheHistoryRow() async {
        var settings = AppSettings(historyEnabled: true)
        settings.addSpaceAfterInsertion = true
        settings.automaticTextFormatting = true
        let insertion = FakeTextInsertionService(target: target)
        let history = InMemoryHistoryRepository()
        let controller = DictationController(
            audio: FakeAudioCaptureService(recording: recording(peak: -10)),
            transcription: FakeTranscriptionEngine(result: transcript("hello  there")),
            insertion: insertion,
            settings: FakeSettingsRepository(settings: settings),
            history: history
        )

        _ = await controller.handleShortcut(.keyDown, mode: .pushToTalk)
        _ = await controller.handleShortcut(.keyUp, mode: .pushToTalk)
        await controller.waitForCompletion()

        let inserted = await insertion.insertedTexts
        XCTAssertEqual(inserted, ["hello there "])
        let entries = await history.entries
        XCTAssertEqual(entries.map(\.finalText), ["hello  there"])
        let fallback = await controller.exactFinalTextForFallback
        XCTAssertEqual(fallback, "hello  there", "Use Raw Transcript Now keeps the verbatim text")
    }

    // MARK: Helpers

    private func recording(peak: Float) -> AudioRecording {
        AudioRecording(
            samples: ContiguousArray(repeating: 0.01, count: 16_000),
            duration: .seconds(1),
            peakLevelDBFS: peak,
            clippedFrameCount: 0
        )
    }

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
