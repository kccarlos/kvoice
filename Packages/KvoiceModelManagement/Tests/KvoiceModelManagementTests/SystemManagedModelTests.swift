import Foundation
import KvoiceDomain
import KvoiceTestSupport
import KvoiceModelManagement
import KvoiceTranscription
import XCTest

/// ADR-025: a system-managed catalog entry through `SystemManagedModelManager`
/// and, above it, `SpeechModelLibrary` — the platform's answers as lifecycle
/// states, Install / Delete as reserve / release, the per-language state,
/// the runtime-observed language overlay, and the library's routing.
final class SystemManagedModelTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    static let appleSpeech = SpeechModelCatalogEntry(
        id: "apple-speech", displayName: "Apple Speech", variantName: "on-device", family: "apple-speech",
        runtime: .appleSpeech, hosting: .onDevice, supportsStreaming: true, supportsBatch: true, downloadBytes: 0,
        languageCodes: TranscriptionLanguage.appleSpeechShippedLanguageCodes, languageSummary: "21 languages",
        summary: "Apple's model.", isRecommended: false, revision: "system", manifestResource: "", manifestSHA256: "",
        punctuation: true, assetSource: .systemManaged
    )

    // MARK: - Manager

    func testStatesFollowThePlatformAndInstalledLoadsTheRuntime() async throws {
        let assets = FakeSystemAssets()
        let loader = SystemRecordingLoader()
        let manager = SystemManagedModelManager(entry: Self.appleSpeech, assets: assets, runtimeLoader: loader, languageCode: "en")
        let initial = await manager.state
        XCTAssertEqual(initial, .absent, "nothing observed yet")
        await XCTAssertFalseAsync(await manager.hasObservedAssets, "the constructor's `.absent` is not an observation")

        await manager.refresh()
        var state = await manager.state
        XCTAssertEqual(state, .absent, "en: supported, not installed")
        await XCTAssertTrueAsync(await manager.hasObservedAssets)
        await XCTAssertEqualAsync(await loader.loads.count, 0)
        await XCTAssertEqualAsync(await manager.supportedLanguageCodes, ["en", "zh"])

        await assets.set(state: .installed, for: "en")
        await manager.refresh()
        state = await manager.state
        XCTAssertEqual(state, .ready(InstalledModelSummary(modelID: "apple-speech", revision: "system", ownership: .systemManaged)))
        await XCTAssertEqualAsync(await loader.loads.map(\.manifest.modelID), ["apple-speech"])
        await XCTAssertEqualAsync(await loader.loads.first?.ownership, .systemManaged)
        await XCTAssertEqualAsync(try await manager.verifiedPackage().manifest.modelID, "apple-speech")
        await XCTAssertEqualAsync(await manager.currentModelReference(), .managed(modelID: "apple-speech", revision: "system"))
        await XCTAssertEqualAsync(await manager.installationSpaceEstimate().requiredBytes, 0)

        await assets.set(state: .unavailable(.requiresNewerMacOS), for: "en")
        await manager.refresh()
        state = await manager.state
        XCTAssertEqual(state, .unavailable(SystemManagedUnavailableReason.requiresNewerMacOS.modelFailure))
        await XCTAssertEqualAsync(await loader.unloads, 2, "no framework: the runtime is released (the first release was the not-installed observation)")
        await XCTAssertNilAsync(await manager.installedPackageSummary())
        do {
            try await manager.installRecommendedModel()
            XCTFail("unavailable is refused before the platform is touched")
        } catch let error as ModelManagementError {
            XCTAssertEqual(error, .unsupportedModel("apple-speech"))
        }
        await XCTAssertEqualAsync(await assets.installs, [])
    }

    func testInstallReservesTheLanguageReportsPercentAndDeleteReleasesIt() async throws {
        let assets = FakeSystemAssets()
        let loader = SystemRecordingLoader()
        let manager = SystemManagedModelManager(entry: Self.appleSpeech, assets: assets, runtimeLoader: loader, languageCode: "zh")
        await assets.set(progressSteps: [0.1, 0.51, 0.93])
        let observed = SystemStateObserver()
        await assets.set(onProgress: { await observed.record(await manager.state) })

        try await manager.installRecommendedModel()
        await XCTAssertEqualAsync(await assets.installs, ["zh"])
        let states = await observed.states
        XCTAssertEqual(states, [
            .downloading(completed: 10, total: 100),
            .downloading(completed: 51, total: 100),
            .downloading(completed: 93, total: 100)
        ], "the platform's fraction as a percentage, never bytes")
        var state = await manager.state
        XCTAssertEqual(state, .ready(InstalledModelSummary(modelID: "apple-speech", revision: "system", ownership: .systemManaged)))
        await XCTAssertEqualAsync(await loader.loads.count, 1)

        try await manager.deleteManagedPackage()
        await XCTAssertEqualAsync(await assets.releases, ["zh"])
        state = await manager.state
        XCTAssertEqual(state, .absent)
        await XCTAssertEqualAsync(await loader.unloads, 2, "the delete, then the not-installed observation that follows it")
        do {
            try await manager.deleteManagedPackage()
            XCTFail("nothing to delete")
        } catch let error as ModelManagementError {
            XCTAssertEqual(error, .noManagedPackage)
        }
    }

    func testInstallFailuresAreTypedAndRetryIsInstallAgain() async throws {
        let assets = FakeSystemAssets()
        let manager = SystemManagedModelManager(entry: Self.appleSpeech, assets: assets, runtimeLoader: SystemRecordingLoader(), languageCode: "en")
        await assets.set(installError: .tooManyReservedLocales)
        do {
            try await manager.installRecommendedModel()
            XCTFail()
        } catch let error as ModelManagementError {
            XCTAssertEqual(error, .downloadFailed(SystemManagedAssetError.tooManyReservedLocales.message))
        }
        var state = await manager.state
        XCTAssertEqual(state, .error(SystemManagedAssetError.tooManyReservedLocales.modelFailure))
        await assets.set(installError: nil)
        try await manager.retryInstallation()
        state = await manager.state
        guard case .ready = state else { return XCTFail("retry installs: \(state)") }
        await XCTAssertEqualAsync(await assets.installs, ["en", "en"])
    }

    func testCancelDuringInstallReturnsToTheObservedState() async throws {
        let assets = FakeSystemAssets()
        let manager = SystemManagedModelManager(entry: Self.appleSpeech, assets: assets, runtimeLoader: SystemRecordingLoader(), languageCode: "en")
        await assets.set(blockInstall: true)
        let install = Task { try await manager.installRecommendedModel() }
        await assets.waitForInstallStart()
        let during = await manager.state
        XCTAssertEqual(during, .downloading(completed: 0, total: 100))
        await manager.cancelInstallation()
        do {
            try await install.value
            XCTFail("cancelled")
        } catch let error as ModelManagementError {
            XCTAssertEqual(error, .cancelled)
        }
        let after = await manager.state
        XCTAssertEqual(after, .absent, "re-observed after the cancellation")
    }

    func testAFailedInstallReleasesTheReservationItTookAndDeleteWorksFromError() async throws {
        let assets = FakeSystemAssets()
        let manager = SystemManagedModelManager(entry: Self.appleSpeech, assets: assets, runtimeLoader: SystemRecordingLoader(), languageCode: "en")
        await assets.set(installError: .downloadFailed)
        do {
            try await manager.installRecommendedModel()
            XCTFail()
        } catch let error as ModelManagementError {
            XCTAssertEqual(error, .downloadFailed(SystemManagedAssetError.downloadFailed.message))
        }
        await XCTAssertEqualAsync(await assets.releases, ["en"], "the slot the request reserved is given back")
        let state = await manager.state
        XCTAssertEqual(state, .error(SystemManagedAssetError.downloadFailed.modelFailure))
        // Delete from `.error` is the card's way out too.
        try await manager.deleteManagedPackage()
        await XCTAssertEqualAsync(await assets.releases, ["en", "en"])
        await XCTAssertEqualAsync(await manager.state, .absent)
    }

    func testACancelledInstallReleasesTheReservationItTook() async throws {
        let assets = FakeSystemAssets()
        let manager = SystemManagedModelManager(entry: Self.appleSpeech, assets: assets, runtimeLoader: SystemRecordingLoader(), languageCode: "zh")
        await assets.set(blockInstall: true)
        let install = Task { try await manager.installRecommendedModel() }
        await assets.waitForInstallStart()
        await manager.cancelInstallation()
        _ = try? await install.value
        await XCTAssertEqualAsync(await assets.releases, ["zh"])
        await XCTAssertEqualAsync(await manager.state, .absent)
    }

    func testARetryOverAHeldReservationReleasesNothing() async throws {
        // Installed already (the app holds the reservation): a failed
        // re-install must not release what the user had.
        let assets = FakeSystemAssets()
        await assets.set(state: .installed, for: "en")
        let manager = SystemManagedModelManager(entry: Self.appleSpeech, assets: assets, runtimeLoader: SystemRecordingLoader(), languageCode: "en")
        await manager.refresh()
        await assets.set(installError: .downloadFailed)
        _ = try? await manager.retryInstallation()
        await XCTAssertEqualAsync(await assets.releases, [])
    }

    func testTheLanguageChangeReobservesAndInferenceHoldsTheState() async throws {
        let assets = FakeSystemAssets()
        let loader = SystemRecordingLoader()
        let manager = SystemManagedModelManager(entry: Self.appleSpeech, assets: assets, runtimeLoader: loader, languageCode: "en")
        await assets.set(state: .installed, for: "en")
        await manager.refresh()
        guard case .ready = await manager.state else { return XCTFail("en installed") }

        await manager.setLanguageCode("zh")
        var state = await manager.state
        XCTAssertEqual(state, .absent, "zh has no assets yet")
        await XCTAssertEqualAsync(await loader.unloads, 1, "the engine cannot serve zh: released")
        await manager.setLanguageCode("fr")
        state = await manager.state
        XCTAssertEqual(state, .unavailable(SystemManagedUnavailableReason.languageUnsupported.modelFailure))
        await manager.setLanguageCode("en")
        state = await manager.state
        guard case .ready = state else { return XCTFail("back to en: \(state)") }

        let jobID = UUID()
        try await manager.beginInference(jobID: jobID)
        state = await manager.state
        XCTAssertEqual(state, .inference(InstalledModelSummary(modelID: "apple-speech", revision: "system", ownership: .systemManaged), jobID: jobID))
        do {
            try await manager.deleteManagedPackage()
            XCTFail("busy")
        } catch let error as ModelManagementError {
            XCTAssertEqual(error, .busy)
        }
        await manager.refresh() // ignored while a job holds the model
        state = await manager.state
        guard case .inference = state else { return XCTFail("refresh during inference is a no-op") }
        await manager.endInference(jobID: UUID()) // wrong job: ignored
        await manager.endInference(jobID: jobID)
        state = await manager.state
        guard case .ready = state else { return XCTFail("ready again") }

        // A language change while a job holds the model: the code moves,
        // the observation does not, and the snapshot says so in one turn.
        try await manager.beginInference(jobID: jobID)
        await manager.setLanguageCode("zh")
        var snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot.languageCode, "zh")
        XCTAssertFalse(snapshot.hasObservedAssets, "`state` is still en's")
        guard case .inference = snapshot.state else { return XCTFail("\(snapshot.state)") }
        await manager.endInference(jobID: jobID)
        snapshot = await manager.snapshot()
        XCTAssertFalse(snapshot.hasObservedAssets, "restored `.ready` is en's, not zh's")
        await manager.refresh()
        snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot, .init(languageCode: "zh", hasObservedAssets: true, state: .absent))
    }

    // MARK: - Library

    private func makeLibrary(
        assets: FakeSystemAssets,
        engine: RecordingEngine,
        preferredDefault: ModelID? = nil,
        transcriptionLanguage: String? = "en",
        includeAssets: Bool = true
    ) throws -> (SpeechModelLibrary, ModelLifecycleFixture) {
        let storageURL = ModelLifecycleFixture.makeTemporaryDirectory(in: &temporaryURLs)
        let whisper = try ModelLifecycleFixture.make(in: &temporaryURLs, storageURL: storageURL)
        let whisperEntry = SpeechModelCatalogEntry(
            id: whisper.manifest.modelID, displayName: "Whisper v3 Turbo", variantName: "High-Accuracy",
            family: whisper.manifest.family, runtime: .whisperKitCoreML, hosting: .onDevice,
            supportsStreaming: true, supportsBatch: true, downloadBytes: ModelLifecycleFixture.totalBytes,
            languageSummary: "99 languages", summary: "fixture", isRecommended: true,
            revision: whisper.manifest.source.revision, manifestResource: whisper.manifest.modelID,
            manifestSHA256: whisper.anchor.manifestSHA256
        )
        let loaded = LoadedSpeechModelCatalog(
            catalog: SpeechModelCatalog(entries: [whisperEntry, Self.appleSpeech]),
            anchors: [whisper.manifest.modelID: whisper.anchor]
        )
        let library = try SpeechModelLibrary(
            loaded: loaded,
            storageDirectoryURL: storageURL,
            engine: engine,
            preferredDefaultModelID: preferredDefault,
            makeDownloader: { LifecycleFixtureDownloader() },
            urlProvider: SingleSourceURLProvider(root: whisper.sourceURL),
            volumeCapacity: FixedVolumeCapacityProvider(availableBytes: Int64.max),
            appVersion: "test-build",
            systemAssets: includeAssets ? [.appleSpeech: assets] : [:],
            transcriptionLanguage: transcriptionLanguage
        )
        return (library, whisper)
    }

    func testTheLibraryListsTheSystemEntryOnlyWithAnAssetsAdapter() throws {
        let assets = FakeSystemAssets()
        let (with, whisper) = try makeLibrary(assets: assets, engine: RecordingEngine())
        XCTAssertEqual(with.modelIDs, [whisper.manifest.modelID, "apple-speech"])
        let (without, _) = try makeLibrary(assets: assets, engine: RecordingEngine(), includeAssets: false)
        XCTAssertEqual(without.modelIDs, [whisper.manifest.modelID], "no adapter: listed in the catalog, no manager")
        XCTAssertEqual(without.catalog.entries.map(\.id), [whisper.manifest.modelID, "apple-speech"])
    }

    func testRefreshOverlaysTheObservedLanguagesAndStatesRouteToTheSystemManager() async throws {
        let assets = FakeSystemAssets()
        let engine = RecordingEngine()
        let (library, whisper) = try makeLibrary(assets: assets, engine: engine)
        XCTAssertEqual(library.catalog.entry(id: "apple-speech")?.languageCodes, TranscriptionLanguage.appleSpeechShippedLanguageCodes, "shipped until observed")

        await library.refresh()
        let entry = try XCTUnwrap(library.catalog.entry(id: "apple-speech"))
        XCTAssertEqual(entry.languageCodes, ["en", "zh"], "the runtime-observed coverage replaces the shipped list")
        XCTAssertEqual(entry.languageSummary, "2 languages on this Mac")
        XCTAssertEqual(entry.summary, Self.appleSpeech.summary, "only the coverage changes")
        XCTAssertEqual(library.catalog.entry(id: whisper.manifest.modelID)?.languageCodes, nil, "other entries untouched")
        let states = await library.states()
        XCTAssertEqual(states["apple-speech"], .absent)
        XCTAssertEqual(SpeechModelLibrary.languageSummary(count: 1), "1 language on this Mac")

        // Install through the library: the `.downloading` activity, then ready.
        try await library.install("apple-speech")
        await XCTAssertEqualAsync(await assets.installs, ["en"])
        let installed = await library.state(of: "apple-speech")
        guard case .ready = installed else { return XCTFail("\(String(describing: installed))") }
        await XCTAssertNilAsync(await engine.loadedModelID, "not the default: nothing resident")
        await XCTAssertEqualAsync(await library.modelReference(for: "apple-speech"), .managed(modelID: "apple-speech", revision: "system"))
        await XCTAssertEqualAsync(await library.installationSpaceEstimate(for: "apple-speech")?.requiredBytes, 0)

        // Make it the default: the resident engine loads the system package.
        await XCTAssertTrueAsync(try await library.setDefaultModel("apple-speech"))
        await XCTAssertEqualAsync(await engine.loadedModelID, "apple-speech")
        await XCTAssertEqualAsync(await engine.loadedIDs, ["apple-speech"])
        await XCTAssertTrueAsync(await library.isDefaultModelResident())
        await XCTAssertEqualAsync(await library.residentPackage()?.ownership, .systemManaged)

        // The language changes to one without assets: the default system
        // entry installs them on its own (ADR-025 amendment, the detail in
        // `SystemManagedAutoInstallTests`) through the Install transaction,
        // and the engine holds it again for the new language.
        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await assets.installs, ["en", "zh"])
        guard case .ready = await library.state(of: "apple-speech") else { return XCTFail("zh installed automatically") }
        await XCTAssertEqualAsync(await engine.loadedModelID, "apple-speech")
        await library.setTranscriptionLanguage("en")
        await XCTAssertEqualAsync(await engine.loadedModelID, "apple-speech")

        // A language change while another activity holds the engine is left
        // for the next call (the slow poll retries), never applied underneath
        // the activity (ADR-022 item 5) — and neither is the install.
        await assets.set(state: .notInstalled, for: "ja")
        try await library.beginActivity(.testing)
        await library.setTranscriptionLanguage("ja")
        await XCTAssertEqualAsync(await library.state(of: "apple-speech"), .ready(InstalledModelSummary(modelID: "apple-speech", revision: "system", ownership: .systemManaged)))
        await XCTAssertEqualAsync(await library.currentActivity, .testing)
        await XCTAssertEqualAsync(await assets.installs, ["en", "zh"])
        await library.endActivity()
        await library.setTranscriptionLanguage("ja")
        await XCTAssertEqualAsync(await assets.installs, ["en", "zh", "ja"])
        guard case .ready = await library.state(of: "apple-speech") else { return XCTFail("ja installed once idle") }
        await XCTAssertEqualAsync(await library.currentActivity, .idle)
        await library.setTranscriptionLanguage("en")

        // Delete releases the reservation; the external-folder operations
        // are refused for a system entry.
        try await library.delete("apple-speech")
        await XCTAssertEqualAsync(await assets.releases, ["en"])
        await XCTAssertEqualAsync(await library.state(of: "apple-speech"), .absent)
        do {
            try await library.selectExternalPackage(at: URL(fileURLWithPath: "/tmp"), for: "apple-speech")
            XCTFail()
        } catch let error as ModelManagementError {
            XCTAssertEqual(error, .unsupportedModel("apple-speech"))
        }
        try await library.forgetExternalPackage(for: "apple-speech") // harmless
        await XCTAssertNilAsync(await library.manager(for: "apple-speech"), "no package manager for a system entry")
        await XCTAssertNotNilAsync(await library.manager(for: whisper.manifest.modelID))
    }

    func testAnUnavailableSystemEntryIsListedWithItsReasonAndNeverBecomesTheDefault() async throws {
        let assets = FakeSystemAssets()
        await assets.set(state: .unavailable(.requiresNewerMacOS), for: "en")
        let engine = RecordingEngine()
        let (library, whisper) = try makeLibrary(assets: assets, engine: engine, preferredDefault: "apple-speech")
        // The persisted preference names the system entry: it is runnable
        // in this build, so it is honoured; the state then says why it
        // cannot serve.
        await XCTAssertEqualAsync(await library.defaultModelID, "apple-speech")
        await library.refresh()
        await XCTAssertEqualAsync(await library.state, .unavailable(SystemManagedUnavailableReason.requiresNewerMacOS.modelFailure))
        await XCTAssertFalseAsync(await library.isDefaultModelResident())
        XCTAssertEqual(library.catalog.entry(id: "apple-speech")?.languageCodes, TranscriptionLanguage.appleSpeechShippedLanguageCodes, "nothing observed: the shipped list stands")
        do {
            try await library.install("apple-speech")
            XCTFail()
        } catch let error as ModelManagementError {
            XCTAssertEqual(error, .unsupportedModel("apple-speech"))
        }
        await XCTAssertEqualAsync(await library.currentActivity, .idle, "the refused install returns the library to idle")
        _ = whisper
    }
}

// MARK: - Doubles

/// A scripted `SystemManagedModelAssets`: per-language states, install
/// progress steps, an error to throw, and a gate to hold an install open.
actor FakeSystemAssets: SystemManagedModelAssets {
    private var states: [String: SystemManagedAssetState] = ["en": .notInstalled, "zh": .notInstalled]
    private var progressSteps: [Double] = []
    private var installError: SystemManagedAssetError?
    private var blockInstall = false
    private var onProgress: (@Sendable () async -> Void)?
    private var installStarted: CheckedContinuation<Void, Never>?
    /// Set when an install has begun, so a waiter that arrives after the
    /// start returns at once instead of parking on a continuation nobody
    /// will resume.
    private var started = false
    private var installGate: CheckedContinuation<Void, Never>?
    /// Holds `assetState` open — the platform call a language change
    /// suspends in — until `releaseAssetState()`.
    private var blockAssetState = false
    private var assetStateStarted: CheckedContinuation<Void, Never>?
    private var assetStateBlocked = false
    private var assetStateGate: CheckedContinuation<Void, Never>?
    private(set) var installs: [String] = []
    private(set) var releases: [String] = []

    func set(state: SystemManagedAssetState, for code: String) { states[code] = state }
    func set(progressSteps: [Double]) { self.progressSteps = progressSteps }
    func set(installError: SystemManagedAssetError?) { self.installError = installError }
    func set(blockInstall: Bool) { self.blockInstall = blockInstall }
    func set(onProgress: @escaping @Sendable () async -> Void) { self.onProgress = onProgress }

    func waitForInstallStart() async {
        if started { return }
        await withCheckedContinuation { continuation in installStarted = continuation }
    }

    func set(blockAssetState: Bool) { self.blockAssetState = blockAssetState }

    /// Returns once an `assetState` call is parked on the gate.
    func waitForAssetStateStart() async {
        if assetStateBlocked { return }
        await withCheckedContinuation { continuation in assetStateStarted = continuation }
    }

    /// Lets the parked call answer, and every later one too.
    func releaseAssetState() {
        blockAssetState = false
        assetStateGate?.resume()
        assetStateGate = nil
    }

    func assetState(languageCode: String?) async -> SystemManagedAssetState {
        if blockAssetState {
            assetStateBlocked = true
            assetStateStarted?.resume()
            assetStateStarted = nil
            await withCheckedContinuation { continuation in assetStateGate = continuation }
            assetStateBlocked = false
        }
        let code = languageCode ?? "en"
        return states[code] ?? .unavailable(.languageUnsupported)
    }

    func installAssets(languageCode: String?, progress: @escaping @Sendable (Double) async -> Void) async throws {
        let code = languageCode ?? "en"
        installs.append(code)
        if let installError { throw installError }
        started = true
        installStarted?.resume()
        installStarted = nil
        if blockInstall {
            try await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in installGate = continuation }
                try Task.checkCancellation()
            }, onCancel: {
                Task { await self.releaseGate() }
            })
        }
        for step in progressSteps {
            // The manager applies the step before this returns (the
            // closure is async and hops to the actor), so the observer
            // sees each state in order.
            await progress(step)
            await onProgress?()
        }
        states[code] = .installed
    }

    private func releaseGate() {
        installGate?.resume()
        installGate = nil
    }

    func releaseAssets(languageCode: String?) async throws {
        let code = languageCode ?? "en"
        releases.append(code)
        states[code] = .notInstalled
    }

    /// Like the real adapter: nothing is supported when the runtime is
    /// unavailable on this Mac.
    func supportedLanguageCodes() async -> [String] {
        let unavailable = states.values.contains {
            if case .unavailable(let reason) = $0, reason != .languageUnsupported { return true }
            return false
        }
        return unavailable ? [] : states.keys.sorted()
    }
}

actor SystemStateObserver {
    private(set) var states: [ModelLifecycleState] = []
    func record(_ state: ModelLifecycleState) { states.append(state) }
}

actor SystemRecordingLoader: ModelRuntimeLoader {
    private(set) var loads: [InstalledModelPackage] = []
    private(set) var unloads = 0

    func load(_ package: InstalledModelPackage) async throws { loads.append(package) }
    func unload() async { unloads += 1 }
}

private actor RecordingEngine: TranscriptionEngine {
    let capabilities = TranscriptionCapabilities(
        supportsBatch: true, supportsStreaming: false, supportsCancellation: true,
        supportedSampleRate: 16_000, supportedChannelCount: 1
    )
    private(set) var loadedModelID: ModelID?
    private(set) var loadedIDs: [ModelID] = []

    func load(_ package: InstalledModelPackage) async throws {
        loadedModelID = package.manifest.modelID
        loadedIDs.append(package.manifest.modelID)
    }

    func unload() async { loadedModelID = nil }

    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> TranscriptionResult {
        throw KVoiceError(code: .sttFailed)
    }
}

private struct SingleSourceURLProvider: ModelDownloadURLProviding {
    let root: URL

    func url(for descriptor: ModelFileDescriptor, manifest: ModelManifest) throws -> URL {
        try ModelRelativePath.url(for: descriptor.path, under: root)
    }
}
