import Foundation

/// ADR-022 item 3: the availability projection.
///
/// `availability(key:settings:environment:gate:)` is pure and table-driven —
/// one row per rule, the `reason` is the footnote or tooltip the page shows.
/// Stored values never change because a control is disabled; the projection
/// only says whether the control takes input right now and why not. The
/// shell computes the whole table (`table(settings:environment:gate:)`)
/// from facts it already has and pushes it into the pages
/// (`SettingsAvailabilityModel` in KvoiceUI); the Runtime card and
/// `MemoryPressureViewModel` read single keys through their snapshots.
///
/// Adding a rule: add a `SettingKey` (or reuse one), add the `reason` to
/// `SettingAvailabilityReason` (its English sentence is the `DomainCopy`
/// key — add the translation too, `DomainCopyTests` checks it), add the
/// row in `availability`, and add the row to `SettingsAvailabilityTests`.
public enum SettingsAvailability {
    public static func availability(
        key: SettingKey,
        settings: AppSettings,
        environment: EnvironmentProfile,
        gate: SettingsGate
    ) -> SettingAvailability {
        switch key {
        case .aiActionSettings:
            // What AI Actions do — the default action, triggers, the
            // profile — is moot while the master switch is off or no endpoint
            // could serve a request. The switch itself and the configuration
            // list stay enabled: they are how the user gets out of this state.
            if !settings.ai.isEnabled {
                return .disabled(reason: SettingAvailabilityReason.aiActionsOff.message)
            }
            if !settings.ai.canEnableProcessing {
                return .disabled(reason: SettingAvailabilityReason.noAIEndpoint.message)
            }
            // ADR-024: the active configuration is the on-device model and
            // the environment says it cannot take a request; the reason is
            // the framework's, in the user's words.
            if settings.ai.provider == .appleIntelligence,
               let reason = environment.appleIntelligenceAvailability?.unavailableMessage {
                return .disabled(reason: reason)
            }
            // ADR-027: the same for Private Cloud Compute. A reached quota is
            // not a refusal here — the model stays available and the row
            // says so; a request in that state falls back like any other.
            if settings.ai.provider == .privateCloudCompute,
               let reason = environment.privateCloudComputeAvailability?.unavailableMessage {
                return .disabled(reason: reason)
            }
            return .enabled

        case .aiAppleIntelligenceConfiguration:
            // ADR-024: the on-device configuration row's "Set as Active" and
            // its subtitle. Unknown (not yet observed) reads as enabled so a
            // fresh launch never shows a stale refusal; the request path
            // fails closed into the raw-transcript fallback regardless.
            if let reason = environment.appleIntelligenceAvailability?.unavailableMessage {
                return .disabled(reason: reason)
            }
            return .enabled

        case .aiPrivateCloudComputeConfiguration:
            // ADR-027: the Private Cloud Compute row. Same rule as the
            // on-device row; the edition and signature refusals arrive
            // through the same fact, so the Developer ID edition shows its
            // reason without the framework ever being asked.
            if let reason = environment.privateCloudComputeAvailability?.unavailableMessage {
                return .disabled(reason: reason)
            }
            return .enabled

        case .dictionary:
            // ADR-018: the dictionary is Whisper's conditioning prompt. A
            // resident model that reports `.unsupported` (Parakeet) cannot
            // take it; while no model is resident the estimate stands.
            if environment.residentModelAcceptsPrompt == false {
                return .disabled(reason: SettingAvailabilityReason.modelTakesNoPrompt.message)
            }
            return .enabled

        case .recorderStyleNotch:
            if let jobReason = recordingSettingRefusal(gate) { return jobReason }
            if environment.hasNotch == false {
                return .disabled(reason: SettingAvailabilityReason.noCameraHousing.message)
            }
            return .enabled

        case .middleMouseTrigger:
            // ADR-026: the trigger is an `NSEvent` global monitor, which
            // never fires for a sandboxed process.
            if !environment.edition.hasGlobalInputMonitors {
                return .disabled(reason: SettingAvailabilityReason.noGlobalInputMonitorsInAppStoreEdition.message)
            }
            return recordingSettingRefusal(gate) ?? .enabled

        case .typedInsertion:
            // ADR-026: in the App Store edition typing is the insertion path;
            // the switch would leave only the clipboard, so it is held on.
            if environment.edition.insertionStrategy == .typedOnly {
                return .disabled(reason: SettingAvailabilityReason.typingIsTheInsertionPathInAppStoreEdition.message)
            }
            return recordingSettingRefusal(gate) ?? .enabled

        case .selectionAction:
            // ADR-026: reading another app's selection is Accessibility.
            if !environment.edition.canReadSelectionInOtherApps {
                return .disabled(reason: SettingAvailabilityReason.noSelectionReadingInAppStoreEdition.message)
            }
            return .enabled

        case .selectedTextContext:
            // ADR-026 §6(b): the "selected text" AI context reads another
            // app's selection through Accessibility; in the App Store edition
            // it is always empty, so the per-action switch is held off.
            if !environment.edition.canReadSelectionInOtherApps {
                return .disabled(reason: SettingAvailabilityReason.noSelectedTextContextInAppStoreEdition.message)
            }
            return .enabled

        case .shortcut, .recordingInteraction, .triggers, .recordingFeedback,
             .insertedText, .recordingLength, .recorderStyle:
            // Every recording setting travels in the job's settings snapshot;
            // the job in flight keeps the values it started with.
            return recordingSettingRefusal(gate) ?? .enabled

        case .speechComputeUnits:
            // Changing the units reloads the model, which needs the engine
            // free and something resident to reload.
            if let held = engineHeldRefusal(gate) { return held }
            if !environment.residentModelLoaded {
                return .disabled(reason: SettingAvailabilityReason.noModelLoaded.message)
            }
            // ADR-025: a runtime that places its own models (Apple Speech)
            // has nothing for the picker to change; the setting is kept for
            // the Core ML runtimes and applied when one is resident again.
            if let runtime = environment.runtime, !runtime.hasComputeUnitChoice {
                return .disabled(reason: SettingAvailabilityReason.runtimeHasNoComputeUnitChoice.message)
            }
            return .enabled

        case .transcribeFile:
            // One model, one inference at a time (`inferenceInProgress`).
            if gate.transcribingFile {
                return .disabled(reason: SettingAvailabilityReason.fileTranscriptionRunning.message)
            }
            return engineHeldRefusal(gate) ?? .enabled

        case .unloadModel:
            // Releasing the runtime under a job, a test, a file
            // transcription, or a reload would fail that operation.
            if gate.transcribingFile {
                return .disabled(reason: SettingAvailabilityReason.fileTranscriptionRunning.message)
            }
            return engineHeldRefusal(gate) ?? .enabled
        }
    }

    /// Every key at once, for the shell to push into the pages.
    public static func table(
        settings: AppSettings,
        environment: EnvironmentProfile,
        gate: SettingsGate
    ) -> [SettingKey: SettingAvailability] {
        var table: [SettingKey: SettingAvailability] = [:]
        for key in SettingKey.allCases {
            table[key] = availability(key: key, settings: settings, environment: environment, gate: gate)
        }
        return table
    }

    // MARK: Shared rows

    private static func recordingSettingRefusal(_ gate: SettingsGate) -> SettingAvailability? {
        guard gate.dictation == .jobActive else { return nil }
        return .disabled(reason: SettingAvailabilityReason.finishDictationFirst.message)
    }

    /// The reason the engine is held, most specific first, or nil when free.
    /// One row per `ModelActivity` case, so a new activity fails to compile
    /// here until it has a reason.
    private static func engineHeldRefusal(_ gate: SettingsGate) -> SettingAvailability? {
        switch gate.model {
        case .reloadingUnits:
            return .disabled(reason: SettingAvailabilityReason.reloadingComputeUnits.message)
        case .testing:
            return .disabled(reason: SettingAvailabilityReason.performanceTestRunning.message)
        case .transcribingFile:
            return .disabled(reason: SettingAvailabilityReason.fileTranscriptionRunning.message)
        case .downloading, .installing, .loading, .unloading:
            return .disabled(reason: SettingAvailabilityReason.modelOperationInProgress.message)
        case .idle:
            break
        }
        if gate.dictation == .jobActive {
            return .disabled(reason: SettingAvailabilityReason.finishDictationFirst.message)
        }
        return nil
    }
}

/// The controls the projection has a rule for. A key names a control group
/// on a page, not a stored field: `.insertedText` covers the two inserted-
/// text toggles, `.triggers` the Cancel shortcut, auto-send and middle
/// mouse.
public enum SettingKey: String, CaseIterable, Sendable, Hashable {
    /// Shortcuts › the recording shortcut.
    case shortcut
    /// Shortcuts › trigger mode.
    case recordingInteraction
    /// Shortcuts › Cancel shortcut, auto-send, middle mouse.
    case triggers
    /// Shortcuts › the middle mouse toggle and its delay (ADR-026: not in
    /// the App Store edition).
    case middleMouseTrigger
    /// Recording › While recording (sound feedback, mute).
    case recordingFeedback
    /// Recording › Inserted text (add space, formatting, typed insertion,
    /// keep on clipboard).
    case insertedText
    /// Recording › Inserted text › "Type into apps that block direct
    /// insertion" (ADR-016; ADR-026: held on in the App Store edition).
    case typedInsertion
    /// Recording › Length.
    case recordingLength
    /// Recording › Recorder style picker as a whole.
    case recorderStyle
    /// The Notch choice of that picker.
    case recorderStyleNotch
    /// Dictionary › the term list and its edits.
    case dictionary
    /// AI Actions › what the actions do (default action, triggers, profile).
    case aiActionSettings
    /// AI Actions › Selection Action slots (ADR-026: not in the App Store
    /// edition).
    case selectionAction
    /// An action's editor › Context Awareness › "Include selected text"
    /// (ADR-026 §6(b): not in the App Store edition).
    case selectedTextContext
    /// AI Actions › Configurations › the "Apple Intelligence (on-device)"
    /// row: its subtitle and "Set as Active" (ADR-024).
    case aiAppleIntelligenceConfiguration
    /// AI Actions › Configurations › the "Apple Intelligence (Private Cloud
    /// Compute)" row: its subtitle and "Set as Active" (ADR-027).
    case aiPrivateCloudComputeConfiguration
    /// Speech Models › Runtime › compute units.
    case speechComputeUnits
    /// History › Transcribe File….
    case transcribeFile
    /// Runtime card banner and status menu › Unload Model Now.
    case unloadModel

    /// The keys ADR-022 calls "every recording setting": what a job's
    /// settings snapshot freezes for its lifetime.
    public static let recordingSettings: [SettingKey] = [
        .shortcut, .recordingInteraction, .triggers, .middleMouseTrigger, .recordingFeedback,
        .insertedText, .typedInsertion, .recordingLength, .recorderStyle, .recorderStyleNotch
    ]
}

public enum SettingAvailability: Equatable, Sendable {
    case enabled
    /// The control is shown but takes no input; `reason` is the English
    /// sentence (a `DomainCopy` key) the page shows beside it.
    case disabled(reason: String)
    /// Declared by ADR-022 for controls that should not render at all; no
    /// initial rule produces it, so a page treating it as `disabled` is
    /// correct until one does.
    case hidden

    public var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }

    public var disabledReason: String? {
        if case .disabled(let reason) = self { return reason }
        return nil
    }
}

/// The reasons the projection can give, as the English sentences the UI
/// localizes through `DomainCopy` (listed in `DomainUserFacingCopy`).
public enum SettingAvailabilityReason: String, CaseIterable, Sendable {
    case finishDictationFirst
    case aiActionsOff
    case noAIEndpoint
    case modelTakesNoPrompt
    case noCameraHousing
    case reloadingComputeUnits
    case performanceTestRunning
    case fileTranscriptionRunning
    case modelOperationInProgress
    /// 2026-09-29: a model change waits for the first Core ML build
    /// (`ModelLifecycleState.optimizing`) — `ModelOperationAdmission`.
    case modelOptimizing
    /// 2026-09-29: a model change waits for a load or verification that
    /// cannot be paused — `ModelOperationAdmission`.
    case modelLoadInProgress
    case noModelLoaded
    /// ADR-025: the resident runtime (Apple Speech) exposes no compute-unit
    /// choice; the picker shows the stored value for the Core ML runtimes.
    case runtimeHasNoComputeUnitChoice
    /// ADR-026: the App Store edition's refusals.
    case noGlobalInputMonitorsInAppStoreEdition
    case typingIsTheInsertionPathInAppStoreEdition
    case noSelectionReadingInAppStoreEdition
    case noSelectedTextContextInAppStoreEdition

    public var message: String {
        switch self {
        case .finishDictationFirst:
            return "Finish the current dictation first."
        case .aiActionsOff:
            return "AI Actions is off, so this has no effect until you turn it on."
        case .noAIEndpoint:
            return "Add an AI configuration before choosing what AI Actions do."
        case .modelTakesNoPrompt:
            return "The current speech model does not take a dictionary. The list is kept for a model that does."
        case .noCameraHousing:
            return "The Notch style needs a display with a camera housing."
        case .reloadingComputeUnits:
            return "Reloading the model with the new compute units…"
        case .performanceTestRunning:
            return "Performance test running…"
        case .fileTranscriptionRunning:
            return "A file is being transcribed."
        case .modelOperationInProgress:
            return "A model operation is in progress."
        case .modelOptimizing:
            return "The speech model is being optimized for this Mac (first time only). Model changes are available when it finishes."
        case .modelLoadInProgress:
            return "The speech model is loading. Model changes are available when it finishes."
        case .noModelLoaded:
            return "No model is loaded."
        case .runtimeHasNoComputeUnitChoice:
            return "Apple Speech places its own model; this choice applies to the Core ML runtimes only."
        case .noGlobalInputMonitorsInAppStoreEdition:
            return "The App Store edition cannot watch the mouse, a single modifier key or Escape while another app is in front. Use key combinations, including a Cancel shortcut."
        case .typingIsTheInsertionPathInAppStoreEdition:
            return "In the App Store edition KVoice always types the text into the app you dictate into; it cannot write to other apps' text fields directly."
        case .noSelectionReadingInAppStoreEdition:
            return "The App Store edition cannot read text selected in other apps, so Selection Actions are not available."
        case .noSelectedTextContextInAppStoreEdition:
            return "The App Store edition cannot read text selected in other apps, so no selected text is sent."
        }
    }
}
