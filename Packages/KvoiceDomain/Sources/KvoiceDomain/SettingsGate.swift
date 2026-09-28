import Foundation

/// ADR-022 item 4: the one description of the shell's state that settings
/// decisions depend on. The shell builds it from facts it already has
/// (`latestState.kind`, the model library's `ModelActivity`, the
/// load/termination flags) and hands it to `SettingsReducer`
/// (KvoiceAppCore) and `SettingsAvailability` (below), so idle-gating is
/// decided in one place instead of once per handler.
///
/// Slice 4 (ADR-022 item 5): `model` is the library's own `ModelActivity`
/// — the shell mirrors it from `SpeechModelLibrary.activityChanges()` —
/// so a file transcription is `.transcribingFile` here rather than a
/// separate flag.
public struct SettingsGate: Equatable, Sendable {
    /// Whether a dictation job holds a settings snapshot. Everything that
    /// is not `.idle` (a `.blocked` HUD included, as today) counts as active:
    /// the running job — or the HUD still showing its outcome — must keep
    /// the values it started with.
    public enum DictationActivity: Equatable, Sendable {
        case idle
        case jobActive
    }

    public var dictation: DictationActivity
    /// What the model library is doing (`SpeechModelLibrary.activity`).
    public var model: ModelActivity
    /// Nothing is written before the settings file has been read, so the
    /// initial hydration can never be mistaken for a user edit.
    public var settingsLoaded: Bool
    /// `applicationShouldTerminate` ran; late callbacks must not write.
    public var terminationInProgress: Bool

    public init(
        dictation: DictationActivity = .idle,
        model: ModelActivity = .idle,
        settingsLoaded: Bool = true,
        terminationInProgress: Bool = false
    ) {
        self.dictation = dictation
        self.model = model
        self.settingsLoaded = settingsLoaded
        self.terminationInProgress = terminationInProgress
    }

    /// Loaded, idle, nothing holding the engine: every intent applies.
    public static let idle = SettingsGate()

    /// "Transcribe File…" holds the resident engine.
    public var transcribingFile: Bool { model == .transcribingFile }

    /// True when anything owns the resident engine: a job, a file
    /// transcription, or a model operation. "Unload Model" and the
    /// compute-unit picker wait for all of them.
    public var engineIsHeld: Bool {
        dictation != .idle || model != .idle
    }
}
