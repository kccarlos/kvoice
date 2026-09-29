import Foundation

/// 2026-09-29 (owner decision 1, amending ADR-025's "Whisper stays the
/// default"): a **fresh setup** starts with Apple Speech whenever this Mac
/// can run it for the language it will dictate in; otherwise with the
/// catalog's recommended entry (Whisper large-v3-turbo), as before.
///
/// Why: in the owner's TestFlight run the default Whisper model took a
/// 632 MB download and then a ~3.5-minute Neural Engine compile before the
/// first dictation. Apple Speech has no download of kvoice's and no
/// compile — the OS installs its per-language assets in seconds (ADR-025
/// amendment: the existing per-language auto-install does it) — so a new
/// user dictates almost at once, and Whisper stays one click away.
///
/// "Can run it" uses only the ADR-025 facts that already exist, nothing new:
/// the system-managed entry's observed `ModelLifecycleState` (`.unavailable`
/// covers macOS < 26, an ineligible Mac and an unsupported chosen language;
/// `.error` is a failed platform query) and the catalog's observed language
/// list (the platform's locales, overlaid on the entry). The language is
/// the chosen transcription language, or — for Auto-detect, which a system
/// runtime reads as "your Mac's language" — the Mac's own language, which
/// the entry's list must cover (the locale mapping would otherwise quietly
/// fall back to English).
///
/// **Existing users never change.** The choice is made only for a fresh
/// setup: onboarding never completed, no saved default model, no saved
/// model selection, and no kvoice-managed package in any state other than
/// `.absent` (a user whose download was interrupted before the selection
/// was saved has Whisper on disk and keeps it). Once made, the choice is an
/// ordinary saved default (`AppSettings.defaultSpeechModelID`).
public enum SetupSpeechModelDefault {
    public static func isFreshSetup(
        onboardingCompletedVersion: Int?,
        savedDefaultModelID: ModelID?,
        selectedModel: ModelReference?,
        catalog: SpeechModelCatalog,
        states: [ModelID: ModelLifecycleState]
    ) -> Bool {
        guard onboardingCompletedVersion == nil, savedDefaultModelID == nil, selectedModel == nil else {
            return false
        }
        for (id, state) in states {
            guard let entry = catalog.entry(id: id), !entry.isSystemManaged else { continue }
            if case .absent = state { continue }
            return false
        }
        return true
    }

    /// The system-managed entry this Mac can run for `transcriptionLanguage`
    /// (or, for Auto-detect, `macLanguageCode`), or nil. Used for the fresh
    /// setup's default and for the wizard's "use it instead" offer.
    public static func usableSystemModel(
        catalog: SpeechModelCatalog,
        states: [ModelID: ModelLifecycleState],
        transcriptionLanguage: String?,
        macLanguageCode: String?
    ) -> ModelID? {
        for entry in catalog.entries where entry.isSystemManaged && entry.runtime.isAvailableInThisBuild {
            guard let state = states[entry.id], isUsable(state) else { continue }
            guard let language = transcriptionLanguage ?? macLanguageCode,
                  entry.supportsLanguage(language) else { continue }
            return entry.id
        }
        return nil
    }

    /// The default a fresh setup should adopt, or nil to keep the
    /// catalog's recommended entry (not a fresh setup, or no usable
    /// system-managed model).
    public static func choice(
        onboardingCompletedVersion: Int?,
        savedDefaultModelID: ModelID?,
        selectedModel: ModelReference?,
        catalog: SpeechModelCatalog,
        states: [ModelID: ModelLifecycleState],
        transcriptionLanguage: String?,
        macLanguageCode: String?
    ) -> ModelID? {
        guard isFreshSetup(
            onboardingCompletedVersion: onboardingCompletedVersion,
            savedDefaultModelID: savedDefaultModelID,
            selectedModel: selectedModel,
            catalog: catalog,
            states: states
        ) else { return nil }
        return usableSystemModel(
            catalog: catalog,
            states: states,
            transcriptionLanguage: transcriptionLanguage,
            macLanguageCode: macLanguageCode
        )
    }

    /// The one-click alternative the wizard offers beside `defaultModelID`:
    /// the catalog's recommended package model (Whisper) when the default
    /// is system-managed, the usable system-managed model when the default
    /// is the recommended package model, nil otherwise.
    public static func alternative(
        to defaultModelID: ModelID,
        catalog: SpeechModelCatalog,
        states: [ModelID: ModelLifecycleState],
        transcriptionLanguage: String?,
        macLanguageCode: String?
    ) -> ModelID? {
        guard let current = catalog.entry(id: defaultModelID) else { return nil }
        let recommendedPackage = catalog.entries.first { $0.isRecommended && !$0.isSystemManaged && states[$0.id] != nil }
        if current.isSystemManaged {
            return recommendedPackage?.id
        }
        guard current.id == recommendedPackage?.id else { return nil }
        return usableSystemModel(
            catalog: catalog,
            states: states,
            transcriptionLanguage: transcriptionLanguage,
            macLanguageCode: macLanguageCode
        )
    }

    /// Whether a switch to `entry` saves the new default *before* its
    /// install starts. A package model's download takes minutes and may be
    /// interrupted by a quit, so the choice is saved first (the next launch
    /// restores it and offers Resume). A system-managed entry is saved after
    /// its install: the install is seconds, and saving first would let the
    /// settings write's language effect start the same install from a task
    /// nothing polls, so the wizard card would sit at Install.
    public static func savesChoiceBeforeInstall(_ entry: SpeechModelCatalogEntry) -> Bool {
        !entry.isSystemManaged
    }

    private static func isUsable(_ state: ModelLifecycleState) -> Bool {
        switch state {
        case .absent, .downloading, .downloadPaused, .ready, .inference, .loading, .optimizing, .installing, .verifying:
            return true
        case .unavailable, .error, .corrupt, .incompatible, .deleting, .validatingExternal:
            return false
        }
    }
}
