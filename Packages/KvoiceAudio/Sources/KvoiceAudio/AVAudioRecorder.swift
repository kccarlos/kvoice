import Foundation
import KvoiceDomain

/// A clock seam keeps elapsed-time and microphone-test behavior deterministic
/// without weakening the production hard cap.
public protocol AudioCaptureClock: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(for duration: Duration) async throws
}

public struct SystemAudioCaptureClock: AudioCaptureClock, Sendable {
    private let clock = ContinuousClock()

    public init() {}

    public var now: ContinuousClock.Instant { clock.now }

    public func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

private struct CaptureSnapshot: Sendable {
    let samples: ContiguousArray<Float>
    let peakLevelDBFS: Float
    let clippedFrameCount: Int
    let clippingWarningEmitted: Bool
    let reachedCap: Bool
}

/// Result of consuming one tap buffer. Events are queued on the capture and
/// drained by the actor, so the update only carries the two flags the actor
/// must react to.
private struct CaptureUpdate: Sendable {
    let reachedCap: Bool
    let failure: KVoiceError?
    /// True for the one buffer that first carried signal (2026-09-16): the
    /// actor restarts the elapsed clock there, so the HUD's clock and the
    /// time-based cap count what the recording will contain.
    var signalStarted = false
}

/// Thread-safe state owned by one actor-started capture.  The AVAudioEngine
/// callback and the actor's stop/cancel path take the same lock, so converter
/// tail flushing cannot race an in-flight input tap.
private final class ActiveCapture: @unchecked Sendable {
    let token: UUID
    let jobID: JobID?
    let inputFormat: AudioInputFormat
    let converter: any AudioConverterAdapter
    let maximumFrames: Int

    private let lock = NSLock()
    private var acceptedSamples = ContiguousArray<Float>()
    private var peakLevelDBFS = AudioLevelMeter.silenceFloorDBFS
    private var clippedFrameCount = 0
    private var clippingWarningEmitted = false
    private var accepting = true
    private var failure: KVoiceError?
    private var reachedCap = false
    private var durationCapWarningEmitted = false
    private var pendingEvents: [AudioCaptureEvent] = []
    // MARK: Leading silence (2026-09-16)
    /// Samples accepted before the first tap buffer whose peak exceeded
    /// `SpeechGate.signalPeakThresholdDBFS`. On a Bluetooth route the input
    /// delivers zero-fill for up to two seconds while it switches profiles;
    /// those buffers only lengthen the clip and inflate the real-time factor.
    /// They are kept until `finish()` and dropped there only once signal did
    /// arrive, so a recording that never carried signal is returned whole and
    /// still reaches the silence outcome (`SpeechGate`) rather than an
    /// empty-audio error.
    private var leadingSilenceSampleCount = 0
    private var signalSeen = false
    // MARK: ADR-017 streaming chunks
    /// Converted samples accepted since the last drain, kept only while a
    /// streaming sink is installed. Never a second copy of the recording:
    /// the buffer is emptied on every actor tick.
    private var pendingChunkSamples = ContiguousArray<Float>()
    private var forwardsChunks = false

    /// A buffer at or below this peak carried no signal
    /// (`SpeechGate.signalPeakThresholdDBFS` compiled; ADR-022 slice 5
    /// hands the loaded value in).
    private let signalPeakThresholdDBFS: Float

    init(
        token: UUID = UUID(),
        jobID: JobID?,
        inputFormat: AudioInputFormat,
        converter: any AudioConverterAdapter,
        maximumFrames: Int,
        signalPeakThresholdDBFS: Float = SpeechGate.signalPeakThresholdDBFS
    ) {
        self.token = token
        self.jobID = jobID
        self.inputFormat = inputFormat
        self.converter = converter
        self.maximumFrames = max(1, maximumFrames)
        self.signalPeakThresholdDBFS = signalPeakThresholdDBFS
    }

    func consume(_ input: AudioInputBuffer) -> CaptureUpdate {
        lock.lock()
        defer { lock.unlock() }

        guard accepting, failure == nil else {
            return CaptureUpdate(reachedCap: reachedCap, failure: failure)
        }
        guard input.format == inputFormat else {
            let error = KVoiceError(code: .audioInputChanged, retryable: false)
            failure = error
            accepting = false
            return CaptureUpdate(reachedCap: false, failure: error)
        }
        guard input.isStructurallyValid else {
            let error = KVoiceError(code: .sttInvalidAudio, retryable: false)
            failure = error
            accepting = false
            return CaptureUpdate(reachedCap: false, failure: error)
        }
        guard input.containsOnlyFiniteSamples else {
            let error = KVoiceError(code: .sttInvalidAudio, retryable: false)
            failure = error
            accepting = false
            return CaptureUpdate(reachedCap: false, failure: error)
        }

        do {
            let converted = try converter.convert(input)
            guard converted.allSatisfy(\.isFinite) else {
                let error = KVoiceError(code: .sttInvalidAudio, retryable: false)
                failure = error
                accepting = false
                return CaptureUpdate(reachedCap: false, failure: error)
            }

            let remaining = max(0, maximumFrames - acceptedSamples.count)
            if remaining > 0, !converted.isEmpty {
                acceptedSamples.append(contentsOf: converted.prefix(remaining))
                if forwardsChunks {
                    pendingChunkSamples.append(contentsOf: converted.prefix(remaining))
                }
                if let measurement = AudioLevelMeter.measure(converted.prefix(remaining)) {
                    var signalStarted = false
                    if !signalSeen {
                        if measurement.peakDBFS > signalPeakThresholdDBFS {
                            signalSeen = true
                            signalStarted = true
                        } else {
                            leadingSilenceSampleCount += converted.prefix(remaining).count
                        }
                    }
                    peakLevelDBFS = max(peakLevelDBFS, measurement.peakDBFS)
                    clippedFrameCount += measurement.clippedFrameCount
                    var events: [AudioCaptureEvent] = [
                        .level(
                            rmsDBFS: measurement.rmsDBFS,
                            peakDBFS: measurement.peakDBFS
                        )
                    ]
                    if measurement.clippedFrameCount > 0 && !clippingWarningEmitted {
                        clippingWarningEmitted = true
                        events.append(.warning(.clipping(frameCount: measurement.clippedFrameCount)))
                    }
                    if acceptedSamples.count >= maximumFrames {
                        reachedCap = true
                    }
                    pendingEvents.append(contentsOf: events)
                    return CaptureUpdate(reachedCap: reachedCap, failure: nil, signalStarted: signalStarted)
                }
            }

            if acceptedSamples.count >= maximumFrames {
                reachedCap = true
            }
            return CaptureUpdate(reachedCap: reachedCap, failure: nil)
        } catch let error as KVoiceError {
            failure = error
            accepting = false
            return CaptureUpdate(reachedCap: false, failure: error)
        } catch {
            let mapped = KVoiceError(code: .audioConversionFailed, retryable: false)
            failure = mapped
            accepting = false
            return CaptureUpdate(reachedCap: false, failure: mapped)
        }
    }

    func markFailure(_ error: KVoiceError) {
        lock.lock()
        failure = error
        accepting = false
        lock.unlock()
    }

    func currentFailure() -> KVoiceError? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func finish() throws -> CaptureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else {
            throw failure!
        }
        accepting = false
        let tail = try converter.finish()
        guard tail.allSatisfy(\.isFinite) else {
            let error = KVoiceError(code: .sttInvalidAudio, retryable: false)
            failure = error
            throw error
        }

        let remaining = max(0, maximumFrames - acceptedSamples.count)
        if remaining > 0 {
            acceptedSamples.append(contentsOf: tail.prefix(remaining))
            if let measurement = AudioLevelMeter.measure(tail.prefix(remaining)) {
                peakLevelDBFS = max(peakLevelDBFS, measurement.peakDBFS)
                clippedFrameCount += measurement.clippedFrameCount
            }
        }
        if acceptedSamples.count >= maximumFrames {
            reachedCap = true
        }
        // The recording starts at the first buffer that carried signal; the
        // zero-fill before it is not part of what the user said. Never
        // applied to a recording without signal (see the property's note).
        if signalSeen, leadingSilenceSampleCount > 0 {
            acceptedSamples.removeFirst(min(leadingSilenceSampleCount, acceptedSamples.count))
            leadingSilenceSampleCount = 0
        }

        return CaptureSnapshot(
            samples: acceptedSamples,
            peakLevelDBFS: peakLevelDBFS,
            clippedFrameCount: clippedFrameCount,
            clippingWarningEmitted: clippingWarningEmitted,
            reachedCap: reachedCap
        )
    }

    func cancel() {
        lock.lock()
        accepting = false
        acceptedSamples.removeAll(keepingCapacity: false)
        pendingEvents.removeAll(keepingCapacity: false)
        pendingChunkSamples.removeAll(keepingCapacity: false)
        forwardsChunks = false
        failure = nil
        leadingSilenceSampleCount = 0
        signalSeen = false
        lock.unlock()
    }

    // MARK: ADR-017 streaming chunks

    func setForwardsChunks(_ enabled: Bool) {
        lock.lock()
        forwardsChunks = enabled
        if !enabled {
            pendingChunkSamples.removeAll(keepingCapacity: false)
        }
        lock.unlock()
    }

    /// Everything accepted since the previous drain, in capture order, or
    /// `nil` when nothing is pending or forwarding is off.
    func drainChunkSamples() -> ContiguousArray<Float>? {
        lock.lock()
        defer { lock.unlock() }
        guard forwardsChunks, !pendingChunkSamples.isEmpty else { return nil }
        let samples = pendingChunkSamples
        pendingChunkSamples = ContiguousArray()
        return samples
    }

    func drainEvents() -> [AudioCaptureEvent] {
        lock.lock()
        defer { lock.unlock() }
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: false)
        return events
    }

    func hasReachedCap() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachedCap
    }

    func claimDurationCapWarning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !durationCapWarningEmitted else { return false }
        durationCapWarningEmitted = true
        return true
    }
}

/// Production implementation of the frozen KvoiceDomain audio protocol.
/// AVAudioEngine lifecycle calls are serialized by this actor; tap callbacks
/// use `ActiveCapture`'s lock and only schedule privacy-safe event metadata.
public actor AVAudioCaptureService: KvoiceDomain.AudioCaptureService, AudioCaptureConfiguring {
    /// The default cap (FR-AUD-009, D.5, product decision #10): recording
    /// stops and the captured audio is processed with a warning. The HUD
    /// warns at 4:30 and 5:00 without stopping. The user can raise it up to
    /// `technicalCeiling`.
    public static let defaultMaximumDuration: Duration = RecordingDurationLimit.default.duration
    /// "No limit" is still bounded: four hours of 16 kHz mono Float32 is
    /// about 920 MB, and the recorder pre-sizes nothing, so memory grows only
    /// with what is actually spoken.
    public static let technicalCeiling: Duration = .seconds(RecordingDurationLimit.technicalCeilingSeconds)
    public static let transcriptionSampleRate: Double = 16_000
    public static let transcriptionChannelCount = 1
    public static let minimumRecordingFrames = 160

    public private(set) var isRecording = false

    private let engine: any AudioEngineAdapter
    private let converterFactory: any AudioConverterFactory
    private let permissionProvider: any MicrophonePermissionProviding
    private let deviceProvider: (any AudioInputDeviceProviding)?
    private let clock: any AudioCaptureClock
    private var maximumDuration: Duration
    private var maximumFrames: Int
    private let inputTapBufferSize: Int
    private var inputSelectionSettings = AudioInputSettings()
    /// What the last `beginCapture` resolved, for the "Currently using" card
    /// and the device-changed event.
    public private(set) var lastInputSelection: AudioInputSelection?

    /// ADR-022 slice 5: the leading-silence threshold the tap applies
    /// (`SpeechGate.signalPeakThresholdDBFS` unless composed otherwise).
    private let signalPeakThresholdDBFS: Float
    private var activeCapture: ActiveCapture?
    private var elapsedTask: Task<Void, Never>?
    private var lastFailureByJob: [JobID: KVoiceError] = [:]
    private var completedByJob: [JobID: AudioRecording] = [:]
    private var testFailureByToken: [UUID: KVoiceError] = [:]
    private var startedAt: ContinuousClock.Instant?

    public init(
        engine: any AudioEngineAdapter = AVAudioEngineAdapter(),
        converterFactory: any AudioConverterFactory = AVAudioConverterFactory(),
        permissionProvider: any MicrophonePermissionProviding = SystemMicrophonePermissionProvider(),
        deviceProvider: (any AudioInputDeviceProviding)? = CoreAudioInputDeviceProvider(),
        clock: any AudioCaptureClock = SystemAudioCaptureClock(),
        maximumDuration: Duration = AVAudioCaptureService.defaultMaximumDuration,
        inputTapBufferSize: Int = 1024,
        signalPeakThresholdDBFS: Float = SpeechGate.signalPeakThresholdDBFS
    ) {
        self.signalPeakThresholdDBFS = signalPeakThresholdDBFS
        self.engine = engine
        self.converterFactory = converterFactory
        self.permissionProvider = permissionProvider
        self.deviceProvider = deviceProvider
        self.clock = clock
        let bounded = Self.boundedMaximumDuration(maximumDuration)
        self.maximumDuration = bounded
        self.maximumFrames = max(1, Self.frames(for: bounded))
        self.inputTapBufferSize = max(1, inputTapBufferSize)
    }

    deinit {
        // A capture dropped without `stop` (tests do this) must not leave the
        // elapsed-time task alive for another tick.
        elapsedTask?.cancel()
    }

    /// Positive and never past the technical ceiling.
    static func boundedMaximumDuration(_ requested: Duration) -> Duration {
        let positive = requested > .zero ? requested : .milliseconds(1)
        return min(positive, technicalCeiling)
    }

    /// The cap in force for the next recording (tests read it back).
    public var currentMaximumDuration: Duration { maximumDuration }

    // MARK: AudioCaptureConfiguring

    /// Applies between jobs; a capture already in progress keeps the cap it
    /// started with, since its sample budget was sized from it.
    public func setMaximumRecordingDuration(_ duration: Duration) {
        guard activeCapture == nil else { return }
        let bounded = Self.boundedMaximumDuration(duration)
        maximumDuration = bounded
        maximumFrames = max(1, Self.frames(for: bounded))
    }

    public func setInputSelection(_ settings: AudioInputSettings) {
        inputSelectionSettings = settings
    }

    /// The device the next recording will use, resolved against what is
    /// connected right now. Nil device means the system default input.
    public func resolveInputSelection() -> AudioInputSelection {
        guard let deviceProvider else {
            return AudioInputSelection(device: nil, reason: .systemDefault)
        }
        return AudioInputDeviceResolver.resolve(
            settings: inputSelectionSettings,
            available: deviceProvider.availableInputDevices(),
            systemDefault: deviceProvider.systemDefaultInputDevice()
        )
    }

    public func start(
        jobID: JobID,
        events: @escaping @Sendable (AudioCaptureEvent) async -> Void
    ) async throws {
        guard activeCapture == nil else {
            throw KVoiceError(code: .appBusy, retryable: false)
        }
        try await requireMicrophonePermission()
        lastFailureByJob.removeValue(forKey: jobID)
        completedByJob.removeValue(forKey: jobID)
        _ = try beginCapture(jobID: jobID, events: events)
        if let activeCapture {
            emit(.elapsed(.zero), for: activeCapture)
        }
    }

    public func stop(jobID: JobID) async throws -> AudioRecording {
        await settleTeardown()
        guard let activeCapture else {
            if let completed = completedByJob.removeValue(forKey: jobID) {
                return completed
            }
            if let failure = lastFailureByJob.removeValue(forKey: jobID) {
                throw failure
            }
            throw KVoiceError(code: .appCancelled, retryable: false)
        }
        guard activeCapture.jobID == jobID else {
            throw KVoiceError(code: .appBusy, retryable: false)
        }

        do {
            let snapshot = try activeCapture.finish()
            emitPendingEvents(for: activeCapture)
            if snapshot.reachedCap,
               activeCapture.jobID != nil,
               activeCapture.claimDurationCapWarning() {
                emit(.warning(.durationCap), for: activeCapture)
            }
            emitTailClippingWarningIfNeeded(snapshot, for: activeCapture)
            let recording = try recording(from: snapshot)
            await cleanup(activeCapture)
            return recording
        } catch let error as KVoiceError {
            lastFailureByJob[jobID] = error
            await cleanup(activeCapture)
            throw error
        } catch {
            let mapped = KVoiceError(code: .audioConversionFailed, retryable: false)
            lastFailureByJob[jobID] = mapped
            await cleanup(activeCapture)
            throw mapped
        }
    }

    public func cancel(jobID: JobID) async {
        // This job's own mid-drain teardown is abandoned, not awaited (see
        // "Event delivery"); another job's is settled as `stop` would.
        abandonTeardown(for: jobID)
        await settleTeardown()
        guard let activeCapture, activeCapture.jobID == jobID else {
            completedByJob.removeValue(forKey: jobID)
            lastFailureByJob.removeValue(forKey: jobID)
            return
        }
        // A cancelled job wants nothing more from its capture: queued
        // events are dropped, not delivered.
        await cleanup(activeCapture, droppingQueuedEvents: true)
        lastFailureByJob.removeValue(forKey: jobID)
    }

    public func runMicrophoneTest(
        duration: Duration,
        levels: (@Sendable (AudioCaptureEvent) async -> Void)?
    ) async throws -> MicrophoneTestResult {
        guard activeCapture == nil else {
            throw KVoiceError(code: .appBusy, retryable: false)
        }
        try await requireMicrophonePermission()

        // The level sink is installed like a job's event sink so the tap's
        // meter events reach the caller while the test runs; only `.level`
        // events are forwarded, never samples.
        var levelSink: (@Sendable (AudioCaptureEvent) async -> Void)?
        if let levels {
            levelSink = { event in
                if case .level = event {
                    await levels(event)
                }
            }
        }
        let token = try beginCapture(jobID: nil, events: levelSink)
        let requestedDuration = max(.zero, duration)
        let boundedDuration = min(requestedDuration, maximumDuration)
        do {
            try await clock.sleep(for: boundedDuration)
        } catch is CancellationError {
            if let activeCapture {
                await cleanup(activeCapture)
            }
            throw CancellationError()
        } catch {
            if let activeCapture {
                await cleanup(activeCapture)
            }
            throw error
        }

        guard let current = activeCapture, current.token == token else {
            if let failure = testFailureByToken.removeValue(forKey: token) {
                throw failure
            }
            throw KVoiceError(code: .audioInputUnavailable, retryable: false)
        }

        do {
            let snapshot = try current.finish()
            // A level the tap queued that the actor has not drained yet
            // still reaches the meter (the sink forwards `.level` only).
            emitPendingEvents(for: current)
            await cleanup(current)
            // The result contains only aggregate meter/count metadata.  The
            // converted samples are released with `current` before returning.
            return MicrophoneTestResult(
                duration: .seconds(Double(snapshot.samples.count) / Self.transcriptionSampleRate),
                peakLevelDBFS: snapshot.peakLevelDBFS,
                capturedSamples: snapshot.samples.count
            )
        } catch let error as KVoiceError {
            await cleanup(current)
            throw error
        } catch {
            await cleanup(current)
            throw KVoiceError(code: .audioConversionFailed, retryable: false)
        }
    }

    private func beginCapture(
        jobID: JobID?,
        events: (@Sendable (AudioCaptureEvent) async -> Void)?
    ) throws -> UUID {
        // Route the input node before reading its format: switching the
        // device changes the hardware format the tap must match.
        let selection = resolveInputSelection()
        lastInputSelection = selection
        try engine.selectInputDevice(uid: selection.pinnedDeviceUID)

        guard let inputFormat = engine.inputFormat, inputFormat.isValid else {
            throw KVoiceError(code: .audioInputUnavailable, retryable: false)
        }

        let converter = try converterFactory.makeConverter(for: inputFormat)
        let capture = ActiveCapture(
            jobID: jobID,
            inputFormat: inputFormat,
            converter: converter,
            maximumFrames: maximumFrames,
            signalPeakThresholdDBFS: signalPeakThresholdDBFS
        )
        let token = capture.token

        engine.onEvent = { [weak self] event in
            Task { [weak self] in
                await self?.handleEngineEvent(event, token: token)
            }
        }

        do {
            try engine.installInputTap(
                bufferSize: inputTapBufferSize,
                format: inputFormat
            ) { [weak self, weak capture] input in
                guard let capture else { return }
                let update = capture.consume(input)
                Task { [weak self] in
                    await self?.handleTapUpdate(update, token: token)
                }
            }
            try engine.start()
        } catch let error as KVoiceError {
            engine.removeInputTap()
            engine.stop()
            engine.onEvent = nil
            throw error
        } catch {
            engine.removeInputTap()
            engine.stop()
            engine.onEvent = nil
            throw KVoiceError(code: .audioEngineStartFailed, retryable: false)
        }

        activeCapture = capture
        if let events {
            armEventPipeline(for: token, sink: events)
        }
        // ADR-017: a sink installed before `start(jobID:)` arms forwarding
        // from the first buffer.
        if let jobID, let sink = pendingChunkSinksByJob.removeValue(forKey: jobID) {
            armChunkPipeline(for: capture, sink: sink)
        }
        isRecording = true
        startedAt = clock.now
        startElapsedTask(for: capture, events: events)
        return token
    }

    private func requireMicrophonePermission() async throws {
        switch await permissionProvider.authorization() {
        case .granted:
            return
        case .notDetermined:
            throw KVoiceError(code: .permissionMicrophoneNotDetermined, retryable: false)
        case .denied:
            throw KVoiceError(code: .permissionMicrophoneDenied, retryable: false)
        case .restricted:
            throw KVoiceError(code: .permissionMicrophoneRestricted, retryable: false)
        }
    }

    private func startElapsedTask(
        for capture: ActiveCapture,
        events: (@Sendable (AudioCaptureEvent) async -> Void)?
    ) {
        elapsedTask?.cancel()
        guard events != nil || capture.jobID != nil else {
            elapsedTask = nil
            return
        }
        // The clock is captured by value, not reached through `self?.`: once
        // the actor is released, `try await self?.clock.sleep(...)` becomes a
        // no-op and the loop spins at 100% CPU forever (that was the
        // "one-off" 30-minute test-suite hang of 2026-09-13; a service dropped
        // by a test without `stop` left its task burning a cooperative thread).
        elapsedTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await self.emitElapsed(for: capture.token)
            }
        }
    }

    private func emitElapsed(for token: UUID) async {
        guard let activeCapture, activeCapture.token == token else { return }
        let elapsed = startedAt.map { clock.now - $0 } ?? .zero
        if elapsed >= maximumDuration {
            await handleDurationCap(for: activeCapture)
            return
        }
        guard activeCapture.jobID != nil else { return }
        // Event delivery is installed in `eventSink`; the sink is only retained
        // by the capture's actor task to keep samples out of UI state.
        emit(.elapsed(elapsed), for: activeCapture)
    }

    private func handleTapUpdate(_ update: CaptureUpdate, token: UUID) async {
        guard let activeCapture, activeCapture.token == token else { return }
        if update.signalStarted {
            // The recording starts here (the buffers before it are dropped
            // in `finish()`), so the elapsed clock and the time-based cap
            // start here too. The sample cap still counts the dropped
            // buffers — at most a couple of seconds against a ten-minute
            // minimum, and on the safe side.
            startedAt = clock.now
        }
        // Both drains hand their run to an ordered pipeline (ADR-017 for the
        // chunks, 2026-09-16 for the events), in capture order.
        forwardPendingChunks(for: activeCapture)
        emitPendingEvents(for: activeCapture)
        if let failure = update.failure {
            await failCapture(activeCapture, error: failure)
            return
        }
        if update.reachedCap, activeCapture.jobID != nil {
            await handleDurationCap(for: activeCapture)
        }
    }

    private func handleEngineEvent(_ event: AudioEngineAdapterEvent, token: UUID) async {
        guard let activeCapture, activeCapture.token == token else { return }
        let error: KVoiceError
        switch event {
        case .configurationChanged:
            if activeCapture.jobID != nil {
                emit(.deviceChanged(name: engine.inputDeviceName), for: activeCapture)
                emit(.warning(.inputChanged), for: activeCapture)
            }
            error = KVoiceError(code: .audioInputChanged, retryable: false)
        case .interruption:
            if activeCapture.jobID != nil {
                emit(.warning(.interruption), for: activeCapture)
            }
            error = KVoiceError(code: .audioInterrupted, retryable: true)
        case .inputUnavailable, .invalidBuffer:
            error = KVoiceError(code: .audioInputUnavailable, retryable: true)
        }
        await failCapture(activeCapture, error: error)
    }

    private func handleDurationCap(for capture: ActiveCapture) async {
        guard activeCapture?.token == capture.token,
              capture.currentFailure() == nil
        else { return }
        // Finish and park the recording first, then tell the owner. The owner
        // reacts to the cap by calling `stop(jobID:)`, which settles this
        // teardown and must then find the completed recording rather than a
        // capture still being torn down. The warning is queued behind the
        // buffer's own events and delivered by the drain in `cleanup`, so it
        // has reached the owner before that `stop` returns. The sink must
        // not await `stop` inline (the job runner spawns a task for it): the
        // drain would be waiting on itself.
        let shouldWarn = capture.jobID != nil && capture.claimDurationCapWarning()
        do {
            let snapshot = try capture.finish()
            emitPendingEvents(for: capture)
            emitTailClippingWarningIfNeeded(snapshot, for: capture)
            let recording = try recording(from: snapshot)
            if let jobID = capture.jobID {
                completedByJob[jobID] = recording
            }
            if shouldWarn {
                emit(.warning(.durationCap), for: capture)
            }
            await cleanup(capture)
        } catch let error as KVoiceError {
            if let jobID = capture.jobID {
                lastFailureByJob[jobID] = error
            } else {
                testFailureByToken[capture.token] = error
            }
            await cleanup(capture)
        } catch {
            let mapped = KVoiceError(code: .audioConversionFailed, retryable: false)
            if let jobID = capture.jobID {
                lastFailureByJob[jobID] = mapped
            } else {
                testFailureByToken[capture.token] = mapped
            }
            await cleanup(capture)
        }
    }

    private func recording(from snapshot: CaptureSnapshot) throws -> AudioRecording {
        guard !snapshot.samples.isEmpty else {
            throw KVoiceError(code: .audioNoSamples, retryable: false)
        }
        guard snapshot.samples.count >= Self.minimumRecordingFrames else {
            throw KVoiceError(code: .audioTooShort, retryable: false)
        }
        guard snapshot.samples.allSatisfy(\.isFinite) else {
            throw KVoiceError(code: .sttInvalidAudio, retryable: false)
        }
        return AudioRecording(
            samples: snapshot.samples,
            sampleRate: Self.transcriptionSampleRate,
            channelCount: Self.transcriptionChannelCount,
            duration: .seconds(Double(snapshot.samples.count) / Self.transcriptionSampleRate),
            peakLevelDBFS: snapshot.peakLevelDBFS,
            clippedFrameCount: snapshot.clippedFrameCount
        )
    }

    private func emitPendingEvents(for capture: ActiveCapture) {
        for event in capture.drainEvents() {
            emit(event, for: capture)
        }
    }

    private func emitTailClippingWarningIfNeeded(
        _ snapshot: CaptureSnapshot,
        for capture: ActiveCapture
    ) {
        guard snapshot.clippedFrameCount > 0,
              !snapshot.clippingWarningEmitted
        else { return }
        emit(
            .warning(.clipping(frameCount: snapshot.clippedFrameCount)),
            for: capture
        )
    }

    private func failCapture(_ capture: ActiveCapture, error: KVoiceError) async {
        guard activeCapture?.token == capture.token else { return }
        capture.markFailure(error)
        // Parked before `cleanup`, whose event drain suspends the actor: a
        // `stop(jobID:)` that enters meanwhile must find this failure, not
        // an empty table.
        if let jobID = capture.jobID {
            lastFailureByJob[jobID] = error
        } else {
            testFailureByToken[capture.token] = error
        }
        await cleanup(capture)
    }

    /// Tears the capture down. Events already queued are delivered before
    /// this returns — so `isRecording` reads false only once the sink has
    /// seen everything — unless `droppingQueuedEvents` (an explicit
    /// cancel). The wait is the one suspension point in teardown; the
    /// active capture is cleared before it, so a `start` that enters
    /// meanwhile is not disturbed by the reset after it.
    private func cleanup(_ capture: ActiveCapture, droppingQueuedEvents: Bool = false) async {
        guard activeCapture?.token == capture.token else { return }
        elapsedTask?.cancel()
        elapsedTask = nil
        engine.removeInputTap()
        engine.stop()
        engine.onEvent = nil
        capture.cancel()
        activeCapture = nil
        tearDownChunkPipeline(for: capture.token)
        if droppingQueuedEvents {
            tearDownEventPipeline(for: capture.token)
            resetIdleState()
        } else {
            await drainEventPipeline(for: capture)
        }
    }

    /// Back to idle — unless a new capture began while a drain suspended
    /// the actor, in which case the new capture's state stands.
    private func resetIdleState() {
        guard activeCapture == nil else { return }
        startedAt = nil
        isRecording = false
    }

    // MARK: - ADR-017 streaming chunks
    //
    // Everything for the streaming input path lives in this section. The tap
    // appends accepted samples to `ActiveCapture.pendingChunkSamples` under
    // the capture lock; the actor drains that run on each tap tick and yields
    // it to a per-capture `AsyncStream`, whose single consumer awaits the sink
    // one chunk at a time. That keeps delivery ordered even though the actor
    // is re-entrant across the sink's suspension. Nothing is delivered after
    // `stop` or `cancel`, and the final `AudioRecording` is unaffected.

    private struct ChunkPipeline {
        let continuation: AsyncStream<AudioSampleChunk>.Continuation
        let consumer: Task<Void, Never>
    }

    private var chunkPipelinesByToken: [UUID: ChunkPipeline] = [:]
    private var pendingChunkSinksByJob: [JobID: @Sendable (AudioSampleChunk) async -> Void] = [:]

    public func setStreamingChunkSink(
        jobID: JobID,
        _ sink: (@Sendable (AudioSampleChunk) async -> Void)?
    ) async {
        if let activeCapture, activeCapture.jobID == jobID {
            tearDownChunkPipeline(for: activeCapture.token)
            if let sink {
                armChunkPipeline(for: activeCapture, sink: sink)
            }
            return
        }
        if let sink {
            pendingChunkSinksByJob[jobID] = sink
        } else {
            pendingChunkSinksByJob.removeValue(forKey: jobID)
        }
    }

    private func armChunkPipeline(
        for capture: ActiveCapture,
        sink: @escaping @Sendable (AudioSampleChunk) async -> Void
    ) {
        let (stream, continuation) = AsyncStream<AudioSampleChunk>.makeStream(
            bufferingPolicy: .unbounded
        )
        let consumer = Task {
            for await chunk in stream {
                await sink(chunk)
            }
        }
        chunkPipelinesByToken[capture.token] = ChunkPipeline(
            continuation: continuation,
            consumer: consumer
        )
        capture.setForwardsChunks(true)
    }

    private func tearDownChunkPipeline(for token: UUID) {
        guard let pipeline = chunkPipelinesByToken.removeValue(forKey: token) else { return }
        activeCapture?.setForwardsChunks(false)
        pipeline.continuation.finish()
        pipeline.consumer.cancel()
    }

    private func forwardPendingChunks(for capture: ActiveCapture) {
        guard let pipeline = chunkPipelinesByToken[capture.token],
              let samples = capture.drainChunkSamples() else { return }
        pipeline.continuation.yield(
            AudioSampleChunk(
                samples: samples,
                sampleRate: Self.transcriptionSampleRate,
                channelCount: Self.transcriptionChannelCount
            )
        )
    }

    // MARK: - Event delivery
    //
    // Events take the same shape as the chunks above: the actor yields them
    // to a per-capture `AsyncStream` and a single consumer awaits the sink
    // one event at a time, so delivery is ordered and — the 2026-09-16
    // fix — nothing is lost to the actor's re-entrancy. Before this, `emit`
    // awaited the sink directly. The tap's task would drain `[.level,
    // .warning(.clipping)]`, deliver `.level`, and suspend in the sink;
    // `stop` then ran on the re-entered actor, saw the clipping flag already
    // claimed, tore the sink down, and the tap task's second `emit` was
    // refused: the clipping warning the buffer raised was dropped whenever
    // `stop` followed the buffer closely (the P2 flake in
    // `testClippingProducesWarningAndImmutableMetadata`). Now `stop`, the
    // duration cap and every failure path finish the stream and await the
    // consumer before they return, so a warning a buffer raised is
    // delivered before the recording is handed back; `cancel` drops what
    // is queued, as before. The sink is deliberately not retained by the
    // `ActiveCapture` (it never receives samples); the pipeline map has the
    // capture's lifetime.
    //
    // The drain is unbounded on purpose: `stop` returns the recording only
    // once the sink has seen every event, so a sink that never returns
    // blocks `stop` — and blocks a `stop` or `cancel` for the same job that
    // arrives while a tap-side teardown (a failure, the cap) is mid-drain,
    // because both settle that teardown first. In production the sink is
    // the job runner's `receiveAudioEvent` on the controller actor, which
    // awaits only cue playback and the output muter and never the capture
    // service, and the app's quit path is bounded above this layer by the
    // shell's `TerminationHandshake`. `cancel` for the job whose teardown
    // is mid-drain does not wait at all (2026-09-16 review): an Escape or a
    // quit has no use for the queued events, so it abandons that drain —
    // the consumer is cancelled and the idle state reset at once — rather
    // than risk waiting on a sink that will not come back. A `cancel` for
    // another job settles the drain like `stop` does, since it is not the
    // one being waited for.

    private struct EventPipeline {
        let continuation: AsyncStream<AudioCaptureEvent>.Continuation
        let consumer: Task<Void, Never>
    }

    private var eventPipelinesByToken: [UUID: EventPipeline] = [:]

    private func armEventPipeline(
        for token: UUID,
        sink: @escaping @Sendable (AudioCaptureEvent) async -> Void
    ) {
        let (stream, continuation) = AsyncStream<AudioCaptureEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let consumer = Task {
            for await event in stream {
                await sink(event)
            }
        }
        eventPipelinesByToken[token] = EventPipeline(
            continuation: continuation,
            consumer: consumer
        )
    }

    /// Queues the event for the capture's consumer; refused once the capture
    /// is no longer the active one, so nothing new is queued after teardown
    /// began.
    private func emit(_ event: AudioCaptureEvent, for capture: ActiveCapture) {
        guard activeCapture?.token == capture.token else { return }
        eventPipelinesByToken[capture.token]?.continuation.yield(event)
    }

    /// The consumer a `cleanup` is currently waiting on, if any, and whose
    /// job it was. A teardown that began on the tap side (a failure, the
    /// cap) parks its result before the drain; `stop` and `cancel` settle
    /// it first so they observe the finished teardown — `isRecording`
    /// false — and not its middle (`cancel` for that same job abandons it
    /// instead, see the section comment).
    private struct TeardownInProgress {
        let jobID: JobID?
        let consumer: Task<Void, Never>
    }

    private var teardownInProgress: TeardownInProgress?

    private func settleTeardown() async {
        while let teardown = teardownInProgress {
            await teardown.consumer.value
            completeTeardown(teardown.consumer)
        }
    }

    /// `cancel` for the job whose teardown is mid-drain: stop waiting for
    /// the sink, drop what it has not seen, and go idle now. The abandoned
    /// consumer ends on its own once its current sink call returns; the
    /// `cleanup` that awaits it finds `completeTeardown` a no-op.
    private func abandonTeardown(for jobID: JobID) {
        guard let teardown = teardownInProgress, teardown.jobID == jobID else { return }
        teardown.consumer.cancel()
        teardownInProgress = nil
        resetIdleState()
    }

    /// The end of a drain. Both the `cleanup` that started it and a
    /// `settleTeardown` waiting on it resume here once the consumer ends,
    /// in either order, so the finalisation is idempotent and done by
    /// whichever runs first.
    private func completeTeardown(_ consumer: Task<Void, Never>) {
        guard teardownInProgress?.consumer == consumer else { return }
        teardownInProgress = nil
        resetIdleState()
    }

    /// Closes the pipeline and waits for everything already queued to reach
    /// the sink. The actor is re-entrant during the wait; `cleanup` sets
    /// `activeCapture = nil` first so nothing can be queued behind it.
    private func drainEventPipeline(for capture: ActiveCapture) async {
        guard let pipeline = eventPipelinesByToken.removeValue(forKey: capture.token) else {
            resetIdleState()
            return
        }
        pipeline.continuation.finish()
        teardownInProgress = TeardownInProgress(jobID: capture.jobID, consumer: pipeline.consumer)
        await pipeline.consumer.value
        completeTeardown(pipeline.consumer)
    }

    /// Closes the pipeline and drops what is queued (an explicit cancel).
    private func tearDownEventPipeline(for token: UUID) {
        guard let pipeline = eventPipelinesByToken.removeValue(forKey: token) else { return }
        pipeline.continuation.finish()
        pipeline.consumer.cancel()
    }

    private static func frames(for duration: Duration) -> Int {
        let components = duration.components
        let seconds = Double(components.seconds)
        let fractional = Double(components.attoseconds) / 1_000_000_000_000_000_000
        let value = (seconds + fractional) * transcriptionSampleRate
        guard value.isFinite, value > 0 else { return 1 }
        return min(Int.max / 2, max(1, Int(ceil(value))))
    }
}

public typealias LiveAudioCaptureService = AVAudioCaptureService
