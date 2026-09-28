import Foundation
import KvoiceDomain

/// The pre-2026-09-13 General settings snapshot. Kept only so a settings
/// value written by an earlier build migrates; nothing writes it any more.
public struct GeneralSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var recordingInteraction: RecordingInteraction
    public var shortcut: ShortcutDefinition?
    public var showDockIcon: Bool

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        recordingInteraction: RecordingInteraction = .pushToTalk,
        shortcut: ShortcutDefinition? = nil,
        showDockIcon: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.recordingInteraction = recordingInteraction
        self.shortcut = shortcut
        self.showDockIcon = showDockIcon
    }

    public init(appSettings: AppSettings) {
        self.init(
            recordingInteraction: appSettings.recordingInteraction,
            shortcut: appSettings.shortcut,
            showDockIcon: appSettings.showDockIcon
        )
    }

    public static let defaults = Self()

    /// The shortcut is intentionally optional until the user confirms one in
    /// the recorder.  Returning it under this name keeps that safety rule
    /// visible at call sites that consume the General settings model.
    public var confirmedShortcut: ShortcutDefinition? {
        shortcut
    }

    public func applying(to settings: AppSettings = .init()) -> AppSettings {
        var result = settings
        result.recordingInteraction = recordingInteraction
        result.shortcut = shortcut
        result.showDockIcon = showDockIcon
        return result
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case recordingInteraction
        case shortcut
        case showDockIcon
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let allValues = try decoder.container(keyedBy: GeneralSettingsCodingKey.self)
        let unknownKeys = allValues.allKeys.filter { key in
            !CodingKeys.allCases.contains { $0.stringValue == key.stringValue }
        }
        guard unknownKeys.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "General settings contain unsupported keys"
            )
        }

        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported General settings schema"
            )
        }

        let recordingInteraction = try values.decodeIfPresent(
            RecordingInteraction.self,
            forKey: .recordingInteraction
        ) ?? .pushToTalk
        let shortcut = try values.decodeIfPresent(ShortcutDefinition.self, forKey: .shortcut)
        let showDockIcon = try values.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? false

        guard Self.isValid(shortcut: shortcut) else {
            throw DecodingError.dataCorruptedError(
                forKey: .shortcut,
                in: values,
                debugDescription: "General settings contain an invalid shortcut"
            )
        }

        self.init(
            schemaVersion: version,
            recordingInteraction: recordingInteraction,
            shortcut: shortcut,
            showDockIcon: showDockIcon
        )
    }

    private static func isValid(shortcut: ShortcutDefinition?) -> Bool {
        guard let shortcut else { return true }

        let key = shortcut.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, key.utf8.count <= 32 else { return false }

        let modifiers = shortcut.modifiers.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard !modifiers.isEmpty,
              modifiers.count == Set(modifiers).count,
              modifiers.allSatisfy(Self.supportedModifiers.contains) else {
            return false
        }
        return true
    }

    private static let supportedModifiers: Set<String> = [
        "command", "cmd", "⌘",
        "option", "alt", "⌥",
        "control", "ctrl", "^",
        "shift", "⇧",
        "function", "fn",
        "capslock", "caps-lock", "caps_lock"
    ]
}

private struct GeneralSettingsCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// An actor-backed UserDefaults repository for every nonsecret setting.
///
/// The whole `AppSettings` value is persisted as one JSON blob under
/// `appSettingsKey`, so a field cannot be silently dropped on save the way it
/// was when only a hand-picked `GeneralSettings` subset was written (2026-09-13:
/// `selectedModel`, `launchAtLogin`, `typedInsertionEnabled`, and
/// `onboardingVersionCompleted` all came back as defaults on every launch).
/// UserDefaults writes the Data value atomically, so readers observe either the
/// old snapshot or the new one.
///
/// Adding a setting: add the stored property, its `CodingKeys` case, and a
/// `decodeIfPresent … ?? default` line to `AppSettings` in KvoiceDomain — the
/// store needs no change, and older files load with the default. Secrets never
/// go through here; see `SecretsFileStore`.
public actor SettingsStore: SettingsRepository {
    public static let appSettingsKey = "io.github.kccarlos.kvoice.appSettings"
    /// Pre-2026-09-13 keys, read once when `appSettingsKey` is absent and then
    /// removed.
    public static let generalSettingsKey = "io.github.kccarlos.kvoice.generalSettings"
    public static let aiSettingsKey = "io.github.kccarlos.kvoice.aiSettings"
    public static let historyEnabledKey = "io.github.kccarlos.kvoice.historyEnabled"

    private let defaults: UserDefaultsBox
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(suiteName: String? = nil) {
        self.defaults = UserDefaultsBox(suiteName: suiteName)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    /// Loads the persisted settings. A missing value is a fresh install; a
    /// malformed value is quarantined (removed) and resolves to defaults so a
    /// bad file can never prevent launch (FR-SET-002). Legacy split keys are
    /// migrated the first time the new key is absent.
    public func load() throws -> AppSettings {
        if let data = defaults.value.data(forKey: Self.appSettingsKey) {
            do {
                return try decoder.decode(AppSettings.self, from: data)
            } catch {
                defaults.value.removeObject(forKey: Self.appSettingsKey)
                return AppSettings()
            }
        }
        let migrated = migrateLegacyKeys()
        if migrated != AppSettings() {
            try? save(migrated)
        }
        return migrated
    }

    /// Saves every nonsecret setting in one write. The value is decoded back
    /// before it is stored so an unencodable or lossy field is caught here
    /// rather than on the next launch.
    public func save(_ settings: AppSettings) throws {
        do {
            let data = try encoder.encode(settings)
            guard try decoder.decode(AppSettings.self, from: data) == settings else {
                throw KVoiceError(code: .settingsCorrupt)
            }
            defaults.value.set(data, forKey: Self.appSettingsKey)
        } catch let error as KVoiceError {
            throw error
        } catch {
            throw KVoiceError(code: .settingsCorrupt)
        }
        removeLegacyKeys()
    }

    /// Clears every stored setting for tests and a reset-settings action.
    public func reset() {
        defaults.value.removeObject(forKey: Self.appSettingsKey)
        removeLegacyKeys()
    }

    // MARK: Legacy migration

    /// Reads the three pre-blob keys. Each is quarantined independently on a
    /// decode failure, so one bad legacy value does not discard the others.
    private func migrateLegacyKeys() -> AppSettings {
        var settings = AppSettings()
        if let data = defaults.value.data(forKey: Self.generalSettingsKey) {
            if let general = try? decoder.decode(GeneralSettings.self, from: data) {
                settings = general.applying(to: settings)
            }
        }
        if let data = defaults.value.data(forKey: Self.aiSettingsKey) {
            if let ai = try? decoder.decode(AIEndpointSettings.self, from: data) {
                settings.ai = ai
            }
        }
        if defaults.value.object(forKey: Self.historyEnabledKey) != nil {
            settings.historyEnabled = defaults.value.bool(forKey: Self.historyEnabledKey)
        }
        return settings
    }

    private func removeLegacyKeys() {
        defaults.value.removeObject(forKey: Self.generalSettingsKey)
        defaults.value.removeObject(forKey: Self.aiSettingsKey)
        defaults.value.removeObject(forKey: Self.historyEnabledKey)
    }
}

/// Foundation's UserDefaults is thread-safe, but its SDK annotation predates
/// Swift's strict actor-sendability checking.  The repositories serialize
/// every operation through their actors and keep this small wrapper as the
/// one audited crossing point (shared with `LocalStateStore`).
final class UserDefaultsBox: @unchecked Sendable {
    let value: UserDefaults

    nonisolated init(suiteName: String?) {
        self.value = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
