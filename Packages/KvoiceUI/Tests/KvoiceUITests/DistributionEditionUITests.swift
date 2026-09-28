import KvoiceDomain
import XCTest
@testable import KvoiceUI

/// ADR-026: the UI state the App Store edition changes — the permission copy
/// and the availability model's edition — and what it leaves alone.
@MainActor
final class DistributionEditionUITests: XCTestCase {
    func testAccessibilityRationaleDescribesTheEditionsPermission() {
        let developerID = PermissionKind.accessibility.rationale(for: .developerID)
        let appStore = PermissionKind.accessibility.rationale(for: .appStore)
        XCTAssertEqual(developerID, PermissionKind.accessibility.rationale)
        XCTAssertNotEqual(appStore, developerID)
        XCTAssertTrue(appStore.contains("keystrokes"))
        // The microphone card is the same in both editions.
        XCTAssertEqual(PermissionKind.microphone.rationale(for: .appStore), PermissionKind.microphone.rationale)
    }

    func testCardsDefaultToTheDeveloperIDEdition() {
        let card = PermissionCard(kind: .accessibility, state: .granted, lastChecked: nil)
        XCTAssertEqual(card.edition, .developerID)
        XCTAssertEqual(card.rationale, PermissionKind.accessibility.rationale)
    }

    func testPermissionsSectionBuildsAppStoreCardsFromTheInjectedAdapter() async {
        let model = PermissionStatusViewModel(
            accessibilityPermission: FixedTrust(trusted: true),
            edition: .appStore,
            now: { Date(timeIntervalSince1970: 100) }
        )
        XCTAssertEqual(model.accessibility.edition, .appStore, "the unchecked card already carries the copy")
        await model.refresh()
        XCTAssertEqual(model.accessibility.state, .granted)
        XCTAssertEqual(model.accessibility.rationale, PermissionKind.accessibility.rationale(for: .appStore))
        await model.request(.accessibility)
        XCTAssertEqual(model.accessibility.edition, .appStore)
    }

    func testOnboardingAccessibilityCardCarriesTheEdition() {
        let appStore = OnboardingViewModel(edition: .appStore)
        XCTAssertEqual(appStore.edition, .appStore)
        XCTAssertEqual(appStore.accessibilityPermissionCard.edition, .appStore)
        XCTAssertEqual(OnboardingViewModel().accessibilityPermissionCard.edition, .developerID)
    }

    func testAvailabilityModelCarriesTheEditionForCopy() {
        XCTAssertEqual(SettingsAvailabilityModel().edition, .developerID)
        let model = SettingsAvailabilityModel(edition: .appStore)
        model.update(SettingsAvailability.table(
            settings: AppSettings(), environment: EnvironmentProfile(edition: .appStore), gate: .idle
        ))
        XCTAssertFalse(model.isEnabled(.selectionAction))
        XCTAssertFalse(model.isEnabled(.middleMouseTrigger))
        XCTAssertFalse(model.isEnabled(.typedInsertion))
        XCTAssertNotNil(model.disabledReason(.selectionAction))
        XCTAssertTrue(model.isEnabled(.shortcut), "key combinations stay")
        XCTAssertTrue(model.isEnabled(.insertedText), "the other inserted-text toggles stay")
    }
}

private struct FixedTrust: AccessibilityPermissionProviding {
    let trusted: Bool
    func isTrusted(prompt _: Bool) async -> Bool { trusted }
}
