import CryptoKit
import Foundation
import KvoiceDomain

public struct ModelManifestGeneratorConfiguration: Sendable, Equatable {
    public let modelID: ModelID
    public let family: String
    public let format: String
    public let workingSpaceBytes: Int64
    public let source: ModelManifestSource
    public let runtimeCompatibility: ModelRuntimeCompatibility
    public let tokenizer: ModelTokenizer
    /// ADR-019: the artifact role per top-level entry under `model/`
    /// (`"Encoder.mlmodelc"`, `"parakeet_vocab.json"`), consulted before the
    /// Whisper file-name defaults. The placement reporter finds the encoder
    /// and decoder graphs by role, so a FluidAudio package must assign
    /// `audioEncoder` and `textDecoder` here.
    public let modelRoles: [String: ModelArtifactRole]

    public init(
        modelID: ModelID = KvoiceManagedModel.modelID,
        family: String = KvoiceManagedModel.family,
        format: String = KvoiceManagedModel.format,
        workingSpaceBytes: Int64 = 1_073_741_824,
        source: ModelManifestSource = ModelManifestSource(
            repository: KvoiceManagedModel.repository,
            revision: KvoiceManagedModel.revision,
            subdirectory: KvoiceManagedModel.subdirectory
        ),
        runtimeCompatibility: ModelRuntimeCompatibility = ModelRuntimeCompatibility(
            swiftPackage: KvoiceManagedModel.runtimePackage,
            exactVersion: KvoiceManagedModel.runtimeVersion
        ),
        tokenizer: ModelTokenizer = ModelTokenizer(relativeRoot: "tokenizer"),
        modelRoles: [String: ModelArtifactRole] = [:]
    ) {
        self.modelID = modelID
        self.family = family
        self.format = format
        self.workingSpaceBytes = workingSpaceBytes
        self.source = source
        self.runtimeCompatibility = runtimeCompatibility
        self.tokenizer = tokenizer
        self.modelRoles = modelRoles
    }

    /// Whether the prepared package must carry a separate `tokenizer/` tree
    /// (Whisper) or keeps everything under `model/` (FluidAudio, ADR-019).
    public var usesSeparateTokenizerDirectory: Bool {
        tokenizer.relativeRoot == "tokenizer"
    }

    /// The configuration for a pinned FluidAudio release: one flat `model/`
    /// folder holding the Core ML bundles and the vocabulary JSON. Returns
    /// nil for a model ID that is not a FluidAudio row of
    /// `PinnedModelReleases`.
    public static func fluidAudio(modelID: String) -> ModelManifestGeneratorConfiguration? {
        guard let release = PinnedModelReleases.release(modelID: modelID),
              release.format == KvoiceFluidAudioModels.format else { return nil }
        let roles: [String: ModelArtifactRole]
        switch release.runtime {
        case .fluidAudioParakeetTDT:
            roles = [
                "Preprocessor.mlmodelc": .melSpectrogram,
                "Encoder.mlmodelc": .audioEncoder,
                "Decoder.mlmodelc": .textDecoder,
                "JointDecisionv3.mlmodelc": .otherRequired,
                "parakeet_vocab.json": .tokenizer,
                "config.json": .configuration
            ]
        case .fluidAudioParakeetUnified:
            roles = [
                // The offline (15 s full-attention) encoder is the batch
                // graph the placement card reports on; the streaming export
                // is a second encoder of the same checkpoint.
                "parakeet_unified_encoder_int8.mlmodelc": .audioEncoder,
                "parakeet_unified_encoder_streaming_70_13_13_int8.mlmodelc": .otherRequired,
                "parakeet_unified_decoder.mlmodelc": .textDecoder,
                "parakeet_unified_joint_decision_single_step.mlmodelc": .otherRequired,
                "vocab.json": .tokenizer,
                "config.json": .configuration,
                "metadata.json": .configuration
            ]
        case .fluidAudioNemotronStreaming:
            roles = [
                // One cache-aware streaming encoder serves batch and
                // streaming. `decoder_joint.mlmodelc` is the fused inner
                // loop FluidAudio prefers; the bare decoder and joint (49 MB)
                // stay in the bundle as the library's unfused fallback
                // path, as published. The `preprocessor.mlmodelc` is
                // not downloaded: 0.15.7 computes the mel front end in Swift
                // and never loads it.
                "encoder.mlmodelc": .audioEncoder,
                "decoder.mlmodelc": .textDecoder,
                "joint.mlmodelc": .otherRequired,
                "decoder_joint.mlmodelc": .otherRequired,
                "tokenizer.json": .tokenizer,
                "metadata.json": .configuration
            ]
        case .fluidAudioSenseVoice:
            roles = [
                // The fp32 CPU front end (kaldi fbank → LFR → CMVN as a
                // Core ML graph; the library never computes it in Swift),
                // the int8 encoder + CTC head that runs on the Neural Engine
                // (the graph the Runtime card plans — the executing graph
                // under the default choice) and the fp32 encoder that runs
                // under every other choice. No decoder graph: the CTC decode
                // is greedy argmax on the host, so the card's decoder row
                // reads Unavailable. The fp16 export is not downloaded.
                "SenseVoicePreprocessor.mlmodelc": .melSpectrogram,
                "SenseVoiceSmall_int8.mlmodelc": .audioEncoder,
                "SenseVoiceSmall_fp32.mlmodelc": .otherRequired,
                "vocab.json": .tokenizer
            ]
        case .fluidAudioParaformer:
            roles = [
                // The same fp32 CPU front end as SenseVoice (digest-identical
                // graph and weights), the int8 SANM encoder (the graph the Runtime card
                // plans), the CIF-alphas head (a 1.5 MB conv + linear +
                // sigmoid whose integrate-and-fire runs on the host) and
                // the int8 parallel decoder — a real decoder graph this
                // time, so the card's decoder row is the executing graph.
                // The fp16 encoder and decoder exports are not downloaded.
                "ParaformerPreprocessor.mlmodelc": .melSpectrogram,
                "ParaformerEncoder_int8.mlmodelc": .audioEncoder,
                "ParaformerCifAlphas.mlmodelc": .otherRequired,
                "ParaformerDecoder_int8.mlmodelc": .textDecoder,
                "vocab.json": .tokenizer
            ]
        case .fluidAudioParakeetEOU:
            roles = [
                // The cache-aware streaming encoder (fp16; the graph the
                // Runtime card plans, and the one that runs in both modes),
                // the 1-layer LSTM decoder (a real decoder graph, so the
                // card's decoder row is the executing graph) and the joint
                // network whose 1,027-way output carries the `<EOU>` token.
                // `parakeet_eou_preprocessor.mlmodelc` is not downloaded:
                // 0.15.7's manager computes the mel front end in Swift and
                // never loads it. The `.mlpackage` sources and the
                // conversion scripts beside them are not part of the package.
                "streaming_encoder.mlmodelc": .audioEncoder,
                "decoder.mlmodelc": .textDecoder,
                "joint_decision.mlmodelc": .otherRequired,
                "vocab.json": .tokenizer
            ]
        case .whisperKitCoreML, .mlxQwen3ASR, .appleSpeech:
            return nil
        }
        return ModelManifestGeneratorConfiguration(
            modelID: release.modelID,
            family: release.family,
            format: release.format,
            // Core ML compiles the graphs on first load into its own cache,
            // not into the package; a flat allowance for the compile scratch.
            workingSpaceBytes: 536_870_912,
            source: ModelManifestSource(
                repository: release.repository,
                revision: release.revision,
                subdirectory: release.subdirectory
            ),
            runtimeCompatibility: ModelRuntimeCompatibility(
                swiftPackage: release.runtimePackage,
                exactVersion: release.runtimeVersion
            ),
            tokenizer: ModelTokenizer(relativeRoot: release.tokenizerRelativeRoot),
            modelRoles: roles
        )
    }
}

/// Generates the committed app-trusted manifest from a prepared package. It
/// never follows symbolic links and does not include the manifest or install
/// sentinel themselves as model artifacts.
public struct ModelManifestGenerator: Sendable {
    public init() {}

    public func generate(
        packageURL: URL,
        configuration: ModelManifestGeneratorConfiguration = .init()
    ) throws -> ModelManifest {
        let root = packageURL.standardizedFileURL
        guard root.isFileURL,
              root.resolvingSymlinksInPath().standardizedFileURL == root,
              fileType(at: root) == .typeDirectory else {
            throw ModelManifestGeneratorError.invalidPackageRoot
        }

        let modelURL = root.appendingPathComponent("model", isDirectory: true)
        let tokenizerURL = root.appendingPathComponent("tokenizer", isDirectory: true)
        guard fileType(at: modelURL) == .typeDirectory else {
            throw ModelManifestGeneratorError.missingRequiredDirectory
        }
        if configuration.usesSeparateTokenizerDirectory {
            guard fileType(at: tokenizerURL) == .typeDirectory else {
                throw ModelManifestGeneratorError.missingRequiredDirectory
            }
        }
        let allowedRoots = configuration.usesSeparateTokenizerDirectory ? ["model", "tokenizer"] : ["model"]

        let artifactURLs = try recursiveArtifacts(in: root, allowedRoots: allowedRoots)
        guard !artifactURLs.isEmpty else {
            throw ModelManifestGeneratorError.noArtifacts
        }
        var seenPaths = Set<String>()
        let descriptors = try artifactURLs.sorted { $0.path < $1.path }.map { url in
            let relative = relativePath(url, under: root)
            let path = try ModelRelativePath.validated(relative)
            guard allowedRoots.contains(where: { path.hasPrefix($0 + "/") }) else {
                throw ModelManifestGeneratorError.unexpectedEntry(path)
            }
            guard seenPaths.insert(path).inserted else {
                throw ModelManifestGeneratorError.unexpectedEntry(path)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes > 0 else {
                throw ModelManifestGeneratorError.emptyArtifact(path)
            }
            return ModelFileDescriptor(
                path: path,
                bytes: bytes,
                sha256: try digest(of: url),
                role: role(for: path, configuration: configuration)
            )
        }
        return ModelManifest(
            schemaVersion: 1,
            modelID: configuration.modelID,
            family: configuration.family,
            format: configuration.format,
            workingSpaceBytes: configuration.workingSpaceBytes,
            source: configuration.source,
            runtimeCompatibility: configuration.runtimeCompatibility,
            tokenizer: configuration.tokenizer,
            files: descriptors
        )
    }

    public func write(
        manifest: ModelManifest,
        to url: URL
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func recursiveArtifacts(in root: URL, allowedRoots: [String]) throws -> [URL] {
        var artifacts: [URL] = []
        func visit(_ directory: URL) throws {
            for url in try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ) {
                guard fileType(at: url) != .typeSymbolicLink else {
                    throw ModelManifestGeneratorError.symlinkForbidden(relativePath(url, under: root))
                }
                switch fileType(at: url) {
                case .typeDirectory:
                    let relative = relativePath(url, under: root)
                    guard allowedRoots.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) else {
                        throw ModelManifestGeneratorError.unexpectedEntry(relative)
                    }
                    try visit(url)
                case .typeRegular:
                    let relative = relativePath(url, under: root)
                    guard allowedRoots.contains(where: { relative.hasPrefix($0 + "/") }) else {
                        throw ModelManifestGeneratorError.unexpectedEntry(relative)
                    }
                    artifacts.append(url)
                default:
                    throw ModelManifestGeneratorError.unexpectedEntry(relativePath(url, under: root))
                }
            }
        }
        try visit(root)
        return artifacts
    }

    private func role(for path: String, configuration: ModelManifestGeneratorConfiguration) -> ModelArtifactRole {
        if path.hasPrefix("tokenizer/") { return .tokenizer }
        let topLevel = path.split(separator: "/").dropFirst().first.map(String.init)
        if let topLevel, let role = configuration.modelRoles[topLevel] { return role }
        switch topLevel {
        case "AudioEncoder.mlmodelc": return .audioEncoder
        case "MelSpectrogram.mlmodelc": return .melSpectrogram
        case "TextDecoder.mlmodelc": return .textDecoder
        case "TextDecoderContextPrefill.mlmodelc": return .decoderPrefill
        case "config.json", "generation_config.json": return .configuration
        default: return .otherRequired
        }
    }

    private func fileType(at url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    private func relativePath(_ url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
    }

    private func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum ModelManifestGeneratorError: Error, Sendable, Equatable, LocalizedError {
    case invalidPackageRoot
    case missingRequiredDirectory
    case noArtifacts
    case symlinkForbidden(String)
    case unexpectedEntry(String)
    case emptyArtifact(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPackageRoot: return "The package root is missing, not a directory, or a symbolic link."
        case .missingRequiredDirectory: return "The package must contain a model/ directory (and tokenizer/ for a Whisper package)."
        case .noArtifacts: return "The package has no model artifacts."
        case let .symlinkForbidden(path): return "Symbolic links are not allowed: " + path + "."
        case let .unexpectedEntry(path): return "The package entry is outside model/ or tokenizer/: " + path + "."
        case let .emptyArtifact(path): return "The package artifact is empty: " + path + "."
        }
    }
}
