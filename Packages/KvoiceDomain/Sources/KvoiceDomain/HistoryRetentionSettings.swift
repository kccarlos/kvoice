import Foundation

/// Retention for transcript rows (Settings › Data & Privacy).
///
/// Off by default: rows stay until the user clears them.  When on,
/// `HistoryMaintenance` deletes rows older than `retentionDays` at launch and
/// once a day.  Audio retention is separate (`AudioStorageSettings`) so a user
/// can keep transcripts for a year and audio for a week.
public struct HistoryRetentionSettings: Codable, Sendable, Equatable {
    /// The retention choices offered by the UI, in days.  Any positive value
    /// decodes; this list only drives the picker.
    public static let retentionChoicesInDays: [Int] = [1, 3, 7, 14, 30, 90, 180, 365]

    public var autoDeleteEnabled: Bool
    /// Rows whose `createdAt` is older than this many days are deleted when
    /// `autoDeleteEnabled` is on.
    public var retentionDays: Int

    public init(autoDeleteEnabled: Bool = false, retentionDays: Int = 30) {
        self.autoDeleteEnabled = autoDeleteEnabled
        self.retentionDays = max(1, retentionDays)
    }

    private enum CodingKeys: String, CodingKey {
        case autoDeleteEnabled
        case retentionDays
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        autoDeleteEnabled = try values.decodeIfPresent(Bool.self, forKey: .autoDeleteEnabled) ?? false
        retentionDays = max(1, try values.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30)
    }

    /// The cutoff for `now`: rows created before it are expired.
    public func cutoff(now: Date) -> Date {
        now.addingTimeInterval(-TimeInterval(retentionDays) * 86_400)
    }
}

public extension Int {
    /// "1 day", "7 days", "1 year" for a retention picker.
    var retentionDaysLabel: String {
        switch self {
        case 365: return "1 year"
        case 1: return "1 day"
        default: return "\(self) days"
        }
    }
}
