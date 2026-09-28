@preconcurrency import AVFoundation
import Foundation
import KvoiceDomain

public enum AudioEngineAdapterEvent: Sendable, Equatable {
    case configurationChanged
    case interruption
    case inputUnavailable
    case invalidBuffer
}

/// AVAudioEngine's mutable lifecycle is kept behind this small seam.  The
/// service actor owns the ordering; the adapter only forwards tap snapshots
/// and native route/interruption notifications.
public protocol AudioEngineAdapter: AnyObject, Sendable {
    var inputFormat: AudioInputFormat? { get }
    var inputDeviceName: String? { get }
    var onEvent: (@Sendable (AudioEngineAdapterEvent) -> Void)? { get set }

    func installInputTap(
        bufferSize: Int,
        format: AudioInputFormat,
        handler: @escaping @Sendable (AudioInputBuffer) -> Void
    ) throws
    func removeInputTap()
    func start() throws
    func stop()
    /// Routes the input node to the device with this CoreAudio UID, or back
    /// to the system default for `nil`. Called by the capture service before
    /// it reads `inputFormat`, while the engine is stopped. Adapters that
    /// cannot switch devices may ignore it.
    func selectInputDevice(uid: String?) throws
}

public extension AudioEngineAdapter {
    func selectInputDevice(uid _: String?) throws {}
}

/// Native AVAudioEngine implementation used by the application and manual
/// spike host.  No AVAudioPCMBuffer is retained after the tap callback; only a
/// value snapshot is handed to the capture session.
public final class AVAudioEngineAdapter: AudioEngineAdapter, @unchecked Sendable {
    private let engine: AVAudioEngine
    private let notificationCenter: NotificationCenter
    private var configurationObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var tapInstalled = false

    public var onEvent: (@Sendable (AudioEngineAdapterEvent) -> Void)?

    public init(
        engine: AVAudioEngine = AVAudioEngine(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.engine = engine
        self.notificationCenter = notificationCenter

        configurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.onEvent?(.configurationChanged)
        }

        // macOS has used this notification name across AVFAudio releases;
        // observe it without retaining any notification payload.  The fake
        // adapter used by deterministic tests can emit the same semantic event
        // directly.
        interruptionObserver = notificationCenter.addObserver(
            forName: Notification.Name("AVAudioEngineInterruptionNotification"),
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.onEvent?(.interruption)
        }
    }

    deinit {
        if let configurationObserver {
            notificationCenter.removeObserver(configurationObserver)
        }
        if let interruptionObserver {
            notificationCenter.removeObserver(interruptionObserver)
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
    }

    public var inputFormat: AudioInputFormat? {
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate.isFinite,
              format.sampleRate > 0,
              format.channelCount > 0
        else { return nil }
        return AudioInputFormat(
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount)
        )
    }

    public var inputDeviceName: String? {
        // AVAudioEngine does not expose a stable cross-release input-device
        // name on macOS.  Route changes still surface as a semantic event with
        // a nil name, which is privacy-safe and deterministic.
        nil
    }

    public func installInputTap(
        bufferSize: Int,
        format: AudioInputFormat,
        handler: @escaping @Sendable (AudioInputBuffer) -> Void
    ) throws {
        guard bufferSize > 0, format.isValid else {
            throw KVoiceError(code: .audioInputUnavailable, retryable: false)
        }
        guard let currentFormat = inputFormat, currentFormat == format else {
            throw KVoiceError(code: .audioInputChanged, retryable: false)
        }

        let inputNode = engine.inputNode
        if tapInstalled {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        let nativeFormat = inputNode.inputFormat(forBus: 0)
        guard nativeFormat.sampleRate == format.sampleRate,
              Int(nativeFormat.channelCount) == format.channelCount
        else {
            throw KVoiceError(code: .audioInputChanged, retryable: false)
        }
        inputNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(bufferSize),
            format: nativeFormat
        ) { [weak self] buffer, _ in
            do {
                let snapshot = try AudioInputBuffer(avAudioBuffer: buffer)
                handler(snapshot)
            } catch {
                self?.onEvent?(.invalidBuffer)
            }
        }
        tapInstalled = true
    }

    public func removeInputTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    public func start() throws {
        do {
            try engine.start()
        } catch {
            throw KVoiceError(code: .audioEngineStartFailed, retryable: false)
        }
    }

    public func stop() {
        engine.stop()
    }

    /// Sets `kAudioOutputUnitProperty_CurrentDevice` on the input node's
    /// audio unit. A `nil` UID (or a UID that is no longer connected) routes
    /// back to the system default input, which is what CoreAudio does when
    /// the property is set to the default device's ID.
    public func selectInputDevice(uid: String?) throws {
        let requested = uid.flatMap(CoreAudioInputDeviceProvider.deviceID(forUID:))
        if requested == nil, pinnedInputDeviceID == nil {
            // Never pinned, and asked for the system default: leave the input
            // node alone so it keeps following System Settings.
            return
        }
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw KVoiceError(code: .audioInputUnavailable, retryable: false)
        }
        guard var deviceID = requested ?? CoreAudioInputDeviceProvider.defaultInputDeviceID() else {
            throw KVoiceError(code: .audioInputUnavailable, retryable: false)
        }
        guard deviceID != pinnedInputDeviceID else { return }
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw KVoiceError(code: .audioInputUnavailable, retryable: false)
        }
        // Once the property has been set the node no longer follows System
        // Settings on its own, so a later system-default start re-applies
        // whatever the default is at that moment.
        pinnedInputDeviceID = deviceID
    }

    private var pinnedInputDeviceID: AudioDeviceID?
}
