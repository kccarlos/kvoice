import CryptoKit
import Foundation

public struct UserRecordingCorpusManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let corpusId: String
    public let sourcePolicy: String
    public let audioIncluded: Bool
    public let externalDirectoryHint: String
    public let expectedExternalFilenames: [String]
    public let referenceFile: String
    public let sourceDurationToleranceSeconds: Double
    public let normalizationTarget: NormalizationTarget
    public let clips: [UserRecordingClip]

    public init(
        schemaVersion: Int,
        corpusId: String,
        sourcePolicy: String,
        audioIncluded: Bool,
        externalDirectoryHint: String,
        expectedExternalFilenames: [String],
        referenceFile: String,
        sourceDurationToleranceSeconds: Double,
        normalizationTarget: NormalizationTarget,
        clips: [UserRecordingClip]
    ) {
        self.schemaVersion = schemaVersion
        self.corpusId = corpusId
        self.sourcePolicy = sourcePolicy
        self.audioIncluded = audioIncluded
        self.externalDirectoryHint = externalDirectoryHint
        self.expectedExternalFilenames = expectedExternalFilenames
        self.referenceFile = referenceFile
        self.sourceDurationToleranceSeconds = sourceDurationToleranceSeconds
        self.normalizationTarget = normalizationTarget
        self.clips = clips
    }

    public static func load(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

public struct NormalizationTarget: Codable, Sendable, Equatable {
    public let container: String
    public let sampleRateHz: Int
    public let channels: Int
    public let sampleFormat: String
}

public struct UserRecordingClip: Codable, Sendable, Equatable {
    public let id: String
    public let filename: String
    public let sourceFormat: SourceFormat
    public let sourceSHA256: String
    public let sourceDurationSeconds: Double
    public let measuredDurationSeconds: Double
    public let reference: UserRecordingReference
    public let languageTags: [String]
    public let protectedSpans: [String]
}

public struct SourceFormat: Codable, Sendable, Equatable {
    public let codec: String
    public let sampleRateHz: Int
    public let channels: Int
}

public struct UserRecordingReference: Codable, Sendable, Equatable {
    public let file: String
    public let line: Int
    public let text: String
}

public struct RuntimeSpikeHashVerification: Codable, Sendable, Equatable {
    public let clipID: String
    public let filename: String
    public let expectedSHA256: String
    public let actualSHA256: String?
    public let matched: Bool

    public init(
        clipID: String,
        filename: String,
        expectedSHA256: String,
        actualSHA256: String?,
        matched: Bool
    ) {
        self.clipID = clipID
        self.filename = filename
        self.expectedSHA256 = expectedSHA256
        self.actualSHA256 = actualSHA256
        self.matched = matched
    }
}

public enum RuntimeSpikeError: Error, Sendable, Equatable, LocalizedError {
    case missingAudio(URL)
    case hashMismatch(clipID: String, expected: String, actual: String)
    case invalidManifest(String)
    case unsupportedIterationCount
    case unsupportedStabilityJobCount

    public var errorDescription: String? {
        switch self {
        case let .missingAudio(url):
            return "The external recording is missing: \(url.path)"
        case let .hashMismatch(clipID, expected, actual):
            return "Corpus hash mismatch for \(clipID) (expected \(expected), received \(actual))."
        case let .invalidManifest(message):
            return "The runtime spike manifest is invalid: \(message)"
        case .unsupportedIterationCount:
            return "The runtime spike requires at least one iteration."
        case .unsupportedStabilityJobCount:
            return "The runtime spike stability job count cannot be negative."
        }
    }
}

public struct RuntimeSpikeCorpusVerifier: Sendable {
    public let manifest: UserRecordingCorpusManifest
    public let audioDirectory: URL

    public init(manifest: UserRecordingCorpusManifest, audioDirectory: URL) {
        self.manifest = manifest
        self.audioDirectory = audioDirectory.standardizedFileURL
    }

    public func verifyHashes() throws -> [RuntimeSpikeHashVerification] {
        guard manifest.schemaVersion == 1 else {
            throw RuntimeSpikeError.invalidManifest("unsupported schema version")
        }
        guard manifest.sourcePolicy == "external-only", !manifest.audioIncluded else {
            throw RuntimeSpikeError.invalidManifest("external-only corpus must not include audio")
        }
        guard !manifest.clips.isEmpty,
              Self.isSafeRelativePath(manifest.referenceFile) else {
            throw RuntimeSpikeError.invalidManifest("corpus must contain clips and a safe reference path")
        }
        try validateAudioDirectory()

        let expectedFilenames = try Set(manifest.expectedExternalFilenames.map(Self.validateLeafFilename))
        let clipFilenames = try Set(manifest.clips.map { try Self.validateClip($0) })
        guard expectedFilenames.count == manifest.expectedExternalFilenames.count,
              clipFilenames.count == manifest.clips.count,
              Set(manifest.clips.map(\.id)).count == manifest.clips.count,
              expectedFilenames == clipFilenames else {
            throw RuntimeSpikeError.invalidManifest("expected external filenames do not match clip filenames")
        }

        return try manifest.clips.map { clip in
            let filename = try Self.validateClip(clip)
            let url = audioDirectory.appendingPathComponent(filename, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw RuntimeSpikeError.missingAudio(url)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
                throw RuntimeSpikeError.invalidManifest("audio entry is not a regular file: \(filename)")
            }
            let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isContained(resolvedURL, in: audioDirectory) else {
                throw RuntimeSpikeError.invalidManifest("audio entry escapes the external audio directory: \(filename)")
            }
            let actual = try hexDigest(for: url)
            guard actual == clip.sourceSHA256 else {
                throw RuntimeSpikeError.hashMismatch(
                    clipID: clip.id,
                    expected: clip.sourceSHA256,
                    actual: actual
                )
            }
            return RuntimeSpikeHashVerification(
                clipID: clip.id,
                filename: clip.filename,
                expectedSHA256: clip.sourceSHA256,
                actualSHA256: actual,
                matched: true
            )
        }
    }

    private func validateAudioDirectory() throws {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: audioDirectory.path)
        guard (attributes[.type] as? FileAttributeType) == .typeDirectory else {
            throw RuntimeSpikeError.invalidManifest("external audio directory is not a regular directory")
        }
        let resolvedDirectory = audioDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedDirectory == audioDirectory else {
            throw RuntimeSpikeError.invalidManifest("external audio directory must not be a symlink")
        }
    }

    private static func validateClip(_ clip: UserRecordingClip) throws -> String {
        let filename = try validateLeafFilename(clip.filename)
        guard !clip.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeSpikeError.invalidManifest("clip ID must not be empty")
        }
        guard clip.sourceSHA256.count == 64,
              clip.sourceSHA256.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
              }) else {
            throw RuntimeSpikeError.invalidManifest("clip hash must be lowercase SHA-256: \(clip.id)")
        }
        guard isSafeRelativePath(clip.reference.file) else {
            throw RuntimeSpikeError.invalidManifest("reference file path is unsafe: \(clip.id)")
        }
        return filename
    }

    private static func validateLeafFilename(_ filename: String) throws -> String {
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.contains("/"),
              !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw RuntimeSpikeError.invalidManifest("audio filename must be a single safe leaf: \(filename)")
        }
        return filename
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isContained(_ url: URL, in directory: URL) -> Bool {
        let root = directory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root + "/")
    }

    private func hexDigest(for url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
