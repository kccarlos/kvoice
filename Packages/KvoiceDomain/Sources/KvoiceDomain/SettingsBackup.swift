import Foundation

// MARK: Settings backup (export / import)

/// The on-disk shape of an exported settings file (Settings › General ›
/// Backup, and the automatic pre-import snapshot). Wraps the whole
/// `AppSettings` blob the same way `SettingsStore` persists it, plus enough
/// metadata to validate and label the file before `AppSettings.init(from:)`
/// ever runs.
///
/// Deliberately has no `SecretSettings` property and no `LocalState`
/// property. API keys live only in `SecretSettings`, keyed by item `id`
/// (the secrets rule in AGENTS.md), and must never round-trip through a file the user
/// might export, email, or drop in a shared folder. Machine-local state —
/// the Auto Daily Export folder's security-scoped bookmark and its plaintext
/// path, onboarding completion, the tutorial flag, the main window's section
/// — lives in `LocalState` (ADR-022 slice 5), which `AppSettings` has no
/// field for, so the export is safe by construction rather than by a
/// redaction step (the bookmark leaked into a file once, before the split).
/// `SettingsBackupTests` walks the encoded JSON and asserts none of
/// `LocalState.keys` or the legacy key names appear at any depth.
public struct SettingsBackupEnvelope: Codable, Sendable, Equatable {
    /// Bumped only when a change to `AppSettings` would not be tolerantly
    /// decodable by an older kvoice build — mirrors `AppSettings.schemaVersion`
    /// one level up. A file whose `formatVersion` is newer than
    /// `currentFormatVersion` is refused before anything is applied, rather
    /// than partially decoded.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var appVersion: String
    public var exportedAt: Date
    public var settings: AppSettings

    public init(
        appVersion: String,
        exportedAt: Date,
        settings: AppSettings,
        formatVersion: Int = Self.currentFormatVersion
    ) {
        self.formatVersion = formatVersion
        self.appVersion = appVersion
        self.exportedAt = exportedAt
        self.settings = settings
    }
}

/// Why an import or restore file was refused before anything was applied.
public enum SettingsBackupImportError: Error, Sendable, Equatable {
    /// `formatVersion` is newer than this build supports.
    case unsupportedFormatVersion(found: Int, supported: Int)
    /// The file was not valid JSON, or not this envelope's shape.
    case malformed
}

/// Deterministic JSON coding for `SettingsBackupEnvelope`, shared by Export,
/// Import, and the automatic pre-import backup so all three read and write
/// the same file shape.
public enum SettingsBackupCoding {
    /// `.sortedKeys` so exporting the same settings twice produces a
    /// byte-identical file (and a friendlier diff if a user compares two
    /// exports by hand).
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The one choke point every export and automatic backup goes through.
    /// Nothing is redacted here any more: `AppSettings` cannot carry local
    /// state (ADR-022 slice 5), so there is nothing to strip.
    public static func encode(_ envelope: SettingsBackupEnvelope) throws -> Data {
        try makeEncoder().encode(envelope)
    }

    /// Validates `formatVersion` before decoding the rest of the file, so an
    /// unsupported version is reported precisely rather than surfacing as
    /// whatever decode error the newer shape happens to trigger.
    public static func decode(_ data: Data) throws -> SettingsBackupEnvelope {
        struct VersionProbe: Decodable { let formatVersion: Int }
        guard let probe = try? makeDecoder().decode(VersionProbe.self, from: data) else {
            throw SettingsBackupImportError.malformed
        }
        guard probe.formatVersion <= SettingsBackupEnvelope.currentFormatVersion else {
            throw SettingsBackupImportError.unsupportedFormatVersion(
                found: probe.formatVersion,
                supported: SettingsBackupEnvelope.currentFormatVersion
            )
        }
        do {
            return try makeDecoder().decode(SettingsBackupEnvelope.self, from: data)
        } catch {
            throw SettingsBackupImportError.malformed
        }
    }
}

/// What an import confirmation dialog shows before anything is applied.
public struct AppSettingsDiff: Sendable, Equatable {
    /// How many of `AppSettings`'s top-level fields differ. `ai` (the whole
    /// AI configuration, including `promptModes`) counts as one field here;
    /// `changedActionCount` breaks that one down further for the summary.
    public let changedFieldCount: Int
    public let shortcutChanged: Bool
    public let interfaceLanguageChanged: Bool
    /// Number of AI actions (`AIEndpointSettings.promptModes`) added,
    /// removed, or edited.
    public let changedActionCount: Int

    public var hasChanges: Bool { changedFieldCount > 0 }

    public init(
        changedFieldCount: Int,
        shortcutChanged: Bool,
        interfaceLanguageChanged: Bool = false,
        changedActionCount: Int
    ) {
        self.changedFieldCount = changedFieldCount
        self.shortcutChanged = shortcutChanged
        self.interfaceLanguageChanged = interfaceLanguageChanged
        self.changedActionCount = changedActionCount
    }
}

extension AppSettings {
    /// Field-by-field comparison against `other` (the settings already on
    /// disk), for the Import/Restore confirmation summary. `schemaVersion` is
    /// excluded — it is bookkeeping, not a setting. Keep this list in sync
    /// with `CodingKeys` when a field is added; `SettingsBackupTests`
    /// exercises it directly so a forgotten field shows up as a test gap
    /// rather than a silent undercount.
    private static let diffFields: [(String, @Sendable (AppSettings, AppSettings) -> Bool)] = [
        ("showDockIcon", { $0.showDockIcon == $1.showDockIcon }),
        ("launchAtLogin", { $0.launchAtLogin == $1.launchAtLogin }),
        ("recordingInteraction", { $0.recordingInteraction == $1.recordingInteraction }),
        ("shortcut", { $0.shortcut == $1.shortcut }),
        ("selectedModel", { $0.selectedModel == $1.selectedModel }),
        ("ai", { $0.ai == $1.ai }),
        ("historyEnabled", { $0.historyEnabled == $1.historyEnabled }),
        ("maxRecordingSeconds", { $0.maxRecordingSeconds == $1.maxRecordingSeconds }),
        ("typedInsertionEnabled", { $0.typedInsertionEnabled == $1.typedInsertionEnabled }),
        ("recorderStyle", { $0.recorderStyle == $1.recorderStyle }),
        ("defaultSpeechModelID", { $0.defaultSpeechModelID == $1.defaultSpeechModelID }),
        ("transcriptionLanguage", { $0.transcriptionLanguage == $1.transcriptionLanguage }),
        ("speechModelModes", { $0.speechModelModes == $1.speechModelModes }),
        ("addSpaceAfterInsertion", { $0.addSpaceAfterInsertion == $1.addSpaceAfterInsertion }),
        ("automaticTextFormatting", { $0.automaticTextFormatting == $1.automaticTextFormatting }),
        ("voiceActivityDetectionEnabled", { $0.voiceActivityDetectionEnabled == $1.voiceActivityDetectionEnabled }),
        ("speechComputeUnits", { $0.speechComputeUnits == $1.speechComputeUnits }),
        ("freeModelMemoryUnderCriticalPressure", { $0.freeModelMemoryUnderCriticalPressure == $1.freeModelMemoryUnderCriticalPressure }),
        ("interfaceLanguage", { $0.interfaceLanguage == $1.interfaceLanguage }),
        ("triggers", { $0.triggers == $1.triggers }),
        ("recordingFeedback", { $0.recordingFeedback == $1.recordingFeedback }),
        ("audioInput", { $0.audioInput == $1.audioInput }),
        ("historyRetention", { $0.historyRetention == $1.historyRetention }),
        ("audioStorage", { $0.audioStorage == $1.audioStorage }),
        ("export", { $0.export == $1.export }),
        ("dictionary", { $0.dictionary == $1.dictionary })
    ]

    /// Every field name `diffFields` compares, for a coverage test that
    /// fails when a new stored property is added without a matching entry.
    public static var diffFieldNames: [String] { diffFields.map(\.0) }

    public func diff(from other: AppSettings) -> AppSettingsDiff {
        let changed = Self.diffFields.filter { !$0.1(self, other) }.count
        return AppSettingsDiff(
            changedFieldCount: changed,
            shortcutChanged: shortcut != other.shortcut,
            interfaceLanguageChanged: interfaceLanguage != other.interfaceLanguage,
            changedActionCount: Self.changedPromptModeCount(ai.promptModes, other.ai.promptModes)
        )
    }

    /// Symmetric difference by `id`: an action present in only one list, or
    /// present in both but edited, counts once.
    private static func changedPromptModeCount(_ lhs: [PromptMode], _ rhs: [PromptMode]) -> Int {
        let lhsByID = Dictionary(uniqueKeysWithValues: lhs.map { ($0.id, $0) })
        let rhsByID = Dictionary(uniqueKeysWithValues: rhs.map { ($0.id, $0) })
        let allIDs = Set(lhsByID.keys).union(rhsByID.keys)
        return allIDs.filter { lhsByID[$0] != rhsByID[$0] }.count
    }
}
