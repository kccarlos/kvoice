import Foundation

public protocol TranscriptionEngine: Actor {
    var capabilities: TranscriptionCapabilities { get }
    var loadedModelID: ModelID? { get async }

    /// Makes `package` resident. The engine contract (ADR-022 item 8) is
    /// that a successful `load` — including the reloads `setComputeUnits`
    /// and a memory-pressure recovery perform — has already run one silent
    /// warm-up pass over `WarmUpAudio` before returning, so `loadedModelID`
    /// only becomes non-nil once the runtime is at steady-state speed. The
    /// warm-up result is discarded, its failure never fails the load, and
    /// its duration is `runtimeStatistics.lastWarmUpDuration`.
    func load(_ package: InstalledModelPackage) async throws
    func unload() async
    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> TranscriptionResult

    // MARK: Runtime

    /// Restricts the compute devices the resident model may use and, when a
    /// model is loaded, reloads it with the new units. Refused while a job
    /// holds the runtime. Engines without a device choice keep the default
    /// no-op.
    func setComputeUnits(_ units: SpeechComputeUnits) async throws
    /// Timings the engine measured about its runtime (load, last pass).
    var runtimeStatistics: TranscriptionRuntimeStatistics { get async }

    // MARK: Dictionary (ADR-018)

    /// How the resident model takes `TranscriptionRequest.initialPrompt`:
    /// the effective token cap the runtime enforces, `.unsupported` for a
    /// model that takes no prompt, `nil` while nothing is loaded. Engines
    /// without a prompt keep the default.
    var promptTokenLimit: PromptTokenLimit? { get async }
    /// `text` encoded the way the runtime will encode a prompt, counted;
    /// `nil` while nothing is loaded (the UI then shows an estimate).
    func promptTokenCount(of text: String) async -> Int?
}

public extension TranscriptionEngine {
    /// Default: no device choice, nothing to reload.
    func setComputeUnits(_: SpeechComputeUnits) async throws {}

    /// Default: nothing measured.
    var runtimeStatistics: TranscriptionRuntimeStatistics {
        get async { TranscriptionRuntimeStatistics() }
    }

    /// Default: a loaded model takes no prompt.
    var promptTokenLimit: PromptTokenLimit? {
        get async { await loadedModelID == nil ? nil : .unsupported }
    }

    /// Default: no tokenizer to count with.
    func promptTokenCount(of _: String) async -> Int? { nil }
}

/// ADR-017: an engine that can consume audio while the recording continues
/// and publish `.partialText` events before the batch pass. `transcribe` is
/// still the source of the final result; a conforming engine tears its
/// streaming session down before the batch pass runs so the runtime is never
/// used concurrently.
public protocol StreamingTranscriptionEngine: TranscriptionEngine {
    /// Starts a streaming session for `jobID`. `events` receives
    /// `.partialText` while the session runs; nothing is delivered after
    /// `endStreaming` returns. `initialPrompt` is the rendered dictionary
    /// (ADR-018), applied to every pass of the session.
    func beginStreaming(
        jobID: JobID,
        languageHint: String?,
        initialPrompt: String?,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws
    /// Appends converted audio to the session. Chunks for a job with no
    /// session are dropped.
    func appendStreamingAudio(_ chunk: AudioSampleChunk, jobID: JobID) async
    /// Cancels any pass in flight, waits for it to unwind, and discards the
    /// session. Idempotent.
    func endStreaming(jobID: JobID) async
}

public protocol ModelPackageProviding: Actor {
    var state: ModelLifecycleState { get }

    func refresh() async
    func installRecommendedModel() async throws
    func resumeInstallation() async throws
    func cancelInstallation() async
    func selectExternalPackage(at url: URL) async throws
    func forgetExternalPackage() async
    func deleteManagedPackage() async throws
    func verifiedPackage() async throws -> InstalledModelPackage
}

public protocol AudioCaptureService: Actor {
    var isRecording: Bool { get }

    func start(
        jobID: JobID,
        events: @escaping @Sendable (AudioCaptureEvent) async -> Void
    ) async throws
    func stop(jobID: JobID) async throws -> AudioRecording
    func cancel(jobID: JobID) async
    /// Meter-only test (C.2 step 5). `levels` receives privacy-safe
    /// `.level` events while the test runs so a meter can read live; the
    /// result carries aggregates only and no test audio is retained.
    func runMicrophoneTest(
        duration: Duration,
        levels: (@Sendable (AudioCaptureEvent) async -> Void)?
    ) async throws -> MicrophoneTestResult
    /// ADR-017 streaming input path. Installs (or, with `nil`, removes) a
    /// sink that receives the converted 16 kHz mono samples of each captured
    /// buffer for `jobID`, in order, while the recording continues. May be
    /// called before `start(jobID:)`; nothing is delivered after `stop` or
    /// `cancel`. The final `AudioRecording` is unaffected. Services without a
    /// streaming path keep the default no-op.
    func setStreamingChunkSink(
        jobID: JobID,
        _ sink: (@Sendable (AudioSampleChunk) async -> Void)?
    ) async
}

public extension AudioCaptureService {
    /// Convenience for callers that do not render a live meter.
    func runMicrophoneTest(duration: Duration) async throws -> MicrophoneTestResult {
        try await runMicrophoneTest(duration: duration, levels: nil)
    }

    /// Default: no streaming input path.
    func setStreamingChunkSink(
        jobID _: JobID,
        _: (@Sendable (AudioSampleChunk) async -> Void)?
    ) async {}
}

public protocol AIProcessingClient: Actor {
    /// `async` on the requirement so a routing client can hand the call to
    /// the actor that owns the rule (ADR-024); an actor's synchronous
    /// implementation still satisfies it.
    func validateConfiguration(_ settings: AIEndpointSettings) async throws
    func process(
        _ request: AIProcessRequest,
        settings: AIEndpointSettings
    ) async throws -> AIProcessResult
    func testConfiguration(_ settings: AIEndpointSettings) async throws
    func cancel(jobID: JobID) async
}

/// Ephemeral credential input. It is intentionally not `Codable` and must never
/// be placed in `AIEndpointSettings`, `DictationJob`, history, or diagnostics.
public struct AICredentialSnapshot: Sendable, Equatable {
    public let apiKey: String?

    public init(apiKey: String?) {
        self.apiKey = apiKey
    }
}

/// Optional capability for clients that accept an explicitly injected secret.
/// The base client contract remains provider-neutral and non-secret.
public protocol CredentialInjectingAIProcessingClient: AIProcessingClient {
    func process(
        _ request: AIProcessRequest,
        settings: AIEndpointSettings,
        credentials: AICredentialSnapshot?
    ) async throws -> AIProcessResult
    /// The configuration test with the key it needs. A requirement (not an
    /// extension default) so the ADR-024 routing client, which holds the
    /// endpoint client as `any CredentialInjectingAIProcessingClient`,
    /// reaches the credential-taking implementation.
    func testConfiguration(
        _ settings: AIEndpointSettings,
        credentials: AICredentialSnapshot?
    ) async throws
}

public protocol TextInsertionService: Sendable {
    func captureTargetApplication() async -> TargetApplicationSnapshot?
    /// Copies final text without resolving or mutating an Accessibility target.
    /// A successful return means the service completed exactly one clipboard
    /// write; callers choose the user-facing fallback reason.
    func copyToClipboard(_ text: String, jobID: JobID) async throws
    func insert(
        _ text: String,
        into target: TargetApplicationSnapshot,
        jobID: JobID
    ) async throws -> InsertionOutcome
}

public protocol GlobalShortcutService: AnyObject {
    var registrationState: ShortcutRegistrationState { get }

    func register(
        _ shortcut: ShortcutDefinition,
        handler: @escaping @MainActor (ShortcutEvent) -> Void
    ) throws
    func unregister()
    func presentRecorder()
}

public protocol HistoryRepository: Actor {
    func migrateIfNeeded() throws
    func append(_ entry: HistoryEntry) throws
    /// Newest first; `before` is an exclusive `createdAt` cursor.
    func fetchPage(before: Date?, limit: Int) throws -> [HistoryEntry]
    func delete(id: HistoryEntryID) throws
    /// Removes every row in one transaction (FR-HIST-005).
    func deleteAll() throws
    /// Total number of stored rows.
    func count() throws -> Int
    /// On-disk size of the store in bytes; `0` when nothing has been written.
    func storageSizeBytes() throws -> Int64
    /// Case-insensitive substring match over raw and final text, newest
    /// first.  Local only; the query never leaves the process (FR-HIST-009).
    func search(_ query: String, limit: Int) throws -> [HistoryEntry]

    // MARK: History and data

    /// Rows matching `filter`, newest first; `before` is an exclusive
    /// `createdAt` cursor.  Combines the time range, duration bucket, and
    /// text query in one read.
    func entries(matching filter: HistoryFilter, before: Date?, limit: Int) throws -> [HistoryEntry]
    /// Aggregates over the rows matching `filter`, for the dashboard tiles.
    /// Stores compute this with SQL and never load the rows.
    func statistics(matching filter: HistoryFilter) throws -> HistoryStatistics
    /// Removes several rows in one transaction (bulk delete).
    func delete(ids: [HistoryEntryID]) throws
    /// Replaces the row with the same `id` (Retranscribe).  A missing row is
    /// inserted.
    func replace(_ entry: HistoryEntry) throws
    /// Deletes every row created before `cutoff` in one transaction and
    /// reports the audio paths those rows held so the caller can remove the
    /// files.
    func expireEntries(createdBefore cutoff: Date) throws -> HistoryCleanupResult
    /// Clears the audio reference of rows created before `cutoff`, keeping
    /// the transcripts, and returns the released paths.
    func expireAudio(createdBefore cutoff: Date) throws -> [String]
    /// Every audio path currently referenced by a row.
    func audioPaths() throws -> [String]
}

/// In-memory defaults so a fake or preview repository only has to implement
/// the v1 surface.  `HistorySQLiteStore` overrides every one with SQL.
public extension HistoryRepository {
    func entries(matching filter: HistoryFilter, before: Date?, limit: Int) throws -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        var collected: [HistoryEntry] = []
        var cursor = before
        while collected.count < limit {
            let page = try fetchPage(before: cursor, limit: 200)
            guard !page.isEmpty else { break }
            collected.append(contentsOf: page.filter(filter.matches))
            cursor = page.last?.createdAt
        }
        return Array(collected.prefix(limit))
    }

    func statistics(matching filter: HistoryFilter) throws -> HistoryStatistics {
        var statistics = HistoryStatistics()
        var cursor: Date?
        while true {
            let page = try fetchPage(before: cursor, limit: 200)
            guard !page.isEmpty else { break }
            for entry in page where filter.matches(entry) {
                statistics.add(entry)
            }
            cursor = page.last?.createdAt
        }
        return statistics
    }

    func delete(ids: [HistoryEntryID]) throws {
        for id in ids {
            try delete(id: id)
        }
    }

    func replace(_ entry: HistoryEntry) throws {
        try delete(id: entry.id)
        try append(entry)
    }

    func expireEntries(createdBefore cutoff: Date) throws -> HistoryCleanupResult {
        var result = HistoryCleanupResult()
        let expired = try entries(matching: HistoryFilter(), before: cutoff, limit: Int.max)
        for entry in expired {
            try delete(id: entry.id)
            result.deletedEntryCount += 1
            if let path = entry.audioPath {
                result.releasedAudioPaths.append(path)
            }
        }
        return result
    }

    func expireAudio(createdBefore cutoff: Date) throws -> [String] {
        var released: [String] = []
        let expired = try entries(matching: HistoryFilter(), before: cutoff, limit: Int.max)
        for entry in expired where entry.audioPath != nil {
            released.append(entry.audioPath ?? "")
            try replace(entry.removingAudio())
        }
        return released
    }

    func audioPaths() throws -> [String] {
        try entries(matching: HistoryFilter(), before: nil, limit: Int.max).compactMap(\.audioPath)
    }
}

public protocol SettingsRepository: Actor {
    func load() throws -> AppSettings
    func save(_ settings: AppSettings) throws
}

/// ADR-022 slice 5: the machine-local blob beside the settings blob. Never
/// part of a backup; `SettingsBackupEnvelope` has no field for it.
public protocol LocalStateRepository: Actor {
    func load() throws -> LocalState
    func save(_ state: LocalState) throws
}

public protocol SecretsRepository: Actor {
    func load() throws -> SecretSettings
    func save(_ settings: SecretSettings) throws
}

public enum PermissionAuthorization: String, Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case granted
}

public protocol MicrophonePermissionProviding: Sendable {
    func authorization() async -> PermissionAuthorization
    func requestAccess() async -> PermissionAuthorization
}

public protocol AccessibilityPermissionProviding: Sendable {
    func isTrusted(prompt: Bool) async -> Bool
}

public protocol KvoiceClock: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(for duration: Duration) async throws
}

/// The production clock: `ContinuousClock` behind the seam.
public struct SystemKvoiceClock: KvoiceClock {
    private let clock = ContinuousClock()

    public init() {}

    public var now: ContinuousClock.Instant { clock.now }

    public func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

// MARK: AI actions

/// Reads the two opt-in context sources an AI action may include (product
/// decision #2: clipboard text and selected text; never a screen capture).
/// The app shell implements it over the pasteboard and
/// `SelectionReading`; the controller asks only for what the action opted into.
public protocol AIContextProviding: Sendable {
    func clipboardText() async -> String?
    func selectedText() async -> String?
}

/// Reads the focused element's current selection through Accessibility.
/// Provided by the insertion adapter; used by the Selection Action.
public protocol SelectionReading: Sendable {
    /// The selected text of the focused element in the frontmost application,
    /// or `nil` when there is none, it is empty, Accessibility is not
    /// trusted, or the element is secure.
    func readFocusedSelection() async -> String?
}
