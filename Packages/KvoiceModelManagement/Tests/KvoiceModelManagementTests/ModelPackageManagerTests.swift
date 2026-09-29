import CryptoKit
import Foundation
import KvoiceDomain
import KvoiceModelManagement
import KvoiceTranscription
import XCTest

final class ModelPackageManagerTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func testValidPackageDownloadsAtomicallyAndLoads() async throws {
        let fixture = try makeFixture()
        let loader = RecordingLoader()
        let downloader = FixtureDownloader()
        let manager = makeManager(fixture: fixture, loader: loader, downloader: downloader)

        try await manager.installRecommendedModel()

        let package = try await manager.verifiedPackage()
        XCTAssertEqual(package.ownership, .managedByKvoice)
        XCTAssertEqual(package.manifest, fixture.manifest)
        let loadCount = await loader.loadCount
        XCTAssertEqual(loadCount, 1)
        let managerState = await manager.state
        XCTAssertEqual(managerState, .ready(InstalledModelSummary(
            modelID: fixture.manifest.modelID,
            revision: fixture.manifest.source.revision,
            ownership: .managedByKvoice
        )))

        let stageEntries = try FileManager.default.contentsOfDirectory(
            at: ModelPackageManager.stagingRootURL(
                storageDirectoryURL: fixture.storageURL,
                modelID: fixture.manifest.modelID
            ),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(stageEntries.isEmpty, "staging must not retain a verified package")
    }

    func testOneByteCorruptionNeverBecomesReady() async throws {
        let fixture = try makeFixture()
        let corruptPath = fixture.sourceURL.appendingPathComponent("model/config.json")
        var corruptData = try Data(contentsOf: corruptPath)
        corruptData[0] ^= 0x01
        try corruptData.write(to: corruptPath, options: .atomic)
        let manager = makeManager(fixture: fixture)

        do {
            try await manager.installRecommendedModel()
            XCTFail("expected package verification failure")
        } catch {
            guard case ModelManagementError.packageCorrupt = error else {
                return XCTFail("expected package verification failure, got \(error)")
            }
        }
        let managerState = await manager.state
        XCTAssertFalse(isReady(managerState))
        let stateFailureName = await manager.stateFailureName()
        XCTAssertEqual(stateFailureName, "corrupt")
    }

    func testVerifierRejectsTraversalAndSymlink() throws {
        let fixture = try makeFixture()
        let traversalManifest = copyManifest(fixture.manifest, replacing: 0) { descriptor in
            ModelFileDescriptor(
                path: "model/../escape.bin",
                bytes: descriptor.bytes,
                sha256: descriptor.sha256,
                role: descriptor.role
            )
        }
        let traversalRoot = try writePackage(
            manifest: traversalManifest,
            files: fixture.files,
            at: makeTemporaryDirectory()
        )
        let traversalAnchor = try makeAnchor(for: traversalManifest)
        let traversalPackage = InstalledModelPackage(
            manifest: traversalManifest,
            packageURL: traversalRoot,
            modelFolderURL: traversalRoot.appendingPathComponent("model", isDirectory: true),
            tokenizerFolderURL: traversalRoot.appendingPathComponent("tokenizer", isDirectory: true),
            ownership: .externalReadOnly
        )
        XCTAssertThrowsError(try ModelPackageVerifier(trustedRelease: traversalAnchor).verify(traversalPackage)) { error in
            XCTAssertEqual(error as? ModelPackageVerificationError, .unsafePath("model/../escape.bin"))
        }

        let symlinkRoot = try writePackage(
            manifest: fixture.manifest,
            files: fixture.files,
            at: makeTemporaryDirectory()
        )
        let outside = makeTemporaryDirectory().appendingPathComponent("outside.bin")
        try Data("outside".utf8).write(to: outside, options: .atomic)
        let symlink = symlinkRoot.appendingPathComponent("model/symlink.bin")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        var symlinkManifest = fixture.manifest
        let first = symlinkManifest.files[0]
        symlinkManifest = replace(
            symlinkManifest,
            files: symlinkManifest.files + [ModelFileDescriptor(
                path: "model/symlink.bin",
                bytes: Int64(Data("outside".utf8).count),
                sha256: digest(Data("outside".utf8)),
                role: first.role
            )]
        )
        let symlinkAnchor = try makeAnchor(for: symlinkManifest)
        try writeManifest(symlinkManifest, at: symlinkRoot)
        let symlinkPackage = InstalledModelPackage(
            manifest: symlinkManifest,
            packageURL: symlinkRoot,
            modelFolderURL: symlinkRoot.appendingPathComponent("model", isDirectory: true),
            tokenizerFolderURL: symlinkRoot.appendingPathComponent("tokenizer", isDirectory: true),
            ownership: .externalReadOnly
        )
        XCTAssertThrowsError(try ModelPackageVerifier(trustedRelease: symlinkAnchor).verify(symlinkPackage)) { error in
            guard case .symlinkForbidden = error as? ModelPackageVerificationError else {
                return XCTFail("expected symlink rejection, got \(error)")
            }
        }
    }

    func testExternalPackageIsNeverDeleted() async throws {
        let fixture = try makeFixture()
        let manager = makeManager(fixture: fixture)
        let external = try writePackage(
            manifest: fixture.manifest,
            files: fixture.files,
            at: makeTemporaryDirectory()
        )

        try await manager.selectExternalPackage(at: external)
        do {
            try await manager.deleteManagedPackage()
            XCTFail("external package must not be deletable")
        } catch {
            XCTAssertEqual(error as? ModelManagementError, .externalPackageCannotBeDeleted)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: external.appendingPathComponent("model/config.json").path
        ))
        await manager.forgetExternalPackage()
        let managerState = await manager.state
        XCTAssertEqual(managerState, .absent)
    }

    func testCancelAndResumeUsesPausedStage() async throws {
        let fixture = try makeFixture()
        let downloader = BlockingFixtureDownloader(sourceRoot: fixture.sourceURL)
        let manager = makeManager(fixture: fixture, downloader: downloader)
        let installation = Task {
            try await manager.installRecommendedModel()
        }
        try await waitUntil { await downloader.started }

        await manager.cancelInstallation()
        do {
            try await installation.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? ModelManagementError, .cancelled)
        }
        if case .downloadPaused(let resumableBytes) = await manager.state {
            XCTAssertNotNil(resumableBytes)
        } else {
            XCTFail("expected a resumable paused state")
        }

        await downloader.allowDownloads()
        try await manager.resumeInstallation()
        let managerState = await manager.state
        XCTAssertTrue(isReady(managerState))
    }

    func testDeletionIsBusyDuringInferenceAndUnloadsBeforeRemoval() async throws {
        let fixture = try makeFixture()
        let loader = RecordingLoader()
        let manager = makeManager(fixture: fixture, loader: loader)
        try await manager.installRecommendedModel()
        let jobID = UUID()
        try await manager.beginInference(jobID: jobID)

        do {
            try await manager.deleteManagedPackage()
            XCTFail("deletion must be busy-gated during inference")
        } catch {
            XCTAssertEqual(error as? ModelManagementError, .busy)
        }
        await manager.endInference(jobID: jobID)
        try await manager.deleteManagedPackage()
        let unloadCount = await loader.unloadCount
        XCTAssertEqual(unloadCount, 1)
        let managerState = await manager.state
        XCTAssertEqual(managerState, .absent)
    }

    private struct Fixture {
        let storageURL: URL
        let sourceURL: URL
        let manifest: ModelManifest
        let files: [(String, Data)]
    }

    private func makeFixture() throws -> Fixture {
        let storageURL = makeTemporaryDirectory()
        let sourceURL = makeTemporaryDirectory()
        let contents: [(String, Data)] = [
            ("model/AudioEncoder.mlmodelc/weights.bin", Data("audio".utf8)),
            ("model/MelSpectrogram.mlmodelc/weights.bin", Data("mel".utf8)),
            ("model/TextDecoder.mlmodelc/weights.bin", Data("decoder".utf8)),
            ("model/TextDecoderContextPrefill.mlmodelc/weights.bin", Data("prefill".utf8)),
            ("model/config.json", Data("{\"config\":true}".utf8)),
            ("model/generation_config.json", Data("{\"generation\":true}".utf8)),
            ("tokenizer/models/openai/whisper-large-v3/tokenizer.json", Data("{}".utf8)),
            ("tokenizer/models/openai/whisper-large-v3/tokenizer_config.json", Data("{}".utf8))
        ]
        for (path, data) in contents {
            let url = sourceURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
        let files = contents.map { path, data in
            ModelFileDescriptor(
                path: path,
                bytes: Int64(data.count),
                sha256: digest(data),
                role: role(for: path)
            )
        }
        let manifest = ModelManifest(
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
            files: files
        )
        return Fixture(storageURL: storageURL, sourceURL: sourceURL, manifest: manifest, files: contents)
    }

    private func makeManager(
        fixture: Fixture,
        loader: any ModelRuntimeLoader = RecordingLoader(),
        downloader: (any ModelDownloadClient)? = nil
    ) -> ModelPackageManager {
        let selectedDownloader = downloader ?? FixtureDownloader()
        return ModelPackageManager(
            trustedRelease: try! makeAnchor(for: fixture.manifest),
            storageDirectoryURL: fixture.storageURL,
            runtimeLoader: loader,
            downloader: selectedDownloader,
            urlProvider: FixtureURLProvider(sourceRoot: fixture.sourceURL)
        )
    }

    private func makeAnchor(for manifest: ModelManifest) throws -> WhisperModelReleaseTrustAnchor {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        return try WhisperModelReleaseTrustAnchor(
            manifestData: data,
            manifestSHA256: digest(data)
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kvoice-model-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func writePackage(
        manifest: ModelManifest,
        files: [(String, Data)],
        at root: URL
    ) throws -> URL {
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
        try writeManifest(manifest, at: root)
        return root
    }

    private func writeManifest(_ manifest: ModelManifest, at root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(
            to: root.appendingPathComponent("ModelManifest.json"),
            options: .atomic
        )
    }

    private func copyManifest(
        _ manifest: ModelManifest,
        replacing index: Int,
        with transform: (ModelFileDescriptor) -> ModelFileDescriptor
    ) -> ModelManifest {
        var files = manifest.files
        files[index] = transform(files[index])
        return replace(manifest, files: files)
    }

    private func replace(_ manifest: ModelManifest, files: [ModelFileDescriptor]) -> ModelManifest {
        ModelManifest(
            schemaVersion: manifest.schemaVersion,
            modelID: manifest.modelID,
            family: manifest.family,
            format: manifest.format,
            workingSpaceBytes: manifest.workingSpaceBytes,
            source: manifest.source,
            runtimeCompatibility: manifest.runtimeCompatibility,
            tokenizer: manifest.tokenizer,
            files: files
        )
    }

    private static func role(for path: String) -> ModelArtifactRole {
        if path.hasPrefix("tokenizer/") { return .tokenizer }
        switch path.split(separator: "/").dropFirst().first.map(String.init) {
        case "AudioEncoder.mlmodelc": return .audioEncoder
        case "MelSpectrogram.mlmodelc": return .melSpectrogram
        case "TextDecoder.mlmodelc": return .textDecoder
        case "TextDecoderContextPrefill.mlmodelc": return .decoderPrefill
        default: return .configuration
        }
    }

    private func role(for path: String) -> ModelArtifactRole { Self.role(for: path) }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isReady(_ state: ModelLifecycleState) -> Bool {
        if case .ready = state { return true }
        return false
    }

    /// The 30 s deadline is a hang guard, not a timing assumption: a
    /// passing condition returns at once. (It was 100 polls of 10 ms, about
    /// a second, which a loaded runner can outlast.)
    private func waitUntil(
        timeout: Duration = .seconds(30),
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition did not become true within \(timeout)")
    }
}

private struct FixtureURLProvider: ModelDownloadURLProviding {
    let sourceRoot: URL

    func url(for descriptor: ModelFileDescriptor, manifest: ModelManifest) throws -> URL {
        try ModelRelativePath.url(for: descriptor.path, under: sourceRoot)
    }
}

private actor FixtureDownloader: ModelDownloadClient {
    func download(
        from url: URL,
        to destination: URL,
        resumeData: Data?,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        let data = try Data(contentsOf: url)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        progress(Int64(data.count), Int64(data.count))
        try data.write(to: destination, options: .atomic)
    }

    func cancel() async {}
    func latestResumeData() async -> Data? { nil }
}

private actor BlockingFixtureDownloader: ModelDownloadClient {
    let sourceRoot: URL
    private(set) var started = false
    private var blocked = true
    private var cancellation: CheckedContinuation<Void, Error>?
    private var resume: Data?

    init(sourceRoot: URL) {
        self.sourceRoot = sourceRoot
    }

    func download(
        from url: URL,
        to destination: URL,
        resumeData: Data?,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        if blocked {
            started = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                cancellation = continuation
            }
        }
        let data = try Data(contentsOf: url)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        progress(Int64(data.count), Int64(data.count))
        try data.write(to: destination, options: .atomic)
    }

    func cancel() async {
        guard let cancellation else { return }
        resume = Data("resume".utf8)
        self.cancellation = nil
        cancellation.resume(throwing: CancellationError())
    }

    func latestResumeData() async -> Data? { resume }

    func allowDownloads() {
        blocked = false
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

private extension ModelPackageManager {
    func stateFailureName() -> String {
        switch state {
        case .corrupt: return "corrupt"
        case .error: return "error"
        default: return "other"
        }
    }
}
