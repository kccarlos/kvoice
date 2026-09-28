import CryptoKit
import XCTest
@testable import KvoiceDomain
@testable import KvoiceModelManagement
@testable import KvoiceTranscription

/// `refresh()` runs on app launch *and* on every app activation. It used to
/// re-verify and reload unconditionally, and it only ever considered the
/// managed location, so a ready model dropped back to Not Ready whenever the
/// user switched away and came back.
final class ModelPackageManagerRefreshTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
        super.tearDown()
    }

    func testRefreshDoesNotReloadAnAlreadyResidentManagedPackage() async throws {
        let storageURL = makeTemporaryDirectory()
        let manifest = try makeManifest()
        let anchor = try makeAnchor(for: manifest)
        _ = try writePackage(
            manifest: manifest,
            at: managedPackageURL(in: storageURL, manifest: manifest)
        )
        let loader = RecordingLoader()
        let manager = ModelPackageManager(
            trustedRelease: anchor,
            storageDirectoryURL: storageURL,
            runtimeLoader: loader
        )

        await manager.refresh()
        let firstLoadCount = await loader.loadCount
        XCTAssertEqual(firstLoadCount, 1, "first refresh must load the package")
        let stateAfterFirstRefresh = await manager.state
        XCTAssertEqual(stateAfterFirstRefresh, .ready(InstalledModelSummary(
            modelID: manifest.modelID,
            revision: manifest.source.revision,
            ownership: .managedByKvoice
        )))

        // Two further app activations.
        await manager.refresh()
        await manager.refresh()

        let finalLoadCount = await loader.loadCount
        XCTAssertEqual(
            finalLoadCount,
            1,
            "refresh must not re-verify and recompile a resident model"
        )
        let finalUnloadCount = await loader.unloadCount
        XCTAssertEqual(finalUnloadCount, 0)
    }

    func testRefreshKeepsALoadedExternalPackage() async throws {
        let storageURL = makeTemporaryDirectory()
        let manifest = try makeManifest()
        let anchor = try makeAnchor(for: manifest)
        let external = try writePackage(
            manifest: manifest,
            at: makeTemporaryDirectory().appendingPathComponent("pkg", isDirectory: true)
        )
        let loader = RecordingLoader()
        let manager = ModelPackageManager(
            trustedRelease: anchor,
            storageDirectoryURL: storageURL,
            runtimeLoader: loader
        )

        try await manager.selectExternalPackage(at: external)
        let readyState = ModelLifecycleState.ready(InstalledModelSummary(
            modelID: manifest.modelID,
            revision: manifest.source.revision,
            ownership: .externalReadOnly
        ))
        let stateBeforeRefresh = await manager.state
        XCTAssertEqual(stateBeforeRefresh, readyState)

        await manager.refresh()

        let stateAfterRefresh = await manager.state
        XCTAssertEqual(
            stateAfterRefresh,
            readyState,
            "an external selection must survive app activation"
        )
        let loadCount = await loader.loadCount
        XCTAssertEqual(loadCount, 1)
        let unloadCount = await loader.unloadCount
        XCTAssertEqual(unloadCount, 0)
    }

    func testRefreshFailsClosedWhenAnExternalPackageDisappears() async throws {
        let storageURL = makeTemporaryDirectory()
        let manifest = try makeManifest()
        let anchor = try makeAnchor(for: manifest)
        let external = try writePackage(
            manifest: manifest,
            at: makeTemporaryDirectory().appendingPathComponent("pkg", isDirectory: true)
        )
        let loader = RecordingLoader()
        let manager = ModelPackageManager(
            trustedRelease: anchor,
            storageDirectoryURL: storageURL,
            runtimeLoader: loader
        )

        try await manager.selectExternalPackage(at: external)
        try FileManager.default.removeItem(at: external)

        await manager.refresh()

        // Spec J.4: a missing external folder is an error state, never a
        // silent Absent, so the user is told to reselect, restore, or forget.
        let finalState = await manager.state
        guard case let .error(failure) = finalState else {
            return XCTFail("expected a fail-closed error, got \(String(describing: finalState))")
        }
        XCTAssertEqual(failure.code, "MODEL-PATH-UNREADABLE")
        let unloadCount = await loader.unloadCount
        XCTAssertEqual(
            unloadCount,
            1,
            "a vanished external package must unload the runtime"
        )
    }

    // MARK: Fixtures

    private static let contents: [(String, Data)] = [
        ("model/config.json", Data("{\"a\":1}".utf8)),
        ("model/generation_config.json", Data("{\"b\":2}".utf8)),
        ("model/AudioEncoder.mlmodelc/coremldata.bin", Data("audio".utf8)),
        ("model/MelSpectrogram.mlmodelc/coremldata.bin", Data("mel".utf8)),
        ("model/TextDecoder.mlmodelc/coremldata.bin", Data("decoder".utf8)),
        ("model/TextDecoderContextPrefill.mlmodelc/coremldata.bin", Data("prefill".utf8)),
        ("tokenizer/tokenizer.json", Data("{\"t\":1}".utf8))
    ]

    private func makeManifest() throws -> ModelManifest {
        ModelManifest(
            schemaVersion: 1,
            modelID: KvoiceManagedModel.modelID,
            family: KvoiceManagedModel.family,
            format: KvoiceManagedModel.format,
            workingSpaceBytes: 1_073_741_824,
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
            files: Self.contents.map { path, data in
                ModelFileDescriptor(
                    path: path,
                    bytes: Int64(data.count),
                    sha256: Self.digest(data),
                    role: Self.role(for: path)
                )
            }
        )
    }

    private func managedPackageURL(in storageURL: URL, manifest: ModelManifest) -> URL {
        storageURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(manifest.modelID, isDirectory: true)
            .appendingPathComponent(manifest.source.revision, isDirectory: true)
    }

    private static func role(for path: String) -> ModelArtifactRole {
        if path.hasPrefix("tokenizer/") { return .tokenizer }
        if path.hasSuffix("config.json") { return .configuration }
        if path.contains("AudioEncoder") { return .audioEncoder }
        if path.contains("MelSpectrogram") { return .melSpectrogram }
        if path.contains("TextDecoderContextPrefill") { return .decoderPrefill }
        if path.contains("TextDecoder") { return .textDecoder }
        return .otherRequired
    }

    private func makeAnchor(for manifest: ModelManifest) throws -> WhisperModelReleaseTrustAnchor {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        return try WhisperModelReleaseTrustAnchor(
            manifestData: data,
            manifestSHA256: Self.digest(data)
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kvoice-refresh-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    @discardableResult
    private func writePackage(manifest: ModelManifest, at root: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(manifest).write(
            to: root.appendingPathComponent("ModelManifest.json")
        )
        for (path, data) in Self.contents {
            let fileURL = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL)
        }
        return root
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private actor RecordingLoader: ModelRuntimeLoader {
    private(set) var loadCount = 0
    private(set) var unloadCount = 0

    func load(_ package: InstalledModelPackage) async throws {
        loadCount += 1
    }

    func unload() async {
        unloadCount += 1
    }
}
