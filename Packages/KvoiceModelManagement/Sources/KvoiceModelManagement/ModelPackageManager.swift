import Foundation
import KvoiceDomain
import KvoiceTranscription

/// Owns managed model acquisition, verification, loading, and deletion.
///
/// Every package operation is serialized by this actor. Files are downloaded
/// into a sibling staging directory, verified against the app-trusted release,
/// and only then moved into the managed model location.
///
/// On-disk layout under `storageDirectoryURL`:
///
/// ```text
/// Models/<modelID>/<revision>/                 the active managed package
/// Models/<modelID>/<revision>.deleting-<uuid>/ a delete that has not finished
/// .staging/model-<uuid>/                       a download in progress or paused
/// .staging/model-<uuid>/download-state.json    resume bookkeeping for that stage
/// ```
///
/// A `.deleting-` directory is the "Delete Pending" marker from spec C.10; it
/// is retried on every `refresh()`. A stage without a valid
/// `download-state.json`, or one not touched for seven days, is removed on
/// `refresh()` (FR-MODEL-016).
public actor ModelPackageManager: ModelPackageProviding {
    public private(set) var state: ModelLifecycleState = .absent

    /// Resumable download state older than this is removed at launch.
    public static let staleStagingAge: TimeInterval = 7 * 24 * 60 * 60

    static let deletionMarkerInfix = ".deleting-"
    static let stagingDirectoryName = ".staging"

    private struct InstallationContext: Sendable {
        let id: UUID
        let stageURL: URL
        let nextFileIndex: Int
        let completedBytes: Int64
        let resumeData: Data?
    }

    private enum ExternalSelectionStatus: Sendable {
        /// Verified and resident in the runtime.
        case loaded
        /// The folder is not there (moved, deleted, unmounted). Re-checked on
        /// every refresh so a remounted volume comes back on its own.
        case missing
        /// The folder is there but failed verification. Not re-hashed on
        /// every activation; the user must reselect, restore, or forget it.
        case invalid
    }

    private struct ExternalSelection: Sendable {
        let url: URL
        var status: ExternalSelectionStatus
    }

    private let trustedRelease: WhisperModelReleaseTrustAnchor
    private let verifier: ModelPackageVerifier
    private let runtimeLoader: any ModelRuntimeLoader
    private let downloader: any ModelDownloadClient
    private let urlProvider: any ModelDownloadURLProviding
    private let volumeCapacity: any ModelVolumeCapacityProviding
    private let clock: ModelClock
    private let storageDirectoryURL: URL
    private let appVersion: String
    private let fileManager = FileManager.default

    private var currentPackage: InstalledModelPackage?
    private var externalSelection: ExternalSelection?
    private var activeJobID: JobID?
    private var activeInstallation: InstallationContext?
    private var pendingInstallation: InstallationContext?
    private var cancellationRequested = false

    public init(
        trustedRelease: WhisperModelReleaseTrustAnchor,
        storageDirectoryURL: URL,
        runtimeLoader: any ModelRuntimeLoader = UnavailableModelRuntimeLoader(),
        downloader: any ModelDownloadClient = URLSessionModelDownloadClient(),
        urlProvider: any ModelDownloadURLProviding = PinnedHuggingFaceModelURLProvider(),
        volumeCapacity: any ModelVolumeCapacityProviding = FileManagerVolumeCapacityProvider(),
        clock: @escaping ModelClock = { Date() },
        appVersion: String = ModelPackageManager.defaultAppVersion()
    ) {
        self.trustedRelease = trustedRelease
        verifier = ModelPackageVerifier(trustedRelease: trustedRelease)
        self.runtimeLoader = runtimeLoader
        self.downloader = downloader
        self.urlProvider = urlProvider
        self.volumeCapacity = volumeCapacity
        self.clock = clock
        self.storageDirectoryURL = storageDirectoryURL.standardizedFileURL
        self.appVersion = appVersion
    }

    /// Convenience initializer for the existing resident transcription actor.
    public init(
        trustedRelease: WhisperModelReleaseTrustAnchor,
        storageDirectoryURL: URL,
        transcriptionEngine: any TranscriptionEngine,
        downloader: any ModelDownloadClient = URLSessionModelDownloadClient(),
        urlProvider: any ModelDownloadURLProviding = PinnedHuggingFaceModelURLProvider(),
        volumeCapacity: any ModelVolumeCapacityProviding = FileManagerVolumeCapacityProvider(),
        clock: @escaping ModelClock = { Date() },
        appVersion: String = ModelPackageManager.defaultAppVersion()
    ) {
        self.init(
            trustedRelease: trustedRelease,
            storageDirectoryURL: storageDirectoryURL,
            runtimeLoader: TranscriptionEngineModelRuntimeLoader(engine: transcriptionEngine),
            downloader: downloader,
            urlProvider: urlProvider,
            volumeCapacity: volumeCapacity,
            clock: clock,
            appVersion: appVersion
        )
    }

    public static func defaultStorageDirectoryURL() -> URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
            .appendingPathComponent("kvoice", isDirectory: true)
    }

    /// The marketing version of the running app, recorded in `.installed.json`.
    public static func defaultAppVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "development"
    }

    // MARK: - Refresh

    /// Rechecks the selected package and loads it when it is present. Refresh
    /// is intentionally non-throwing because it is normally called during app
    /// launch; failures remain visible through `state`.
    ///
    /// Also performs launch-time housekeeping: retries pending deletions and
    /// removes stale or structurally invalid staging directories.
    public func refresh() async {
        guard activeJobID == nil, activeInstallation == nil else { return }
        do {
            try ensurePinnedRelease()
        } catch {
            state = .error(failure(for: error))
            return
        }

        retryPendingDeletions()
        cleanUpStaging()

        // An externally selected package lives outside the managed location.
        // Refresh runs on launch *and* on every app activation, so it must not
        // discard a loaded external model merely because the user switched
        // away from the app and back; it fails closed only when the folder
        // actually disappears, and comes back when a missing volume returns.
        if externalSelection != nil {
            await refreshExternalSelection()
            return
        }

        let packageURL = managedPackageURL
        guard fileManager.fileExists(atPath: packageURL.path) else {
            currentPackage = nil
            if isFailureState {
                // A terminal failure (insufficient disk, corrupt selection,
                // failed download, …) stays visible until the user acts on
                // it; an activation must not silently reset it to Absent.
            } else if let pendingInstallation {
                state = .downloadPaused(resumableBytes: pendingInstallation.resumeData.map { Int64($0.count) })
            } else {
                state = .absent
            }
            return
        }

        // Already verified and resident: re-hashing every artifact and
        // recompiling the CoreML model would otherwise happen on *every* app
        // activation, which made a ready model drop back to Not Ready for the
        // duration and repeat the multi-minute load each time.
        if let loaded = currentPackage,
           loaded.ownership == .managedByKvoice,
           loaded.packageURL.standardizedFileURL == packageURL.standardizedFileURL,
           isReadyOrInInference {
            return
        }

        do {
            state = .verifying(completedFiles: 0, totalFiles: trustedRelease.manifest.files.count)
            let package = try verifier.makePackage(at: packageURL, ownership: .managedByKvoice)
            try verifier.verify(package)
            try await loadVerifiedPackage(package)
        } catch {
            currentPackage = nil
            state = isVerificationError(error)
                ? .corrupt(failure(for: error))
                : .error(failure(for: error))
        }
    }

    // MARK: - Free-space gate

    /// What the next managed download needs versus what the storage volume
    /// offers. Accounts for a paused download's already-completed bytes.
    /// Intended for "about X GB, Y free" surfaces before the user commits.
    public func installationSpaceEstimate() -> ModelInstallationSpaceEstimate {
        let total = (try? totalBytes()) ?? 0
        let completed = pendingInstallation?.completedBytes ?? 0
        return ModelInstallationSpaceEstimate(
            remainingDownloadBytes: total - completed,
            workingSpaceBytes: trustedRelease.manifest.workingSpaceBytes,
            availableBytes: volumeCapacity.availableCapacity(forVolumeContaining: storageDirectoryURL)
        )
    }

    private func ensureSufficientSpace() throws {
        let estimate = installationSpaceEstimate()
        guard estimate.isInsufficient, let available = estimate.availableBytes else { return }
        let error = ModelManagementError.insufficientDiskSpace(
            requiredBytes: estimate.requiredBytes,
            availableBytes: available
        )
        state = .error(ModelFailure(
            code: KVoiceErrorCode.modelInsufficientDisk.rawValue,
            message: error.localizedDescription
        ))
        throw error
    }

    // MARK: - Installation

    public func installRecommendedModel() async throws {
        try ensureCanMutate()
        try ensurePinnedRelease()
        guard activeInstallation == nil else { throw ModelManagementError.busy }

        if let pendingInstallation {
            removeIfExists(pendingInstallation.stageURL)
            self.pendingInstallation = nil
        }
        // Nothing has started yet, so a refusal here leaves any resident
        // package untouched (spec C.3 step 3, FR-MODEL-006).
        try ensureSufficientSpace()

        let stageURL = try createStagingDirectory()
        let context = InstallationContext(
            id: UUID(),
            stageURL: stageURL,
            nextFileIndex: 0,
            completedBytes: 0,
            resumeData: nil
        )
        do {
            try prepareStagingDirectory(at: stageURL)
            try writeDownloadState(for: context)
        } catch {
            removeIfExists(stageURL)
            throw error
        }
        try await performInstallation(context)
    }

    public func resumeInstallation() async throws {
        try ensureCanMutate()
        guard activeInstallation == nil else { throw ModelManagementError.busy }
        guard let pendingInstallation else {
            throw ModelManagementError.noResumableInstallation
        }
        try ensureSufficientSpace()
        self.pendingInstallation = nil
        try await performInstallation(pendingInstallation)
    }

    /// Retry is useful to UI callers that do not need to distinguish a fresh
    /// retry from a resumable cancellation.
    public func retryInstallation() async throws {
        if pendingInstallation != nil {
            try await resumeInstallation()
        } else {
            try await installRecommendedModel()
        }
    }

    public func cancelInstallation() async {
        guard activeInstallation != nil else { return }
        cancellationRequested = true
        await downloader.cancel()
    }

    // MARK: - External packages

    public func selectExternalPackage(at url: URL) async throws {
        try ensureCanMutate()
        try ensurePinnedRelease()
        let url = url.standardizedFileURL
        state = .validatingExternal
        do {
            let package = try verifier.makePackage(at: url, ownership: .externalReadOnly)
            try verifier.verify(package)
            try await loadVerifiedPackage(package)
            externalSelection = ExternalSelection(url: url, status: .loaded)
        } catch {
            currentPackage = nil
            externalSelection = nil
            state = isVerificationError(error)
                ? .corrupt(failure(for: error))
                : .error(failure(for: error))
            throw mapError(error)
        }
    }

    /// Re-establishes the model selection persisted in settings at launch.
    ///
    /// An external reference is re-validated from its stored path. A missing
    /// or unmounted path fails closed with `MODEL-PATH-UNREADABLE`; a changed
    /// package fails closed with the verification failure. External files are
    /// never modified or deleted on this path. A managed or empty reference is
    /// equivalent to `refresh()`.
    public func restoreSelectedModel(_ reference: ModelReference?) async {
        guard activeJobID == nil, activeInstallation == nil else { return }
        switch reference {
        case nil, .managed:
            await refresh()
        case let .external(path, expectedModelID, expectedRevision):
            do {
                try ensurePinnedRelease()
            } catch {
                state = .error(failure(for: error))
                return
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard expectedModelID == trustedRelease.manifest.modelID,
                  expectedRevision == trustedRelease.manifest.source.revision else {
                await unloadExternalIfResident()
                externalSelection = ExternalSelection(url: url, status: .invalid)
                state = .incompatible(ModelFailure(
                    code: KVoiceErrorCode.modelIncompatible.rawValue,
                    message: "The remembered external model (" + expectedModelID + " @ "
                        + String(expectedRevision.prefix(12))
                        + ") is not the model this version of KVoice supports. "
                        + "Choose a supported package or forget the reference."
                ))
                return
            }
            if let loaded = currentPackage,
               loaded.ownership == .externalReadOnly,
               loaded.packageURL.standardizedFileURL == url,
               isReadyOrInInference {
                externalSelection = ExternalSelection(url: url, status: .loaded)
                return
            }
            externalSelection = ExternalSelection(url: url, status: .missing)
            await refreshExternalSelection()
        }
    }

    public func forgetExternalPackage() async {
        guard activeJobID == nil, activeInstallation == nil else { return }
        guard externalSelection != nil || currentPackage?.ownership == .externalReadOnly else { return }
        await unloadExternalIfResident()
        externalSelection = nil
        state = .absent
        // Forget only clears the reference (FR-MODEL-012). A managed package
        // that was installed earlier becomes the selection again.
        await refresh()
    }

    /// The reference the app shell should persist for the current selection,
    /// or `nil` when nothing is selected.
    public func currentModelReference() -> ModelReference? {
        if let externalSelection {
            return .external(
                path: externalSelection.url.path,
                expectedModelID: trustedRelease.manifest.modelID,
                expectedRevision: trustedRelease.manifest.source.revision
            )
        }
        if let currentPackage, currentPackage.ownership == .managedByKvoice {
            return .managed(
                modelID: currentPackage.manifest.modelID,
                revision: currentPackage.manifest.source.revision
            )
        }
        return nil
    }

    private func refreshExternalSelection() async {
        guard var selection = externalSelection else { return }
        let exists = isDirectory(selection.url)

        switch selection.status {
        case .loaded:
            if exists { return }
            await unloadExternalIfResident()
        case .invalid:
            if exists { return }
        case .missing:
            break
        }

        guard exists else {
            // The selection is external; a managed package that happens to
            // be resident must not stand in for it (spec G.9).
            if currentPackage != nil {
                await runtimeLoader.unload()
                currentPackage = nil
            }
            selection.status = .missing
            externalSelection = selection
            state = .error(ModelFailure(
                code: KVoiceErrorCode.modelPathUnreadable.rawValue,
                message: "The external model folder is missing or unreadable at "
                    + selection.url.path
                    + ". Reconnect the volume, choose the package again, or forget it."
            ))
            return
        }

        state = .validatingExternal
        do {
            let package = try verifier.makePackage(at: selection.url, ownership: .externalReadOnly)
            try verifier.verify(package)
            try await loadVerifiedPackage(package)
            selection.status = .loaded
            externalSelection = selection
        } catch {
            currentPackage = nil
            selection.status = .invalid
            externalSelection = selection
            let base = failure(for: error)
            let guidance = ModelFailure(
                code: base.code,
                message: base.message
                    + " The external package at " + selection.url.path
                    + " changed since it was selected. Restore it, choose it again, or forget it."
            )
            state = isVerificationError(error) ? .corrupt(guidance) : .error(guidance)
        }
    }

    private func unloadExternalIfResident() async {
        guard currentPackage?.ownership == .externalReadOnly else { return }
        await runtimeLoader.unload()
        currentPackage = nil
    }

    // MARK: - Deletion

    /// Deletes the managed package in two steps (spec C.10): an atomic rename
    /// to a `.deleting-<uuid>` sibling makes the package disappear from the
    /// active location immediately, then the renamed tree is removed off the
    /// actor. A removal that fails leaves the renamed tree as the "Delete
    /// Pending" marker; `refresh()` retries it on the next launch.
    public func deleteManagedPackage() async throws {
        try ensureCanMutate()
        guard currentPackage?.ownership != .externalReadOnly else {
            throw ModelManagementError.externalPackageCannotBeDeleted
        }

        let packageURL = managedPackageURL
        guard fileManager.fileExists(atPath: packageURL.path) else {
            currentPackage = nil
            state = .absent
            throw ModelManagementError.noManagedPackage
        }
        let summary = currentPackage.map(Self.summary(for:)) ?? InstalledModelSummary(
            modelID: trustedRelease.manifest.modelID,
            revision: trustedRelease.manifest.source.revision,
            ownership: .managedByKvoice
        )
        state = .deleting(summary)
        await runtimeLoader.unload()
        currentPackage = nil

        let stagedURL = packageURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                packageURL.lastPathComponent + Self.deletionMarkerInfix + UUID().uuidString,
                isDirectory: true
            )
        do {
            try fileManager.moveItem(at: packageURL, to: stagedURL)
        } catch {
            // The package is intact; the next refresh re-verifies and reloads it.
            state = .error(ModelFailure(code: "model.delete.failed", message: error.localizedDescription))
            throw ModelManagementError.deleteFailed(error.localizedDescription)
        }
        state = .absent

        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: stagedURL)
        }
    }

    /// Number of managed package trees renamed for deletion whose removal has
    /// not completed. Non-zero means a delete is pending retry.
    public func pendingDeletionCount() -> Int {
        pendingDeletionURLs().count
    }

    public func hasPendingDeletion() -> Bool {
        pendingDeletionCount() > 0
    }

    private func pendingDeletionURLs() -> [URL] {
        let parent = managedPackageURL.deletingLastPathComponent()
        let entries = (try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { $0.lastPathComponent.contains(Self.deletionMarkerInfix) }
    }

    private func retryPendingDeletions() {
        for url in pendingDeletionURLs() {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Inference reservation

    public func verifiedPackage() async throws -> InstalledModelPackage {
        guard let currentPackage, isReadyOrInInference else {
            throw ModelManagementError.noVerifiedPackage
        }
        return currentPackage
    }

    /// The coordinator calls this immediately before local inference. Keeping
    /// the marker in the manager makes deletion/replacement busy-gated even
    /// when runtime work is performed by a separate actor.
    public func beginInference(jobID: JobID) throws {
        try ensureCanMutate()
        guard let package = currentPackage, case .ready = state else {
            throw ModelManagementError.noVerifiedPackage
        }
        activeJobID = jobID
        state = .inference(Self.summary(for: package), jobID: jobID)
    }

    public func endInference(jobID: JobID) {
        guard activeJobID == jobID else { return }
        activeJobID = nil
        if let currentPackage {
            state = .ready(Self.summary(for: currentPackage))
        } else {
            state = .absent
        }
    }

    public func installedPackageSummary() -> InstalledModelSummary? {
        currentPackage.map(Self.summary(for:))
    }

    // MARK: - Residency (ADR-017)

    /// The catalog ID this manager owns.
    public nonisolated var modelID: ModelID {
        trustedRelease.manifest.modelID
    }

    public nonisolated var manifest: ModelManifest {
        trustedRelease.manifest
    }

    /// Re-runs the runtime load for the verified package that is already
    /// selected. The library calls this when this model becomes the default
    /// after being installed while another model was resident, because
    /// `refresh()` deliberately skips a package that is already verified.
    /// A no-op unless a verified package is selected and idle.
    public func loadResidentRuntime() async {
        guard activeJobID == nil, activeInstallation == nil,
              let package = currentPackage, isReadyOrInInference else { return }
        try? await loadVerifiedPackage(package)
    }

    /// Asks the runtime loader to release this model's runtime while keeping
    /// the package selected and verified. Used when another model becomes
    /// the default.
    public func releaseResidentRuntime() async {
        guard activeJobID == nil, activeInstallation == nil, currentPackage != nil else { return }
        await runtimeLoader.unload()
    }

    // MARK: - Download and install transaction

    private func performInstallation(_ initialContext: InstallationContext) async throws {
        activeInstallation = initialContext
        state = .downloading(
            completed: initialContext.completedBytes,
            total: try totalBytes()
        )

        do {
            let descriptors = trustedRelease.manifest.files
            var completedBytes = initialContext.completedBytes
            var resumeData = initialContext.resumeData
            var startIndex = initialContext.nextFileIndex

            while startIndex < descriptors.count {
                guard let activeInstallation,
                      activeInstallation.id == initialContext.id else {
                    throw ModelManagementError.cancelled
                }
                if cancellationRequested {
                    throw CancellationError()
                }
                let descriptor = descriptors[startIndex]
                let url = try urlProvider.url(for: descriptor, manifest: trustedRelease.manifest)
                let destination = try ModelRelativePath.url(for: descriptor.path, under: initialContext.stageURL)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if resumeData == nil {
                    removeIfExists(destination)
                }

                let operationID = initialContext.id
                let fileIndex = startIndex
                let progressBase = completedBytes
                let aggregateTotal = try totalBytes()
                let progress: @Sendable (Int64, Int64?) -> Void = { [self] bytes, expected in
                    Task {
                        await self.applyDownloadProgress(
                            operationID: operationID,
                            fileIndex: fileIndex,
                            bytes: bytes,
                            expected: expected,
                            completedBytes: progressBase,
                            totalBytes: aggregateTotal
                        )
                    }
                }
                try await downloader.download(
                    from: url,
                    to: destination,
                    resumeData: resumeData,
                    progress: progress
                )
                if cancellationRequested {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                completedBytes += descriptor.bytes
                startIndex += 1
                resumeData = nil
                let advanced = InstallationContext(
                    id: initialContext.id,
                    stageURL: initialContext.stageURL,
                    nextFileIndex: startIndex,
                    completedBytes: completedBytes,
                    resumeData: nil
                )
                self.activeInstallation = advanced
                try? writeDownloadState(for: advanced)
            }

            activeInstallation = nil
            // The bookkeeping file is not part of the package allowlist.
            removeIfExists(downloadStateURL(in: initialContext.stageURL))
            state = .verifying(completedFiles: 0, totalFiles: descriptors.count)
            let stagedPackage = try verifier.makePackage(
                at: initialContext.stageURL,
                ownership: .managedByKvoice
            )
            try verifier.verify(stagedPackage)

            state = .installing
            if currentPackage != nil {
                await runtimeLoader.unload()
                currentPackage = nil
            }
            try atomicallyInstall(
                stagingURL: initialContext.stageURL,
                managedURL: managedPackageURL
            )
            let installedPackage = try verifier.makePackage(
                at: managedPackageURL,
                ownership: .managedByKvoice
            )
            try verifier.verify(installedPackage)
            try await loadVerifiedPackage(installedPackage)
            pendingInstallation = nil
            externalSelection = nil
        } catch {
            let wasCancelled = cancellationRequested || error is CancellationError || Task.isCancelled
            // Non-nil only while still downloading: a later failure (verify,
            // install, load) has already cleared it.
            let downloadContext = activeInstallation
            activeInstallation = nil
            cancellationRequested = false

            if wasCancelled {
                let context = downloadContext ?? initialContext
                let resumeData = await downloader.latestResumeData()
                let paused = InstallationContext(
                    id: context.id,
                    stageURL: context.stageURL,
                    nextFileIndex: context.nextFileIndex,
                    completedBytes: context.completedBytes,
                    resumeData: resumeData
                )
                pendingInstallation = paused
                try? writeDownloadState(for: paused)
                state = .downloadPaused(resumableBytes: resumeData.map { Int64($0.count) })
                throw ModelManagementError.cancelled
            }

            if let downloadContext, !isVerificationError(error) {
                // A network or HTTP failure keeps the completed files so Retry
                // restarts only the incomplete one (spec C.3 step 8).
                let resumeData = await downloader.latestResumeData()
                let paused = InstallationContext(
                    id: downloadContext.id,
                    stageURL: downloadContext.stageURL,
                    nextFileIndex: downloadContext.nextFileIndex,
                    completedBytes: downloadContext.completedBytes,
                    resumeData: resumeData
                )
                pendingInstallation = paused
                try? writeDownloadState(for: paused)
                state = .error(failure(for: error))
                throw mapError(error)
            }

            pendingInstallation = nil
            removeIfExists(initialContext.stageURL)
            state = isVerificationError(error)
                ? .corrupt(failure(for: error))
                : .error(failure(for: error))
            throw mapError(error)
        }
    }

    private func applyDownloadProgress(
        operationID: UUID,
        fileIndex: Int,
        bytes: Int64,
        expected: Int64?,
        completedBytes: Int64,
        totalBytes: Int64
    ) {
        guard let activeInstallation,
              activeInstallation.id == operationID,
              case .downloading = state else { return }
        let descriptorBytes = trustedRelease.manifest.files[fileIndex].bytes
        let currentBytes = min(max(bytes, 0), expected ?? descriptorBytes)
        let completed = min(totalBytes, completedBytes + currentBytes)
        state = .downloading(completed: completed, total: totalBytes)
    }

    private func prepareStagingDirectory(at stageURL: URL) throws {
        let manifestURL = stageURL.appendingPathComponent("ModelManifest.json", isDirectory: false)
        try canonicalManifestData().write(to: manifestURL, options: .atomic)
        let manifest = trustedRelease.manifest
        let sentinel = InstalledModelSentinel(
            modelID: manifest.modelID,
            repository: manifest.source.repository,
            revision: manifest.source.revision,
            manifestVersion: manifest.schemaVersion,
            manifestSHA256: trustedRelease.manifestSHA256,
            installedBytes: try totalBytes(),
            installedAt: clock(),
            appVersion: appVersion,
            ownership: .managedByKvoice
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(sentinel).write(
            to: stageURL.appendingPathComponent(".installed.json", isDirectory: false),
            options: .atomic
        )
    }

    /// ADR-017: one staging root per model, so this manager's housekeeping
    /// (which removes any stage it cannot resume) never touches another
    /// model's paused download.
    private var stagingRootURL: URL {
        Self.stagingRootURL(storageDirectoryURL: storageDirectoryURL, modelID: trustedRelease.manifest.modelID)
    }

    public static func stagingRootURL(storageDirectoryURL: URL, modelID: ModelID) -> URL {
        storageDirectoryURL
            .appendingPathComponent(stagingDirectoryName, isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
    }

    private func createStagingDirectory() throws -> URL {
        try fileManager.createDirectory(at: stagingRootURL, withIntermediateDirectories: true)
        let stageURL = stagingRootURL.appendingPathComponent("model-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stageURL, withIntermediateDirectories: true)
        return stageURL
    }

    private func atomicallyInstall(stagingURL: URL, managedURL: URL) throws {
        let parent = managedURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: managedURL.path) {
            _ = try fileManager.replaceItemAt(managedURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: managedURL)
        }
    }

    private func loadVerifiedPackage(_ package: InstalledModelPackage) async throws {
        state = .loading
        do {
            try await runtimeLoader.load(package)
            currentPackage = package
            state = .ready(Self.summary(for: package))
        } catch {
            currentPackage = nil
            state = .error(failure(for: error))
            throw ModelManagementError.runtimeLoadFailed(error.localizedDescription)
        }
    }

    // MARK: - Staging bookkeeping (FR-MODEL-016)

    private func downloadStateURL(in stageURL: URL) -> URL {
        stageURL.appendingPathComponent(ModelDownloadStateRecord.fileName, isDirectory: false)
    }

    private func writeDownloadState(for context: InstallationContext) throws {
        let record = ModelDownloadStateRecord(
            installationID: context.id,
            manifestSHA256: trustedRelease.manifestSHA256,
            nextFileIndex: context.nextFileIndex,
            completedBytes: context.completedBytes,
            resumeData: context.resumeData,
            updatedAt: clock()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: downloadStateURL(in: context.stageURL), options: .atomic)
    }

    /// Reads a stage's bookkeeping and checks it structurally against the
    /// trusted manifest. `nil` means the stage is corrupt or unusable.
    private func resumableContext(in stageURL: URL) -> (InstallationContext, Date)? {
        guard let data = try? Data(contentsOf: downloadStateURL(in: stageURL)),
              let record = try? JSONDecoder().decode(ModelDownloadStateRecord.self, from: data),
              record.schemaVersion == ModelDownloadStateRecord.currentSchemaVersion,
              record.manifestSHA256 == trustedRelease.manifestSHA256 else {
            return nil
        }
        let descriptors = trustedRelease.manifest.files
        guard record.nextFileIndex >= 0, record.nextFileIndex <= descriptors.count else { return nil }
        guard fileType(at: stageURL.appendingPathComponent("ModelManifest.json")) == .typeRegular,
              fileType(at: stageURL.appendingPathComponent(".installed.json")) == .typeRegular else {
            return nil
        }

        var expectedCompleted: Int64 = 0
        for descriptor in descriptors[..<record.nextFileIndex] {
            guard let url = try? ModelRelativePath.url(for: descriptor.path, under: stageURL),
                  fileType(at: url) == .typeRegular,
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  (attributes[.size] as? NSNumber)?.int64Value == descriptor.bytes else {
                return nil
            }
            expectedCompleted += descriptor.bytes
        }
        guard record.completedBytes == expectedCompleted else { return nil }

        let context = InstallationContext(
            id: record.installationID,
            stageURL: stageURL,
            nextFileIndex: record.nextFileIndex,
            completedBytes: record.completedBytes,
            resumeData: record.resumeData
        )
        return (context, record.updatedAt)
    }

    /// Removes corrupt or stale stages and adopts the newest valid one as the
    /// paused download when nothing else is selected.
    private func cleanUpStaging() {
        let entries = (try? fileManager.contentsOfDirectory(
            at: stagingRootURL,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        let held = Set([activeInstallation?.stageURL, pendingInstallation?.stageURL]
            .compactMap { $0?.standardizedFileURL.path })
        let now = clock()
        var newest: (InstallationContext, Date)?

        for entry in entries {
            let stageURL = entry.standardizedFileURL
            if held.contains(stageURL.path) { continue }
            guard let candidate = resumableContext(in: stageURL) else {
                removeIfExists(stageURL)
                continue
            }
            if now.timeIntervalSince(candidate.1) > Self.staleStagingAge {
                removeIfExists(stageURL)
                continue
            }
            if let current = newest {
                // Only one download can ever be resumed; drop the older one.
                if candidate.1 > current.1 {
                    removeIfExists(current.0.stageURL)
                    newest = candidate
                } else {
                    removeIfExists(stageURL)
                }
            } else {
                newest = candidate
            }
        }

        guard let adopted = newest else { return }
        let canAdopt = pendingInstallation == nil
            && externalSelection == nil
            && !fileManager.fileExists(atPath: managedPackageURL.path)
        if canAdopt {
            pendingInstallation = adopted.0
        } else {
            removeIfExists(adopted.0.stageURL)
        }
    }

    // MARK: - Helpers

    private func ensureCanMutate() throws {
        guard activeJobID == nil else { throw ModelManagementError.busy }
        guard activeInstallation == nil else { throw ModelManagementError.busy }
    }

    /// ADR-017 / ADR-019: the release must be one of `PinnedModelReleases` —
    /// exact model ID, repository, revision, subdirectory, family, format,
    /// runtime package and version, tokenizer root. Anything else is refused
    /// before a byte is downloaded.
    private func ensurePinnedRelease() throws {
        let manifest = trustedRelease.manifest
        guard PinnedModelReleases.release(matching: manifest) != nil else {
            throw ModelManagementError.unsupportedModel(manifest.modelID)
        }
    }

    private func totalBytes() throws -> Int64 {
        let (total, overflow) = trustedRelease.manifest.files.reduce(into: (Int64(0), false)) { partial, descriptor in
            let result = partial.0.addingReportingOverflow(descriptor.bytes)
            partial.0 = result.partialValue
            partial.1 = partial.1 || result.overflow
        }
        guard !overflow, total > 0 else {
            throw ModelManagementError.invalidManifest("manifest file sizes must have a positive non-overflowing total")
        }
        return total
    }

    private var managedPackageURL: URL {
        storageDirectoryURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(trustedRelease.manifest.modelID, isDirectory: true)
            .appendingPathComponent(trustedRelease.manifest.source.revision, isDirectory: true)
    }

    private var isReadyOrInInference: Bool {
        switch state {
        case .ready, .inference:
            return true
        default:
            return false
        }
    }

    private var isFailureState: Bool {
        switch state {
        case .corrupt, .incompatible, .error:
            return true
        default:
            return false
        }
    }

    private func canonicalManifestData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(trustedRelease.manifest)
    }

    private func mapError(_ error: Error) -> ModelManagementError {
        if let error = error as? ModelManagementError { return error }
        if let error = error as? ModelPackageVerificationError {
            return .packageCorrupt(error.localizedDescription)
        }
        return .installFailed(error.localizedDescription)
    }

    private func isVerificationError(_ error: Error) -> Bool {
        error is ModelPackageVerificationError || error is WhisperPackageValidationError
    }

    private func failure(for error: Error) -> ModelFailure {
        let code: String
        if let error = error as? ModelPackageVerificationError {
            let name = String(describing: error).split(separator: "(").first ?? "verification"
            code = "model.package.\(name)"
        } else if error is WhisperPackageValidationError {
            code = "model.runtime.validation"
        } else if case .insufficientDiskSpace? = error as? ModelManagementError {
            code = KVoiceErrorCode.modelInsufficientDisk.rawValue
        } else if error is ModelManagementError {
            code = "model.management"
        } else {
            code = "model.error"
        }
        return ModelFailure(code: code, message: error.localizedDescription)
    }

    private func removeIfExists(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func isDirectory(_ url: URL) -> Bool {
        fileType(at: url) == .typeDirectory
    }

    private func fileType(at url: URL) -> FileAttributeType? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    private static func summary(for package: InstalledModelPackage) -> InstalledModelSummary {
        InstalledModelSummary(
            modelID: package.manifest.modelID,
            revision: package.manifest.source.revision,
            ownership: package.ownership
        )
    }
}
