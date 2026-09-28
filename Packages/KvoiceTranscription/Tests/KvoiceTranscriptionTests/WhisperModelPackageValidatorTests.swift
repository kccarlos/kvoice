import CryptoKit
import Foundation
import XCTest
@testable import KvoiceTranscription
import KvoiceDomain

final class WhisperModelPackageValidatorTests: XCTestCase {
    private var temporaryPackageURLs: [URL] = []

    override func tearDown() {
        for url in temporaryPackageURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryPackageURLs.removeAll()
        super.tearDown()
    }

    func testValidatesPinnedPackageAndAllManifestFiles() throws {
        let package = makePackage()

        XCTAssertNoThrow(try validator(for: package).validate(package))
    }

    func testRejectsHashMismatch() throws {
        let package = makePackage()
        let path = package.modelFolderURL.appendingPathComponent("config.json")
        let original = Data("{\"fixture\":\"model/config.json\"}".utf8)
        try Data(repeating: 0x7f, count: original.count).write(to: path, options: .atomic)

        XCTAssertThrowsError(try validator(for: package).validate(package)) { error in
            XCTAssertEqual(error as? WhisperPackageValidationError, .hashMismatch("model/config.json"))
        }
    }

    func testRejectsSymlinkAndUnexpectedFiles() throws {
        let symlinkPackage = makePackage()
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kvoice-validator-outside-\(UUID().uuidString)")
        try Data("outside".utf8).write(to: outside, options: .atomic)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: symlinkPackage.modelFolderURL.appendingPathComponent("AudioEncoder.mlmodelc/weights-link"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try validator(for: symlinkPackage).validate(symlinkPackage)) { error in
            guard case .symlinkForbidden = error as? WhisperPackageValidationError else {
                return XCTFail("Expected symlink rejection, received \(error)")
            }
        }

        let unexpectedPackage = makePackage()
        try Data("unexpected".utf8).write(
            to: unexpectedPackage.modelFolderURL.appendingPathComponent("unexpected.bin"),
            options: .atomic
        )
        XCTAssertThrowsError(try validator(for: unexpectedPackage).validate(unexpectedPackage)) { error in
            XCTAssertEqual(error as? WhisperPackageValidationError, .unexpectedFile("model/unexpected.bin"))
        }
    }

    func testRejectsTraversalRevisionAndTokenizerContract() throws {
        let traversalPackage = makePackage { manifest in
            var files = manifest.files
            let descriptor = files[0]
            files[0] = ModelFileDescriptor(
                path: "model/../escape.bin",
                bytes: descriptor.bytes,
                sha256: descriptor.sha256,
                role: descriptor.role
            )
            return Self.copy(manifest, files: files)
        }
        XCTAssertThrowsError(try validator(for: traversalPackage).validate(traversalPackage)) { error in
            XCTAssertEqual(error as? WhisperPackageValidationError, .pathEscapesPackage("model/../escape.bin"))
        }

        let revisionPackage = makePackage { manifest in
            Self.copy(
                manifest,
                source: ModelManifestSource(
                    repository: manifest.source.repository,
                    revision: String(repeating: "a", count: 40),
                    subdirectory: manifest.source.subdirectory
                )
            )
        }
        XCTAssertThrowsError(try validator(for: revisionPackage).validate(revisionPackage)) { error in
            XCTAssertEqual(error as? WhisperPackageValidationError, .revisionMismatch)
        }

        let tokenizerPackage = makePackage { manifest in
            Self.copy(manifest, tokenizer: ModelTokenizer(relativeRoot: "wrong", offlineRequired: true))
        }
        XCTAssertThrowsError(try validator(for: tokenizerPackage).validate(tokenizerPackage)) { error in
            XCTAssertEqual(error as? WhisperPackageValidationError, .tokenizerContractInvalid)
        }

        let missingTokenizerConfig = makePackage()
        try FileManager.default.removeItem(
            at: missingTokenizerConfig.tokenizerFolderURL
                .appendingPathComponent("models/openai/whisper-large-v3/tokenizer_config.json")
        )
        XCTAssertThrowsError(try validator(for: missingTokenizerConfig).validate(missingTokenizerConfig)) { error in
            XCTAssertEqual(
                error as? WhisperPackageValidationError,
                .requiredFileMissing("tokenizer/models/openai/whisper-large-v3/tokenizer_config.json")
            )
        }
    }

    func testRejectsManifestOutsideAppSuppliedTrustAnchor() throws {
        let trustedPackage = makePackage()
        let untrustedPackage = makePackage { manifest in
            Self.copy(manifest, workingSpaceBytes: manifest.workingSpaceBytes + 1)
        }

        XCTAssertThrowsError(
            try WhisperModelPackageValidator(
                trustedReleases: [anchor(for: trustedPackage)]
            ).validate(untrustedPackage)
        ) { error in
            XCTAssertEqual(error as? WhisperPackageValidationError, .untrustedReleaseManifest)
        }
    }

    func testRejectsPackageManifestFileThatDiffersFromTrustAnchor() throws {
        let package = makePackage()
        let onDiskManifest = Self.copy(
            package.manifest,
            workingSpaceBytes: package.manifest.workingSpaceBytes + 1
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(onDiskManifest).write(
            to: package.packageURL.appendingPathComponent("ModelManifest.json"),
            options: .atomic
        )

        XCTAssertThrowsError(try validator(for: package).validate(package)) { error in
            XCTAssertEqual(error as? WhisperPackageValidationError, .untrustedReleaseManifest)
        }
    }

    private func makePackage(
        transform: (ModelManifest) -> ModelManifest = { $0 }
    ) -> InstalledModelPackage {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kvoice-validator-test-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        let paths: [(String, ModelArtifactRole)] = [
            ("model/AudioEncoder.mlmodelc/weights.bin", .audioEncoder),
            ("model/MelSpectrogram.mlmodelc/weights.bin", .melSpectrogram),
            ("model/TextDecoder.mlmodelc/weights.bin", .textDecoder),
            ("model/TextDecoderContextPrefill.mlmodelc/weights.bin", .decoderPrefill),
            ("model/config.json", .configuration),
            ("model/generation_config.json", .configuration),
            ("tokenizer/models/openai/whisper-large-v3/tokenizer.json", .tokenizer),
            ("tokenizer/models/openai/whisper-large-v3/tokenizer_config.json", .tokenizer)
        ]
        var descriptors: [ModelFileDescriptor] = []
        for (path, role) in paths {
            let data = path.hasSuffix(".json")
                ? Data("{\"fixture\":\"\(path)\"}".utf8)
                : Data("fixture-\(path)".utf8)
            let url = root.appendingPathComponent(path)
            try! fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try! data.write(to: url, options: .atomic)
            descriptors.append(
                ModelFileDescriptor(
                    path: path,
                    bytes: Int64(data.count),
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    role: role
                )
            )
        }
        let manifest = transform(
            ModelManifest(
                schemaVersion: 1,
                modelID: "whisper-large-v3-turbo-coreml-uncompressed",
                family: "whisper-large-v3-turbo",
                format: "whisperkit-coreml",
                workingSpaceBytes: 1_073_741_824,
                source: ModelManifestSource(
                    repository: "argmaxinc/whisperkit-coreml",
                    revision: "04e5c42d80a522518023727e8c7e68d4bb391b28",
                    subdirectory: "openai_whisper-large-v3-v20240930_turbo"
                ),
                runtimeCompatibility: ModelRuntimeCompatibility(
                    swiftPackage: "argmaxinc/argmax-oss-swift/WhisperKit",
                    exactVersion: "1.1.0"
                ),
                tokenizer: ModelTokenizer(relativeRoot: "tokenizer"),
                files: descriptors
            )
        )
        try! fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try! encoder.encode(manifest).write(
            to: root.appendingPathComponent("ModelManifest.json"),
            options: .atomic
        )
        temporaryPackageURLs.append(root)
        return InstalledModelPackage(
            manifest: manifest,
            packageURL: root,
            modelFolderURL: root.appendingPathComponent("model", isDirectory: true),
            tokenizerFolderURL: root.appendingPathComponent("tokenizer", isDirectory: true),
            ownership: .managedByKvoice
        )
    }

    private static func copy(
        _ manifest: ModelManifest,
        source: ModelManifestSource? = nil,
        tokenizer: ModelTokenizer? = nil,
        files: [ModelFileDescriptor]? = nil,
        workingSpaceBytes: Int64? = nil
    ) -> ModelManifest {
        ModelManifest(
            schemaVersion: manifest.schemaVersion,
            modelID: manifest.modelID,
            family: manifest.family,
            format: manifest.format,
            workingSpaceBytes: workingSpaceBytes ?? manifest.workingSpaceBytes,
            source: source ?? manifest.source,
            runtimeCompatibility: manifest.runtimeCompatibility,
            tokenizer: tokenizer ?? manifest.tokenizer,
            files: files ?? manifest.files
        )
    }

    private func anchor(for package: InstalledModelPackage) -> WhisperModelReleaseTrustAnchor {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(package.manifest)
        return try! WhisperModelReleaseTrustAnchor(
            manifestData: data,
            manifestSHA256: try! WhisperModelReleaseTrustAnchor.digest(for: package.manifest)
        )
    }

    private func validator(for package: InstalledModelPackage) -> WhisperModelPackageValidator {
        WhisperModelPackageValidator(trustedReleases: [anchor(for: package)])
    }
}
