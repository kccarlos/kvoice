import Foundation
import KvoiceDomain

/// A deterministic clock for unit tests. Sleeping advances no wall clock and returns
/// immediately; production code must inject a real clock when timing matters.
public struct ImmediateClock: KvoiceClock {
    private let continuousClock = ContinuousClock()

    public init() {}

    public var now: ContinuousClock.Instant {
        continuousClock.now
    }

    public func sleep(for _: Duration) async throws {}
}

public enum DomainFixtures {
    public static let jobID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let alternateJobID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    public static func audio(duration: Duration = .seconds(1)) -> AudioRecording {
        AudioRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            samples: ContiguousArray(repeating: 0, count: 16_000),
            duration: duration,
            peakLevelDBFS: -18,
            clippedFrameCount: 0
        )
    }

    public static func settings() -> AppSettings {
        AppSettings(
            ai: AIEndpointSettings(
                mode: .off,
                modelID: "kvoice-fixture",
                promptConfiguration: PromptConfiguration()
            )
        )
    }
}

public actor FakeTranscriptionEngine: TranscriptionEngine {
    public let capabilities = TranscriptionCapabilities(
        supportsBatch: true,
        supportsStreaming: false,
        supportsCancellation: true,
        supportedSampleRate: 16_000,
        supportedChannelCount: 1
    )

    public private(set) var loadedModelID: ModelID?
    public var result: TranscriptionResult?
    public var failure: KVoiceError?
    /// Sample count of each request's audio, in call order, so a test can see
    /// what the controller handed the model (for example a trimmed tail).
    public private(set) var receivedAudioSampleCounts: [Int] = []
    /// `initialPrompt` of each request, in call order (ADR-018).
    public private(set) var receivedInitialPrompts: [String?] = []

    public init(result: TranscriptionResult? = nil, failure: KVoiceError? = nil) {
        self.result = result
        self.failure = failure
    }

    public func load(_ package: InstalledModelPackage) async throws {
        loadedModelID = package.manifest.modelID
    }

    public func unload() async {
        loadedModelID = nil
    }

    public func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> TranscriptionResult {
        receivedAudioSampleCounts.append(request.audio.samples.count)
        receivedInitialPrompts.append(request.initialPrompt)
        await events(.phase(.finalizing))
        try Task.checkCancellation()
        if let failure {
            throw failure
        }
        guard let result else {
            throw KVoiceError(code: .sttEmpty)
        }
        return result
    }
}

public actor FakeAIProcessingClient: CredentialInjectingAIProcessingClient {
    public var result: AIProcessResult?
    public var failure: KVoiceError?
    public private(set) var receivedRequests: [AIProcessRequest] = []

    public init(result: AIProcessResult? = nil, failure: KVoiceError? = nil) {
        self.result = result
        self.failure = failure
    }

    public func validateConfiguration(_: AIEndpointSettings) throws {}

    public func process(
        _ request: AIProcessRequest,
        settings _: AIEndpointSettings
    ) async throws -> AIProcessResult {
        receivedRequests.append(request)
        if let failure {
            throw failure
        }
        guard let result else {
            throw KVoiceError(code: .aiEmptyResponse)
        }
        return result
    }

    public func process(
        _ request: AIProcessRequest,
        settings: AIEndpointSettings,
        credentials _: AICredentialSnapshot?
    ) async throws -> AIProcessResult {
        try await process(request, settings: settings)
    }

    public func testConfiguration(_: AIEndpointSettings) async throws {}
    public func testConfiguration(_: AIEndpointSettings, credentials _: AICredentialSnapshot?) async throws {}
    public func cancel(jobID _: JobID) async {}
}

public actor InMemoryHistoryRepository: HistoryRepository {
    public private(set) var entries: [HistoryEntry] = []

    public init() {}

    public func migrateIfNeeded() throws {}

    public func append(_ entry: HistoryEntry) throws {
        entries.append(entry)
    }

    public func fetchPage(before: Date?, limit: Int) throws -> [HistoryEntry] {
        let sorted = entries.sorted { $0.createdAt > $1.createdAt }
        let filtered = before.map { date in sorted.filter { $0.createdAt < date } } ?? sorted
        return Array(filtered.prefix(max(0, limit)))
    }

    public func delete(id: HistoryEntryID) throws {
        entries.removeAll { $0.id == id }
    }

    public func deleteAll() throws {
        entries.removeAll()
    }

    public func count() throws -> Int {
        entries.count
    }

    public func storageSizeBytes() throws -> Int64 {
        0
    }

    public func search(_ query: String, limit: Int) throws -> [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return try fetchPage(before: nil, limit: limit) }
        let matches = entries
            .filter {
                $0.rawText.localizedCaseInsensitiveContains(needle)
                    || $0.finalText.localizedCaseInsensitiveContains(needle)
            }
            .sorted { $0.createdAt > $1.createdAt }
        return Array(matches.prefix(max(0, limit)))
    }
}

public enum ModelFixtures {
    public static let manifest = ModelManifest(
        schemaVersion: 1,
        modelID: "whisper-large-v3-turbo-coreml-uncompressed",
        family: "whisper-large-v3-turbo",
        format: "whisperkit-coreml",
        workingSpaceBytes: 1_073_741_824,
        source: ModelManifestSource(
            repository: "argmaxinc/whisperkit-coreml",
            revision: String(repeating: "a", count: 40),
            subdirectory: "openai_whisper-large-v3-v20240930_turbo"
        ),
        runtimeCompatibility: ModelRuntimeCompatibility(
            swiftPackage: "argmaxinc/argmax-oss-swift/WhisperKit",
            exactVersion: "1.1.0"
        ),
        tokenizer: ModelTokenizer(relativeRoot: "tokenizer"),
        files: [
            ModelFileDescriptor(
                path: "model.mlmodelc/weights.bin",
                bytes: 1,
                sha256: String(repeating: "b", count: 64),
                role: .otherRequired
            )
        ]
    )

    public static let package = InstalledModelPackage(
        manifest: manifest,
        packageURL: URL(fileURLWithPath: "/tmp/kvoice-model"),
        modelFolderURL: URL(fileURLWithPath: "/tmp/kvoice-model/model"),
        tokenizerFolderURL: URL(fileURLWithPath: "/tmp/kvoice-model/tokenizer"),
        ownership: .managedByKvoice
    )
}

public actor FakeModelPackageProvider: ModelPackageProviding {
    public private(set) var state: ModelLifecycleState = .absent
    public var package: InstalledModelPackage?
    public var failure: KVoiceError?

    public init(package: InstalledModelPackage? = ModelFixtures.package) {
        self.package = package
    }

    public func refresh() async {
        if let package {
            state = .ready(
                InstalledModelSummary(
                    modelID: package.manifest.modelID,
                    revision: package.manifest.source.revision,
                    ownership: package.ownership
                )
            )
        }
    }

    public func installRecommendedModel() async throws {
        try failIfConfigured()
        await refresh()
    }

    public func resumeInstallation() async throws {
        try await installRecommendedModel()
    }

    public func cancelInstallation() async {
        state = .downloadPaused(resumableBytes: nil)
    }

    public func selectExternalPackage(at _: URL) async throws {
        try failIfConfigured()
        state = .validatingExternal
    }

    public func forgetExternalPackage() async {
        package = nil
        state = .absent
    }

    public func deleteManagedPackage() async throws {
        try failIfConfigured()
        package = nil
        state = .absent
    }

    public func verifiedPackage() async throws -> InstalledModelPackage {
        try failIfConfigured()
        guard let package else {
            throw KVoiceError(code: .modelNotInstalled)
        }
        return package
    }

    private func failIfConfigured() throws {
        if let failure {
            throw failure
        }
    }
}

public actor FakeAudioCaptureService: AudioCaptureService {
    public private(set) var isRecording = false
    public var recording: AudioRecording
    public var failure: KVoiceError?
    /// Like a wired microphone, `start` reports one buffer with signal right
    /// away (the controller's start cue and `captureStarted` key off it).
    /// `false` models a route that delivers only zeros until the test calls
    /// `deliverSignal()` — or never does.
    private let deliversSignalOnStart: Bool
    private var events: (@Sendable (AudioCaptureEvent) async -> Void)?

    public init(
        recording: AudioRecording = DomainFixtures.audio(),
        failure: KVoiceError? = nil,
        deliversSignalOnStart: Bool = true
    ) {
        self.recording = recording
        self.failure = failure
        self.deliversSignalOnStart = deliversSignalOnStart
    }

    public func start(
        jobID _: JobID,
        events: @escaping @Sendable (AudioCaptureEvent) async -> Void
    ) async throws {
        try failIfConfigured()
        isRecording = true
        self.events = events
        await events(.elapsed(.zero))
        if deliversSignalOnStart {
            await events(.level(rmsDBFS: -32, peakDBFS: -20))
        } else {
            await events(.level(rmsDBFS: -120, peakDBFS: -120))
        }
    }

    /// One tap buffer with signal for the running capture (peak -20 dBFS),
    /// delivered through the handler `start` received.
    public func deliverSignal() async {
        await events?(.level(rmsDBFS: -32, peakDBFS: -20))
    }

    /// One tap buffer of digital silence for the running capture.
    public func deliverSilence() async {
        await events?(.level(rmsDBFS: -120, peakDBFS: -120))
    }

    /// One elapsed-time tick for the running capture.
    public func deliverElapsed(_ elapsed: Duration) async {
        await events?(.elapsed(elapsed))
    }

    public func stop(jobID _: JobID) async throws -> AudioRecording {
        try failIfConfigured()
        isRecording = false
        events = nil
        return recording
    }

    public func cancel(jobID _: JobID) async {
        isRecording = false
        events = nil
    }

    public func runMicrophoneTest(
        duration: Duration,
        levels _: (@Sendable (AudioCaptureEvent) async -> Void)?
    ) async throws -> MicrophoneTestResult {
        try failIfConfigured()
        return MicrophoneTestResult(
            duration: duration,
            peakLevelDBFS: recording.peakLevelDBFS,
            capturedSamples: recording.samples.count
        )
    }

    private func failIfConfigured() throws {
        if let failure {
            throw failure
        }
    }
}

public actor FakeTextInsertionService: TextInsertionService {
    public var target: TargetApplicationSnapshot?
    public var outcome: InsertionOutcome = .inserted(method: .selectedTextAttribute)
    public var failure: KVoiceError?
    public var clipboardFailure: KVoiceError?
    public private(set) var insertedTexts: [String] = []
    /// The target of each `insert`, in call order (ADR-022 item 6: a retry
    /// goes to the application frontmost *now*).
    public private(set) var insertedTargets: [TargetApplicationSnapshot] = []
    public private(set) var clipboardTexts: [String] = []

    public init(
        target: TargetApplicationSnapshot? = nil,
        clipboardFailure: KVoiceError? = nil
    ) {
        self.target = target
        self.clipboardFailure = clipboardFailure
    }

    public func captureTargetApplication() async -> TargetApplicationSnapshot? {
        target
    }

    /// What the next `captureTargetApplication` returns (nil: nothing frontmost).
    public func setTarget(_ target: TargetApplicationSnapshot?) {
        self.target = target
    }

    /// What the next `insert` throws (nil: succeeds with `outcome`).
    public func setFailure(_ failure: KVoiceError?) {
        self.failure = failure
    }

    /// What the next `insert` reports (a clipboard fallback, say).
    public func setOutcome(_ outcome: InsertionOutcome) {
        self.outcome = outcome
    }

    public func copyToClipboard(_ text: String, jobID _: JobID) async throws {
        if let clipboardFailure {
            throw clipboardFailure
        }
        clipboardTexts.append(text)
    }

    public func insert(
        _ text: String,
        into target: TargetApplicationSnapshot,
        jobID _: JobID
    ) async throws -> InsertionOutcome {
        if let failure {
            throw failure
        }
        insertedTexts.append(text)
        insertedTargets.append(target)
        return outcome
    }
}

public actor FakeSettingsRepository: SettingsRepository {
    public var settings: AppSettings
    public var failure: KVoiceError?

    public init(settings: AppSettings = DomainFixtures.settings(), failure: KVoiceError? = nil) {
        self.settings = settings
        self.failure = failure
    }

    public func load() throws -> AppSettings {
        try failIfConfigured()
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        try failIfConfigured()
        self.settings = settings
    }

    private func failIfConfigured() throws {
        if let failure {
            throw failure
        }
    }
}

public actor FakeSecretsRepository: SecretsRepository {
    public var settings: SecretSettings
    public var failure: KVoiceError?

    public init(settings: SecretSettings = .init(), failure: KVoiceError? = nil) {
        self.settings = settings
        self.failure = failure
    }

    public func load() throws -> SecretSettings {
        try failIfConfigured()
        return settings
    }

    public func save(_ settings: SecretSettings) throws {
        try failIfConfigured()
        self.settings = settings
    }

    private func failIfConfigured() throws {
        if let failure {
            throw failure
        }
    }
}

public final class FakeGlobalShortcutService: GlobalShortcutService {
    private let lock = NSLock()
    private var storedState: ShortcutRegistrationState = .unregistered
    private var handler: (@MainActor (ShortcutEvent) -> Void)?
    public var registrationFailure: KVoiceError?

    public init() {}

    public var registrationState: ShortcutRegistrationState {
        lock.lock()
        defer { lock.unlock() }
        return storedState
    }

    public func register(
        _ shortcut: ShortcutDefinition,
        handler: @escaping @MainActor (ShortcutEvent) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        if let registrationFailure {
            storedState = .failed(registrationFailure.code)
            throw registrationFailure
        }
        storedState = .registered(shortcut)
        self.handler = handler
    }

    public func unregister() {
        lock.lock()
        storedState = .unregistered
        handler = nil
        lock.unlock()
    }

    public func presentRecorder() {}

    public func emit(_ event: ShortcutEvent) async {
        let callback = lock.withLock { handler }
        await MainActor.run {
            callback?(event)
        }
    }
}

/// A clock the test advances by hand. `now` starts at the real clock's
/// instant so `Duration` arithmetic behaves; only `advance(by:)` moves it, so
/// a Hybrid tap-versus-hold or a double-press window is decided by the test
/// rather than by how fast the machine ran.
public final class ManualClock: KvoiceClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: ContinuousClock.Instant = ContinuousClock().now

    public init() {}

    public var now: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func advance(by duration: Duration) {
        lock.lock()
        current = current + duration
        lock.unlock()
    }

    /// Never waits: a sleeping caller resumes at once with the clock unmoved.
    public func sleep(for _: Duration) async throws {}
}

/// A clock whose `sleep` returns at once but moves `now` forward by the
/// requested duration, so a polling loop with a deadline runs its whole
/// schedule in microseconds and a test can assert the elapsed time it
/// reports ("waited 300 ms") exactly. `ManualClock` is the choice when the
/// test, not the sleeper, should decide when time moves.
public final class AdvancingClock: KvoiceClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: ContinuousClock.Instant = ContinuousClock().now
    private var sleepCount = 0

    public init() {}

    public var now: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// How many times `sleep` was called.
    public var sleeps: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepCount
    }

    public func sleep(for duration: Duration) async throws {
        advance(by: duration)
    }

    private func advance(by duration: Duration) {
        lock.lock()
        current = current + duration
        sleepCount += 1
        lock.unlock()
    }
}

/// `ModelCompileRecording` in memory (2026-09-29): seed it with keys a test
/// wants "already compiled", read back what the code under test recorded.
public actor InMemoryModelCompileRecord: ModelCompileRecording {
    public private(set) var compiled: Set<ModelCompileKey>

    public init(compiled: Set<ModelCompileKey> = []) {
        self.compiled = compiled
    }

    public func hasCompiled(_ key: ModelCompileKey) -> Bool {
        compiled.contains(key)
    }

    public func recordCompiled(_ key: ModelCompileKey) {
        compiled.insert(key)
    }
}
