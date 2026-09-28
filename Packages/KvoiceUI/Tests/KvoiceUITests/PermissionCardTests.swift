import XCTest
@testable import KvoiceDomain
@testable import KvoiceUI

/// Spec D.9: five states, one action, a last-checked time, and never a green
/// badge from a stale reading.
@MainActor
final class PermissionCardTests: XCTestCase {
    func testMicrophoneAuthorizationMapsOntoTheFiveStates() {
        XCTAssertEqual(PermissionCardState(PermissionAuthorization.notDetermined), .notRequested)
        XCTAssertEqual(PermissionCardState(PermissionAuthorization.granted), .granted)
        XCTAssertEqual(PermissionCardState(PermissionAuthorization.denied), .denied)
        XCTAssertEqual(PermissionCardState(PermissionAuthorization.restricted), .restricted)
    }

    func testAccessibilityStatusMapsOntoTheFiveStates() {
        XCTAssertEqual(PermissionCardState(AccessibilityPermissionStatus.notDetermined), .notRequested)
        XCTAssertEqual(PermissionCardState(AccessibilityPermissionStatus.granted), .granted)
        XCTAssertEqual(PermissionCardState(AccessibilityPermissionStatus.denied), .denied)
        XCTAssertEqual(PermissionCardState(AccessibilityPermissionStatus.unknown), .unknown)
    }

    func testStaleGrantedIsPresentedAsUnknownNeverGreen() {
        let checked = Date(timeIntervalSince1970: 1_000)
        let card = PermissionCard(kind: .microphone, state: .granted, lastChecked: checked)

        XCTAssertEqual(card.presentedState(now: checked.addingTimeInterval(1)), .granted)
        XCTAssertEqual(card.presentedState(now: checked.addingTimeInterval(PermissionCard.staleAfter)), .granted)
        XCTAssertEqual(card.presentedState(now: checked.addingTimeInterval(PermissionCard.staleAfter + 0.5)), .unknown)
        XCTAssertTrue(card.isStale(now: checked.addingTimeInterval(60)))

        let neverChecked = PermissionCard(kind: .microphone, state: .granted, lastChecked: nil)
        XCTAssertEqual(neverChecked.presentedState(), .unknown, "a Granted with no timestamp is not evidence")
    }

    func testStaleNonGrantedStatesAreNotUpgradedOrHidden() {
        let old = Date(timeIntervalSince1970: 0)
        for state in [PermissionCardState.denied, .restricted, .notRequested, .unknown] {
            let card = PermissionCard(kind: .accessibility, state: state, lastChecked: old)
            XCTAssertEqual(card.presentedState(now: Date()), state, "\(state) is shown as read; only Granted expires")
        }
    }

    func testEachStateOffersExactlyOneRelevantAction() {
        let now = Date()
        func card(_ state: PermissionCardState) -> PermissionCard {
            PermissionCard(kind: .accessibility, state: state, lastChecked: now)
        }

        XCTAssertEqual(card(.notRequested).action(now: now), .request)
        XCTAssertEqual(card(.denied).action(now: now), .openSystemSettings)
        XCTAssertEqual(card(.restricted).action(now: now), .openSystemSettings)
        XCTAssertEqual(card(.granted).action(now: now), .refresh)
        XCTAssertEqual(card(.unknown).action(now: now), .refresh)

        // The written path accompanies the deep link (FR-PERM-004).
        XCTAssertTrue(card(.denied).showsSystemSettingsPath(now: now))
        XCTAssertFalse(card(.granted).showsSystemSettingsPath(now: now))
        XCTAssertTrue(PermissionKind.accessibility.systemSettingsPath.contains("Accessibility"))
        XCTAssertTrue(PermissionKind.microphone.systemSettingsPath.contains("Microphone"))
    }

    func testStaleGrantedFallsBackToRefreshAction() {
        let old = Date(timeIntervalSince1970: 0)
        let card = PermissionCard(kind: .microphone, state: .granted, lastChecked: old)
        XCTAssertEqual(card.action(now: Date()), .refresh)
    }

    // MARK: PermissionStatusViewModel

    func testRefreshNeverPromptsAndStampsLastChecked() async {
        let microphone = FakeMicrophonePermission(authorization: .granted)
        let accessibility = FakeAccessibilityPermission(refreshValue: false, promptValue: true)
        let clock = Date(timeIntervalSince1970: 5_000)
        let model = PermissionStatusViewModel(
            microphonePermission: microphone,
            accessibilityPermission: accessibility,
            now: { clock }
        )

        XCTAssertEqual(model.microphone.presentedState(), .unknown)
        XCTAssertNil(model.microphone.lastChecked)

        await model.refresh()

        XCTAssertEqual(microphone.requestCount, 0)
        XCTAssertEqual(accessibility.prompts, [false])
        XCTAssertEqual(model.microphone.state, .granted)
        XCTAssertEqual(model.microphone.lastChecked, clock)
        XCTAssertEqual(model.accessibility.state, .notRequested, "an unprompted false is Not Requested, not Denied")
        XCTAssertEqual(model.microphone.presentedState(now: clock), .granted)
        XCTAssertEqual(model.microphone.presentedState(now: clock.addingTimeInterval(30)), .unknown)
    }

    func testRequestIsTheOnlyPromptingPathAndFalseAfterPromptIsDenied() async {
        let microphone = FakeMicrophonePermission(authorization: .denied)
        let accessibility = FakeAccessibilityPermission(refreshValue: false, promptValue: false)
        let model = PermissionStatusViewModel(
            microphonePermission: microphone,
            accessibilityPermission: accessibility
        )

        await model.performAction(for: .microphone)     // unknown -> refresh
        XCTAssertEqual(microphone.requestCount, 0)
        XCTAssertEqual(model.microphone.state, .denied)

        await model.request(.accessibility)
        XCTAssertEqual(accessibility.prompts.last, true)
        XCTAssertEqual(model.accessibility.state, .denied, "a prompt is not a grant (FR-PERM-006)")
        XCTAssertEqual(model.accessibility.action(), .openSystemSettings)
    }

    func testDeepLinkFailureIsRememberedPerPermission() async {
        var attempts: [PermissionKind] = []
        let model = PermissionStatusViewModel(openSystemSettings: { kind in
            attempts.append(kind)
            return kind == .accessibility
        })

        model.open(.microphone)
        XCTAssertEqual(model.systemSettingsOpenFailed, .microphone)

        model.open(.accessibility)
        XCTAssertEqual(model.systemSettingsOpenFailed, .microphone, "an unrelated success does not clear the failure")

        XCTAssertEqual(attempts, [.microphone, .accessibility])
    }

    func testPermissionsSectionCanBeConstructedWithoutPrompting() {
        let view = PermissionsSectionView()
        XCTAssertNotNil(view)
    }

    /// A Request prompt stays open as long as the user likes; the card's
    /// button must be locked meanwhile so a second press cannot queue a
    /// second prompt, and unlocked afterwards.
    func testACardActionIsMarkedInFlightUntilItFinishes() async {
        let microphone = FakeMicrophonePermission(authorization: .notDetermined)
        let gate = AsyncGate()
        microphone.beforeRequest = { await gate.wait() }
        let model = PermissionStatusViewModel(
            microphonePermission: microphone,
            accessibilityPermission: FakeAccessibilityPermission(refreshValue: false, promptValue: false)
        )
        await model.refresh()
        XCTAssertNil(model.actionInProgress)

        let first = Task { await model.performAction(for: .microphone) }
        await gate.waitUntilWaiting()
        XCTAssertEqual(model.actionInProgress, .microphone)

        // A second press while the prompt is up is dropped.
        await model.performAction(for: .microphone)
        XCTAssertEqual(microphone.requestCount, 1)

        await gate.open()
        await first.value
        XCTAssertNil(model.actionInProgress)
        XCTAssertEqual(microphone.requestCount, 1)
    }
}

/// Lets a test hold an async call open until it chooses to release it.
private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waitingObservers: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for observer in waitingObservers { observer.resume() }
            waitingObservers.removeAll()
        }
    }

    /// Returns once `wait()` is parked.
    func waitUntilWaiting() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { waitingObservers.append($0) }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private final class FakeMicrophonePermission: MicrophonePermissionProviding, @unchecked Sendable {
    let authorizationValue: PermissionAuthorization
    private(set) var requestCount = 0
    var beforeRequest: (@Sendable () async -> Void)?

    init(authorization: PermissionAuthorization) {
        authorizationValue = authorization
    }

    func authorization() async -> PermissionAuthorization {
        authorizationValue
    }

    func requestAccess() async -> PermissionAuthorization {
        requestCount += 1
        await beforeRequest?()
        return authorizationValue
    }
}

private final class FakeAccessibilityPermission: AccessibilityPermissionProviding, @unchecked Sendable {
    let refreshValue: Bool
    let promptValue: Bool
    private(set) var prompts: [Bool] = []

    init(refreshValue: Bool, promptValue: Bool) {
        self.refreshValue = refreshValue
        self.promptValue = promptValue
    }

    func isTrusted(prompt: Bool) async -> Bool {
        prompts.append(prompt)
        return prompt ? promptValue : refreshValue
    }
}
