import Foundation
import KvoiceDomain

/// Auto Daily Export: appends each completed dictation to `YYYY-MM-DD.md` in
/// the folder the user chose. The *toggle* is a preference
/// (`ExportSettings.autoDailyExportEnabled`); the folder is this Mac's grant
/// (`LocalState.exportFolder`, ADR-022 slice 5), so the exporter reads both
/// sources on every append.
///
/// The folder comes from a security-scoped bookmark resolved on every append
/// and checked against the path the user chose (`ExportFolderAccess.resolve`),
/// so a folder that was moved, renamed, trashed, or whose grant was lost is
/// skipped rather than written to wherever it went; the Data & Privacy
/// section shows "Re-authorize" for that state.  A day's file is created with a heading the first time and
/// appended to afterwards, so an external editor can keep it open.
///
/// The exporter is fed by the shell from `DictationController`'s
/// history-append hook and by `HistoryViewModel.onEntryAppended` for file
/// transcriptions; it never reads the database itself.
public actor AutoDailyExporter {
    public enum Outcome: Sendable, Equatable {
        case disabled
        case folderUnavailable
        case appended(URL)
        case failed
    }

    private let settingsProvider: @Sendable () async -> AppSettings
    private let localStateProvider: @Sendable () async -> LocalState
    private let timeZone: TimeZone
    private let fileManager: ExportFileManager

    public init(
        settingsProvider: @escaping @Sendable () async -> AppSettings,
        localStateProvider: @escaping @Sendable () async -> LocalState,
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) {
        self.settingsProvider = settingsProvider
        self.localStateProvider = localStateProvider
        self.timeZone = timeZone
        self.fileManager = ExportFileManager(fileManager)
    }

    /// Appends `entry` to today's file when the feature is on and the folder
    /// resolves.  Never throws: export is best effort and must not affect
    /// the dictation that produced the row.
    @discardableResult
    public func append(_ entry: HistoryEntry) async -> Outcome {
        let settings = await settingsProvider()
        guard settings.export.autoDailyExportEnabled else { return .disabled }
        let grant = await localStateProvider().exportFolder
        guard case .available(let folder) = ExportFolderAccess.resolve(
            grant?.bookmark,
            displayPath: grant?.displayPath,
            fileManager: fileManager.value
        ) else {
            return .folderUnavailable
        }
        return append(entry, to: folder)
    }

    /// The write itself, with the folder already resolved.  Exposed for the
    /// manual "export today" path and for tests.
    public func append(_ entry: HistoryEntry, to folder: URL) -> Outcome {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

        let day = entry.createdAt
        let fileURL = folder.appendingPathComponent(
            HistoryExportFormatter.dayString(day, timeZone: timeZone) + ".md",
            isDirectory: false
        )
        let section = "\n" + HistoryExportFormatter.markdownSection(entry, timeZone: timeZone)
        do {
            if fileManager.value.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(section.utf8))
            } else {
                let document = HistoryExportFormatter.markdownDayHeader(day, timeZone: timeZone) + section
                try Data(document.utf8).write(to: fileURL, options: [.atomic])
            }
            return .appended(fileURL)
        } catch {
            return .failed
        }
    }
}

private final class ExportFileManager: @unchecked Sendable {
    let value: FileManager

    init(_ value: FileManager) {
        self.value = value
    }
}
