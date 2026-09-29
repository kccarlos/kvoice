import CryptoKit
import Foundation
import KvoiceDomain
import KvoiceModelManagement
import KvoiceTranscription
import XCTest

/// Shared fixtures for the lifecycle tests (space gate, staging cleanup,
/// staged deletion, external restore). The older test files keep their own
/// private copies; this one is the place for new tests.
struct ModelLifecycleFixture {
    let storageURL: URL
    let sourceURL: URL
    let manifest: ModelManifest
    let anchor: WhisperModelReleaseTrustAnchor
    let files: [(String, Data)]

    static let contents: [(String, Data)] = [
        ("model/AudioEncoder.mlmodelc/weights.bin", Data("audio".utf8)),
        ("model/MelSpectrogram.mlmodelc/weights.bin", Data("mel".utf8)),
        ("model/TextDecoder.mlmodelc/weights.bin", Data("decoder".utf8)),
        ("model/TextDecoderContextPrefill.mlmodelc/weights.bin", Data("prefill".utf8)),
        ("model/config.json", Data("{\"config\":true}".utf8)),
        ("model/generation_config.json", Data("{\"generation\":true}".utf8)),
        ("tokenizer/models/openai/whisper-large-v3/tokenizer.json", Data("{}".utf8)),
        ("tokenizer/models/openai/whisper-large-v3/tokenizer_config.json", Data("{}".utf8))
    ]

    static var totalBytes: Int64 {
        contents.reduce(0) { $0 + Int64($1.1.count) }
    }

    /// A second release the validator knows (ADR-017's "Standard" package),
    /// for tests that need two distinct models in one storage directory.
    static let standardRelease = (
        modelID: "whisper-large-v3-turbo-coreml-632mb",
        revision: KvoiceManagedModel.revision,
        subdirectory: "openai_whisper-large-v3-v20240930_turbo_632MB"
    )

    static func make(
        in tracker: inout [URL],
        workingSpaceBytes: Int64 = 1_073_741_824,
        modelID: String = KvoiceManagedModel.modelID,
        revision: String = KvoiceManagedModel.revision,
        subdirectory: String = KvoiceManagedModel.subdirectory,
        storageURL presetStorageURL: URL? = nil,
        contentSalt: String = ""
    ) throws -> ModelLifecycleFixture {
        let storageURL = presetStorageURL ?? makeTemporaryDirectory(in: &tracker)
        let sourceURL = makeTemporaryDirectory(in: &tracker)
        let salted = Self.contents.map { path, data in (path, data + Data(contentSalt.utf8)) }
        for (path, data) in salted {
            let url = sourceURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
        let manifest = ModelManifest(
            schemaVersion: 1,
            modelID: modelID,
            family: KvoiceManagedModel.family,
            format: KvoiceManagedModel.format,
            workingSpaceBytes: workingSpaceBytes,
            source: ModelManifestSource(
                repository: KvoiceManagedModel.repository,
                revision: revision,
                subdirectory: subdirectory
            ),
            runtimeCompatibility: ModelRuntimeCompatibility(
                swiftPackage: KvoiceManagedModel.runtimePackage,
                exactVersion: KvoiceManagedModel.runtimeVersion
            ),
            tokenizer: ModelTokenizer(relativeRoot: "tokenizer"),
            files: salted.map { path, data in
                ModelFileDescriptor(
                    path: path,
                    bytes: Int64(data.count),
                    sha256: digest(data),
                    role: role(for: path)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifest)
        let anchor = try WhisperModelReleaseTrustAnchor(
            manifestData: manifestData,
            manifestSHA256: digest(manifestData)
        )
        return ModelLifecycleFixture(
            storageURL: storageURL,
            sourceURL: sourceURL,
            manifest: manifest,
            anchor: anchor,
            files: salted
        )
    }

    var managedPackageURL: URL {
        storageURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(manifest.modelID, isDirectory: true)
            .appendingPathComponent(manifest.source.revision, isDirectory: true)
    }

    /// ADR-017: staging is namespaced by model ID.
    var stagingRootURL: URL {
        ModelPackageManager.stagingRootURL(storageDirectoryURL: storageURL, modelID: manifest.modelID)
    }

    var readySummary: InstalledModelSummary {
        InstalledModelSummary(
            modelID: manifest.modelID,
            revision: manifest.source.revision,
            ownership: .managedByKvoice
        )
    }

    var externalReadySummary: InstalledModelSummary {
        InstalledModelSummary(
            modelID: manifest.modelID,
            revision: manifest.source.revision,
            ownership: .externalReadOnly
        )
    }

    func makeManager(
        loader: any ModelRuntimeLoader = LifecycleRecordingLoader(),
        downloader: (any ModelDownloadClient)? = nil,
        availableBytes: Int64? = Int64.max,
        capacity: (any ModelVolumeCapacityProviding)? = nil,
        clock: @escaping ModelClock = { Date() },
        appVersion: String = "test-build"
    ) -> ModelPackageManager {
        ModelPackageManager(
            trustedRelease: anchor,
            storageDirectoryURL: storageURL,
            runtimeLoader: loader,
            downloader: downloader ?? LifecycleFixtureDownloader(),
            urlProvider: LifecycleFixtureURLProvider(sourceRoot: sourceURL),
            volumeCapacity: capacity ?? FixedVolumeCapacityProvider(availableBytes: availableBytes),
            clock: clock,
            appVersion: appVersion
        )
    }

    /// Writes a complete, verifiable package (manifest plus every file) at
    /// `root`, which is created if needed.
    @discardableResult
    func writePackage(at root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(
            to: root.appendingPathComponent("ModelManifest.json"),
            options: .atomic
        )
        return root
    }

    static func makeTemporaryDirectory(in tracker: inout [URL]) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kvoice-lifecycle-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tracker.append(url)
        return url
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func role(for path: String) -> ModelArtifactRole {
        if path.hasPrefix("tokenizer/") { return .tokenizer }
        switch path.split(separator: "/").dropFirst().first.map(String.init) {
        case "AudioEncoder.mlmodelc": return .audioEncoder
        case "MelSpectrogram.mlmodelc": return .melSpectrogram
        case "TextDecoder.mlmodelc": return .textDecoder
        case "TextDecoderContextPrefill.mlmodelc": return .decoderPrefill
        default: return .configuration
        }
    }
}

/// A capacity answer that a test can change between operations.
final class MutableVolumeCapacityProvider: ModelVolumeCapacityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64?

    init(availableBytes: Int64?) {
        value = availableBytes
    }

    var availableBytes: Int64? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    func availableCapacity(forVolumeContaining url: URL) -> Int64? {
        availableBytes
    }
}

struct LifecycleFixtureURLProvider: ModelDownloadURLProviding {
    let sourceRoot: URL

    func url(for descriptor: ModelFileDescriptor, manifest: ModelManifest) throws -> URL {
        try ModelRelativePath.url(for: descriptor.path, under: sourceRoot)
    }
}

/// Copies fixture files straight from the source tree; records how many
/// downloads were requested so a "starts no download" assertion is exact.
actor LifecycleFixtureDownloader: ModelDownloadClient {
    private(set) var downloadCount = 0
    /// When set, the download at this zero-based call index throws instead.
    var failAtCallIndex: Int?
    /// When set, the download at this zero-based call index pauses until
    /// `openGate()` (or the task is cancelled), so a `.downloading`
    /// activity is provably in flight while a test calls something else.
    private var holdAtCallIndex: Int?
    private var isGateOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// How many downloads reached the hold.
    private(set) var heldCount = 0

    func setFailAtCallIndex(_ index: Int?) {
        failAtCallIndex = index
    }

    func setHoldAtCallIndex(_ index: Int?) {
        holdAtCallIndex = index
    }

    func openGate() {
        isGateOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    /// Returns once `count` downloads have reached the hold (never real
    /// time; fails after `testYieldBudget` yields).
    func waitUntilHeld(count: Int = 1, file: StaticString = #filePath, line: UInt = #line) async {
        var yields = 0
        while heldCount < count {
            yields += 1
            if yields > testYieldBudget {
                return XCTFail("waitUntilHeld: `heldCount < count` still held after \(testYieldBudget) yields; heldCount = \(heldCount)", file: file, line: line)
            }
            await Task.yield()
        }
    }

    func download(
        from url: URL,
        to destination: URL,
        resumeData: Data?,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        let index = downloadCount
        downloadCount += 1
        if index == failAtCallIndex {
            throw URLError(.networkConnectionLost)
        }
        if index == holdAtCallIndex, !isGateOpen {
            heldCount += 1
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if isGateOpen { continuation.resume() } else { waiters.append(continuation) }
                }
            } onCancel: {
                Task { await self.openGate() }
            }
            try Task.checkCancellation()
        }
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

actor LifecycleRecordingLoader: ModelRuntimeLoader {
    private(set) var loadCount = 0
    private(set) var unloadCount = 0
    private(set) var loadedPackageURLs: [URL] = []

    func load(_ package: InstalledModelPackage) async throws {
        loadCount += 1
        loadedPackageURLs.append(package.packageURL)
    }

    func unload() async {
        unloadCount += 1
    }
}

extension XCTestCase {
    /// The 30 s deadline is a hang guard, not a timing assumption: a
    /// passing condition returns at once.
    func waitUntilTrue(
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
