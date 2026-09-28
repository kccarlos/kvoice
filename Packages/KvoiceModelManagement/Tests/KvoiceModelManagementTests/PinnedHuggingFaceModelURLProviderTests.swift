import Foundation
import KvoiceDomain
import XCTest
@testable import KvoiceModelManagement

/// The manifest describes the installed layout, not the published one. These
/// URLs were verified against huggingface.co on 2026-09-13 by downloading each
/// file and matching the manifest's SHA-256; the pre-fix provider appended the
/// installed path verbatim and every file 404'd.
final class PinnedHuggingFaceModelURLProviderTests: XCTestCase {
    private let provider = PinnedHuggingFaceModelURLProvider()

    private func manifest() -> ModelManifest {
        ModelManifest(
            schemaVersion: 1,
            modelID: KvoiceManagedModel.modelID,
            family: KvoiceManagedModel.family,
            format: KvoiceManagedModel.format,
            workingSpaceBytes: 1,
            source: ModelManifestSource(
                repository: KvoiceManagedModel.repository,
                revision: KvoiceManagedModel.revision,
                subdirectory: KvoiceManagedModel.subdirectory
            ),
            runtimeCompatibility: ModelRuntimeCompatibility(
                swiftPackage: KvoiceManagedModel.runtimePackage,
                exactVersion: KvoiceManagedModel.runtimeVersion
            ),
            tokenizer: ModelTokenizer(relativeRoot: "tokenizer"),
            files: []
        )
    }

    private func descriptor(_ path: String) -> ModelFileDescriptor {
        ModelFileDescriptor(path: path, bytes: 1, sha256: String(repeating: "0", count: 64), role: .otherRequired)
    }

    func testModelFilesResolveDirectlyUnderThePackageSubdirectory() throws {
        let url = try provider.url(
            for: descriptor("model/AudioEncoder.mlmodelc/weights/weight.bin"),
            manifest: manifest()
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/"
                + "04e5c42d80a522518023727e8c7e68d4bb391b28/"
                + "openai_whisper-large-v3-v20240930_turbo/AudioEncoder.mlmodelc/weights/weight.bin?download=true"
        )
    }

    func testTokenizerFilesResolveFromThePinnedUpstreamRepository() throws {
        let url = try provider.url(
            for: descriptor("tokenizer/models/openai/whisper-large-v3/tokenizer.json"),
            manifest: manifest()
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/openai/whisper-large-v3/resolve/"
                + "06f233fe06e710322aca913c1bc4249a0d71fce1/tokenizer.json?download=true"
        )
    }

    func testUnknownPrefixIsRejected() {
        XCTAssertThrowsError(try provider.url(for: descriptor("extras/readme.txt"), manifest: manifest()))
    }

    func testEveryBundledManifestEntryMapsToAPrefix() throws {
        // The shipped manifest must never contain a path the provider cannot
        // publish.
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Apps/KvoiceApp/ModelManifest.json")
        let bundled = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(bundled.files.count, 31)
        for file in bundled.files {
            XCTAssertNoThrow(try provider.url(for: file, manifest: bundled), file.path)
        }
    }
}
