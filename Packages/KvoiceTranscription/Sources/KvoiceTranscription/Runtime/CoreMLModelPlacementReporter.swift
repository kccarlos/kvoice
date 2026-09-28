import CoreML
import Foundation
import KvoiceDomain

/// `ModelPlacementReporting` over Core ML's public compute plan (macOS 14.4+).
///
/// Why a plan and not a measurement: macOS exposes no public Neural Engine
/// utilisation counter, so the only authoritative statement about *where* a
/// graph runs is Core ML's own placement decision. `MLComputePlan` is that
/// decision, computed for a compiled model under a given
/// `MLModelConfiguration`. It is URL-based — Core ML re-plans the compiled
/// artifact rather than introspecting a loaded `MLModel` — so this reporter
/// points it at the same `AudioEncoder.mlmodelc` / `TextDecoder.mlmodelc` the
/// engine loaded, with the same compute units, and the answer is the plan
/// the resident model is running under.
///
/// Core ML types stay inside this file (rule 1); the result is the domain's
/// `ModelPlacementReport`. Anything that cannot be planned reports `nil` for
/// that graph, which the UI shows as "Unavailable for this model" — never a
/// guess.
public struct CoreMLModelPlacementReporter: ModelPlacementReporting {
    /// WhisperKit's compiled-model names inside the package's `model/`
    /// folder (`ModelUtilities.detectModelURL`). Kept here rather than
    /// borrowed from WhisperKit so a rename in the library fails loudly in
    /// `KvoiceTranscriptionTests` instead of silently reporting Unavailable.
    /// Since ADR-019 they are the fallback: the graphs are found by manifest
    /// role first, so a FluidAudio package (`Encoder.mlmodelc`,
    /// `parakeet_unified_encoder_int8.mlmodelc`, …) is planned too.
    static let encoderModelName = "AudioEncoder"
    static let decoderModelName = "TextDecoder"

    public init() {}

    public func placement(
        for package: InstalledModelPackage,
        computeUnits: SpeechComputeUnits
    ) async -> ModelPlacementReport {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = Self.mlComputeUnits(for: computeUnits)
        let encoder = await Self.placement(
            ofCompiledModelNamed: Self.compiledModelName(role: .audioEncoder, in: package.manifest) ?? Self.encoderModelName,
            in: package.modelFolderURL,
            configuration: configuration
        )
        let decoder = await Self.placement(
            ofCompiledModelNamed: Self.compiledModelName(role: .textDecoder, in: package.manifest) ?? Self.decoderModelName,
            in: package.modelFolderURL,
            configuration: configuration
        )
        return ModelPlacementReport(
            modelID: package.manifest.modelID,
            computeUnits: computeUnits,
            encoder: encoder,
            decoder: decoder
        )
    }

    /// Mirrors `WhisperKitRuntimeFactory.computeOptions(for:)` for the two
    /// graphs it reports on; the encoder and decoder always receive the same
    /// units there, so one configuration serves both.
    static func mlComputeUnits(for units: SpeechComputeUnits) -> MLComputeUnits {
        switch units {
        case .neuralEngineAndCPU: return .cpuAndNeuralEngine
        case .gpuAndCPU: return .cpuAndGPU
        case .all: return .all
        case .cpuOnly: return .cpuOnly
        }
    }

    /// The `<name>.mlmodelc` directly under `model/` whose files carry
    /// `role`, without the extension; nil when the manifest names none (an
    /// older manifest, or a role the package does not have).
    static func compiledModelName(role: ModelArtifactRole, in manifest: ModelManifest) -> String? {
        for descriptor in manifest.files where descriptor.role == role {
            let components = descriptor.path.split(separator: "/").map(String.init)
            guard components.count >= 3, components[0] == "model", components[1].hasSuffix(".mlmodelc") else { continue }
            return String(components[1].dropLast(".mlmodelc".count))
        }
        return nil
    }

    static func compiledModelURL(named name: String, in folder: URL) -> URL? {
        let url = folder.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func placement(
        ofCompiledModelNamed name: String,
        in folder: URL,
        configuration: MLModelConfiguration
    ) async -> ModelPlacement? {
        guard let url = compiledModelURL(named: name, in: folder) else { return nil }
        let plan: MLComputePlan
        do {
            plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
        } catch {
            return nil
        }
        var counts: [ComputeDeviceKind: Int] = [:]
        count(plan.modelStructure, in: plan, into: &counts)
        guard !counts.isEmpty else { return nil }
        return ModelPlacement(operationCounts: counts)
    }

    private static func count(
        _ structure: MLModelStructure,
        in plan: MLComputePlan,
        into counts: inout [ComputeDeviceKind: Int]
    ) {
        switch structure {
        case let .program(program):
            for function in program.functions.values {
                count(function.block, in: plan, into: &counts)
            }
        case let .neuralNetwork(network):
            for layer in network.layers {
                if let device = plan.deviceUsage(for: layer).map({ kind(of: $0.preferred) }) {
                    counts[device, default: 0] += 1
                }
            }
        case let .pipeline(pipeline):
            for subModel in pipeline.subModels {
                count(subModel, in: plan, into: &counts)
            }
        case .unsupported:
            break
        @unknown default:
            break
        }
    }

    /// Nested blocks (control flow) are counted too; a `const` has no
    /// device and is skipped by `deviceUsage` returning nil.
    private static func count(
        _ block: MLModelStructure.Program.Block,
        in plan: MLComputePlan,
        into counts: inout [ComputeDeviceKind: Int]
    ) {
        for operation in block.operations {
            if let usage = plan.deviceUsage(for: operation) {
                counts[kind(of: usage.preferred), default: 0] += 1
            }
            for nested in operation.blocks {
                count(nested, in: plan, into: &counts)
            }
        }
    }

    static func kind(of device: MLComputeDevice) -> ComputeDeviceKind {
        switch device {
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .neuralEngine: return .neuralEngine
        @unknown default: return .cpu
        }
    }
}
