import Foundation
import SQLite3
import XCTest
@testable import KvoiceDomain
@testable import KvoicePersistence

final class HistorySQLiteStoreTests: XCTestCase {
    // MARK: Schema

    func testMigrationCreatesSchemaAndRecordsEveryVersion() async throws {
        let location = try TemporaryHistoryLocation()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.fileURL)

        try await store.migrateIfNeeded()

        XCTAssertTrue(FileManager.default.fileExists(atPath: location.fileURL.path))
        let inspector = try SQLiteInspector(path: location.fileURL.path)
        XCTAssertEqual(inspector.scalarInts("SELECT version FROM schema_migrations ORDER BY version"), [1, 2])
        XCTAssertEqual(
            inspector.scalarStrings("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"),
            ["history_entries", "schema_migrations"]
        )
        XCTAssertEqual(
            inspector.scalarStrings("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'history_entries_created_at'"),
            ["history_entries_created_at"]
        )
        XCTAssertEqual(inspector.scalarStrings("PRAGMA journal_mode"), ["delete"], "v1 must not enable WAL")

        // Opening again must not re-apply or duplicate the migrations.
        try await store.migrateIfNeeded()
        let second = HistorySQLiteStore(fileURL: location.fileURL)
        try await second.migrateIfNeeded()
        XCTAssertEqual(inspector.scalarInts("SELECT COUNT(*) FROM schema_migrations"), [2])
    }

    /// v1 columns come first and untouched; v2 appends the dashboard and
    /// opt-in audio columns.  `audio_path` is a relative file path, never
    /// audio: the accepted deviation from FR-HIST-003 (decision #1).
    func testSchemaHasExactlyTheSpecifiedColumnsAndNoAudioBlob() async throws {
        let location = try TemporaryHistoryLocation()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.fileURL)
        try await store.migrateIfNeeded()

        let inspector = try SQLiteInspector(path: location.fileURL.path)
        let columns = inspector.scalarStrings("SELECT name FROM pragma_table_info('history_entries')")
        XCTAssertEqual(
            columns,
            [
                "id", "created_at", "raw_text", "final_text", "mode", "translation_target",
                "stt_model_id", "stt_duration_ms", "ai_status", "insertion_status",
                "error_code", "target_class", "app_version",
                "recording_duration_ms", "ai_duration_ms", "audio_path", "word_count"
            ]
        )
        XCTAssertEqual(
            inspector.scalarStrings("SELECT type FROM pragma_table_info('history_entries') WHERE name = 'audio_path'"),
            ["TEXT"],
            "the audio column is a path, not a BLOB"
        )
        for column in columns {
            XCTAssertFalse(column.localizedCaseInsensitiveContains("key"), column)
            XCTAssertFalse(column.localizedCaseInsensitiveContains("bundle"), column)
        }
        // With audio storage off (the default) nothing but the database (and
        // a transient journal) lives in the History directory.
        let files = try FileManager.default.contentsOfDirectory(atPath: location.directoryURL.path)
        XCTAssertEqual(files.filter { !$0.hasSuffix("-journal") }, ["history.sqlite3"])
    }

    /// A database written by the v1 store upgrades in place: the v1 rows keep
    /// every value, gain NULL durations and audio, and get their word count
    /// backfilled so the dashboard sums are right from the first launch.
    func testV1DatabaseMigratesToV2WithWordCountBackfill() async throws {
        let location = try TemporaryHistoryLocation()
        defer { location.remove() }
        let inspector = try SQLiteInspector(path: location.fileURL.path)
        try inspector.execute(
            """
            CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
            INSERT INTO schema_migrations VALUES (1, 1700000000);
            CREATE TABLE history_entries (
                id TEXT PRIMARY KEY NOT NULL,
                created_at REAL NOT NULL,
                raw_text TEXT NOT NULL,
                final_text TEXT NOT NULL,
                mode TEXT NOT NULL CHECK (mode IN ('off', 'polish', 'translate')),
                translation_target TEXT,
                stt_model_id TEXT NOT NULL,
                stt_duration_ms INTEGER,
                ai_status TEXT NOT NULL,
                insertion_status TEXT NOT NULL,
                error_code TEXT,
                target_class TEXT,
                app_version TEXT NOT NULL
            );
            CREATE INDEX history_entries_created_at ON history_entries(created_at DESC);
            INSERT INTO history_entries VALUES (
                '11111111-1111-1111-1111-111111111111', 1700000000, 'three words here', 'three words here',
                'off', NULL, 'model-a', 250, 'off', 'inserted:selectedTextAttribute', NULL, 'other', '0.1'
            );
            INSERT INTO history_entries VALUES (
                '22222222-2222-2222-2222-222222222222', 1700000001, 'raw', '这是中文句子',
                'polish', NULL, 'model-a', NULL, 'succeeded', 'copied:timeout', 'AI-TIMEOUT', NULL, '0.1'
            );
            """
        )

        let store = HistorySQLiteStore(fileURL: location.fileURL)
        try await store.migrateIfNeeded()

        XCTAssertEqual(inspector.scalarInts("SELECT version FROM schema_migrations ORDER BY version"), [1, 2])
        XCTAssertEqual(
            inspector.scalarInts("SELECT word_count FROM history_entries ORDER BY created_at"),
            [3, TranscriptMetrics.wordCount(of: "这是中文句子")]
        )
        XCTAssertGreaterThan(TranscriptMetrics.wordCount(of: "这是中文句子"), 1, "CJK is segmented, not split on spaces")
        let rows = try await store.fetchPage(before: nil, limit: 10)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].rawText, "three words here")
        XCTAssertEqual(rows[1].sttDurationMilliseconds, 250)
        XCTAssertNil(rows[1].recordingDurationMilliseconds)
        XCTAssertNil(rows[1].aiDurationMilliseconds)
        XCTAssertNil(rows[1].audioPath)
        XCTAssertEqual(rows[0].insertionOutcome, .copiedToClipboard(reason: .timeout))
        XCTAssertEqual(rows[0].errorCode, .aiTimeout)
        let degraded = await store.isDegraded
        XCTAssertFalse(degraded)
        let statistics = try await store.statistics(matching: .all)
        XCTAssertEqual(statistics.sessionCount, 2)
        XCTAssertEqual(statistics.wordCount, 3 + TranscriptMetrics.wordCount(of: "这是中文句子"))
    }

    func testReadsOnAMissingDatabaseReturnEmptyResults() async throws {
        let location = try TemporaryHistoryLocation()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.fileURL)

        let size = try await store.storageSizeBytes()
        XCTAssertEqual(size, 0)
        let page = try await store.fetchPage(before: nil, limit: 10)
        XCTAssertEqual(page, [])
        let count = try await store.count()
        XCTAssertEqual(count, 0)
        let degraded = await store.isDegraded
        XCTAssertFalse(degraded)
    }

    // MARK: Round trips

    func testAppendRoundTripsEveryField() async throws {
        let location = try TemporaryHistoryLocation()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.fileURL)

        let full = HistoryEntry(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            rawText: "raw 这个功能 %_\\",
            finalText: "final\nwith newline",
            mode: .translate,
            insertionOutcome: .copiedToClipboard(reason: .targetApplicationChanged),
            errorCode: .aiUnreachable,
            modelID: "whisper-large-v3-turbo-coreml-uncompressed",
            translationTarget: "zh-Hans",
            sttDurationMilliseconds: 1_234,
            aiStatus: .failed,
            targetClass: "textArea",
            appVersion: "1.0.0 (12)"
        )
        let minimal = HistoryEntry(
            createdAt: Date(timeIntervalSince1970: 1_700_000_001),
            rawText: "plain",
            finalText: "plain",
            mode: .off,
            insertionOutcome: .inserted(method: .textEditValueSplice)
        )

        try await store.append(full)
        try await store.append(minimal)

        let fetched = try await store.fetchPage(before: nil, limit: 10)
        XCTAssertEqual(fetched, [minimal, full])
        XCTAssertNil(fetched[0].translationTarget)
        XCTAssertNil(fetched[0].sttDurationMilliseconds)
        XCTAssertNil(fetched[0].targetClass)
        XCTAssertNil(fetched[0].errorCode)
    }

    func testFetchPageIsNewestFirstWithExclusiveCursorAndLimit() async throws {
        let location = try TemporaryHistoryLocation()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.fileURL)
        for offset in 0..<5 {
            try await store.append(
                makeEntry(createdAt: Date(timeIntervalSince1970: TimeInterval(offset)), rawText: "entry-\(offset)")
            )
        }

        let firstPage = try await store.fetchPage(before: nil, limit: 2)
        XCTAssertEqual(firstPage.map(\.rawText), ["entry-4", "entry-3"])
        let nextPage = try await store.fetchPage(before: firstPage.last?.createdAt, limit: 2)
        XCTAssertEqual(nextPage.map(\.rawText), ["entry-2", "entry-1"])
        let empty = try await store.fetchPage(before: nil, limit: 0)
        XCTAssertEqual(empty, [])
    }

    func testDeleteRemovesOnlyThatRow() async throws {
        let location = try TemporaryHistoryLocation()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.fileURL)
        let keep = makeEntry(createdAt: Date(timeIntervalSince1970: 1), rawText: "keep")
        let remove = makeEntry(createdAt: Date(timeIntervalSince1970: 2), rawText: "remove")
        try await store.append(keep)
        try await store.append(remove)

        try await store.delete(id: remove.id)
        try await store.delete(id: UUID()) // unknown ids are a no-op

        let remaining = try await store.fetchPage(before: nil, limit: 10)
        XCTAssertEqual(remaining, [keep])
        let count = try await store.count()
        XCTAssertEqual(count, 1)
    }

    func testDeleteAllClearsEveryRowAndShrinksTheFile() async throws {
        let location = try TemporaryHistoryLocation()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.fileURL)
        for offset in 0..<200 {
            try await store.append(
                makeEntry(
                    createdAt: Date(timeIntervalSince1970: TimeInterval(offset)),
                    rawText: String(repeating: "transcript \(offset) ", count: 40)
                )
            )
        }
        let populatedSize = try await store.storageSizeBytes()
        XCTAssertGreaterThan(populatedSize, 0)

        try await store.deleteAll()

        let count = try await store.count()
        XCTAssertEqual(count, 0)
        let page = try await store.fetchPage(before: nil, limit: 10)
        XCTAssertEqual(page, [])
        let clearedSize = try await store.storageSizeBytes()
        XCTAssertLessThan(clearedSize, populatedSize)
        // The store keeps working after a clear.
        try await store.append(makeEntry(createdAt: Date(), rawText: "after clear"))
        let after = try await store.count()
        XCTAssertEqual(after, 1)
    }

    func testAppendIsRejectedWhenTheRowViolatesTheSchemaAndLeavesNothingBehind() async throws {
        let location = try TemporaryHistoryLocation()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.fileURL)
        let entry = makeEntry(createdAt: Date(), rawText: "dup")
        try await store.append(entry)

        // Same primary key: the INSERT fails inside its transaction.
        do {
            try await store.append(entry)
            XCTFail("duplicate id must be rejected")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .historyWriteFailed)
        }
        let count = try await store.count()
        XCTAssertEqual(count, 1)
        let degraded = await store.isDegraded
        XCTAssertFalse(degraded, "a write failure is not corruption")
    }

    // MARK: Search and counts

    func testSearchMatchesRawOrFinalTextCaseInsensitively() async throws {
        let location = try TemporaryHistoryLocation()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.fileURL)
        let rawHit = HistoryEntry(
            createdAt: Date(timeIntervalSince1970: 3),
            rawText: "Meeting notes about the Budget",
            finalText: "Notes about finances.",
            mode: .polish,
            insertionOutcome: .inserted(method: .selectedTextAttribute)
        )
        let finalHit = HistoryEntry(
            createdAt: Date(timeIntervalSince1970: 2),
            rawText: "something else",
            finalText: "The BUDGET is approved.",
            mode: .polish,
            insertionOutcome: .inserted(method: .selectedTextAttribute)
        )
        let miss = makeEntry(createdAt: Date(timeIntervalSince1970: 1), rawText: "lunch has been ordered")
        let wildcard = makeEntry(createdAt: Date(timeIntervalSince1970: 0), rawText: "100% done_now")
        for entry in [rawHit, finalHit, miss, wildcard] {
            try await store.append(entry)
        }

        let hits = try await store.search("budget", limit: 10)
        XCTAssertEqual(hits.map(\.id), [rawHit.id, finalHit.id])
        let limited = try await store.search("budget", limit: 1)
        XCTAssertEqual(limited.map(\.id), [rawHit.id])
        let literalPercent = try await store.search("100%", limit: 10)
        XCTAssertEqual(literalPercent.map(\.id), [wildcard.id])
        let literalUnderscore = try await store.search("e_n", limit: 10)
        XCTAssertEqual(literalUnderscore.map(\.id), [wildcard.id], "`_` must not act as a wildcard")
        let blank = try await store.search("   ", limit: 10)
        XCTAssertEqual(blank.count, 4, "a blank query is the unfiltered newest-first page")
        let none = try await store.search("zzz", limit: 10)
        XCTAssertEqual(none, [])
    }

    func testCountAndStorageSizeTrackMutations() async throws {
        let location = try TemporaryHistoryLocation()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.fileURL)

        let initialCount = try await store.count()
        XCTAssertEqual(initialCount, 0)
        let sizeAfterOpen = try await store.storageSizeBytes()
        XCTAssertGreaterThan(sizeAfterOpen, 0, "the schema itself occupies a page")

        let first = makeEntry(createdAt: Date(timeIntervalSince1970: 1), rawText: "one")
        try await store.append(first)
        try await store.append(makeEntry(createdAt: Date(timeIntervalSince1970: 2), rawText: "two"))
        let twoCount = try await store.count()
        XCTAssertEqual(twoCount, 2)
        try await store.delete(id: first.id)
        let oneCount = try await store.count()
        XCTAssertEqual(oneCount, 1)
    }

    // MARK: Insertion status codec

    func testInsertionStatusRoundTripsEveryCase() {
        var outcomes: [InsertionOutcome] = []
        for method in [InsertionMethod.selectedTextAttribute, .textEditValueSplice] {
            outcomes.append(.inserted(method: method))
        }
        let reasons: [ClipboardFallbackReason] = [
            .noFrontmostApplication, .targetApplicationChanged, .noFocusedElement, .notEditable,
            .secureTarget, .unsupportedValueType, .setFailed, .verifyFailed, .timeout
        ]
        for reason in reasons {
            outcomes.append(.copiedToClipboard(reason: reason))
        }

        for outcome in outcomes {
            let stored = outcome.historyStorageValue
            XCTAssertEqual(InsertionOutcome(historyStorageValue: stored), outcome, stored)
        }
        XCTAssertEqual(
            InsertionOutcome.inserted(method: .selectedTextAttribute).historyStorageValue,
            "inserted:selectedTextAttribute"
        )
        XCTAssertEqual(
            InsertionOutcome.copiedToClipboard(reason: .targetApplicationChanged).historyStorageValue,
            "copied:targetApplicationChanged"
        )
        XCTAssertNil(InsertionOutcome(historyStorageValue: "inserted"))
        XCTAssertNil(InsertionOutcome(historyStorageValue: "inserted:keystrokes"))
        XCTAssertNil(InsertionOutcome(historyStorageValue: "pasted:setFailed"))
        XCTAssertNil(InsertionOutcome(historyStorageValue: ""))
    }

    func testStoredInsertionStatusUsesTheStableStrings() async throws {
        let location = try TemporaryHistoryLocation()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.fileURL)
        try await store.append(
            HistoryEntry(
                createdAt: Date(timeIntervalSince1970: 1),
                rawText: "r",
                finalText: "f",
                mode: .off,
                insertionOutcome: .copiedToClipboard(reason: .secureTarget),
                aiStatus: .cancelledFallback
            )
        )

        let inspector = try SQLiteInspector(path: location.fileURL.path)
        XCTAssertEqual(inspector.scalarStrings("SELECT insertion_status FROM history_entries"), ["copied:secureTarget"])
        XCTAssertEqual(inspector.scalarStrings("SELECT ai_status FROM history_entries"), ["cancelledFallback"])
        XCTAssertEqual(inspector.scalarStrings("SELECT mode FROM history_entries"), ["off"])
    }

    // MARK: Corruption recovery (FR-HIST-008)

    func testCorruptFileIsMovedAsideAndAFreshDatabaseIsCreated() async throws {
        let location = try TemporaryHistoryLocation()
        defer { location.remove() }
        let garbage = String(repeating: "this is not a database at all. ", count: 200)
        try Data(garbage.utf8).write(to: location.fileURL)
        let store = HistorySQLiteStore(fileURL: location.fileURL)

        let entry = makeEntry(createdAt: Date(timeIntervalSince1970: 5), rawText: "fresh start")
        try await store.append(entry)

        let degraded = await store.isDegraded
        XCTAssertFalse(degraded)
        let fetched = try await store.fetchPage(before: nil, limit: 10)
        XCTAssertEqual(fetched, [entry])

        let asideURL = await store.recoveredCorruptFileURL
        let aside = try XCTUnwrap(asideURL)
        XCTAssertTrue(aside.lastPathComponent.hasPrefix("history.sqlite3.corrupt-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path), "the original is kept for recovery")
        XCTAssertEqual(String(decoding: try Data(contentsOf: aside), as: UTF8.self), garbage)
        let files = try FileManager.default.contentsOfDirectory(atPath: location.directoryURL.path).sorted()
        XCTAssertEqual(files.filter { !$0.hasSuffix("-journal") }, ["history.sqlite3", aside.lastPathComponent])
    }

    func testUnrecoverableLocationEntersDegradedStateWithoutBlockingCallers() async throws {
        // The History "directory" is a regular file, so neither the first
        // open nor the retry after moving the (absent) database aside can
        // create anything.
        let location = try TemporaryHistoryLocation()
        defer { location.remove() }
        let blocker = location.directoryURL.appendingPathComponent("History", isDirectory: false)
        try Data("not a directory".utf8).write(to: blocker)
        let store = HistorySQLiteStore(fileURL: blocker.appendingPathComponent("history.sqlite3"))

        let page = try await store.fetchPage(before: nil, limit: 10)
        XCTAssertEqual(page, [], "reads on a degraded store are empty, not errors")
        let hits = try await store.search("anything", limit: 10)
        XCTAssertEqual(hits, [])
        let count = try await store.count()
        XCTAssertEqual(count, 0)
        let degraded = await store.isDegraded
        XCTAssertTrue(degraded)

        do {
            try await store.append(makeEntry(createdAt: Date(), rawText: "never stored"))
            XCTFail("a degraded store must refuse writes with the open-failed code")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .historyOpenFailed)
        }
        do {
            try await store.migrateIfNeeded()
            XCTFail("migration cannot succeed on a degraded store")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .historyOpenFailed)
        }
    }

    func testDatabaseFromANewerAppIsPreservedAndTheStoreDegrades() async throws {
        let location = try TemporaryHistoryLocation()
        defer { location.remove() }
        let seed = HistorySQLiteStore(fileURL: location.fileURL)
        try await seed.migrateIfNeeded()
        let inspector = try SQLiteInspector(path: location.fileURL.path)
        try inspector.execute("INSERT INTO schema_migrations (version, applied_at) VALUES (99, 0)")

        let store = HistorySQLiteStore(fileURL: location.fileURL)
        let page = try await store.fetchPage(before: nil, limit: 10)
        XCTAssertEqual(page, [])
        let degraded = await store.isDegraded
        XCTAssertTrue(degraded)
        let aside = await store.recoveredCorruptFileURL
        XCTAssertNil(aside, "a newer schema is not corruption; the file is left where it is")
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.fileURL.path))
        XCTAssertEqual(inspector.scalarInts("SELECT MAX(version) FROM schema_migrations"), [99])
    }

    func testRowsWithUnknownEnumValuesAreSkippedNotFatal() async throws {
        let location = try TemporaryHistoryLocation()
        defer { location.remove() }
        let store = HistorySQLiteStore(fileURL: location.fileURL)
        let good = makeEntry(createdAt: Date(timeIntervalSince1970: 1), rawText: "good")
        try await store.append(good)
        let inspector = try SQLiteInspector(path: location.fileURL.path)
        try inspector.execute(
            """
            INSERT INTO history_entries (
                id, created_at, raw_text, final_text, mode, stt_model_id,
                ai_status, insertion_status, app_version
            ) VALUES ('\(UUID().uuidString)', 2, 'r', 'f', 'off', 'm', 'off', 'typed:keystrokes', '1')
            """
        )

        let fetched = try await store.fetchPage(before: nil, limit: 10)
        XCTAssertEqual(fetched, [good])
    }

    func testDefaultLocationFollowsTheDirectoryPolicy() {
        let url = HistorySQLiteStore.defaultFileURL()
        let components = url.pathComponents
        XCTAssertEqual(Array(components.suffix(3)), ["kvoice", "History", "history.sqlite3"])
        XCTAssertTrue(components.contains("Application Support"))
    }

    func testRecoveryTimestampIsSortableUTC() {
        XCTAssertEqual(
            HistorySQLiteStore.recoveryTimestamp(Date(timeIntervalSince1970: 1_700_000_000)),
            "20231114T221320Z"
        )
    }

    func testLikeEscapingCoversTheWildcards() {
        XCTAssertEqual(HistorySQLiteStore.escapeLikePattern("a%b_c\\d"), "a\\%b\\_c\\\\d")
        XCTAssertEqual(HistorySQLiteStore.escapeLikePattern("plain"), "plain")
    }

    // MARK: Helpers

    private func makeEntry(createdAt: Date, rawText: String) -> HistoryEntry {
        HistoryEntry(
            createdAt: createdAt,
            rawText: rawText,
            finalText: "final \(rawText)",
            mode: .off,
            insertionOutcome: .inserted(method: .selectedTextAttribute),
            modelID: "test-model",
            appVersion: "0.0.0"
        )
    }
}

private struct TemporaryHistoryLocation {
    let directoryURL: URL
    let fileURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvoice-history-sqlite-tests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("history.sqlite3", isDirectory: false)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

/// A second, independent read-only connection used to look at what the store
/// actually wrote, so the tests are not checking the store against itself.
private final class SQLiteInspector {
    private let db: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let handle else {
            throw KVoiceError(code: .historyOpenFailed)
        }
        db = handle
    }

    deinit {
        sqlite3_close_v2(db)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw KVoiceError(code: .historyWriteFailed)
        }
    }

    func scalarStrings(_ sql: String) -> [String] {
        rows(sql) { statement in
            sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        }
    }

    func scalarInts(_ sql: String) -> [Int] {
        rows(sql) { statement in Int(sqlite3_column_int64(statement, 0)) }
    }

    private func rows<T>(_ sql: String, _ read: (OpaquePointer) -> T) -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(read(statement))
        }
        return results
    }
}
