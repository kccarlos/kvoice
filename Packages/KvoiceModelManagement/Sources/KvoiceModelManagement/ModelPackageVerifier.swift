import CryptoKit
import Foundation
import KvoiceDomain
import KvoiceTranscription

/// Errors produced by the manager's acquisition boundary. The existing
/// Whisper validator repeats these checks immediately before runtime loading;
/// this verifier additionally accepts a temporary staging package and is used
/// before any directory is atomically installed.
public enum ModelPackageVerificationError: Error, Sendable, Equatable, LocalizedError {
    case packageDirectoryMissing
    case packageRootSymlink
    case manifestMissing
    case manifestUnreadable
    case manifestNotTrusted
    case trustedManifestDigestInvalid
    case trustedManifestDigestMismatch
    case invalidDescriptor(String)
    case unsafePath(String)
    case missingFile(String)
    case symlinkForbidden(String)
    case notRegularFile(String)
    case byteCountMismatch(String)
    case hashMismatch(String)
    case unexpectedEntry(String)

    public var errorDescription: String? {
        switch self {
        case .packageDirectoryMissing: return "The model package directory is missing."
        case .packageRootSymlink: return "The model package root must not be a symbolic link."
        case .manifestMissing: return "ModelManifest.json is missing."
        case .manifestUnreadable: return "ModelManifest.json could not be decoded."
        case .manifestNotTrusted: return "The package manifest is not the app-trusted manifest."
        case .trustedManifestDigestInvalid: return "The trusted manifest digest is not lowercase SHA-256."
        case .trustedManifestDigestMismatch: return "The trusted manifest digest does not match its contents."
        case let .invalidDescriptor(path): return "The model manifest descriptor is invalid: " + path + "."
        case let .unsafePath(path): return "The model path is unsafe: " + path + "."
        case let .missingFile(path): return "A model file is missing: " + path + "."
        case let .symlinkForbidden(path): return "A model path is a symbolic link: " + path + "."
        case let .notRegularFile(path): return "A model path is not a regular file: " + path + "."
        case let .byteCountMismatch(path): return "The model file size does not match its manifest: " + path + "."
        case let .hashMismatch(path): return "The model file hash does not match its manifest: " + path + "."
        case let .unexpectedEntry(path): return "The model package contains an unexpected entry: " + path + "."
        }
    }
}

/// Shared path validation for model manifests and download destinations.
public enum ModelRelativePath {
    public static func validated(_ path: String) throws -> String {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\") else {
            throw ModelPackageVerificationError.unsafePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ModelPackageVerificationError.unsafePath(path)
        }
        let normalized = components.joined(separator: "/")
        guard normalized == path else {
            throw ModelPackageVerificationError.unsafePath(path)
        }
        return normalized.precomposedStringWithCanonicalMapping
    }

    public static func url(for path: String, under root: URL) throws -> URL {
        let normalized = try validated(path)
        let rootURL = root.standardizedFileURL
        let result = rootURL.appendingPathComponent(normalized, isDirectory: false).standardizedFileURL
        guard result.path == rootURL.path || result.path.hasPrefix(rootURL.path + "/") else {
            throw ModelPackageVerificationError.unsafePath(path)
        }
        return result
    }
}

/// Verifies an entire package against an app-supplied trusted release
/// manifest. It is intentionally deterministic and does not fetch metadata or
/// infer missing files from a remote repository.
public struct ModelPackageVerifier: Sendable {
    public let trustedRelease: WhisperModelReleaseTrustAnchor

    public init(trustedRelease: WhisperModelReleaseTrustAnchor) {
        self.trustedRelease = trustedRelease
    }

    /// The folder names a manifest may name as its tokenizer root: the
    /// separate `tokenizer/` tree Whisper packages carry, or `model/` for a
    /// FluidAudio package whose vocabulary sits beside the graphs (ADR-019).
    /// Anything else is refused so the root can never point outside the
    /// package.
    public static let allowedTokenizerRoots: Set<String> = ["tokenizer", "model"]

    public static func tokenizerFolderURL(for manifest: ModelManifest, packageRoot root: URL) throws -> URL {
        let relativeRoot = manifest.tokenizer.relativeRoot
        guard allowedTokenizerRoots.contains(relativeRoot) else {
            throw ModelPackageVerificationError.unsafePath(relativeRoot)
        }
        return root.appendingPathComponent(relativeRoot, isDirectory: true)
    }

    public func makePackage(
        at packageURL: URL,
        ownership: ModelOwnership
    ) throws -> InstalledModelPackage {
        let root = try verifiedRoot(packageURL)
        let manifest = try trustedManifest(in: root)
        let modelFolderURL = root.appendingPathComponent("model", isDirectory: true)
        let tokenizerFolderURL = try Self.tokenizerFolderURL(for: manifest, packageRoot: root)
        guard isDirectory(modelFolderURL), isDirectory(tokenizerFolderURL) else {
            throw ModelPackageVerificationError.packageDirectoryMissing
        }
        return InstalledModelPackage(
            manifest: manifest,
            packageURL: root,
            modelFolderURL: modelFolderURL,
            tokenizerFolderURL: tokenizerFolderURL,
            ownership: ownership
        )
    }

    public func verify(_ package: InstalledModelPackage) throws {
        let root = try verifiedRoot(package.packageURL)
        let manifest = try trustedManifest(in: root)
        guard package.manifest == manifest,
              package.modelFolderURL.standardizedFileURL == root.appendingPathComponent("model", isDirectory: true).standardizedFileURL,
              package.tokenizerFolderURL.standardizedFileURL == (try Self.tokenizerFolderURL(for: manifest, packageRoot: root)).standardizedFileURL else {
            throw ModelPackageVerificationError.manifestNotTrusted
        }
        guard isDirectory(package.modelFolderURL), isDirectory(package.tokenizerFolderURL) else {
            throw ModelPackageVerificationError.packageDirectoryMissing
        }
        guard !manifest.files.isEmpty else {
            throw ModelPackageVerificationError.invalidDescriptor("manifest files must not be empty")
        }

        var allowlistedPaths = Set<String>()
        var foldedPaths = Set<String>()
        for descriptor in manifest.files {
            let path = try ModelRelativePath.validated(descriptor.path)
            guard path.hasPrefix("model/") || path.hasPrefix("tokenizer/") else {
                throw ModelPackageVerificationError.unsafePath(path)
            }
            guard descriptor.bytes > 0,
                  isLowercaseSHA256(descriptor.sha256) else {
                throw ModelPackageVerificationError.invalidDescriptor(path)
            }
            guard allowlistedPaths.insert(path).inserted else {
                throw ModelPackageVerificationError.invalidDescriptor("duplicate path (path)")
            }
            let folded = path.precomposedStringWithCanonicalMapping.lowercased()
            guard foldedPaths.insert(folded).inserted else {
                throw ModelPackageVerificationError.invalidDescriptor("case-fold collision (path)")
            }

            let url = try ModelRelativePath.url(for: path, under: root)
            try rejectSymlinksAlongPath(url, under: root, relativePath: path)
            guard fileType(at: url) != nil else {
                throw ModelPackageVerificationError.missingFile(path)
            }
            guard fileType(at: url) == .typeRegular else {
                throw ModelPackageVerificationError.notRegularFile(path)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == descriptor.bytes else {
                throw ModelPackageVerificationError.byteCountMismatch(path)
            }
            guard try SHA256.digest(of: url) == descriptor.sha256 else {
                throw ModelPackageVerificationError.hashMismatch(path)
            }
        }

        let entries = try recursiveEntries(in: root)
        try rejectSymlinks(in: root, entries: entries)
        try rejectUnexpectedEntries(
            in: root,
            entries: entries,
            allowlistedPaths: allowlistedPaths
        )
    }

    private func verifiedRoot(_ packageURL: URL) throws -> URL {
        let root = packageURL.standardizedFileURL
        guard root.isFileURL, isDirectory(root) else {
            throw ModelPackageVerificationError.packageDirectoryMissing
        }
        guard root.resolvingSymlinksInPath().standardizedFileURL == root else {
            throw ModelPackageVerificationError.packageRootSymlink
        }
        return root
    }

    private func trustedManifest(in root: URL) throws -> ModelManifest {
        guard isLowercaseSHA256(trustedRelease.manifestSHA256) else {
            throw ModelPackageVerificationError.trustedManifestDigestInvalid
        }
        guard try WhisperModelReleaseTrustAnchor.digest(for: trustedRelease.manifest) == trustedRelease.manifestSHA256 else {
            throw ModelPackageVerificationError.trustedManifestDigestMismatch
        }

        let manifestURL = root.appendingPathComponent("ModelManifest.json", isDirectory: false)
        guard fileType(at: manifestURL) == .typeRegular else {
            throw ModelPackageVerificationError.manifestMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw ModelPackageVerificationError.manifestUnreadable
        }
        let manifest: ModelManifest
        do {
            manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        } catch {
            throw ModelPackageVerificationError.manifestUnreadable
        }
        let canonical = try canonicalData(for: trustedRelease.manifest)
        guard manifest == trustedRelease.manifest,
              data == canonical,
              try WhisperModelReleaseTrustAnchor.digest(for: manifest) == trustedRelease.manifestSHA256 else {
            throw ModelPackageVerificationError.manifestNotTrusted
        }
        return manifest
    }

    private func recursiveEntries(in root: URL) throws -> [URL] {
        var entries: [URL] = []
        func visit(_ directory: URL) throws {
            for url in try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ) {
                entries.append(url)
                if fileType(at: url) == .typeDirectory {
                    try visit(url)
                }
            }
        }
        try visit(root)
        return entries
    }

    private func rejectSymlinks(in root: URL, entries: [URL]) throws {
        if fileType(at: root) == .typeSymbolicLink {
            throw ModelPackageVerificationError.packageRootSymlink
        }
        for url in entries where fileType(at: url) == .typeSymbolicLink {
            throw ModelPackageVerificationError.symlinkForbidden(relativePath(url, under: root))
        }
    }

    private func rejectSymlinksAlongPath(
        _ url: URL,
        under root: URL,
        relativePath: String
    ) throws {
        var cursor = root
        let components = relativePath.split(separator: "/").map(String.init)
        for component in components {
            cursor.appendPathComponent(component, isDirectory: false)
            if fileType(at: cursor) == .typeSymbolicLink {
                throw ModelPackageVerificationError.symlinkForbidden(relativePath)
            }
        }
    }

    private func rejectUnexpectedEntries(
        in root: URL,
        entries: [URL],
        allowlistedPaths: Set<String>
    ) throws {
        var allowedDirectories = Set(["model", "tokenizer"])
        for path in allowlistedPaths {
            let components = path.split(separator: "/").map(String.init)
            for index in 1..<components.count {
                allowedDirectories.insert(components[..<index].joined(separator: "/"))
            }
        }
        for url in entries {
            let relative = relativePath(url, under: root)
            switch fileType(at: url) {
            case .typeDirectory:
                guard allowedDirectories.contains(relative) else {
                    throw ModelPackageVerificationError.unexpectedEntry(relative)
                }
            case .typeRegular:
                guard relative == "ModelManifest.json" ||
                    relative == ".installed.json" ||
                    allowlistedPaths.contains(relative) else {
                    throw ModelPackageVerificationError.unexpectedEntry(relative)
                }
            default:
                throw ModelPackageVerificationError.unexpectedEntry(relative)
            }
        }
    }

    private func canonicalData(for manifest: ModelManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }

    private func isDirectory(_ url: URL) -> Bool {
        fileType(at: url) == .typeDirectory
    }

    private func fileType(at url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    private func relativePath(_ url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }
}

private extension SHA256 {
    static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
