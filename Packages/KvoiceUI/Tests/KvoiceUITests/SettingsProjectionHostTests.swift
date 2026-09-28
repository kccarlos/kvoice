import XCTest
import KvoiceAppCore
import KvoiceDomain
@testable import KvoiceUI

/// ADR-022 slice 7: the base every settings projection is built on.
@MainActor
final class SettingsProjectionHostTests: XCTestCase {
    func testReadsAreThePassThroughsOfTheCoordinator() {
        let harness = SettingsProjectionTestHarness(
            settings: AppSettings(showDockIcon: true),
            localState: LocalState(tutorialSeen: true)
        )
        let host = harness.host
        XCTAssertTrue(host.settings.showDockIcon)
        XCTAssertTrue(host.localState.tutorialSeen)
        XCTAssertEqual(host.effective, harness.coordinator.effective)
        XCTAssertEqual(host.environment, harness.coordinator.environment)

        harness.commitFromElsewhere(.setShowDockIcon(false, origin: .statusMenu))
        XCTAssertFalse(host.settings.showDockIcon, "a projection reads the committed value with nothing re-applied")
    }

    func testAnAcceptedSendCommitsAndClearsTheNote() {
        let harness = SettingsProjectionTestHarness()
        XCTAssertNil(harness.host.send(.setShowDockIcon(true, origin: .page(.general))))
        XCTAssertTrue(harness.settings.showDockIcon)
        XCTAssertEqual(harness.sent, [.setShowDockIcon(true, origin: .page(.general))])
        XCTAssertEqual(harness.effects, [.applyActivationPolicy, .persist, .rebuildMenu])
        XCTAssertNil(harness.host.refusalNote)
    }

    func testARefusedSendLeavesTheStateAndRecordsTheNote() {
        let harness = SettingsProjectionTestHarness()
        harness.startJob()
        let refusal = harness.host.send(.setShowDockIcon(true, origin: .page(.general)))
        XCTAssertEqual(refusal?.reason, .dictationInProgress)
        XCTAssertFalse(harness.settings.showDockIcon)
        XCTAssertTrue(harness.effects.isEmpty)
        XCTAssertEqual(harness.host.refusalNote, "Finish the current dictation first.")

        harness.endJob()
        XCTAssertNil(harness.host.send(.setShowDockIcon(true, origin: .page(.general))))
        XCTAssertNil(harness.host.refusalNote, "the next accepted send clears the note")
    }

    func testTheTypedNotePicksTheSpecificSentence() {
        let harness = SettingsProjectionTestHarness()
        harness.startJob()
        harness.host.send(.setDictionary(DictionarySettings(terms: ["kvoice"]), origin: .page(.dictionary)))
        XCTAssertEqual(
            harness.host.refusalNote,
            "Finish the current dictation first — a running dictation keeps the list it started with."
        )
        XCTAssertEqual(
            SettingsProjectionHost.note(for: SettingsRefusal(intent: "x", reason: .notLoaded)),
            "Finish the current dictation first."
        )
    }

    func testLocalStateSendsGoThroughTheirOwnDoor() {
        let harness = SettingsProjectionTestHarness()
        let grant = ExportFolderGrant(bookmark: Data([1, 2]), displayPath: "/x")
        XCTAssertNil(harness.host.send(.setExportFolder(grant, origin: .page(.dataPrivacy))))
        XCTAssertEqual(harness.sentLocalState, [.setExportFolder(grant, origin: .page(.dataPrivacy))])
        XCTAssertEqual(harness.localState.exportFolder, grant)
        XCTAssertEqual(harness.effects, [.persistLocalState])
        XCTAssertTrue(harness.sent.isEmpty)
    }

    func testClearRefusalNote() {
        let harness = SettingsProjectionTestHarness()
        harness.startJob()
        harness.host.send(.setShowDockIcon(true, origin: .page(.general)))
        XCTAssertNotNil(harness.host.refusalNote)
        harness.host.clearRefusalNote()
        XCTAssertNil(harness.host.refusalNote)
    }

    func testDetachedHostAcceptsEverythingAndRunsNothing() {
        let host = SettingsProjectionHost.detached(settings: AppSettings(launchAtLogin: true))
        XCTAssertTrue(host.settings.launchAtLogin)
        XCTAssertNil(host.send(.setLaunchAtLogin(false, origin: .page(.general))))
        XCTAssertFalse(host.settings.launchAtLogin)
        XCTAssertNil(host.refusalNote)
    }

    func testTheDefaultSendIsTheCoordinatorsOwn() {
        let coordinator = SettingsCoordinator(gate: { SettingsGate(dictation: .jobActive) }, effectRunner: { _ in })
        let host = SettingsProjectionHost(coordinator: coordinator)
        XCTAssertNotNil(host.send(.setShowDockIcon(true, origin: .page(.general))))
        XCTAssertEqual(host.refusalNote, "Finish the current dictation first.")
    }
}
