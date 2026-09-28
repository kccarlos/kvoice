import Foundation

/// Opt-in stored audio (product decision 2026-09-13 #1, an accepted deviation
/// from FR-HIST-003 / FR-AUD-003).
///
/// Off by default, in which case no audio file is ever written.  When on, the
/// history write for a completed dictation also saves the job's recording as
/// 16 kHz mono WAV under `History/Audio/<entryID>.wav` (mode 0600) and the row
/// stores the relative path.  Turning it off writes nothing new and leaves
/// existing files alone until cleanup removes them by age or the user clears
/// history.  Audio never reaches diagnostics.
public struct AudioStorageSettings: Codable, Sendable, Equatable {
    public static let retentionChoicesInDays: [Int] = HistoryRetentionSettings.retentionChoicesInDays

    public var keepRecordings: Bool
    /// Audio files older than this many days are deleted by cleanup even while
    /// the row's transcript is kept.
    public var retentionDays: Int

    public init(keepRecordings: Bool = false, retentionDays: Int = 7) {
        self.keepRecordings = keepRecordings
        self.retentionDays = max(1, retentionDays)
    }

    private enum CodingKeys: String, CodingKey {
        case keepRecordings
        case retentionDays
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        keepRecordings = try values.decodeIfPresent(Bool.self, forKey: .keepRecordings) ?? false
        retentionDays = max(1, try values.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 7)
    }

    public func cutoff(now: Date) -> Date {
        now.addingTimeInterval(-TimeInterval(retentionDays) * 86_400)
    }
}
