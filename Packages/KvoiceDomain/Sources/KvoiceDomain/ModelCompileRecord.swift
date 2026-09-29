import Foundation

/// 2026-09-29 (owner decision 2): the first load of a Core ML model on a Mac
/// compiles it for the Neural Engine, which for Whisper large-v3-turbo took
/// ~3.5 minutes in the owner's TestFlight log; later loads reuse the OS's
/// compiled cache and take seconds. The UI says "Optimizing for your Mac —
/// first time only" for the first one (`ModelLifecycleState.optimizing`)
/// and nothing of the sort for the others, so it needs to know in advance
/// which kind of load is about to happen.
///
/// **Why a persisted record, not a probe of the OS cache.** Core ML keeps
/// its compiled programs in an OS-private cache whose location and format
/// are undocumented (and differ between the sandboxed and the Developer ID
/// edition's containers); nothing public says "this model is compiled".
/// kvoice instead records, after a load that really reached the engine and
/// succeeded, the exact combination it compiled: the model, its pinned
/// revision (a new revision is new weights) and the compute units (Core ML
/// plans a different graph per choice). The implementation also scopes the
/// record to the macOS build it was written under, because an OS update
/// replaces the Neural Engine compiler and recompiles — "optimizing" after
/// an update is then the truth, not a false alarm.
///
/// What it cannot see: the OS evicting its cache on its own (storage
/// pressure). Then a load kvoice believes cached is slow again and reads
/// "Loading…" rather than "Optimizing…" — the plain loading copy stays
/// honest about taking a while, so the failure mode is mild wording, never
/// a fake promise.
public struct ModelCompileKey: Hashable, Sendable, Codable {
    public let modelID: ModelID
    public let revision: String
    public let computeUnits: SpeechComputeUnits

    public init(modelID: ModelID, revision: String, computeUnits: SpeechComputeUnits) {
        self.modelID = modelID
        self.revision = revision
        self.computeUnits = computeUnits
    }

    /// One stable string per key, for a flat on-disk list.
    public var token: String {
        "\(modelID)@\(revision)#\(computeUnits.rawValue)"
    }
}

/// Remembers which (model, revision, compute units) this Mac has already
/// compiled. Implemented by a small file store in KvoiceModelManagement;
/// tests use an in-memory double.
public protocol ModelCompileRecording: Sendable {
    func hasCompiled(_ key: ModelCompileKey) async -> Bool
    func recordCompiled(_ key: ModelCompileKey) async
}
