import Foundation
import KvoiceDomain
import KvoiceModelManagement
import XCTest

/// Spec coverage: FR-MODEL-006 (free-space gate), FR-MODEL-016 (stale staging
/// cleanup), C.10/FR-MODEL-017 (staged deletion with retry), C.4 step 6
/// (external reference restore), C.3 step 12 (sentinel fields).
final class ModelPackageManagerLifecycleTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            // A deletion-failure test leaves a read-only tree behind.
            restoreWritePermissions(under: url)
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    // MARK: - Free-space gate (FR-MODEL-006)

    func testInsufficientSpaceStartsNoDownloadAndStatesBytes() async throws {
        let fixture = try ModelLifecycleFixture.make(in: &temporaryURLs)
        let downloader = LifecycleFixtureDownloader()
        let available: Int64 = 12_345
        let manager = fixture.makeManager(downloader: downloader, availableBytes: available)
        let expectedRequired = ModelLifecycleFixture.totalBytes + fixture.manifest.workingSpaceBytes

        let estimate = await manager.installationSpaceEstimate()
        XCTAssertEqual(estimate.requiredBytes, expectedRequired)
        XCTAssertEqual(estimate.remainingDownloadBytes, ModelLifecycleFixture.totalBytes)
        XCTAssertEqual(estimate.availableBytes, available)
        XCTAssertTrue(estimate.isInsufficient)

        do {
            try await manager.installRecommendedModel()
            XCTFail("expected the free-space gate to refuse")
        } catch {
            XCTAssertEqual(
                error as? ModelManagementError,
                .insufficientDiskSpace(requiredBytes: expectedRequired, availableBytes: available)
            )
        }

        let downloadCount = await downloader.downloadCount
        XCTAssertEqual(downloadCount, 0, "no download may start when space is insufficient")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.stagingRootURL.path),
            "no staging directory may be created"
        )

        let observedState = await manager.state
        guard case let .error(failure) = observedState else {
            return XCTFail("expected an error state, got \(String(describing: observedState))")
        }
        XCTAssertEqual(failure.code, "MODEL-INSUFFICIENT-DISK")
        XCTAssertTrue(
            failure.message.contains(ModelInstallationSpaceEstimate.format(expectedRequired)),
            "message must state required bytes: \(failure.message)"
        )
        XCTAssertTrue(
            failure.message.contains(ModelInstallationSpaceEstimate.format(available)),
            "message must state available bytes: \(failure.message)"
        )

        // The failure stays visible across an app activation.
        await manager.refresh()
        guard case .error = await manager.state else {
            return XCTFail("refresh must not reset a disk-space failure to absent")
        }
    }

    func testSufficientSpaceProceeds() async throws {
        let fixture = try ModelLifecycleFixture.make(in: &temporaryURLs)
        let required = ModelLifecycleFixture.totalBytes + fixture.manifest.workingSpaceBytes
        let manager = fixture.makeManager(availableBytes: required)

        try await manager.installRecommendedModel()

        let state = await manager.state
        XCTAssertEqual(state, .ready(fixture.readySummary))
    }

    func testUnknownCapacityDoesNotBlockInstallation() async throws {
        let fixture = try ModelLifecycleFixture.make(in: &temporaryURLs)
        let manager = fixture.makeManager(availableBytes: nil)

        let estimate = await manager.installationSpaceEstimate()
        XCTAssertNil(estimate.availableBytes)
        XCTAssertFalse(estimate.isInsufficient)

        try await manager.installRecommendedModel()
        let state = await manager.state
        XCTAssertEqual(state, .ready(fixture.readySummary))
    }

    func testInsufficientSpaceOnReplacementKeepsInstalledPackageIntact() async throws {
        let fixture = try ModelLifecycleFixture.make(in: &temporaryURLs)
        let capacity = MutableVolumeCapacityProvider(availableBytes: Int64.max)
        let loader = LifecycleRecordingLoader()
        let manager = fixture.makeManager(loader: loader, capacity: capacity)
        try await manager.installRecommendedModel()

        capacity.availableBytes = 0
        do {
            try await manager.installRecommendedModel()
            XCTFail("expected the free-space gate to refuse")
        } catch {
            guard case .insufficientDiskSpace? = error as? ModelManagementError else {
                return XCTFail("unexpected error \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.managedPackageURL.path))
        let unloadCount = await loader.unloadCount
        XCTAssertEqual(unloadCount, 0, "a refused replacement must not unload the active package")

        // Once space is back, the package on disk is still verifiable and reloads.
        capacity.availableBytes = Int64.max
        await manager.refresh()
        let state = await manager.state
        XCTAssertEqual(state, .ready(fixture.readySummary))
    }

    func testResumeEstimateSubtractsCompletedBytesAndRetryRestartsOnlyTheIncompleteFile() async throws {
        let fixture = try ModelLifecycleFixture.make(in: &temporaryURLs)
        let downloader = LifecycleFixtureDownloader()
        await downloader.setFailAtCallIndex(2)
        let manager = fixture.makeManager(downloader: downloader)

        do {
            try await manager.installRecommendedModel()
            XCTFail("expected the third download to fail")
        } catch {
            guard case .installFailed? = error as? ModelManagementError else {
                return XCTFail("unexpected error \(error)")
            }
        }
        guard case .error = await manager.state else {
            return XCTFail("a network failure must surface as an error state")
        }

        let completedBytes = fixture.files.prefix(2).reduce(Int64(0)) { $0 + Int64($1.1.count) }
        let estimate = await manager.installationSpaceEstimate()
        XCTAssertEqual(
            estimate.remainingDownloadBytes,
            ModelLifecycleFixture.totalBytes - completedBytes,
            "a paused download only needs the bytes it has not fetched"
        )
        let stageEntries = try FileManager.default.contentsOfDirectory(
            at: fixture.stagingRootURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(stageEntries.count, 1, "completed files must be preserved for retry")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: stageEntries[0].appendingPathComponent("download-state.json").path
        ))

        await downloader.setFailAtCallIndex(nil)
        try await manager.retryInstallation()

        let state = await manager.state
        XCTAssertEqual(state, .ready(fixture.readySummary))
        let downloadCount = await downloader.downloadCount
        XCTAssertEqual(
            downloadCount,
            fixture.files.count + 1,
            "retry must restart only the failed file, not the completed ones"
        )
    }

    // MARK: - Stale staging cleanup (FR-MODEL-016)

    func testRefreshAdoptsRecentResumableStagingAndRemovesItAfterSevenDays() async throws {
        let fixture = try ModelLifecycleFixture.make(in: &temporaryURLs)
        let pausedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let stageURL = try await makePausedStage(fixture: fixture, at: pausedAt)

        // Six days later: still resumable, adopted as the paused download.
        let recent = fixture.makeManager(clock: { pausedAt.addingTimeInterval(6 * 24 * 3600) })
        await recent.refresh()
        let recentState = await recent.state
        XCTAssertEqual(recentState, .downloadPaused(resumableBytes: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stageURL.path))
        try await recent.retryInstallation()
        let resumedState = await recent.state
        XCTAssertEqual(resumedState, .ready(fixture.readySummary))

        // A fresh stage older than seven days is removed at launch.
        try FileManager.default.removeItem(at: fixture.managedPackageURL)
        let staleStageURL = try await makePausedStage(fixture: fixture, at: pausedAt)
        let stale = fixture.makeManager(clock: {
            pausedAt.addingTimeInterval(ModelPackageManager.staleStagingAge + 1)
        })
        await stale.refresh()
        let staleState = await stale.state
        XCTAssertEqual(staleState, .absent)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staleStageURL.path),
            "resumable state older than seven days must be removed on launch"
        )
    }

    func testRefreshRemovesStructurallyInvalidStagingImmediately() async throws {
        let fixture = try ModelLifecycleFixture.make(in: &temporaryURLs)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // No bookkeeping at all: a stage from a process that died mid-setup.
        let junkStage = fixture.stagingRootURL.appendingPathComponent("model-junk", isDirectory: true)
        try FileManager.default.createDirectory(at: junkStage, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: junkStage.appendingPathComponent("partial.bin"))

        // Bookkeeping that claims a completed file which is not there.
        let brokenStage = try await makePausedStage(fixture: fixture, at: now)
        let firstFile = brokenStage.appendingPathComponent(fixture.files[0].0)
        try FileManager.default.removeItem(at: firstFile)

        let manager = fixture.makeManager(clock: { now })
        await manager.refresh()

        XCTAssertFalse(FileManager.default.fileExists(atPath: junkStage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: brokenStage.path))
        let state = await manager.state
        XCTAssertEqual(state, .absent)
    }

    // MARK: - Staged deletion (C.10, FR-MODEL-017)

    func testDeleteRenamesAtomicallyThenRemovesAsynchronously() async throws {
        let fixture = try ModelLifecycleFixture.make(in: &temporaryURLs)
        let loader = LifecycleRecordingLoader()
        let manager = fixture.makeManager(loader: loader)
        try await manager.installRecommendedModel()

        try await manager.deleteManagedPackage()

        let state = await manager.state
        XCTAssertEqual(state, .absent, "state is absent as soon as the rename lands")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.managedPackageURL.path))
        let unloadCount = await loader.unloadCount
        XCTAssertEqual(unloadCount, 1)
        let reference = await manager.currentModelReference()
        XCTAssertNil(reference)
        try await waitUntilTrue { await manager.pendingDeletionCount() == 0 }
    }

    func testFailedDeleteLeavesPendingMarkerAndIsRetriedOnRefresh() async throws {
        let fixture = try ModelLifecycleFixture.make(in: &temporaryURLs)
        let manager = fixture.makeManager()
        try await manager.installRecommendedModel()

        // A read-only directory cannot have its children unlinked, so the
        // asynchronous removal fails while the rename still succeeds.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: fixture.managedPackageURL.path
        )

        try await manager.deleteManagedPackage()

        let state = await manager.state
        XCTAssertEqual(state, .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.managedPackageURL.path))
        // Give the detached removal a chance to (fail to) run.
        try await Task.sleep(for: .milliseconds(200))
        let pendingCount = await manager.pendingDeletionCount()
        XCTAssertEqual(pendingCount, 1, "a failed removal must leave the Delete Pending marker")
        let hasPending = await manager.hasPendingDeletion()
        XCTAssertTrue(hasPending)

        // A refresh while removal is still impossible keeps the marker and
        // stays absent — the active location never references the tree.
        await manager.refresh()
        let stillPending = await manager.pendingDeletionCount()
        XCTAssertEqual(stillPending, 1)
        let refreshedState = await manager.state
        XCTAssertEqual(refreshedState, .absent)

        // Once the obstruction is gone (permissions, space), the next launch
        // completes the deletion.
        restoreWritePermissions(under: fixture.storageURL)
        await manager.refresh()
        let finalPending = await manager.pendingDeletionCount()
        XCTAssertEqual(finalPending, 0)
        let finalState = await manager.state
        XCTAssertEqual(finalState, .absent)
    }

    // MARK: - External reference persistence (C.4 step 6)

    func testSelectExternalYieldsPersistableReferenceAndRestoreLoadsIt() async throws {
        let fixture = try ModelLifecycleFixture.make(in: &temporaryURLs)
        let external = try fixture.writePackage(
            at: ModelLifecycleFixture.makeTemporaryDirectory(in: &temporaryURLs)
                .appendingPathComponent("pkg", isDirectory: true)
        )
        let first = fixture.makeManager()
        try await first.selectExternalPackage(at: external)
        let reference = await first.currentModelReference()
        XCTAssertEqual(reference, .external(
            path: external.standardizedFileURL.path,
            expectedModelID: fixture.manifest.modelID,
            expectedRevision: fixture.manifest.source.revision
        ))

        // A new launch restores the same reference from settings.
        let loader = LifecycleRecordingLoader()
        let second = fixture.makeManager(loader: loader)
        await second.restoreSelectedModel(reference)
        let state = await second.state
        XCTAssertEqual(state, .ready(fixture.externalReadySummary))
        let loadedURLs = await loader.loadedPackageURLs
        XCTAssertEqual(loadedURLs, [external.standardizedFileURL])
        let restored = await second.currentModelReference()
        XCTAssertEqual(restored, reference)

        // Activation refreshes keep it resident without reloading.
        await second.refresh()
        let loadCount = await loader.loadCount
        XCTAssertEqual(loadCount, 1)
    }

    func testRestoreFailsClosedWhenExternalPathIsMissingAndRecoversWhenItReturns() async throws {
        let fixture = try ModelLifecycleFixture.make(in: &temporaryURLs)
        let volume = ModelLifecycleFixture.makeTemporaryDirectory(in: &temporaryURLs)
        let missing = volume.appendingPathComponent("unmounted/pkg", isDirectory: true)
        let reference = ModelReference.external(
            path: missing.path,
            expectedModelID: fixture.manifest.modelID,
            expectedRevision: fixture.manifest.source.revision
        )
        let loader = LifecycleRecordingLoader()
        let manager = fixture.makeManager(loader: loader)

        await manager.restoreSelectedModel(reference)

        let observedState = await manager.state
        guard case let .error(failure) = observedState else {
            return XCTFail("expected a fail-closed error, got \(String(describing: observedState))")
        }
        XCTAssertEqual(failure.code, "MODEL-PATH-UNREADABLE")
        XCTAssertTrue(failure.message.contains(missing.standardizedFileURL.path))
        XCTAssertTrue(failure.message.lowercased().contains("forget"))
        let loadCount = await loader.loadCount
        XCTAssertEqual(loadCount, 0, "a missing path must never reach the runtime")
        let retained = await manager.currentModelReference()
        XCTAssertEqual(retained, reference, "the reference is kept so the user can reselect or forget")
        do {
            _ = try await manager.verifiedPackage()
            XCTFail("no package may be handed out while the reference is missing")
        } catch {}

        // The volume comes back: the next activation loads it.
        try fixture.writePackage(at: missing)
        await manager.refresh()
        let recovered = await manager.state
        XCTAssertEqual(recovered, .ready(fixture.externalReadySummary))

        // Forget clears only the reference; the user's files stay.
        await manager.forgetExternalPackage()
        let forgottenState = await manager.state
        XCTAssertEqual(forgottenState, .absent)
        let forgottenReference = await manager.currentModelReference()
        XCTAssertNil(forgottenReference)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: missing.appendingPathComponent("model/config.json").path
        ))
    }

    func testRestoreFailsClosedWhenExternalPackageChangedAndNeverDeletes() async throws {
        let fixture = try ModelLifecycleFixture.make(in: &temporaryURLs)
        let external = try fixture.writePackage(
            at: ModelLifecycleFixture.makeTemporaryDirectory(in: &temporaryURLs)
                .appendingPathComponent("pkg", isDirectory: true)
        )
        let corruptPath = external.appendingPathComponent("model/config.json")
        var corrupt = try Data(contentsOf: corruptPath)
        corrupt[0] ^= 0x01
        try corrupt.write(to: corruptPath, options: .atomic)
        let loader = LifecycleRecordingLoader()
        let manager = fixture.makeManager(loader: loader)

        await manager.restoreSelectedModel(.external(
            path: external.path,
            expectedModelID: fixture.manifest.modelID,
            expectedRevision: fixture.manifest.source.revision
        ))

        let observedState = await manager.state
        guard case let .corrupt(failure) = observedState else {
            return XCTFail("expected a corrupt state, got \(String(describing: observedState))")
        }
        XCTAssertTrue(failure.message.contains("changed since it was selected"))
        let loadCount = await loader.loadCount
        XCTAssertEqual(loadCount, 0)
        for (path, _) in fixture.files {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: external.appendingPathComponent(path).path),
                "external files are never deleted: \(path)"
            )
        }
        XCTAssertEqual(try Data(contentsOf: corruptPath), corrupt, "external files are never rewritten")

        // Activation must not re-hash a known-bad selection.
        await manager.refresh()
        let stateAfterRefresh = await manager.state
        XCTAssertEqual(stateAfterRefresh, .corrupt(failure))
    }

    func testRestoreRejectsAReferenceToAnotherRevision() async throws {
        let fixture = try ModelLifecycleFixture.make(in: &temporaryURLs)
        let external = try fixture.writePackage(
            at: ModelLifecycleFixture.makeTemporaryDirectory(in: &temporaryURLs)
                .appendingPathComponent("pkg", isDirectory: true)
        )
        let loader = LifecycleRecordingLoader()
        let manager = fixture.makeManager(loader: loader)

        await manager.restoreSelectedModel(.external(
            path: external.path,
            expectedModelID: fixture.manifest.modelID,
            expectedRevision: "0000000000000000000000000000000000000000"
        ))

        let observedState = await manager.state
        guard case let .incompatible(failure) = observedState else {
            return XCTFail("expected an incompatible state, got \(String(describing: observedState))")
        }
        XCTAssertEqual(failure.code, "MODEL-INCOMPATIBLE")
        let loadCount = await loader.loadCount
        XCTAssertEqual(loadCount, 0)
    }

    func testManagedInstallReplacesExternalReference() async throws {
        let fixture = try ModelLifecycleFixture.make(in: &temporaryURLs)
        let external = try fixture.writePackage(
            at: ModelLifecycleFixture.makeTemporaryDirectory(in: &temporaryURLs)
                .appendingPathComponent("pkg", isDirectory: true)
        )
        let manager = fixture.makeManager()
        try await manager.selectExternalPackage(at: external)

        try await manager.installRecommendedModel()

        let reference = await manager.currentModelReference()
        XCTAssertEqual(reference, .managed(
            modelID: fixture.manifest.modelID,
            revision: fixture.manifest.source.revision
        ))
        await manager.restoreSelectedModel(reference)
        let state = await manager.state
        XCTAssertEqual(state, .ready(fixture.readySummary))
    }

    // MARK: - Sentinel (C.3 step 12)

    func testInstalledSentinelRecordsCanonicalFieldsAndRoundTrips() async throws {
        let fixture = try ModelLifecycleFixture.make(in: &temporaryURLs)
        let installedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let manager = fixture.makeManager(clock: { installedAt }, appVersion: "1.2.3")
        try await manager.installRecommendedModel()

        let data = try Data(contentsOf: fixture.managedPackageURL.appendingPathComponent(".installed.json"))
        let sentinel = try JSONDecoder().decode(InstalledModelSentinel.self, from: data)
        XCTAssertEqual(sentinel.schemaVersion, InstalledModelSentinel.currentSchemaVersion)
        XCTAssertEqual(sentinel.modelID, fixture.manifest.modelID)
        XCTAssertEqual(sentinel.repository, fixture.manifest.source.repository)
        XCTAssertEqual(sentinel.revision, fixture.manifest.source.revision)
        XCTAssertEqual(sentinel.manifestVersion, fixture.manifest.schemaVersion)
        XCTAssertEqual(sentinel.manifestSHA256, fixture.anchor.manifestSHA256)
        XCTAssertEqual(sentinel.installedBytes, ModelLifecycleFixture.totalBytes)
        XCTAssertEqual(sentinel.installedAt, installedAt)
        XCTAssertEqual(sentinel.appVersion, "1.2.3")
        XCTAssertEqual(sentinel.ownership, .managedByKvoice)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(json.keys),
            [
                "schemaVersion", "modelID", "repository", "revision", "manifestVersion",
                "manifestSHA256", "installedBytes", "installedAt", "appVersion", "ownership"
            ]
        )
        XCTAssertEqual(json["ownership"] as? String, "managed")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reencoded = try encoder.encode(sentinel)
        XCTAssertEqual(try JSONDecoder().decode(InstalledModelSentinel.self, from: reencoded), sentinel)
    }

    // MARK: - Helpers

    /// Produces a stage with two completed files and a `download-state.json`
    /// stamped at `date`, the way a network failure leaves it.
    private func makePausedStage(fixture: ModelLifecycleFixture, at date: Date) async throws -> URL {
        let downloader = LifecycleFixtureDownloader()
        await downloader.setFailAtCallIndex(2)
        let manager = fixture.makeManager(downloader: downloader, clock: { date })
        _ = try? await manager.installRecommendedModel()
        let entries = try FileManager.default.contentsOfDirectory(
            at: fixture.stagingRootURL,
            includingPropertiesForKeys: nil
        )
        // Pick the stage that actually carries bookkeeping: a test may have
        // planted other `model-*` directories, and directory order is not
        // stable.
        let stage = try XCTUnwrap(entries.first {
            $0.lastPathComponent.hasPrefix("model-")
                && FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent("download-state.json").path
                )
        })
        return stage
    }

    private func restoreWritePermissions(under root: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
    }
}
