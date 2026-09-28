import Foundation
import Security

/// ADR-027: whether this running build is *signed* to use Private Cloud
/// Compute, so an unentitled build (every Debug and local `kvoice Local
/// Signing` build, every Developer ID build) reports the engine unavailable
/// with a reason instead of failing at request time.
///
/// Apple documents `com.apple.developer.private-cloud-compute` as a
/// *managed* entitlement: it is assigned to the developer account on
/// request and reaches an app only through a provisioning profile that
/// grants it. A signature can carry any key, so the key alone is not proof;
/// the heuristic is "the process holds the key as `true` **and** the bundle
/// embeds a provisioning profile" (`Contents/embedded.provisionprofile`).
/// It is a heuristic and says so: the request path still fails closed
/// (`.aiProviderUnavailable` or the framework's own error) if the OS
/// disagrees. Reading one's own entitlements needs no permission and makes
/// no network request.
public enum PrivateCloudComputeSigning {
    /// The managed entitlement's key (Apple's entitlement reference,
    /// macOS 27.0).
    public static let entitlementKey = "com.apple.developer.private-cloud-compute"

    /// The pure rule, for tests: the entitlement's value must be a Boolean
    /// `true`, and a provisioning profile must be embedded.
    public static func isEntitled(entitlementValue: Any?, hasProvisioningProfile: Bool) -> Bool {
        guard hasProvisioningProfile else { return false }
        if let flag = entitlementValue as? Bool { return flag }
        if let number = entitlementValue as? NSNumber { return number.boolValue }
        return false
    }

    /// The running process, read once by the composition root.
    public static func currentProcessIsEntitled(bundle: Bundle = .main) -> Bool {
        let profile = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("embedded.provisionprofile", isDirectory: false)
        let hasProfile = FileManager.default.fileExists(atPath: profile.path)
        guard hasProfile, let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, entitlementKey as CFString, nil)
        return isEntitled(entitlementValue: value, hasProvisioningProfile: hasProfile)
    }
}
