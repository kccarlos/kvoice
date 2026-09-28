import Foundation
import XCTest
@testable import KvoiceDomain
@testable import KvoicePersistence

/// ADR-022 slice 5: the local-state store and its one-time seeding from
/// the pre-split settings blob.
final class LocalStateStoreTests: XCTestCase {
    private func makeSuiteName() -> String {
        "kvoice.localstate.tests.\(UUID().uuidString)"
    }

    /// An `AppSettings` blob as a build before 2026-09-16 wrote it: the
    /// local fields at the top level and the folder grant under `export`.
    private static let legacySettingsBlob = Data("""
    {
      "schemaVersion": 1,
      "onboardingVersionCompleted": 2,
      "tutorialSeen": true,
      "mainWindowSection": "dictionary",
      "launchAtLogin": true,
      "historyEnabled": false,
      "export": {
        "autoDailyExportEnabled": true,
        "autoExportFolderBookmark": "\(Data("bookmark".utf8).base64EncodedString())",
        "autoExportFolderDisplayPath": "/Users/x/Transcripts"
      }
    }
    """.utf8)

    func testFreshStoreIsFresh() async throws {
        let suite = makeSuiteName()
        let store = LocalStateStore(suiteName: suite)
        let state = try await store.load()
        XCTAssertEqual(state, .fresh)
        XCTAssertNil(UserDefaults(suiteName: suite)!.object(forKey: LocalStateStore.localStateKey), "nothing is written for a fresh install")
    }

    func testRoundTrip() async throws {
        let store = LocalStateStore(suiteName: makeSuiteName())
        let state = LocalState(
            onboardingVersionCompleted: 3,
            tutorialSeen: true,
            mainWindowSection: "history",
            exportFolder: ExportFolderGrant(bookmark: Data([1, 2, 3]), displayPath: "/tmp/x")
        )
        try await store.save(state)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, state)
    }

    func testMalformedValueIsQuarantined() async throws {
        let suite = makeSuiteName()
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Data("not json".utf8), forKey: LocalStateStore.localStateKey)
        let store = LocalStateStore(suiteName: suite)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, .fresh)
        XCTAssertNil(defaults.object(forKey: LocalStateStore.localStateKey))
    }

    // MARK: Migration

    func testFirstLoadSeedsFromTheLegacySettingsBlobOnce() async throws {
        let suite = makeSuiteName()
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Self.legacySettingsBlob, forKey: SettingsStore.appSettingsKey)
        let store = LocalStateStore(suiteName: suite)

        let seeded = try await store.load()
        XCTAssertEqual(seeded.onboardingVersionCompleted, 2)
        XCTAssertTrue(seeded.tutorialSeen)
        XCTAssertEqual(seeded.mainWindowSection, "dictionary")
        XCTAssertEqual(seeded.exportFolder, ExportFolderGrant(bookmark: Data("bookmark".utf8), displayPath: "/Users/x/Transcripts"))
        XCTAssertNotNil(defaults.object(forKey: LocalStateStore.localStateKey), "the seed is saved so it happens once")

        // Once seeded, the local blob is the truth: a change here is not
        // undone by the legacy keys still sitting in the settings blob.
        var changed = seeded
        changed.mainWindowSection = "general"
        try await store.save(changed)
        let reloaded = try await LocalStateStore(suiteName: suite).load()
        XCTAssertEqual(reloaded.mainWindowSection, "general")
    }

    func testTheSettingsStoreDropsTheLegacyKeysOnItsNextSave() async throws {
        let suite = makeSuiteName()
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Self.legacySettingsBlob, forKey: SettingsStore.appSettingsKey)

        // The settings themselves load with the preferences intact and the
        // local keys ignored…
        let settingsStore = SettingsStore(suiteName: suite)
        let settings = try await settingsStore.load()
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertFalse(settings.historyEnabled)
        XCTAssertTrue(settings.export.autoDailyExportEnabled)

        // …and the local state seeds from the same blob before that save.
        let localStore = LocalStateStore(suiteName: suite)
        let seeded = try await localStore.load()
        XCTAssertEqual(seeded.onboardingVersionCompleted, 2)

        // The next settings save writes a blob without the legacy keys.
        try await settingsStore.save(settings)
        let rewritten = try XCTUnwrap(defaults.data(forKey: SettingsStore.appSettingsKey))
        let json = String(decoding: rewritten, as: UTF8.self)
        for key in LocalState.legacyTopLevelKeys + LocalState.legacyExportKeys {
            XCTAssertFalse(json.contains("\"\(key)\""), "\(key) must not be written by the settings store any more")
        }
        XCTAssertFalse(json.contains("/Users/x/Transcripts"))

        // And the local state survives that rewrite (it was saved on seed).
        let survived = try await LocalStateStore(suiteName: suite).load()
        XCTAssertEqual(survived, seeded)
    }

    func testAModernSettingsBlobSeedsNothing() async throws {
        let suite = makeSuiteName()
        let defaults = UserDefaults(suiteName: suite)!
        let settingsStore = SettingsStore(suiteName: suite)
        var settings = AppSettings()
        settings.launchAtLogin = true
        try await settingsStore.save(settings)
        XCTAssertNotNil(defaults.data(forKey: SettingsStore.appSettingsKey))

        let loaded = try await LocalStateStore(suiteName: suite).load()
        XCTAssertEqual(loaded, .fresh)
        XCTAssertNil(defaults.object(forKey: LocalStateStore.localStateKey))
    }

    func testResetClearsTheValue() async throws {
        let suite = makeSuiteName()
        let store = LocalStateStore(suiteName: suite)
        try await store.save(LocalState(tutorialSeen: true))
        await store.reset()
        let afterReset = try await store.load()
        XCTAssertEqual(afterReset, .fresh)
    }
}
