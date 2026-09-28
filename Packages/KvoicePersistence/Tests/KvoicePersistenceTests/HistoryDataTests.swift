import Foundation
import XCTest
@testable import KvoiceDomain
@testable import KvoicePersistence

/// Schema v2 reads (filters, aggregates, bulk operations), the opt-in audio
/// file store, age-based maintenance, and Auto Daily Export.
final class HistoryDataTests: XCTestCase {
    // MARK: Filters and aggregates

    func testEntriesMatchingCombinesRangeDurationAndQuery() async throws {
        let location = try TemporaryDirectory()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.url.appendingPathComponent("history.sqlite3"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = makeEntry(createdAt: now.addingTimeInterval(-3_600), text: "budget review", durationMs: 12_000)
        let older = makeEntry(createdAt: now.addingTimeInterval(-3 * 86_400), text: "budget planning", durationMs: 90_000)
        let ancient = makeEntry(createdAt: now.addingTimeInterval(-40 * 86_400), text: "lunch", durationMs: 20_000)
        let undated = makeEntry(createdAt: now.addingTimeInterval(-60), text: "budget v1 row", durationMs: nil)
        for entry in [recent, older, ancient, undated] {
            try await store.append(entry)
        }

        let all = try await store.entries(matching: .all, before: nil, limit: 10)
        XCTAssertEqual(all.map(\.id), [undated.id, recent.id, older.id, ancient.id], "newest first")

        let week = HistoryFilter(timeRange: .last7Days, durationBucket: nil, now: now)
        let inWeek = try await store.entries(matching: week, before: nil, limit: 10)
        XCTAssertEqual(inWeek.map(\.id), [undated.id, recent.id, older.id])

        let shortOnes = HistoryFilter(timeRange: .all, durationBucket: .under15Seconds, now: now)
        let short = try await store.entries(matching: shortOnes, before: nil, limit: 10)
        XCTAssertEqual(short.map(\.id), [recent.id], "a NULL duration never matches a bucket")

        let combined = HistoryFilter(timeRange: .last7Days, durationBucket: .from1To5Minutes, query: "BUDGET", now: now)
        let hits = try await store.entries(matching: combined, before: nil, limit: 10)
        XCTAssertEqual(hits.map(\.id), [older.id])

        let paged = try await store.entries(matching: week, before: recent.createdAt, limit: 10)
        XCTAssertEqual(paged.map(\.id), [older.id], "`before` is an exclusive cursor within the filter")

        let wildcard = HistoryFilter(query: "100%")
        let none = try await store.entries(matching: wildcard, before: nil, limit: 10)
        XCTAssertEqual(none, [], "LIKE wildcards typed by the user are literal")
    }

    func testStatisticsAreSQLAggregatesOverTheFilteredRows() async throws {
        let location = try TemporaryDirectory()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.url.appendingPathComponent("history.sqlite3"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.append(HistoryEntry(
            createdAt: now.addingTimeInterval(-60),
            rawText: "one two three",
            finalText: "one two three four",
            mode: .polish,
            insertionOutcome: .inserted(method: .selectedTextAttribute),
            aiStatus: .succeeded,
            recordingDurationMilliseconds: 10_000,
            aiDurationMilliseconds: 1_500
        ))
        try await store.append(HistoryEntry(
            createdAt: now.addingTimeInterval(-120),
            rawText: "五个字的句子",
            finalText: "五个字的句子",
            mode: .off,
            insertionOutcome: .inserted(method: .selectedTextAttribute),
            recordingDurationMilliseconds: 5_000
        ))
        try await store.append(HistoryEntry(
            createdAt: now.addingTimeInterval(-10 * 86_400),
            rawText: "old",
            finalText: "old",
            mode: .off,
            insertionOutcome: .inserted(method: .selectedTextAttribute),
            recordingDurationMilliseconds: 1_000
        ))

        let everything = try await store.statistics(matching: .all)
        XCTAssertEqual(everything.sessionCount, 3)
        XCTAssertEqual(everything.wordCount, 4 + TranscriptMetrics.wordCount(of: "五个字的句子") + 1)
        XCTAssertEqual(everything.characterCount, "one two three four".count + "五个字的句子".count + "old".count)
        let folded = HistoryStatistics.aggregate(try await store.fetchPage(before: nil, limit: 10))
        XCTAssertEqual(everything.characterCount, folded.characterCount, "SQL LENGTH and the in-memory fold agree")
        XCTAssertEqual(everything.recordingMilliseconds, 16_000)
        XCTAssertEqual(everything.aiSessionCount, 1)
        XCTAssertEqual(everything.aiMilliseconds, 1_500)

        let day = try await store.statistics(matching: HistoryFilter(timeRange: .last24Hours, durationBucket: nil, now: now))
        XCTAssertEqual(day.sessionCount, 2)
        XCTAssertEqual(day.recordingMilliseconds, 15_000)

        let empty = try await store.statistics(matching: HistoryFilter(query: "nothing matches"))
        XCTAssertEqual(empty, .empty)

        // The in-memory default agrees with the SQL, so fakes and the store
        // report the same tiles.
        let loaded = try await store.entries(matching: .all, before: nil, limit: 10)
        XCTAssertEqual(HistoryStatistics.aggregate(loaded), everything)
    }

    func testBulkDeleteIsOneTransactionAndReplaceKeepsTheRow() async throws {
        let location = try TemporaryDirectory()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.url.appendingPathComponent("history.sqlite3"))
        let a = makeEntry(createdAt: Date(timeIntervalSince1970: 1), text: "a", durationMs: 1)
        let b = makeEntry(createdAt: Date(timeIntervalSince1970: 2), text: "b", durationMs: 1)
        let c = makeEntry(createdAt: Date(timeIntervalSince1970: 3), text: "c", durationMs: 1)
        for entry in [a, b, c] {
            try await store.append(entry)
        }

        try await store.delete(ids: [a.id, c.id])
        var remaining = try await store.fetchPage(before: nil, limit: 10)
        XCTAssertEqual(remaining.map(\.id), [b.id])

        let retranscribed = b.replacingRawText("b again")
        try await store.replace(retranscribed)
        remaining = try await store.fetchPage(before: nil, limit: 10)
        XCTAssertEqual(remaining, [retranscribed])
        XCTAssertEqual(remaining[0].finalText, "b again", "final text follows raw when AI had not changed it")
        let count = try await store.count()
        XCTAssertEqual(count, 1)

        try await store.delete(ids: [])
        let stillOne = try await store.count()
        XCTAssertEqual(stillOne, 1)
    }

    func testExpireEntriesAndExpireAudioAreIndependent() async throws {
        let location = try TemporaryDirectory()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.url.appendingPathComponent("history.sqlite3"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let oldWithAudio = makeEntry(createdAt: now.addingTimeInterval(-40 * 86_400), text: "old", durationMs: 1, audioPath: "Audio/old.wav")
        let midWithAudio = makeEntry(createdAt: now.addingTimeInterval(-10 * 86_400), text: "mid", durationMs: 1, audioPath: "Audio/mid.wav")
        let fresh = makeEntry(createdAt: now.addingTimeInterval(-60), text: "fresh", durationMs: 1, audioPath: "Audio/fresh.wav")
        for entry in [oldWithAudio, midWithAudio, fresh] {
            try await store.append(entry)
        }
        let paths = try await store.audioPaths()
        XCTAssertEqual(Set(paths), ["Audio/old.wav", "Audio/mid.wav", "Audio/fresh.wav"])

        // Audio retention of 7 days clears two references but keeps the rows.
        let released = try await store.expireAudio(createdBefore: now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(Set(released), ["Audio/old.wav", "Audio/mid.wav"])
        let afterAudio = try await store.fetchPage(before: nil, limit: 10)
        XCTAssertEqual(afterAudio.count, 3)
        XCTAssertEqual(afterAudio.map(\.audioPath), ["Audio/fresh.wav", nil, nil])

        // Text retention of 30 days deletes one row and reports the audio it
        // (no longer) held.
        let result = try await store.expireEntries(createdBefore: now.addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(result.deletedEntryCount, 1)
        XCTAssertEqual(result.releasedAudioPaths, [])
        let afterText = try await store.fetchPage(before: nil, limit: 10)
        XCTAssertEqual(afterText.map(\.id), [fresh.id, midWithAudio.id])

        // And a row that still carries audio reports it when deleted.
        let everything = try await store.expireEntries(createdBefore: now)
        XCTAssertEqual(everything.deletedEntryCount, 2)
        XCTAssertEqual(everything.releasedAudioPaths, ["Audio/fresh.wav"])
        let nothing = try await store.expireEntries(createdBefore: now)
        XCTAssertEqual(nothing, HistoryCleanupResult())
    }

    // MARK: Audio file store

    func testAudioStoreWritesA16BitWavWithOwnerOnlyPermissions() async throws {
        let location = try TemporaryDirectory()
        defer { location.remove() }
        let audioStore = HistoryAudioFileStore(historyDirectoryURL: location.url)
        let entryID = UUID()
        let recording = AudioRecording(
            samples: [0, 0.5, -0.5, 1, -1, 2, -2],
            duration: .milliseconds(7),
            peakLevelDBFS: 0,
            clippedFrameCount: 2
        )

        let relativePath = try await audioStore.store(recording, for: entryID)

        XCTAssertEqual(relativePath, "Audio/\(entryID.uuidString).wav")
        let fileURL = audioStore.fileURL(forRelativePath: relativePath)
        XCTAssertEqual(fileURL, location.url.appendingPathComponent("Audio/\(entryID.uuidString).wav"))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: audioStore.audioDirectoryURL.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let data = try Data(contentsOf: fileURL)
        XCTAssertEqual(data.count, 44 + 7 * 2)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(data.readUInt16(at: 20), 1, "PCM")
        XCTAssertEqual(data.readUInt16(at: 22), 1, "mono")
        XCTAssertEqual(data.readUInt32(at: 24), 16_000)
        XCTAssertEqual(data.readUInt16(at: 34), 16, "bits per sample")
        XCTAssertEqual(data.readUInt32(at: 40), 14, "data chunk bytes")
        let samples = (0..<7).map { data.readInt16(at: 44 + $0 * 2) }
        XCTAssertEqual(samples, [0, 16_384, -16_384, 32_767, -32_767, 32_767, -32_767], "clamped to full scale")

        let exists = await audioStore.exists(relativePath: relativePath)
        XCTAssertTrue(exists)
        let size = try await audioStore.totalSizeBytes()
        XCTAssertEqual(size, 58)

        // Overwriting the same entry replaces the file and keeps the mode.
        let again = try await audioStore.store(recording, for: entryID)
        XCTAssertEqual(again, relativePath)
        let afterAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((afterAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let files = try FileManager.default.contentsOfDirectory(atPath: audioStore.audioDirectoryURL.path)
        XCTAssertEqual(files, ["\(entryID.uuidString).wav"], "no temporary file is left behind")

        try await audioStore.delete(relativePath: relativePath)
        let gone = await audioStore.exists(relativePath: relativePath)
        XCTAssertFalse(gone)
        try await audioStore.delete(relativePath: relativePath)
        try await audioStore.delete(relativePath: "../../etc/passwd")
    }

    func testAudioStoreDeleteAllRemovesTheFolder() async throws {
        let location = try TemporaryDirectory()
        defer { location.remove() }
        let audioStore = HistoryAudioFileStore(historyDirectoryURL: location.url)
        let recording = AudioRecording(samples: [0.1, 0.2], duration: .milliseconds(1), peakLevelDBFS: -20, clippedFrameCount: 0)
        _ = try await audioStore.store(recording, for: UUID())
        _ = try await audioStore.store(recording, for: UUID())

        try await audioStore.deleteAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioStore.audioDirectoryURL.path))
        let size = try await audioStore.totalSizeBytes()
        XCTAssertEqual(size, 0)
        try await audioStore.deleteAll()
    }

    // MARK: Maintenance

    func testMaintenanceAppliesTextAndAudioRetentionIndependently() async throws {
        let location = try TemporaryDirectory()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.url.appendingPathComponent("history.sqlite3"))
        let audioStore = HistoryAudioFileStore(historyDirectoryURL: location.url)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recording = AudioRecording(samples: [0.1], duration: .milliseconds(1), peakLevelDBFS: -20, clippedFrameCount: 0)

        func seed(daysAgo: Double, text: String) async throws -> HistoryEntry {
            let id = UUID()
            let path = try await audioStore.store(recording, for: id)
            let entry = HistoryEntry(
                id: id,
                createdAt: now.addingTimeInterval(-daysAgo * 86_400),
                rawText: text,
                finalText: text,
                mode: .off,
                insertionOutcome: .inserted(method: .selectedTextAttribute),
                audioPath: path
            )
            try await store.append(entry)
            return entry
        }
        let ancient = try await seed(daysAgo: 40, text: "ancient")
        let old = try await seed(daysAgo: 10, text: "old")
        let fresh = try await seed(daysAgo: 1, text: "fresh")

        let settings = SettingsBox(AppSettings(
            historyRetention: HistoryRetentionSettings(autoDeleteEnabled: true, retentionDays: 30),
            audioStorage: AudioStorageSettings(keepRecordings: false, retentionDays: 7)
        ))
        let maintenance = HistoryMaintenance(
            repository: store,
            audioStore: audioStore,
            settingsProvider: { await settings.value },
            now: { now }
        )

        let report = await maintenance.runOnce()

        XCTAssertEqual(report, HistoryMaintenance.Report(deletedEntryCount: 1, deletedAudioFileCount: 2, ranAt: now))
        let rows = try await store.fetchPage(before: nil, limit: 10)
        XCTAssertEqual(rows.map(\.id), [fresh.id, old.id])
        XCTAssertEqual(rows.map(\.audioPath), [fresh.audioPath, nil], "audio retention cleared the 10-day-old file but kept its transcript")
        let ancientExists = await audioStore.exists(relativePath: ancient.audioPath ?? "")
        XCTAssertFalse(ancientExists)
        let oldExists = await audioStore.exists(relativePath: old.audioPath ?? "")
        XCTAssertFalse(oldExists)
        let freshExists = await audioStore.exists(relativePath: fresh.audioPath ?? "")
        XCTAssertTrue(freshExists)
        let last = await maintenance.lastReport
        XCTAssertEqual(last, report)
    }

    func testMaintenanceSkipsTextRetentionWhenOffUnlessForced() async throws {
        let location = try TemporaryDirectory()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.url.appendingPathComponent("history.sqlite3"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.append(makeEntry(createdAt: now.addingTimeInterval(-100 * 86_400), text: "old", durationMs: 1))
        let settings = SettingsBox(AppSettings(historyRetention: HistoryRetentionSettings(autoDeleteEnabled: false, retentionDays: 30)))
        let maintenance = HistoryMaintenance(
            repository: store,
            audioStore: nil,
            settingsProvider: { await settings.value },
            now: { now }
        )

        let automatic = await maintenance.runOnce()
        XCTAssertEqual(automatic.deletedEntryCount, 0)
        let untouched = try await store.count()
        XCTAssertEqual(untouched, 1)

        let forced = await maintenance.runOnce(force: true)
        XCTAssertEqual(forced.deletedEntryCount, 1)
        let cleared = try await store.count()
        XCTAssertEqual(cleared, 0)
    }

    func testMaintenanceRunsAtStartAndThenOncePerInterval() async throws {
        let location = try TemporaryDirectory()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.url.appendingPathComponent("history.sqlite3"))
        let clock = ManualClock()
        let counter = Counter()
        let maintenance = HistoryMaintenance(
            repository: store,
            audioStore: nil,
            settingsProvider: {
                await counter.increment()
                return AppSettings(historyRetention: HistoryRetentionSettings(autoDeleteEnabled: true, retentionDays: 1))
            },
            clock: clock,
            interval: .seconds(60)
        )

        await maintenance.start()
        await maintenance.start()
        await clock.waitForSleepers(1)
        var passes = await counter.value
        XCTAssertEqual(passes, 1, "one pass at start, then the loop sleeps")
        var pending = await clock.pendingDurations
        XCTAssertEqual(pending, [.seconds(60)])

        await clock.advance()
        await clock.waitForSleepers(1)
        passes = await counter.value
        XCTAssertEqual(passes, 2)

        await maintenance.stop()
        await clock.advance()
        // The resumed loop sees the cancellation and exits without another
        // pass; a pass can only start after the while-check, so this holds
        // whether or not the loop task has run yet.
        passes = await counter.value
        XCTAssertEqual(passes, 2, "stop ends the loop")
        pending = await clock.pendingDurations
        XCTAssertEqual(pending, [], "advance() drained the sleeper and nothing re-armed it")
    }

    // MARK: Auto Daily Export

    func testAutoExportCreatesTodaysFileThenAppends() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let utc = TimeZone(identifier: "UTC")!
        let bookmark = try ExportFolderAccess.makeBookmark(for: folder.url)
        let settings = SettingsBox(AppSettings(export: ExportSettings(autoDailyExportEnabled: true)))
        let local = LocalState(exportFolder: ExportFolderGrant(bookmark: bookmark, displayPath: nil))
        let exporter = AutoDailyExporter(settingsProvider: { await settings.value }, localStateProvider: { local }, timeZone: utc)
        let first = HistoryEntry(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), // 2023-11-14 22:13:20 UTC
            rawText: "raw one",
            finalText: "Polished one.",
            mode: .polish,
            insertionOutcome: .inserted(method: .selectedTextAttribute),
            aiStatus: .succeeded,
            recordingDurationMilliseconds: 4_000
        )
        let second = HistoryEntry(
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            rawText: "plain two",
            finalText: "plain two",
            mode: .off,
            insertionOutcome: .inserted(method: .selectedTextAttribute)
        )
        let nextDay = HistoryEntry(
            createdAt: Date(timeIntervalSince1970: 1_700_100_000), // 2023-11-16
            rawText: "three",
            finalText: "three",
            mode: .off,
            insertionOutcome: .inserted(method: .selectedTextAttribute)
        )

        let firstOutcome = await exporter.append(first)
        let secondOutcome = await exporter.append(second)
        let thirdOutcome = await exporter.append(nextDay)

        // The bookmark resolves through the /private symlink; compare paths
        // with symlinks resolved.
        func appendedPath(_ outcome: AutoDailyExporter.Outcome) -> String? {
            if case .appended(let url) = outcome { return url.resolvingSymlinksInPath().path }
            return nil
        }
        let dayFile = folder.url.appendingPathComponent("2023-11-14.md")
        XCTAssertEqual(appendedPath(firstOutcome), dayFile.resolvingSymlinksInPath().path)
        XCTAssertEqual(appendedPath(secondOutcome), dayFile.resolvingSymlinksInPath().path)
        XCTAssertEqual(
            appendedPath(thirdOutcome),
            folder.url.appendingPathComponent("2023-11-16.md").resolvingSymlinksInPath().path
        )
        let content = try String(contentsOf: dayFile, encoding: .utf8)
        XCTAssertEqual(
            content,
            """
            # Dictations — 2023-11-14

            ## 22:13:20 · 4s · Polish

            Polished one.

            <details><summary>Original transcript</summary>

            raw one

            </details>

            ## 22:15:00

            plain two

            """
        )
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
        XCTAssertEqual(files, ["2023-11-14.md", "2023-11-16.md"])
    }

    func testAutoExportSkipsWhenDisabledOrFolderIsGone() async throws {
        let folder = try TemporaryDirectory()
        let bookmark = try ExportFolderAccess.makeBookmark(for: folder.url)
        let entry = makeEntry(createdAt: Date(), text: "x", durationMs: 1)

        let granted = LocalState(exportFolder: ExportFolderGrant(bookmark: bookmark, displayPath: nil))
        let disabled = SettingsBox(AppSettings(export: ExportSettings(autoDailyExportEnabled: false)))
        let disabledOutcome = await AutoDailyExporter(settingsProvider: { await disabled.value }, localStateProvider: { granted }).append(entry)
        XCTAssertEqual(disabledOutcome, .disabled)

        let unconfigured = SettingsBox(AppSettings(export: ExportSettings(autoDailyExportEnabled: true)))
        let unconfiguredOutcome = await AutoDailyExporter(settingsProvider: { await unconfigured.value }, localStateProvider: { .fresh }).append(entry)
        XCTAssertEqual(unconfiguredOutcome, .folderUnavailable)
        XCTAssertEqual(ExportFolderAccess.resolve(nil), .notConfigured)

        folder.remove()
        let gone = SettingsBox(AppSettings(export: ExportSettings(autoDailyExportEnabled: true)))
        let goneOutcome = await AutoDailyExporter(settingsProvider: { await gone.value }, localStateProvider: { granted }).append(entry)
        XCTAssertEqual(goneOutcome, .folderUnavailable)
        XCTAssertEqual(ExportFolderAccess.resolve(bookmark), .needsReauthorization)
        XCTAssertEqual(ExportFolderAccess.resolve(Data("garbage".utf8)), .needsReauthorization)
    }

    /// A security-scoped bookmark follows a renamed or moved folder. An
    /// export destination must not: the user chose a place, and a folder
    /// dragged to the Trash would otherwise keep receiving transcripts.
    func testAMovedOrTrashedFolderNeedsReauthorizationEvenThoughTheBookmarkStillResolves() async throws {
        let parent = try TemporaryDirectory()
        defer { parent.remove() }
        let chosen = parent.url.appendingPathComponent("Dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let bookmark = try ExportFolderAccess.makeBookmark(for: chosen)
        XCTAssertEqual(ExportFolderAccess.resolve(bookmark, displayPath: chosen.path).url != nil, true)
        // The display path may be spelled through /var while the bookmark
        // resolves through /private/var; both are the same folder.
        XCTAssertNotNil(ExportFolderAccess.resolve(bookmark, displayPath: chosen.resolvingSymlinksInPath().path).url)

        let renamed = parent.url.appendingPathComponent("Dictations (old)", isDirectory: true)
        try FileManager.default.moveItem(at: chosen, to: renamed)

        // Whether the bare bookmark follows the rename depends on the volume;
        // the path check makes the answer the same everywhere.
        XCTAssertEqual(ExportFolderAccess.resolve(bookmark, displayPath: chosen.path), .needsReauthorization)

        let settings = SettingsBox(AppSettings(export: ExportSettings(autoDailyExportEnabled: true)))
        let moved = LocalState(exportFolder: ExportFolderGrant(bookmark: bookmark, displayPath: chosen.path))
        let outcome = await AutoDailyExporter(settingsProvider: { await settings.value }, localStateProvider: { moved })
            .append(makeEntry(createdAt: Date(), text: "x", durationMs: 1))
        XCTAssertEqual(outcome, .folderUnavailable)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: renamed.path), [], "nothing was written into the moved folder")

        // The same folder in a .Trash is refused even when the path matches.
        let trash = parent.url.appendingPathComponent(".Trash", isDirectory: true)
        let trashed = trash.appendingPathComponent("Dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
        let trashedBookmark = try ExportFolderAccess.makeBookmark(for: trashed)
        XCTAssertEqual(ExportFolderAccess.resolve(trashedBookmark, displayPath: trashed.path), .needsReauthorization)
    }

    // MARK: Settings

    func testHistoryAndDataSettingsRoundTripAndDefaultWhenAbsent() async throws {
        let suite = "kvoice.settings.history-data.\(UUID().uuidString)"
        let store = SettingsStore(suiteName: suite)
        let input = AppSettings(
            historyRetention: HistoryRetentionSettings(autoDeleteEnabled: true, retentionDays: 90),
            audioStorage: AudioStorageSettings(keepRecordings: true, retentionDays: 3),
            export: ExportSettings(autoDailyExportEnabled: true)
        )
        try await store.save(input)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, input)

        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"schemaVersion":1}"#.utf8))
        XCTAssertEqual(legacy.historyRetention, HistoryRetentionSettings())
        XCTAssertFalse(legacy.audioStorage.keepRecordings, "stored audio is opt-in")
        XCTAssertEqual(legacy.export, ExportSettings())

        let clamped = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"schemaVersion":1,"historyRetention":{"retentionDays":0},"audioStorage":{"keepRecordings":true,"retentionDays":-5}}"#.utf8)
        )
        XCTAssertEqual(clamped.historyRetention.retentionDays, 1)
        XCTAssertEqual(clamped.audioStorage.retentionDays, 1)
        XCTAssertTrue(clamped.audioStorage.keepRecordings)
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
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvoice-history-data-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private actor SettingsBox {
    var value: AppSettings

    init(_ value: AppSettings) {
        self.value = value
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

/// A clock whose sleeps only return when the test advances it.
private actor ManualClock: KvoiceClock {
    nonisolated var now: ContinuousClock.Instant { ContinuousClock.now }

    private var sleepers: [(duration: Duration, continuation: CheckedContinuation<Void, Error>)] = []
    /// Tests parked in `waitForSleepers`, resumed as soon as enough sleepers exist.
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var pendingDurations: [Duration] { sleepers.map(\.duration) }

    func sleep(for duration: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers.append((duration, continuation))
                resumeWaiters()
            }
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    func advance() {
        let current = sleepers
        sleepers.removeAll()
        for sleeper in current {
            sleeper.continuation.resume()
        }
    }

    private func cancelAll() {
        let current = sleepers
        sleepers.removeAll()
        for sleeper in current {
            sleeper.continuation.resume(throwing: CancellationError())
        }
    }

    /// Suspends until `count` sleepers are parked, so the test can assert on a
    /// pass that has completed rather than one still running. No polling: the
    /// next `sleep` resumes it.
    func waitForSleepers(_ count: Int) async {
        guard sleepers.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { sleepers.count >= $0.count }
        waiters.removeAll { sleepers.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        UInt32(readUInt16(at: offset)) | (UInt32(readUInt16(at: offset + 2)) << 16)
    }

    func readInt16(at offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16(at: offset))
    }
}
