import Foundation
import XCTest
import KvoiceDomain
@testable import KvoiceAudio

final class AudioCaptureServiceTests: XCTestCase {
    func testProductionConverterDownmixesAndResamplesFiniteInput() throws {
        let converter = try AVAudioConverterAdapter(
            inputFormat: AudioInputFormat(sampleRate: 48_000, channelCount: 2)
        )
        let input = AudioInputBuffer(
            sampleRate: 48_000,
            channelCount: 2,
            samples: makeStereoSine(frameCount: 480, sampleRate: 48_000)
        )

        let converted = try converter.convert(input)
        let tail = try converter.finish()
        let samples = converted + tail

        XCTAssertEqual(converter.outputSampleRate, 16_000)
        XCTAssertEqual(converter.outputChannelCount, 1)
        XCTAssertGreaterThan(samples.count, 0)
        XCTAssertLessThanOrEqual(abs(samples.count - 160), 4)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
    }

    func testStartStopSerializesTapAndFlushesConverterTail() async throws {
        let engine = TestAudioEngine(inputFormat: .init(sampleRate: 48_000, channelCount: 1))
        let converter = ScriptedConverter(
            convertedSamples: Array(repeating: 0.25, count: 160),
            tailSamples: [0.125]
        )
        let factory = ScriptedConverterFactory(converter: converter)
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: factory,
            permissionProvider: GrantedMicrophonePermissionProvider(),
            maximumDuration: .seconds(10)
        )
        let events = EventCollector()
        let jobID = UUID()

        try await service.start(jobID: jobID) { event in
            await events.append(event)
        }
        let started = await service.isRecording
        XCTAssertTrue(started)
        engine.emit(.init(sampleRate: 48_000, channelCount: 1, samples: [0, 0, 0]))

        let recording = try await service.stop(jobID: jobID)
        let stopped = await service.isRecording
        XCTAssertFalse(stopped)
        XCTAssertEqual(recording.sampleRate, 16_000)
        XCTAssertEqual(recording.channelCount, 1)
        XCTAssertEqual(recording.samples.count, 161)
        XCTAssertEqual(recording.samples.last, 0.125)
        XCTAssertEqual(recording.duration, .seconds(161.0 / 16_000.0))
        let emittedEvents = await events.values
        XCTAssertEqual(emittedEvents.first, .elapsed(.zero))
        XCTAssertTrue(emittedEvents.contains {
            if case .level = $0 { return true }
            return false
        })
        XCTAssertEqual(engine.installCount, 1)
        XCTAssertEqual(engine.removeCount, 1)
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(converter.finishCount, 1)
    }

    func testCancelDiscardsAllSamplesAndReleasesTap() async throws {
        let engine = TestAudioEngine(inputFormat: .init(sampleRate: 16_000, channelCount: 1))
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: ScriptedConverterFactory(converter: ScriptedConverter(convertedSamples: Array(repeating: 0.1, count: 200))),
            permissionProvider: GrantedMicrophonePermissionProvider(),
            maximumDuration: .seconds(10)
        )
        let jobID = UUID()
        try await service.start(jobID: jobID) { _ in }
        engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: Array(repeating: 0.1, count: 200)))
        await service.cancel(jobID: jobID)

        let cancelled = await service.isRecording
        XCTAssertFalse(cancelled)
        XCTAssertEqual(engine.removeCount, 1)
        do {
            _ = try await service.stop(jobID: jobID)
            XCTFail("cancelled recording must not be returned")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .appCancelled)
        }
    }

    func testInvalidConverterOutputFailsClosedBeforeRecording() async throws {
        let engine = TestAudioEngine(inputFormat: .init(sampleRate: 16_000, channelCount: 1))
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: ScriptedConverterFactory(
                converter: ScriptedConverter(convertedSamples: [Float.nan])
            ),
            permissionProvider: GrantedMicrophonePermissionProvider()
        )
        let jobID = UUID()
        try await service.start(jobID: jobID) { _ in }
        engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: [0]))
        await Task.yield()
        await Task.yield()

        do {
            _ = try await service.stop(jobID: jobID)
            XCTFail("non-finite converter output must fail")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .sttInvalidAudio)
            let stopped = await service.isRecording
            XCTAssertFalse(stopped)
        }
    }

    func testClippingProducesWarningAndImmutableMetadata() async throws {
        let engine = TestAudioEngine(inputFormat: .init(sampleRate: 16_000, channelCount: 1))
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: ScriptedConverterFactory(
                converter: ScriptedConverter(convertedSamples: Array(repeating: 1, count: 200))
            ),
            permissionProvider: GrantedMicrophonePermissionProvider()
        )
        let events = EventCollector()
        let jobID = UUID()
        try await service.start(jobID: jobID) { event in await events.append(event) }
        engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: Array(repeating: 0, count: 200)))
        let recording = try await service.stop(jobID: jobID)

        XCTAssertEqual(recording.clippedFrameCount, 200)
        XCTAssertEqual(recording.peakLevelDBFS, 0, accuracy: 0.001)
        let warnings = await events.values.compactMap { event -> AudioCaptureWarning? in
            guard case .warning(let warning) = event else { return nil }
            return warning
        }
        XCTAssertEqual(warnings, [.clipping(frameCount: 200)])
    }

    /// 2026-09-16: the flake behind the test above, reproduced on purpose.
    /// The buffer queues `[.level, .warning(.clipping)]`; the sink parks on
    /// `.level`, and `stop` is called while it is parked — exactly the
    /// interleaving under load. Before the event pipeline, `stop` tore the
    /// sink down while the tap's task was suspended in it and the warning
    /// was refused; now `stop` waits for the queued events to be delivered.
    func testClippingWarningSurvivesAStopThatInterleavesWithDelivery() async throws {
        let engine = TestAudioEngine(inputFormat: .init(sampleRate: 16_000, channelCount: 1))
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: ScriptedConverterFactory(
                converter: ScriptedConverter(convertedSamples: Array(repeating: 1, count: 200))
            ),
            permissionProvider: GrantedMicrophonePermissionProvider()
        )
        let events = EventCollector()
        let gate = DeliveryGate()
        let jobID = UUID()
        try await service.start(jobID: jobID) { event in
            if case .level = event {
                await gate.reached()
                await gate.wait()
            }
            await events.append(event)
        }
        engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: Array(repeating: 0, count: 200)))
        await gate.untilReached()

        // `stop` while the sink is parked on `.level`; give it every chance
        // to run its teardown before the gate opens.
        let stop = Task { try await service.stop(jobID: jobID) }
        for _ in 0..<20 { await Task.yield() }
        await gate.open()
        let recording = try await stop.value

        XCTAssertEqual(recording.clippedFrameCount, 200)
        let delivered = await events.values
        XCTAssertEqual(delivered, [
            .elapsed(.zero),
            .level(rmsDBFS: 0, peakDBFS: 0),
            .warning(.clipping(frameCount: 200)),
        ], "every event the buffer raised is delivered, in order, before stop returns")
        let stopped = await service.isRecording
        XCTAssertFalse(stopped)
    }

    /// 2026-09-16 review: the drain waits for the sink, so a sink that never
    /// returns would have blocked a `cancel` (Escape, quit) that arrived
    /// while a tap-side failure teardown was mid-drain. `cancel` for that
    /// job abandons the drain instead: it returns, the service is idle, and
    /// the parked sink is simply never resumed.
    func testCancelDoesNotWaitOnAParkedSinkDuringATapSideTeardown() async throws {
        let engine = TestAudioEngine(inputFormat: .init(sampleRate: 16_000, channelCount: 1))
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: ScriptedConverterFactory(
                converter: ScriptedConverter(convertedSamples: [Float.nan])
            ),
            permissionProvider: GrantedMicrophonePermissionProvider()
        )
        let gate = DeliveryGate()
        let jobID = UUID()
        // The sink parks on the very first event and is never released.
        try await service.start(jobID: jobID) { _ in
            await gate.reached()
            await gate.wait()
        }
        await gate.untilReached()
        // A non-finite buffer: the tap side fails the capture and its
        // cleanup starts draining into the parked sink.
        engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: [0]))
        for _ in 0..<20 { await Task.yield() }

        let cancel = Task { await service.cancel(jobID: jobID) }
        var idle = false
        for _ in 0..<200 where !idle {
            await Task.yield()
            idle = await !service.isRecording
        }
        XCTAssertTrue(idle, "cancel must not wait for a sink that never returns")
        // Bounded: the task finished (a hang would leave `idle` false above
        // and this await would never return, so it sits behind the assert).
        if idle { await cancel.value }
        let stopped = await service.isRecording
        XCTAssertFalse(stopped)
        // A later stop for the job finds nothing: the cancel cleared it.
        do {
            _ = try await service.stop(jobID: jobID)
            XCTFail("a cancelled job has no recording")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .appCancelled)
        }
    }

    func testConfigurationChangeStopsCaptureWithDeviceWarning() async throws {
        let engine = TestAudioEngine(inputFormat: .init(sampleRate: 16_000, channelCount: 1), deviceName: "Test Input")
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: ScriptedConverterFactory(
                converter: ScriptedConverter(convertedSamples: Array(repeating: 0.1, count: 200))
            ),
            permissionProvider: GrantedMicrophonePermissionProvider()
        )
        let events = EventCollector()
        let jobID = UUID()
        try await service.start(jobID: jobID) { event in await events.append(event) }
        engine.emitEvent(.configurationChanged)
        for _ in 0..<100 {
            if !(await service.isRecording) {
                break
            }
            await Task.yield()
        }

        let stopped = await service.isRecording
        XCTAssertFalse(stopped)
        let emittedEvents = await events.values
        XCTAssertEqual(
            emittedEvents,
            [.elapsed(.zero), .deviceChanged(name: "Test Input"), .warning(.inputChanged)]
        )
        do {
            _ = try await service.stop(jobID: jobID)
            XCTFail("configuration changes must not return a partial recording")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .audioInputChanged)
        }
    }

    func testMicrophoneTestReturnsAggregateOnlyAndLeavesNoRecording() async throws {
        let engine = TestAudioEngine(inputFormat: .init(sampleRate: 16_000, channelCount: 1))
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: ScriptedConverterFactory(converter: ScriptedConverter(convertedSamples: [0.25])),
            permissionProvider: GrantedMicrophonePermissionProvider(),
            maximumDuration: .seconds(10)
        )
        let result = try await service.runMicrophoneTest(duration: .zero)

        XCTAssertEqual(result.capturedSamples, 0)
        XCTAssertEqual(result.peakLevelDBFS, -120)
        let stopped = await service.isRecording
        XCTAssertFalse(stopped)
        XCTAssertEqual(engine.removeCount, 1)
    }

    func testMicrophoneTestKeepsAggregateResultWhenSampleCapIsReached() async throws {
        let engine = TestAudioEngine(inputFormat: .init(sampleRate: 16_000, channelCount: 1))
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: ScriptedConverterFactory(
                converter: ScriptedConverter(convertedSamples: Array(repeating: 0.25, count: 500))
            ),
            permissionProvider: GrantedMicrophonePermissionProvider(),
            maximumDuration: .milliseconds(10)
        )
        engine.onStart = {
            engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: [0]))
        }

        let result = try await service.runMicrophoneTest(duration: .zero)

        XCTAssertEqual(result.capturedSamples, 160)
        XCTAssertEqual(result.peakLevelDBFS, -12.0412, accuracy: 0.001)
        let stopped = await service.isRecording
        XCTAssertFalse(stopped)
    }

    /// C.2 step 5: the level meter reads live during the test, and only
    /// `.level` events cross the boundary — never samples or elapsed time.
    func testMicrophoneTestStreamsLevelEventsWhileRunning() async throws {
        let engine = TestAudioEngine(inputFormat: .init(sampleRate: 16_000, channelCount: 1))
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: ScriptedConverterFactory(
                converter: ScriptedConverter(convertedSamples: Array(repeating: 0.25, count: 100))
            ),
            permissionProvider: GrantedMicrophonePermissionProvider(),
            maximumDuration: .seconds(10)
        )
        engine.onStart = {
            engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: [0]))
        }
        let received = LevelRecorder()

        _ = try await service.runMicrophoneTest(duration: .zero) { event in
            await received.record(event)
        }
        // The tap update is delivered on the actor after the test returns;
        // give it a moment to drain.
        for _ in 0..<50 where await received.events.isEmpty {
            await Task.yield()
        }

        let events = await received.events
        XCTAssertFalse(events.isEmpty)
        for event in events {
            guard case .level(let rms, let peak) = event else {
                return XCTFail("only level events may reach a meter, got \(event)")
            }
            XCTAssertEqual(peak, -12.0412, accuracy: 0.001)
            XCTAssertLessThanOrEqual(rms, peak)
        }
    }

    func testSecondStartIsRejectedWhileFirstCaptureIsActive() async throws {
        let engine = TestAudioEngine(inputFormat: .init(sampleRate: 16_000, channelCount: 1))
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: ScriptedConverterFactory(converter: ScriptedConverter(convertedSamples: [0.1])),
            permissionProvider: GrantedMicrophonePermissionProvider()
        )
        try await service.start(jobID: UUID()) { _ in }
        do {
            try await service.start(jobID: UUID()) { _ in }
            XCTFail("a second capture must not overlap the first")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .appBusy)
        }
    }

    func testMicrophonePermissionIsCheckedBeforeEngineStart() async throws {
        let engine = TestAudioEngine(inputFormat: .init(sampleRate: 16_000, channelCount: 1))
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: ScriptedConverterFactory(converter: ScriptedConverter(convertedSamples: [0.1])),
            permissionProvider: ScriptedMicrophonePermissionProvider(status: .denied)
        )

        do {
            try await service.start(jobID: UUID()) { _ in }
            XCTFail("denied microphone permission must prevent engine start")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .permissionMicrophoneDenied)
        }
        XCTAssertEqual(engine.startCount, 0)
        XCTAssertEqual(engine.installCount, 0)
    }

    func testSampleCapBoundsMemoryAndEmitsDurationWarning() async throws {
        let engine = TestAudioEngine(inputFormat: .init(sampleRate: 16_000, channelCount: 1))
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: ScriptedConverterFactory(
                converter: ScriptedConverter(convertedSamples: Array(repeating: 0.1, count: 500))
            ),
            permissionProvider: GrantedMicrophonePermissionProvider(),
            maximumDuration: .milliseconds(10)
        )
        let events = EventCollector()
        let jobID = UUID()
        try await service.start(jobID: jobID) { event in await events.append(event) }
        engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: Array(repeating: 0, count: 500)))
        let recording = try await service.stop(jobID: jobID)

        XCTAssertEqual(recording.samples.count, 160)
        let emittedEvents = await events.values
        XCTAssertTrue(emittedEvents.contains(.warning(.durationCap)))
    }

    private func makeStereoSine(frameCount: Int, sampleRate: Double) -> [Float] {
        (0..<frameCount).flatMap { index in
            let sample = Float(sin(Double(index) / sampleRate * 2 * .pi * 440)) * 0.25
            return [sample, sample]
        }
    }
}

private actor EventCollector {
    private(set) var values: [AudioCaptureEvent] = []

    func append(_ event: AudioCaptureEvent) {
        values.append(event)
    }
}

/// Parks a sink until the test says so, and tells the test when the sink
/// got there. Two one-shot latches, so the interleaving is the test's
/// choice rather than the scheduler's.
private actor DeliveryGate {
    private var isReached = false
    private var isOpen = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    /// The sink has entered the gated event.
    func reached() {
        isReached = true
        let waiters = reachedWaiters
        reachedWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func untilReached() async {
        if isReached { return }
        await withCheckedContinuation { reachedWaiters.append($0) }
    }

    /// Lets the parked sink continue.
    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }
}

private struct GrantedMicrophonePermissionProvider: MicrophonePermissionProviding, Sendable {
    func authorization() async -> PermissionAuthorization { .granted }

    func requestAccess() async -> PermissionAuthorization { .granted }
}

private struct ScriptedMicrophonePermissionProvider: MicrophonePermissionProviding, Sendable {
    let status: PermissionAuthorization

    func authorization() async -> PermissionAuthorization { status }

    func requestAccess() async -> PermissionAuthorization { status }
}

private final class TestAudioEngine: AudioEngineAdapter, @unchecked Sendable {
    let inputFormat: AudioInputFormat?
    let inputDeviceName: String?
    var onEvent: (@Sendable (AudioEngineAdapterEvent) -> Void)?
    var onStart: (() -> Void)?
    private var handler: (@Sendable (AudioInputBuffer) -> Void)?

    private(set) var installCount = 0
    private(set) var removeCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(inputFormat: AudioInputFormat?, deviceName: String? = nil) {
        self.inputFormat = inputFormat
        self.inputDeviceName = deviceName
    }

    func installInputTap(
        bufferSize _: Int,
        format: AudioInputFormat,
        handler: @escaping @Sendable (AudioInputBuffer) -> Void
    ) throws {
        guard format == inputFormat else {
            throw KVoiceError(code: .audioInputChanged, retryable: false)
        }
        self.handler = handler
        installCount += 1
    }

    func removeInputTap() {
        handler = nil
        removeCount += 1
    }

    func start() throws {
        startCount += 1
        onStart?()
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ input: AudioInputBuffer) {
        handler?(input)
    }

    func emitEvent(_ event: AudioEngineAdapterEvent) {
        onEvent?(event)
    }
}

private final class ScriptedConverterFactory: AudioConverterFactory, @unchecked Sendable {
    let converter: ScriptedConverter

    init(converter: ScriptedConverter) {
        self.converter = converter
    }

    func makeConverter(for _: AudioInputFormat) throws -> any AudioConverterAdapter {
        converter
    }
}

private final class ScriptedConverter: AudioConverterAdapter, @unchecked Sendable {
    let outputSampleRate: Double = 16_000
    let outputChannelCount: Int = 1
    private let convertedSamples: ContiguousArray<Float>
    private let tailSamples: ContiguousArray<Float>
    private(set) var finishCount = 0

    init(convertedSamples: [Float], tailSamples: [Float] = []) {
        self.convertedSamples = ContiguousArray(convertedSamples)
        self.tailSamples = ContiguousArray(tailSamples)
    }

    func convert(_ input: AudioInputBuffer) throws -> ContiguousArray<Float> {
        guard input.isValid else {
            throw KVoiceError(code: .sttInvalidAudio, retryable: false)
        }
        return convertedSamples
    }

    func finish() throws -> ContiguousArray<Float> {
        finishCount += 1
        return tailSamples
    }
}

private actor LevelRecorder {
    private(set) var events: [AudioCaptureEvent] = []

    func record(_ event: AudioCaptureEvent) {
        events.append(event)
    }
}
