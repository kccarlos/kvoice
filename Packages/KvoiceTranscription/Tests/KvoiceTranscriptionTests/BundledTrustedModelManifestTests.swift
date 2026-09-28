import XCTest
import KvoiceDomain
@testable import KvoiceTranscription

/// Guards the app-owned release trust material in `Apps/KvoiceApp`.
///
/// `BundledTrustedModelReleaseLoader` fails closed when `ModelManifest.json` or
/// `ModelManifest.sha256` is missing or inconsistent, which silently disables
/// every model operation and leaves the menu at `Model: Not Ready`. These checks
/// catch that drift in the package suite instead of at runtime.
final class BundledTrustedModelManifestTests: XCTestCase {
    private static var appDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KvoiceTranscriptionTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // KvoiceTranscription
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Apps")
            .appendingPathComponent("KvoiceApp")
    }

    func testBundledDigestMatchesCanonicalManifestBytes() throws {
        let manifestData = try Data(
            contentsOf: Self.appDirectory.appendingPathComponent("ModelManifest.json")
        )
        let digest = try String(
            contentsOf: Self.appDirectory.appendingPathComponent("ModelManifest.sha256"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(
            digest.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) },
            "digest must be lowercase hex"
        )

        let anchor = try WhisperModelReleaseTrustAnchor(
            manifestData: manifestData,
            manifestSHA256: digest
        )
        XCTAssertEqual(
            try WhisperModelReleaseTrustAnchor.digest(for: anchor.manifest),
            digest
        )
    }

    func testBundledManifestMatchesTheOneSupportedRelease() throws {
        let manifestData = try Data(
            contentsOf: Self.appDirectory.appendingPathComponent("ModelManifest.json")
        )
        let digest = try String(
            contentsOf: Self.appDirectory.appendingPathComponent("ModelManifest.sha256"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = try WhisperModelReleaseTrustAnchor(
            manifestData: manifestData,
            manifestSHA256: digest
        ).manifest

        XCTAssertEqual(manifest.family, "whisper-large-v3-turbo")
        XCTAssertEqual(manifest.format, "whisperkit-coreml")
        XCTAssertEqual(manifest.source.repository, "argmaxinc/whisperkit-coreml")
        XCTAssertEqual(manifest.runtimeCompatibility.exactVersion, "1.1.0")
        XCTAssertEqual(manifest.tokenizer.relativeRoot, "tokenizer")
        XCTAssertTrue(manifest.tokenizer.offlineRequired)
        XCTAssertFalse(manifest.files.isEmpty)
    }
}
