import Foundation
import KvoiceDomain

/// The model manager does not know about a concrete STT runtime. This narrow
/// seam lets it enforce unload-before-delete while keeping WhisperKit behind
/// the existing transcription adapter.
public protocol ModelRuntimeLoader: Sendable {
    func load(_ package: InstalledModelPackage) async throws
    func unload() async
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
