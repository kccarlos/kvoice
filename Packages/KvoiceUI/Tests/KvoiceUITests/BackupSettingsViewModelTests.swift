import Foundation
import XCTest
import KvoiceAppCore
@testable import KvoiceDomain
@testable import KvoiceUI

/// Settings › General › Backup (KNOWN_ISSUES "Later waves": import/export
/// settings backup). File I/O runs against a real temp directory — only the
/// panels are stubbed — matching `DictionaryViewModelTests`. ADR-022 slice 7
/// part B: the model is a projection, so `makeModel` builds it over a
/// `SettingsProjectionTestHarness` — `applied()` reads back every
/// `.replaceAll` the model sent itself, in place of the old
/// `applyImportedSettings` callback.
@MainActor
final class BackupSettingsViewModelTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    private func makeModel(
        current: AppSettings = AppSettings(),
        isIdle: Bool = true,
        clock: @escaping @MainActor () -> Date = { Date(timeIntervalSince1970: 1_757_800_000) }
    ) -> (model: BackupSettingsViewModel, harness: SettingsProjectionTestHarness, applied: () -> [AppSettings]) {
        let harness = SettingsProjectionTestHarness(settings: current)
        let model = BackupSettingsViewModel(
            host: harness.host,
            backupsDirectory: tempDirectory.appendingPathComponent("Backups", isDirectory: true)
        )
        model.isIdle = { isIdle }
        model.appVersion = { "1.0 (1)" }
        model.now = clock
        let applied: () -> [AppSettings] = {
            harness.sent.compactMap {
                if case .replaceAll(let settings, _) = $0 { return settings }
                return nil
            }
        }
        return (model, harness, applied)
    }

    private func sample(historyEnabled: Bool = true, shortcutKey: String = "space") -> AppSettings {
        AppSettings(
            shortcut: ShortcutDefinition(key: shortcutKey, modifiers: ["control", "shift"]),
            historyEnabled: historyEnabled
        )
    }

    // MARK: Export

    func testExportWritesAFileThatImportsBackToTheSameSettings() {
        let settings = sample()
        let (exporter, _, _) = makeModel(current: settings)
        let file = tempDirectory.appendingPathComponent("export.json")
        exporter.chooseExportFile = { file }
        exporter.exportToPanel()
        XCTAssertEqual(exporter.message, "Exported settings to “export.json”.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let (importer, _, _) = makeModel(current: AppSettings())
        importer.chooseImportFile = { file }
        importer.importFromPanel()
        XCTAssertEqual(importer.pendingChange?.envelope.settings, settings)
        XCTAssertEqual(importer.pendingChange?.diff.shortcutChanged, true, "the file's shortcut differs from the fresh default")
    }

    func testExportedEnvelopeNeverContainsSecretMaterial() throws {
        let (model, _, _) = makeModel(current: sample())
        let file = tempDirectory.appendingPathComponent("export.json")
        model.chooseExportFile = { file }
        model.exportToPanel()
        let json = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("apiKey"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("secretSettings"))
    }

    func testExportPanelCancelledDoesNothing() {
        let (model, _, _) = makeModel()
        model.chooseExportFile = { nil }
        model.exportToPanel()
        XCTAssertNil(model.message)
    }

    // MARK: Import validation

    func testImportOfMalformedFileIsRefusedAndAppliesNothing() {
        let file = tempDirectory.appendingPathComponent("bad.json")
        try? Data("not json".utf8).write(to: file)
        let (model, _, applied) = makeModel()
        model.chooseImportFile = { file }
        model.importFromPanel()
        XCTAssertNil(model.pendingChange)
        XCTAssertEqual(model.message, "Could not read this file. It may be damaged, or not a KVoice settings export.")
        XCTAssertTrue(applied().isEmpty)
    }

    func testImportOfNewerFormatVersionIsRefusedAndAppliesNothing() throws {
        struct FutureEnvelope: Encodable {
            let formatVersion: Int
            let appVersion: String
            let exportedAt: Date
            let settings: AppSettings
        }
        let data = try SettingsBackupCoding.makeEncoder().encode(
            FutureEnvelope(
                formatVersion: SettingsBackupEnvelope.currentFormatVersion + 1,
                appVersion: "9.9",
                exportedAt: Date(),
                settings: sample()
            )
        )
        let file = tempDirectory.appendingPathComponent("future.json")
        try data.write(to: file)

        let (model, _, applied) = makeModel()
        model.chooseImportFile = { file }
        model.importFromPanel()
        XCTAssertNil(model.pendingChange)
        XCTAssertTrue(model.message?.contains("newer version of KVoice") == true)
        XCTAssertTrue(applied().isEmpty)
    }

    func testImportPanelCancelledDoesNothing() {
        let (model, _, _) = makeModel()
        model.chooseImportFile = { nil }
        model.importFromPanel()
        XCTAssertNil(model.pendingChange)
        XCTAssertNil(model.message)
    }

    // MARK: Confirm — idle vs busy

    func testConfirmWhileIdleWritesAutomaticBackupThenApplies() throws {
        let current = sample(historyEnabled: true)
        let incoming = sample(historyEnabled: false)
        let (model, _, applied) = makeModel(current: current, isIdle: true)
        let file = tempDirectory.appendingPathComponent("import.json")
        try SettingsBackupCoding.encode(
            SettingsBackupEnvelope(appVersion: "1.0", exportedAt: Date(), settings: incoming)
        ).write(to: file)

        model.chooseImportFile = { file }
        model.importFromPanel()
        XCTAssertNotNil(model.pendingChange)

        model.confirmPendingChange()
        XCTAssertNil(model.pendingChange, "confirming clears the pending change")
        XCTAssertEqual(applied(), [incoming])
        XCTAssertEqual(model.message, "Settings applied.")

        // The automatic backup snapshots what was current *before* the
        // import, and shows up in the Restore list.
        XCTAssertEqual(model.backups.count, 1)
        let backupData = try Data(contentsOf: model.backups[0].url)
        let backupEnvelope = try SettingsBackupCoding.decode(backupData)
        XCTAssertEqual(backupEnvelope.settings, current)
    }

    /// Import confirmed through `confirmPendingChange()` is the reducer's
    /// `.replaceAll`, which owes the same relaunch consent a manual
    /// language pick gets when the imported file changes the interface
    /// language — this is an effect of the intent the model sends itself,
    /// not something `BackupSettingsViewModel` has to ask for separately.
    func testConfirmingAnImportThatChangesTheLanguageOffersARelaunch() throws {
        let current = sample()
        var incoming = sample(shortcutKey: "j")
        incoming.interfaceLanguage = .simplifiedChinese
        let (model, harness, _) = makeModel(current: current, isIdle: true)
        let file = tempDirectory.appendingPathComponent("import.json")
        try SettingsBackupCoding.encode(
            SettingsBackupEnvelope(appVersion: "1.0", exportedAt: Date(), settings: incoming)
        ).write(to: file)

        model.chooseImportFile = { file }
        model.importFromPanel()
        model.confirmPendingChange()

        XCTAssertTrue(harness.effects.contains(.offerRelaunch(.simplifiedChinese)))
    }

    /// ADR-022 slice 5: the folder grant is `LocalState`, which the backup
    /// envelope has no field for — the file cannot carry it. This test keeps
    /// the historical canary (the bookmark leaked once, before the split).
    func testAutomaticBackupNeverContainsTheFolderBookmarkOrDisplayPath() throws {
        var current = sample()
        current.export = ExportSettings(autoDailyExportEnabled: true)
        let (model, _, _) = makeModel(current: current, isIdle: true)
        let file = tempDirectory.appendingPathComponent("import.json")
        try SettingsBackupCoding.encode(
            SettingsBackupEnvelope(appVersion: "1.0", exportedAt: Date(), settings: sample(shortcutKey: "j"))
        ).write(to: file)

        model.chooseImportFile = { file }
        model.importFromPanel()
        model.confirmPendingChange()

        XCTAssertEqual(model.backups.count, 1)
        let raw = try String(contentsOf: model.backups[0].url, encoding: .utf8)
        XCTAssertFalse(raw.contains("canary-bookmark-bytes"))
        XCTAssertFalse(raw.contains("/Users/someone/Desktop/Transcripts"))
        XCTAssertFalse(raw.contains("autoExportFolderBookmark"))
        XCTAssertFalse(raw.contains("exportFolder"))
        let decoded = try SettingsBackupCoding.decode(Data(contentsOf: model.backups[0].url))
        XCTAssertEqual(decoded.settings.export, ExportSettings(autoDailyExportEnabled: true))
    }

    func testConfirmWhileBusyRefusesAndWritesNoBackup() throws {
        let current = sample()
        let incoming = sample(shortcutKey: "j")
        let (model, _, applied) = makeModel(current: current, isIdle: false)
        let file = tempDirectory.appendingPathComponent("import.json")
        try SettingsBackupCoding.encode(
            SettingsBackupEnvelope(appVersion: "1.0", exportedAt: Date(), settings: incoming)
        ).write(to: file)

        model.chooseImportFile = { file }
        model.importFromPanel()
        model.confirmPendingChange()

        XCTAssertNil(model.pendingChange)
        XCTAssertTrue(applied().isEmpty, "nothing is applied while busy")
        XCTAssertEqual(model.message, "Finish the current dictation first, then try again.")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: model.backupsDirectory.path),
            "no automatic backup is written when the apply is refused"
        )
    }

    /// The idle pre-flight above races a job that started in between; the
    /// reducer's own gate on `.replaceAll` is what actually decides, and its
    /// note is what `message` shows — the automatic backup is never written.
    func testConfirmRefusedByTheReducerReportsTheReducersNoteAndWritesNoBackup() throws {
        let current = sample()
        let incoming = sample(shortcutKey: "j")
        let (model, harness, _) = makeModel(current: current, isIdle: true)
        let file = tempDirectory.appendingPathComponent("import.json")
        try SettingsBackupCoding.encode(
            SettingsBackupEnvelope(appVersion: "1.0", exportedAt: Date(), settings: incoming)
        ).write(to: file)

        model.chooseImportFile = { file }
        model.importFromPanel()
        harness.startJob()
        model.confirmPendingChange()

        XCTAssertNil(model.pendingChange)
        XCTAssertEqual(model.message, "Finish the current dictation first.")
        XCTAssertEqual(harness.settings, current, "the reducer's own refusal leaves the state untouched")
        XCTAssertFalse(harness.effects.contains(.persist), "a refused replaceAll runs no effect")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: model.backupsDirectory.path),
            "no automatic backup is written when the reducer refuses"
        )
    }

    func testCancelPendingChangeDiscardsItWithoutApplying() throws {
        let (model, _, applied) = makeModel()
        let file = tempDirectory.appendingPathComponent("import.json")
        try SettingsBackupCoding.encode(
            SettingsBackupEnvelope(appVersion: "1.0", exportedAt: Date(), settings: sample())
        ).write(to: file)
        model.chooseImportFile = { file }
        model.importFromPanel()
        XCTAssertNotNil(model.pendingChange)

        model.cancelPendingChange()
        XCTAssertNil(model.pendingChange)
        XCTAssertTrue(applied().isEmpty)
    }

    // MARK: Automatic backups: listing and pruning

    func testAutomaticBackupsArePrunedToTheNewestFive() throws {
        var tick = 0
        let (model, _, _) = makeModel(isIdle: true, clock: {
            tick += 1
            return Date(timeIntervalSince1970: TimeInterval(1_757_800_000 + tick))
        })
        let file = tempDirectory.appendingPathComponent("import.json")
        try SettingsBackupCoding.encode(
            SettingsBackupEnvelope(appVersion: "1.0", exportedAt: Date(), settings: sample())
        ).write(to: file)

        for _ in 0..<7 {
            model.chooseImportFile = { file }
            model.importFromPanel()
            model.confirmPendingChange()
        }

        XCTAssertEqual(model.backups.count, BackupSettingsViewModel.maxAutomaticBackups)
    }

    func testRestoreBackupDecodesAndDiffsAgainstCurrentSettings() throws {
        let current = sample(historyEnabled: true)
        let (model, _, applied) = makeModel(current: current, isIdle: true)
        // Seed one automatic backup by importing once.
        let differing = sample(historyEnabled: false)
        let file = tempDirectory.appendingPathComponent("import.json")
        try SettingsBackupCoding.encode(
            SettingsBackupEnvelope(appVersion: "1.0", exportedAt: Date(), settings: differing)
        ).write(to: file)
        model.chooseImportFile = { file }
        model.importFromPanel()
        model.confirmPendingChange()
        XCTAssertEqual(model.backups.count, 1)

        // Now restore that automatic backup (which snapshotted `current`).
        model.selectBackupForRestore(model.backups[0])
        XCTAssertEqual(model.pendingChange?.envelope.settings, current)
        if case .automaticBackup = model.pendingChange?.source {} else {
            XCTFail("expected an automaticBackup source")
        }
        model.confirmPendingChange()
        XCTAssertEqual(applied().last, current)
    }

    // MARK: Diff summary text

    func testSummaryTextForIdenticalSettings() {
        let diff = AppSettingsDiff(changedFieldCount: 0, shortcutChanged: false, changedActionCount: 0)
        XCTAssertEqual(
            BackupSettingsViewModel.summary(for: diff),
            "These settings are identical; nothing will change."
        )
    }

    func testSummaryTextCountsFieldsAndHighlightsShortcutAndActions() {
        let diff = AppSettingsDiff(changedFieldCount: 12, shortcutChanged: true, changedActionCount: 3)
        XCTAssertEqual(
            BackupSettingsViewModel.summary(for: diff),
            "12 settings differ. This includes the shortcut. 3 AI actions differ."
        )
    }

    func testSummaryTextSingularForms() {
        let diff = AppSettingsDiff(changedFieldCount: 1, shortcutChanged: false, changedActionCount: 1)
        XCTAssertEqual(
            BackupSettingsViewModel.summary(for: diff),
            "1 setting differs. 1 AI action differs."
        )
    }

    func testSummaryTextHighlightsInterfaceLanguageChange() {
        let diff = AppSettingsDiff(
            changedFieldCount: 2,
            shortcutChanged: false,
            interfaceLanguageChanged: true,
            changedActionCount: 0
        )
        XCTAssertEqual(
            BackupSettingsViewModel.summary(for: diff),
            "2 settings differ. This includes the interface language, which takes a relaunch."
        )
    }

    // MARK: Automatic backup filename collisions

    func testTwoConfirmsUnderTheSameClockSecondProduceTwoDistinctBackups() throws {
        let (model, _, _) = makeModel(isIdle: true, clock: { Date(timeIntervalSince1970: 1_757_800_000) })
        let file = tempDirectory.appendingPathComponent("import.json")
        try SettingsBackupCoding.encode(
            SettingsBackupEnvelope(appVersion: "1.0", exportedAt: Date(), settings: sample())
        ).write(to: file)

        model.chooseImportFile = { file }
        model.importFromPanel()
        model.confirmPendingChange()
        model.chooseImportFile = { file }
        model.importFromPanel()
        model.confirmPendingChange()

        XCTAssertEqual(model.backups.count, 2, "a fixed clock must not make the second write overwrite the first")
        let files = try FileManager.default.contentsOfDirectory(
            at: model.backupsDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(Set(files.map(\.lastPathComponent)).count, files.count, "file names must be unique")
    }
}
