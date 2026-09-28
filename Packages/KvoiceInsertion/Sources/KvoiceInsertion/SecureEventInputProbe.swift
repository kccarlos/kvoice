import Carbon.HIToolbox
import Foundation

/// Whether some process has Secure Event Input on — what a password field
/// (and a terminal's "Secure Keyboard Entry") turns on while it has focus.
///
/// ADR-026: the App Store edition cannot read the focused element's role,
/// so the secure-field refusal of the Accessibility path (L.8 check 4,
/// `AXSecureMetadata`) has no direct counterpart there. This is the coarse
/// substitute: while secure input is on anywhere, typing is refused and the
/// transcript goes to the clipboard instead. It cannot tell *which* field is
/// secure, and an app that shows a password field without enabling secure
/// input is not caught — the edition's accepted cost, recorded in ADR-026.
public protocol SecureEventInputProviding: Sendable {
    var isSecureEventInputEnabled: Bool { get }
}

public struct SystemSecureEventInputProbe: SecureEventInputProviding {
    public init() {}

    public var isSecureEventInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }
}
