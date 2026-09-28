import CoreAudio
import Foundation
import XCTest
@testable import KvoiceAudio
@testable import KvoiceDomain

/// Recording-time options: the output muter's policy, the cue sets (the
/// synthesised kvoice tones and the bundled alert sounds), the recorder's
/// leading-silence drop, and the capture service's adjustable ceiling and
/// input-device selection.
final class RecordingOptionsTests: XCTestCase {
    // MARK: Output muting

    func testMuterLowersOnceRestoresOnceAndRespectsTheUsersChanges() async {
        let access = FakeVolumeAccess(volume: 0.6)
        let muter = SystemOutputMuter(access: access)

        await muter.mute()
        await muter.mute()
        XCTAssertEqual(access.writes, [0])
        let pending = await muter.pendingRestoreVolume
        XCTAssertEqual(pending, 0.6)

        await muter.restore()
        await muter.restore()
        XCTAssertEqual(access.writes, [0, 0.6])
        let cleared = await muter.pendingRestoreVolume
        XCTAssertNil(cleared)

        // Already silent: nothing written, nothing to put back.
        access.volume = 0
        await muter.mute()
        await muter.restore()
        XCTAssertEqual(access.writes, [0, 0.6])

        // The user turned it up during the recording; their level wins.
        access.volume = 0.5
        await muter.mute()
        access.volume = 0.8
        await muter.restore()
        XCTAssertEqual(access.writes, [0, 0.6, 0])

        // A device that refuses the write saves nothing.
        access.volume = 0.4
        access.writable = false
        await muter.mute()
        let refused = await muter.pendingRestoreVolume
        XCTAssertNil(refused)
    }

    func testFeedbackCuesMapToDistinctBundledSystemSounds() {
        let urls = RecordingFeedbackCue.allCases.map(RecordingFeedbackSoundMap.soundURL(for:))
        XCTAssertEqual(Set(urls).count, RecordingFeedbackCue.allCases.count)
        for url in urls {
            XCTAssertTrue(url.path.hasPrefix("/System/Library/Sounds/"))
            XCTAssertEqual(url.pathExtension, "aiff")
        }
    }

    func testFeedbackPlayerSkipsMissingSoundFilesSilently() async {
        // Never plays audio in the suite: the file manager reports no files
        // for the system sets, and the tone path is switched off.
        let player = SystemRecordingFeedbackPlayer(fileManager: NoFilesFileManager(), playsTones: false)
        await player.play(.start, using: .systemClassic)
        await player.play(.pasted, using: .system(name: "Glass"))
        await player.play(.start, using: .kvoice)
    }

    // MARK: Cue sets (2026-09-16)

    func testCueSetsMapEveryCueToTheExpectedSound() {
        for cue in RecordingFeedbackCue.allCases {
            XCTAssertNil(RecordingFeedbackCueSet.kvoice.systemSoundName(for: cue), "the kvoice set is synthesised, not a file")
            XCTAssertEqual(RecordingFeedbackCueSet.system(name: "Glass").systemSoundName(for: cue), "Glass", "one sound for every cue")
        }
        XCTAssertEqual(RecordingFeedbackCueSet.systemClassic.systemSoundName(for: .start), "Tink")
        XCTAssertEqual(RecordingFeedbackCueSet.systemClassic.systemSoundName(for: .stop), "Pop")
        XCTAssertEqual(RecordingFeedbackCueSet.systemClassic.systemSoundName(for: .cancel), "Funk")
        XCTAssertEqual(RecordingFeedbackCueSet.systemClassic.systemSoundName(for: .pasted), "Purr")
        XCTAssertFalse(RecordingFeedbackCueSet.kvoice.usesSystemAlertSounds)
        XCTAssertTrue(RecordingFeedbackCueSet.systemClassic.usesSystemAlertSounds)
        XCTAssertEqual(RecordingFeedbackSoundMap.soundURL(named: "Glass").path, "/System/Library/Sounds/Glass.aiff")
        XCTAssertTrue(RecordingFeedbackCueSet.systemSoundNames.contains("Tink"))
        XCTAssertEqual(Set(RecordingFeedbackCueSet.systemSoundNames).count, RecordingFeedbackCueSet.systemSoundNames.count)
    }

    func testSynthesizedCuesAreShortMidBandAndPeakAtMinusTwelveDBFS() {
        let sampleRate = SynthesizedCueSet.sampleRate
        // Start and stop: two 75 ms notes; cancel: two ticks and a gap;
        // pasted: one 30 ms click.
        let expectedSeconds: [RecordingFeedbackCue: Double] = [.start: 0.15, .stop: 0.15, .cancel: 0.13, .pasted: 0.03]
        for cue in RecordingFeedbackCue.allCases {
            let samples = SynthesizedCueSet.samples(for: cue)
            XCTAssertEqual(Double(samples.count) / sampleRate, expectedSeconds[cue]!, accuracy: 0.001, "\(cue)")
            XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= SynthesizedCueSet.peakAmplitude + 0.0001 }, "\(cue) never exceeds the ceiling")
            let peak = SpeechGate.peakLevelDBFS(of: samples)
            let expectedPeak: Float = cue == .pasted ? -18 : -12
            XCTAssertEqual(peak, expectedPeak, accuracy: 0.6, "\(cue) peaks at the set level")
            XCTAssertEqual(samples.first, 0, "\(cue) starts at zero (attack), so no click")
            XCTAssertEqual(samples.last ?? 1, 0, accuracy: 0.0001, "\(cue) ends at zero (release)")
        }
        // Start rises, stop falls: the second note is the higher one for
        // start and the lower one for stop.
        let start = SynthesizedCueSet.notes(for: .start)
        let stop = SynthesizedCueSet.notes(for: .stop)
        XCTAssertLessThan(start[0].frequency, start[1].frequency)
        XCTAssertGreaterThan(stop[0].frequency, stop[1].frequency)
        XCTAssertEqual(start.map(\.frequency), stop.map(\.frequency).reversed())
        // Every note sits inside the 300–3400 Hz band a Bluetooth call
        // profile carries.
        for cue in RecordingFeedbackCue.allCases {
            for note in SynthesizedCueSet.notes(for: cue) where note.amplitude > 0 {
                XCTAssertGreaterThanOrEqual(note.frequency, 300)
                XCTAssertLessThanOrEqual(note.frequency, 3_400)
            }
        }
    }

    func testSynthesizedCueEncodesToAValidMonoSixteenBitWAV() {
        let samples = SynthesizedCueSet.samples(for: .start)
        let data = SynthesizedCueSet.wavData(for: .start)
        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        func uint32(_ offset: Int) -> UInt32 {
            data[offset..<offset + 4].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        }
        func uint16(_ offset: Int) -> UInt16 {
            UInt16(data[offset + 1]) << 8 | UInt16(data[offset])
        }
        XCTAssertEqual(uint32(4), UInt32(36 + samples.count * 2))
        XCTAssertEqual(uint16(20), 1, "PCM")
        XCTAssertEqual(uint16(22), 1, "mono")
        XCTAssertEqual(uint32(24), UInt32(SynthesizedCueSet.sampleRate))
        XCTAssertEqual(uint16(34), 16, "bits per sample")
        XCTAssertEqual(uint32(40), UInt32(samples.count * 2))
        // Deterministic: the player prepares the data once and reuses it.
        XCTAssertEqual(data, SynthesizedCueSet.wavData(for: .start))
    }

    // MARK: Leading silence (2026-09-16)

    func testRecordingStartsAtTheFirstBufferWithSignal() async throws {
        let engine = RoutingTestEngine(inputFormat: .init(sampleRate: 16_000, channelCount: 1))
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: PassthroughConverterFactory(),
            permissionProvider: AlwaysGrantedMicrophonePermission(),
            deviceProvider: nil
        )
        let events = LevelCollector()
        let jobID = UUID()
        try await service.start(jobID: jobID) { event in await events.append(event) }
        // Two buffers of the zero-fill a Bluetooth route delivers while it
        // switches, then speech, then more speech.
        engine.emit(samples: Array(repeating: 0, count: 8_000))
        engine.emit(samples: Array(repeating: 0, count: 8_000))
        engine.emit(samples: Array(repeating: 0.3, count: 4_000))
        engine.emit(samples: Array(repeating: 0.1, count: 4_000))
        // Level delivery is best effort once `stop` is under way (the sink
        // map is torn down), so let the four tap tasks report first.
        for _ in 0..<2_000 where await events.peaks.count < 4 {
            await Task.yield()
        }
        let recording = try await service.stop(jobID: jobID)

        XCTAssertEqual(recording.samples.count, 8_000, "the two silent buffers are gone; the recording starts at the speech")
        XCTAssertEqual(recording.samples.first, 0.3)
        XCTAssertEqual(recording.samples.last, 0.1)
        XCTAssertEqual(recording.duration, .seconds(0.5))
        XCTAssertEqual(recording.peakLevelDBFS, SpeechGate.peakLevelDBFS(of: [0.3]), accuracy: 0.01)
        let peaks = await events.peaks
        XCTAssertEqual(peaks.count, 4, "every buffer still reports a level, silent ones included, so the controller sees the switch end")
        // Delivery order across tap tasks is not guaranteed; the mix is.
        XCTAssertEqual(peaks.filter { $0 <= SpeechGate.signalPeakThresholdDBFS }.count, 2)
        XCTAssertEqual(peaks.filter { $0 > SpeechGate.signalPeakThresholdDBFS }.count, 2)
    }

    func testRecordingWithoutSignalIsReturnedWholeForTheSilenceOutcome() async throws {
        let engine = RoutingTestEngine(inputFormat: .init(sampleRate: 16_000, channelCount: 1))
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: PassthroughConverterFactory(),
            permissionProvider: AlwaysGrantedMicrophonePermission(),
            deviceProvider: nil
        )
        let jobID = UUID()
        try await service.start(jobID: jobID) { _ in }
        engine.emit(samples: Array(repeating: 0, count: 16_000))
        engine.emit(samples: Array(repeating: 0, count: 16_000))
        let recording = try await service.stop(jobID: jobID)
        XCTAssertEqual(recording.samples.count, 32_000, "nothing dropped: the silence gate, not an empty-audio error, must answer this")
        XCTAssertEqual(recording.duration, .seconds(2))
        XCTAssertLessThanOrEqual(recording.peakLevelDBFS, SpeechGate.silencePeakThresholdDBFS)
    }

    // MARK: Bluetooth transport (2026-09-16)

    func testBluetoothTransportsMapToTheDeviceFlagAndNothingElseDoes() {
        XCTAssertTrue(CoreAudioInputDeviceProvider.isBluetoothTransport(kAudioDeviceTransportTypeBluetooth))
        XCTAssertTrue(CoreAudioInputDeviceProvider.isBluetoothTransport(kAudioDeviceTransportTypeBluetoothLE))
        for other in [
            kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeAggregate,
            kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeContinuityCaptureWired,
            kAudioDeviceTransportTypeContinuityCaptureWireless, kAudioDeviceTransportTypeUnknown
        ] {
            XCTAssertFalse(CoreAudioInputDeviceProvider.isBluetoothTransport(other), "\(other)")
        }
        XCTAssertFalse(CoreAudioInputDeviceProvider.isBluetoothTransport(nil), "an unreadable property is not Bluetooth")
        XCTAssertFalse(AudioInputDevice(uid: "x", name: "x").isBluetooth, "off unless the provider says so")
    }

    // MARK: Adjustable ceiling and input device

    func testMaximumDurationIsBoundedAndFrozenWhileCapturing() async throws {
        let engine = RoutingTestEngine(inputFormat: .init(sampleRate: 16_000, channelCount: 1))
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: PassthroughConverterFactory(),
            permissionProvider: AlwaysGrantedMicrophonePermission(),
            deviceProvider: nil,
            maximumDuration: .seconds(99_999)
        )
        var cap = await service.currentMaximumDuration
        XCTAssertEqual(cap, AVAudioCaptureService.technicalCeiling, "init clamps to the four-hour ceiling")

        await service.setMaximumRecordingDuration(.seconds(1_800))
        cap = await service.currentMaximumDuration
        XCTAssertEqual(cap, .seconds(1_800))
        await service.setMaximumRecordingDuration(.zero)
        cap = await service.currentMaximumDuration
        XCTAssertEqual(cap, .milliseconds(1), "never zero: the sample budget must stay positive")

        await service.setMaximumRecordingDuration(.seconds(600))
        let jobID = UUID()
        try await service.start(jobID: jobID) { _ in }
        await service.setMaximumRecordingDuration(.seconds(3_600))
        cap = await service.currentMaximumDuration
        XCTAssertEqual(cap, .seconds(600), "a capture keeps the cap it was sized from")
        engine.emitOneSecond()
        _ = try await service.stop(jobID: jobID)
        await service.setMaximumRecordingDuration(.seconds(3_600))
        cap = await service.currentMaximumDuration
        XCTAssertEqual(cap, .seconds(3_600))
    }

    func testStartRoutesTheEngineToTheResolvedInputDevice() async throws {
        let engine = RoutingTestEngine(inputFormat: .init(sampleRate: 16_000, channelCount: 1))
        let usb = AudioInputDevice(uid: "usb", name: "USB Microphone")
        let builtIn = AudioInputDevice(uid: "builtin", name: "MacBook Pro Microphone")
        let provider = FakeDeviceProvider(available: [builtIn, usb], systemDefault: builtIn)
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: PassthroughConverterFactory(),
            permissionProvider: AlwaysGrantedMicrophonePermission(),
            deviceProvider: provider
        )

        // System default: the engine is told to follow the default (nil).
        var jobID = UUID()
        try await service.start(jobID: jobID) { _ in }
        engine.emitOneSecond()
        _ = try await service.stop(jobID: jobID)
        XCTAssertEqual(engine.selectedUIDs, [nil])
        var last = await service.lastInputSelection
        XCTAssertEqual(last, AudioInputSelection(device: builtIn, reason: .systemDefault))

        // Custom device: pinned by UID.
        await service.setInputSelection(AudioInputSettings(mode: .customDevice, customDeviceUID: "usb"))
        let resolved = await service.resolveInputSelection()
        XCTAssertEqual(resolved.pinnedDeviceUID, "usb")
        jobID = UUID()
        try await service.start(jobID: jobID) { _ in }
        engine.emitOneSecond()
        _ = try await service.stop(jobID: jobID)
        XCTAssertEqual(engine.selectedUIDs, [nil, "usb"])
        last = await service.lastInputSelection
        XCTAssertEqual(last?.reason, .customDevice)

        // The custom device left: back to the default, and the card says why.
        provider.available = [builtIn]
        jobID = UUID()
        try await service.start(jobID: jobID) { _ in }
        engine.emitOneSecond()
        _ = try await service.stop(jobID: jobID)
        XCTAssertEqual(engine.selectedUIDs, [nil, "usb", nil])
        last = await service.lastInputSelection
        XCTAssertEqual(last, AudioInputSelection(device: builtIn, reason: .customDeviceUnavailable))

        // Without a device provider the service follows the system default.
        let plain = AVAudioCaptureService(
            engine: engine,
            converterFactory: PassthroughConverterFactory(),
            permissionProvider: AlwaysGrantedMicrophonePermission(),
            deviceProvider: nil
        )
        await plain.setInputSelection(AudioInputSettings(mode: .customDevice, customDeviceUID: "usb"))
        let noProvider = await plain.resolveInputSelection()
        XCTAssertEqual(noProvider, AudioInputSelection(device: nil, reason: .systemDefault))
    }
}

// MARK: - Doubles

private struct AlwaysGrantedMicrophonePermission: MicrophonePermissionProviding, Sendable {
    func authorization() async -> PermissionAuthorization { .granted }
    func requestAccess() async -> PermissionAuthorization { .granted }
}

private final class FakeVolumeAccess: OutputVolumeAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var storedVolume: Float
    private var storedWritable = true
    private var storedWrites: [Float] = []

    init(volume: Float) {
        storedVolume = volume
    }

    var volume: Float {
        get { lock.lock(); defer { lock.unlock() }; return storedVolume }
        set { lock.lock(); storedVolume = newValue; lock.unlock() }
    }

    var writable: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storedWritable }
        set { lock.lock(); storedWritable = newValue; lock.unlock() }
    }

    var writes: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return storedWrites
    }

    func readVolume() -> Float? {
        volume
    }

    func writeVolume(_ volume: Float) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storedWritable else { return false }
        storedWrites.append(volume)
        storedVolume = volume
        return true
    }
}

private actor LevelCollector {
    private(set) var peaks: [Float] = []

    func append(_ event: AudioCaptureEvent) {
        if case .level(_, let peak) = event {
            peaks.append(peak)
        }
    }
}

private final class NoFilesFileManager: FileManager, @unchecked Sendable {
    override func fileExists(atPath _: String) -> Bool { false }
}

private final class FakeDeviceProvider: AudioInputDeviceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedAvailable: [AudioInputDevice]
    let systemDefault: AudioInputDevice?

    init(available: [AudioInputDevice], systemDefault: AudioInputDevice?) {
        storedAvailable = available
        self.systemDefault = systemDefault
    }

    var available: [AudioInputDevice] {
        get { lock.lock(); defer { lock.unlock() }; return storedAvailable }
        set { lock.lock(); storedAvailable = newValue; lock.unlock() }
    }

    func availableInputDevices() -> [AudioInputDevice] { available }
    func systemDefaultInputDevice() -> AudioInputDevice? { systemDefault }
}

private final class RoutingTestEngine: AudioEngineAdapter, @unchecked Sendable {
    let inputFormat: AudioInputFormat?
    let inputDeviceName: String? = nil
    var onEvent: (@Sendable (AudioEngineAdapterEvent) -> Void)?
    private let lock = NSLock()
    private var storedSelections: [String?] = []
    private var handler: (@Sendable (AudioInputBuffer) -> Void)?

    init(inputFormat: AudioInputFormat?) {
        self.inputFormat = inputFormat
    }

    /// One second of silence at the transcription format, so `stop` has a
    /// recording to return.
    func emitOneSecond() {
        emit(samples: Array(repeating: 0, count: 16_000))
    }

    func emit(samples: [Float]) {
        handler?(AudioInputBuffer(sampleRate: 16_000, channelCount: 1, samples: samples))
    }

    var selectedUIDs: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return storedSelections
    }

    func installInputTap(bufferSize _: Int, format _: AudioInputFormat, handler: @escaping @Sendable (AudioInputBuffer) -> Void) throws {
        self.handler = handler
    }

    func removeInputTap() {
        handler = nil
    }
    func start() throws {}
    func stop() {}

    func selectInputDevice(uid: String?) throws {
        lock.lock()
        storedSelections.append(uid)
        lock.unlock()
    }
}

private final class PassthroughConverterFactory: AudioConverterFactory, @unchecked Sendable {
    func makeConverter(for _: AudioInputFormat) throws -> any AudioConverterAdapter {
        PassthroughConverter()
    }
}

private final class PassthroughConverter: AudioConverterAdapter, @unchecked Sendable {
    let outputSampleRate: Double = 16_000
    let outputChannelCount: Int = 1

    func convert(_ input: AudioInputBuffer) throws -> ContiguousArray<Float> {
        ContiguousArray(input.samples)
    }

    func finish() throws -> ContiguousArray<Float> {
        []
    }
}
