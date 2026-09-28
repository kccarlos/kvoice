import Foundation
import KvoiceDomain

/// ADR-017 test doubles for the streaming path. Kept in their own file so the
/// shared `TestDoubles.swift` stays untouched by the streaming work.

/// A transcription engine that also supports streaming. Partials are pushed
/// by the test through `emitPartial`; the batch `transcribe` behaves like
/// `FakeTranscriptionEngine`. Every call is recorded in order so a test can
/// assert that the session ended before the batch pass began.
public actor FakeStreamingTranscriptionEngine: StreamingTranscriptionEngine {
    public enum Call: Sendable, Equatable {
        case beginStreaming(JobID, languageHint: String?)
        case endStreaming(JobID)
        case transcribe(JobID, languageHint: String?)
    }

    /// The `initialPrompt` of each `beginStreaming` / `transcribe` call, in
    /// order (ADR-018: the controller threads the job's dictionary).
    public private(set) var receivedInitialPrompts: [String?] = []

    public let capabilities: TranscriptionCapabilities
    public private(set) var loadedModelID: ModelID?
    public var result: TranscriptionResult?
    public var failure: KVoiceError?
    public var beginFailure: KVoiceError?
    public private(set) var calls: [Call] = []
    public private(set) var appendedSampleCount = 0
    public private(set) var appendedJobIDs: [JobID] = []

    private var liveJobID: JobID?
    private var liveEvents: (@Sendable (TranscriptionEvent) async -> Void)?

    public init(
        result: TranscriptionResult? = nil,
        loadedModelID: ModelID? = "fixture-model",
        supportsStreaming: Bool = true
    ) {
        self.result = result
        self.loadedModelID = loadedModelID
        capabilities = TranscriptionCapabilities(
            supportsBatch: true,
            supportsStreaming: supportsStreaming,
            supportsCancellation: true,
            supportedSampleRate: 16_000,
            supportedChannelCount: 1
        )
    }

    public var isStreaming: Bool { liveJobID != nil }

    public func setBeginFailure(_ failure: KVoiceError?) {
        beginFailure = failure
    }

    public func load(_ package: InstalledModelPackage) async throws {
        loadedModelID = package.manifest.modelID
    }

    public func unload() async {
        loadedModelID = nil
    }

    public func beginStreaming(
        jobID: JobID,
        languageHint: String?,
        initialPrompt: String?,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws {
        calls.append(.beginStreaming(jobID, languageHint: languageHint))
        receivedInitialPrompts.append(initialPrompt)
        if let beginFailure { throw beginFailure }
        liveJobID = jobID
        liveEvents = events
    }

    public func appendStreamingAudio(_ chunk: AudioSampleChunk, jobID: JobID) async {
        guard liveJobID == jobID else { return }
        appendedSampleCount += chunk.samples.count
        appendedJobIDs.append(jobID)
    }

    public func endStreaming(jobID: JobID) async {
        guard liveJobID == jobID else { return }
        calls.append(.endStreaming(jobID))
        liveJobID = nil
        liveEvents = nil
    }

    /// Delivers a partial to the live session's event sink. Returns false
    /// when no session is live (the controller ended or never started one).
    @discardableResult
    public func emitPartial(_ text: String) async -> Bool {
        guard let liveEvents else { return false }
        await liveEvents(.partialText(text))
        return true
    }

    /// Delivers a partial through a sink captured earlier, simulating a pass
    /// that finishes after the controller dropped the session.
    public func captureEventSink() -> (@Sendable (TranscriptionEvent) async -> Void)? {
        liveEvents
    }

    public func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> TranscriptionResult {
        calls.append(.transcribe(request.jobID, languageHint: request.languageHint))
        receivedInitialPrompts.append(request.initialPrompt)
        await events(.phase(.finalizing))
        try Task.checkCancellation()
        if let failure { throw failure }
        guard let result else { throw KVoiceError(code: .sttEmpty) }
        return result
    }
}

/// An audio service with the ADR-017 chunk sink. `pushChunk` delivers a chunk
/// to whatever sink is installed for the active job.
public actor FakeStreamingAudioCaptureService: AudioCaptureService {
    public private(set) var isRecording = false
    public var recording: AudioRecording
    public var failure: KVoiceError?
    public private(set) var activeJobID: JobID?
    private var sinks: [JobID: @Sendable (AudioSampleChunk) async -> Void] = [:]

    public init(recording: AudioRecording = DomainFixtures.audio(), failure: KVoiceError? = nil) {
        self.recording = recording
        self.failure = failure
    }

    public var hasSink: Bool {
        activeJobID.map { sinks[$0] != nil } ?? false
    }

    public func start(
        jobID: JobID,
        events: @escaping @Sendable (AudioCaptureEvent) async -> Void
    ) async throws {
        if let failure { throw failure }
        isRecording = true
        activeJobID = jobID
        await events(.elapsed(.zero))
    }

    public func stop(jobID: JobID) async throws -> AudioRecording {
        if let failure { throw failure }
        isRecording = false
        sinks.removeValue(forKey: jobID)
        activeJobID = nil
        return recording
    }

    public func cancel(jobID: JobID) async {
        isRecording = false
        sinks.removeValue(forKey: jobID)
        activeJobID = nil
    }

    public func runMicrophoneTest(
        duration: Duration,
        levels _: (@Sendable (AudioCaptureEvent) async -> Void)?
    ) async throws -> MicrophoneTestResult {
        MicrophoneTestResult(duration: duration, peakLevelDBFS: recording.peakLevelDBFS, capturedSamples: 0)
    }

    public func setStreamingChunkSink(
        jobID: JobID,
        _ sink: (@Sendable (AudioSampleChunk) async -> Void)?
    ) async {
        if let sink {
            sinks[jobID] = sink
        } else {
            sinks.removeValue(forKey: jobID)
        }
    }

    /// Returns false when no sink is installed for the active job.
    @discardableResult
    public func pushChunk(_ chunk: AudioSampleChunk) async -> Bool {
        guard let activeJobID, let sink = sinks[activeJobID] else { return false }
        await sink(chunk)
        return true
    }
}
