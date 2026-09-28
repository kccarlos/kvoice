import Foundation
import KvoiceDomain

/// Resolves target affinity at insertion time.  It deliberately stores only
/// providers; an AX element is returned to the caller and is never retained by
/// the resolver or insertion service.
public struct AXTargetResolver: Sendable {
    private let workspace: any FrontmostApplicationProviding
    private let axClient: any AXElementClient
    private let focusRetryCount: Int
    private let focusRetryDelay: Duration

    /// `focusRetryCount` / `focusRetryDelay` bound the wait for an
    /// Electron/Chromium app to publish its focused element after the
    /// accessibility handshake (Claude desktop needed one retry on the
    /// M4 test Mac). The resolver runs on the serial AX executor, so the wait
    /// blocks only the insertion in progress. Tests pass a zero delay.
    public init(
        workspace: any FrontmostApplicationProviding,
        axClient: any AXElementClient,
        focusRetryCount: Int = 4,
        focusRetryDelay: Duration = .milliseconds(60)
    ) {
        self.workspace = workspace
        self.axClient = axClient
        self.focusRetryCount = max(0, focusRetryCount)
        self.focusRetryDelay = focusRetryDelay
    }

    public func currentTargetMatches(_ target: TargetApplicationSnapshot) -> Bool {
        guard let current = workspace.frontmostApplication() else { return false }
        guard current.processIdentifier == target.processIdentifier else { return false }
        guard let expectedBundle = nonEmptyIdentity(target.bundleIdentifier),
              let currentBundle = nonEmptyIdentity(current.bundleIdentifier)
        else {
            return false
        }
        return expectedBundle == currentBundle
    }

    public func resolveFocusedElement(
        for target: TargetApplicationSnapshot
    ) throws -> AXElementHandle {
        guard let current = workspace.frontmostApplication() else {
            throw AXTargetResolutionError.noFrontmostApplication
        }
        guard current.processIdentifier == target.processIdentifier else {
            throw AXTargetResolutionError.targetChanged
        }
        guard let expectedBundle = nonEmptyIdentity(target.bundleIdentifier),
              let currentBundle = nonEmptyIdentity(current.bundleIdentifier)
        else {
            throw AXTargetResolutionError.identityUnavailable
        }
        guard currentBundle == expectedBundle else {
            throw AXTargetResolutionError.targetChanged
        }
        guard let element = try focusedElementWithHandshake(processIdentifier: target.processIdentifier) else {
            throw AXTargetResolutionError.noFocusedElement
        }
        guard try axClient.processIdentifier(of: element) == target.processIdentifier else {
            throw AXTargetResolutionError.targetChanged
        }
        guard currentTargetMatches(target) else {
            throw AXTargetResolutionError.targetChanged
        }
        return element
    }
}

extension AXTargetResolver {
    /// System-wide focus first (what every native app answers), then the
    /// application's own root. When both are empty the app may be an
    /// Electron/Chromium one that has not built its tree yet: ask it to, and
    /// poll briefly. A native app with genuinely nothing focused ignores the
    /// handshake and still resolves to `nil` after the retries.
    func focusedElementWithHandshake(processIdentifier: pid_t) throws -> AXElementHandle? {
        if let element = try axClient.focusedElement() { return element }
        if let element = try axClient.focusedElement(inApplication: processIdentifier) { return element }
        try axClient.enableAccessibility(inApplication: processIdentifier)
        for _ in 0..<focusRetryCount {
            if focusRetryDelay > .zero {
                Thread.sleep(forTimeInterval: Double(focusRetryDelay.components.seconds)
                    + Double(focusRetryDelay.components.attoseconds) / 1e18)
            }
            if let element = try axClient.focusedElement(inApplication: processIdentifier) { return element }
            if let element = try axClient.focusedElement() { return element }
        }
        return nil
    }
}

public enum AXTargetResolutionError: Error, Sendable, Equatable {
    case noFrontmostApplication
    case targetChanged
    case identityUnavailable
    case noFocusedElement
}

private func nonEmptyIdentity(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : value
}
