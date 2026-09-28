import XCTest
@testable import KvoiceDomain

/// Settings backup (export/import): the envelope round-trips `AppSettings`
/// exactly, refuses a file from a newer format or malformed JSON before
/// decoding anything, never carries secrets, and the diff the import
/// confirmation shows counts what actually changed.
final class SettingsBackupTests: XCTestCase {
    /// Fixed so two calls describe the same action, not two different ones
    /// with coincidentally equal fields — `diff` compares prompt modes by
    /// this `id`.
    private static let samplePromptModeID = UUID()

    private func sampleSettings(shortcutKey: String = "space") -> AppSettings {
        var settings = AppSettings(
            shortcut: ShortcutDefinition(key: shortcutKey, modifiers: ["control", "shift"]),
            selectedModel: .managed(modelID: "model", revision: "revision"),
            ai: AIEndpointSettings(promptConfiguration: PromptConfiguration())
        )
        settings.ai.promptModes = [
            PromptMode(id: Self.samplePromptModeID, name: "Polish", behavior: .polish, prompt: "Polish it.")
        ]
        settings.dictionary = DictionarySettings(terms: ["kvoice", "WhisperKit"])
        // Not the default, so the envelope test proves the cue set travels.
        settings.recordingFeedback.cueSet = .system(name: "Glass")
        return settings
    }

    // MARK: Round trip

    func testEncodeDecodeRoundTripsTheWholeEnvelope() throws {
        let settings = sampleSettings()
        let envelope = SettingsBackupEnvelope(
            appVersion: "1.2 (34)",
            exportedAt: Date(timeIntervalSince1970: 1_757_800_000),
            settings: settings
        )
        let data = try SettingsBackupCoding.encode(envelope)
        let decoded = try SettingsBackupCoding.decode(data)
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.settings, settings)
        XCTAssertEqual(decoded.formatVersion, SettingsBackupEnvelope.currentFormatVersion)
    }

    func testEncodingIsDeterministic() throws {
        let envelope = SettingsBackupEnvelope(
            appVersion: "1.0",
            exportedAt: Date(timeIntervalSince1970: 0),
            settings: sampleSettings()
        )
        let first = try SettingsBackupCoding.encode(envelope)
        let second = try SettingsBackupCoding.encode(envelope)
        XCTAssertEqual(first, second)
    }

    // MARK: Envelope validation

    func testNewerFormatVersionIsRefusedBeforeDecodingSettings() throws {
        let future = try SettingsBackupCoding.makeEncoder().encode(
            FutureEnvelope(
                formatVersion: SettingsBackupEnvelope.currentFormatVersion + 1,
                appVersion: "9.9",
                exportedAt: Date(),
                settings: sampleSettings()
            )
        )
        XCTAssertThrowsError(try SettingsBackupCoding.decode(future)) { error in
            XCTAssertEqual(
                error as? SettingsBackupImportError,
                .unsupportedFormatVersion(
                    found: SettingsBackupEnvelope.currentFormatVersion + 1,
                    supported: SettingsBackupEnvelope.currentFormatVersion
                )
            )
        }
    }

    func testMalformedJSONIsRefused() {
        let malformed = Data("not json".utf8)
        XCTAssertThrowsError(try SettingsBackupCoding.decode(malformed)) { error in
            XCTAssertEqual(error as? SettingsBackupImportError, .malformed)
        }
    }

    func testJSONMissingFormatVersionIsRefused() {
        let noVersion = Data("{\"appVersion\":\"1.0\"}".utf8)
        XCTAssertThrowsError(try SettingsBackupCoding.decode(noVersion)) { error in
            XCTAssertEqual(error as? SettingsBackupImportError, .malformed)
        }
    }

    // MARK: No secrets

    func testExportedJSONNeverContainsSecretMaterial() throws {
        let secrets = SecretSettings(apiKey: "sk-canary-should-never-appear")
        let envelope = SettingsBackupEnvelope(
            appVersion: "1.0",
            exportedAt: Date(),
            settings: sampleSettings()
        )
        let data = try SettingsBackupCoding.encode(envelope)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(json.contains("sk-canary-should-never-appear"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("apiKey"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("openAICompatibleAPIKey"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("secretSettings"))

        // Also assert at the type level: the envelope has no property whose
        // type is `SecretSettings`, so a future field cannot smuggle one in
        // without this test's `Mirror` catching it.
        let mirror = Mirror(reflecting: envelope)
        for child in mirror.children {
            XCTAssertFalse(child.value is SecretSettings, "envelope must never carry SecretSettings")
        }
        _ = secrets
    }

    // MARK: No local state (ADR-022 slice 5) — structural, not a redaction

    /// Every key of an encoded `AppSettings`, at any depth.
    private func keyPaths(in json: Any, prefix: String = "") -> Set<String> {
        var keys = Set<String>()
        if let object = json as? [String: Any] {
            for (key, value) in object {
                keys.insert(key)
                keys.formUnion(keyPaths(in: value, prefix: prefix + key + "."))
            }
        } else if let array = json as? [Any] {
            for value in array { keys.formUnion(keyPaths(in: value, prefix: prefix)) }
        }
        return keys
    }

    func testExportedJSONCarriesNoLocalStateKeyAtAnyDepth() throws {
        var settings = sampleSettings()
        settings.export = ExportSettings(autoDailyExportEnabled: true)
        let envelope = SettingsBackupEnvelope(appVersion: "1.0", exportedAt: Date(), settings: settings)
        let data = try SettingsBackupCoding.encode(envelope)
        let keys = keyPaths(in: try JSONSerialization.jsonObject(with: data))

        // The toggle is a preference and travels; nothing local does.
        XCTAssertTrue(keys.contains("autoDailyExportEnabled"))
        for key in LocalState.keys where key != "schemaVersion" {
            XCTAssertFalse(keys.contains(key), "\(key) is local state and must not be exportable")
        }
        for key in LocalState.legacyTopLevelKeys + LocalState.legacyExportKeys {
            XCTAssertFalse(keys.contains(key), "\(key) was removed from AppSettings and must not come back")
        }
    }

    func testEnvelopeHasNoLocalStateProperty() {
        let envelope = SettingsBackupEnvelope(appVersion: "1.0", exportedAt: Date(), settings: sampleSettings())
        for child in Mirror(reflecting: envelope).children {
            XCTAssertFalse(child.value is LocalState, "envelope must never carry LocalState")
            XCTAssertFalse(child.value is ExportFolderGrant)
        }
        // (`is ExportFolderGrant?` would match every nil optional, so the
        // static type name is compared instead.)
        for child in Mirror(reflecting: AppSettings()).children {
            let typeName = String(describing: type(of: child.value))
            XCTAssertFalse(typeName.contains("ExportFolderGrant"), "AppSettings must not hold the folder grant (\(child.label ?? "?"))")
            XCTAssertFalse(typeName.contains("LocalState"), "AppSettings must not nest LocalState (\(child.label ?? "?"))")
        }
    }

    /// A backup written before the split still carries the local keys (and
    /// the old export bookmark). Importing it ignores every one of them —
    /// this Mac's onboarding state and folder grant are not the file's to
    /// set — while the preferences beside them load normally.
    func testImportingAPreSplitBackupIgnoresItsLocalStateKeys() throws {
        let legacy = """
        {
          "formatVersion": 1,
          "appVersion": "0.9",
          "exportedAt": "2026-09-01T00:00:00Z",
          "settings": {
            "schemaVersion": 1,
            "onboardingVersionCompleted": 7,
            "tutorialSeen": true,
            "mainWindowSection": "history",
            "showDockIcon": true,
            "historyEnabled": false,
            "export": {
              "autoDailyExportEnabled": true,
              "autoExportFolderBookmark": "Y2FuYXJ5",
              "autoExportFolderDisplayPath": "/Users/someone/Desktop/Transcripts"
            }
          }
        }
        """
        let decoded = try SettingsBackupCoding.decode(Data(legacy.utf8))
        XCTAssertTrue(decoded.settings.showDockIcon)
        XCTAssertFalse(decoded.settings.historyEnabled)
        XCTAssertTrue(decoded.settings.export.autoDailyExportEnabled)
        // Re-encoding proves the local keys did not survive the decode.
        let reencoded = try SettingsBackupCoding.encode(decoded)
        let keys = keyPaths(in: try JSONSerialization.jsonObject(with: reencoded))
        for key in LocalState.legacyTopLevelKeys + LocalState.legacyExportKeys {
            XCTAssertFalse(keys.contains(key), key)
        }
        XCTAssertFalse(String(decoding: reencoded, as: UTF8.self).contains("/Users/someone"))
    }

    // MARK: Diff

    func testIdenticalSettingsHaveNoDiff() {
        let settings = sampleSettings()
        let diff = settings.diff(from: settings)
        XCTAssertEqual(diff.changedFieldCount, 0)
        XCTAssertFalse(diff.hasChanges)
        XCTAssertFalse(diff.shortcutChanged)
        XCTAssertEqual(diff.changedActionCount, 0)
    }

    func testShortcutChangeIsCountedAndHighlighted() {
        let before = sampleSettings(shortcutKey: "space")
        let after = sampleSettings(shortcutKey: "j")
        let diff = after.diff(from: before)
        XCTAssertEqual(diff.changedFieldCount, 1)
        XCTAssertTrue(diff.shortcutChanged)
        XCTAssertEqual(diff.changedActionCount, 0)
    }

    func testInterfaceLanguageChangeIsCountedAndHighlighted() {
        var before = sampleSettings()
        before.interfaceLanguage = .system
        var after = before
        after.interfaceLanguage = .simplifiedChinese
        let diff = after.diff(from: before)
        XCTAssertEqual(diff.changedFieldCount, 1)
        XCTAssertTrue(diff.interfaceLanguageChanged)
        XCTAssertFalse(diff.shortcutChanged)
    }

    func testInterfaceLanguageUnchangedIsNotHighlighted() {
        let settings = sampleSettings()
        let diff = settings.diff(from: settings)
        XCTAssertFalse(diff.interfaceLanguageChanged)
    }

    func testAddedRemovedAndEditedPromptModesAreCountedInChangedActionCount() {
        var before = sampleSettings()
        let kept = PromptMode(id: UUID(), name: "Kept", behavior: .polish, prompt: "Keep me.")
        let edited = PromptMode(id: UUID(), name: "Edited", behavior: .polish, prompt: "Before.")
        let removed = PromptMode(id: UUID(), name: "Removed", behavior: .polish, prompt: "Gone soon.")
        before.ai.promptModes = [kept, edited, removed]

        var after = before
        var editedChanged = edited
        editedChanged.prompt = "After."
        let added = PromptMode(id: UUID(), name: "Added", behavior: .polish, prompt: "New.")
        after.ai.promptModes = [kept, editedChanged, added]

        let diff = after.diff(from: before)
        // edited + removed + added = 3 distinct actions differ; `kept` does not.
        XCTAssertEqual(diff.changedActionCount, 3)
        // `ai` is one top-level field, changed once.
        XCTAssertEqual(diff.changedFieldCount, 1)
    }

    func testMultipleTopLevelFieldsCountIndependently() {
        let before = sampleSettings()
        var after = before
        after.historyEnabled.toggle()
        after.showDockIcon.toggle()
        after.maxRecordingSeconds = 120
        let diff = after.diff(from: before)
        XCTAssertEqual(diff.changedFieldCount, 3)
        XCTAssertFalse(diff.shortcutChanged)
        XCTAssertEqual(diff.changedActionCount, 0)
    }

    /// Every stored property of `AppSettings` except `schemaVersion` (internal
    /// bookkeeping, not a user setting) must have a `diffFields` entry, so a
    /// newly added setting cannot silently undercount the import summary.
    func testDiffFieldsCoverEveryStoredPropertyExceptSchemaVersion() {
        let mirror = Mirror(reflecting: AppSettings())
        let propertyNames = Set(mirror.children.compactMap(\.label)).subtracting(["schemaVersion"])
        XCTAssertEqual(Set(AppSettings.diffFieldNames), propertyNames)
    }
}

/// A `formatVersion` newer than this build supports, encoded directly
/// (rather than via `SettingsBackupEnvelope`, whose `init` has no guard
/// against it — the guard lives in `SettingsBackupCoding.decode`).
private struct FutureEnvelope: Encodable {
    let formatVersion: Int
    let appVersion: String
    let exportedAt: Date
    let settings: AppSettings
}
