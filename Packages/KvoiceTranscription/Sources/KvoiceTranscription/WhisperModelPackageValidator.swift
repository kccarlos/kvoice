import CryptoKit
import Foundation
import ArgmaxOSS
import KvoiceDomain

/// A release manifest and digest supplied by the app from its trusted release
/// evidence. It is intentionally separate from the manifest read from an
/// installed package: package metadata is evidence to verify, not an anchor.
public struct WhisperModelReleaseTrustAnchor: Sendable, Equatable {
    public let manifest: ModelManifest
    public let manifestSHA256: String

    /// Creates an anchor from app-owned release-resource bytes and its
    /// independently recorded release digest.
    public init(manifestData: Data, manifestSHA256: String) throws {
        self.manifest = try JSONDecoder().decode(ModelManifest.self, from: manifestData)
        self.manifestSHA256 = manifestSHA256
    }

    public static func digest(for manifest: ModelManifest) throws -> String {
        SHA256.hash(data: try canonicalData(for: manifest))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The canonical bytes a manifest hashes to: sorted keys, compact.
    public static func canonicalData(for manifest: ModelManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }
}

/// The local-only tokenizer construction seam. Production uses the
/// WhisperKit/Argmax local-folder API directly; tests can inject a
/// deterministic implementation without constructing Core ML or touching a
/// network boundary.
public protocol WhisperLocalTokenizerPreflight: Sendable {
    func validate(tokenizerFolderURL: URL) async throws
}

public struct WhisperKitLocalTokenizerPreflight: WhisperLocalTokenizerPreflight {
    public init() {}

    public func validate(tokenizerFolderURL: URL) async throws {
        do {
            let nestedTokenizerFolder = tokenizerFolderURL
                .standardizedFileURL
                .appendingPathComponent("models/openai/whisper-large-v3", isDirectory: true)
            let fileManager = FileManager.default
            let localFolder = fileManager.fileExists(
                atPath: nestedTokenizerFolder.appendingPathComponent("tokenizer.json").path
            ) ? nestedTokenizerFolder : tokenizerFolderURL.standardizedFileURL
            // This overload is local-only. Do not replace it with
            // ModelUtilities.loadTokenizer, which catches local errors and
            // then falls back to AutoTokenizer.from(pretrained:).
            _ = try await AutoTokenizerWrapper.from(
                modelFolder: localFolder,
                strict: true
            )
        } catch {
            throw WhisperPackageValidationError.tokenizerSemanticsInvalid
        }
    }
}

/// Fail-closed validation for the package handed to WhisperKit.
///
/// The model manager owns acquisition, but the runtime boundary repeats the
/// security/integrity checks immediately before construction. This prevents a
/// stale, moved, symlinked, or hand-built package from reaching WhisperKit,
/// where a missing tokenizer could otherwise trigger a Hub lookup.
public struct WhisperModelPackageValidator: Sendable {
    private let trustedReleases: [WhisperModelReleaseTrustAnchor]

    public init(trustedReleases: [WhisperModelReleaseTrustAnchor]) {
        self.trustedReleases = trustedReleases
    }

    public func validate(_ package: InstalledModelPackage) throws {
        let fileManager = FileManager.default
        guard package.manifest.schemaVersion == 1,
              package.manifest.workingSpaceBytes > 0 else {
            throw WhisperPackageValidationError.manifestContractInvalid
        }
        let packageRoot = try Self.requireDirectory(
            package.packageURL.standardizedFileURL,
            error: .packageDirectoryMissing
        )
        guard packageRoot.resolvingSymlinksInPath().standardizedFileURL == packageRoot else {
            throw WhisperPackageValidationError.symlinkForbidden(packageRoot.lastPathComponent)
        }
        let trustedRelease = try Self.trustedRelease(
            for: package.manifest,
            in: trustedReleases
        )
        try Self.validateTrustedManifest(
            trustedRelease,
            packageRoot: packageRoot,
            fileManager: fileManager
        )
        let definition = try Self.knownDefinition(for: package.manifest)
        try Self.requireDirectDirectory(
            package.modelFolderURL,
            named: "model",
            under: packageRoot,
            fileManager: fileManager
        )
        try Self.requireDirectDirectory(
            package.tokenizerFolderURL,
            named: "tokenizer",
            under: packageRoot,
            fileManager: fileManager
        )
        let entries = try Self.recursiveEntries(in: packageRoot, fileManager: fileManager)
        try Self.rejectSymlinks(in: packageRoot, entries: entries, fileManager: fileManager)

        guard package.manifest.tokenizer.relativeRoot == "tokenizer",
              package.manifest.tokenizer.offlineRequired else {
            throw WhisperPackageValidationError.tokenizerContractInvalid
        }
        guard !package.manifest.files.isEmpty else {
            throw WhisperPackageValidationError.emptyAllowlist
        }

        var allowlistedPaths = Set<String>()
        var caseFoldedPaths = Set<String>()
        for descriptor in package.manifest.files {
            let path = try Self.validatedRelativePath(descriptor.path)
            guard Self.isAllowedArtifactPath(path, role: descriptor.role) else {
                throw WhisperPackageValidationError.pathNotAllowlisted(path)
            }
            guard allowlistedPaths.insert(path).inserted else {
                throw WhisperPackageValidationError.duplicatePath(path)
            }
            let caseFolded = path.precomposedStringWithCanonicalMapping.lowercased()
            guard caseFoldedPaths.insert(caseFolded).inserted else {
                throw WhisperPackageValidationError.caseFoldCollision(path)
            }
            guard descriptor.bytes > 0,
                  descriptor.sha256.count == 64,
                  descriptor.sha256.unicodeScalars.allSatisfy(Self.isLowercaseHex) else {
                throw WhisperPackageValidationError.descriptorMetadataInvalid(path)
            }

            let fileURL = packageRoot.appendingPathComponent(path, isDirectory: false)
            try Self.requireRegularFile(fileURL, relativePath: path, fileManager: fileManager)
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard let bytes = attributes[.size] as? NSNumber,
                  bytes.int64Value == descriptor.bytes else {
                throw WhisperPackageValidationError.byteCountMismatch(path)
            }
            guard try Self.sha256(of: fileURL) == descriptor.sha256 else {
                throw WhisperPackageValidationError.hashMismatch(path)
            }
            if path.hasSuffix(".json") {
                try Self.validateJSON(at: fileURL, relativePath: path)
            }
        }

        for requiredRoot in definition.requiredArtifactRoots {
            guard allowlistedPaths.contains(where: {
                $0 == requiredRoot || $0.hasPrefix(requiredRoot + "/")
            }) else {
                throw WhisperPackageValidationError.requiredArtifactMissing(requiredRoot)
            }
        }
        for tokenizerFile in ["tokenizer.json", "tokenizer_config.json"] {
            guard allowlistedPaths.contains("tokenizer/\(tokenizerFile)") ||
                    allowlistedPaths.contains("tokenizer/models/openai/whisper-large-v3/\(tokenizerFile)") else {
                throw WhisperPackageValidationError.requiredArtifactMissing("tokenizer/\(tokenizerFile)")
            }
        }

        try Self.rejectUnallowlistedFiles(
            in: packageRoot,
            allowlistedPaths: allowlistedPaths,
            entries: entries,
            fileManager: fileManager
        )
    }

    private struct KnownDefinition: Sendable {
        let modelID: String
        let revision: String
        let subdirectory: String
        let requiredArtifactRoots: Set<String>
    }

    private static func trustedRelease(
        for manifest: ModelManifest,
        in trustedReleases: [WhisperModelReleaseTrustAnchor]
    ) throws -> WhisperModelReleaseTrustAnchor {
        guard !trustedReleases.isEmpty else {
            throw WhisperPackageValidationError.noTrustedRelease
        }
        guard let release = trustedReleases.first(where: { $0.manifest == manifest }) else {
            throw WhisperPackageValidationError.untrustedReleaseManifest
        }
        guard release.manifestSHA256.count == 64,
              release.manifestSHA256.unicodeScalars.allSatisfy(Self.isLowercaseHex) else {
            throw WhisperPackageValidationError.trustedReleaseDigestInvalid
        }
        guard try WhisperModelReleaseTrustAnchor.digest(for: release.manifest) == release.manifestSHA256 else {
            throw WhisperPackageValidationError.trustedReleaseDigestMismatch
        }
        return release
    }

    private static func validateTrustedManifest(
        _ release: WhisperModelReleaseTrustAnchor,
        packageRoot: URL,
        fileManager: FileManager
    ) throws {
        let manifestURL = packageRoot.appendingPathComponent("ModelManifest.json", isDirectory: false)
        guard (try? fileType(at: manifestURL, fileManager: fileManager)) == .typeRegular else {
            throw WhisperPackageValidationError.trustedReleaseManifestMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw WhisperPackageValidationError.trustedReleaseManifestInvalid
        }
        do {
            let manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
            let canonicalData = try WhisperModelReleaseTrustAnchor.canonicalData(for: release.manifest)
            let manifestDigest = try WhisperModelReleaseTrustAnchor.digest(for: manifest)
            guard manifest == release.manifest,
                  data == canonicalData,
                  manifestDigest == release.manifestSHA256 else {
                throw WhisperPackageValidationError.untrustedReleaseManifest
            }
        } catch let error as WhisperPackageValidationError {
            throw error
        } catch {
            throw WhisperPackageValidationError.trustedReleaseManifestInvalid
        }
    }

    private static let knownDefinitions: [KnownDefinition] = [
        KnownDefinition(
            modelID: "whisper-large-v3-turbo-coreml-uncompressed",
            revision: "04e5c42d80a522518023727e8c7e68d4bb391b28",
            subdirectory: "openai_whisper-large-v3-v20240930_turbo",
            requiredArtifactRoots: [
                "model/AudioEncoder.mlmodelc",
                "model/MelSpectrogram.mlmodelc",
                "model/TextDecoder.mlmodelc",
                "model/TextDecoderContextPrefill.mlmodelc",
                "model/config.json",
                "model/generation_config.json"
            ]
        ),
        KnownDefinition(
            modelID: "whisper-large-v3-turbo-coreml-626mb",
            revision: "7235bbd38ae9ab5476bee007313c0bb327387b84",
            subdirectory: "openai_whisper-large-v3-v20240930_626MB",
            requiredArtifactRoots: [
                "model/AudioEncoder.mlmodelc",
                "model/MelSpectrogram.mlmodelc",
                "model/TextDecoder.mlmodelc",
                "model/TextDecoderContextPrefill.mlmodelc",
                "model/config.json",
                "model/generation_config.json"
            ]
        ),
        // ADR-017: the quantized turbo package published beside the
        // uncompressed one at the same pinned revision ("Standard").
        KnownDefinition(
            modelID: "whisper-large-v3-turbo-coreml-632mb",
            revision: "04e5c42d80a522518023727e8c7e68d4bb391b28",
            subdirectory: "openai_whisper-large-v3-v20240930_turbo_632MB",
            requiredArtifactRoots: [
                "model/AudioEncoder.mlmodelc",
                "model/MelSpectrogram.mlmodelc",
                "model/TextDecoder.mlmodelc",
                "model/TextDecoderContextPrefill.mlmodelc",
                "model/config.json",
                "model/generation_config.json"
            ]
        )
    ]

    /// Whether a (model ID, revision, subdirectory) triple is one of the
    /// releases this build's validator knows. The manager and the download
    /// URL provider consult it so a catalog cannot name a package the runtime
    /// validator would refuse to load.
    public static func isKnownRelease(modelID: String, revision: String, subdirectory: String) -> Bool {
        knownDefinitions.contains {
            $0.modelID == modelID && $0.revision == revision && $0.subdirectory == subdirectory
        }
    }

    private static let allowedModelRoots: Set<String> = [
        "AudioEncoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
        "TextDecoder.mlmodelc",
        "TextDecoderContextPrefill.mlmodelc",
        "config.json",
        "generation_config.json"
    ]

    private static let allowedTokenizerFiles: Set<String> = [
        "tokenizer.json",
        "vocab.json",
        "merges.txt",
        "special_tokens_map.json",
        "tokenizer_config.json",
        "added_tokens.json",
        "normalizer.json"
    ]

    private static func knownDefinition(for manifest: ModelManifest) throws -> KnownDefinition {
        guard manifest.source.repository == "argmaxinc/whisperkit-coreml",
              manifest.family == "whisper-large-v3-turbo",
              manifest.format == "whisperkit-coreml",
              manifest.runtimeCompatibility.swiftPackage == "argmaxinc/argmax-oss-swift/WhisperKit",
              manifest.runtimeCompatibility.exactVersion == "1.1.0" else {
            throw WhisperPackageValidationError.runtimeContractInvalid
        }
        guard let definition = knownDefinitions.first(where: { $0.modelID == manifest.modelID }) else {
            throw WhisperPackageValidationError.unknownModelID(manifest.modelID)
        }
        guard manifest.source.revision == definition.revision,
              manifest.source.subdirectory == definition.subdirectory else {
            throw WhisperPackageValidationError.revisionMismatch
        }
        return definition
    }

    private static func validatedRelativePath(_ path: String) throws -> String {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\") else {
            throw WhisperPackageValidationError.pathEscapesPackage(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WhisperPackageValidationError.pathEscapesPackage(path)
        }
        let normalized = components.joined(separator: "/")
        guard normalized == path else {
            throw WhisperPackageValidationError.pathEscapesPackage(path)
        }
        return normalized.precomposedStringWithCanonicalMapping
    }

    private static func isAllowedArtifactPath(_ path: String, role: ModelArtifactRole) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return false }
        switch components[0] {
        case "model":
            guard let root = allowedModelRoots.first(where: { $0 == components[1] }),
                  Self.expectedRole(forModelRoot: root) == role else { return false }
            if root.hasSuffix(".json") {
                return components.count == 2
            }
            return components.count >= 3
        case "tokenizer":
            guard role == .tokenizer else { return false }
            if components.count == 2 {
                return allowedTokenizerFiles.contains(components[1])
            }
            return components.count == 5 &&
                components[1] == "models" &&
                components[2] == "openai" &&
                components[3] == "whisper-large-v3" &&
                allowedTokenizerFiles.contains(components[4])
        default:
            return false
        }
    }

    private static func expectedRole(forModelRoot root: String) -> ModelArtifactRole {
        switch root {
        case "AudioEncoder.mlmodelc": return .audioEncoder
        case "MelSpectrogram.mlmodelc": return .melSpectrogram
        case "TextDecoder.mlmodelc": return .textDecoder
        case "TextDecoderContextPrefill.mlmodelc": return .decoderPrefill
        case "config.json", "generation_config.json": return .configuration
        default: return .otherRequired
        }
    }

    private static func requireDirectDirectory(
        _ url: URL,
        named name: String,
        under packageRoot: URL,
        fileManager: FileManager
    ) throws {
        let standardized = url.standardizedFileURL
        let expected = packageRoot.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard standardized == expected else {
            throw WhisperPackageValidationError.pathEscapesPackage(name)
        }
        _ = try requireDirectory(standardized, error: name == "model" ? .modelDirectoryMissing : .tokenizerDirectoryMissing)
        guard try fileType(at: standardized, fileManager: fileManager) == .typeDirectory else {
            throw name == "model"
                ? WhisperPackageValidationError.modelDirectoryMissing
                : WhisperPackageValidationError.tokenizerDirectoryMissing
        }
    }

    private static func requireDirectory(_ url: URL, error: WhisperPackageValidationError) throws -> URL {
        guard url.isFileURL,
              let type = try? fileType(at: url, fileManager: .default),
              type == .typeDirectory else {
            throw error
        }
        return url
    }

    private static func requireRegularFile(
        _ url: URL,
        relativePath: String,
        fileManager: FileManager
    ) throws {
        guard let type = try? fileType(at: url, fileManager: fileManager),
              type == .typeRegular else {
            throw WhisperPackageValidationError.requiredFileMissing(relativePath)
        }
    }

    private static func fileType(at url: URL, fileManager: FileManager) throws -> FileAttributeType {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let type = attributes[.type] as? FileAttributeType else {
            throw WhisperPackageValidationError.fileTypeUnavailable(url.lastPathComponent)
        }
        return type
    }

    private static func recursiveEntries(in root: URL, fileManager: FileManager) throws -> [URL] {
        var entries: [URL] = []

        func visit(_ directory: URL) throws {
            for entry in try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ) {
                entries.append(entry)
                if try fileType(at: entry, fileManager: fileManager) == .typeDirectory {
                    try visit(entry)
                }
            }
        }

        try visit(root)
        return entries
    }

    private static func rejectSymlinks(
        in root: URL,
        entries: [URL],
        fileManager: FileManager
    ) throws {
        guard try fileType(at: root, fileManager: fileManager) != .typeSymbolicLink else {
            throw WhisperPackageValidationError.symlinkForbidden(root.lastPathComponent)
        }
        for url in entries {
            if try fileType(at: url, fileManager: fileManager) == .typeSymbolicLink {
                throw WhisperPackageValidationError.symlinkForbidden(url.lastPathComponent)
            }
        }
    }

    private static func rejectUnallowlistedFiles(
        in root: URL,
        allowlistedPaths: Set<String>,
        entries: [URL],
        fileManager: FileManager
    ) throws {
        var allowedDirectoryPrefixes = Set(["model", "tokenizer"])
        for path in allowlistedPaths {
            let components = path.split(separator: "/").map(String.init)
            for index in 1..<components.count {
                allowedDirectoryPrefixes.insert(components[..<index].joined(separator: "/"))
            }
        }

        for url in entries {
            let relative = try relativePath(of: url, under: root)
            let type = try fileType(at: url, fileManager: fileManager)
            switch type {
            case .typeRegular:
                guard relative == "ModelManifest.json" ||
                        relative == ".installed.json" ||
                        allowlistedPaths.contains(relative) else {
                    throw WhisperPackageValidationError.unexpectedFile(relative)
                }
            case .typeDirectory:
                guard allowedDirectoryPrefixes.contains(relative) else {
                    throw WhisperPackageValidationError.unexpectedFile(relative)
                }
            default:
                throw WhisperPackageValidationError.unexpectedFile(relative)
            }
        }
    }

    private static func relativePath(of url: URL, under root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            throw WhisperPackageValidationError.pathEscapesPackage(path)
        }
        return String(path.dropFirst(rootPath.count + 1)).precomposedStringWithCanonicalMapping
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validateJSON(at url: URL, relativePath: String) throws {
        do {
            _ = try JSONSerialization.jsonObject(
                with: Data(contentsOf: url),
                options: [.fragmentsAllowed]
            )
        } catch {
            throw WhisperPackageValidationError.invalidJSON(relativePath)
        }
    }

    private static func isLowercaseHex(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57) ||
            (scalar.value >= 97 && scalar.value <= 102)
    }
}

public enum WhisperPackageValidationError: Error, Sendable, Equatable, LocalizedError {
    case packageDirectoryMissing
    case modelDirectoryMissing
    case tokenizerDirectoryMissing
    case manifestContractInvalid
    case noTrustedRelease
    case untrustedReleaseManifest
    case trustedReleaseDigestInvalid
    case trustedReleaseDigestMismatch
    case trustedReleaseManifestMissing
    case trustedReleaseManifestInvalid
    case runtimeContractInvalid
    case unknownModelID(String)
    case revisionMismatch
    case tokenizerContractInvalid
    case emptyAllowlist
    case pathEscapesPackage(String)
    case pathNotAllowlisted(String)
    case duplicatePath(String)
    case caseFoldCollision(String)
    case descriptorMetadataInvalid(String)
    case requiredFileMissing(String)
    case fileTypeUnavailable(String)
    case byteCountMismatch(String)
    case hashMismatch(String)
    case invalidJSON(String)
    case tokenizerSemanticsInvalid
    case requiredArtifactMissing(String)
    case symlinkForbidden(String)
    case unexpectedFile(String)

    public var errorDescription: String? {
        switch self {
        case .packageDirectoryMissing: return "The model package directory is missing."
        case .modelDirectoryMissing: return "The model directory is missing or invalid."
        case .tokenizerDirectoryMissing: return "The tokenizer directory is missing or invalid."
        case .manifestContractInvalid: return "The model manifest schema or working-space contract is invalid."
        case .noTrustedRelease: return "No trusted app-supplied model release is configured."
        case .untrustedReleaseManifest: return "The installed model manifest is not an app-trusted release manifest."
        case .trustedReleaseDigestInvalid: return "The trusted release manifest digest is not lowercase SHA-256."
        case .trustedReleaseDigestMismatch: return "The trusted release manifest does not match its app-supplied digest."
        case .trustedReleaseManifestMissing: return "The installed package has no trusted release manifest."
        case .trustedReleaseManifestInvalid: return "The installed release manifest is malformed or unreadable."
        case .runtimeContractInvalid: return "The model manifest does not match the pinned WhisperKit 1.1.0 contract."
        case let .unknownModelID(modelID): return "Unsupported Whisper model identity: \(modelID)."
        case .revisionMismatch: return "The model revision or source subdirectory is not an approved pinned revision."
        case .tokenizerContractInvalid: return "The tokenizer must be the explicit offline tokenizer root."
        case .emptyAllowlist: return "The model manifest allowlist is empty."
        case let .pathEscapesPackage(path): return "A model path escapes the verified package: \(path)."
        case let .pathNotAllowlisted(path): return "A model path is outside the approved artifact allowlist: \(path)."
        case let .duplicatePath(path): return "The model manifest contains a duplicate path: \(path)."
        case let .caseFoldCollision(path): return "The model manifest contains a case-folding collision: \(path)."
        case let .descriptorMetadataInvalid(path): return "The model descriptor metadata is invalid: \(path)."
        case let .requiredFileMissing(path): return "A required model file is missing or not regular: \(path)."
        case let .fileTypeUnavailable(path): return "The model file type could not be determined: \(path)."
        case let .byteCountMismatch(path): return "A model file byte count does not match its manifest: \(path)."
        case let .hashMismatch(path): return "A model file hash does not match its manifest: \(path)."
        case let .invalidJSON(path): return "A JSON model or tokenizer file is malformed: \(path)."
        case .tokenizerSemanticsInvalid: return "The local tokenizer is semantically invalid."
        case let .requiredArtifactMissing(path): return "A required Whisper model component is not allowlisted: \(path)."
        case let .symlinkForbidden(path): return "Symlinks are not allowed in a model package: \(path)."
        case let .unexpectedFile(path): return "An unallowlisted model package file was found: \(path)."
        }
    }
}
