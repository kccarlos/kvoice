import XCTest
@testable import KvoiceDomain

/// ADR-022 slice 5: the machine-local blob and its one-time seeding from
/// the pre-split `AppSettings` JSON.
final class LocalStateTests: XCTestCase {
    private static let grant = ExportFolderGrant(bookmark: Data("bookmark".utf8), displayPath: "/Users/x/Transcripts")

    func testRoundTrip() throws {
        let state = LocalState(
            onboardingVersionCompleted: 3,
            tutorialSeen: true,
            mainWindowSection: "history",
            exportFolder: Self.grant
        )
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(LocalState.self, from: data), state)
    }

    func testEveryKeyDecodesWhenMissing() throws {
        XCTAssertEqual(try JSONDecoder().decode(LocalState.self, from: Data("{}".utf8)), .fresh)
        let partial = Data(#"{"tutorialSeen": true}"#.utf8)
        var expected = LocalState.fresh
        expected.tutorialSeen = true
        XCTAssertEqual(try JSONDecoder().decode(LocalState.self, from: partial), expected)
    }

    func testNewerSchemaIsRefused() {
        XCTAssertThrowsError(try JSONDecoder().decode(LocalState.self, from: Data(#"{"schemaVersion": 99}"#.utf8)))
    }

    func testKeysListEveryCodingKey() {
        XCTAssertEqual(
            Set(LocalState.keys),
            ["schemaVersion", "onboardingVersionCompleted", "tutorialSeen", "mainWindowSection", "exportFolder"]
        )
    }

    // MARK: Seeding from the old AppSettings blob

    func testSeedsFromALegacySettingsBlob() throws {
        let legacy = """
        {
          "schemaVersion": 1,
          "onboardingVersionCompleted": 2,
          "tutorialSeen": true,
          "mainWindowSection": "dictionary",
          "showDockIcon": true,
          "export": {
            "autoDailyExportEnabled": true,
            "autoExportFolderBookmark": "\(Data("bookmark".utf8).base64EncodedString())",
            "autoExportFolderDisplayPath": "/Users/x/Transcripts"
          }
        }
        """
        let seeded = try XCTUnwrap(LocalState.seeded(fromLegacySettingsData: Data(legacy.utf8)))
        XCTAssertEqual(seeded.onboardingVersionCompleted, 2)
        XCTAssertTrue(seeded.tutorialSeen)
        XCTAssertEqual(seeded.mainWindowSection, "dictionary")
        XCTAssertEqual(seeded.exportFolder, Self.grant)
        XCTAssertEqual(seeded.schemaVersion, LocalState.currentSchemaVersion)
    }

    func testSeedsAPartialLegacyBlob() throws {
        // Only the completion flag was ever written (a user who never chose
        // a folder or opened the tutorial).
        let legacy = Data(#"{"schemaVersion": 1, "onboardingVersionCompleted": 1}"#.utf8)
        let seeded = try XCTUnwrap(LocalState.seeded(fromLegacySettingsData: legacy))
        XCTAssertEqual(seeded.onboardingVersionCompleted, 1)
        XCTAssertFalse(seeded.tutorialSeen)
        XCTAssertNil(seeded.mainWindowSection)
        XCTAssertNil(seeded.exportFolder)
    }

    func testABlobWithoutLegacyKeysSeedsNothing() {
        // A post-split blob (or a fresh one): nothing to migrate, so the
        // store must not overwrite a newer local-state file with defaults.
        let modern = Data(#"{"schemaVersion": 1, "showDockIcon": true, "export": {"autoDailyExportEnabled": true}}"#.utf8)
        XCTAssertNil(LocalState.seeded(fromLegacySettingsData: modern))
        XCTAssertNil(LocalState.seeded(fromLegacySettingsData: Data("not json".utf8)))
    }

    func testADisplayPathWithoutABookmarkIsNotAGrant() throws {
        // The bookmark is the authority; a path alone cannot resolve.
        let legacy = Data(#"{"export": {"autoExportFolderDisplayPath": "/Users/x/T"}}"#.utf8)
        let seeded = try XCTUnwrap(LocalState.seeded(fromLegacySettingsData: legacy))
        XCTAssertNil(seeded.exportFolder)
    }

    func testAppSettingsDecoderIgnoresTheLegacyKeys() throws {
        let legacy = """
        {
          "schemaVersion": 1,
          "onboardingVersionCompleted": 2,
          "tutorialSeen": true,
          "mainWindowSection": "dictionary",
          "launchAtLogin": true,
          "export": {
            "autoDailyExportEnabled": true,
            "autoExportFolderBookmark": "Ym9vaw==",
            "autoExportFolderDisplayPath": "/Users/x/Transcripts"
          }
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertTrue(settings.export.autoDailyExportEnabled)
        // Re-encoding drops them: the next save writes a clean blob.
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        for key in LocalState.legacyTopLevelKeys + LocalState.legacyExportKeys {
            XCTAssertFalse(json.contains("\"\(key)\""), key)
        }
    }
}
