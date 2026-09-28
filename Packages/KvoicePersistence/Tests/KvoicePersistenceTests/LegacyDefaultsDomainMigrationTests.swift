import Foundation
import XCTest
@testable import KvoiceDomain
@testable import KvoicePersistence

/// The one-time copy of the `com.kccarlos.kvoice` defaults domain into the
/// current bundle identifier's (2026-09-27). Every suite is a throwaway
/// UUID domain removed in `tearDown`, so nothing touches the real domains
/// and no plist is left behind in `~/Library/Preferences`.
final class LegacyDefaultsDomainMigrationTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    private func makeSuite(_ role: String) -> (name: String, defaults: UserDefaults) {
        let name = "kvoice.legacy-migration.\(role).\(UUID().uuidString)"
        suiteNames.append(name)
        return (name, UserDefaults(suiteName: name)!)
    }

    /// A legacy domain shaped like a real one: kvoice's two blobs, a
    /// KeyboardShortcuts recording, and a window frame.
    private func makeLegacyDomain() -> (name: String, defaults: UserDefaults) {
        let legacy = makeSuite("legacy")
        legacy.defaults.set(Data("settings".utf8), forKey: "com.kccarlos.kvoice.appSettings")
        legacy.defaults.set(Data("local".utf8), forKey: "com.kccarlos.kvoice.localState")
        legacy.defaults.set("{\"carbonKeyCode\":49}", forKey: "KeyboardShortcuts_kvoice.recording")
        legacy.defaults.set("10 10 600 400 0 0 1512 944 ", forKey: "NSWindow Frame kvoice.main")
        return legacy
    }

    private func migration(legacyName: String, target: (name: String, defaults: UserDefaults)) -> LegacyDefaultsDomainMigration {
        LegacyDefaultsDomainMigration(
            readLegacyDomain: { UserDefaults.standard.persistentDomain(forName: legacyName) },
            readCurrentDomain: { UserDefaults.standard.persistentDomain(forName: target.name) },
            target: target.defaults
        )
    }

    private func migration(legacyName: String, store: LayeredStore) -> LegacyDefaultsDomainMigration {
        LegacyDefaultsDomainMigration(
            readLegacyDomain: { UserDefaults.standard.persistentDomain(forName: legacyName) },
            readCurrentDomain: { store.appDomain },
            target: store
        )
    }

    func testKeyRenameAppliesOnlyToTheLegacyPrefix() {
        XCTAssertEqual(
            LegacyDefaultsDomainMigration.currentKey(forLegacyKey: "com.kccarlos.kvoice.appSettings"),
            SettingsStore.appSettingsKey
        )
        XCTAssertEqual(
            LegacyDefaultsDomainMigration.currentKey(forLegacyKey: "com.kccarlos.kvoice.localState"),
            LocalStateStore.localStateKey
        )
        XCTAssertEqual(
            LegacyDefaultsDomainMigration.currentKey(forLegacyKey: "KeyboardShortcuts_kvoice.recording"),
            "KeyboardShortcuts_kvoice.recording"
        )
        XCTAssertEqual(LegacyDefaultsDomainMigration.legacyDomainName, "com.kccarlos.kvoice")
    }

    func testNothingToMigrateRecordsCompletionAndWritesNothingElse() {
        let target = makeSuite("target")
        let outcome = migration(legacyName: "kvoice.legacy-migration.absent.\(UUID().uuidString)", target: target).run()

        XCTAssertEqual(outcome, .nothingToMigrate)
        XCTAssertEqual(
            UserDefaults.standard.persistentDomain(forName: target.name).map { Set($0.keys) },
            [LegacyDefaultsDomainMigration.completionKey]
        )
    }

    func testFullMigrationCopiesEveryKeyAndRenamesKvoiceKeys() async throws {
        let legacy = makeLegacyDomain()
        let target = makeSuite("target")

        let outcome = migration(legacyName: legacy.name, target: target).run()

        XCTAssertEqual(outcome, .migrated(copiedKeyCount: 4, keptExistingKeyCount: 0))
        XCTAssertEqual(target.defaults.data(forKey: SettingsStore.appSettingsKey), Data("settings".utf8))
        XCTAssertEqual(target.defaults.data(forKey: LocalStateStore.localStateKey), Data("local".utf8))
        XCTAssertEqual(target.defaults.string(forKey: "KeyboardShortcuts_kvoice.recording"), "{\"carbonKeyCode\":49}")
        XCTAssertEqual(target.defaults.string(forKey: "NSWindow Frame kvoice.main"), "10 10 600 400 0 0 1512 944 ")
        XCTAssertNil(target.defaults.object(forKey: "com.kccarlos.kvoice.appSettings"), "kvoice keys land under the new prefix only")
        XCTAssertEqual(target.defaults.object(forKey: LegacyDefaultsDomainMigration.completionKey) as? Bool, true)
        // The legacy domain is read, never modified.
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: legacy.name)?.count, 4)
    }

    func testMigratedSettingsBlobIsWhatSettingsStoreLoads() async throws {
        let legacy = makeSuite("legacy")
        var settings = AppSettings()
        settings.launchAtLogin = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        legacy.defaults.set(try encoder.encode(settings), forKey: "com.kccarlos.kvoice.appSettings")
        let target = makeSuite("target")

        migration(legacyName: legacy.name, target: target).run()

        let loaded = try await SettingsStore(suiteName: target.name).load()
        XCTAssertEqual(loaded, settings)
    }

    func testPartiallyPresentNewDataIsKeptAndTheRestCopied() {
        let legacy = makeLegacyDomain()
        let target = makeSuite("target")
        target.defaults.set(Data("newer".utf8), forKey: SettingsStore.appSettingsKey)

        let outcome = migration(legacyName: legacy.name, target: target).run()

        XCTAssertEqual(outcome, .migrated(copiedKeyCount: 3, keptExistingKeyCount: 1))
        XCTAssertEqual(target.defaults.data(forKey: SettingsStore.appSettingsKey), Data("newer".utf8), "a value already under the new identifier wins")
        XCTAssertEqual(target.defaults.data(forKey: LocalStateStore.localStateKey), Data("local".utf8))
    }

    func testRerunAfterSuccessIsANoOp() {
        let legacy = makeLegacyDomain()
        let target = makeSuite("target")
        let subject = migration(legacyName: legacy.name, target: target)
        subject.run()
        // The user changes a setting under the new identifier, then relaunches.
        target.defaults.set(Data("changed".utf8), forKey: SettingsStore.appSettingsKey)
        target.defaults.removeObject(forKey: "NSWindow Frame kvoice.main")

        XCTAssertEqual(subject.run(), .alreadyCompleted)
        XCTAssertEqual(target.defaults.data(forKey: SettingsStore.appSettingsKey), Data("changed".utf8))
        XCTAssertNil(target.defaults.object(forKey: "NSWindow Frame kvoice.main"), "a completed migration never copies again")
        XCTAssertNil(LegacyDefaultsDomainMigration.diagnosticEvent(for: .alreadyCompleted))
    }

    func testRefusedWriteLeavesLegacyIntactAndRetriesNextLaunch() {
        let legacy = makeLegacyDomain()
        let target = LayeredStore(refusing: LocalStateStore.localStateKey)

        let first = migration(legacyName: legacy.name, store: target).run()

        XCTAssertEqual(first, .failed(unverifiedKeyCount: 1))
        XCTAssertNil(target.appDomain[LegacyDefaultsDomainMigration.completionKey], "no completion without a verified copy")
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: legacy.name)?.count, 4, "the legacy domain is untouched")

        // Next launch: the store accepts the write; the keys that did land
        // last time are kept, the missing one is copied, and it completes.
        target.refusedKey = nil
        let second = migration(legacyName: legacy.name, store: target).run()
        XCTAssertEqual(second, .migrated(copiedKeyCount: 1, keptExistingKeyCount: 3))
        XCTAssertEqual(target.appDomain[LocalStateStore.localStateKey] as? Data, Data("local".utf8))
        XCTAssertEqual(target.appDomain[LegacyDefaultsDomainMigration.completionKey] as? Bool, true)
    }

    /// Regression (swift-reviewer, 2026-09-27): `AppleLanguages` always
    /// exists in `NSGlobalDomain`, so an `object(forKey:)` presence check
    /// saw it as "already present" and never copied the interface-language
    /// override. Presence is the app domain's own, not the search list's.
    func testKeyInheritedFromTheGlobalDomainIsStillCopied() {
        let legacy = makeSuite("legacy")
        legacy.defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        let store = LayeredStore()
        store.globalDomain["AppleLanguages"] = ["en-US", "zh-Hans-US"]

        let outcome = migration(legacyName: legacy.name, store: store).run()

        XCTAssertEqual(outcome, .migrated(copiedKeyCount: 1, keptExistingKeyCount: 0))
        XCTAssertEqual(store.appDomain["AppleLanguages"] as? [String], ["zh-Hans"])
    }

    /// The same through real `UserDefaults`: a suite's `object(forKey:)`
    /// also sees `NSGlobalDomain`, where `AppleLanguages` lives on every Mac.
    func testInterfaceLanguageOverrideIsCopiedThroughRealDefaults() {
        let legacy = makeSuite("legacy")
        legacy.defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        let target = makeSuite("target")

        let outcome = migration(legacyName: legacy.name, target: target).run()

        XCTAssertEqual(outcome, .migrated(copiedKeyCount: 1, keptExistingKeyCount: 0))
        XCTAssertEqual(
            UserDefaults.standard.persistentDomain(forName: target.name)?["AppleLanguages"] as? [String],
            ["zh-Hans"]
        )
    }

    func testDiagnosticsCarryCountsOnly() throws {
        let migrated = try XCTUnwrap(LegacyDefaultsDomainMigration.diagnosticEvent(for: .migrated(copiedKeyCount: 5, keptExistingKeyCount: 2)))
        XCTAssertEqual(migrated.name, .settingsLegacyDomainMigration)
        XCTAssertEqual(migrated.result, .success)
        XCTAssertEqual(migrated.attributes, DiagnosticAttributes(fileCount: 5))

        let failed = try XCTUnwrap(LegacyDefaultsDomainMigration.diagnosticEvent(for: .failed(unverifiedKeyCount: 1)))
        XCTAssertEqual(failed.result, .failure)
        XCTAssertEqual(failed.attributes, DiagnosticAttributes(fileCount: 1))

        let none = try XCTUnwrap(LegacyDefaultsDomainMigration.diagnosticEvent(for: .nothingToMigrate))
        XCTAssertEqual(none.result, .ignored)
    }
}

/// An in-memory model of the defaults search list: `object(forKey:)`
/// reads the app domain, then falls through to a global layer, as
/// `UserDefaults.standard` does; writes land in the app domain. A refused
/// key silently drops the write, the way a full disk or a preferences
/// daemon hiccup would look from here.
private final class LayeredStore: PreferencesKeyValueStore {
    var appDomain: [String: Any] = [:]
    var globalDomain: [String: Any] = [:]
    var refusedKey: String?

    init(refusing key: String? = nil) {
        refusedKey = key
    }

    func object(forKey defaultName: String) -> Any? {
        appDomain[defaultName] ?? globalDomain[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        guard defaultName != refusedKey else { return }
        appDomain[defaultName] = value
    }
}
