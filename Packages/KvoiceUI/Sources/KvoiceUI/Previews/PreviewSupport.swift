#if DEBUG
import Foundation
import KvoiceDomain

// Preview-only fixtures.
//
// Deliberately local to KvoiceUI and wrapped in `#if DEBUG` rather than reaching
// for `KvoiceTestSupport`: production targets must not depend on that module, and
// a preview is compiled into the production target.
//
// Everything here is in-memory. A preview must never touch the real settings
// file, the history store on disk, an AI endpoint, or a microphone.

enum PreviewFixtures {
    static var historyEntries: [HistoryEntry] {
        let now = Date()
        let modelID = "whisper-large-v3-turbo-coreml-uncompressed"
        return [
            HistoryEntry(
                createdAt: now.addingTimeInterval(-90),
                rawText: "um so i think we should ship the the menu bar thing first",
                finalText: "I think we should ship the menu bar work first.",
                mode: .polish,
                insertionOutcome: .inserted(method: .selectedTextAttribute),
                modelID: modelID,
                sttDurationMilliseconds: 1_840,
                aiStatus: .succeeded,
                targetClass: "textArea",
                appVersion: "0.1.0 (1)"
            ),
            HistoryEntry(
                createdAt: now.addingTimeInterval(-3_600),
                rawText: "open the terminal and run the build script",
                finalText: "Open the terminal and run the build script.",
                mode: .polish,
                // Exercises the clipboard-fallback label and badge in the row.
                insertionOutcome: .copiedToClipboard(reason: .notEditable),
                modelID: modelID,
                sttDurationMilliseconds: 920,
                aiStatus: .succeeded,
                targetClass: "staticText",
                appVersion: "0.1.0 (1)"
            ),
            HistoryEntry(
                // Yesterday, so the row shows a date rather than a bare time.
                createdAt: now.addingTimeInterval(-90_000),
                rawText: "这个功能很有用",
                finalText: "这个功能很有用",
                mode: .translate,
                insertionOutcome: .inserted(method: .textEditValueSplice),
                // Drives the AI-fallback warning in the detail pane.
                errorCode: .aiUnreachable,
                modelID: modelID,
                translationTarget: "en",
                sttDurationMilliseconds: 640,
                aiStatus: .failed,
                targetClass: "textField",
                appVersion: "0.1.0 (1)"
            )
        ]
    }
}

/// In-memory `HistoryRepository` so History previews render real rows without a
/// file on disk.
actor PreviewHistoryRepository: HistoryRepository {
    private var entries: [HistoryEntry]

    init(entries: [HistoryEntry] = PreviewFixtures.historyEntries) {
        self.entries = entries.sorted { $0.createdAt > $1.createdAt }
    }

    func migrateIfNeeded() throws {}

    func append(_ entry: HistoryEntry) throws {
        entries.insert(entry, at: 0)
    }

    func fetchPage(before: Date?, limit: Int) throws -> [HistoryEntry] {
        let candidates = before.map { cutoff in
            entries.filter { $0.createdAt < cutoff }
        } ?? entries
        return Array(candidates.prefix(limit))
    }

    func delete(id: HistoryEntryID) throws {
        entries.removeAll { $0.id == id }
    }

    func deleteAll() throws {
        entries.removeAll()
    }

    func count() throws -> Int {
        entries.count
    }

    func storageSizeBytes() throws -> Int64 {
        // A plausible on-disk size so the footer renders as it would in the app.
        Int64(entries.count) * 4_096 + 20_480
    }

    func search(_ query: String, limit: Int) throws -> [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return try fetchPage(before: nil, limit: limit) }
        let matches = entries.filter {
            $0.rawText.localizedCaseInsensitiveContains(needle)
                || $0.finalText.localizedCaseInsensitiveContains(needle)
        }
        return Array(matches.prefix(limit))
    }
}
#endif
