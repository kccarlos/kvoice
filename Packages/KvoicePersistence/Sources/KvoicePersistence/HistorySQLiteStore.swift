import Foundation
import KvoiceDomain
import SQLite3

/// The history database (spec J.5, ADR-011).
///
/// One system-SQLite connection owned by this actor.  Every mutation and every
/// migration runs in an explicit transaction; every statement is prepared.
/// The database uses the default rollback journal — WAL is deliberately never
/// enabled for v1.
///
/// Corruption never blocks dictation (FR-HIST-008).  If the file cannot be
/// opened, fails its integrity check, or cannot be migrated, it is moved aside
/// with a timestamp suffix (kept for recovery) and a fresh database is created
/// once.  If that also fails the store is *degraded*: `append` throws
/// `historyOpenFailed`, reads return nothing, and `isDegraded` is `true`.
///
/// Nothing here carries audio samples, credentials, bundle identifiers, or
/// field content; the domain `HistoryEntry` is the complete persistence
/// boundary.  Schema v2 adds the recording and AI durations, a stored word
/// count for the dashboard aggregates, and `audio_path` — the *relative path*
/// of an opt-in WAV file kept by `HistoryAudioFileStore`, never the audio.
public actor HistorySQLiteStore: HistoryRepository {
    public static let fileName = "history.sqlite3"
    /// The same Application Support folder the model, secrets, and diagnostics
    /// already use. The spec (J.1) names the bundle identifier; the shipped
    /// stores settled on `kvoice` before this store existed, and one folder
    /// is what "Open data folder" shows. Because the name is not the bundle
    /// identifier, the 2026-09-27 identifier change left it where it was.
    public static let applicationSupportDirectoryName = "kvoice"
    public static let historyDirectoryName = "History"
    public static let currentSchemaVersion = 2

    /// The resolved location, exposed for diagnostics and tests.
    public nonisolated let fileURL: URL

    /// `true` once corruption recovery has failed for this store's lifetime.
    public var isDegraded: Bool { degraded }

    /// Where the most recent corrupt database was moved, if recovery ran.
    public private(set) var recoveredCorruptFileURL: URL?

    private let fileManager: HistoryFileManager
    private var connection: SQLiteConnection?
    private var degraded = false

    /// Creates a store at the J.1 default location unless a file URL is
    /// given.  Directories and the file are created lazily on first use.
    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.fileManager = HistoryFileManager(fileManager)
    }

    /// `~/Library/Application Support/kvoice/History/history.sqlite3`
    /// resolved through `FileManager`; no directory is created here.
    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let supportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)

        return supportDirectory
            .appendingPathComponent(Self.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.historyDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.fileName, isDirectory: false)
    }

    // MARK: HistoryRepository

    /// Opens the database and applies pending migrations.  Idempotent; the
    /// other operations call it implicitly.
    public func migrateIfNeeded() throws {
        _ = try openIfNeeded()
    }

    public func append(_ entry: HistoryEntry) throws {
        let db = try openIfNeeded()
        try inTransaction(db, failure: .historyWriteFailed) {
            try insert(entry, into: db, replacing: false)
        }
    }

    /// `INSERT` or, for Retranscribe, `INSERT OR REPLACE` by primary key.
    /// Both bind the same column list so the two can never drift apart.
    private func insert(_ entry: HistoryEntry, into db: OpaquePointer, replacing: Bool) throws {
        let verb = replacing ? "INSERT OR REPLACE" : "INSERT"
        let statement = try prepare(
            db,
            """
            \(verb) INTO history_entries (
                id, created_at, raw_text, final_text, mode, translation_target,
                stt_model_id, stt_duration_ms, ai_status, insertion_status,
                error_code, target_class, app_version,
                recording_duration_ms, ai_duration_ms, audio_path, word_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            failure: .historyWriteFailed
        )
        defer { sqlite3_finalize(statement) }

        bind(statement, 1, entry.id.uuidString)
        bind(statement, 2, entry.createdAt.timeIntervalSince1970)
        bind(statement, 3, entry.rawText)
        bind(statement, 4, entry.finalText)
        bind(statement, 5, entry.mode.rawValue)
        bind(statement, 6, entry.translationTarget)
        bind(statement, 7, entry.modelID)
        bind(statement, 8, entry.sttDurationMilliseconds)
        bind(statement, 9, entry.aiStatus.rawValue)
        bind(statement, 10, entry.insertionOutcome.historyStorageValue)
        bind(statement, 11, entry.errorCode?.rawValue)
        bind(statement, 12, entry.targetClass)
        bind(statement, 13, entry.appVersion)
        bind(statement, 14, entry.recordingDurationMilliseconds)
        bind(statement, 15, entry.aiDurationMilliseconds)
        bind(statement, 16, entry.audioPath)
        bind(statement, 17, entry.wordCount)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw KVoiceError(code: .historyWriteFailed)
        }
    }

    public func fetchPage(before: Date?, limit: Int) throws -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        guard let db = try openIfNeededUnlessDegraded() else { return [] }

        let statement = try prepare(
            db,
            """
            SELECT \(Self.selectColumns) FROM history_entries
            WHERE (? IS NULL OR created_at < ?)
            ORDER BY created_at DESC, id DESC
            LIMIT ?
            """,
            failure: .historyOpenFailed
        )
        defer { sqlite3_finalize(statement) }

        let cursor = before?.timeIntervalSince1970
        bind(statement, 1, cursor)
        bind(statement, 2, cursor)
        bind(statement, 3, limit)
        return try readEntries(statement)
    }

    public func delete(id: HistoryEntryID) throws {
        let db = try openIfNeeded()
        try inTransaction(db, failure: .historyWriteFailed) {
            let statement = try prepare(
                db,
                "DELETE FROM history_entries WHERE id = ?",
                failure: .historyWriteFailed
            )
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, id.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw KVoiceError(code: .historyWriteFailed)
            }
        }
    }

    /// One transaction (FR-HIST-005).  A best-effort `VACUUM` afterwards
    /// returns the space so the size shown in the UI reflects the clear.
    public func deleteAll() throws {
        let db = try openIfNeeded()
        try inTransaction(db, failure: .historyWriteFailed) {
            try execute(db, "DELETE FROM history_entries", failure: .historyWriteFailed)
        }
        // VACUUM cannot run inside a transaction and its failure does not
        // change the (already committed) result, so it is not surfaced.
        try? execute(db, "VACUUM", failure: .historyWriteFailed)
    }

    public func count() throws -> Int {
        guard let db = try openIfNeededUnlessDegraded() else { return 0 }
        let statement = try prepare(
            db,
            "SELECT COUNT(*) FROM history_entries",
            failure: .historyOpenFailed
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw KVoiceError(code: .historyOpenFailed)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Size of the database file itself.  The rollback journal is transient
    /// and is not counted.
    public func storageSizeBytes() throws -> Int64 {
        guard let attributes = try? fileManager.value.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.int64Value
    }

    /// `LIKE` folds ASCII case only; that is the v1 contract.  `%` and `_`
    /// typed by the user are escaped so they match literally.
    public func search(_ query: String, limit: Int) throws -> [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return try fetchPage(before: nil, limit: limit) }
        guard limit > 0 else { return [] }
        guard let db = try openIfNeededUnlessDegraded() else { return [] }

        let statement = try prepare(
            db,
            """
            SELECT \(Self.selectColumns) FROM history_entries
            WHERE raw_text LIKE ? ESCAPE '\\' OR final_text LIKE ? ESCAPE '\\'
            ORDER BY created_at DESC, id DESC
            LIMIT ?
            """,
            failure: .historyOpenFailed
        )
        defer { sqlite3_finalize(statement) }

        let pattern = "%" + Self.escapeLikePattern(needle) + "%"
        bind(statement, 1, pattern)
        bind(statement, 2, pattern)
        bind(statement, 3, limit)
        return try readEntries(statement)
    }

    // MARK: History and data (filters, aggregates, bulk operations)

    /// One `WHERE` for every filtered read.  The SQL text is assembled from
    /// fixed fragments only; every user value is bound.
    private struct FilterClause {
        var sql: String
        var bindings: [FilterBinding]

        enum FilterBinding {
            case double(Double)
            case int(Int)
            case text(String)
        }

        init(_ filter: HistoryFilter, before: Date?) {
            var conditions: [String] = []
            var bindings: [FilterBinding] = []
            if let since = filter.since {
                conditions.append("created_at >= ?")
                bindings.append(.double(since.timeIntervalSince1970))
            }
            if let before {
                conditions.append("created_at < ?")
                bindings.append(.double(before.timeIntervalSince1970))
            }
            if let lower = filter.minimumDurationMilliseconds {
                conditions.append("recording_duration_ms >= ?")
                bindings.append(.int(lower))
            }
            if let upper = filter.maximumDurationMilliseconds {
                conditions.append("recording_duration_ms < ?")
                bindings.append(.int(upper))
            }
            if filter.restrictsDuration {
                // A NULL duration (schema v1 row) compares as unknown and
                // would already be excluded; stating it keeps the intent
                // visible in the plan.
                conditions.append("recording_duration_ms IS NOT NULL")
            }
            if let needle = filter.normalizedQuery {
                let pattern = "%" + HistorySQLiteStore.escapeLikePattern(needle) + "%"
                conditions.append("(raw_text LIKE ? ESCAPE '\\' OR final_text LIKE ? ESCAPE '\\')")
                bindings.append(.text(pattern))
                bindings.append(.text(pattern))
            }
            sql = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
            self.bindings = bindings
        }
    }

    private func bindFilter(_ clause: FilterClause, to statement: OpaquePointer, startingAt first: Int32 = 1) -> Int32 {
        var index = first
        for binding in clause.bindings {
            switch binding {
            case .double(let value): bind(statement, index, value)
            case .int(let value): bind(statement, index, value)
            case .text(let value): bind(statement, index, value)
            }
            index += 1
        }
        return index
    }

    public func entries(matching filter: HistoryFilter, before: Date?, limit: Int) throws -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        guard let db = try openIfNeededUnlessDegraded() else { return [] }
        let clause = FilterClause(filter, before: before)
        let statement = try prepare(
            db,
            """
            SELECT \(Self.selectColumns) FROM history_entries\(clause.sql)
            ORDER BY created_at DESC, id DESC
            LIMIT ?
            """,
            failure: .historyOpenFailed
        )
        defer { sqlite3_finalize(statement) }
        let next = bindFilter(clause, to: statement)
        bind(statement, next, limit)
        return try readEntries(statement)
    }

    /// `COUNT`/`SUM` in SQL; no row is materialised.  `LENGTH` on a TEXT
    /// column counts Unicode code points, which is the keystrokes-saved
    /// figure; `HistoryStatistics.add` uses `unicodeScalars.count` to match.
    public func statistics(matching filter: HistoryFilter) throws -> HistoryStatistics {
        guard let db = try openIfNeededUnlessDegraded() else { return .empty }
        let clause = FilterClause(filter, before: nil)
        let statement = try prepare(
            db,
            """
            SELECT COUNT(*),
                   COALESCE(SUM(word_count), 0),
                   COALESCE(SUM(LENGTH(final_text)), 0),
                   COALESCE(SUM(recording_duration_ms), 0),
                   COUNT(ai_duration_ms),
                   COALESCE(SUM(ai_duration_ms), 0)
            FROM history_entries\(clause.sql)
            """,
            failure: .historyOpenFailed
        )
        defer { sqlite3_finalize(statement) }
        _ = bindFilter(clause, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw KVoiceError(code: .historyOpenFailed)
        }
        return HistoryStatistics(
            sessionCount: Int(sqlite3_column_int64(statement, 0)),
            wordCount: Int(sqlite3_column_int64(statement, 1)),
            characterCount: Int(sqlite3_column_int64(statement, 2)),
            recordingMilliseconds: Int(sqlite3_column_int64(statement, 3)),
            aiSessionCount: Int(sqlite3_column_int64(statement, 4)),
            aiMilliseconds: Int(sqlite3_column_int64(statement, 5))
        )
    }

    /// One transaction for the whole selection: either every row goes or
    /// none does.
    public func delete(ids: [HistoryEntryID]) throws {
        guard !ids.isEmpty else { return }
        let db = try openIfNeeded()
        try inTransaction(db, failure: .historyWriteFailed) {
            let statement = try prepare(
                db,
                "DELETE FROM history_entries WHERE id = ?",
                failure: .historyWriteFailed
            )
            defer { sqlite3_finalize(statement) }
            for id in ids {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, 1, id.uuidString)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw KVoiceError(code: .historyWriteFailed)
                }
            }
        }
    }

    public func replace(_ entry: HistoryEntry) throws {
        let db = try openIfNeeded()
        try inTransaction(db, failure: .historyWriteFailed) {
            try insert(entry, into: db, replacing: true)
        }
    }

    /// Reads the audio paths of the rows about to go, then deletes them, in
    /// one transaction so a crash between the two cannot orphan files
    /// silently: either the rows are gone and the caller has the paths, or
    /// nothing changed.
    public func expireEntries(createdBefore cutoff: Date) throws -> HistoryCleanupResult {
        let db = try openIfNeeded()
        var result = HistoryCleanupResult()
        try inTransaction(db, failure: .historyWriteFailed) {
            result.releasedAudioPaths = try audioPaths(in: db, createdBefore: cutoff)
            let statement = try prepare(
                db,
                "DELETE FROM history_entries WHERE created_at < ?",
                failure: .historyWriteFailed
            )
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, cutoff.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw KVoiceError(code: .historyWriteFailed)
            }
            result.deletedEntryCount = Int(sqlite3_changes(db))
        }
        return result
    }

    public func expireAudio(createdBefore cutoff: Date) throws -> [String] {
        let db = try openIfNeeded()
        var released: [String] = []
        try inTransaction(db, failure: .historyWriteFailed) {
            released = try audioPaths(in: db, createdBefore: cutoff)
            guard !released.isEmpty else { return }
            let statement = try prepare(
                db,
                "UPDATE history_entries SET audio_path = NULL WHERE created_at < ? AND audio_path IS NOT NULL",
                failure: .historyWriteFailed
            )
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, cutoff.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw KVoiceError(code: .historyWriteFailed)
            }
        }
        return released
    }

    public func audioPaths() throws -> [String] {
        guard let db = try openIfNeededUnlessDegraded() else { return [] }
        return try audioPaths(in: db, createdBefore: nil)
    }

    private func audioPaths(in db: OpaquePointer, createdBefore cutoff: Date?) throws -> [String] {
        let statement = try prepare(
            db,
            """
            SELECT audio_path FROM history_entries
            WHERE audio_path IS NOT NULL AND (? IS NULL OR created_at < ?)
            """,
            failure: .historyOpenFailed
        )
        defer { sqlite3_finalize(statement) }
        let cursor = cutoff?.timeIntervalSince1970
        bind(statement, 1, cursor)
        bind(statement, 2, cursor)
        var paths: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw KVoiceError(code: .historyOpenFailed) }
            if let path = columnText(statement, 0) {
                paths.append(path)
            }
        }
        return paths
    }

    // MARK: Opening and recovery

    /// Reads treat a degraded store as empty, including the read that first
    /// discovers the failure; only writes surface `historyOpenFailed`.
    private func openIfNeededUnlessDegraded() throws -> OpaquePointer? {
        if degraded { return nil }
        do {
            return try openIfNeeded()
        } catch {
            if degraded { return nil }
            throw error
        }
    }

    /// Opens on first use, recovering from a corrupt file exactly once.
    private func openIfNeeded() throws -> OpaquePointer {
        if let connection { return connection.handle }
        guard !degraded else { throw KVoiceError(code: .historyOpenFailed) }

        do {
            connection = SQLiteConnection(try openAndMigrate())
        } catch let failure as OpenFailure {
            guard failure == .corrupt else {
                degraded = true
                throw KVoiceError(code: .historyOpenFailed)
            }
            moveCorruptFileAside()
            do {
                connection = SQLiteConnection(try openAndMigrate())
            } catch {
                degraded = true
                throw KVoiceError(code: .historyOpenFailed)
            }
        } catch {
            degraded = true
            throw KVoiceError(code: .historyOpenFailed)
        }

        guard let connection else { throw KVoiceError(code: .historyOpenFailed) }
        return connection.handle
    }

    private enum OpenFailure: Error, Equatable {
        /// The file is unreadable or damaged; move it aside and start over.
        case corrupt
        /// The file is a valid database written by a newer app.  It is
        /// preserved untouched and the store runs degraded.
        case newerSchema
    }

    private func openAndMigrate() throws -> OpaquePointer {
        try fileManager.value.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(fileURL.path, &handle, flags, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw OpenFailure.corrupt
        }

        do {
            try configureConnection(db)
            try verifyIntegrity(db)
            try migrate(db)
        } catch let failure as OpenFailure {
            sqlite3_close_v2(db)
            throw failure
        } catch {
            sqlite3_close_v2(db)
            throw OpenFailure.corrupt
        }
        return db
    }

    private func configureConnection(_ db: OpaquePointer) throws {
        // J.5 connection policy. `journal_mode = DELETE` is the default
        // rollback journal, set explicitly so a file that somehow carries a
        // persisted WAL mode is switched back rather than inherited.
        try execute(db, "PRAGMA foreign_keys = ON", failure: .historyOpenFailed)
        try execute(db, "PRAGMA synchronous = FULL", failure: .historyOpenFailed)
        try execute(db, "PRAGMA busy_timeout = 1000", failure: .historyOpenFailed)
        try execute(db, "PRAGMA journal_mode = DELETE", failure: .historyOpenFailed)
    }

    private func verifyIntegrity(_ db: OpaquePointer) throws {
        let statement = try prepare(db, "PRAGMA quick_check", failure: .historyOpenFailed)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              columnText(statement, 0) == "ok"
        else {
            throw OpenFailure.corrupt
        }
    }

    // MARK: Migrations

    private struct Migration: Sendable {
        /// Work SQL cannot express, run inside the migration's transaction
        /// after `statements`.
        enum Backfill: Sendable {
            case wordCounts
        }

        let version: Int
        let statements: [String]
        let backfill: Backfill?
    }

    /// v1 is the spec's J.5 schema and is never rewritten; later versions
    /// only add.  v2 (History and data): recording and AI durations for the
    /// dashboard, the stored word count that makes "Words Dictated" a `SUM`,
    /// and the relative path of an opt-in audio file.
    private static let migrations: [Migration] = [
        Migration(
            version: 1,
            statements: [
                """
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
                )
                """,
                """
                CREATE INDEX history_entries_created_at
                ON history_entries(created_at DESC)
                """
            ],
            backfill: nil
        ),
        Migration(
            version: 2,
            statements: [
                "ALTER TABLE history_entries ADD COLUMN recording_duration_ms INTEGER",
                "ALTER TABLE history_entries ADD COLUMN ai_duration_ms INTEGER",
                "ALTER TABLE history_entries ADD COLUMN audio_path TEXT",
                "ALTER TABLE history_entries ADD COLUMN word_count INTEGER NOT NULL DEFAULT 0"
            ],
            backfill: .wordCounts
        )
    ]

    /// Counts words of every existing row once, in Swift, because SQLite
    /// cannot segment text.  Only runs when upgrading from v1.
    private func backfillWordCounts(_ db: OpaquePointer) throws {
        let select = try prepare(db, "SELECT id, final_text FROM history_entries", failure: .historyMigrationFailed)
        defer { sqlite3_finalize(select) }
        var counts: [(id: String, words: Int)] = []
        while true {
            let result = sqlite3_step(select)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw KVoiceError(code: .historyMigrationFailed) }
            guard let id = columnText(select, 0) else { continue }
            counts.append((id, TranscriptMetrics.wordCount(of: columnText(select, 1) ?? "")))
        }
        guard !counts.isEmpty else { return }
        let update = try prepare(db, "UPDATE history_entries SET word_count = ? WHERE id = ?", failure: .historyMigrationFailed)
        defer { sqlite3_finalize(update) }
        for row in counts {
            sqlite3_reset(update)
            sqlite3_clear_bindings(update)
            bind(update, 1, row.words)
            bind(update, 2, row.id)
            guard sqlite3_step(update) == SQLITE_DONE else { throw KVoiceError(code: .historyMigrationFailed) }
        }
    }

    private func migrate(_ db: OpaquePointer) throws {
        try inTransaction(db, failure: .historyMigrationFailed) {
            try execute(
                db,
                """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version INTEGER PRIMARY KEY,
                    applied_at REAL NOT NULL
                )
                """,
                failure: .historyMigrationFailed
            )
        }

        let applied = try appliedSchemaVersion(db)
        guard applied <= Self.currentSchemaVersion else { throw OpenFailure.newerSchema }

        for migration in Self.migrations where migration.version > applied {
            try inTransaction(db, failure: .historyMigrationFailed) {
                for sql in migration.statements {
                    try execute(db, sql, failure: .historyMigrationFailed)
                }
                switch migration.backfill {
                case .wordCounts: try backfillWordCounts(db)
                case nil: break
                }
                let record = try prepare(
                    db,
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                    failure: .historyMigrationFailed
                )
                defer { sqlite3_finalize(record) }
                bind(record, 1, migration.version)
                bind(record, 2, Date().timeIntervalSince1970)
                guard sqlite3_step(record) == SQLITE_DONE else {
                    throw KVoiceError(code: .historyMigrationFailed)
                }
            }
        }
    }

    private func appliedSchemaVersion(_ db: OpaquePointer) throws -> Int {
        let statement = try prepare(
            db,
            "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
            failure: .historyMigrationFailed
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw KVoiceError(code: .historyMigrationFailed)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Renames the damaged database (and any journal) next to itself with a
    /// timestamp suffix.  Nothing is deleted; the user can recover it later.
    private func moveCorruptFileAside() {
        let stamp = Self.recoveryTimestamp(Date())
        let corruptURL = fileURL.appendingPathExtension("corrupt-\(stamp)")
        let journalURL = URL(fileURLWithPath: fileURL.path + "-journal")
        let journalAsideURL = URL(fileURLWithPath: corruptURL.path + "-journal")

        try? fileManager.value.moveItem(at: fileURL, to: corruptURL)
        if fileManager.value.fileExists(atPath: journalURL.path) {
            try? fileManager.value.moveItem(at: journalURL, to: journalAsideURL)
        }
        recoveredCorruptFileURL = corruptURL
    }

    static func recoveryTimestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    // MARK: Row mapping

    private static let selectColumns = """
        id, created_at, raw_text, final_text, mode, translation_target,
        stt_model_id, stt_duration_ms, ai_status, insertion_status,
        error_code, target_class, app_version,
        recording_duration_ms, ai_duration_ms, audio_path
        """

    private func readEntries(_ statement: OpaquePointer) throws -> [HistoryEntry] {
        var entries: [HistoryEntry] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw KVoiceError(code: .historyOpenFailed) }
            // A row whose enum columns this build does not understand is
            // skipped rather than making the whole history unreadable.
            if let entry = entry(from: statement) {
                entries.append(entry)
            }
        }
        return entries
    }

    private func entry(from statement: OpaquePointer) -> HistoryEntry? {
        guard let idString = columnText(statement, 0),
              let id = UUID(uuidString: idString),
              let rawText = columnText(statement, 2),
              let finalText = columnText(statement, 3),
              let mode = columnText(statement, 4).flatMap(DictationMode.init(rawValue:)),
              let modelID = columnText(statement, 6),
              let aiStatus = columnText(statement, 8).flatMap(HistoryAIStatus.init(rawValue:)),
              let insertionOutcome = columnText(statement, 9)
                  .flatMap(InsertionOutcome.init(historyStorageValue:)),
              let appVersion = columnText(statement, 12)
        else {
            return nil
        }

        return HistoryEntry(
            id: id,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            rawText: rawText,
            finalText: finalText,
            mode: mode,
            insertionOutcome: insertionOutcome,
            errorCode: columnText(statement, 10).flatMap(KVoiceErrorCode.init(rawValue:)),
            modelID: modelID,
            translationTarget: columnText(statement, 5),
            sttDurationMilliseconds: columnInt(statement, 7),
            aiStatus: aiStatus,
            targetClass: columnText(statement, 11),
            appVersion: appVersion,
            recordingDurationMilliseconds: columnInt(statement, 13),
            aiDurationMilliseconds: columnInt(statement, 14),
            audioPath: columnText(statement, 15)
        )
    }

    private func columnInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int64(statement, index))
    }

    static func escapeLikePattern(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if character == "\\" || character == "%" || character == "_" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    // MARK: SQLite plumbing

    private func inTransaction(
        _ db: OpaquePointer,
        failure: KVoiceErrorCode,
        _ body: () throws -> Void
    ) throws {
        try execute(db, "BEGIN IMMEDIATE", failure: failure)
        do {
            try body()
            try execute(db, "COMMIT", failure: failure)
        } catch {
            try? execute(db, "ROLLBACK", failure: failure)
            throw error
        }
    }

    /// Runs one statement with no bound parameters through the prepared
    /// statement API.  Never pass user content here.
    private func execute(_ db: OpaquePointer, _ sql: String, failure: KVoiceErrorCode) throws {
        let statement = try prepare(db, sql, failure: failure)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw KVoiceError(code: failure)
        }
    }

    private func prepare(_ db: OpaquePointer, _ sql: String, failure: KVoiceErrorCode) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            // The SQLite message is not attached: it can quote the failing
            // SQL, which for a bound-parameter statement is safe, but keeping
            // the error a bare code is simpler to audit.
            throw KVoiceError(code: failure)
        }
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, Self.transientDestructor)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index)
        else {
            return nil
        }
        return String(cString: pointer)
    }

    /// `SQLITE_TRANSIENT` is a C macro that does not import into Swift.
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

// MARK: - Insertion status codec

public extension InsertionOutcome {
    /// The stable `insertion_status` column value: `inserted:<method>`,
    /// `copied:<reason>`, `inApp`, or `aborted` (J.5).  Changing a case name is
    /// a schema change.
    var historyStorageValue: String {
        switch self {
        case .inserted(let method):
            return "inserted:\(method.rawValue)"
        case .copiedToClipboard(let reason):
            return "copied:\(reason.rawValue)"
        case .deliveredInApp:
            return "inApp"
        case .abortedAtTermination:
            return "aborted"
        }
    }

    init?(historyStorageValue: String) {
        switch historyStorageValue {
        case "inApp":
            self = .deliveredInApp
            return
        case "aborted":
            self = .abortedAtTermination
            return
        default:
            break
        }
        let parts = historyStorageValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let payload = String(parts[1])
        switch parts[0] {
        case "inserted":
            guard let method = InsertionMethod(rawValue: payload) else { return nil }
            self = .inserted(method: method)
        case "copied":
            guard let reason = ClipboardFallbackReason(rawValue: payload) else { return nil }
            self = .copiedToClipboard(reason: reason)
        default:
            return nil
        }
    }
}

/// Owns the raw handle so it is closed exactly once when the actor goes
/// away.  Only the actor ever touches it, which is what makes the unchecked
/// conformance sound.
private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(_ handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close_v2(handle)
    }
}

/// `FileManager` predates Swift's strict sendability annotations.  The store
/// serializes every operation through its actor, making this wrapper the only
/// audited crossing point.
private final class HistoryFileManager: @unchecked Sendable {
    let value: FileManager

    init(_ value: FileManager) {
        self.value = value
    }
}
