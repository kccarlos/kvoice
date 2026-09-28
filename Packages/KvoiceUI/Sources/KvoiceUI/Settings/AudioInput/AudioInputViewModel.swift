import Foundation
import KvoiceAppCore
import KvoiceDomain
import Observation

/// Main-actor state for the Microphone section and the `Microphone ▸`
/// status-menu submenu: the persisted preference (`AppSettings.audioInput`),
/// the devices the host reports right now, and what the resolver would pick.
///
/// ADR-022 slice 7: a projection over `SettingsProjectionHost`. `settings`
/// is the coordinator's `audioInput` read live; every edit builds the next
/// value and sends one `.setAudioInput` intent — origin `.page(.audioInput)`
/// from the section, `.statusMenu` from the submenu (`selectDevice(uid:
/// origin:)`). The device list is *observed* state, not a setting: it is
/// read from `AudioInputDeviceProviding` (the domain protocol; the app
/// shell passes the CoreAudio adapter), so nothing here needs hardware and
/// the tests hand in a fixed list.
@Observable
@MainActor
public final class AudioInputViewModel {
    /// The coordinator projection and the intent door.
    public let host: SettingsProjectionHost
    public private(set) var devices: [AudioInputDevice] = []
    public private(set) var systemDefault: AudioInputDevice?

    private let deviceProvider: any AudioInputDeviceProviding

    public init(
        host: SettingsProjectionHost = .detached(),
        deviceProvider: any AudioInputDeviceProviding = NoAudioInputDevices()
    ) {
        self.host = host
        self.deviceProvider = deviceProvider
        refresh()
    }

    // MARK: Reading

    /// The stored preference.
    public var settings: AudioInputSettings { host.settings.audioInput }

    /// The last refusal's sentence, for the section; nil otherwise.
    public var refusalNote: String? { host.refusalNote }

    /// Re-reads the connected devices and the system default.
    public func refresh() {
        devices = deviceProvider.availableInputDevices()
        systemDefault = deviceProvider.systemDefaultInputDevice()
    }

    /// What the next recording would use, against the devices read last.
    public var selection: AudioInputSelection {
        AudioInputDeviceResolver.resolve(
            settings: settings,
            available: devices,
            systemDefault: systemDefault
        )
    }

    public var mode: AudioInputMode {
        get { settings.mode }
        set { update { $0.mode = newValue } }
    }

    /// The "Currently using" card: the device name, or why there is none.
    public var currentDeviceName: String {
        selection.device?.name ?? String(localized: "No input device", bundle: .module)
    }

    /// One line explaining how the current device was chosen, or why the
    /// preference could not be honoured. Nil for a plain system default.
    public var selectionNote: String? {
        switch selection.reason {
        case .systemDefault:
            return nil
        case .customDevice:
            return String(localized: "Overrides the system default while recording.", bundle: .module)
        case .customDeviceUnavailable:
            return String(localized: "The chosen device is not connected; the system default is used until it returns.", bundle: .module)
        case .prioritizedDevice:
            return String(localized: "The first connected device in your list.", bundle: .module)
        case .noPrioritizedDeviceAvailable:
            return settings.prioritizedDeviceUIDs.isEmpty
                ? String(localized: "Add devices to the list; until then the system default is used.", bundle: .module)
                : String(localized: "None of the listed devices is connected; the system default is used.", bundle: .module)
        }
    }

    /// One line shown on the Recording and Audio Input pages while the
    /// device the next recording would use is a Bluetooth microphone
    /// (2026-09-16): its route takes up to two seconds to start delivering
    /// audio, which is why the start cue waits for the first real buffer.
    /// Nil for every other transport. Advice only; nothing changes.
    public var bluetoothInputNote: String? {
        guard selection.device?.isBluetooth == true else { return nil }
        return String(localized: "Bluetooth microphones can take a few seconds to start; wait for the start cue before speaking, or use the built-in or a wired microphone.", bundle: .module)
    }

    // MARK: Custom device

    public var customDeviceUID: String? {
        get { settings.customDeviceUID }
        set { update { $0.customDeviceUID = newValue } }
    }

    /// Picks one device outright: Custom mode with that device (the status
    /// menu's one-click path). `nil` returns to the system default. The
    /// submenu passes `.statusMenu` so the refusal line names its door.
    public func selectDevice(uid: String?, origin: SettingsOrigin = .page(.audioInput)) {
        update(origin: origin) { settings in
            if let uid {
                settings.mode = .customDevice
                settings.customDeviceUID = uid
            } else {
                settings.mode = .systemDefault
            }
        }
    }

    // MARK: Prioritized list

    /// The list in order, with the last-known name for a device that is not
    /// connected right now so the row still reads.
    public var prioritizedDevices: [AudioInputDevice] {
        settings.prioritizedDeviceUIDs.map { uid in
            devices.first { $0.uid == uid }
                ?? AudioInputDevice(uid: uid, name: Self.disconnectedName(for: uid), isAvailable: false)
        }
    }

    /// Connected devices not yet in the list.
    public var devicesAvailableToAdd: [AudioInputDevice] {
        devices.filter { !settings.prioritizedDeviceUIDs.contains($0.uid) }
    }

    public func addToPriority(uid: String) {
        guard !uid.isEmpty, !settings.prioritizedDeviceUIDs.contains(uid) else { return }
        update { $0.prioritizedDeviceUIDs.append(uid) }
    }

    public func removeFromPriority(uid: String) {
        update { $0.prioritizedDeviceUIDs.removeAll { $0 == uid } }
    }

    /// Moves one entry up (`offset` -1) or down (+1); out-of-range moves are
    /// ignored so the buttons need no extra guards.
    public func movePriority(uid: String, by offset: Int) {
        guard let index = settings.prioritizedDeviceUIDs.firstIndex(of: uid) else { return }
        let target = index + offset
        guard settings.prioritizedDeviceUIDs.indices.contains(target) else { return }
        update { $0.prioritizedDeviceUIDs.swapAt(index, target) }
    }

    /// One edit → one intent with the whole block; an unchanged edit sends
    /// nothing, and a refusal leaves `settings` (so every control) as it was.
    private func update(origin: SettingsOrigin = .page(.audioInput), _ change: (inout AudioInputSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        host.send(.setAudioInput(next, origin: origin))
    }

    /// A UID is not a name; show the tail so two disconnected devices still
    /// look different, without pretending to know what they were.
    private static func disconnectedName(for uid: String) -> String {
        String(localized: "Disconnected device (\(uid.suffix(8)))", bundle: .module)
    }
}

/// The provider used when no host is attached (previews, tests, a shell
/// without CoreAudio): no devices, no default.
public struct NoAudioInputDevices: AudioInputDeviceProviding {
    public init() {}
    public func availableInputDevices() -> [AudioInputDevice] { [] }
    public func systemDefaultInputDevice() -> AudioInputDevice? { nil }
}
