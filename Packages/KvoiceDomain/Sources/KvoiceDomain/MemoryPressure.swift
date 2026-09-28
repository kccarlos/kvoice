import Foundation

/// System-wide memory pressure, from the kernel's compressor/jetsam signal —
/// never this process's own footprint (see `MemoryPressureObserving`).
/// Ordered so callers can compare severity (`.warning < .critical`).
public enum MemoryPressureLevel: String, Codable, Sendable, Equatable, CaseIterable, Comparable {
    case normal
    case warning
    case critical

    private var ordinal: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.ordinal < rhs.ordinal }
}

/// Observes *system-wide* memory pressure. Implemented once, in the
/// transcription adapter, over `DispatchSource.makeMemoryPressureSource`
/// (rule 1: the vendor/system type stays in its one adapter file).
///
/// Why system-wide and not this process's footprint: kvoice's own resident
/// model is 0.5–1.6 GB, small next to a Mac's total memory, and the app
/// already reads its own footprint (`RuntimeTelemetryProviding`) for the
/// Runtime card. What predicts an actual slowdown or a jetsam kill is
/// whether *the system* — every process, the compressor, the other apps the
/// user has open — is under pressure, which is exactly the kernel signal
/// `DispatchSource.makeMemoryPressureSource` reports. A resident-footprint
/// threshold would warn a user whose Mac has 128 GB and warn never on a
/// machine with 8 GB where the model is the straw that broke the camel's
/// back but wasn't itself unusually large.
public protocol MemoryPressureObserving: Sendable {
    /// The level as of the last observed transition. `.normal` before the
    /// first callback (the common case) or if the platform never reports
    /// pressure during this run.
    var currentLevel: MemoryPressureLevel { get async }
    /// Every level change, de-duplicated (no two consecutive equal values),
    /// starting from the next transition after the call. A caller that wants
    /// the value as of now reads `currentLevel` first.
    func changes() -> AsyncStream<MemoryPressureLevel>
}

/// A coarse, unbounded-cardinality label for a memory footprint, for the
/// scalar-only diagnostics rule (the scalars-only rule in AGENTS.md): never the raw byte count,
/// which — chained across events — could approach fingerprinting the
/// machine's installed RAM or this launch's exact working set.
public enum MemoryFootprintBucket {
    private static let lt256mb = DiagnosticToken(rawValue: "lt256mb")!
    private static let mb256to512 = DiagnosticToken(rawValue: "256to512mb")!
    private static let mb512to1024 = DiagnosticToken(rawValue: "512mbto1gb")!
    private static let gb1to1_5 = DiagnosticToken(rawValue: "1to1.5gb")!
    private static let gb1_5to2 = DiagnosticToken(rawValue: "1.5to2gb")!
    private static let gte2gb = DiagnosticToken(rawValue: "gte2gb")!

    /// Bands chosen around the shipped models' 0.5–1.6 GB resident range, so
    /// "the model is/isn't resident" and roughly which model is visible
    /// without a figure precise enough to be a fingerprint.
    public static func token(forBytes bytes: UInt64) -> DiagnosticToken {
        let megabytes = Double(bytes) / 1_048_576
        switch megabytes {
        case ..<256: return lt256mb
        case 256..<512: return mb256to512
        case 512..<1024: return mb512to1024
        case 1024..<1536: return gb1to1_5
        case 1536..<2048: return gb1_5to2
        default: return gte2gb
        }
    }
}
