import Foundation

/// The advanced trigger controls (HoAh parity, product decision #5).
///
/// Everything here is opt-in and off by default. The primary recording
/// shortcut and interaction mode stay on `AppSettings` itself because they
/// predate this struct and the app shell already persists them by name.
public struct TriggerSettings: Codable, Sendable, Equatable {
    /// Replaces nothing: Escape always cancels (ADR-016 / C.7). A custom
    /// combination is an *additional* cancel trigger for keyboards where
    /// Escape is awkward to reach while the recording shortcut is held.
    public var cancelShortcut: ShortcutDefinition?

    /// Double-press of the recording shortcut arms auto-send: after a
    /// successful Accessibility or typed insertion, a Return key event is
    /// posted to the target application. Never a paste chord.
    public var autoSendEnabled: Bool

    /// Middle mouse button as an additional toggle trigger. The button must be
    /// held for `middleMouseActivationDelayMilliseconds` before it counts, so
    /// an ordinary middle click passes through untouched.
    public var middleMouseToggleEnabled: Bool
    public var middleMouseActivationDelayMilliseconds: Int

    /// Key-up within this window after key-down is a tap in Hybrid mode.
    public static let hybridTapWindow: Duration = .milliseconds(250)
    /// Two key-downs within this window arm auto-send.
    public static let doublePressWindow: Duration = .milliseconds(400)
    public static let defaultMiddleMouseActivationDelayMilliseconds = 300
    public static let middleMouseActivationDelayRange = 0...2_000

    public init(
        cancelShortcut: ShortcutDefinition? = nil,
        autoSendEnabled: Bool = false,
        middleMouseToggleEnabled: Bool = false,
        middleMouseActivationDelayMilliseconds: Int = TriggerSettings.defaultMiddleMouseActivationDelayMilliseconds
    ) {
        self.cancelShortcut = cancelShortcut
        self.autoSendEnabled = autoSendEnabled
        self.middleMouseToggleEnabled = middleMouseToggleEnabled
        self.middleMouseActivationDelayMilliseconds = Self.middleMouseActivationDelayRange.clamping(
            middleMouseActivationDelayMilliseconds
        )
    }

    public var middleMouseActivationDelay: Duration {
        .milliseconds(middleMouseActivationDelayMilliseconds)
    }

    // The Append shortcut (a second recording key inserting " " + transcript)
    // was removed by product decision on 2026-09-13 as redundant with "Add
    // space after paste". Settings files written while it existed still carry
    // an `appendShortcut` key; the keyed decoder below ignores it.
    private enum CodingKeys: String, CodingKey {
        case cancelShortcut
        case autoSendEnabled
        case middleMouseToggleEnabled
        case middleMouseActivationDelayMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            cancelShortcut: try values.decodeIfPresent(ShortcutDefinition.self, forKey: .cancelShortcut),
            autoSendEnabled: try values.decodeIfPresent(Bool.self, forKey: .autoSendEnabled) ?? false,
            middleMouseToggleEnabled: try values.decodeIfPresent(Bool.self, forKey: .middleMouseToggleEnabled) ?? false,
            middleMouseActivationDelayMilliseconds: try values.decodeIfPresent(
                Int.self,
                forKey: .middleMouseActivationDelayMilliseconds
            ) ?? Self.defaultMiddleMouseActivationDelayMilliseconds
        )
    }
}

/// The user-selectable recording length ceiling (product decision #10).
///
/// "No limit" is still bounded: one hour of 16 kHz mono Float32 is about
/// 230 MB, so the recorder keeps a four-hour technical ceiling rather than
/// growing without bound. `AppSettings.maxRecordingSeconds` stays an integer
/// number of seconds; this enum is the picker's view of it.
public enum RecordingDurationLimit: Int, Codable, Sendable, Equatable, CaseIterable {
    case tenMinutes = 600
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    /// Stored as the technical ceiling so every consumer still sees a
    /// positive cap.
    case noLimit = 14_400

    public static let `default`: RecordingDurationLimit = .tenMinutes
    public static let technicalCeilingSeconds = RecordingDurationLimit.noLimit.rawValue

    public var seconds: Int { rawValue }
    public var duration: Duration { .seconds(rawValue) }

    /// True for the ceiling: the HUD then omits the "stops automatically at"
    /// clock, since four hours is a memory bound rather than a feature.
    public var isUnlimited: Bool { self == .noLimit }

    /// The picker case for a stored value. Values written by a hand-edited
    /// file map to the nearest case at or above them so the user never gets
    /// a shorter recording than they asked for.
    public init(seconds: Int) {
        let bounded = min(max(seconds, 1), Self.technicalCeilingSeconds)
        self = Self.allCases.first { $0.rawValue >= bounded } ?? .noLimit
    }

    public var displayName: String {
        switch self {
        case .tenMinutes: return "10 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .noLimit: return "No limit"
        }
    }
}

private extension ClosedRange where Bound == Int {
    func clamping(_ value: Int) -> Int {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
