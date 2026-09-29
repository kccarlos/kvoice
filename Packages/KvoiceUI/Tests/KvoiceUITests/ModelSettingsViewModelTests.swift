import XCTest
@testable import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceUI

/// The Model tab offers only the actions that make sense for the lifecycle
/// state and locks mutation out while a job or operation is active
/// (FR-MODEL-017).
@MainActor
final class ModelSettingsViewModelTests: XCTestCase {
    private let managed = ModelDescriptor(
        modelID: "whisper-large-v3-turbo",
        revision: "abc",
        source: .managed(URL(fileURLWithPath: "/tmp/kvoice/model")),
        installedBytes: 1_600_000_000
    )
    private let external = ModelDescriptor(
        modelID: "whisper-large-v3-turbo",
        revision: "abc",
        source: .external(URL(fileURLWithPath: "/Volumes/Models/whisper"))
    )
    private var summary: InstalledModelSummary {
        InstalledModelSummary(modelID: "whisper-large-v3-turbo", revision: "abc", ownership: .managedByKvoice)
    }

    func testAbsentOffersDownloadAndChooseExisting() {
        let model = ModelSettingsViewModel(state: .absent)
        XCTAssertEqual(model.availableActions, [.download, .chooseExisting])
        XCTAssertNil(model.mutationDisabledReason)
        XCTAssertEqual(model.statusDescription, "Not installed")
        XCTAssertEqual(model.sizeDescription, "Unknown")
    }

    func testDownloadingOffersOnlyCancelAndExplainsTheLock() {
        let model = ModelSettingsViewModel(state: .downloading(completed: 500, total: 1_000))
        XCTAssertEqual(model.availableActions, [.cancel])
        XCTAssertTrue(model.isEnabled(.cancel), "cancel is not a mutation")
        XCTAssertNotNil(model.mutationDisabledReason)
        XCTAssertEqual(model.progress, 0.5)
    }

    /// 2026-09-29: the first Core ML build and a cached load read
    /// differently on the card, both indeterminate, both locked.
    func testTheFirstCompileSaysFirstTimeOnlyAndACachedLoadDoesNot() {
        let optimizing = ModelSettingsViewModel(state: .optimizing)
        XCTAssertEqual(optimizing.availableActions, [])
        XCTAssertTrue(optimizing.isBusy)
        XCTAssertNil(optimizing.progress, "no made-up percentage")
        XCTAssertEqual(optimizing.statusDescription, "Optimizing for your Mac — first time only, this can take a few minutes…")
        XCTAssertEqual(
            optimizing.mutationDisabledReason,
            "Optimizing the model for your Mac. This happens only the first time and can take a few minutes; model changes are available when it finishes."
        )

        let loading = ModelSettingsViewModel(state: .loading)
        XCTAssertTrue(loading.isBusy)
        XCTAssertEqual(loading.statusDescription, "Loading into the Neural Engine…")
        XCTAssertEqual(loading.mutationDisabledReason, "Loading the model. Wait for it to finish.")
        XCTAssertFalse(loading.statusDescription.contains("first time"))
    }

    func testPausedOffersResume() {
        let model = ModelSettingsViewModel(state: .downloadPaused(resumableBytes: 42))
        XCTAssertEqual(model.availableActions, [.resume, .chooseExisting])
        XCTAssertTrue(model.statusDescription.hasPrefix("Paused"))
    }

    func testReadyManagedOffersRevealAndDeleteNotForget() {
        let model = ModelSettingsViewModel(state: .ready(summary), descriptor: managed)
        XCTAssertEqual(model.availableActions, [.revealInFinder, .delete, .chooseExisting])
        XCTAssertFalse(model.availableActions.contains(.forget))
        XCTAssertEqual(model.sizeDescription, ModelSettingsViewModel.formatBytes(1_600_000_000))
    }

    func testReadyExternalOffersForgetAndDownloadNotDelete() {
        let model = ModelSettingsViewModel(state: .ready(summary), descriptor: external)
        XCTAssertEqual(model.availableActions, [.forget, .chooseExisting, .download])
        XCTAssertFalse(model.availableActions.contains(.delete))
        XCTAssertFalse(model.availableActions.contains(.revealInFinder))
    }

    /// ADR-025: a system-managed default (Apple Speech) has no folder to
    /// reveal or forget and no external folder to choose; Delete releases
    /// the platform reservation.
    func testReadySystemManagedOffersDeleteOnly() {
        let descriptor = ModelDescriptor(modelID: "apple-speech", revision: "system", source: .systemManaged)
        let systemSummary = InstalledModelSummary(modelID: "apple-speech", revision: "system", ownership: .systemManaged)
        let model = ModelSettingsViewModel(state: .ready(systemSummary), descriptor: descriptor)
        XCTAssertEqual(model.availableActions, [.delete])
        XCTAssertEqual(descriptor.source.displayName, "Managed by macOS")
        XCTAssertNil(descriptor.source.location)
        XCTAssertFalse(descriptor.source.isManaged)
        XCTAssertFalse(descriptor.source.isExternal)
        XCTAssertEqual(model.sizeDescription, "Unknown", "nothing on kvoice's disk")
        XCTAssertEqual(model.spaceEstimateKey, "ready:systemManaged")
    }

    func testInferenceAndActiveDictationLockMutation() {
        var performed: [ModelSettingsAction] = []
        let model = ModelSettingsViewModel(
            state: .inference(summary, jobID: JobID()),
            descriptor: managed,
            onAction: { performed.append($0) }
        )
        XCTAssertEqual(model.availableActions, [.revealInFinder])
        XCTAssertNotNil(model.mutationDisabledReason)

        model.setState(.ready(summary))
        XCTAssertNil(model.mutationDisabledReason)
        model.setDictationActive(true)
        XCTAssertEqual(model.mutationDisabledReason, "Model changes are unavailable while dictation is running.")
        XCTAssertFalse(model.isEnabled(.delete))
        XCTAssertTrue(model.isEnabled(.revealInFinder))

        model.perform(.delete)
        XCTAssertTrue(performed.isEmpty, "a locked action must not reach the shell")
        model.perform(.revealInFinder)
        XCTAssertEqual(performed, [.revealInFinder])
    }

    func testFailureOffersRetryAndOwnershipCleanup() {
        let failure = ModelFailure(code: "x", message: "bad hash")
        let model = ModelSettingsViewModel(state: .corrupt(failure), descriptor: managed)
        XCTAssertEqual(model.availableActions, [.retry, .chooseExisting, .revealInFinder, .delete])
        XCTAssertTrue(model.statusDescription.hasPrefix("Corrupt"))
    }

    // MARK: In-flight actions

    /// The shell reflects a click on its next sync tick. Until then the
    /// mutating buttons must be locked, or a double-click starts two
    /// downloads.
    func testAPerformedActionLocksMutationUntilTheStateMovesOn() {
        var performed: [ModelSettingsAction] = []
        let model = ModelSettingsViewModel(state: .absent, onAction: { performed.append($0) })

        model.perform(.download)
        XCTAssertEqual(model.pendingAction, .download)
        XCTAssertFalse(model.isEnabled(.download))
        XCTAssertFalse(model.isEnabled(.chooseExisting))
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.mutationDisabledReason, ModelSettingsAction.download.inProgressDescription)

        model.perform(.download)
        XCTAssertEqual(performed, [.download], "The second click is swallowed")

        model.setState(.downloading(completed: 0, total: 100))
        XCTAssertNil(model.pendingAction)
        XCTAssertEqual(model.availableActions, [.cancel])
    }

    func testAPendingActionExpiresWhenTheShellNeverReacts() async throws {
        let clock = ParkingClock()
        let model = ModelSettingsViewModel(
            state: .ready(summary),
            descriptor: external,
            pendingActionTimeout: .milliseconds(40),
            clock: clock
        )

        model.perform(.forget)
        XCTAssertEqual(model.pendingAction, .forget)

        await clock.waitForSleepers(1)
        XCTAssertEqual(clock.pendingDurations, [.milliseconds(40)])
        let expiry = try XCTUnwrap(model.pendingActionTask)
        clock.advance(by: .milliseconds(39))
        XCTAssertEqual(model.pendingAction, .forget, "the lock holds until the timeout has elapsed")
        clock.advance(by: .milliseconds(1))
        await awaitTask(expiry, "the pending-action timer never finished after its deadline")
        XCTAssertNil(model.pendingAction)
        XCTAssertTrue(model.isEnabled(.forget))
    }

    func testChooseExistingAndRevealDoNotLock() {
        let model = ModelSettingsViewModel(state: .ready(summary), descriptor: managed)
        model.perform(.chooseExisting)
        XCTAssertNil(model.pendingAction, "The open panel may be cancelled; nothing to wait for")
        model.perform(.revealInFinder)
        XCTAssertNil(model.pendingAction)
    }

    func testUnchangedShellPushesAreIgnored() {
        let model = ModelSettingsViewModel(state: .absent, descriptor: managed)
        model.perform(.download)
        // Same state pushed again (the shell's 250 ms tick) must not clear
        // the in-flight lock; only an actual change does.
        model.setState(.absent)
        XCTAssertEqual(model.pendingAction, .download)
        model.setDescriptor(managed)
        model.setDictationActive(false)
        XCTAssertEqual(model.pendingAction, .download)
    }

    func testSpaceEstimateKeyFollowsTheStateClass() {
        let model = ModelSettingsViewModel(state: .absent)
        let absent = model.spaceEstimateKey
        model.setState(.downloading(completed: 1, total: 2))
        let downloading = model.spaceEstimateKey
        model.setState(.downloading(completed: 2, total: 2))
        XCTAssertEqual(model.spaceEstimateKey, downloading, "Progress alone must not re-run the preflight")
        model.setState(.ready(summary))
        XCTAssertNotEqual(model.spaceEstimateKey, absent)
        XCTAssertNotEqual(model.spaceEstimateKey, downloading)
    }

    func testSpaceEstimateComesFromTheHook() async {
        let model = ModelSettingsViewModel(modelSpaceEstimate: {
            ModelSpaceEstimate(requiredBytes: 1_000, availableBytes: 10)
        })
        XCTAssertNil(model.spaceEstimateDescription)
        await model.refreshSpaceEstimate()
        XCTAssertEqual(model.spaceEstimate?.isSufficient, false)
        XCTAssertTrue(model.spaceEstimateDescription?.hasPrefix("about ") ?? false)
    }
}
