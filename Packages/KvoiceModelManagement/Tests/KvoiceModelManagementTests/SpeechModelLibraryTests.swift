import Foundation
import KvoiceDomain
import KvoiceModelManagement
import KvoiceTranscription
import XCTest

/// ADR-017: one manager per catalog entry, one resident runtime (the
/// default's), per-model staging isolation, and the default-model façade.
final class SpeechModelLibraryTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    private struct TwoModelFixture {
        let storageURL: URL
        let standard: ModelLifecycleFixture
        let highAccuracy: ModelLifecycleFixture
        let loaded: LoadedSpeechModelCatalog

        var standardID: ModelID { standard.manifest.modelID }
        var highAccuracyID: ModelID { highAccuracy.manifest.modelID }
    }

    private func makeFixture() throws -> TwoModelFixture {
        let storageURL = ModelLifecycleFixture.makeTemporaryDirectory(in: &temporaryURLs)
        let standard = try ModelLifecycleFixture.make(
            in: &temporaryURLs,
            modelID: ModelLifecycleFixture.standardRelease.modelID,
            revision: ModelLifecycleFixture.standardRelease.revision,
            subdirectory: ModelLifecycleFixture.standardRelease.subdirectory,
            storageURL: storageURL,
            contentSalt: "-standard"
        )
        let highAccuracy = try ModelLifecycleFixture.make(in: &temporaryURLs, storageURL: storageURL)
        let catalog = SpeechModelCatalog(entries: [
            entry(for: standard, variant: "Standard", recommended: true),
            entry(for: highAccuracy, variant: "High-Accuracy", recommended: false)
        ])
        let loaded = LoadedSpeechModelCatalog(
            catalog: catalog,
            anchors: [standard.manifest.modelID: standard.anchor, highAccuracy.manifest.modelID: highAccuracy.anchor]
        )
        return TwoModelFixture(storageURL: storageURL, standard: standard, highAccuracy: highAccuracy, loaded: loaded)
    }

    private func entry(for fixture: ModelLifecycleFixture, variant: String, recommended: Bool) -> SpeechModelCatalogEntry {
        SpeechModelCatalogEntry(
            id: fixture.manifest.modelID,
            displayName: "Whisper v3 Turbo",
            variantName: variant,
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
        _ fixture: TwoModelFixture,
        engine: any TranscriptionEngine,
        preferredDefault: ModelID? = nil,
        diagnostics: (any DiagnosticLogging)? = nil,
        downloader: LifecycleFixtureDownloader? = nil
    ) throws -> SpeechModelLibrary {
        try SpeechModelLibrary(
            loaded: fixture.loaded,
            storageDirectoryURL: fixture.storageURL,
            engine: engine,
            preferredDefaultModelID: preferredDefault,
            makeDownloader: { downloader ?? LifecycleFixtureDownloader() },
            urlProvider: TwoSourceURLProvider(
                roots: [
                    fixture.standardID: fixture.standard.sourceURL,
                    fixture.highAccuracyID: fixture.highAccuracy.sourceURL
                ]
            ),
            volumeCapacity: FixedVolumeCapacityProvider(availableBytes: Int64.max),
            appVersion: "test-build",
            diagnosticLogger: diagnostics
        )
    }

    func testDefaultFallsBackToRecommendedAndUnknownPreferenceIsIgnored() async throws {
        let fixture = try makeFixture()
        let engine = RecordingEngine()
        let library = try makeLibrary(fixture, engine: engine)
        let unknownPreference = try makeLibrary(fixture, engine: engine, preferredDefault: "does-not-exist")
        let explicit = try makeLibrary(fixture, engine: engine, preferredDefault: fixture.highAccuracyID)

        let libraryDefault = await library.defaultModelID
        let unknownDefault = await unknownPreference.defaultModelID
        let explicitDefault = await explicit.defaultModelID
        XCTAssertEqual(libraryDefault, fixture.standardID)
        XCTAssertEqual(unknownDefault, fixture.standardID)
        XCTAssertEqual(explicitDefault, fixture.highAccuracyID)
        XCTAssertEqual(library.modelIDs, [fixture.standardID, fixture.highAccuracyID])
    }

    func testInstallingBothModelsLoadsOnlyTheDefaultIntoTheEngine() async throws {
        let fixture = try makeFixture()
        let engine = RecordingEngine()
        let library = try makeLibrary(fixture, engine: engine)

        try await library.installRecommendedModel()
        var loadedID = await engine.loadedModelID
        XCTAssertEqual(loadedID, fixture.standardID)
        let defaultState = await library.state
        XCTAssertEqual(defaultState, .ready(fixture.standard.readySummary))
        let resident = await library.isDefaultModelResident()
        XCTAssertTrue(resident)

        try await library.install(fixture.highAccuracyID)
        loadedID = await engine.loadedModelID
        XCTAssertEqual(loadedID, fixture.standardID, "a non-default install is verified, not loaded")
        let states = await library.states()
        XCTAssertEqual(states[fixture.highAccuracyID], .ready(fixture.highAccuracy.readySummary))
        XCTAssertEqual(states[fixture.standardID], .ready(fixture.standard.readySummary))
        let loads = await engine.loadedIDs
        XCTAssertEqual(loads, [fixture.standardID], "the engine saw exactly one load")

        // Both packages sit side by side on disk, each under its own ID.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.standard.managedPackageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.highAccuracy.managedPackageURL.path))
    }

    func testSwitchingTheDefaultReleasesTheOldRuntimeAndLoadsTheNewOne() async throws {
        let fixture = try makeFixture()
        let engine = RecordingEngine()
        let library = try makeLibrary(fixture, engine: engine)
        try await library.installRecommendedModel()
        try await library.install(fixture.highAccuracyID)

        let changed = try await library.setDefaultModel(fixture.highAccuracyID)
        XCTAssertTrue(changed)
        let loadedID = await engine.loadedModelID
        XCTAssertEqual(loadedID, fixture.highAccuracyID)
        let unloads = await engine.unloadCount
        XCTAssertEqual(unloads, 1, "the previous default was released first")
        let states = await library.states()
        XCTAssertEqual(states[fixture.highAccuracyID], .ready(fixture.highAccuracy.readySummary))
        XCTAssertEqual(states[fixture.standardID], .ready(fixture.standard.readySummary), "still installed and verified")
        let resident = await library.isDefaultModelResident()
        XCTAssertTrue(resident)

        let unchanged = try await library.setDefaultModel(fixture.highAccuracyID)
        XCTAssertFalse(unchanged)
        do {
            try await library.setDefaultModel("nope")
            XCTFail("unknown IDs are refused")
        } catch {
            XCTAssertEqual(error as? ModelManagementError, .unsupportedModel("nope"))
        }

        // Switching to a model that is not installed leaves the engine empty
        // and that model Absent; nothing else is touched.
        try await library.delete(fixture.standardID)
        _ = try await library.setDefaultModel(fixture.standardID)
        let afterSwitch = await engine.loadedModelID
        XCTAssertNil(afterSwitch)
        let absent = await library.state
        XCTAssertEqual(absent, .absent)
    }

    func testDeletingANonDefaultModelKeepsTheDefaultResident() async throws {
        let fixture = try makeFixture()
        let engine = RecordingEngine()
        let library = try makeLibrary(fixture, engine: engine)
        try await library.installRecommendedModel()
        try await library.install(fixture.highAccuracyID)

        try await library.delete(fixture.highAccuracyID)
        let loadedID = await engine.loadedModelID
        XCTAssertEqual(loadedID, fixture.standardID)
        let unloads = await engine.unloadCount
        XCTAssertEqual(unloads, 0, "deleting a model the engine does not hold never unloads")
        let states = await library.states()
        XCTAssertEqual(states[fixture.highAccuracyID], .absent)

        // Deleting the default does unload.
        try await library.deleteManagedPackage()
        let afterDefaultDelete = await engine.loadedModelID
        XCTAssertNil(afterDefaultDelete)
    }

    func testSwitchingIsRefusedDuringInference() async throws {
        let fixture = try makeFixture()
        let engine = RecordingEngine()
        let library = try makeLibrary(fixture, engine: engine)
        try await library.installRecommendedModel()
        try await library.install(fixture.highAccuracyID)

        let jobID = UUID()
        try await library.beginInference(jobID: jobID)
        do {
            _ = try await library.setDefaultModel(fixture.highAccuracyID)
            XCTFail("a switch must not happen under a running job")
        } catch {
            XCTAssertEqual(error as? ModelManagementError, .busy)
        }
        await library.endInference(jobID: jobID)
        _ = try await library.setDefaultModel(fixture.highAccuracyID)
        let loadedID = await engine.loadedModelID
        XCTAssertEqual(loadedID, fixture.highAccuracyID)
    }

    /// Later waves: memory-pressure warnings' "Unload model now" and its
    /// reload once a dictation is asked for again.
    func testUnloadResidentRuntimeReleasesTheEngineButKeepsTheModelVerifiedAndReloadRestoresIt() async throws {
        let fixture = try makeFixture()
        let engine = RecordingEngine()
        let library = try makeLibrary(fixture, engine: engine)
        try await library.installRecommendedModel()
        var resident = await library.isDefaultModelResident()
        XCTAssertTrue(resident)

        try await library.unloadResidentRuntime()

        var loadedID = await engine.loadedModelID
        XCTAssertNil(loadedID, "the engine's runtime is released")
        let stateAfterUnload = await library.state
        XCTAssertEqual(stateAfterUnload, .ready(fixture.standard.readySummary), "the package is still verified, not absent")
        resident = await library.isDefaultModelResident()
        XCTAssertFalse(resident)

        try await library.reloadResidentRuntimeIfNeeded()

        loadedID = await engine.loadedModelID
        XCTAssertEqual(loadedID, fixture.standardID, "the next dictation's prerequisite reload brings it back")
        resident = await library.isDefaultModelResident()
        XCTAssertTrue(resident)
    }

    /// A job is the *package* fact (`.inference`), not a library activity:
    /// the manager refuses to release under it and the call is a no-op, so
    /// the shell's own `.unloadModel` availability row — "finish the
    /// current dictation" — is what the user actually sees.
    func testUnloadResidentRuntimeIsANoOpWhileAJobIsActive() async throws {
        let fixture = try makeFixture()
        let engine = RecordingEngine()
        let library = try makeLibrary(fixture, engine: engine)
        try await library.installRecommendedModel()
        let jobID = UUID()
        try await library.beginInference(jobID: jobID)

        try await library.unloadResidentRuntime()

        let loadedID = await engine.loadedModelID
        XCTAssertEqual(loadedID, fixture.standardID, "must not unload out from under the running job")
        await library.endInference(jobID: jobID)
    }

    /// The 2026-09-14 review: `reloadResidentRuntimeIfNeeded()` — the
    /// prerequisite checker's reload-on-unload kickoff — used to see
    /// `ModelPackageManager.state == .ready` (untouched, because
    /// `setComputeUnits` reloads the engine directly, never through a
    /// manager) and `engine.loadedModelID == nil` (transiently true mid
    /// reload) and read that as "pressure-unloaded", firing a second,
    /// uncoordinated `engine.load(_:)` on the same actor a real
    /// `setComputeUnits` reload was already in the middle of. ADR-022
    /// item 5: `.loading` requested during `.reloadingUnits` is a rejected
    /// transition, typed and logged, and the reverse pair is refused too.
    func testReloadIsRefusedWhileAComputeUnitsReloadIsInFlightAndSucceedsOnceItFinishes() async throws {
        let fixture = try makeFixture()
        let engine = GatedComputeUnitsEngine()
        let diagnostics = RecordingDiagnosticLogger()
        let library = try makeLibrary(fixture, engine: engine, diagnostics: diagnostics)
        try await library.installRecommendedModel()
        var loadCallCount = await engine.loadCallCount
        XCTAssertEqual(loadCallCount, 1)

        let reloadTask = Task { try await library.setComputeUnits(.cpuOnly) }
        await engine.waitUntilMidReload()
        let residentDuringReload = await library.isDefaultModelResident()
        XCTAssertFalse(residentDuringReload, "loadedModelID is nil mid-reload, exactly like the real engines")
        let activityDuring = await library.activity
        XCTAssertEqual(activityDuring, .reloadingUnits)
        XCTAssertEqual(library.currentActivity, .reloadingUnits, "the synchronous copy agrees")

        // The prerequisite checker's reload-on-unload kickoff, racing the
        // compute-units reload already in flight.
        do {
            try await library.reloadResidentRuntimeIfNeeded()
            XCTFail("a pressure reload must not interleave with a compute-unit reload")
        } catch let refusal as ModelActivityRefusal {
            XCTAssertEqual(refusal, ModelActivityRefusal(requested: .loading(fixture.standardID), running: .reloadingUnits))
        }
        loadCallCount = await engine.loadCallCount
        XCTAssertEqual(loadCallCount, 1, "must not call load() a second time while the reload is in flight")

        await engine.openGate()
        try await reloadTask.value
        let activityAfter = await library.activity
        XCTAssertEqual(activityAfter, .idle)

        loadCallCount = await engine.loadCallCount
        XCTAssertEqual(loadCallCount, 1, "setComputeUnits restores loadedModelID directly; it never re-calls load()")
        var resident = await library.isDefaultModelResident()
        XCTAssertTrue(resident, "the finished compute-units reload leaves the model resident on its own")

        // Once the reload has actually finished, a fresh unload/reload pair
        // still works normally — the machine does not wedge shut.
        try await library.unloadResidentRuntime()
        let loadedIDAfterUnload = await engine.loadedModelID
        XCTAssertNil(loadedIDAfterUnload)
        try await library.reloadResidentRuntimeIfNeeded()
        loadCallCount = await engine.loadCallCount
        XCTAssertEqual(loadCallCount, 2)
        resident = await library.isDefaultModelResident()
        XCTAssertTrue(resident)

        // One scalar line for the refusal: case names only, no model ID.
        let events = await diagnostics.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.name, .modelActivityRefused)
        XCTAssertEqual(events.first?.attributes.reason?.rawValue, "loading")
        XCTAssertEqual(events.first?.attributes.site?.rawValue, "reloadingUnits")
        XCTAssertNil(events.first?.attributes.modelID)
    }

    /// The reverse of the pair above: the compute-unit reload requested
    /// while a pressure reload (`.loading`) is mid-`load` is refused.
    func testComputeUnitsReloadIsRefusedWhileAPressureReloadIsInFlight() async throws {
        let fixture = try makeFixture()
        let engine = GatedLoadEngine()
        let library = try makeLibrary(fixture, engine: engine)
        try await library.installRecommendedModel()
        try await library.unloadResidentRuntime()
        await engine.closeGate()

        let reloadTask = Task { try await library.reloadResidentRuntimeIfNeeded() }
        await engine.waitUntilLoading()
        let activity = await library.activity
        XCTAssertEqual(activity, .loading(fixture.standardID))

        do {
            try await library.setComputeUnits(.cpuOnly)
            XCTFail("a compute-unit reload must not interleave with a pressure reload")
        } catch let refusal as ModelActivityRefusal {
            XCTAssertEqual(refusal.requested, .reloadingUnits)
            XCTAssertEqual(refusal.running, .loading(fixture.standardID))
        }
        let unitsDuring = await engine.computeUnitsCalls
        XCTAssertEqual(unitsDuring, [], "nothing reached the engine")

        await engine.openGate()
        try await reloadTask.value
        let after = await library.activity
        XCTAssertEqual(after, .idle)
        try await library.setComputeUnits(.cpuOnly)
        let unitsAfter = await engine.computeUnitsCalls
        XCTAssertEqual(unitsAfter, [.cpuOnly])
    }

    /// 2026-09-14 slice-2 review: `setDefaultModel` releases and loads on the
    /// same engine actor as a compute-unit reload. Under the table it is
    /// `.loading(new)` and is refused while `.reloadingUnits` runs — and,
    /// the bug's own direction, a compute-unit reload requested while a
    /// switch is `.loading` is refused too (the GPU units that reached the
    /// Unified encoder mid-reload).
    func testSwitchingTheDefaultAndAComputeUnitsReloadRefuseEachOther() async throws {
        let fixture = try makeFixture()
        let engine = GatedComputeUnitsEngine()
        let library = try makeLibrary(fixture, engine: engine)
        try await library.installRecommendedModel()
        try await library.install(fixture.highAccuracyID)
        let defaultBefore = await library.defaultModelID

        let reloadTask = Task { try await library.setComputeUnits(.cpuOnly) }
        await engine.waitUntilMidReload()

        do {
            try await library.setDefaultModel(fixture.highAccuracyID)
            XCTFail("a default-model switch must not interleave with a reload")
        } catch let refusal as ModelActivityRefusal {
            XCTAssertEqual(refusal, ModelActivityRefusal(requested: .loading(fixture.highAccuracyID), running: .reloadingUnits))
        }
        let defaultDuring = await library.defaultModelID
        XCTAssertEqual(defaultDuring, defaultBefore, "a refusal changes nothing")
        let loadsDuring = await engine.loadCallCount
        XCTAssertEqual(loadsDuring, 1, "no second load() reached the engine")

        await engine.openGate()
        try await reloadTask.value

        // Once the reload has finished the switch works, and the machine
        // does not wedge shut.
        let changed = try await library.setDefaultModel(fixture.highAccuracyID)
        XCTAssertTrue(changed)
        let loadedID = await engine.loadedModelID
        XCTAssertEqual(loadedID, fixture.highAccuracyID)

        // The other direction: a switch is mid-load, units arrive.
        let gated = GatedLoadEngine()
        let second = try makeLibrary(fixture, engine: gated)
        try await second.installRecommendedModel()
        try await second.install(fixture.highAccuracyID)
        await gated.closeGate()
        let switchTask = Task { try await second.setDefaultModel(fixture.highAccuracyID) }
        await gated.waitUntilLoading()
        do {
            try await second.setComputeUnits(.gpuAndCPU)
            XCTFail("units must not reach the engine while a switch is loading")
        } catch let refusal as ModelActivityRefusal {
            XCTAssertEqual(refusal.requested, .reloadingUnits)
            XCTAssertEqual(refusal.running, .loading(fixture.highAccuracyID))
        }
        let unitsDuringSwitch = await gated.computeUnitsCalls
        XCTAssertEqual(unitsDuringSwitch, [])
        await gated.openGate()
        _ = try await switchTask.value
        let idle = await second.activity
        XCTAssertEqual(idle, .idle)
    }

    /// ADR-022 item 5 (c) and (d): the Runtime card's test and Transcribe
    /// File are shell-driven activities under the same table; one refuses
    /// the other in both directions, every library operation is refused
    /// under either, and unload is refused under anything — a download in
    /// flight being the long one.
    func testShellActivitiesRefuseEachOtherAndUnloadRefusesUnderAnything() async throws {
        let fixture = try makeFixture()
        let engine = RecordingEngine()
        let library = try makeLibrary(fixture, engine: engine)
        try await library.installRecommendedModel()

        try await library.beginActivity(.transcribingFile)
        await XCTAssertThrowsRefusal(try await library.beginActivity(.testing), requested: .testing, running: .transcribingFile)
        await XCTAssertThrowsRefusal(try await library.unloadResidentRuntime(), requested: .unloading, running: .transcribingFile)
        await XCTAssertThrowsRefusal(try await library.setComputeUnits(.cpuOnly), requested: .reloadingUnits, running: .transcribingFile)
        await XCTAssertThrowsRefusal(try await library.install(fixture.highAccuracyID), requested: .downloading(fixture.highAccuracyID), running: .transcribingFile)
        await XCTAssertThrowsRefusal(try await library.setDefaultModel(fixture.highAccuracyID), requested: .loading(fixture.highAccuracyID), running: .transcribingFile)
        await XCTAssertThrowsRefusal(try await library.reloadResidentRuntimeIfNeeded(), requested: .loading(fixture.standardID), running: .transcribingFile)
        await XCTAssertThrowsRefusal(try await library.delete(fixture.standardID), requested: .installing(fixture.standardID), running: .transcribingFile)
        let refreshRefusal = await library.refresh()
        XCTAssertEqual(refreshRefusal, ModelActivityRefusal(requested: .installing(fixture.standardID), running: .transcribingFile))
        let restoreRefusal = await library.restoreSelectedModel(.managed(modelID: fixture.highAccuracyID, revision: "r"))
        XCTAssertEqual(restoreRefusal, ModelActivityRefusal(requested: .installing(fixture.highAccuracyID), running: .transcribingFile))
        await library.endActivity()
        let afterFile = await library.activity
        XCTAssertEqual(afterFile, .idle)

        try await library.beginActivity(.testing)
        await XCTAssertThrowsRefusal(try await library.beginActivity(.transcribingFile), requested: .transcribingFile, running: .testing)
        await XCTAssertThrowsRefusal(try await library.unloadResidentRuntime(), requested: .unloading, running: .testing)
        await library.endActivity()
        let stillLoaded = await engine.loadedModelID
        XCTAssertEqual(stillLoaded, fixture.standardID, "nothing touched the engine")

        // Unload (and the test) during a download in flight.
        let downloader = LifecycleFixtureDownloader()
        await downloader.setHoldAtCallIndex(0)
        let downloading = try makeLibrary(fixture, engine: engine, downloader: downloader)
        let installTask = Task { try await downloading.install(fixture.highAccuracyID) }
        await downloader.waitUntilHeld()
        let during = await downloading.activity
        XCTAssertEqual(during, .downloading(fixture.highAccuracyID))
        await XCTAssertThrowsRefusal(try await downloading.unloadResidentRuntime(), requested: .unloading, running: .downloading(fixture.highAccuracyID))
        await XCTAssertThrowsRefusal(try await downloading.beginActivity(.testing), requested: .testing, running: .downloading(fixture.highAccuracyID))
        await XCTAssertThrowsRefusal(try await downloading.install(fixture.standardID), requested: .downloading(fixture.standardID), running: .downloading(fixture.highAccuracyID))
        await downloader.openGate()
        try await installTask.value
        let afterDownload = await downloading.activity
        XCTAssertEqual(afterDownload, .idle)
        let states = await downloading.states()
        XCTAssertEqual(states[fixture.highAccuracyID], .ready(fixture.highAccuracy.readySummary))
    }

    /// ADR-022 item 5 (e): every activity returns to `.idle` on success,
    /// on failure and on cancellation, and `activityChanges()` reports the
    /// transitions the shell recomputes its gate from.
    func testEveryActivityReturnsToIdleOnSuccessFailureAndCancellation() async throws {
        let fixture = try makeFixture()
        let engine = RecordingEngine()
        let library = try makeLibrary(fixture, engine: engine)
        // Read the stream directly: it keeps the newest value, so right
        // after a synchronous change `next()` returns exactly that value,
        // with no consumer task whose scheduling the assertions depend on.
        let stream = await library.activityChanges()
        var activities = stream.makeAsyncIterator()
        let initial = await activities.next()
        XCTAssertEqual(initial, .idle)

        // Success, one of each: downloading, unloading, loading (reload
        // and switch), installing (refresh, delete), reloadingUnits, and
        // the two shell activities.
        try await library.installRecommendedModel()
        try await library.install(fixture.highAccuracyID)
        try await library.unloadResidentRuntime()
        try await library.reloadResidentRuntimeIfNeeded()
        _ = try await library.setDefaultModel(fixture.highAccuracyID)
        let refreshed = await library.refresh()
        XCTAssertNil(refreshed)
        try await library.setComputeUnits(.cpuOnly)
        try await library.delete(fixture.standardID)
        try await library.beginActivity(.testing)
        let published = await activities.next()
        XCTAssertEqual(published, .testing)
        await library.endActivity()
        let publishedIdle = await activities.next()
        XCTAssertEqual(publishedIdle, .idle)
        try await library.beginActivity(.transcribingFile)
        await library.endActivity()
        let afterSuccesses = await library.activity
        XCTAssertEqual(afterSuccesses, .idle)

        // Failure: a download that fails ends `.downloading` as failed; an
        // unsupported ID never begins at all.
        let failingFixture = try makeFixture()
        let failingDownloader = LifecycleFixtureDownloader()
        await failingDownloader.setFailAtCallIndex(0)
        let failing = try makeLibrary(failingFixture, engine: RecordingEngine(), downloader: failingDownloader)
        do {
            try await failing.installRecommendedModel()
            XCTFail("the fake downloader fails the first file")
        } catch {}
        let afterFailedDownload = await failing.activity
        XCTAssertEqual(afterFailedDownload, .idle)
        do {
            _ = try await library.setDefaultModel("nope")
            XCTFail("unknown IDs are refused")
        } catch {}
        let afterUnsupported = await library.activity
        XCTAssertEqual(afterUnsupported, .idle)

        // Cancellation: a download held mid-flight, its task cancelled.
        let downloader = LifecycleFixtureDownloader()
        await downloader.setHoldAtCallIndex(0)
        let cancelling = try makeLibrary(fixture, engine: RecordingEngine(), downloader: downloader)
        try await cancelling.delete(fixture.highAccuracyID)
        let installTask = Task { try await cancelling.install(fixture.highAccuracyID) }
        await downloader.waitUntilHeld()
        let mid = await cancelling.activity
        XCTAssertEqual(mid, .downloading(fixture.highAccuracyID))
        installTask.cancel()
        _ = try? await installTask.value
        let afterCancel = await cancelling.activity
        XCTAssertEqual(afterCancel, .idle)

        // Ending when nothing runs is harmless.
        await library.endActivity()
        let idle = await library.activity
        XCTAssertEqual(idle, .idle)
        XCTAssertEqual(library.currentActivity, .idle)
    }

    // MARK: Helpers

    func testStagingIsIsolatedPerModelSoRefreshNeverRemovesAnotherModelsPausedDownload() async throws {
        let fixture = try makeFixture()
        let engine = RecordingEngine()
        // A download for the high-accuracy model fails on its third file so
        // its stage is kept for retry.
        let failing = LifecycleFixtureDownloader()
        await failing.setFailAtCallIndex(2)
        let library = try SpeechModelLibrary(
            loaded: fixture.loaded,
            storageDirectoryURL: fixture.storageURL,
            engine: engine,
            makeDownloader: { failing },
            urlProvider: TwoSourceURLProvider(
                roots: [
                    fixture.standardID: fixture.standard.sourceURL,
                    fixture.highAccuracyID: fixture.highAccuracy.sourceURL
                ]
            ),
            volumeCapacity: FixedVolumeCapacityProvider(availableBytes: Int64.max),
            appVersion: "test-build"
        )
        _ = try? await library.install(fixture.highAccuracyID)
        let pausedStages = try FileManager.default.contentsOfDirectory(
            at: fixture.highAccuracy.stagingRootURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(pausedStages.count, 1, "the failed download keeps its stage")
        XCTAssertNotEqual(
            fixture.highAccuracy.stagingRootURL, fixture.standard.stagingRootURL,
            "each model stages under its own root"
        )

        // Refreshing everything (which runs the standard model's staging
        // housekeeping) leaves the other model's stage alone.
        await library.refresh()
        let afterRefresh = try FileManager.default.contentsOfDirectory(
            at: fixture.highAccuracy.stagingRootURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(afterRefresh.count, 1)
        let state = await library.state(of: fixture.highAccuracyID)
        guard case .error? = state else {
            return XCTFail("expected the failed download to stay visible, got \(String(describing: state))")
        }
    }

    func testPerModelOperationsRouteToTheRightManagerAndUnknownIDsThrow() async throws {
        let fixture = try makeFixture()
        let engine = RecordingEngine()
        let library = try makeLibrary(fixture, engine: engine)

        try await library.install(fixture.highAccuracyID)
        let package = try await library.verifiedPackage(for: fixture.highAccuracyID)
        XCTAssertEqual(package.manifest.modelID, fixture.highAccuracyID)
        let estimate = await library.installationSpaceEstimate(for: fixture.standardID)
        XCTAssertEqual(
            estimate?.remainingDownloadBytes,
            fixture.standard.manifest.files.reduce(0) { $0 + $1.bytes },
            "the estimate is that model's own manifest, not the default's"
        )
        let reference = await library.modelReference(for: fixture.highAccuracyID)
        XCTAssertEqual(reference, .managed(modelID: fixture.highAccuracyID, revision: fixture.highAccuracy.manifest.source.revision))
        let nilReference = await library.modelReference(for: fixture.standardID)
        XCTAssertNil(nilReference)

        do {
            try await library.install("unknown")
            XCTFail("unknown IDs are refused")
        } catch {
            XCTAssertEqual(error as? ModelManagementError, .unsupportedModel("unknown"))
        }
        let missingState = await library.state(of: "unknown")
        XCTAssertNil(missingState)
    }
}

/// Records what the shared engine is asked to load and unload.
private actor RecordingEngine: TranscriptionEngine {
    let capabilities = TranscriptionCapabilities(
        supportsBatch: true,
        supportsStreaming: false,
        supportsCancellation: true,
        supportedSampleRate: 16_000,
        supportedChannelCount: 1
    )
    private(set) var loadedModelID: ModelID?
    private(set) var loadedIDs: [ModelID] = []
    private(set) var unloadCount = 0

    func load(_ package: InstalledModelPackage) async throws {
        loadedModelID = package.manifest.modelID
        loadedIDs.append(package.manifest.modelID)
    }

    func unload() async {
        loadedModelID = nil
        unloadCount += 1
    }

    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> TranscriptionResult {
        throw KVoiceError(code: .sttFailed)
    }
}

/// Simulates the real engines' `setComputeUnits` reload — `loadedModelID`
/// goes `nil` for the duration, exactly like `WhisperTranscriptionEngine`
/// and `ParakeetTranscriptionEngine` while `replaceRuntime` runs — but pauses
/// mid-reload until the test opens the gate, so a test can call another
/// library method while a reload is provably in flight (2026-09-14 review:
/// `reloadResidentRuntimeIfNeeded()` used to race exactly this window).
private actor GatedComputeUnitsEngine: TranscriptionEngine {
    let capabilities = TranscriptionCapabilities(
        supportsBatch: true,
        supportsStreaming: false,
        supportsCancellation: true,
        supportedSampleRate: 16_000,
        supportedChannelCount: 1
    )
    private(set) var loadedModelID: ModelID?
    private(set) var loadCallCount = 0
    private var isGateOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var reloadsInFlight = 0

    func load(_ package: InstalledModelPackage) async throws {
        loadedModelID = package.manifest.modelID
        loadCallCount += 1
    }

    func unload() async { loadedModelID = nil }

    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> TranscriptionResult {
        throw KVoiceError(code: .sttFailed)
    }

    func setComputeUnits(_ units: SpeechComputeUnits) async throws {
        let previous = loadedModelID
        loadedModelID = nil
        reloadsInFlight += 1
        await waitForGate()
        reloadsInFlight -= 1
        loadedModelID = previous
    }

    /// Returns once a `setComputeUnits` call is parked at the gate, so the
    /// race a test exists for is real rather than assumed. Never real time;
    /// fails after `testYieldBudget` yields.
    func waitUntilMidReload(file: StaticString = #filePath, line: UInt = #line) async {
        var yields = 0
        while reloadsInFlight == 0 {
            yields += 1
            if yields > testYieldBudget {
                return XCTFail("waitUntilMidReload: `reloadsInFlight == 0` still held after \(testYieldBudget) yields; reloadsInFlight = \(reloadsInFlight)", file: file, line: line)
            }
            await Task.yield()
        }
    }

    /// Lets the test's `Task` past the gate; safe to call before or after
    /// `setComputeUnits` reaches it.
    func openGate() {
        isGateOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    private func waitForGate() async {
        if isGateOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// Pauses inside `load(_:)` until the test opens the gate, so a
/// `.loading` activity (a default switch, a pressure reload) is provably
/// in flight while another library method is called. `setComputeUnits` is
/// recorded and returns at once.
private actor GatedLoadEngine: TranscriptionEngine {
    let capabilities = TranscriptionCapabilities(
        supportsBatch: true,
        supportsStreaming: false,
        supportsCancellation: true,
        supportedSampleRate: 16_000,
        supportedChannelCount: 1
    )
    private(set) var loadedModelID: ModelID?
    private(set) var loadsInFlight = 0
    private(set) var computeUnitsCalls: [SpeechComputeUnits] = []
    private var isGateOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func load(_ package: InstalledModelPackage) async throws {
        loadsInFlight += 1
        defer { loadsInFlight -= 1 }
        if !isGateOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        loadedModelID = package.manifest.modelID
    }

    func unload() async { loadedModelID = nil }

    func setComputeUnits(_ units: SpeechComputeUnits) async throws {
        computeUnitsCalls.append(units)
    }

    func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> TranscriptionResult {
        throw KVoiceError(code: .sttFailed)
    }

    /// The gate starts open so the fixture installs load at once; a test
    /// closes it right before the load it wants to hold.
    func closeGate() { isGateOpen = false }

    /// Returns once a `load` is in flight (parked at the closed gate).
    /// Never real time; fails after `testYieldBudget` yields.
    func waitUntilLoading(file: StaticString = #filePath, line: UInt = #line) async {
        var yields = 0
        while loadsInFlight == 0 {
            yields += 1
            if yields > testYieldBudget {
                return XCTFail("waitUntilLoading: `loadsInFlight == 0` still held after \(testYieldBudget) yields; loadsInFlight = \(loadsInFlight)", file: file, line: line)
            }
            await Task.yield()
        }
    }

    func openGate() {
        isGateOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor RecordingDiagnosticLogger: DiagnosticLogging {
    private(set) var events: [DiagnosticEvent] = []

    func log(_ event: DiagnosticEvent) async {
        events.append(event)
    }
}

/// Asserts that `expression` throws exactly the typed refusal.
private func XCTAssertThrowsRefusal<T>(
    _ expression: @autoclosure () async throws -> T,
    requested: ModelActivity,
    running: ModelActivity,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("\(requested.name) must be refused while \(running.name) runs", file: file, line: line)
    } catch let refusal as ModelActivityRefusal {
        XCTAssertEqual(refusal, ModelActivityRefusal(requested: requested, running: running), file: file, line: line)
    } catch {
        XCTFail("expected a ModelActivityRefusal, got \(error)", file: file, line: line)
    }
}

/// Serves each model's files from its own fixture source tree.
private struct TwoSourceURLProvider: ModelDownloadURLProviding {
    let roots: [ModelID: URL]

    func url(for descriptor: ModelFileDescriptor, manifest: ModelManifest) throws -> URL {
        guard let root = roots[manifest.modelID] else {
            throw ModelManagementError.unsupportedModel(manifest.modelID)
        }
        return try ModelRelativePath.url(for: descriptor.path, under: root)
    }
}
