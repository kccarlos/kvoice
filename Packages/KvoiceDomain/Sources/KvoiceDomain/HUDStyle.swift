import Foundation

/// Settings › Recording › Recorder style (ADR-021). Which shape the
/// non-activating recorder HUD takes; both styles show the level meter, the
/// elapsed time, and the in-recorder AI controls, and both keep the D.4
/// auto-dismiss timings. The value is captured in the job's settings
/// snapshot at the start edge like every other recording setting, so a
/// change made mid-dictation applies from the next one.
public enum HUDStyle: String, Codable, Sendable, Equatable, CaseIterable {
    /// A floating pill near the bottom-centre of the recording-start screen
    /// (D.3's original geometry).
    case mini
    /// A dark shape hanging from the menu bar directly under the camera
    /// housing of a built-in display; on a display without a housing it
    /// hangs from the top-centre with the same look.
    case notch
}
