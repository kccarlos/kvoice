import Foundation

/// How the microphone is chosen (HoAh "Audio Input").
public enum AudioInputMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Follow System Settings › Sound › Input, including changes made while
    /// kvoice runs.
    case systemDefault
    /// One named device. Overrides the system default while it is connected;
    /// falls back to the system default when it is not.
    case customDevice
    /// An ordered list. The first connected device wins; when none is
    /// connected the system default is used.
    case prioritized
}

/// Which microphone kvoice records from.
///
/// Devices are persisted by CoreAudio UID, which survives reboots and
/// re-plugging; the display name is only ever read live.
public struct AudioInputSettings: Codable, Sendable, Equatable {
    public var mode: AudioInputMode
    public var customDeviceUID: String?
    public var prioritizedDeviceUIDs: [String]

    public init(
        mode: AudioInputMode = .systemDefault,
        customDeviceUID: String? = nil,
        prioritizedDeviceUIDs: [String] = []
    ) {
        self.mode = mode
        self.customDeviceUID = customDeviceUID
        self.prioritizedDeviceUIDs = Self.deduplicated(prioritizedDeviceUIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case customDeviceUID
        case prioritizedDeviceUIDs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let modeName = try values.decodeIfPresent(String.self, forKey: .mode)
        self.init(
            mode: modeName.flatMap(AudioInputMode.init(rawValue:)) ?? .systemDefault,
            customDeviceUID: try values.decodeIfPresent(String.self, forKey: .customDeviceUID),
            prioritizedDeviceUIDs: try values.decodeIfPresent([String].self, forKey: .prioritizedDeviceUIDs) ?? []
        )
    }

    private static func deduplicated(_ uids: [String]) -> [String] {
        var seen = Set<String>()
        return uids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// One input-capable audio device as reported by the host.
public struct AudioInputDevice: Sendable, Equatable, Hashable, Identifiable {
    /// CoreAudio device UID; stable across launches for the same hardware.
    public let uid: String
    public let name: String
    /// True when the host currently reports the device as connected.
    public let isAvailable: Bool
    /// True when the host reports a Bluetooth transport (classic or LE),
    /// 2026-09-16. Such a microphone takes up to two seconds to start
    /// delivering audio (the A2DP→HFP switch), which the Recording and
    /// Audio Input pages warn about; nothing else reads it.
    public let isBluetooth: Bool

    public var id: String { uid }

    public init(uid: String, name: String, isAvailable: Bool = true, isBluetooth: Bool = false) {
        self.uid = uid
        self.name = name
        self.isAvailable = isAvailable
        self.isBluetooth = isBluetooth
    }
}

/// The host's view of input devices. The production adapter queries
/// CoreAudio; tests supply a fixed list.
public protocol AudioInputDeviceProviding: Sendable {
    /// Every connected input-capable device, in the host's order.
    func availableInputDevices() -> [AudioInputDevice]
    /// The device System Settings currently routes input to, if any.
    func systemDefaultInputDevice() -> AudioInputDevice?
}

/// What the resolver chose and why. The reason drives the "Currently using"
/// card and the diagnostics attribute; the device drives the engine.
public struct AudioInputSelection: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        case systemDefault
        case customDevice
        case customDeviceUnavailable
        case prioritizedDevice
        case noPrioritizedDeviceAvailable
    }

    /// The device that will be used, for display. For a system-default
    /// outcome this is whatever System Settings routes to (nil when the host
    /// reports no input device at all).
    public let device: AudioInputDevice?
    public let reason: Reason

    public init(device: AudioInputDevice?, reason: Reason) {
        self.device = device
        self.reason = reason
    }

    /// True when the engine should be pinned to `device`; false when it
    /// should follow the system default.
    public var pinsDevice: Bool {
        switch reason {
        case .customDevice, .prioritizedDevice: return device != nil
        case .systemDefault, .customDeviceUnavailable, .noPrioritizedDeviceAvailable: return false
        }
    }

    public var usesSystemDefault: Bool { !pinsDevice }

    /// The UID to hand the engine: nil follows the system default.
    public var pinnedDeviceUID: String? {
        pinsDevice ? device?.uid : nil
    }
}

/// Pure resolution of the input-device preference against what is connected.
public enum AudioInputDeviceResolver {
    public static func resolve(
        settings: AudioInputSettings,
        available: [AudioInputDevice],
        systemDefault: AudioInputDevice?
    ) -> AudioInputSelection {
        let connected = available.filter(\.isAvailable)
        switch settings.mode {
        case .systemDefault:
            return AudioInputSelection(device: systemDefault, reason: .systemDefault)
        case .customDevice:
            if let uid = settings.customDeviceUID,
               let device = connected.first(where: { $0.uid == uid }) {
                return AudioInputSelection(device: device, reason: .customDevice)
            }
            return AudioInputSelection(device: systemDefault, reason: .customDeviceUnavailable)
        case .prioritized:
            for uid in settings.prioritizedDeviceUIDs {
                if let device = connected.first(where: { $0.uid == uid }) {
                    return AudioInputSelection(device: device, reason: .prioritizedDevice)
                }
            }
            return AudioInputSelection(device: systemDefault, reason: .noPrioritizedDeviceAvailable)
        }
    }
}

/// Optional capability of an `AudioCaptureService` whose recording ceiling
/// and input device can be changed between jobs. `DictationController`
/// applies the active settings through this before each start so neither
/// needs app-shell wiring.
public protocol AudioCaptureConfiguring: Actor {
    /// Bounded by the four-hour technical ceiling inside the service.
    func setMaximumRecordingDuration(_ duration: Duration) async
    func setInputSelection(_ settings: AudioInputSettings) async
}
