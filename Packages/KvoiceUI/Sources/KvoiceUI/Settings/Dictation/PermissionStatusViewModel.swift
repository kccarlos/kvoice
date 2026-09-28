import Foundation
import KvoiceDomain
import Observation

/// Owns the two permission cards on the Dictation tab.
///
/// Reads are explicit and never prompt; `request(_:)` is the only path that
/// shows an OS prompt and the view calls it only from the card's own button.
/// While the tab is visible the view runs `pollWhileVisible()`, which re-reads
/// both states every second (FR-PERM-005) so a grant made in System Settings
/// shows up without a relaunch and a revocation cannot hide behind a cached
/// Granted.
@Observable
@MainActor
public final class PermissionStatusViewModel {
    public private(set) var microphone: PermissionCard = .unchecked(.microphone)
    public private(set) var accessibility: PermissionCard = .unchecked(.accessibility)

    /// Set when the deep link could not be opened, so the view can promote the
    /// written path from a footnote to the main instruction.
    public private(set) var systemSettingsOpenFailed: PermissionKind?

    /// The card whose action is still running (a Request prompt can take as
    /// long as the user likes). Its button is disabled meanwhile so a second
    /// press cannot queue a second prompt.
    public private(set) var actionInProgress: PermissionKind?

    private let microphonePermission: any MicrophonePermissionProviding
    private let accessibilityPermission: any AccessibilityPermissionProviding
    private let openSystemSettings: @MainActor (PermissionKind) -> Bool
    /// ADR-026: which adapter `accessibilityPermission` is, for the card copy.
    public let edition: DistributionEdition
    private let now: @Sendable () -> Date
    private var accessibilityPromptWasRequested = false

    public init(
        microphonePermission: any MicrophonePermissionProviding = UnavailableMicrophonePermissionProvider(),
        accessibilityPermission: any AccessibilityPermissionProviding = UnavailableAccessibilityPermissionProvider(),
        edition: DistributionEdition = .developerID,
        openSystemSettings: @escaping @MainActor (PermissionKind) -> Bool = { _ in false },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.microphonePermission = microphonePermission
        self.accessibilityPermission = accessibilityPermission
        self.edition = edition
        accessibility = PermissionCard(kind: .accessibility, state: .unknown, lastChecked: nil, edition: edition)
        self.openSystemSettings = openSystemSettings
        self.now = now
    }

    public func card(for kind: PermissionKind) -> PermissionCard {
        switch kind {
        case .microphone: return microphone
        case .accessibility: return accessibility
        }
    }

    /// Reads both states without prompting.
    public func refresh() async {
        let authorization = await microphonePermission.authorization()
        let trusted = await accessibilityPermission.isTrusted(prompt: false)
        let checkedAt = now()
        microphone = PermissionCard(
            kind: .microphone,
            state: PermissionCardState(authorization),
            lastChecked: checkedAt
        )
        accessibility = PermissionCard(
            kind: .accessibility,
            state: accessibilityState(trusted: trusted),
            lastChecked: checkedAt,
            edition: edition
        )
    }

    /// Loops `refresh()` at `interval` until the calling task is cancelled.
    /// Run it from the tab's `.task` so it stops as soon as the tab is hidden.
    public func pollWhileVisible(interval: Duration = .seconds(1)) async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    /// The one prompting path. For Accessibility the OS prompt is asynchronous
    /// and the return value is the *current* trust, so a prompt being shown is
    /// never recorded as a grant (FR-PERM-006).
    public func request(_ kind: PermissionKind) async {
        switch kind {
        case .microphone:
            let authorization = await microphonePermission.requestAccess()
            microphone = PermissionCard(
                kind: .microphone,
                state: PermissionCardState(authorization),
                lastChecked: now()
            )
        case .accessibility:
            accessibilityPromptWasRequested = true
            let trusted = await accessibilityPermission.isTrusted(prompt: true)
            accessibility = PermissionCard(
                kind: .accessibility,
                state: accessibilityState(trusted: trusted),
                lastChecked: now(),
                edition: edition
            )
        }
    }

    /// Performs the card's single offered action.
    public func performAction(for kind: PermissionKind) async {
        guard actionInProgress != kind else { return }
        actionInProgress = kind
        defer { actionInProgress = nil }
        switch card(for: kind).action(now: now()) {
        case .request:
            await request(kind)
        case .openSystemSettings:
            open(kind)
        case .refresh:
            await refresh()
        }
    }

    /// Best-effort deep link. A failure is remembered so the view leads with
    /// the written path instead.
    public func open(_ kind: PermissionKind) {
        if openSystemSettings(kind) {
            if systemSettingsOpenFailed == kind {
                systemSettingsOpenFailed = nil
            }
        } else {
            systemSettingsOpenFailed = kind
        }
    }

    private func accessibilityState(trusted: Bool) -> PermissionCardState {
        if trusted { return .granted }
        // AXIsProcessTrusted cannot distinguish "never asked" from "refused".
        // Before this session has prompted, the honest label is Not Requested.
        return accessibilityPromptWasRequested ? .denied : .notRequested
    }
}
