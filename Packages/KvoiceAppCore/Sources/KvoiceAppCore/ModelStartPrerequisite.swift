import Foundation
import KvoiceDomain

/// The model half of the start prerequisite check (C.5 step 3 /
/// FR-PERM-002), as a pure function over the default model's lifecycle
/// state so the sentence per state is testable. `AppComposition`'s
/// `prerequisiteChecker` closure asks the library for the three inputs and
/// hands the answer to the controller; the closure keeps only what cannot
/// be pure — the reload kickoff for a verified-but-not-resident model.
///
/// ADR-025 amendment (2026-09-16): a system-managed default (Apple Speech)
/// that is `.absent` or `.unavailable` gets its own sentence. The generic
/// "No transcription model is ready. Download or choose one…" sent the
/// user to a card that read "Installed" — the assets are per language,
/// and the language they had just chosen had none. The `KVoiceErrorCode`
/// stays `modelNotInstalled` for every blocked model state, so the HUD's
/// error mapping and the diagnostics are unchanged.
public enum ModelStartPrerequisite {
    /// - Parameters:
    ///   - state: the default model's lifecycle state.
    ///   - isResident: `SpeechModelLibrary.isDefaultModelResident()` — the
    ///     engine holds the default model (ADR-017: another installed model
    ///     in the engine does not count).
    ///   - isSystemManaged: the default entry's `assetSource` is
    ///     `.systemManaged` (ADR-025).
    public static func check(
        _ state: ModelLifecycleState,
        isResident: Bool,
        isSystemManaged: Bool
    ) -> StartPrerequisites {
        switch state {
        case .ready, .inference:
            // Verified but not resident: the launch load hasn't reached it
            // yet, memory pressure released it, or a compute-units reload
            // is in flight. Blocked/loading, never a failure; the caller
            // kicks off the reload.
            return isResident ? .passed : .blocked(.modelLoading)
        case .downloading, .downloadPaused, .verifying, .installing, .loading, .validatingExternal:
            return .blocked(.modelLoading)
        case .optimizing:
            // 2026-09-29: the first Core ML build on this Mac — minutes,
            // not a moment, and the sentence says so.
            return .blocked(.modelOptimizing)
        case .absent:
            return .blocked(isSystemManaged ? .systemManagedAssetsMissing : .modelUnavailable)
        case .unavailable(let failure):
            return .blocked(isSystemManaged ? .systemManagedUnavailable(failure) : .modelUnavailable)
        case .corrupt, .incompatible, .deleting, .error:
            return .blocked(.modelUnavailable)
        }
    }

    /// Whether `check` would ask the caller to bring the resident runtime
    /// back: verified, not resident.
    public static func wantsReload(_ state: ModelLifecycleState, isResident: Bool) -> Bool {
        switch state {
        case .ready, .inference: return !isResident
        default: return false
        }
    }
}
