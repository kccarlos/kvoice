import Foundation
import KvoiceDomain

/// Maps a catalog runtime to the engine that executes it (ADR-019). The app
/// composition supplies one engine per runtime it ships; a runtime with no
/// engine is unavailable in this build, which the catalog already says
/// through `SpeechModelRuntime.isAvailableInThisBuild`.
public protocol SpeechRuntimeFactory: Sendable {
    func engine(for runtime: SpeechModelRuntime) -> (any TranscriptionEngine)?
    /// Every engine the factory can hand out, for operations that must reach
    /// all of them (a compute-unit choice made before anything is resident).
    var allEngines: [any TranscriptionEngine] { get }
}

/// A fixed table of engines, one per runtime.
public struct StaticSpeechRuntimeFactory: SpeechRuntimeFactory {
    private let engines: [SpeechModelRuntime: any TranscriptionEngine]

    public init(engines: [SpeechModelRuntime: any TranscriptionEngine]) {
        self.engines = engines
    }

    public func engine(for runtime: SpeechModelRuntime) -> (any TranscriptionEngine)? {
        engines[runtime]
    }

    public var allEngines: [any TranscriptionEngine] {
        SpeechModelRuntime.allCases.compactMap { engines[$0] }
    }
}

public enum RuntimeSwitchingError: Error, Sendable, Equatable, LocalizedError {
    case unknownModel(ModelID)
    case runtimeUnavailable(SpeechModelRuntime)
    case noModelLoaded
    case streamingUnsupported(ModelID)

    public var errorDescription: String? {
        switch self {
        case let .unknownModel(id):
            return "The model \(id) is not in the bundled catalog."
        case let .runtimeUnavailable(runtime):
            return "This build has no engine for the \(runtime.displayName) runtime."
        case .noModelLoaded:
            return "No speech model is loaded."
        case let .streamingUnsupported(id):
            return "The model \(id) does not support streaming."
        }
    }
}

/// The one resident engine the library and the controller talk to (ADR-017
/// "one resident runtime", extended by ADR-019 to more than one runtime).
///
/// It owns nothing but the routing: `load` looks the package's catalog entry
/// up, asks the factory for that runtime's engine, unloads whatever another
/// engine holds — Core ML graphs from two runtimes must never be resident at
/// once — and forwards. Every other member forwards to the engine holding
/// the model, or answers "nothing loaded". `setComputeUnits` reaches *every*
/// engine because each keeps the choice for its next load, so a persisted
/// setting applies to whichever runtime the default model turns out to use.
public actor RuntimeSwitchingTranscriptionEngine: StreamingTranscriptionEngine, PromptTokenCounting {
    public let capabilities = TranscriptionCapabilities(
        supportsBatch: true,
        supportsStreaming: true,
        supportsCancellation: true,
        supportedSampleRate: 16_000,
        supportedChannelCount: 1
    )

    private let catalog: SpeechModelCatalog
    private let factory: any SpeechRuntimeFactory
    /// The engine that accepted the last `load`, and the runtime it serves.
    private var current: (runtime: SpeechModelRuntime, engine: any TranscriptionEngine)?
    private var computeUnits: SpeechComputeUnits = .default

    public init(catalog: SpeechModelCatalog, factory: any SpeechRuntimeFactory) {
        self.catalog = catalog
        self.factory = factory
    }

    /// The runtime of the resident model, for the shell's Runtime card.
    public var currentRuntime: SpeechModelRuntime? {
        get async {
            guard let current, await current.engine.loadedModelID != nil else { return nil }
            return current.runtime
        }
    }

    /// The compute units the resident (or next) runtime is loaded with.
    public var currentComputeUnits: SpeechComputeUnits {
        computeUnits
    }

    public var loadedModelID: ModelID? {
        get async { await current?.engine.loadedModelID }
    }

    /// The engine a catalog model would be loaded into, for tests and for
    /// the shell's runtime-specific facts. Nil for an unknown model or a
    /// runtime this build lacks.
    public nonisolated func engine(forModelID id: ModelID) -> (any TranscriptionEngine)? {
        guard let entry = catalog.entry(id: id) else { return nil }
        return factory.engine(for: entry.runtime)
    }

    public func load(_ package: InstalledModelPackage) async throws {
        let id = package.manifest.modelID
        guard let entry = catalog.entry(id: id) else {
            throw RuntimeSwitchingError.unknownModel(id)
        }
        guard let engine = factory.engine(for: entry.runtime) else {
            throw RuntimeSwitchingError.runtimeUnavailable(entry.runtime)
        }
        if let current, current.runtime != entry.runtime {
            await current.engine.unload()
        }
        current = (entry.runtime, engine)
        do {
            try await engine.load(package)
        } catch {
            // Accepted tradeoff (KNOWN_ISSUES): the previous runtime's graphs
            // are already released and are not restored here. The library
            // releases the old default before loading the new one anyway, so
            // a restore at this level would load a package the library no
            // longer considers resident. Nothing is left half-pointing at an
            // engine that holds no model.
            current = nil
            throw error
        }
    }

    public func unload() async {
        await current?.engine.unload()
        current = nil
    }

    public func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> TranscriptionResult {
        guard let current else { throw RuntimeSwitchingError.noModelLoaded }
        return try await current.engine.transcribe(request, events: events)
    }

    // MARK: Runtime

    public func setComputeUnits(_ units: SpeechComputeUnits) async throws {
        // The resident engine first: it is the one that reloads and may
        // refuse (busy, or a choice its graphs cannot take — ADR-019: the
        // Unified int8 encoder on the GPU). A refusal leaves everything as
        // it was, so the stored choice, the other engines and the resident
        // placement stay consistent.
        if let current {
            try await current.engine.setComputeUnits(units)
        }
        computeUnits = units
        for engine in factory.allEngines where !isCurrent(engine) {
            try await engine.setComputeUnits(units)
        }
    }

    private func isCurrent(_ engine: any TranscriptionEngine) -> Bool {
        guard let current else { return false }
        return ObjectIdentifier(current.engine) == ObjectIdentifier(engine)
    }

    public var runtimeStatistics: TranscriptionRuntimeStatistics {
        get async { await current?.engine.runtimeStatistics ?? TranscriptionRuntimeStatistics() }
    }

    // MARK: Dictionary (ADR-018)

    public var promptTokenLimit: PromptTokenLimit? {
        get async { await current?.engine.promptTokenLimit }
    }

    public func promptTokenCount(of text: String) async -> Int? {
        await current?.engine.promptTokenCount(of: text)
    }

    /// `PromptTokenCounting` spelling of the engine property.
    public func promptTokenLimit() async -> PromptTokenLimit? {
        await current?.engine.promptTokenLimit
    }

    // MARK: Streaming (ADR-017)

    public func beginStreaming(
        jobID: JobID,
        languageHint: String?,
        initialPrompt: String?,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws {
        guard let current else { throw RuntimeSwitchingError.noModelLoaded }
        guard let streaming = current.engine as? any StreamingTranscriptionEngine else {
            throw RuntimeSwitchingError.streamingUnsupported(await current.engine.loadedModelID ?? "")
        }
        try await streaming.beginStreaming(
            jobID: jobID,
            languageHint: languageHint,
            initialPrompt: initialPrompt,
            events: events
        )
    }

    public func appendStreamingAudio(_ chunk: AudioSampleChunk, jobID: JobID) async {
        guard let streaming = current?.engine as? any StreamingTranscriptionEngine else { return }
        await streaming.appendStreamingAudio(chunk, jobID: jobID)
    }

    public func endStreaming(jobID: JobID) async {
        guard let streaming = current?.engine as? any StreamingTranscriptionEngine else { return }
        await streaming.endStreaming(jobID: jobID)
    }
}
