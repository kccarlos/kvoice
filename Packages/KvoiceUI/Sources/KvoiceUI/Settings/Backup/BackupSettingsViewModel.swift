import AppKit
import Foundation
import KvoiceAppCore
import KvoiceDomain
import Observation
import UniformTypeIdentifiers

/// One file in the automatic-backup list (Settings › General › Backup ›
/// Restore Previous Settings).
public struct SettingsBackupListing: Identifiable, Sendable, Equatable {
    public var id: URL { url }
    public let url: URL
    public let exportedAt: Date

    public init(url: URL, exportedAt: Date) {
        self.url = url
        self.exportedAt = exportedAt
    }
}

/// A decoded file (an explicit Import, or a chosen automatic backup) waiting
/// on the user's confirmation before it replaces the current settings.
public struct PendingSettingsChange: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case importedFile(name: String)
        case automaticBackup(SettingsBackupListing)
    }

    public let source: Source
    public let envelope: SettingsBackupEnvelope
    public let diff: AppSettingsDiff
}

/// State for Settings › General › Backup (KNOWN_ISSUES "Later waves": import/
/// export settings backup).
///
/// Export and Import both go through `SettingsBackupEnvelope` /
/// `SettingsBackupCoding` (KvoiceDomain): one JSON file with `AppSettings`
/// plus a small envelope, never `SecretSettings` — API keys are never in the
/// file (the secrets rule in AGENTS.md), and `SettingsBackupCoding.encode` also strips
/// the Auto Daily Export folder's security-scoped bookmark and its
/// plaintext path (`AppSettings.redactedForBackup()`) — a capability grant
/// and a home-folder path are just as unfit to leave this Mac in a file.
/// `SettingsBackupTests` in KvoiceDomain asserts both. Import never applies
/// immediately: it decodes the file, diffs it against the live settings,
/// and waits in `pendingChange` for the view to show a confirmation before
/// `confirmPendingChange()` runs. Restoring an automatic backup reuses the
/// same decode → diff → confirm path.
///
/// Applying is idle-gated like every other dictation setting — a job in
/// flight holds its own settings snapshot — and, when it goes ahead, the
/// settings on disk are snapshotted to `backupsDirectory` first
/// (`settings-before-import-<date>.json`, newest 5 kept) so a bad import is
/// reversible from Restore Previous Settings.
///
/// ADR-022 slice 7 part B: a projection over `SettingsProjectionHost`. `isIdle`
/// stays as a UI-only pre-flight so the automatic backup file is never
/// written for a change that is about to be refused; the actual gate is the
/// reducer's own idle check on `.replaceAll`, run when `confirmPendingChange()`
/// sends the intent itself. A refusal (the idle pre-flight raced a job that
/// just started) discards the pending change and shows the reducer's note in
/// `message`, exactly like every other outcome this page reports.
///
/// Panels (`NSOpenPanel`/`NSSavePanel`) are the only pieces behind
/// injectable hooks; the rest of the file I/O runs against
/// `backupsDirectory` directly (a temp directory in tests), matching
/// `DictionaryViewModel`'s panel-only injection.
@Observable
@MainActor
public final class BackupSettingsViewModel {
    private static let backupFilePrefix = "settings-before-import-"
    /// Fixed-width and lexically sortable, so newest-first can be read off
    /// the file name alone without opening every file.
    private static let backupFileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
    /// The compiled retention (`DeveloperDefaults.automaticBackupRetentionCount`).
    public static let maxAutomaticBackups = 5
    /// How many automatic backups `pruneBackups()` keeps (ADR-022 slice 5:
    /// from the developer defaults the shell loaded).
    public let automaticBackupRetentionCount: Int

    /// The last outcome (success or refusal) shown under the buttons.
    public private(set) var message: String?
    /// Set once a file (Import or a chosen automatic backup) has been
    /// decoded and is waiting for the user to confirm or cancel it.
    public private(set) var pendingChange: PendingSettingsChange?
    /// The automatic pre-import backups, newest first.
    public private(set) var backups: [SettingsBackupListing] = []

    // MARK: Shell hooks

    /// The coordinator projection and the intent door.
    public let host: SettingsProjectionHost

    /// Presents the Export panel; replaceable so tests never open a panel.
    @ObservationIgnored public var chooseExportFile: @MainActor () -> URL? = BackupSettingsViewModel.presentExportPanel
    /// Presents the Import panel.
    @ObservationIgnored public var chooseImportFile: @MainActor () -> URL? = BackupSettingsViewModel.presentImportPanel
    /// Whether a change may be applied right now (no dictation in flight): a
    /// UI-only pre-flight, checked before the automatic backup file is
    /// written. The reducer's own idle check on `.replaceAll` is the actual
    /// gate.
    @ObservationIgnored public var isIdle: @MainActor () -> Bool = { true }
    @ObservationIgnored public var now: @MainActor () -> Date = { Date() }
    @ObservationIgnored public var appVersion: @MainActor () -> String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (version, build) {
        case (let version?, let build?): return "\(version) (\(build))"
        case (let version?, nil): return version
        default: return "development"
        }
    }
    /// Where automatic pre-import backups live. A temp directory in tests.
    @ObservationIgnored public var backupsDirectory: URL
    @ObservationIgnored private let fileManager: FileManager

    public init(
        host: SettingsProjectionHost = .detached(),
        backupsDirectory: URL = BackupSettingsViewModel.defaultBackupsDirectory(),
        fileManager: FileManager = .default,
        automaticBackupRetentionCount: Int = BackupSettingsViewModel.maxAutomaticBackups
    ) {
        self.host = host
        self.backupsDirectory = backupsDirectory
        self.fileManager = fileManager
        self.automaticBackupRetentionCount = max(1, automaticBackupRetentionCount)
    }

    public static func defaultBackupsDirectory(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("kvoice", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
    }

    // MARK: Export

    public func exportToPanel() {
        guard let url = chooseExportFile() else { return }
        exportFile(to: url)
    }

    public func exportFile(to url: URL) {
        let envelope = SettingsBackupEnvelope(
            appVersion: appVersion(),
            exportedAt: now(),
            settings: host.settings
        )
        do {
            let data = try SettingsBackupCoding.encode(envelope)
            try data.write(to: url, options: .atomic)
            message = String(localized: "Exported settings to “\(url.lastPathComponent)”.", bundle: .module)
        } catch {
            message = String(localized: "Could not write “\(url.lastPathComponent)”.", bundle: .module)
        }
    }

    // MARK: Import

    public func importFromPanel() {
        guard let url = chooseImportFile() else { return }
        importFile(at: url)
    }

    public func importFile(at url: URL) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            pendingChange = nil
            message = String(localized: "Could not read “\(url.lastPathComponent)”.", bundle: .module)
            return
        }
        switch decode(data) {
        case .success(let envelope):
            let diff = envelope.settings.diff(from: host.settings)
            pendingChange = PendingSettingsChange(
                source: .importedFile(name: url.lastPathComponent),
                envelope: envelope,
                diff: diff
            )
            message = nil
        case .failure(let error):
            pendingChange = nil
            message = Self.message(for: error)
        }
    }

    /// Cancels a pending Import or Restore without changing anything.
    public func cancelPendingChange() {
        pendingChange = nil
    }

    /// Applies `pendingChange`: refuses while a dictation is running (the
    /// pending change is discarded — nothing was applied, the user re-opens
    /// the file or reselects the backup to try again), otherwise writes the
    /// automatic backup and sends `.replaceAll` itself.
    public func confirmPendingChange() {
        guard let pending = pendingChange else { return }
        pendingChange = nil
        guard isIdle() else {
            message = String(
                localized: "Finish the current dictation first, then try again.",
                bundle: .module
            )
            return
        }
        let origin: SettingsOrigin
        switch pending.source {
        case .importedFile: origin = .import
        case .automaticBackup: origin = .restore
        }
        // Snapshot the "before" state ahead of the send: once `send`
        // returns without a refusal, `host.settings` already reads the
        // imported value. The idle pre-flight above can still race a job
        // that started in between; the reducer's own gate on `.replaceAll`
        // is what actually decides, and a refusal here — the automatic
        // backup never written — reports the same way every other outcome
        // this page shows does.
        let previousSettings = host.settings
        if let refusal = host.send(.replaceAll(pending.envelope.settings, origin: origin)) {
            message = SettingsProjectionHost.note(for: refusal)
            return
        }
        writeAutomaticBackup(of: previousSettings)
        message = String(localized: "Settings applied.", bundle: .module)
        refreshBackups()
    }

    private func decode(_ data: Data) -> Result<SettingsBackupEnvelope, SettingsBackupImportError> {
        do {
            return .success(try SettingsBackupCoding.decode(data))
        } catch let error as SettingsBackupImportError {
            return .failure(error)
        } catch {
            return .failure(.malformed)
        }
    }

    private static func message(for error: SettingsBackupImportError) -> String {
        switch error {
        case .unsupportedFormatVersion(let found, let supported):
            return String(
                localized: "This file was exported by a newer version of KVoice (format \(found)); this version supports up to format \(supported). Update KVoice and try again.",
                bundle: .module
            )
        case .malformed:
            return String(
                localized: "Could not read this file. It may be damaged, or not a KVoice settings export.",
                bundle: .module
            )
        }
    }

    // MARK: Restore Previous Settings

    /// Rescans `backupsDirectory`, newest first. Cheap enough to call every
    /// time the Backup section appears — at most `maxAutomaticBackups` files.
    public func refreshBackups() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            backups = []
            return
        }
        backups = files
            .filter { $0.lastPathComponent.hasPrefix(Self.backupFilePrefix) }
            .compactMap { url -> SettingsBackupListing? in
                guard let data = try? Data(contentsOf: url),
                      let envelope = try? SettingsBackupCoding.decode(data) else { return nil }
                return SettingsBackupListing(url: url, exportedAt: envelope.exportedAt)
            }
            .sorted { $0.exportedAt > $1.exportedAt }
    }

    public func selectBackupForRestore(_ listing: SettingsBackupListing) {
        guard let data = try? Data(contentsOf: listing.url) else {
            message = String(localized: "That backup could not be read. It may have been moved or deleted.", bundle: .module)
            refreshBackups()
            return
        }
        switch decode(data) {
        case .success(let envelope):
            let diff = envelope.settings.diff(from: host.settings)
            pendingChange = PendingSettingsChange(
                source: .automaticBackup(listing),
                envelope: envelope,
                diff: diff
            )
            message = nil
        case .failure:
            message = String(localized: "That backup could not be read. It may have been moved or deleted.", bundle: .module)
            refreshBackups()
        }
    }

    // MARK: Automatic backups

    private func writeAutomaticBackup(of settings: AppSettings) {
        let exportedAt = now()
        let envelope = SettingsBackupEnvelope(appVersion: appVersion(), exportedAt: exportedAt, settings: settings)
        guard let data = try? SettingsBackupCoding.encode(envelope) else { return }
        try? fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let url = backupsDirectory.appendingPathComponent(uniqueBackupFileName(for: exportedAt))
        try? data.write(to: url, options: .atomic)
        pruneBackups()
    }

    /// `backupFileNameFormatter` only resolves to the second, so two imports
    /// confirmed inside the same wall-clock second (or two writes under a
    /// test's fixed clock) would otherwise silently overwrite one another.
    /// A zero-padded, always-present `-NN` sequence keeps every write, and
    /// keeps `pruneBackups()`'s lexical newest-first sort correct: the date
    /// component still dominates, and within one second a higher sequence
    /// sorts after a lower one exactly as it was written.
    private func uniqueBackupFileName(for date: Date) -> String {
        let base = "\(Self.backupFilePrefix)\(Self.backupFileNameFormatter.string(from: date))"
        var sequence = 1
        while true {
            let name = "\(base)-\(String(format: "%02d", sequence)).json"
            if !fileManager.fileExists(atPath: backupsDirectory.appendingPathComponent(name).path) {
                return name
            }
            sequence += 1
        }
    }

    /// Keeps the newest `maxAutomaticBackups` files by name (the timestamped
    /// name sorts newest-last), deleting the rest.
    private func pruneBackups() {
        guard let files = try? fileManager.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        let matching = files
            .filter { $0.lastPathComponent.hasPrefix(Self.backupFilePrefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in matching.dropFirst(automaticBackupRetentionCount) {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: Diff summary

    /// Whole, independent sentences only (never a fragment spliced into
    /// another), per `Docs/Localization.md`: Chinese has no plural and other
    /// languages reorder, so the count and each highlight are complete
    /// sentences joined with a space, the same pattern `DictionaryViewModel`
    /// uses for its import summary.
    public static func summary(for diff: AppSettingsDiff) -> String {
        guard diff.hasChanges else {
            return String(localized: "These settings are identical; nothing will change.", bundle: .module)
        }
        var parts: [String] = [
            diff.changedFieldCount == 1
                ? String(localized: "1 setting differs.", bundle: .module)
                : String(localized: "\(diff.changedFieldCount) settings differ.", bundle: .module)
        ]
        if diff.shortcutChanged {
            parts.append(String(localized: "This includes the shortcut.", bundle: .module))
        }
        if diff.interfaceLanguageChanged {
            parts.append(String(localized: "This includes the interface language, which takes a relaunch.", bundle: .module))
        }
        if diff.changedActionCount == 1 {
            parts.append(String(localized: "1 AI action differs.", bundle: .module))
        } else if diff.changedActionCount > 1 {
            parts.append(String(localized: "\(diff.changedActionCount) AI actions differ.", bundle: .module))
        }
        return parts.joined(separator: " ")
    }

    // MARK: Panels

    public static func presentExportPanel() -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Settings", bundle: .module)
        panel.message = String(localized: "API keys and the Auto Daily Export folder grant are never exported; re-choose the folder after importing.", bundle: .module)
        panel.nameFieldStringValue = "kvoice-settings-\(exportFileDateStamp()).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export", bundle: .module)
        return panel.runModal() == .OK ? panel.url : nil
    }

    public static func presentImportPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Settings", bundle: .module)
        panel.message = String(localized: "Choose a KVoice settings export. You will see what changes before anything is applied.", bundle: .module)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = String(localized: "Import", bundle: .module)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func exportFileDateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}
