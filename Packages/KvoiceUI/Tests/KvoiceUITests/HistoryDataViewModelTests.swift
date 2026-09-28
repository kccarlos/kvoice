import AVFoundation
import Foundation
import XCTest
@testable import KvoiceDomain
@testable import KvoiceUI

/// The History and data additions to `HistoryViewModel`: dashboard figures,
/// combined filters, bulk delete, export files, stored audio, Retranscribe,
/// and Transcribe File.
@MainActor
final class HistoryDataViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Dashboard

    func testDashboardDerivesRatesFromTheAggregates() async {
        let entries = [
            HistoryEntry(
                createdAt: now.addingTimeInterval(-10),
                rawText: "one two three four five six",
                finalText: "one two three four five six seven eight",
                mode: .polish,
                insertionOutcome: .inserted(method: .selectedTextAttribute),
                aiStatus: .succeeded,
                recordingDurationMilliseconds: 30_000,
                aiDurationMilliseconds: 2_000
            ),
            HistoryEntry(
                createdAt: now.addingTimeInterval(-20),
                rawText: "nine ten",
                finalText: "nine ten",
                mode: .off,
                insertionOutcome: .inserted(method: .selectedTextAttribute),
                recordingDurationMilliseconds: 30_000
            )
        ]
        let model = HistoryViewModel(repository: TestHistoryRepository(entries: entries), now: { [now] in now })

        await model.load()

        let dashboard = model.dashboard
        XCTAssertEqual(dashboard.sessions, 2)
        XCTAssertEqual(dashboard.words, 10)
        XCTAssertEqual(dashboard.wordsPerMinute, 10, "10 words in one minute of recording")
        XCTAssertEqual(dashboard.keystrokesSaved, "one two three four five six seven eight".count + "nine ten".count)
        XCTAssertEqual(dashboard.averageAIMilliseconds, 2_000)
        // 10 words at 40 wpm is 15 s of typing, minus 60 s of recording: never negative.
        XCTAssertEqual(dashboard.timeSavedSeconds, 0)
        XCTAssertEqual(HistoryViewModel.assumedTypingWordsPerMinute, 40)

        let empty = HistoryViewModel(repository: TestHistoryRepository())
        XCTAssertEqual(empty.dashboard, .empty)
        XCTAssertNil(empty.dashboard.wordsPerMinute)
        XCTAssertNil(empty.dashboard.averageAIMilliseconds)
    }

    func testTimeSavedIsTypingTimeMinusRecordingTime() async {
        let entry = HistoryEntry(
            createdAt: now,
            rawText: "",
            finalText: Array(repeating: "word", count: 400).joined(separator: " "),
            mode: .off,
            insertionOutcome: .inserted(method: .selectedTextAttribute),
            recordingDurationMilliseconds: 120_000
        )
        let model = HistoryViewModel(repository: TestHistoryRepository(entries: [entry]))
        await model.load()
        // 400 words / 40 wpm = 10 min of typing; 2 min were spent recording.
        XCTAssertEqual(model.dashboard.timeSavedSeconds, 480)
        XCTAssertEqual(HistoryDashboardView.timeSaved(480), "8 m")
        XCTAssertEqual(HistoryDashboardView.timeSaved(3_725), "1 h 2 m")
        XCTAssertEqual(HistoryDashboardView.timeSaved(12), "12 s")
        XCTAssertEqual(HistoryDashboardView.seconds(1_260), "1.3 s")
    }

    // MARK: Filters

    func testFiltersCombineIntoOneRepositoryReadAndStatisticsFollowThem() async {
        let recent = makeEntry(createdAt: now.addingTimeInterval(-3_600), text: "budget review", durationMs: 12_000)
        let older = makeEntry(createdAt: now.addingTimeInterval(-3 * 86_400), text: "budget planning", durationMs: 90_000)
        let ancient = makeEntry(createdAt: now.addingTimeInterval(-40 * 86_400), text: "budget archive", durationMs: 20_000)
        let repository = TestHistoryRepository(entries: [recent, older, ancient])
        let model = HistoryViewModel(repository: repository, now: { [now] in now })
        await model.load()
        XCTAssertFalse(model.isFiltered)
        XCTAssertEqual(model.statistics?.sessionCount, 3)

        model.timeRange = .last7Days
        await model.applyFilters()
        XCTAssertTrue(model.isFiltered)
        XCTAssertTrue(model.isShowingSearchResults)
        XCTAssertEqual(model.entries.map(\.id), [recent.id, older.id])
        XCTAssertEqual(model.statistics?.sessionCount, 2, "tiles cover the filtered rows")

        model.durationBucket = .from1To5Minutes
        model.searchText = "budget"
        await model.applyFilters()
        XCTAssertEqual(model.entries.map(\.id), [older.id])
        let filter = await repository.filters.last
        XCTAssertEqual(filter?.since, now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(filter?.minimumDurationMilliseconds, 60_000)
        XCTAssertEqual(filter?.maximumDurationMilliseconds, 300_000)
        XCTAssertEqual(filter?.normalizedQuery, "budget")

        model.durationBucket = .over5Minutes
        await model.applyFilters()
        XCTAssertEqual(model.loadState, .empty)
        XCTAssertTrue(model.isShowingSearchResults)

        await model.clearFilters()
        XCTAssertEqual(model.timeRange, .all)
        XCTAssertNil(model.durationBucket)
        XCTAssertEqual(model.searchText, "")
        XCTAssertFalse(model.isFiltered)
        XCTAssertEqual(model.entries.count, 3)
    }

    func testFilteredResultsStillPage() async {
        let entries = (0..<5).map { index in
            makeEntry(createdAt: now.addingTimeInterval(-Double(index)), text: "row \(index)", durationMs: 1_000)
        }
        let model = HistoryViewModel(repository: TestHistoryRepository(entries: entries), pageSize: 2, now: { [now] in now })
        model.searchText = "row"
        await model.runSearch()
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertTrue(model.canLoadMore)

        await model.loadNextPage()
        XCTAssertEqual(model.entries.count, 4)
        await model.loadNextPage()
        XCTAssertEqual(model.entries.count, 5)
        XCTAssertFalse(model.canLoadMore)
    }

    // MARK: Multi-select and bulk delete

    func testBulkDeleteRemovesCheckedRowsInOneCallAndTheirAudio() async {
        let a = makeEntry(createdAt: now.addingTimeInterval(-1), text: "a", durationMs: 1, audioPath: "Audio/a.wav")
        let b = makeEntry(createdAt: now.addingTimeInterval(-2), text: "b", durationMs: 1)
        let c = makeEntry(createdAt: now.addingTimeInterval(-3), text: "c", durationMs: 1, audioPath: "Audio/c.wav")
        let repository = TestHistoryRepository(entries: [a, b, c])
        let audio = FakeAudioStore(existing: ["Audio/a.wav", "Audio/c.wav"])
        let model = HistoryViewModel(repository: repository, audioStore: audio)
        await model.load()
        model.selectedEntryID = a.id

        model.setSelecting(true)
        model.toggleSelection(a.id)
        model.toggleSelection(c.id)
        XCTAssertEqual(model.selectedEntryIDs, [a.id, c.id])
        XCTAssertEqual(model.selectedEntries.map(\.id), [a.id, c.id])

        await model.deleteSelectedEntries()

        XCTAssertEqual(model.entries.map(\.id), [b.id])
        XCTAssertFalse(model.isSelecting)
        XCTAssertTrue(model.selectedEntryIDs.isEmpty)
        XCTAssertEqual(model.selectedEntryID, b.id, "the detail selection moved off a deleted row")
        XCTAssertNil(model.pendingUndo, "bulk delete is confirmed, not undoable")
        XCTAssertEqual(model.statusMessage, "2 items deleted.")
        let deletes = await repository.bulkDeletes
        XCTAssertEqual(deletes, [[a.id, c.id]])
        let deletedFiles = await audio.deleted
        XCTAssertEqual(deletedFiles, ["Audio/a.wav", "Audio/c.wav"])

        model.setSelecting(true)
        model.selectAllLoaded()
        XCTAssertEqual(model.selectedEntryIDs, [b.id])
        model.setSelecting(false)
        XCTAssertTrue(model.selectedEntryIDs.isEmpty, "leaving selection mode clears the checks")
    }

    func testSingleDeleteKeepsAudioUntilUndoIsForfeited() async throws {
        let entry = makeEntry(createdAt: now, text: "keep", durationMs: 1, audioPath: "Audio/keep.wav")
        let audio = FakeAudioStore(existing: ["Audio/keep.wav"])
        let model = HistoryViewModel(
            repository: TestHistoryRepository(entries: [entry]),
            audioStore: audio,
            undoWindow: .milliseconds(60)
        )
        await model.load()

        await model.delete(entry)
        XCTAssertNotNil(model.pendingUndo)
        var deleted = await audio.deleted
        XCTAssertEqual(deleted, [], "the recording survives while Undo is possible")

        await model.undoDelete()
        XCTAssertEqual(model.entries.map(\.id), [entry.id])
        deleted = await audio.deleted
        XCTAssertEqual(deleted, [])

        await model.delete(entry)
        await model.dismissUndo()
        deleted = await audio.deleted
        XCTAssertEqual(deleted, ["Audio/keep.wav"], "dismissing Undo finalises the deletion, file included")
    }

    func testClearAllRemovesEveryRecording() async {
        let entry = makeEntry(createdAt: now, text: "x", durationMs: 1, audioPath: "Audio/x.wav")
        let audio = FakeAudioStore(existing: ["Audio/x.wav"])
        let model = HistoryViewModel(repository: TestHistoryRepository(entries: [entry]), audioStore: audio)
        await model.load()

        await model.clearAll()

        let cleared = await audio.deletedAll
        XCTAssertTrue(cleared)
        XCTAssertEqual(model.audioSizeBytes, 0)
    }

    // MARK: Export

    func testCSVExportWritesEveryFilteredRowNotJustTheLoadedPage() async throws {
        let entries = (0..<7).map { index in
            makeEntry(createdAt: now.addingTimeInterval(-Double(index) * 60), text: "row \(index), \"quoted\"", durationMs: 1_500)
        }
        let model = HistoryViewModel(repository: TestHistoryRepository(entries: entries), pageSize: 3, now: { [now] in now })
        await model.load()
        XCTAssertEqual(model.entries.count, 3)
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let csvURL = folder.url.appendingPathComponent("export.csv")

        await model.exportCSV(to: csvURL)

        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 8, "header plus every row")
        XCTAssertEqual(lines[0], HistoryExportFormatter.csvColumns.joined(separator: ","))
        XCTAssertTrue(lines[1].hasSuffix(",\"row 0, \"\"quoted\"\"\",\"row 0, \"\"quoted\"\"\""), lines[1])
        XCTAssertTrue(lines[1].contains(",1.5,off,off,test-model,inserted:selectedTextAttribute,3,"), lines[1])
        XCTAssertEqual(model.statusMessage, "Exported 7 items.")
    }

    func testDailyMarkdownExportWritesOneFilePerDay() async throws {
        let utc = TimeZone(identifier: "UTC")!
        let dayOne = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 UTC
        let dayTwo = Date(timeIntervalSince1970: 1_700_100_000) // 2023-11-16 UTC
        let entries = [
            makeEntry(createdAt: dayOne, text: "first", durationMs: 1_000),
            makeEntry(createdAt: dayOne.addingTimeInterval(60), text: "second", durationMs: 1_000),
            makeEntry(createdAt: dayTwo, text: "third", durationMs: 1_000)
        ]
        let model = HistoryViewModel(repository: TestHistoryRepository(entries: entries))
        await model.load()
        let folder = try TemporaryFolder()
        defer { folder.remove() }

        let destination = await model.exportDailyMarkdown(into: folder.url)

        // Into its own subfolder, so an existing YYYY-MM-DD.md in the chosen
        // folder (an Auto Daily Export target, say) is never overwritten.
        let expectedFolder = folder.url.appendingPathComponent(HistoryViewModel.dailyExportFolderName(now: Date()), isDirectory: true)
        XCTAssertEqual(destination?.standardizedFileURL, expectedFolder.standardizedFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.url.path), [expectedFolder.lastPathComponent])
        let files = try FileManager.default.contentsOfDirectory(atPath: expectedFolder.path).sorted()
        let expectedNames = Set([
            HistoryExportFormatter.dayString(dayOne) + ".md",
            HistoryExportFormatter.dayString(dayTwo) + ".md"
        ])
        XCTAssertEqual(Set(files), expectedNames)
        let dayOneFile = try String(contentsOf: expectedFolder.appendingPathComponent(HistoryExportFormatter.dayString(dayOne) + ".md"), encoding: .utf8)
        XCTAssertTrue(dayOneFile.hasPrefix("# Dictations — \(HistoryExportFormatter.dayString(dayOne))\n"))
        XCTAssertTrue(dayOneFile.range(of: "first")!.lowerBound < dayOneFile.range(of: "second")!.lowerBound, "oldest first within a day")
        XCTAssertEqual(model.statusMessage, "Exported 2 days.")
        _ = utc
    }

    func testSaveSelectedAsMarkdownOrText() async throws {
        let entry = HistoryEntry(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            rawText: "raw",
            finalText: "Enhanced.",
            mode: .polish,
            insertionOutcome: .inserted(method: .selectedTextAttribute),
            aiStatus: .succeeded
        )
        let model = HistoryViewModel(repository: TestHistoryRepository(entries: [entry]))
        await model.load()
        XCTAssertEqual(model.rowsForSelectionExport.map(\.id), [entry.id], "the detail selection counts as selected")
        let folder = try TemporaryFolder()
        defer { folder.remove() }

        let markdownURL = folder.url.appendingPathComponent("one.md")
        await model.save(model.rowsForSelectionExport, as: .markdown, to: markdownURL)
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("## "))
        XCTAssertTrue(markdown.contains("Enhanced."))
        XCTAssertTrue(markdown.contains("<details><summary>Original transcript</summary>"))
        XCTAssertTrue(markdown.contains("raw"))

        let textURL = folder.url.appendingPathComponent("one.txt")
        await model.save(model.rowsForSelectionExport, as: .text, to: textURL)
        let text = try String(contentsOf: textURL, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("["))
        XCTAssertTrue(text.hasSuffix("]\nEnhanced.\n"))
        XCTAssertFalse(text.contains("raw"), "plain text carries the final output only")
        XCTAssertEqual(model.statusMessage, "Saved 1 item.")
    }

    // MARK: Stored audio and Retranscribe

    func testAudioAffordancesFollowTheStoreAndTheRow() async {
        let withAudio = makeEntry(createdAt: now, text: "a", durationMs: 1, audioPath: "Audio/a.wav")
        let without = makeEntry(createdAt: now.addingTimeInterval(-1), text: "b", durationMs: 1)
        let noStore = HistoryViewModel(repository: TestHistoryRepository(entries: [withAudio]))
        XCTAssertFalse(noStore.hasStoredAudio(withAudio), "no store wired: audio is hidden even if a row names a file")
        XCTAssertNil(noStore.audioURL(for: withAudio))
        XCTAssertFalse(noStore.canRetranscribe)
        XCTAssertFalse(noStore.canTranscribeFiles)

        let audio = FakeAudioStore(existing: ["Audio/a.wav"])
        let model = HistoryViewModel(repository: TestHistoryRepository(entries: [withAudio, without]), audioStore: audio)
        XCTAssertTrue(model.hasStoredAudio(withAudio))
        XCTAssertFalse(model.hasStoredAudio(without))
        XCTAssertEqual(model.audioURL(for: withAudio), audio.fileURL(forRelativePath: "Audio/a.wav"))

        var revealed: [URL] = []
        model.revealInFinder = { revealed.append($0) }
        model.revealAudio(for: withAudio)
        model.revealAudio(for: without)
        XCTAssertEqual(revealed, [audio.fileURL(forRelativePath: "Audio/a.wav")])
    }

    func testOpenDataPrivacyHookIsOptionalAndForwardsTheLinkTap() async {
        // P-M8: the History page's "off" note links to Data & Privacy through
        // this hook; nil (previews, tests) simply renders the note without a link.
        let model = HistoryViewModel(repository: TestHistoryRepository(entries: []), audioStore: FakeAudioStore(existing: []))
        XCTAssertNil(model.openDataPrivacy)
        var opened = 0
        model.openDataPrivacy = { opened += 1 }
        model.openDataPrivacy?()
        XCTAssertEqual(opened, 1)
    }

    func testRetranscribeProposesThenReplacesOnlyOnAccept() async {
        let entry = HistoryEntry(
            createdAt: now,
            rawText: "old words",
            finalText: "old words",
            mode: .off,
            insertionOutcome: .inserted(method: .selectedTextAttribute),
            recordingDurationMilliseconds: 3_000,
            audioPath: "Audio/x.wav"
        )
        let repository = TestHistoryRepository(entries: [entry])
        let audio = FakeAudioStore(existing: ["Audio/x.wav"])
        let model = HistoryViewModel(repository: repository, audioStore: audio)
        let engine = FakeEngine(text: "new words")
        model.retranscriber = { url in await engine.transcribe(url) }
        await model.load()
        XCTAssertTrue(model.canRetranscribe)

        await model.retranscribe(entry)

        XCTAssertFalse(model.isRetranscribing)
        XCTAssertEqual(model.retranscribeProposal, HistoryViewModel.RetranscribeProposal(entryID: entry.id, newRawText: "new words", previousRawText: "old words"))
        let requested = await engine.requestedURLs
        XCTAssertEqual(requested, [audio.fileURL(forRelativePath: "Audio/x.wav")])
        var stored = await repository.stored
        XCTAssertEqual(stored.first?.rawText, "old words", "nothing is written until the user accepts")

        model.dismissRetranscription()
        XCTAssertNil(model.retranscribeProposal)
        stored = await repository.stored
        XCTAssertEqual(stored.first?.rawText, "old words")

        await model.retranscribe(entry)
        await model.acceptRetranscription()

        XCTAssertNil(model.retranscribeProposal)
        stored = await repository.stored
        XCTAssertEqual(stored.first?.rawText, "new words")
        XCTAssertEqual(stored.first?.finalText, "new words", "final follows raw when AI had not changed it")
        XCTAssertEqual(stored.first?.audioPath, "Audio/x.wav", "the recording is kept")
        XCTAssertEqual(stored.first?.recordingDurationMilliseconds, 3_000)
        XCTAssertEqual(model.entries.first?.rawText, "new words")
        XCTAssertEqual(model.statusMessage, "Transcript replaced.")
    }

    func testRetranscribeFailureAndEmptyResultLeaveTheRowAlone() async {
        let entry = makeEntry(createdAt: now, text: "keep me", durationMs: 1, audioPath: "Audio/x.wav")
        let model = HistoryViewModel(repository: TestHistoryRepository(entries: [entry]), audioStore: FakeAudioStore(existing: ["Audio/x.wav"]))
        await model.load()

        model.retranscriber = { _ in throw KVoiceError(code: .sttFailed) }
        await model.retranscribe(entry)
        XCTAssertNil(model.retranscribeProposal)
        XCTAssertEqual(model.errorMessage, "Retranscription failed. The saved transcript is unchanged.")

        model.retranscriber = { _ in "   " }
        await model.retranscribe(entry)
        XCTAssertNil(model.retranscribeProposal)
        XCTAssertEqual(model.errorMessage, "The recording produced no transcript.")

        model.retranscriber = { _ in "fine" }
        await model.retranscribe(makeEntry(createdAt: now, text: "no audio", durationMs: 1))
        XCTAssertNil(model.retranscribeProposal, "a row without audio cannot be retranscribed")
    }

    // MARK: Transcribe a file

    func testTranscribeFileWritesAFileRowAndNotifiesTheObserver() async {
        let repository = TestHistoryRepository()
        let model = HistoryViewModel(repository: repository, now: { [now] in now })
        let observed = ObservedEntries()
        model.fileTranscriber = { url in
            FileTranscription(
                text: "spoken in \(url.lastPathComponent)",
                modelID: "whisper-test",
                sttDurationMilliseconds: 800,
                recordingDurationMilliseconds: 42_000
            )
        }
        model.onEntryAppended = { entry in await observed.record(entry) }
        await model.load()
        XCTAssertTrue(model.canTranscribeFiles)

        let entry = await model.transcribeFile(at: URL(fileURLWithPath: "/tmp/meeting.m4a"))

        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.rawText, "spoken in meeting.m4a")
        XCTAssertEqual(entry?.finalText, "spoken in meeting.m4a")
        XCTAssertEqual(entry?.targetClass, "file")
        XCTAssertTrue(entry?.isFileTranscription ?? false)
        XCTAssertEqual(entry?.insertionOutcome, .deliveredInApp)
        XCTAssertEqual(entry?.aiStatus, .off)
        XCTAssertEqual(entry?.modelID, "whisper-test")
        XCTAssertEqual(entry?.sttDurationMilliseconds, 800)
        XCTAssertEqual(entry?.recordingDurationMilliseconds, 42_000)
        XCTAssertEqual(entry?.createdAt, now)
        XCTAssertNil(entry?.audioPath, "the source file is not copied into history")
        let stored = await repository.stored
        XCTAssertEqual(stored, [entry])
        XCTAssertEqual(model.entries, [entry])
        XCTAssertEqual(model.selectedEntryID, entry?.id)
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertFalse(model.isTranscribingFile)
        let seen = await observed.entries
        XCTAssertEqual(seen, [entry])
        XCTAssertEqual(model.statusMessage, "Transcribed meeting.m4a.")
    }

    /// FR-HIST-001: the switch gates every history write, and a file
    /// transcription is one. This is also the Dock-drop path.
    func testTranscribeFileRefusesWhenHistoryIsOff() async {
        let repository = TestHistoryRepository()
        let model = HistoryViewModel(repository: repository, host: .detached(settings: AppSettings(historyEnabled: false)))
        let engine = FakeEngine(text: "never")
        model.fileTranscriber = { url in
            FileTranscription(text: await engine.transcribe(url), modelID: "m")
        }

        let entry = await model.transcribeFile(at: URL(fileURLWithPath: "/tmp/meeting.m4a"))

        XCTAssertNil(entry)
        let asked = await engine.requestedURLs
        XCTAssertTrue(asked.isEmpty, "the engine is not even asked")
        XCTAssertEqual(model.errorMessage, "Turn on Save History to transcribe files.")
        let stored = await repository.stored
        XCTAssertTrue(stored.isEmpty)
        XCTAssertFalse(model.isTranscribingFile)
    }

    func testTranscribeFileSaysSoWhenTheEngineIsBusyWithADictation() async {
        let model = HistoryViewModel(repository: TestHistoryRepository())
        model.fileTranscriber = { _ in throw KVoiceError(code: .appBusy) }
        let result = await model.transcribeFile(at: URL(fileURLWithPath: "/tmp/clip.mov"))
        XCTAssertNil(result)
        XCTAssertEqual(model.errorMessage, "Finish the current dictation first, then try again.")
    }

    func testTranscribeFileReportsDecodeProblemsPlainly() async {
        let model = HistoryViewModel(repository: TestHistoryRepository())
        model.fileTranscriber = { _ in throw MediaFileDecoder.DecodeError.noAudioTrack }
        let result = await model.transcribeFile(at: URL(fileURLWithPath: "/tmp/clip.mov"))
        XCTAssertNil(result)
        XCTAssertEqual(model.errorMessage, "clip.mov has no audio track.")

        model.fileTranscriber = { _ in FileTranscription(text: " ", modelID: "m") }
        _ = await model.transcribeFile(at: URL(fileURLWithPath: "/tmp/silence.wav"))
        XCTAssertEqual(model.errorMessage, "No speech was found in silence.wav.")
        XCTAssertTrue(model.entries.isEmpty)
    }

    // MARK: Decoding

    func testMediaFileDecoderResamplesAStereo44kFixtureTo16kMono() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fixture = folder.url.appendingPathComponent("tone.caf")
        try Self.writeStereoFixture(to: fixture, sampleRate: 44_100, seconds: 1)

        let recording = try await MediaFileDecoder.decode(fixture)

        XCTAssertEqual(recording.sampleRate, 16_000)
        XCTAssertEqual(recording.channelCount, 1)
        XCTAssertTrue(recording.isEngineCompatible)
        XCTAssertEqual(recording.samples.count, 16_000, accuracy: 200)
        XCTAssertGreaterThan(recording.peakLevelDBFS, -12, "a half-scale tone survives the mix-down")
        XCTAssertEqual(recording.clippedFrameCount, 0)
        let seconds = Double(recording.duration.components.seconds) + Double(recording.duration.components.attoseconds) / 1e18
        XCTAssertEqual(seconds, 1, accuracy: 0.02)

        let bins = MediaFileDecoder.waveform(of: recording, bins: 40)
        XCTAssertEqual(bins.count, 40)
        XCTAssertTrue(bins.allSatisfy { $0 > 0.3 && $0 <= 1 })
        XCTAssertEqual(MediaFileDecoder.waveform(of: recording, bins: 0), [])
    }

    func testMediaFileDecoderRejectsAFileWithoutAudio() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bogus = folder.url.appendingPathComponent("not-audio.mp4")
        try Data("this is not a movie".utf8).write(to: bogus)

        do {
            _ = try await MediaFileDecoder.decode(bogus)
            XCTFail("expected a decode error")
        } catch let error as MediaFileDecoder.DecodeError {
            XCTAssertTrue(error == .noAudioTrack || error == .unreadable)
        }
        XCTAssertEqual(MediaFileDecoder.supportedExtensions, ["wav", "mp3", "m4a", "aiff", "aif", "mp4", "mov", "aac", "flac", "caf"])
    }

    func testFileTranscriptionBridgeDecodesThenRunsTheEngine() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fixture = folder.url.appendingPathComponent("tone.wav")
        try Self.writeStereoFixture(to: fixture, sampleRate: 48_000, seconds: 0.5)
        let engine = FakeTranscriptionEngine(text: "bridge works")

        let transcriber = HistoryFileTranscription.transcriber(engine: engine)
        let result = try await transcriber(fixture)

        XCTAssertEqual(result.text, "bridge works")
        XCTAssertEqual(result.modelID, "fake-model")
        XCTAssertNotNil(result.sttDurationMilliseconds)
        XCTAssertEqual(result.recordingDurationMilliseconds ?? 0, 500, accuracy: 20)
        let received = await engine.requests
        XCTAssertEqual(received.count, 1)
        XCTAssertTrue(received.first?.audio.isEngineCompatible ?? false, "the engine receives 16 kHz mono")
        XCTAssertNil(received.first?.initialPrompt, "no prompt hook means no prompt")
    }

    /// ADR-018: Transcribe File and Retranscribe send the dictionary too, read
    /// at call time so a list edited after wiring is what the file sees.
    func testFileTranscriptionBridgeReadsTheDictionaryPromptPerCall() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fixture = folder.url.appendingPathComponent("tone.wav")
        try Self.writeStereoFixture(to: fixture, sampleRate: 48_000, seconds: 0.2)
        let engine = FakeTranscriptionEngine(text: "kvoice")
        let terms = CurrentTerms(["kvoice"])

        let transcriber = HistoryFileTranscription.transcriber(engine: engine) {
            DictionaryPrompt.render(terms: await terms.value)
        }
        _ = try await transcriber(fixture)
        await terms.set(["kvoice", "Cosima"])
        _ = try await transcriber(fixture)

        let received = await engine.requests.map(\.initialPrompt)
        XCTAssertEqual(received, ["Glossary: kvoice.", "Glossary: kvoice, Cosima."])
    }

    // MARK: Helpers

    private func makeEntry(createdAt: Date, text: String, durationMs: Int?, audioPath: String? = nil) -> HistoryEntry {
        HistoryEntry(
            createdAt: createdAt,
            rawText: text,
            finalText: text,
            mode: .off,
            insertionOutcome: .inserted(method: .selectedTextAttribute),
            modelID: "test-model",
            appVersion: "0.0.0",
            recordingDurationMilliseconds: durationMs,
            audioPath: audioPath
        )
    }

    /// A stereo 440 Hz tone at half scale, so the decoder has real
    /// resampling and mix-down to do.
    private static func writeStereoFixture(to url: URL, sampleRate: Double, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let value = Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate)) * 0.5
            buffer.floatChannelData![0][frame] = value
            buffer.floatChannelData![1][frame] = value
        }
        try file.write(from: buffer)
    }
}

// MARK: - Doubles

private actor FakeAudioStore: HistoryAudioStoring {
    private var files: Set<String>
    private(set) var deleted: [String] = []
    private(set) var deletedAll = false

    init(existing: [String]) {
        files = Set(existing)
    }

    func store(_: AudioRecording, for entryID: HistoryEntryID) throws -> String {
        let path = "Audio/\(entryID.uuidString).wav"
        files.insert(path)
        return path
    }

    nonisolated func fileURL(forRelativePath path: String) -> URL {
        URL(fileURLWithPath: "/tmp/kvoice-ui-tests/History").appendingPathComponent(path)
    }

    func exists(relativePath path: String) -> Bool {
        files.contains(path)
    }

    func delete(relativePath path: String) throws {
        deleted.append(path)
        files.remove(path)
    }

    func deleteAll() throws {
        deletedAll = true
        files.removeAll()
    }

    func totalSizeBytes() throws -> Int64 {
        Int64(files.count) * 1_024
    }
}

private actor FakeEngine {
    private let text: String
    private(set) var requestedURLs: [URL] = []

    init(text: String) {
        self.text = text
    }

    func transcribe(_ url: URL) -> String {
        requestedURLs.append(url)
        return text
    }
}

private actor FakeTranscriptionEngine: TranscriptionEngine {
    nonisolated let capabilities = TranscriptionCapabilities(
        supportsBatch: true,
        supportsStreaming: false,
        supportsCancellation: true,
        supportedSampleRate: 16_000,
        supportedChannelCount: 1
    )
    var loadedModelID: ModelID? { "fake-model" }
    private let text: String
    private(set) var requests: [TranscriptionRequest] = []

    init(text: String) {
        self.text = text
    }

    func load(_: InstalledModelPackage) async throws {}
    func unload() async {}

    func transcribe(
        _ request: TranscriptionRequest,
        events _: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> TranscriptionResult {
        requests.append(request)
        let now = ContinuousClock().now
        return TranscriptionResult(
            text: text,
            detectedLanguage: nil,
            segments: [],
            timings: TranscriptionTimings(requestStart: now, inferenceStart: now, inferenceEnd: now, runtimeReportedRealTimeFactor: nil),
            modelID: "fake-model"
        )
    }
}

private actor CurrentTerms {
    private(set) var value: [String]

    init(_ value: [String]) {
        self.value = value
    }

    func set(_ value: [String]) {
        self.value = value
    }
}

private actor ObservedEntries {
    private(set) var entries: [HistoryEntry] = []

    func record(_ entry: HistoryEntry) {
        entries.append(entry)
    }
}

private struct TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvoice-history-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
