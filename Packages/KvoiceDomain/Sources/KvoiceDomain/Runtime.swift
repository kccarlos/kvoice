import Foundation

// MARK: - Compute units

/// Where the speech model's Core ML graphs are allowed to run. The app's own
/// vocabulary for Core ML's `MLComputeUnits`; the transcription adapter maps
/// it, so neither Core ML nor WhisperKit types cross this package (rule 1).
///
/// `neuralEngineAndCPU` is WhisperKit's default (`cpuAndNeuralEngine`) and the
/// fast path for the shipped large-v3-turbo packages. The others exist so a
/// user can *see* the difference — Placement and the performance test read
/// very differently on CPU only — and recover if a machine misbehaves on
/// the Neural Engine.
public enum SpeechComputeUnits: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case neuralEngineAndCPU
    case gpuAndCPU
    case all
    case cpuOnly

    public var id: Self { self }

    public static let `default`: SpeechComputeUnits = .neuralEngineAndCPU

    public var displayName: String {
        switch self {
        case .neuralEngineAndCPU: return "Neural Engine + CPU"
        case .gpuAndCPU: return "GPU + CPU"
        case .all: return "All"
        case .cpuOnly: return "CPU only"
        }
    }

    /// The accelerator the user is asking for, for the verdict copy
    /// ("Running on Neural Engine"). `all` lets Core ML choose and is
    /// judged against the Neural Engine expectation because that is where
    /// Core ML places these graphs when everything is allowed.
    public var expectedDeviceDisplayName: String {
        switch self {
        case .neuralEngineAndCPU, .all: return "Neural Engine"
        case .gpuAndCPU: return "GPU"
        case .cpuOnly: return "CPU"
        }
    }
}

// MARK: - Placement (Core ML compute plan)

/// One kind of compute device Core ML can place an operation on.
public enum ComputeDeviceKind: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case neuralEngine
    case gpu
    case cpu

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .neuralEngine: return "Neural Engine"
        case .gpu: return "GPU"
        case .cpu: return "CPU"
        }
    }
}

/// How Core ML *plans* to distribute one compiled model's operations, from
/// `MLComputePlan` (macOS 14+). This is the authoritative "where will it
/// run" answer, and only that: it is a plan, not a measurement of load, and
/// the UI must never present it as utilisation.
public struct ModelPlacement: Sendable, Equatable {
    /// Operations whose *preferred* device is each kind. Operations with no
    /// determinable usage are excluded from the count.
    public let operationCounts: [ComputeDeviceKind: Int]

    public init(operationCounts: [ComputeDeviceKind: Int]) {
        self.operationCounts = operationCounts
    }

    public var totalOperations: Int {
        operationCounts.values.reduce(0, +)
    }

    /// Share of operations preferring `device`, 0…1; `0` when nothing was
    /// counted.
    public func share(of device: ComputeDeviceKind) -> Double {
        let total = totalOperations
        guard total > 0 else { return 0 }
        return Double(operationCounts[device] ?? 0) / Double(total)
    }

    /// The device holding the most operations, or nil when nothing was
    /// counted.
    public var dominantDevice: ComputeDeviceKind? {
        ComputeDeviceKind.allCases
            .filter { (operationCounts[$0] ?? 0) > 0 }
            .max { (operationCounts[$0] ?? 0) < (operationCounts[$1] ?? 0) }
    }

    /// "97 % Neural Engine · 3 % CPU" — devices with a non-zero share, most
    /// operations first; percentages are rounded so a 0.4 % remainder still
    /// shows as "<1 %" rather than vanishing.
    public var summary: String {
        let total = totalOperations
        guard total > 0 else { return "No operations" }
        let parts = ComputeDeviceKind.allCases
            .compactMap { device -> (ComputeDeviceKind, Int)? in
                guard let count = operationCounts[device], count > 0 else { return nil }
                return (device, count)
            }
            .sorted { $0.1 > $1.1 }
            .map { device, count -> String in
                let percent = Double(count) * 100 / Double(total)
                let rounded = Int(percent.rounded())
                let figure = rounded == 0 ? "<1" : "\(rounded)"
                return "\(figure) % \(device.displayName)"
            }
        return parts.joined(separator: " · ")
    }
}

/// The placement of the two graphs that dominate a Whisper package. A `nil`
/// entry means Core ML could not produce a plan for that model (an old
/// neural-network container, a missing file, or a Core ML error); the UI
/// says "Unavailable for this model" rather than guessing.
public struct ModelPlacementReport: Sendable, Equatable {
    public let modelID: ModelID
    public let computeUnits: SpeechComputeUnits
    public let encoder: ModelPlacement?
    public let decoder: ModelPlacement?

    public init(
        modelID: ModelID,
        computeUnits: SpeechComputeUnits,
        encoder: ModelPlacement?,
        decoder: ModelPlacement?
    ) {
        self.modelID = modelID
        self.computeUnits = computeUnits
        self.encoder = encoder
        self.decoder = decoder
    }
}

/// Produces `ModelPlacementReport`s. The transcription adapter implements it
/// with `MLComputePlan` over the package's compiled encoder and decoder,
/// using the same compute-unit configuration the engine loaded them with.
public protocol ModelPlacementReporting: Sendable {
    func placement(
        for package: InstalledModelPackage,
        computeUnits: SpeechComputeUnits
    ) async -> ModelPlacementReport
}

// MARK: - Runtime statistics (engine-measured)

/// Scalars the engine measured about its resident runtime. Timings only —
/// no transcript, no audio (rule 3) — so this may be logged and shown as is.
public struct TranscriptionRuntimeStatistics: Sendable, Equatable {
    /// Wall time of the last successful runtime load (Core ML compile and
    /// weight load, plus the tokenizer). `nil` until a model has loaded.
    public var lastLoadDuration: Duration?
    /// Real-time factor of the last completed batch pass — inference time
    /// divided by audio duration, so below 1 is faster than real time. The
    /// runtime's own figure when it reports one, else the engine's wall
    /// measurement.
    public var lastRealTimeFactor: Double?
    /// Wall time of the last completed batch pass.
    public var lastInferenceDuration: Duration?
    /// ADR-022 item 8: wall time of the silent warm-up pass that followed
    /// the last load (Core ML's first-inference kernel compilation lands
    /// here instead of on the user's first sentence). `nil` until a load has
    /// warmed up, or when the warm-up failed (the load still succeeded). It
    /// is never folded into `lastRealTimeFactor` or `lastInferenceDuration`.
    public var lastWarmUpDuration: Duration?

    public init(
        lastLoadDuration: Duration? = nil,
        lastRealTimeFactor: Double? = nil,
        lastInferenceDuration: Duration? = nil,
        lastWarmUpDuration: Duration? = nil
    ) {
        self.lastLoadDuration = lastLoadDuration
        self.lastRealTimeFactor = lastRealTimeFactor
        self.lastInferenceDuration = lastInferenceDuration
        self.lastWarmUpDuration = lastWarmUpDuration
    }
}

// MARK: - Warm-up audio (ADR-022 item 8)

/// The audio every engine feeds its runtime once after a load so Core ML
/// compiles and specialises the kernels before the user's first sentence.
/// Measured on an M4 test Mac (2026-09-14): the first pass after a load ran
/// ~2× slower for Parakeet (RTF 0.155 → 0.082 steady) and far slower for
/// Whisper (Neural Engine compilation on first inference); without a
/// warm-up that cost lands on the first dictation after launch and again
/// after every memory-pressure unload/reload and compute-unit change.
///
/// The clip is near-silent rather than all zeros so the same graph paths a
/// spoken clip takes are exercised (a mel over pure zeros is degenerate),
/// at −60 dBFS peak so nothing could be mistaken for speech. It is
/// deterministic so two warm-ups are identical. The result is discarded by
/// the engine — never inserted, never in history, never logged as text —
/// and the pass goes straight to the runtime, so `SpeechGate` and the
/// engine's own statistics are not involved.
public enum WarmUpAudio {
    public static let sampleRate: Double = 16_000
    public static let duration: Duration = .seconds(1)
    /// −60 dBFS.
    public static let peakAmplitude: Float = 0.001

    /// One second of deterministic low-level noise at 16 kHz mono.
    public static func samples() -> [Float] {
        let count = Int(sampleRate)
        var samples = [Float](repeating: 0, count: count)
        // A tiny linear congruential generator: no Foundation randomness, so
        // the clip is the same on every machine and every load.
        var state: UInt32 = 0x9E37_79B9
        for index in 0..<count {
            state = state &* 1_664_525 &+ 1_013_904_223
            let unit = Float(state >> 8) / Float(1 << 24) // 0 ..< 1
            samples[index] = (unit * 2 - 1) * peakAmplitude
        }
        return samples
    }
}

// MARK: - Process telemetry

/// Live counters about *this process* and the machine, read by the Runtime
/// card while a recording, a file transcription, or the performance test
/// runs. Every value is a scalar; a `nil` means the counter is not
/// available on this system and the UI hides that line rather than
/// inventing a number.
///
/// There is deliberately no Neural Engine reading: macOS exposes no public
/// ANE utilisation counter, and a graph made from a proxy would be a lie.
/// Placement and the timed performance test are the ANE evidence.
public protocol RuntimeTelemetryProviding: Sendable {
    /// The process's physical footprint in bytes (what Activity Monitor
    /// calls Memory), or nil when the kernel refuses the query.
    func memoryFootprintBytes() -> UInt64?
    /// CPU time this process consumed since the previous call, as a share of
    /// all cores (0…1). `nil` on the first call, which only primes the
    /// baseline, and when the query fails.
    func cpuUtilisation() -> Double?
    /// System-wide GPU busy share (0…1) from the accelerator driver, or nil
    /// when no readable counter exists on this system.
    func gpuUtilisation() -> Double?
}
