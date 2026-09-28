import XCTest
import KvoiceAppCore
@testable import KvoiceDomain
@testable import KvoiceUI

/// The General view model as a projection (ADR-022 slice 7): it renders the
/// coordinator's values, every edit is one intent with the page's origin, a
/// refusal snaps the control back with a note, and a change from another
/// door shows without anything being re-applied.
@MainActor
final class GeneralSettingsViewTests: XCTestCase {
    func testGeneralModelUsesSafeDefaultsAndRequiresConfirmation() {
        let model = GeneralSettingsViewModel()

        XCTAssertEqual(model.recordingInteraction, .pushToTalk)
        XCTAssertNil(model.confirmedShortcut)
        XCTAssertFalse(model.showDockIcon)
        XCTAssertEqual(model.shortcutDescription, "No shortcut confirmed")
    }

    func testRecommendedShortcutIsOnlyAppliedAfterConfirmation() {
        let harness = SettingsProjectionTestHarness()
        let model = GeneralSettingsViewModel(host: harness.host)

        XCTAssertNil(model.confirmedShortcut)
        model.confirmRecommendedShortcut()

        XCTAssertEqual(
            model.confirmedShortcut,
            ShortcutDefinition(key: "space", modifiers: ["control", "shift"])
        )
        XCTAssertEqual(model.shortcutDescription, "Control-Shift-Space")
        XCTAssertEqual(harness.sent, [.setShortcut(GeneralSettingsViewModel.recommendedShortcut, origin: .page(.shortcuts))])
        XCTAssertEqual(harness.effects, [.registerShortcut, .persist, .rebuildMenu])

        model.confirmRecommendedShortcut()
        XCTAssertEqual(harness.sent.count, 1, "confirming the stored shortcut again sends nothing")

        model.clearShortcut()
        XCTAssertNil(model.confirmedShortcut)
        XCTAssertEqual(harness.sent.last, .setShortcut(nil, origin: .page(.shortcuts)))
        model.clearShortcut()
        XCTAssertEqual(harness.sent.count, 2, "clearing nothing sends nothing")
    }

    func testAnUnusableShortcutIsNeverSent() {
        let harness = SettingsProjectionTestHarness()
        let model = GeneralSettingsViewModel(host: harness.host)
        model.confirmShortcut(ShortcutDefinition(key: "a", modifiers: []))
        XCTAssertTrue(harness.sent.isEmpty)
        XCTAssertNil(model.confirmedShortcut)
    }

    func testTheModelRendersTheCoordinatorsValues() {
        let harness = SettingsProjectionTestHarness(settings: AppSettings(
            showDockIcon: true,
            recordingInteraction: .toggle,
            shortcut: ShortcutDefinition(key: "s", modifiers: ["command"]),
            historyEnabled: false,
            typedInsertionEnabled: false,
            freeModelMemoryUnderCriticalPressure: true,
            interfaceLanguage: .english
        ))
        let model = GeneralSettingsViewModel(host: harness.host)

        XCTAssertEqual(model.recordingInteraction, .toggle)
        XCTAssertEqual(model.confirmedShortcut?.key, "s")
        XCTAssertTrue(model.showDockIcon)
        XCTAssertFalse(model.typedInsertionEnabled)
        XCTAssertTrue(model.freeModelMemoryUnderCriticalPressure)
        XCTAssertEqual(model.interfaceLanguage, .english)
        XCTAssertTrue(harness.sent.isEmpty, "rendering sends nothing")
    }

    /// Every General control: one intent, the page it lives on as origin,
    /// and an equal assignment sends nothing.
    func testEveryEditIsOneIntentWithThePagesOrigin() {
        let harness = SettingsProjectionTestHarness()
        let model = GeneralSettingsViewModel(host: harness.host)

        model.recordingInteraction = .hybrid
        model.showDockIcon = true
        model.typedInsertionEnabled = false
        model.freeModelMemoryUnderCriticalPressure = true

        XCTAssertEqual(harness.sent, [
            .setRecordingInteraction(.hybrid, origin: .page(.shortcuts)),
            .setShowDockIcon(true, origin: .page(.general)),
            .setTypedInsertionEnabled(false, origin: .page(.recording)),
            .setFreeModelMemoryUnderCriticalPressure(true, origin: .page(.general))
        ])
        XCTAssertEqual(harness.settings.recordingInteraction, .hybrid)
        XCTAssertTrue(harness.settings.showDockIcon)
        XCTAssertFalse(harness.settings.typedInsertionEnabled)
        XCTAssertTrue(harness.settings.freeModelMemoryUnderCriticalPressure)

        model.showDockIcon = true
        model.recordingInteraction = .hybrid
        XCTAssertEqual(harness.sent.count, 4, "equal assignments send nothing")
    }

    func testARefusalSnapsTheControlBackAndShowsTheNote() {
        let harness = SettingsProjectionTestHarness()
        let model = GeneralSettingsViewModel(host: harness.host)
        harness.startJob()

        model.showDockIcon = true

        XCTAssertFalse(model.showDockIcon, "the projection reads the untouched stored value")
        XCTAssertEqual(model.refusalNote, "Finish the current dictation first.")
        XCTAssertTrue(harness.effects.isEmpty)

        harness.endJob()
        model.showDockIcon = true
        XCTAssertTrue(model.showDockIcon)
        XCTAssertNil(model.refusalNote)
    }

    func testAChangeFromAnotherDoorShowsWithoutHydration() {
        let harness = SettingsProjectionTestHarness()
        let model = GeneralSettingsViewModel(host: harness.host)

        harness.commitFromElsewhere(.setRecordingInteraction(.toggle, origin: .wizard))
        harness.commitFromElsewhere(.setShortcut(ShortcutDefinition(key: "d", modifiers: ["command"]), origin: .hotkeyRecorder))

        XCTAssertEqual(model.recordingInteraction, .toggle)
        XCTAssertEqual(model.confirmedShortcut?.key, "d")
        XCTAssertTrue(harness.sent.isEmpty)
    }

    /// Later waves: memory-pressure warnings. Defaults false, rendered from
    /// the coordinator, and a user edit sends the intent — the same contract
    /// every other General toggle has.
    func testFreeModelMemoryUnderCriticalPressureDefaultsOffAndSendsOnEdit() {
        let harness = SettingsProjectionTestHarness()
        let model = GeneralSettingsViewModel(host: harness.host)

        XCTAssertFalse(model.freeModelMemoryUnderCriticalPressure)

        harness.commitFromElsewhere(.setFreeModelMemoryUnderCriticalPressure(true, origin: .statusMenu))
        XCTAssertTrue(model.freeModelMemoryUnderCriticalPressure)
        XCTAssertTrue(harness.sent.isEmpty, "a change from elsewhere is not an edit")

        model.freeModelMemoryUnderCriticalPressure = false
        XCTAssertEqual(harness.sent, [.setFreeModelMemoryUnderCriticalPressure(false, origin: .page(.general))])
        XCTAssertFalse(harness.settings.freeModelMemoryUnderCriticalPressure)
    }

    func testViewCanBeConstructedForSettingsScene() {
        let model = GeneralSettingsViewModel()
        let view = GeneralSettingsView(viewModel: model)

        XCTAssertNotNil(view)
    }
}
