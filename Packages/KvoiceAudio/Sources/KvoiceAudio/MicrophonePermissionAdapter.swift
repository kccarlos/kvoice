@preconcurrency import AVFoundation
import KvoiceDomain

/// Native TCC adapter.  Permission is queried before every capture attempt;
/// this type does not retain audio or attempt to infer permission from engine
/// start failures.
public struct SystemMicrophonePermissionProvider: MicrophonePermissionProviding, Sendable {
    /// Best-effort deep link to System Settings › Privacy & Security ›
    /// Microphone, mirroring `SystemAccessibilityPermissionAdapter
    /// .accessibilitySettingsURL`. The scheme is undocumented and can change,
    /// so callers must show the written path as well (FR-PERM-004).
    public static let microphoneSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )

    public init() {}

    public func authorization() async -> PermissionAuthorization {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: return .notDetermined
        case .denied: return .denied
        case .granted: return .granted
        @unknown default: return .restricted
        }
    }

    public func requestAccess() async -> PermissionAuthorization {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(
                    returning: granted ? .granted : .denied
                )
            }
        }
    }

}
