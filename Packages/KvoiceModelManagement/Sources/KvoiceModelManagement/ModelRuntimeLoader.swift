import Foundation
import KvoiceDomain

/// The model manager does not know about a concrete STT runtime. This narrow
/// seam lets it enforce unload-before-delete while keeping WhisperKit behind
/// the existing transcription adapter.
public protocol ModelRuntimeLoader: Sendable {
    func load(_ package: InstalledModelPackage) async throws
    func unload() async
    /// 2026-09-29: true when `load(package)` would reach the engine *and*
    /// this Mac has no record of building the model under the current
    /// compute units — the first-time Core ML compile, which the manager
    /// shows as `.optimizing` instead of `.loading`. A loader that does not
    /// know (the default) answers false: "Loading…" is never a false
    /// promise, "first time only" would be.
    func loadWillCompileFirstTime(_ package: InstalledModelPackage) async -> Bool
}

public extension ModelRuntimeLoader {
    func loadWillCompileFirstTime(_ package: InstalledModelPackage) async -> Bool { false }
}
/// Bridges the existing actor-isolated transcription engine to the manager.
public struct TranscriptionEngineModelRuntimeLoader: ModelRuntimeLoader {
    private let engine: any TranscriptionEngine

    public init(engine: any TranscriptionEngine) {
        self.engine = engine
    }

    public func load(_ package: InstalledModelPackage) async throws {
        try await engine.load(package)
    }

    public func unload() async {
        await engine.unload()
    }
}

/// A deliberately failing default. Production composition must inject the
/// resident local Whisper engine; tests can inject a deterministic loader.
public struct UnavailableModelRuntimeLoader: ModelRuntimeLoader {
    public init() {}

    public func load(_ package: InstalledModelPackage) async throws {
        throw ModelManagementError.runtimeLoadFailed("No local model runtime was configured.")
    }

    public func unload() async {}
}
