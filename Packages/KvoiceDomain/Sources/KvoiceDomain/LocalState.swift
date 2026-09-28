import Foundation

/// ADR-022 item 1, the third of the four configuration sources: **local app
/// state** — what the app remembers about *this machine's* past, as opposed
/// to what the user chose (`AppSettings`).
///
/// The distinction is structural, not a redaction: `LocalState` is its own
/// blob under its own store (`LocalStateStore`), it never enters
/// `SettingsBackupEnvelope`, and `AppSettings` has no field for any of it.
/// Until 2026-09-16 these fields lived on `AppSettings`, and the Auto Daily
/// Export folder's security-scoped bookmark leaked into an exported settings
/// file until a redaction was bolted on (`redactedForBackup`, now gone). A
/// capability grant, a home-folder path, a window's last sidebar section and
/// "has this user seen the tutorial" are facts about one Mac; exporting them
/// is at best meaningless and at worst a leak, and importing them would
/// replay another machine's onboarding state here.
///
/// What belongs here (the test for a new field): would a user restoring a
/// settings backup on a *second* Mac want this value to come along? If not,
/// it is local state.
public struct LocalState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// FR-ONB-009: the onboarding version the user completed; nil replays the
    /// wizard. A version bump replays it too.
    public var onboardingVersionCompleted: Int?
    /// Whether the post-setup tutorial pages have been shown. Distinct from
    /// `onboardingVersionCompleted`: a user who finished setup before the
    /// tutorial existed must see the one-time banner offering it rather than
    /// being routed back through the whole wizard.
    public var tutorialSeen: Bool
    /// The sidebar section the main window last showed (`MainWindowSection`
    /// raw value in KvoiceUI). Nil until the user has picked one.
    public var mainWindowSection: String?
    /// The Auto Daily Export folder the user granted on this Mac; nil when
    /// none is chosen. The *toggle* stays a preference
    /// (`ExportSettings.autoDailyExportEnabled`).
    public var exportFolder: ExportFolderGrant?

    public init(
        schemaVersion: Int = LocalState.currentSchemaVersion,
        onboardingVersionCompleted: Int? = nil,
        tutorialSeen: Bool = false,
        mainWindowSection: String? = nil,
        exportFolder: ExportFolderGrant? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.onboardingVersionCompleted = onboardingVersionCompleted
        self.tutorialSeen = tutorialSeen
        self.mainWindowSection = mainWindowSection
        self.exportFolder = exportFolder
    }

    /// A fresh install.
    public static let fresh = LocalState()

    public enum CodingKeys: String, CodingKey, CaseIterable, Sendable {
        case schemaVersion
        case onboardingVersionCompleted
        case tutorialSeen
        case mainWindowSection
        case exportFolder
    }

    /// Every top-level key, for the structural export test
    /// (`SettingsBackupTests`): none of these may appear in an encoded
    /// `AppSettings`, at any depth.
    public static var keys: [String] { CodingKeys.allCases.map(\.rawValue) }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        guard version <= Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Local state schema is newer than this app"
            )
        }
        schemaVersion = version
        onboardingVersionCompleted = try values.decodeIfPresent(Int.self, forKey: .onboardingVersionCompleted)
        tutorialSeen = try values.decodeIfPresent(Bool.self, forKey: .tutorialSeen) ?? false
        mainWindowSection = try values.decodeIfPresent(String.self, forKey: .mainWindowSection)
        exportFolder = try values.decodeIfPresent(ExportFolderGrant.self, forKey: .exportFolder)
    }

    // MARK: Migration from the pre-split `AppSettings` blob

    /// The fields the pre-2026-09-16 `AppSettings` JSON carried that now
    /// live here, decoded leniently from that blob. `LocalStateStore` reads
    /// them once — on the first launch after the split, when no local-state
    /// blob exists yet — to seed `LocalState`; the settings store drops them
    /// on its next save because `AppSettings` no longer encodes them.
    /// Returns nil when the blob names none of them (nothing to migrate).
    public static func seeded(fromLegacySettingsData data: Data) -> LocalState? {
        guard let carrier = try? JSONDecoder().decode(LegacySettingsCarrier.self, from: data),
              carrier.namesAnyLocalField else { return nil }
        return LocalState(
            onboardingVersionCompleted: carrier.onboardingVersionCompleted,
            tutorialSeen: carrier.tutorialSeen ?? false,
            mainWindowSection: carrier.mainWindowSection,
            exportFolder: carrier.export?.grant
        )
    }

    /// The legacy key names, for the store's "drop them on the next save"
    /// test and for the import test that proves an old backup's copies are
    /// ignored. Top-level keys; the two export keys sit under `export`.
    public static let legacyTopLevelKeys = ["onboardingVersionCompleted", "tutorialSeen", "mainWindowSection"]
    public static let legacyExportKeys = ["autoExportFolderBookmark", "autoExportFolderDisplayPath"]

    private struct LegacySettingsCarrier: Decodable {
        struct LegacyExport: Decodable {
            var autoExportFolderBookmark: Data?
            var autoExportFolderDisplayPath: String?

            var grant: ExportFolderGrant? {
                autoExportFolderBookmark.map { ExportFolderGrant(bookmark: $0, displayPath: autoExportFolderDisplayPath) }
            }

            var namesAnyLocalField: Bool {
                autoExportFolderBookmark != nil || autoExportFolderDisplayPath != nil
            }
        }

        var onboardingVersionCompleted: Int?
        var tutorialSeen: Bool?
        var mainWindowSection: String?
        var export: LegacyExport?

        var namesAnyLocalField: Bool {
            onboardingVersionCompleted != nil || tutorialSeen != nil || mainWindowSection != nil
                || export?.namesAnyLocalField == true
        }
    }
}

/// The Auto Daily Export folder as granted on this Mac: the security-scoped
/// bookmark (the authority) and the path at the time of choosing (display,
/// and the moved-folder check in `ExportFolderAccess.resolve`). Local state
/// by nature — a bookmark is a capability grant meaningless anywhere but the
/// Mac that made it.
public struct ExportFolderGrant: Codable, Sendable, Equatable {
    /// `URL.bookmarkData(options: .withSecurityScope)` of the chosen folder.
    public var bookmark: Data
    /// Path of the folder when it was chosen, for display only.
    public var displayPath: String?

    public init(bookmark: Data, displayPath: String?) {
        self.bookmark = bookmark
        self.displayPath = displayPath
    }
}
