import KvoiceDomain
import XCTest

/// ADR-026: the edition value and the availability rows that key off it.
final class DistributionEditionTests: XCTestCase {
    func testInfoDictionaryDecidesTheEdition() {
        XCTAssertEqual(DistributionEdition(infoDictionary: ["KvoiceDistributionEdition": "appStore"]), .appStore)
        XCTAssertEqual(DistributionEdition(infoDictionary: ["KvoiceDistributionEdition": "developerID"]), .developerID)
    }

    /// Anything else is the Developer ID edition — the one whose behaviour
    /// is unchanged — including an unexpanded build setting.
    func testMissingOrUnknownValuesAreTheDeveloperIDEdition() {
        XCTAssertEqual(DistributionEdition(infoDictionary: nil), .developerID)
        XCTAssertEqual(DistributionEdition(infoDictionary: [:]), .developerID)
        XCTAssertEqual(DistributionEdition(infoDictionary: ["KvoiceDistributionEdition": "$(KVOICE_DISTRIBUTION_EDITION)"]), .developerID)
        XCTAssertEqual(DistributionEdition(infoDictionary: ["KvoiceDistributionEdition": "AppStore"]), .developerID)
        XCTAssertEqual(DistributionEdition(infoDictionary: ["KvoiceDistributionEdition": 1]), .developerID)
    }

    func testDeveloperIDCapabilitiesAreTheUnchangedOnes() {
        let edition = DistributionEdition.developerID
        XCTAssertFalse(edition.isSandboxed)
        XCTAssertTrue(edition.canControlOtherAppsThroughAccessibility)
        XCTAssertTrue(edition.canReadSelectionInOtherApps)
        XCTAssertTrue(edition.hasGlobalInputMonitors)
        XCTAssertTrue(edition.migratesLegacyDefaultsDomain)
        XCTAssertEqual(edition.insertionStrategy, .accessibilityThenTyped)
    }

    func testAppStoreCapabilities() {
        let edition = DistributionEdition.appStore
        XCTAssertTrue(edition.isSandboxed)
        XCTAssertFalse(edition.canControlOtherAppsThroughAccessibility)
        XCTAssertFalse(edition.canReadSelectionInOtherApps)
        XCTAssertFalse(edition.hasGlobalInputMonitors)
        XCTAssertFalse(edition.migratesLegacyDefaultsDomain)
        XCTAssertEqual(edition.insertionStrategy, .typedOnly)
    }

    func testEnvironmentDefaultsToTheDeveloperIDEdition() {
        XCTAssertEqual(EnvironmentProfile.unknown.edition, .developerID)
        XCTAssertEqual(EnvironmentProfile(edition: .appStore).edition, .appStore)
    }

    private static let sandboxed = ["APP_SANDBOX_CONTAINER_ID": "io.github.kccarlos.kvoice"]
    private static var storePlist: [String: Any] { ["KvoiceDistributionEdition": "appStore"] }
    private static var dmgPlist: [String: Any] { ["KvoiceDistributionEdition": "developerID"] }

    /// The sandbox wins: a sandboxed process is the App Store edition even
    /// when its bundle declares otherwise; unsandboxed, the declaration.
    func testRunningSandboxedIsAlwaysTheAppStoreEdition() {
        XCTAssertEqual(DistributionEdition(infoDictionary: Self.dmgPlist, environment: Self.sandboxed), .appStore)
        XCTAssertEqual(DistributionEdition(infoDictionary: nil, environment: Self.sandboxed), .appStore)
        XCTAssertEqual(DistributionEdition(infoDictionary: Self.storePlist, environment: Self.sandboxed), .appStore)
        XCTAssertEqual(DistributionEdition(infoDictionary: Self.storePlist, environment: [:]), .appStore)
        XCTAssertEqual(DistributionEdition(infoDictionary: Self.dmgPlist, environment: [:]), .developerID)
        XCTAssertEqual(DistributionEdition(infoDictionary: nil, environment: ["HOME": "/tmp"]), .developerID)
    }

    func testLaunchDiagnosticNamesTheEditionAndWarnsOnASandboxMismatch() {
        let store = DistributionEdition.launchDiagnostic(infoDictionary: Self.storePlist, environment: Self.sandboxed)
        XCTAssertEqual(store.name, .appEdition)
        XCTAssertEqual(store.result, .success)
        XCTAssertEqual(store.attributes.reason?.rawValue, "appStore")
        XCTAssertEqual(store.attributes.site?.rawValue, "sandboxed")

        XCTAssertEqual(DistributionEdition.launchDiagnostic(infoDictionary: Self.dmgPlist, environment: [:]).result, .success)
        XCTAssertEqual(DistributionEdition.launchDiagnostic(infoDictionary: Self.storePlist, environment: [:]).result, .warning)
        let mislabelled = DistributionEdition.launchDiagnostic(infoDictionary: Self.dmgPlist, environment: Self.sandboxed)
        XCTAssertEqual(mislabelled.result, .warning)
        XCTAssertEqual(mislabelled.attributes.reason?.rawValue, "appStore", "the edition in effect")
    }

    // MARK: Availability

    private func availability(_ key: SettingKey, _ edition: DistributionEdition, gate: SettingsGate = .idle) -> SettingAvailability {
        SettingsAvailability.availability(
            key: key, settings: AppSettings(), environment: EnvironmentProfile(edition: edition), gate: gate
        )
    }

    func testAppStoreEditionRefusesWhatItCannotDo() {
        XCTAssertEqual(
            availability(.selectionAction, .appStore),
            .disabled(reason: SettingAvailabilityReason.noSelectionReadingInAppStoreEdition.message)
        )
        XCTAssertEqual(
            availability(.middleMouseTrigger, .appStore),
            .disabled(reason: SettingAvailabilityReason.noGlobalInputMonitorsInAppStoreEdition.message)
        )
        XCTAssertEqual(
            availability(.typedInsertion, .appStore),
            .disabled(reason: SettingAvailabilityReason.typingIsTheInsertionPathInAppStoreEdition.message)
        )
    }

    /// The edition's refusal outranks "finish the dictation first": the
    /// sentence that stays true after the job is the one to show.
    func testEditionRefusalOutranksTheJobRefusal() {
        let jobActive = SettingsGate(dictation: .jobActive)
        XCTAssertEqual(
            availability(.middleMouseTrigger, .appStore, gate: jobActive),
            .disabled(reason: SettingAvailabilityReason.noGlobalInputMonitorsInAppStoreEdition.message)
        )
        XCTAssertEqual(
            availability(.typedInsertion, .appStore, gate: jobActive),
            .disabled(reason: SettingAvailabilityReason.typingIsTheInsertionPathInAppStoreEdition.message)
        )
    }

    func testDeveloperIDEditionKeepsEveryNewControl() {
        XCTAssertEqual(availability(.selectionAction, .developerID), .enabled)
        XCTAssertEqual(availability(.middleMouseTrigger, .developerID), .enabled)
        XCTAssertEqual(availability(.typedInsertion, .developerID), .enabled)
        // The Selection Action is not a recording setting: a job does not
        // freeze it.
        XCTAssertEqual(availability(.selectionAction, .developerID, gate: SettingsGate(dictation: .jobActive)), .enabled)
    }

    /// The rest of the table does not depend on the edition.
    func testEveryOtherKeyIsTheSameInBothEditions() {
        let editionKeys: Set<SettingKey> = [.selectionAction, .middleMouseTrigger, .typedInsertion]
        for key in SettingKey.allCases where !editionKeys.contains(key) {
            XCTAssertEqual(availability(key, .appStore), availability(key, .developerID), key.rawValue)
        }
    }
}
