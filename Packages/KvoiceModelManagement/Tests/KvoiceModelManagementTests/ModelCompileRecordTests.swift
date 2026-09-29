import Foundation
import KvoiceDomain
import KvoiceModelManagement
import KvoiceTestSupport
import XCTest

/// 2026-09-29 (owner decision 2): the first Core ML build of a model on this
/// Mac is `.optimizing` — "first time only, a few minutes" — and a load the
/// compile record has seen is plain `.loading`. The record is written only
/// for a load that really reached the engine, keyed by model, revision and
/// compute units.
final class ModelCompileRecordTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    private struct Fixture {
        let storageURL: URL
        let standard: ModelLifecycleFixture
        let other: ModelLifecycleFixture
        let loaded: LoadedSpeechModelCatalog

        func key(_ fixture: ModelLifecycleFixture, _ units: SpeechComputeUnits = .default) -> ModelCompileKey {
            ModelCompileKey(
                modelID: fixture.manifest.modelID,
                revision: fixture.manifest.source.revision,
                computeUnits: units
            )
        }
    }

    private func makeFixture() throws -> Fixture {
        let storageURL = ModelLifecycleFixture.makeTemporaryDirectory(in: &temporaryURLs)
        let standard = try ModelLifecycleFixture.make(
            in: &temporaryURLs,
            modelID: ModelLifecycleFixture.standardRelease.modelID,
            revision: ModelLifecycleFixture.standardRelease.revision,
            subdirectory: ModelLifecycleFixture.standardRelease.subdirectory,
            storageURL: storageURL,
            contentSalt: "-standard"
        )
        let other = try ModelLifecycleFixture.make(in: &temporaryURLs, storageURL: storageURL)
        let catalog = SpeechModelCatalog(entries: [
            entry(for: standard, recommended: true),
            entry(for: other, recommended: false)
        ])
        let loaded = LoadedSpeechModelCatalog(
            catalog: catalog,
            anchors: [standard.manifest.modelID: standard.anchor, other.manifest.modelID: other.anchor]
        )
        return Fixture(storageURL: storageURL, standard: standard, other: other, loaded: loaded)
    }

    private func entry(for fixture: ModelLifecycleFixture, recommended: Bool) -> SpeechModelCatalogEntry {
        SpeechModelCatalogEntry(
            id: fixture.manifest.modelID,
            displayName: "Whisper v3 Turbo",
            variantName: recommended ? "Standard" : "Other",
            family: fixture.manifest.family,
            runtime: .whisperKitCoreML,
            hosting: .onDevice,
            supportsStreaming: true,
            supportsBatch: true,
            downloadBytes: ModelLifecycleFixture.totalBytes,
            languageSummary: "99 languages",
            summary: "fixture",
            isRecommended: recommended,
            revision: fixture.manifest.source.revision,
            manifestResource: fixture.manifest.modelID,
            manifestSHA256: fixture.anchor.manifestSHA256
        )
    }

    private func makeLibrary(
        _ fixture: Fixture,
        engine: any TranscriptionEngine,
        record: (any ModelCompileRecording)?,
        diagnostics: (any DiagnosticLogging)? = nil
    ) throws -> SpeechModelLibrary {
        let roots = [
            fixture.standard.manifest.modelID: fixture.standard.sourceURL,
            fixture.other.manifest.modelID: fixture.other.sourceURL
        ]
        return try SpeechModelLibrary(
            loaded: fixture.loaded,
            storageDirectoryURL: fixture.storageURL,
            engine: engine,
            makeDownloader: { LifecycleFixtureDownloader() },
            urlProvider: PerModelURLProvider(roots: roots),
            volumeCapacity: FixedVolumeCapacityProvider(availableBytes: Int64.max),
            appVersion: "test-build",
            diagnosticLogger: diagnostics,
            compileRecord: record
        )
    }

    /// Runs the default model's install with the engine's load held open,
    /// and returns the library's state while Core ML is "building".
    private func stateDuringTheDefaultLoad(
        _ library: SpeechModelLibrary,
        engine: HeldLoadEngine
    ) async throws -> ModelLifecycleState {
        await engine.hold()
        let install = Task { try await library.installRecommendedModel() }
        await engine.waitUntilLoading()
        let midLoad = await library.state
        await engine.release()
        try await install.value
        return midLoad
    }

    func testTheFirstLoadOfTheDefaultIsOptimizingAndIsRecordedWithScalarEvents() async throws {
        let fixture = try makeFixture()
        let engine = HeldLoadEngine()
        let record = InMemoryModelCompileRecord()
        let diagnostics = EventRecorder()
        let library = try makeLibrary(fixture, engine: engine, record: record, diagnostics: diagnostics)

        let midLoad = try await stateDuringTheDefaultLoad(library, engine: engine)

        XCTAssertEqual(midLoad, .optimizing)
        let state = await library.state
        XCTAssertEqual(state, .ready(fixture.standard.readySummary))
        let compiled = await record.compiled
        XCTAssertEqual(compiled, [fixture.key(fixture.standard)])
        let events = await diagnostics.events
        let started = events.filter { $0.name == .modelLoadStarted }
        let completed = events.filter { $0.name == .modelLoadCompleted }
        XCTAssertEqual(started.map { $0.attributes.reason?.rawValue }, ["firstCompile"])
        XCTAssertEqual(completed.map { $0.attributes.reason?.rawValue }, ["firstCompile"])
        XCTAssertEqual(completed.first?.result, .success)
        XCTAssertNotNil(completed.first?.durationMilliseconds)
        XCTAssertEqual(completed.first?.attributes.modelID?.rawValue, fixture.standard.manifest.modelID)
    }

    /// swift-reviewer 2026-09-29: a failed engine load closes the pair with
    /// a failure line, records no compile, and the error still reaches the
    /// manager.
    func testAFailedLoadLogsAFailureAndRecordsNothing() async throws {
        let fixture = try makeFixture()
        let engine = HeldLoadEngine()
        await engine.failLoads()
        let record = InMemoryModelCompileRecord()
        let diagnostics = EventRecorder()
        let library = try makeLibrary(fixture, engine: engine, record: record, diagnostics: diagnostics)

        try? await library.installRecommendedModel()

        let state = await library.state
        if case .error = state {} else { XCTFail("the manager still sees the failure, got \(state)") }
        let compiled = await record.compiled
        XCTAssertTrue(compiled.isEmpty)
        let completed = await diagnostics.events.filter { $0.name == .modelLoadCompleted }
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.result, .failure)
        XCTAssertEqual(completed.first?.errorCode, .modelLoadFailed)
        XCTAssertEqual(completed.first?.attributes.reason?.rawValue, "firstCompileFailed")
        XCTAssertEqual(completed.first?.attributes.site?.rawValue, "engineLoad")
    }

    func testALoadTheRecordHasSeenIsPlainLoadingWithCachedEvents() async throws {
        let fixture = try makeFixture()
        let engine = HeldLoadEngine()
        let record = InMemoryModelCompileRecord(compiled: [fixture.key(fixture.standard)])
        let diagnostics = EventRecorder()
        let library = try makeLibrary(fixture, engine: engine, record: record, diagnostics: diagnostics)

        let midLoad = try await stateDuringTheDefaultLoad(library, engine: engine)

        XCTAssertEqual(midLoad, .loading, "a cached load never claims to be the first time")
        let reasons = await diagnostics.events
            .filter { $0.name == .modelLoadStarted }
            .map { $0.attributes.reason?.rawValue }
        XCTAssertEqual(reasons, ["cached"])
    }

    func testComputeUnitsArePartOfTheKey() async throws {
        let fixture = try makeFixture()
        let engine = HeldLoadEngine()
        // Compiled under the default units only.
        let record = InMemoryModelCompileRecord(compiled: [fixture.key(fixture.standard)])
        let library = try makeLibrary(fixture, engine: engine, record: record)
        try await library.setComputeUnits(.cpuOnly)

        let midLoad = try await stateDuringTheDefaultLoad(library, engine: engine)

        XCTAssertEqual(midLoad, .optimizing, "another compute-unit choice is another Core ML build")
        let compiled = await record.compiled
        XCTAssertTrue(compiled.contains(fixture.key(fixture.standard, .cpuOnly)))
    }

    func testAComputeUnitReloadOfTheResidentModelIsRecorded() async throws {
        let fixture = try makeFixture()
        let engine = HeldLoadEngine()
        let record = InMemoryModelCompileRecord()
        let library = try makeLibrary(fixture, engine: engine, record: record)
        try await library.installRecommendedModel()

        try await library.setComputeUnits(.all)

        let compiled = await record.compiled
        XCTAssertTrue(compiled.contains(fixture.key(fixture.standard, .all)))
    }

    func testANonDefaultInstallNeverReachesTheEngineAndRecordsNothing() async throws {
        let fixture = try makeFixture()
        let engine = HeldLoadEngine()
        let record = InMemoryModelCompileRecord()
        let library = try makeLibrary(fixture, engine: engine, record: record)

        try await library.install(fixture.other.manifest.modelID)

        let compiled = await record.compiled
        XCTAssertTrue(compiled.isEmpty, "a verified-only package compiled nothing")
        let state = await library.state(of: fixture.other.manifest.modelID)
        XCTAssertEqual(state, .ready(fixture.other.readySummary))
    }

    func testWithoutARecordEveryLoadIsPlainLoading() async throws {
        let fixture = try makeFixture()
        let engine = HeldLoadEngine()
        let library = try makeLibrary(fixture, engine: engine, record: nil)

        let midLoad = try await stateDuringTheDefaultLoad(library, engine: engine)

        XCTAssertEqual(midLoad, .loading)
    }

    // MARK: File store

    func testTheFileRecordSurvivesANewInstanceOnTheSameBuild() async throws {
        let directory = ModelLifecycleFixture.makeTemporaryDirectory(in: &temporaryURLs)
        let key = ModelCompileKey(modelID: "m", revision: "r", computeUnits: .neuralEngineAndCPU)
        let first = FileModelCompileRecord(directoryURL: directory, systemBuild: "Version 27.0 (Build A)", hardwareModel: "Mac16,1")
        let before = await first.hasCompiled(key)
        XCTAssertFalse(before)
        await first.recordCompiled(key)

        let second = FileModelCompileRecord(directoryURL: directory, systemBuild: "Version 27.0 (Build A)", hardwareModel: "Mac16,1")
        let after = await second.hasCompiled(key)
        XCTAssertTrue(after)
        let otherUnits = await second.hasCompiled(
            ModelCompileKey(modelID: "m", revision: "r", computeUnits: .cpuOnly)
        )
        XCTAssertFalse(otherUnits)
    }

    func testAnOSUpdateMakesEveryModelAFirstCompileAgain() async throws {
        let directory = ModelLifecycleFixture.makeTemporaryDirectory(in: &temporaryURLs)
        let key = ModelCompileKey(modelID: "m", revision: "r", computeUnits: .neuralEngineAndCPU)
        await FileModelCompileRecord(directoryURL: directory, systemBuild: "Build A", hardwareModel: "Mac16,1").recordCompiled(key)

        let updated = FileModelCompileRecord(directoryURL: directory, systemBuild: "Build B", hardwareModel: "Mac16,1")
        let compiled = await updated.hasCompiled(key)
        XCTAssertFalse(compiled)
    }

    /// swift-reviewer 2026-09-29: a home folder migrated to another Mac has
    /// compiled nothing there; and the file never goes into a backup.
    func testAnotherMacModelIsAFirstCompileAndTheFileIsExcludedFromBackup() async throws {
        let directory = ModelLifecycleFixture.makeTemporaryDirectory(in: &temporaryURLs)
        let key = ModelCompileKey(modelID: "m", revision: "r", computeUnits: .neuralEngineAndCPU)
        await FileModelCompileRecord(directoryURL: directory, systemBuild: "Build A", hardwareModel: "Mac16,1").recordCompiled(key)

        let otherMac = FileModelCompileRecord(directoryURL: directory, systemBuild: "Build A", hardwareModel: "Mac14,2")
        let compiled = await otherMac.hasCompiled(key)
        XCTAssertFalse(compiled)

        let values = try directory.appendingPathComponent(FileModelCompileRecord.fileName)
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertFalse(FileModelCompileRecord.currentHardwareModel().isEmpty)
    }

    func testAnUnreadableFileIsNothingCompiled() async throws {
        let directory = ModelLifecycleFixture.makeTemporaryDirectory(in: &temporaryURLs)
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent(FileModelCompileRecord.fileName)
        )
        let key = ModelCompileKey(modelID: "m", revision: "r", computeUnits: .neuralEngineAndCPU)
        let record = FileModelCompileRecord(directoryURL: directory, systemBuild: "Build A", hardwareModel: "Mac16,1")
        let compiled = await record.hasCompiled(key)
        XCTAssertFalse(compiled)
        await record.recordCompiled(key)
        let reread = await FileModelCompileRecord(directoryURL: directory, systemBuild: "Build A", hardwareModel: "Mac16,1").hasCompiled(key)
        XCTAssertTrue(reread, "the next write replaces the unreadable file")
    }
}

/// Holds `load(_:)` open while the test looks at the library's state —
/// the stand-in for a multi-minute Core ML build. Never real time.
private actor HeldLoadEngine: TranscriptionEngine {
    let capabilities = TranscriptionCapabilities(
        supportsBatch: true,
        supportsStreaming: false,
        supportsCancellation: true,
        supportedSampleRate: 16_000,
        supportedChannelCount: 1
    )
    private(set) var loadedModelID: ModelID?
    private var held = false
    private var failing = false
    private var loadsInFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func load(_ package: InstalledModelPackage) async throws {
        loadsInFlight += 1
        defer { loadsInFlight -= 1 }
        if held {
            await withCheckedContinuation { waiters.append($0) }
        }
        if failing { throw KVoiceError(code: .modelLoadFailed) }
        loadedModelID = package.manifest.modelID
    }

    func unload() async { loadedModelID = nil }

    func setComputeUnits(_ units: SpeechComputeUnits) async throws {}

    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> TranscriptionResult {
        throw KVoiceError(code: .sttFailed)
    }

    func hold() { held = true }

    func failLoads() { failing = true }

    func release() {
        held = false
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func waitUntilLoading(file: StaticString = #filePath, line: UInt = #line) async {
        var yields = 0
        while loadsInFlight == 0 {
            yields += 1
            if yields > testYieldBudget {
                return XCTFail("waitUntilLoading: no load after \(testYieldBudget) yields", file: file, line: line)
            }
            await Task.yield()
        }
    }
}

private actor EventRecorder: DiagnosticLogging {
    private(set) var events: [DiagnosticEvent] = []

    func log(_ event: DiagnosticEvent) async {
        events.append(event)
    }
}

private struct PerModelURLProvider: ModelDownloadURLProviding {
    let roots: [ModelID: URL]

    func url(for descriptor: ModelFileDescriptor, manifest: ModelManifest) throws -> URL {
        guard let root = roots[manifest.modelID] else {
            throw ModelManagementError.unsupportedModel(manifest.modelID)
        }
        return try ModelRelativePath.url(for: descriptor.path, under: root)
    }
}
