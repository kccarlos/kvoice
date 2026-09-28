import XCTest
import KvoiceAppCore
@testable import KvoiceDomain
@testable import KvoiceUI

@MainActor
final class MemoryPressureViewModelTests: XCTestCase {
    /// Yields (never sleeps) until the view model's detached `Task` has
    /// finished, mirroring `RuntimeCardViewModelTests.settle(while:)`.
    private func settle(while condition: @MainActor () -> Bool) async {
        for _ in 0..<5_000 where condition() { await Task.yield() }
    }

    // MARK: Banner state per level

    func testBannerShowsAtWarningAndCriticalOnlyAndOnlyCriticalOffersUnload() {
        let model = MemoryPressureViewModel()
        XCTAssertFalse(model.showsBanner)
        XCTAssertFalse(model.isCritical)

        model.apply(level: .warning)
        XCTAssertTrue(model.showsBanner)
        XCTAssertFalse(model.isCritical)

        model.apply(level: .critical)
        XCTAssertTrue(model.showsBanner)
        XCTAssertTrue(model.isCritical)

        model.apply(level: .normal)
        XCTAssertFalse(model.showsBanner)
    }

    // MARK: Diagnostics: exactly once per distinct change

    func testDiagnosticFiresOnceForARealChangeAndNeverForARepeat() {
        var seen: [MemoryPressureLevel] = []
        let model = MemoryPressureViewModel(onLevelChange: { seen.append($0) })

        model.apply(level: .warning)
        model.apply(level: .warning) // no-op: not a change
        model.apply(level: .critical)
        model.apply(level: .critical) // no-op
        model.apply(level: .normal)

        XCTAssertEqual(seen, [.warning, .critical, .normal])
    }

    func testApplyingTheStartingLevelDoesNotFireADiagnostic() {
        var callCount = 0
        let model = MemoryPressureViewModel(level: .warning, onLevelChange: { _ in callCount += 1 })

        model.apply(level: .warning)

        XCTAssertEqual(callCount, 0)
    }

    // MARK: Unload gating on idle

    func testUnloadIsDisabledWhileBusyAndEnabledWhileIdle() {
        var idle = false
        let model = MemoryPressureViewModel(level: .critical, isIdle: { idle })

        XCTAssertFalse(model.canUnloadNow)
        XCTAssertNotNil(model.unloadDisabledReason)

        idle = true
        XCTAssertTrue(model.canUnloadNow)
        XCTAssertNil(model.unloadDisabledReason)
    }

    func testUnloadNowCallsTheActionOnlyWhenIdleAndTracksInFlightState() async {
        var unloadCallCount = 0
        let model = MemoryPressureViewModel(level: .critical, isIdle: { true }, unload: {
            unloadCallCount += 1
        })

        model.unloadNow()
        XCTAssertTrue(model.isUnloading)
        await settle { model.isUnloading }

        XCTAssertEqual(unloadCallCount, 1)
        XCTAssertFalse(model.isUnloading)
        XCTAssertNil(model.unloadError)
    }

    func testUnloadNowIsRefusedWhileBusyAndNeverCallsTheAction() {
        var unloadCallCount = 0
        let model = MemoryPressureViewModel(level: .critical, isIdle: { false }, unload: {
            unloadCallCount += 1
        })

        model.unloadNow()

        XCTAssertEqual(unloadCallCount, 0)
        XCTAssertFalse(model.isUnloading)
    }

    func testUnloadFailureSurfacesTheBusyMessageForAppBusyAndAGenericMessageOtherwise() async {
        let busyModel = MemoryPressureViewModel(level: .critical, isIdle: { true }, unload: {
            throw KVoiceError(code: .appBusy)
        })
        busyModel.unloadNow()
        await settle { busyModel.isUnloading }
        XCTAssertEqual(busyModel.unloadError, "Finish the current dictation first.")

        struct OtherError: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let otherModel = MemoryPressureViewModel(level: .critical, isIdle: { true }, unload: {
            throw OtherError()
        })
        otherModel.unloadNow()
        await settle { otherModel.isUnloading }
        XCTAssertEqual(otherModel.unloadError, "Could not unload the model: boom")
    }

    // MARK: Auto-unload only when opted in

    func testCriticalNeverAutoUnloadsWhenTheOptInIsOff() async {
        var unloadCallCount = 0
        let model = MemoryPressureViewModel(host: .detached(settings: AppSettings(freeModelMemoryUnderCriticalPressure: false)), isIdle: { true }, unload: {
            unloadCallCount += 1
        })

        model.apply(level: .critical)

        // The guard that gates auto-unload runs synchronously inside
        // `apply`; the opt-in being off means no `Task` is ever spawned.
        XCTAssertEqual(unloadCallCount, 0, "unload must never happen without the opt-in")
    }

    func testCriticalAutoUnloadsWhenOptedInAndIdle() async {
        var unloadCallCount = 0
        let model = MemoryPressureViewModel(host: .detached(settings: AppSettings(freeModelMemoryUnderCriticalPressure: true)), isIdle: { true }, unload: {
            unloadCallCount += 1
        })

        model.apply(level: .critical)
        XCTAssertTrue(model.isUnloading, "the opt-in and idle system must start the unload synchronously")
        await settle { model.isUnloading }

        XCTAssertEqual(unloadCallCount, 1)
    }

    func testCriticalDoesNotAutoUnloadWhenOptedInButBusy() async {
        var unloadCallCount = 0
        let model = MemoryPressureViewModel(host: .detached(settings: AppSettings(freeModelMemoryUnderCriticalPressure: true)), isIdle: { false }, unload: {
            unloadCallCount += 1
        })

        model.apply(level: .critical)

        XCTAssertFalse(model.isUnloading)
        XCTAssertEqual(unloadCallCount, 0, "never unloads out from under an active job")
    }

    func testWarningNeverAutoUnloadsEvenWhenOptedIn() async {
        var unloadCallCount = 0
        let model = MemoryPressureViewModel(host: .detached(settings: AppSettings(freeModelMemoryUnderCriticalPressure: true)), isIdle: { true }, unload: {
            unloadCallCount += 1
        })

        model.apply(level: .warning)

        XCTAssertFalse(model.isUnloading)
        XCTAssertEqual(unloadCallCount, 0, "only critical pressure ever triggers an automatic unload")
    }

    /// ADR-022 slice 7: the opt-in is read from the coordinator, so the
    /// General page's edit reaches the automatic unload with nothing
    /// re-applied.
    func testTheOptInIsAProjectionOfTheStoredSetting() async {
        let harness = SettingsProjectionTestHarness()
        var unloads = 0
        let model = MemoryPressureViewModel(host: harness.host, isIdle: { true }, unload: { unloads += 1 })
        XCTAssertFalse(model.autoUnloadEnabled)

        harness.commitFromElsewhere(.setFreeModelMemoryUnderCriticalPressure(true, origin: .page(.general)))
        XCTAssertTrue(model.autoUnloadEnabled)

        model.apply(level: .critical)
        XCTAssertTrue(model.isUnloading)
        await settle { model.isUnloading }
        XCTAssertEqual(unloads, 1)

        harness.commitFromElsewhere(.resetToDefault(.freeModelMemoryUnderCriticalPressure, origin: .page(.general)))
        XCTAssertFalse(model.autoUnloadEnabled)
    }
}
