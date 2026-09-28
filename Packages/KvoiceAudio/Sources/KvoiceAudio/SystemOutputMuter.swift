import AudioToolbox
import CoreAudio
import Foundation
import KvoiceDomain

/// The three CoreAudio reads and writes the muter needs, behind a seam so the
/// mute/restore policy is testable without touching the real output device.
public protocol OutputVolumeAccess: Sendable {
    /// The default output device's virtual main volume in `0...1`, or nil
    /// when there is no default output device or it has no settable volume.
    func readVolume() -> Float?
    /// Returns false when the write was refused.
    @discardableResult
    func writeVolume(_ volume: Float) -> Bool
}

/// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` on the default
/// output device. Public CoreAudio only; media playback is not paused because
/// that needs the private MediaRemote framework.
public struct CoreAudioOutputVolumeAccess: OutputVolumeAccess, Sendable {
    public init() {}

    public func readVolume() -> Float? {
        guard let deviceID = Self.defaultOutputDeviceID() else { return nil }
        var address = Self.volumeAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr, volume.isFinite else { return nil }
        return min(max(volume, 0), 1)
    }

    public func writeVolume(_ volume: Float) -> Bool {
        guard let deviceID = Self.defaultOutputDeviceID() else { return false }
        var address = Self.volumeAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(deviceID, &address),
              AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
              settable.boolValue
        else { return false }
        var value = Float32(min(max(volume, 0), 1))
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &value
        )
        return status == noErr
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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
}

/// Lowers the default output volume to zero for the length of a recording
/// and puts it back afterwards ("Mute system audio during recording").
///
/// Policy, all of it tested against a fake `OutputVolumeAccess`:
/// - `mute()` is idempotent: a second call while muted changes nothing.
/// - `restore()` without a matching `mute()` is a no-op, so the controller
///   can call it from every exit path.
/// - If the volume was already zero, nothing is written and nothing is
///   restored: the user had it muted and keeps it that way.
/// - If the user raised the volume during the recording (it is no longer
///   zero at restore time), their change wins and the saved level is
///   dropped.
public actor SystemOutputMuter: SystemOutputMuting {
    private let access: any OutputVolumeAccess
    private var savedVolume: Float?

    public init(access: any OutputVolumeAccess = CoreAudioOutputVolumeAccess()) {
        self.access = access
    }

    /// The level that will be restored, if a mute is in effect.
    public var pendingRestoreVolume: Float? { savedVolume }

    public func mute() {
        guard savedVolume == nil else { return }
        guard let current = access.readVolume(), current > 0 else { return }
        guard access.writeVolume(0) else { return }
        savedVolume = current
    }

    public func restore() {
        guard let saved = savedVolume else { return }
        savedVolume = nil
        if let current = access.readVolume(), current > 0.001 {
            // The user turned it back up themselves; do not fight them.
            return
        }
        access.writeVolume(saved)
    }
}
