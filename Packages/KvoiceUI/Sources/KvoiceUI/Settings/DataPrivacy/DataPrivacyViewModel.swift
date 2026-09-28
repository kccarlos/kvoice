import AppKit
import Foundation
import KvoiceAppCore
import KvoiceDomain
import Observation

/// Storage figures for the Data & Privacy section.
public struct DataPrivacyMetrics: Sendable, Equatable {
    public let entryCount: Int
    public let databaseBytes: Int64
    public let audioBytes: Int64

    public init(entryCount: Int, databaseBytes: Int64, audioBytes: Int64) {
        self.entryCount = entryCount
        self.databaseBytes = databaseBytes
        self.audioBytes = audioBytes
    }
}

/// What a cleanup pass removed, for the confirmation line.
public struct DataPrivacyCleanupOutcome: Sendable, Equatable {
    public let deletedEntries: Int
    public let deletedAudioFiles: Int
    public let hadErrors: Bool

    public init(deletedEntries: Int, deletedAudioFiles: Int, hadErrors: Bool = false) {
        self.deletedEntries = deletedEntries
        self.deletedAudioFiles = deletedAudioFiles
        self.hadErrors = hadErrors
    }
}

/// State for Settings › Data & Privacy: transcript retention, opt-in stored
/// audio and its retention, and Auto Daily Export.  The Save History toggle
/// itself stays on `HistoryViewModel`, which the shell already persists, so
/// there is one source of truth for it.
///
/// ADR-022 slice 7: a projection over `SettingsProjectionHost`. The five
/// controls read the coordinator's `historyRetention` / `audioStorage` /
/// `export` blocks live and commit at once (no text fields), each edit one
/// `.setDataPrivacy` intent carrying the whole block. The export *folder* is
/// not a setting: it is this Mac's grant (`LocalState.exportFolder`, ADR-022
/// slice 5), read from the host's `localState` and written as a
/// `LocalStateIntent.setExportFolder`, so it never rides in the settings
/// blob. What the model owns is the observed access state of that folder
/// (`exportFolderAccess`, resolved off the main actor), the storage figures,
/// and the last cleanup outcome. Cleanup and folder choosing are closures
/// the shell wires; the view model reads no files and opens no windows on
/// its own beyond the folder panel.
@Observable
@MainActor
public final class DataPrivacyViewModel {
    /// The coordinator projection and the intent door.
    public let host: SettingsProjectionHost

    public var autoDeleteEnabled: Bool {
        get { host.settings.historyRetention.autoDeleteEnabled }
        set { update { $0.retention.autoDeleteEnabled = newValue } }
    }
    public var textRetentionDays: Int {
        get { host.settings.historyRetention.retentionDays }
        set { update { $0.retention.retentionDays = newValue } }
    }
    public var keepRecordings: Bool {
        get { host.settings.audioStorage.keepRecordings }
        set { update { $0.audio.keepRecordings = newValue } }
    }
    public var audioRetentionDays: Int {
        get { host.settings.audioStorage.retentionDays }
        set { update { $0.audio.retentionDays = newValue } }
    }
    public var autoDailyExportEnabled: Bool {
        get { host.settings.export.autoDailyExportEnabled }
        set { update { $0.export.autoDailyExportEnabled = newValue } }
    }

    /// The last refusal's sentence, for the section; nil otherwise.
    public var refusalNote: String? { host.refusalNote }

    /// Resolved by `refreshFolderAccess()`, never synchronously: resolving a
    /// bookmark touches the file system, and the folder may be on a volume
    /// that is slow or gone.  Until the first check a configured folder reads
    /// as `.notConfigured` with `isCheckingFolderAccess` set.
    public private(set) var exportFolderAccess: ExportFolderAccess = .notConfigured
    public private(set) var isCheckingFolderAccess: Bool
    public private(set) var metrics: DataPrivacyMetrics?
    public private(set) var lastCleanup: DataPrivacyCleanupOutcome?
    public private(set) var isRunningCleanup = false

    // MARK: Shell hooks

    /// Runs `HistoryMaintenance.runOnce(force: true)` and maps its report.
    @ObservationIgnored public var runCleanup: (@Sendable () async -> DataPrivacyCleanupOutcome?)?
    /// Storage figures; refreshed when the section appears and after cleanup.
    @ObservationIgnored public var metricsProvider: (@Sendable () async -> DataPrivacyMetrics?)?
    /// Presents the folder chooser.  Replaceable for tests.
    @ObservationIgnored public var chooseFolder: @MainActor () -> URL? = DataPrivacyViewModel.presentFolderPanel

    public init(host: SettingsProjectionHost = .detached()) {
        self.host = host
        isCheckingFolderAccess = host.localState.exportFolder != nil
    }

    /// The folder grant as stored for this Mac (`LocalState.exportFolder`).
    public var exportFolder: ExportFolderGrant? {
        host.localState.exportFolder
    }

    public var exportFolderDisplayPath: String? {
        exportFolder?.displayPath
    }

    /// This section's three blocks as one editable value.
    private struct Block: Equatable {
        var retention: HistoryRetentionSettings
        var audio: AudioStorageSettings
        var export: ExportSettings
    }

    private var block: Block {
        let settings = host.settings
        return Block(retention: settings.historyRetention, audio: settings.audioStorage, export: settings.export)
    }

    /// One edit → one intent with the whole block; an unchanged edit sends
    /// nothing, and a refusal leaves every control where it was.
    private func update(_ change: (inout Block) -> Void) {
        var next = block
        change(&next)
        guard next != block else { return }
        host.send(.setDataPrivacy(
            historyRetention: next.retention,
            audioStorage: next.audio,
            export: next.export,
            origin: .page(.dataPrivacy)
        ))
    }

    /// Re-resolves the bookmark off the main actor (the folder may have come
    /// back, gone away, or been moved since the section last looked).  The
    /// view runs this when the section appears.
    public func refreshFolderAccess() async {
        guard let bookmark = exportFolder?.bookmark else {
            exportFolderAccess = .notConfigured
            isCheckingFolderAccess = false
            return
        }
        isCheckingFolderAccess = true
        let displayPath = exportFolderDisplayPath
        let access = await Task.detached(priority: .utility) {
            ExportFolderAccess.resolve(bookmark, displayPath: displayPath)
        }.value
        // A folder chosen while the check ran wins.
        guard exportFolder?.bookmark == bookmark else { return }
        exportFolderAccess = access
        isCheckingFolderAccess = false
    }

    public var needsReauthorization: Bool {
        exportFolderAccess == .needsReauthorization
    }

    /// Choose (or re-authorize) the export folder.  A cancelled panel changes
    /// nothing.
    public func chooseExportFolder() {
        guard let folder = chooseFolder() else { return }
        setExportFolder(folder)
    }

    /// Stores a folder the user picked as a security-scoped bookmark.
    public func setExportFolder(_ folder: URL) {
        guard let bookmark = try? ExportFolderAccess.makeBookmark(for: folder) else {
            exportFolderAccess = .needsReauthorization
            return
        }
        let grant = ExportFolderGrant(bookmark: bookmark, displayPath: folder.path)
        guard host.send(.setExportFolder(grant, origin: .page(.dataPrivacy))) == nil else { return }
        // The panel just returned this folder; no file-system check needed.
        exportFolderAccess = .available(folder)
        isCheckingFolderAccess = false
    }

    public func clearExportFolder() {
        guard host.send(.setExportFolder(nil, origin: .page(.dataPrivacy))) == nil else { return }
        exportFolderAccess = .notConfigured
        isCheckingFolderAccess = false
        // The toggle is a preference and follows through the settings path.
        autoDailyExportEnabled = false
    }

    public func refreshMetrics() async {
        guard let metricsProvider else { return }
        metrics = await metricsProvider()
    }

    /// "Run Transcript Cleanup Now" (confirmed by the view).
    public func runCleanupNow() async {
        guard let runCleanup, !isRunningCleanup else { return }
        isRunningCleanup = true
        defer { isRunningCleanup = false }
        lastCleanup = await runCleanup()
        await refreshMetrics()
    }

    public var lastCleanupDescription: String? {
        guard let lastCleanup else { return nil }
        let entries = lastCleanup.deletedEntries == 1 ? String(localized: "1 transcript", bundle: .module) : String(localized: "\(lastCleanup.deletedEntries) transcripts", bundle: .module)
        let audio = lastCleanup.deletedAudioFiles == 1 ? String(localized: "1 recording", bundle: .module) : String(localized: "\(lastCleanup.deletedAudioFiles) recordings", bundle: .module)
        let base = String(localized: "Removed \(entries) and \(audio).", bundle: .module)
        return lastCleanup.hadErrors ? base + " " + String(localized: "Some items could not be removed.", bundle: .module) : base
    }

    public var metricsDescription: String? {
        guard let metrics else { return nil }
        let entries = metrics.entryCount == 1 ? String(localized: "1 transcript", bundle: .module) : String(localized: "\(metrics.entryCount) transcripts", bundle: .module)
        var parts = [entries, metrics.databaseBytes.formatted(.byteCount(style: .file))]
        if metrics.audioBytes > 0 {
            parts.append(String(localized: "audio \(metrics.audioBytes.formatted(.byteCount(style: .file)))", bundle: .module))
        }
        return parts.joined(separator: " · ")
    }

    /// Default folder chooser.  Public only so it can be a default value.
    public static func presentFolderPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Auto Daily Export Folder", bundle: .module)
        panel.message = String(localized: "Choose the folder where a Markdown file for each day is kept.", bundle: .module)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", bundle: .module)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
