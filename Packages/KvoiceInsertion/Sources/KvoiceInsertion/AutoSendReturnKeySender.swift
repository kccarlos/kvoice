import Foundation
import KvoiceDomain

public enum AutoSendError: Error, Sendable, Equatable {
    /// Posting keyboard events needs Accessibility trust.
    case accessibilityNotTrusted
    /// The recording-start application is no longer frontmost, so the
    /// Return would land somewhere the user did not dictate into.
    case targetApplicationChanged
}

/// Auto-send's "press Return after insertion" (HoAh parity, opt-in).
///
/// Reuses the ADR-016 typed keyboard-event poster and keeps the same two
/// safety rules as typed insertion: the process must be Accessibility-trusted,
/// and the recording-start application must still be frontmost. The event is
/// addressed to that PID only. Never a paste chord; the poster's
/// source-scanning test forbids one.
public struct AutoSendReturnKeySender: ReturnKeySending {
    private let workspace: any FrontmostApplicationProviding
    private let trust: any AccessibilityTrustProviding
    private let poster: any KeyboardEventPosting

    public init(
        workspace: any FrontmostApplicationProviding = SystemFrontmostApplicationProvider(),
        trust: any AccessibilityTrustProviding = SystemAccessibilityTrustProvider(),
        poster: any KeyboardEventPosting = TypedKeyboardEventPoster()
    ) {
        self.workspace = workspace
        self.trust = trust
        self.poster = poster
    }

    public func sendReturnKey(to target: TargetApplicationSnapshot, jobID _: JobID) async throws {
        try Task.checkCancellation()
        guard trust.isTrusted(prompt: false) else {
            throw AutoSendError.accessibilityNotTrusted
        }
        guard let frontmost = workspace.frontmostApplication(),
              frontmost.processIdentifier == target.processIdentifier
        else {
            throw AutoSendError.targetApplicationChanged
        }
        try poster.postReturnKey(to: target.processIdentifier)
    }
}
