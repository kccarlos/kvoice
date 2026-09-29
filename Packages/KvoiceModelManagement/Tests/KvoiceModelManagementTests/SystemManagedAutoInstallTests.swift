import Foundation
import KvoiceDomain
import KvoiceTestSupport
import KvoiceModelManagement
import KvoiceTranscription
import XCTest

/// ADR-025 amendment (2026-09-16): when the default model is system-managed
/// and a language change finds the platform without assets for the new
/// language, `SpeechModelLibrary` installs them on its own — once per
/// language, through the card's own Install transaction, never from
/// `.unavailable` or `.error`, never for a non-default entry, never while
/// another activity runs, and never undoing a Delete.
final class SystemManagedAutoInstallTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    private static let ready = ModelLifecycleState.ready(
        InstalledModelSummary(modelID: "apple-speech", revision: "system", ownership: .systemManaged)
    )

    private func makeLibrary(
        assets: FakeSystemAssets,
        engine: AutoInstallRecordingEngine = AutoInstallRecordingEngine(),
        preferredDefault: ModelID? = "apple-speech",
        transcriptionLanguage: String? = "en",
        diagnostics: (any DiagnosticLogging)? = nil
    ) throws -> SpeechModelLibrary {
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
            catalog: SpeechModelCatalog(entries: [whisperEntry, SystemManagedModelTests.appleSpeech]),
            anchors: [whisper.manifest.modelID: whisper.anchor]
        )
        return try SpeechModelLibrary(
            loaded: loaded,
            storageDirectoryURL: storageURL,
            engine: engine,
            preferredDefaultModelID: preferredDefault,
            makeDownloader: { LifecycleFixtureDownloader() },
            urlProvider: AutoInstallSingleSourceURLProvider(root: whisper.sourceURL),
            volumeCapacity: FixedVolumeCapacityProvider(availableBytes: Int64.max),
            appVersion: "test-build",
            diagnosticLogger: diagnostics,
            systemAssets: [.appleSpeech: assets],
            transcriptionLanguage: transcriptionLanguage
        )
    }

    /// The kickoff line is logged from a detached task; yield until it
    /// lands (no real time — a handful of scheduler turns at most).
    private func events(of logger: AutoInstallDiagnosticLogger, count: Int) async -> [DiagnosticEvent] {
        for _ in 0..<200 where await logger.events.count < count {
            await Task.yield()
        }
        return await logger.events
    }

    // MARK: - The language change

    func testALanguageChangeInstallsTheDefaultSystemEntrysAssetsOnce() async throws {
        let assets = FakeSystemAssets()
        await assets.set(state: .installed, for: "en")
        let engine = AutoInstallRecordingEngine()
        let logger = AutoInstallDiagnosticLogger()
        let library = try makeLibrary(assets: assets, engine: engine, diagnostics: logger)
        await library.refresh()
        await XCTAssertEqualAsync(await library.state, Self.ready)
        await XCTAssertEqualAsync(await engine.loadedModelID, "apple-speech")

        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await assets.installs, ["zh"], "the Install transaction, through the card's path")
        await XCTAssertEqualAsync(await library.state, Self.ready)
        await XCTAssertEqualAsync(await engine.loadedIDs, ["apple-speech", "apple-speech"], "reloaded as resident for the new language")
        await XCTAssertEqualAsync(await library.currentActivity, .idle)

        // The one-second poll: the same language again is not a second install.
        await library.setTranscriptionLanguage("zh")
        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await assets.installs, ["zh"])

        // One scalar line for the kickoff: the model, the code, the door.
        let events = await events(of: logger, count: 1)
        XCTAssertEqual(events.map(\.name), [.modelAssetsAutoInstall])
        XCTAssertEqual(events.first?.attributes.modelID?.rawValue, "apple-speech")
        XCTAssertEqual(events.first?.attributes.reason?.rawValue, "zh")
        XCTAssertEqual(events.first?.attributes.site?.rawValue, "languageChange")
    }

    func testTheInstallRunsAsTheDownloadingActivityAndShowsThePercent() async throws {
        let assets = FakeSystemAssets()
        await assets.set(state: .installed, for: "en")
        await assets.set(progressSteps: [0.4])
        let library = try makeLibrary(assets: assets)
        await library.refresh()
        let observed = SystemStateObserver()
        let activities = AutoInstallActivityObserver()
        await assets.set(onProgress: {
            await observed.record(await library.state(of: "apple-speech") ?? .absent)
            await activities.record(library.currentActivity)
        })
        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await observed.states, [.downloading(completed: 40, total: 100)], "the card's percent, the prerequisite check's `.downloading`")
        await XCTAssertEqualAsync(await activities.values, [.downloading("apple-speech")], "the same activity as the card's Install")
    }

    func testAutoDetectIsALanguageOfItsOwn() async throws {
        // nil = the Mac's language, which the fake maps to `en`.
        let assets = FakeSystemAssets()
        await assets.set(state: .installed, for: "zh")
        let logger = AutoInstallDiagnosticLogger()
        let library = try makeLibrary(assets: assets, transcriptionLanguage: "zh", diagnostics: logger)
        await library.refresh()
        await XCTAssertEqualAsync(await library.state, Self.ready)

        await library.setTranscriptionLanguage(nil)
        await XCTAssertEqualAsync(await assets.installs, ["en"])
        await XCTAssertEqualAsync(await library.state, Self.ready)
        await library.setTranscriptionLanguage(nil)
        await XCTAssertEqualAsync(await assets.installs, ["en"], "decided for Auto-detect; the poll does not repeat it")
        let events = await events(of: logger, count: 1)
        XCTAssertEqual(events.first?.attributes.reason?.rawValue, "auto")
    }

    // MARK: - What is left alone

    func testANonDefaultSystemEntryKeepsThePerLanguageNotInstalledState() async throws {
        let assets = FakeSystemAssets()
        await assets.set(state: .installed, for: "en")
        let library = try makeLibrary(assets: assets, preferredDefault: nil)
        await library.refresh()
        let defaultModelID = await library.defaultModelID
        XCTAssertNotEqual(defaultModelID, "apple-speech")
        await XCTAssertEqualAsync(await library.state(of: "apple-speech"), Self.ready)

        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await library.state(of: "apple-speech"), .absent, "not the default: the card shows Install, nothing runs")
        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await assets.installs, [])
    }

    func testAnUnsupportedLanguageStaysUnavailableWithNothingInstalled() async throws {
        let assets = FakeSystemAssets()
        await assets.set(state: .installed, for: "en")
        let library = try makeLibrary(assets: assets)
        await library.refresh()

        await library.setTranscriptionLanguage("fr")
        await XCTAssertEqualAsync(await library.state, .unavailable(SystemManagedUnavailableReason.languageUnsupported.modelFailure))
        await library.setTranscriptionLanguage("fr")
        await XCTAssertEqualAsync(await assets.installs, [], "`.unavailable` is never installed")
    }

    func testAFailedAutoInstallStaysInErrorAndIsNotRetriedByThePoll() async throws {
        let assets = FakeSystemAssets()
        await assets.set(state: .installed, for: "en")
        await assets.set(installError: .tooManyReservedLocales)
        let library = try makeLibrary(assets: assets)
        await library.refresh()

        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await assets.installs, ["zh"], "tried once")
        let failed = ModelLifecycleState.error(SystemManagedAssetError.tooManyReservedLocales.modelFailure)
        await XCTAssertEqualAsync(await library.state, failed, "the reservation cap, with the card's Retry / Delete")
        await XCTAssertEqualAsync(await library.currentActivity, .idle)

        for _ in 0..<3 {
            await library.setTranscriptionLanguage("zh")
        }
        await XCTAssertEqualAsync(await assets.installs, ["zh"], "the poll does not retry a failed auto-install")
        await XCTAssertEqualAsync(await library.state, failed)

        // The user's Retry is still the way out.
        await assets.set(installError: nil)
        try await library.retry("apple-speech")
        await XCTAssertEqualAsync(await assets.installs, ["zh", "zh"])
        await XCTAssertEqualAsync(await library.state, Self.ready)
    }

    func testADeleteIsNotUndoneByThePoll() async throws {
        let assets = FakeSystemAssets()
        await assets.set(state: .installed, for: "en")
        let library = try makeLibrary(assets: assets)
        await library.refresh()
        await library.setTranscriptionLanguage("en") // the poll decides `en`: installed, nothing to do
        await XCTAssertEqualAsync(await assets.installs, [])

        try await library.delete("apple-speech")
        await XCTAssertEqualAsync(await library.state, .absent)
        await library.setTranscriptionLanguage("en")
        await library.setTranscriptionLanguage("en")
        await XCTAssertEqualAsync(await assets.installs, [], "the user deleted it; the card shows Install and waits")

        // A language change after the delete is a new decision: zh installs.
        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await assets.installs, ["zh"])
        // And back to the deleted language: a new decision for `en` too.
        await library.setTranscriptionLanguage("en")
        await XCTAssertEqualAsync(await assets.installs, ["zh", "en"])
    }

    func testTheChangeAndTheInstallWaitWhileAnotherActivityRuns() async throws {
        let assets = FakeSystemAssets()
        await assets.set(state: .installed, for: "en")
        let library = try makeLibrary(assets: assets)
        await library.refresh()

        try await library.beginActivity(.testing)
        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await library.state, Self.ready, "the change is left for the next call")
        await XCTAssertEqualAsync(await assets.installs, [])
        await XCTAssertEqualAsync(await library.currentActivity, .testing)

        await library.endActivity()
        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await assets.installs, ["zh"])
        await XCTAssertEqualAsync(await library.state, Self.ready)
    }

    func testAManualInstallInFlightIsNotDoubledAndItsCancelIsNotUndone() async throws {
        // zh is absent and undecided (it was chosen while Whisper was the
        // default), Apple Speech becomes the default, and the user presses
        // Install before the poll gets there.
        let assets = FakeSystemAssets()
        let library = try makeLibrary(assets: assets, preferredDefault: nil, transcriptionLanguage: "zh")
        await library.refresh()
        _ = try await library.setDefaultModel("apple-speech")
        await assets.set(blockInstall: true)
        let manual = Task { try await library.install("apple-speech") }
        await assets.waitForInstallStart()
        await XCTAssertEqualAsync(await library.currentActivity, .downloading("apple-speech"))

        await library.setTranscriptionLanguage("zh")
        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await assets.installs, ["zh"], "one install, the user's")

        await library.cancel("apple-speech")
        do {
            try await manual.value
            XCTFail("cancelled")
        } catch let error as ModelManagementError {
            XCTAssertEqual(error, .cancelled)
        }
        await XCTAssertEqualAsync(await library.currentActivity, .idle)
        await XCTAssertEqualAsync(await library.state, .absent)
        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await assets.installs, ["zh"], "the user cancelled; the poll does not start it again")
    }

    func testAPollDuringASuspendedLanguageChangeDoesNotLatchOnTheOldState() async throws {
        // The swift-reviewer's must-fix: the change has moved the manager's
        // language to zh and is suspended in the platform call while
        // `state` is still en's `.ready`. A poll that arrived then read the
        // three facts in three hops, took the stale `.ready` for zh's, and
        // latched the decision — the change's own kickoff then found it
        // taken, and the card stayed "Not installed" for good.
        let assets = FakeSystemAssets()
        await assets.set(state: .installed, for: "en")
        let library = try makeLibrary(assets: assets)
        await library.refresh()
        await XCTAssertEqualAsync(await library.state, Self.ready)

        await assets.set(blockAssetState: true)
        let change = Task { await library.setTranscriptionLanguage("zh") }
        await assets.waitForAssetStateStart()
        await XCTAssertEqualAsync(await library.currentActivity, .installing("apple-speech"))
        await library.setTranscriptionLanguage("zh") // the poll, mid-change
        await XCTAssertEqualAsync(await assets.installs, [])

        await assets.releaseAssetState()
        await change.value
        await XCTAssertEqualAsync(await assets.installs, ["zh"], "the change's own kickoff, exactly once")
        await XCTAssertEqualAsync(await library.state, Self.ready)
        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await assets.installs, ["zh"])
    }

    func testALanguageChangeDuringADictationIsObservedByTheNextIdlePoll() async throws {
        // Inference is not a library activity, so the change goes through,
        // but the manager skips the observation while a job holds it and
        // `endInference` restores `.ready` for a language it never looked
        // at. The idle poll re-observes (and then installs) instead of
        // waiting for the next activation refresh.
        let assets = FakeSystemAssets()
        await assets.set(state: .installed, for: "en")
        let library = try makeLibrary(assets: assets)
        await library.refresh()
        let jobID = UUID()
        try await library.beginInference(jobID: jobID)

        await library.setTranscriptionLanguage("zh")
        guard case .inference = await library.state else { return XCTFail("the job still holds the model") }
        await XCTAssertEqualAsync(await assets.installs, [], "nothing decided on an unobserved state")
        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await assets.installs, [])

        await library.endInference(jobID: jobID)
        await XCTAssertEqualAsync(await library.state, Self.ready, "restored for a language never observed")
        await library.setTranscriptionLanguage("zh") // the poll
        await XCTAssertEqualAsync(await assets.installs, ["zh"], "re-observed as absent, then installed")
        await XCTAssertEqualAsync(await library.state, Self.ready)
    }

    // MARK: - Launch

    func testTheLaunchPathInstallsThePersistedLanguageOnceTheStateIsObserved() async throws {
        // `AppDelegate+Model.restoreSelectedModelFromSettings`: the library
        // is built with no language and no preferred default; the shell then
        // sets the language, the default, and restores — the first
        // observation — and the one-second poll follows.
        let assets = FakeSystemAssets()
        let engine = AutoInstallRecordingEngine()
        let logger = AutoInstallDiagnosticLogger()
        let library = try makeLibrary(assets: assets, engine: engine, preferredDefault: nil, transcriptionLanguage: nil, diagnostics: logger)

        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await assets.installs, [], "Whisper is the default at this point")
        await XCTAssertTrueAsync(try await library.setDefaultModel("apple-speech"))
        await library.restoreSelectedModel(.managed(modelID: "apple-speech", revision: "system"))
        await XCTAssertEqualAsync(await library.state, .absent)
        await XCTAssertEqualAsync(await assets.installs, [], "restore observes; it does not install inline")

        await library.setTranscriptionLanguage("zh") // the poll
        await XCTAssertEqualAsync(await assets.installs, ["zh"])
        await XCTAssertEqualAsync(await library.state, Self.ready)
        await XCTAssertEqualAsync(await engine.loadedModelID, "apple-speech")
        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await assets.installs, ["zh"])
        let events = await events(of: logger, count: 1)
        XCTAssertEqual(events.first?.attributes.site?.rawValue, "poll")
    }

    func testNothingHappensBeforeTheFirstObservation() async throws {
        // The persisted language and default reach the library before any
        // refresh: the constructor's `.absent` is not an observation, and
        // the poll neither installs on it nor observes on its own — the
        // launch path's first observation is `restoreSelectedModel`'s (a
        // second platform query here would double the launch cost).
        let assets = FakeSystemAssets()
        await assets.set(state: .installed, for: "zh")
        let library = try makeLibrary(assets: assets, transcriptionLanguage: "zh")
        await library.setTranscriptionLanguage("zh")
        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await assets.installs, [], "unobserved: no reservation on a guess")
        await XCTAssertEqualAsync(await library.state, .absent, "and no observation of its own")

        await library.restoreSelectedModel(nil)
        await XCTAssertEqualAsync(await library.state, Self.ready)
        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await assets.installs, [], "installed already: decided, nothing to do")
    }

    func testTheReservationsPersistSoALaunchWithThemIsANoOp() async throws {
        let assets = FakeSystemAssets()
        await assets.set(state: .installed, for: "zh")
        let library = try makeLibrary(assets: assets, preferredDefault: nil, transcriptionLanguage: nil)
        await library.setTranscriptionLanguage("zh")
        _ = try await library.setDefaultModel("apple-speech")
        await library.restoreSelectedModel(nil)
        await library.setTranscriptionLanguage("zh")
        await XCTAssertEqualAsync(await assets.installs, [])
        await XCTAssertEqualAsync(await library.state, Self.ready)
    }

    // MARK: - Fresh-setup default (2026-09-29)

    /// The decision waits for the system entry to have looked at this Mac:
    /// its constructor `.absent` would otherwise read as "can run it".
    func testObservedStatesAreWithheldUntilTheSystemEntryHasObservedThePlatform() async throws {
        let assets = FakeSystemAssets()
        await assets.set(state: .unavailable(.requiresNewerMacOS), for: "en")
        let library = try makeLibrary(assets: assets, preferredDefault: nil, transcriptionLanguage: nil)

        let before = await library.observedStates()
        XCTAssertNil(before, "never decide on the constructor's state")

        await library.restoreSelectedModel(nil)
        let after = await library.observedStates()
        XCTAssertEqual(after?["apple-speech"], .unavailable(SystemManagedUnavailableReason.requiresNewerMacOS.modelFailure))
        let choice = SetupSpeechModelDefault.usableSystemModel(
            catalog: library.catalog, states: after ?? [:], transcriptionLanguage: nil, macLanguageCode: "en"
        )
        XCTAssertNil(choice, "an older macOS keeps Whisper")
    }

    /// End to end at the library: a fresh setup on a Mac that can run Apple
    /// Speech switches the default, and the existing per-language automatic
    /// install fetches the assets — no new install path.
    func testAFreshSetupAdoptsAppleSpeechAndTheAutomaticInstallFetchesItsAssets() async throws {
        let assets = FakeSystemAssets()
        let library = try makeLibrary(assets: assets, preferredDefault: nil, transcriptionLanguage: nil)
        await library.restoreSelectedModel(nil)
        let observed = await library.observedStates()
        let states = try XCTUnwrap(observed)
        let choice = SetupSpeechModelDefault.choice(
            onboardingCompletedVersion: nil, savedDefaultModelID: nil, selectedModel: nil,
            catalog: library.catalog, states: states, transcriptionLanguage: nil, macLanguageCode: "en"
        )
        XCTAssertEqual(choice, "apple-speech")

        _ = try await library.setDefaultModel("apple-speech")
        await library.setTranscriptionLanguage(nil)

        await XCTAssertEqualAsync(await assets.installs, ["en"])
        await XCTAssertEqualAsync(await library.state, Self.ready)
    }

    func testWaitUntilIdleReturnsAtOnceWhenNothingRuns() async throws {
        let library = try makeLibrary(assets: FakeSystemAssets(), preferredDefault: nil)
        await library.waitUntilIdle()
        XCTAssertEqual(library.currentActivity, .idle)
    }
}

// MARK: - Doubles

private actor AutoInstallDiagnosticLogger: DiagnosticLogging {
    private(set) var events: [DiagnosticEvent] = []

    func log(_ event: DiagnosticEvent) async {
        events.append(event)
    }
}

private actor AutoInstallActivityObserver {
    private(set) var values: [ModelActivity] = []
    func record(_ value: ModelActivity) { values.append(value) }
}

private actor AutoInstallRecordingEngine: TranscriptionEngine {
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

private struct AutoInstallSingleSourceURLProvider: ModelDownloadURLProviding {
    let root: URL

    func url(for descriptor: ModelFileDescriptor, manifest: ModelManifest) throws -> URL {
        try ModelRelativePath.url(for: descriptor.path, under: root)
    }
}
