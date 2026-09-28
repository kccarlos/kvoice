import CoreAudio
import Foundation
import KvoiceDomain

/// Enumerates input-capable CoreAudio devices (`kAudioHardwarePropertyDevices`)
/// and reads the system default input. Names, UIDs and the transport type
/// are the only fields read; nothing here opens a device.
///
/// This is deliberately thin: the choice between the enumerated devices and
/// the user's preference is `AudioInputDeviceResolver` in the domain, which
/// is what the tests cover. The CoreAudio calls themselves need hardware.
public struct CoreAudioInputDeviceProvider: AudioInputDeviceProviding, Sendable {
    public init() {}

    public func availableInputDevices() -> [AudioInputDevice] {
        Self.allDeviceIDs()
            .filter { Self.inputChannelCount(of: $0) > 0 }
            .compactMap { deviceID -> AudioInputDevice? in
                guard let uid = Self.string(for: kAudioDevicePropertyDeviceUID, of: deviceID),
                      !uid.isEmpty
                else { return nil }
                let name = Self.string(for: kAudioObjectPropertyName, of: deviceID) ?? uid
                return AudioInputDevice(
                    uid: uid,
                    name: name,
                    isAvailable: true,
                    isBluetooth: Self.isBluetoothTransport(Self.transportType(of: deviceID))
                )
            }
    }

    public func systemDefaultInputDevice() -> AudioInputDevice? {
        guard let deviceID = Self.defaultInputDeviceID(),
              let uid = Self.string(for: kAudioDevicePropertyDeviceUID, of: deviceID)
        else { return nil }
        let name = Self.string(for: kAudioObjectPropertyName, of: deviceID) ?? uid
        return AudioInputDevice(
            uid: uid,
            name: name,
            isAvailable: true,
            isBluetooth: Self.isBluetoothTransport(Self.transportType(of: deviceID))
        )
    }

    /// The Bluetooth transports (`kAudioDevicePropertyTransportType`):
    /// classic (HFP/A2DP headsets such as AirPods) and LE. Pure, so the
    /// mapping is tested without a device; nil (the property is missing or
    /// unreadable) is not Bluetooth.
    public static func isBluetoothTransport(_ transportType: UInt32?) -> Bool {
        guard let transportType else { return false }
        return transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The device ID for a persisted UID, if that device is connected.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { string(for: kAudioDevicePropertyDeviceUID, of: $0) == uid }
    }

    // MARK: CoreAudio property reads

    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func transportType(of deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func string(for selector: AudioObjectPropertySelector, of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
