import Foundation
import XCTest
import KvoiceAppCore
@testable import KvoiceDomain
@testable import KvoiceUI

/// Settings › Data & Privacy as a projection (ADR-022 slice 7): the five
/// controls render the coordinator's blocks, each edit is one
/// `.setDataPrivacy` intent carrying the whole block, the folder grant is a
/// `LocalStateIntent` through the same host, and nothing is hydrated.
@MainActor
final class DataPrivacyViewModelTests: XCTestCase {
    func testEveryControlSendsTheWholeBlockAsOneIntent() throws {
        let base = AppSettings(
            showDockIcon: true,
            shortcut: ShortcutDefinition(key: "s", modifiers: ["command"]),
            ai: AIEndpointSettings(mode: .polish, baseURL: URL(string: "http://127.0.0.1:11434/v1"), modelID: "m"),
            historyEnabled: true,
            maxRecordingSeconds: 120
        )
        let harness = SettingsProjectionTestHarness(settings: base)
        let model = DataPrivacyViewModel(host: harness.host)
        XCTAssertTrue(harness.sent.isEmpty, "rendering never sends")
        XCTAssertFalse(model.autoDeleteEnabled)
        XCTAssertEqual(model.textRetentionDays, 30)
        XCTAssertFalse(model.keepRecordings, "stored audio is opt-in")
        XCTAssertEqual(model.audioRetentionDays, 7)
        XCTAssertFalse(model.autoDailyExportEnabled)
        XCTAssertEqual(model.exportFolderAccess, .notConfigured)
        XCTAssertFalse(model.isCheckingFolderAccess, "no bookmark, nothing to check")

        model.autoDeleteEnabled = true
        model.textRetentionDays = 90
        model.keepRecordings = true
        model.audioRetentionDays = 3
        model.autoDailyExportEnabled = true
        model.autoDailyExportEnabled = true

        XCTAssertEqual(harness.sent.count, 5, "equal assignments do not send")
        XCTAssertEqual(harness.sent.last, .setDataPrivacy(
            historyRetention: HistoryRetentionSettings(autoDeleteEnabled: true, retentionDays: 90),
            audioStorage: AudioStorageSettings(keepRecordings: true, retentionDays: 3),
            export: ExportSettings(autoDailyExportEnabled: true),
            origin: .page(.dataPrivacy)
        ))
        let stored = harness.settings
        XCTAssertTrue(stored.historyEnabled, "Save History belongs to HistoryViewModel; this section never touches it")
        XCTAssertEqual(stored.historyRetention, HistoryRetentionSettings(autoDeleteEnabled: true, retentionDays: 90))
        XCTAssertEqual(stored.audioStorage, AudioStorageSettings(keepRecordings: true, retentionDays: 3))
        XCTAssertTrue(stored.export.autoDailyExportEnabled)
        // Everything the section does not own is untouched.
        XCTAssertTrue(stored.showDockIcon)
        XCTAssertEqual(stored.shortcut, base.shortcut)
        XCTAssertEqual(stored.ai, base.ai)
        XCTAssertEqual(stored.maxRecordingSeconds, 120)
        XCTAssertEqual(harness.effects.last, .persist)
    }

    func testAChangeFromAnotherDoorRendersWithoutHydration() {
        let harness = SettingsProjectionTestHarness()
        let model = DataPrivacyViewModel(host: harness.host)
        harness.commitFromElsewhere(.replaceAll(AppSettings(
            historyEnabled: false,
            historyRetention: HistoryRetentionSettings(autoDeleteEnabled: true, retentionDays: 14),
            audioStorage: AudioStorageSettings(keepRecordings: true, retentionDays: 1)
        ), origin: .import))
        XCTAssertTrue(model.autoDeleteEnabled)
        XCTAssertEqual(model.textRetentionDays, 14)
        XCTAssertTrue(model.keepRecordings)
        XCTAssertEqual(model.audioRetentionDays, 1)
        XCTAssertTrue(harness.sent.isEmpty)
    }

    /// `.setDataPrivacy` is loaded-gated only, so a job never refuses it;
    /// before the settings file is read a write is refused and the control
    /// snaps back with the note.
    func testARefusalSnapsBackWithTheNote() {
        let harness = SettingsProjectionTestHarness()
        let model = DataPrivacyViewModel(host: harness.host)
        harness.startJob()
        model.keepRecordings = true
        XCTAssertTrue(model.keepRecordings, "a job does not gate Data & Privacy")
        XCTAssertNil(model.refusalNote)

        harness.gate = SettingsGate(settingsLoaded: false)
        model.autoDeleteEnabled = true
        XCTAssertFalse(model.autoDeleteEnabled)
        XCTAssertEqual(model.refusalNote, "Finish the current dictation first.")
    }

    func testChoosingAFolderStoresABookmarkAndReauthorizationIsDetected() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvoice-data-privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let harness = SettingsProjectionTestHarness()
        let model = DataPrivacyViewModel(host: harness.host)
        model.chooseFolder = { folder }

        model.chooseExportFolder()

        guard case .available(let resolved) = model.exportFolderAccess else {
            return XCTFail("expected the folder to resolve, got \(model.exportFolderAccess)")
        }
        XCTAssertEqual(resolved.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        XCTAssertEqual(model.exportFolderDisplayPath, folder.path)
        XCTAssertFalse(model.needsReauthorization)
        // ADR-022 slice 5: the grant goes out as local state, never as a
        // settings change — the settings blob has no field for it.
        XCTAssertTrue(harness.sent.isEmpty, "choosing a folder is not a settings write")
        XCTAssertEqual(harness.sentLocalState.count, 1)
        guard case .setExportFolder(let grant, let origin) = harness.sentLocalState.last else {
            return XCTFail("expected setExportFolder")
        }
        XCTAssertEqual(origin, .page(.dataPrivacy))
        XCTAssertEqual(grant?.displayPath, folder.path)
        XCTAssertNotNil(grant?.bookmark)
        XCTAssertEqual(model.exportFolder, grant)
        XCTAssertEqual(harness.localState.exportFolder, grant, "the grant lives in local state")

        // A cancelled panel changes nothing.
        model.chooseFolder = { nil }
        model.chooseExportFolder()
        XCTAssertEqual(harness.sentLocalState.count, 1)

        // The folder disappears: the bookmark no longer resolves and the
        // section asks for re-authorization while keeping the old path for
        // display.
        try FileManager.default.removeItem(at: folder)
        await model.refreshFolderAccess()
        XCTAssertEqual(model.exportFolderAccess, .needsReauthorization)
        XCTAssertFalse(model.isCheckingFolderAccess)
        XCTAssertTrue(model.needsReauthorization)
        XCTAssertEqual(model.exportFolderDisplayPath, folder.path)

        // A second view model over the persisted local state does no file
        // I/O until asked (the folder may be on a slow volume), then sees
        // the same state.
        let rehydrated = DataPrivacyViewModel(host: .detached(localState: LocalState(exportFolder: try XCTUnwrap(grant))))
        XCTAssertTrue(rehydrated.isCheckingFolderAccess)
        XCTAssertEqual(rehydrated.exportFolderAccess, .notConfigured, "nothing resolved yet")
        await rehydrated.refreshFolderAccess()
        XCTAssertFalse(rehydrated.isCheckingFolderAccess)
        XCTAssertEqual(rehydrated.exportFolderAccess, .needsReauthorization)

        model.autoDailyExportEnabled = true
        model.clearExportFolder()
        XCTAssertEqual(model.exportFolderAccess, .notConfigured)
        XCTAssertFalse(model.autoDailyExportEnabled, "no folder means no auto export")
        XCTAssertEqual(harness.sentLocalState.count, 2)
        XCTAssertEqual(harness.sentLocalState.last, .setExportFolder(nil, origin: .page(.dataPrivacy)), "clearing sends a nil grant")
        XCTAssertNil(model.exportFolder)
        XCTAssertNil(harness.localState.exportFolder)
        // The toggle is a preference, so switching it off is a settings
        // write; the settings blob carries no bookmark by construction.
        XCTAssertEqual(harness.settings.export, ExportSettings(autoDailyExportEnabled: false))

        // A grant written from another door (the launch load) shows without
        // anything re-applied, and clearing it there does too.
        let other = SettingsProjectionTestHarness()
        let projected = DataPrivacyViewModel(host: other.host)
        other.commitFromElsewhere(.setExportFolder(ExportFolderGrant(bookmark: Data([1]), displayPath: "/x"), origin: .shell))
        XCTAssertEqual(projected.exportFolderDisplayPath, "/x")
        XCTAssertTrue(other.sentLocalState.isEmpty)
        other.commitFromElsewhere(.setExportFolder(nil, origin: .shell))
        XCTAssertNil(projected.exportFolder)
        await projected.refreshFolderAccess()
        XCTAssertEqual(projected.exportFolderAccess, .notConfigured)
    }

    func testRunCleanupNowReportsCountsAndRefreshesMetrics() async {
        let model = DataPrivacyViewModel()
        let calls = Counter()
        model.runCleanup = {
            await calls.increment()
            return DataPrivacyCleanupOutcome(deletedEntries: 3, deletedAudioFiles: 1)
        }
        model.metricsProvider = {
            let count = await calls.value
            return DataPrivacyMetrics(entryCount: 10 - count * 3, databaseBytes: 4_096, audioBytes: count == 0 ? 2_048 : 0)
        }

        await model.refreshMetrics()
        XCTAssertEqual(model.metrics, DataPrivacyMetrics(entryCount: 10, databaseBytes: 4_096, audioBytes: 2_048))
        // Byte units follow the locale ("kB" / "KB"), so compare against the formatter.
        let fourK = Int64(4_096).formatted(.byteCount(style: .file))
        let twoK = Int64(2_048).formatted(.byteCount(style: .file))
        XCTAssertEqual(model.metricsDescription, "10 transcripts · \(fourK) · audio \(twoK)")

        await model.runCleanupNow()

        XCTAssertFalse(model.isRunningCleanup)
        XCTAssertEqual(model.lastCleanup, DataPrivacyCleanupOutcome(deletedEntries: 3, deletedAudioFiles: 1))
        XCTAssertEqual(model.lastCleanupDescription, "Removed 3 transcripts and 1 recording.")
        XCTAssertEqual(model.metrics?.entryCount, 7, "metrics are re-read after cleanup")
        XCTAssertEqual(model.metricsDescription, "7 transcripts · \(fourK)")

        let errored = DataPrivacyViewModel()
        errored.runCleanup = { DataPrivacyCleanupOutcome(deletedEntries: 0, deletedAudioFiles: 0, hadErrors: true) }
        await errored.runCleanupNow()
        XCTAssertEqual(errored.lastCleanupDescription, "Removed 0 transcripts and 0 recordings. Some items could not be removed.")

        let unwired = DataPrivacyViewModel()
        await unwired.runCleanupNow()
        XCTAssertNil(unwired.lastCleanup, "no hook, no cleanup")
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
