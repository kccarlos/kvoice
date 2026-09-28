import XCTest
import KvoiceAppCore
@testable import KvoiceDomain
@testable import KvoiceUI

/// Launch at Login (FR-APP-005) and the typed-insertion tier flow through the
/// General view model as intents (ADR-022 slice 7); the launchd call is the
/// view model's, the stored flag follows what launchd reports.
@MainActor
final class GeneralSettingsLaunchAtLoginTests: XCTestCase {
    func testLaunchAtLoginAndTypedInsertionAreSentAsIntents() {
        let service = FakeLaunchAtLoginService()
        let harness = SettingsProjectionTestHarness()
        let model = GeneralSettingsViewModel(host: harness.host, launchAtLoginService: service)

        XCTAssertFalse(model.launchAtLogin)
        XCTAssertTrue(model.typedInsertionEnabled, "typed insertion defaults on, matching AppSettings")

        model.launchAtLogin = true
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(service.unregisterCount, 0)
        XCTAssertEqual(harness.sent.last, .setLaunchAtLogin(true, origin: .page(.general)))
        XCTAssertTrue(harness.settings.launchAtLogin)
        XCTAssertEqual(model.launchAtLoginStatus, .enabled)

        model.typedInsertionEnabled = false
        XCTAssertEqual(harness.sent.last, .setTypedInsertionEnabled(false, origin: .page(.recording)))
        XCTAssertFalse(harness.settings.typedInsertionEnabled)
        XCTAssertTrue(harness.settings.launchAtLogin)

        model.launchAtLogin = false
        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertEqual(harness.sent.last, .setLaunchAtLogin(false, origin: .page(.general)))
        XCTAssertFalse(harness.settings.launchAtLogin)
        XCTAssertEqual(model.launchAtLoginStatus, .notRegistered)
    }

    func testARefusedLaunchAtLoginEditKeepsTheStoredFlagAndTheNextRefreshRetries() {
        let service = FakeLaunchAtLoginService()
        let harness = SettingsProjectionTestHarness()
        let model = GeneralSettingsViewModel(host: harness.host, launchAtLoginService: service)
        harness.startJob()

        model.launchAtLogin = true
        XCTAssertEqual(service.registerCount, 1, "launchd was asked; the flag write is what the gate refused")
        XCTAssertFalse(model.launchAtLogin)
        XCTAssertEqual(model.refusalNote, "Finish the current dictation first.")

        harness.endJob()
        model.refreshLaunchAtLoginStatus()
        XCTAssertTrue(model.launchAtLogin, "the refresh brings the flag in line with launchd once idle")
        XCTAssertNil(model.refusalNote)
    }

    func testApprovalRequiredIsShownTruthfullyAndNeverRePrompted() {
        let service = FakeLaunchAtLoginService(statusAfterRegister: .requiresApproval)
        let model = GeneralSettingsViewModel(launchAtLoginService: service)

        model.launchAtLogin = true
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(model.launchAtLoginStatus, .requiresApproval)
        XCTAssertTrue(model.launchAtLoginNeedsApproval)
        XCTAssertTrue(model.launchAtLogin, "awaiting approval still reads as requested")

        // Repeated refreshes read status only; they must not register again.
        model.refreshLaunchAtLoginStatus()
        model.refreshLaunchAtLoginStatus()
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(service.statusReads, 3)

        XCTAssertTrue(model.openLoginItemsSettings())
        XCTAssertEqual(service.openCount, 1)
    }

    func testRefreshAlignsToggleWithSystemStateWithoutRegistering() {
        let service = FakeLaunchAtLoginService()
        let harness = SettingsProjectionTestHarness(settings: AppSettings(launchAtLogin: true))
        let model = GeneralSettingsViewModel(host: harness.host, launchAtLoginService: service)
        XCTAssertTrue(model.launchAtLogin)

        // The user removed the login item in System Settings.
        service.currentStatus = .notRegistered
        model.refreshLaunchAtLoginStatus()

        XCTAssertFalse(model.launchAtLogin)
        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(service.unregisterCount, 0)
        XCTAssertEqual(harness.sent, [.setLaunchAtLogin(false, origin: .page(.general))], "the persisted value follows the truth")

        model.refreshLaunchAtLoginStatus()
        XCTAssertEqual(harness.sent.count, 1, "a refresh that agrees sends nothing")
    }

    func testRegistrationFailureIsSurfacedAndToggleReverts() {
        let service = FakeLaunchAtLoginService(registerError: FakeLaunchAtLoginService.Failure())
        let harness = SettingsProjectionTestHarness()
        let model = GeneralSettingsViewModel(host: harness.host, launchAtLoginService: service)

        model.launchAtLogin = true

        XCTAssertEqual(model.launchAtLoginError, "launchd said no")
        XCTAssertFalse(model.launchAtLogin, "an unregistered service must not read as on")
        XCTAssertEqual(model.launchAtLoginStatus, .notRegistered)
        XCTAssertTrue(harness.sent.isEmpty, "a flag launchd refused is never persisted")
    }

    func testUnavailableServiceLeavesStatusUnknownAndTogglePersists() {
        let harness = SettingsProjectionTestHarness()
        let model = GeneralSettingsViewModel(host: harness.host)

        model.launchAtLogin = true

        XCTAssertEqual(model.launchAtLoginStatus, .unknown)
        XCTAssertNotNil(model.launchAtLoginError)
        XCTAssertEqual(harness.sent.last, .setLaunchAtLogin(true, origin: .page(.general)))
        XCTAssertTrue(model.launchAtLogin)
    }

    func testAChangeFromAnotherDoorRendersWithoutHydration() {
        let harness = SettingsProjectionTestHarness()
        let model = GeneralSettingsViewModel(host: harness.host)

        harness.commitFromElsewhere(.replaceAll(AppSettings(
            showDockIcon: true,
            launchAtLogin: true,
            recordingInteraction: .toggle,
            shortcut: ShortcutDefinition(key: "d", modifiers: ["command"]),
            typedInsertionEnabled: false
        ), origin: .import))

        XCTAssertTrue(harness.sent.isEmpty)
        XCTAssertTrue(model.showDockIcon)
        XCTAssertTrue(model.launchAtLogin)
        XCTAssertEqual(model.recordingInteraction, .toggle)
        XCTAssertEqual(model.confirmedShortcut?.key, "d")
        XCTAssertFalse(model.typedInsertionEnabled)
    }

    func testResetOnboardingCallsTheShellHook() {
        var resets = 0
        let model = GeneralSettingsViewModel(onResetOnboarding: { resets += 1 })
        model.resetOnboarding()
        XCTAssertEqual(resets, 1)
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginService {
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "launchd said no" }
    }

    var currentStatus: LaunchAtLoginStatus = .notRegistered
    private let statusAfterRegister: LaunchAtLoginStatus
    private let registerError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var statusReads = 0
    private(set) var openCount = 0

    init(
        statusAfterRegister: LaunchAtLoginStatus = .enabled,
        registerError: Error? = nil
    ) {
        self.statusAfterRegister = statusAfterRegister
        self.registerError = registerError
    }

    func status() -> LaunchAtLoginStatus {
        statusReads += 1
        return currentStatus
    }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        currentStatus = statusAfterRegister
    }

    func unregister() throws {
        unregisterCount += 1
        currentStatus = .notRegistered
    }

    func openLoginItemsSettings() -> Bool {
        openCount += 1
        return true
    }
}
