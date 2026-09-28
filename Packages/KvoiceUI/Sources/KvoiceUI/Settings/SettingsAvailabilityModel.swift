import Foundation
import KvoiceDomain
import Observation

/// The availability projection (ADR-022 item 3) as the pages see it: one
/// observable table the shell refreshes whenever its inputs change — a
/// dictation state change, the slow model/permission poll, and every
/// accepted settings intent (`AppDelegate+SettingsCoordinator.swift`).
///
/// Pages read `model[key]` and apply `.disabled` plus the localized reason;
/// the stored value never changes because a control is disabled. The
/// default (`.enabled` for every key) is what a preview or a test build
/// without a shell sees.
@Observable
@MainActor
public final class SettingsAvailabilityModel {
    public private(set) var table: [SettingKey: SettingAvailability]
    /// ADR-026: which distribution this is, for copy that describes what the
    /// edition does (not whether a control takes input — that is the table).
    /// Given by the shell at construction.
    public let edition: DistributionEdition
    /// ADR-027: the Private Cloud Compute daily-limit standing the shell last
    /// read (`EnvironmentProfile.privateCloudComputeQuota`), for the
    /// configuration row and the sheet. Not an availability rule: a reached
    /// limit leaves the model available (Apple: quota is orthogonal to
    /// availability).
    public private(set) var privateCloudComputeQuota: AIProviderQuota?
    /// ADR-027: the refusal that holds for this build whatever the user
    /// does — the Developer ID edition, or an App Store build without the
    /// managed entitlement. The sheet refuses to save a Private Cloud
    /// Compute configuration while it is set; a passing state such as
    /// `systemNotReady` does not block saving.
    public private(set) var privateCloudComputeStaticRefusal: AIProviderUnavailableReason?

    public init(table: [SettingKey: SettingAvailability] = [:], edition: DistributionEdition = .developerID) {
        self.table = table
        self.edition = edition
    }

    public subscript(key: SettingKey) -> SettingAvailability {
        table[key] ?? .enabled
    }

    /// Whether the control takes input. `.hidden` reads as disabled until a
    /// rule produces it and a page decides how to hide.
    public func isEnabled(_ key: SettingKey) -> Bool {
        self[key].isEnabled
    }

    /// The localized footnote for a disabled control, or nil when enabled.
    public func disabledReason(_ key: SettingKey) -> String? {
        self[key].disabledReason.map { DomainCopy.localized($0) }
    }

    /// A section footer: the page's own sentence, with the reason appended
    /// while the control is disabled.
    public func footnote(_ key: SettingKey, base: String) -> String {
        guard let reason = disabledReason(key) else { return base }
        return base + " " + reason
    }

    /// Replaces the table; equality-guarded so a poll that finds nothing
    /// changed does not re-render every page.
    public func update(_ table: [SettingKey: SettingAvailability]) {
        guard table != self.table else { return }
        self.table = table
    }

    /// ADR-027: equality-guarded like `update(_:)`.
    public func update(privateCloudComputeStaticRefusal refusal: AIProviderUnavailableReason?) {
        guard refusal != privateCloudComputeStaticRefusal else { return }
        privateCloudComputeStaticRefusal = refusal
    }

    /// ADR-027: the localized reason the configuration sheet may not save a
    /// configuration of this transport, or nil when it may.
    public func savingRefusal(for transport: AIProviderTransport) -> String? {
        guard transport == .privateCloudCompute, let refusal = privateCloudComputeStaticRefusal else { return nil }
        return DomainCopy.localized(refusal.message)
    }

    /// ADR-027: equality-guarded like `update(_:)`.
    public func update(privateCloudComputeQuota quota: AIProviderQuota?) {
        guard quota != privateCloudComputeQuota else { return }
        privateCloudComputeQuota = quota
    }

    /// ADR-027: the localized quota line for the Private Cloud Compute row,
    /// or nil when there is nothing to say (below the limit, or unknown). A
    /// reached limit names the reset time when Apple gives one.
    public var privateCloudComputeQuotaLine: String? {
        guard let quota = privateCloudComputeQuota, let message = quota.message else { return nil }
        let line = DomainCopy.localized(message)
        guard quota.status == .limitReached, let reset = quota.resetDate else { return line }
        let time = reset.formatted(date: .abbreviated, time: .shortened)
        return line + " " + String(localized: "Resets \(time).", bundle: .module)
    }
}
