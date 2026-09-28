import CryptoKit
import Foundation
import KvoiceDomain
import KvoiceTranscription

public enum ParakeetPackageValidationError: Error, Sendable, Equatable, LocalizedError {
    case packageDirectoryMissing
    case symlinkForbidden(String)
    case noTrustedRelease
    case untrustedReleaseManifest
    case trustedReleaseDigestMismatch
    case trustedReleaseManifestMissing
    case trustedReleaseManifestInvalid
    case runtimeContractInvalid
    case unknownVariant(String)
    case tokenizerContractInvalid
    case pathEscapesPackage(String)
    case pathNotAllowlisted(String)
    case duplicatePath(String)
    case descriptorMetadataInvalid(String)
    case requiredFileMissing(String)
    case byteCountMismatch(String)
    case hashMismatch(String)
    case invalidJSON(String)
    case requiredArtifactMissing(String)
    case unexpectedFile(String)

    public var errorDescription: String? {
        switch self {
        case .packageDirectoryMissing: return "The model package directory is missing."
        case let .symlinkForbidden(path): return "Symlinks are not allowed in a model package: \(path)."
        case .noTrustedRelease: return "No trusted app-supplied model release is configured."
        case .untrustedReleaseManifest: return "The installed model manifest is not an app-trusted release manifest."
        case .trustedReleaseDigestMismatch: return "The trusted release manifest does not match its app-supplied digest."
        case .trustedReleaseManifestMissing: return "The installed package has no trusted release manifest."
        case .trustedReleaseManifestInvalid: return "The installed release manifest is malformed or unreadable."
        case .runtimeContractInvalid: return "The model manifest does not match the pinned FluidAudio contract."
        case let .unknownVariant(family): return "Unsupported FluidAudio model family: \(family)."
        case .tokenizerContractInvalid: return "A FluidAudio package keeps its vocabulary beside the graphs under model/."
        case let .pathEscapesPackage(path): return "A model path escapes the verified package: \(path)."
        case let .pathNotAllowlisted(path): return "A model path is outside model/: \(path)."
        case let .duplicatePath(path): return "The model manifest contains a duplicate path: \(path)."
        case let .descriptorMetadataInvalid(path): return "The model descriptor metadata is invalid: \(path)."
        case let .requiredFileMissing(path): return "A required model file is missing or not regular: \(path)."
        case let .byteCountMismatch(path): return "A model file byte count does not match its manifest: \(path)."
        case let .hashMismatch(path): return "A model file hash does not match its manifest: \(path)."
        case let .invalidJSON(path): return "A JSON model file is malformed: \(path)."
        case let .requiredArtifactMissing(path): return "A required Parakeet model component is not allowlisted: \(path)."
        case let .unexpectedFile(path): return "An unallowlisted model package file was found: \(path)."
        }
    }
}

/// Fail-closed validation immediately before FluidAudio is handed a folder
/// (ADR-019, the counterpart of `WhisperModelPackageValidator`).
///
/// The model manager verified the package at install; this repeats the
/// integrity checks at the runtime boundary so a moved, edited, symlinked or
/// hand-built folder never reaches Core ML, and so the adapter can never be
/// tempted to "fill in" a missing bundle from the network — a missing file is
/// a validation error here.
public struct ParakeetModelPackageValidator: Sendable {
    public static let runtimePackage = "FluidInference/FluidAudio"
    /// Must equal the `exact:` pin in `Package.swift`; a test asserts it.
    public static let runtimeVersion = "0.15.7"

    private let trustedReleases: [WhisperModelReleaseTrustAnchor]

    public init(trustedReleases: [WhisperModelReleaseTrustAnchor]) {
        self.trustedReleases = trustedReleases
    }

    /// Validates and returns the variant the package must be driven by.
    @discardableResult
    public func validate(_ package: InstalledModelPackage) throws -> ParakeetModelVariant {
        let fileManager = FileManager.default
        let root = package.packageURL.standardizedFileURL
        guard Self.fileType(at: root) == .typeDirectory else {
            throw ParakeetPackageValidationError.packageDirectoryMissing
        }
        guard root.resolvingSymlinksInPath().standardizedFileURL == root else {
            throw ParakeetPackageValidationError.symlinkForbidden(root.lastPathComponent)
        }
        let release = try trustedRelease(for: package.manifest)
        try Self.validateInstalledManifest(release, packageRoot: root)

        let manifest = package.manifest
        guard manifest.schemaVersion == 1,
              manifest.workingSpaceBytes > 0,
              manifest.format == ParakeetModelVariant.manifestFormat,
              manifest.runtimeCompatibility.swiftPackage == Self.runtimePackage,
              manifest.runtimeCompatibility.exactVersion == Self.runtimeVersion else {
            throw ParakeetPackageValidationError.runtimeContractInvalid
        }
        guard let variant = ParakeetModelVariant(manifest: manifest) else {
            throw ParakeetPackageValidationError.unknownVariant(manifest.family)
        }
        guard manifest.tokenizer.relativeRoot == "model", manifest.tokenizer.offlineRequired else {
            throw ParakeetPackageValidationError.tokenizerContractInvalid
        }
        let modelFolder = root.appendingPathComponent("model", isDirectory: true)
        guard package.modelFolderURL.standardizedFileURL == modelFolder,
              package.tokenizerFolderURL.standardizedFileURL == modelFolder,
              Self.fileType(at: modelFolder) == .typeDirectory else {
            throw ParakeetPackageValidationError.pathEscapesPackage("model")
        }

        var allowlisted = Set<String>()
        for descriptor in manifest.files {
            let path = try Self.validatedRelativePath(descriptor.path)
            guard path.hasPrefix("model/"), path.split(separator: "/").count >= 2 else {
                throw ParakeetPackageValidationError.pathNotAllowlisted(path)
            }
            guard allowlisted.insert(path).inserted else {
                throw ParakeetPackageValidationError.duplicatePath(path)
            }
            guard descriptor.bytes > 0,
                  descriptor.sha256.count == 64,
                  descriptor.sha256.unicodeScalars.allSatisfy(Self.isLowercaseHex) else {
                throw ParakeetPackageValidationError.descriptorMetadataInvalid(path)
            }
            let url = root.appendingPathComponent(path, isDirectory: false)
            try Self.rejectSymlinksAlongPath(path, under: root)
            guard Self.fileType(at: url) == .typeRegular else {
                throw ParakeetPackageValidationError.requiredFileMissing(path)
            }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == descriptor.bytes else {
                throw ParakeetPackageValidationError.byteCountMismatch(path)
            }
            guard try Self.sha256(of: url) == descriptor.sha256 else {
                throw ParakeetPackageValidationError.hashMismatch(path)
            }
            if path.hasSuffix(".json") {
                do {
                    _ = try JSONSerialization.jsonObject(with: Data(contentsOf: url), options: [.fragmentsAllowed])
                } catch {
                    throw ParakeetPackageValidationError.invalidJSON(path)
                }
            }
        }
        for required in variant.requiredArtifactRoots {
            guard allowlisted.contains(where: { $0 == required || $0.hasPrefix(required + "/") }) else {
                throw ParakeetPackageValidationError.requiredArtifactMissing(required)
            }
        }
        try Self.rejectUnexpectedEntries(in: root, allowlisted: allowlisted)
        return variant
    }

    // MARK: - Trust anchor

    private func trustedRelease(for manifest: ModelManifest) throws -> WhisperModelReleaseTrustAnchor {
        guard !trustedReleases.isEmpty else {
            throw ParakeetPackageValidationError.noTrustedRelease
        }
        guard let release = trustedReleases.first(where: { $0.manifest == manifest }) else {
            throw ParakeetPackageValidationError.untrustedReleaseManifest
        }
        guard (try? WhisperModelReleaseTrustAnchor.digest(for: release.manifest)) == release.manifestSHA256 else {
            throw ParakeetPackageValidationError.trustedReleaseDigestMismatch
        }
        return release
    }

    /// The `ModelManifest.json` on disk must be the trusted manifest's
    /// canonical bytes, exactly.
    private static func validateInstalledManifest(_ release: WhisperModelReleaseTrustAnchor, packageRoot: URL) throws {
        let url = packageRoot.appendingPathComponent("ModelManifest.json", isDirectory: false)
        guard fileType(at: url) == .typeRegular else {
            throw ParakeetPackageValidationError.trustedReleaseManifestMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ParakeetPackageValidationError.trustedReleaseManifestInvalid
        }
        do {
            let installed = try JSONDecoder().decode(ModelManifest.self, from: data)
            let canonical = try WhisperModelReleaseTrustAnchor.canonicalData(for: release.manifest)
            guard installed == release.manifest, data == canonical else {
                throw ParakeetPackageValidationError.untrustedReleaseManifest
            }
        } catch let error as ParakeetPackageValidationError {
            throw error
        } catch {
            throw ParakeetPackageValidationError.trustedReleaseManifestInvalid
        }
    }

    // MARK: - File system

    private static func validatedRelativePath(_ path: String) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
            throw ParakeetPackageValidationError.pathEscapesPackage(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              components.joined(separator: "/") == path else {
            throw ParakeetPackageValidationError.pathEscapesPackage(path)
        }
        return path.precomposedStringWithCanonicalMapping
    }

    private static func rejectSymlinksAlongPath(_ path: String, under root: URL) throws {
        var cursor = root
        for component in path.split(separator: "/") {
            cursor.appendPathComponent(String(component), isDirectory: false)
            if fileType(at: cursor) == .typeSymbolicLink {
                throw ParakeetPackageValidationError.symlinkForbidden(path)
            }
        }
    }

    private static func rejectUnexpectedEntries(in root: URL, allowlisted: Set<String>) throws {
        var allowedDirectories: Set<String> = ["model"]
        for path in allowlisted {
            let components = path.split(separator: "/").map(String.init)
            for index in 1..<components.count {
                allowedDirectories.insert(components[..<index].joined(separator: "/"))
            }
        }
        var entries: [URL] = []
        func visit(_ directory: URL) throws {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: []) {
                entries.append(url)
                if fileType(at: url) == .typeDirectory { try visit(url) }
            }
        }
        try visit(root)
        let rootPath = root.standardizedFileURL.path
        for url in entries {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else {
                throw ParakeetPackageValidationError.pathEscapesPackage(full)
            }
            let relative = String(full.dropFirst(rootPath.count + 1)).precomposedStringWithCanonicalMapping
            switch fileType(at: url) {
            case .typeRegular:
                guard relative == "ModelManifest.json" || relative == ".installed.json" || allowlisted.contains(relative) else {
                    throw ParakeetPackageValidationError.unexpectedFile(relative)
                }
            case .typeDirectory:
                guard allowedDirectories.contains(relative) else {
                    throw ParakeetPackageValidationError.unexpectedFile(relative)
                }
            case .typeSymbolicLink:
                throw ParakeetPackageValidationError.symlinkForbidden(relative)
            default:
                throw ParakeetPackageValidationError.unexpectedFile(relative)
            }
        }
    }

    private static func fileType(at url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
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

    private static func isLowercaseHex(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
    }
}
