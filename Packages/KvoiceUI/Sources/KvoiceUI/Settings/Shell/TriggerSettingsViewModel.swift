import Foundation
import KvoiceAppCore
import KvoiceDomain
import Observation
import SwiftUI

/// Main-actor state behind `TriggerOptionBindings` and
/// `RecordingOptionBindings` (product decisions #5 and #10).
///
/// ADR-022 slice 7: a projection over `SettingsProjectionHost`. `snapshot`
/// is `TriggerSettingsSnapshot(settings: host.settings)` read live, the
/// bindings it hands out read that and write one `.setTriggers` intent
/// with the edited snapshot (origin `.page(.shortcuts)` for the trigger
/// controls, `.page(.recording)` for the recording options), and a refusal
/// leaves the stored value — so the control — where it was, with
/// `refusalNote` for the footer. Recording a Cancel shortcut goes through
/// the `recordCancelShortcut` hook the shell installs (the recorder window
/// lives in the hotkeys package); the recorded value comes back through
/// `setCancelShortcut`, and a registration failure through
/// `cancelShortcutError` — the two error strings are the shell's feedback,
/// not settings, and stay here.
@Observable
@MainActor
public final class TriggerSettingsViewModel {
    /// The coordinator projection and the intent door.
    public let host: SettingsProjectionHost
    /// Registration feedback for the secondary shortcuts and the mouse
    /// trigger (a conflict, or Accessibility missing). Set by the shell.
    public var cancelShortcutError: String?
    public var middleMouseError: String?

    /// Installed by the shell: present the recorder for the role.
    @ObservationIgnored public var recordCancelShortcut: @MainActor () -> Void = {}
    /// Installed by the shell (`AppDelegate.installTriggers`): play the
    /// start cue of a cue set through the KvoiceAudio player, for the
    /// Recording page's Preview button. The default plays nothing, and the
    /// bindings then hand the page no preview so the button is disabled.
    @ObservationIgnored public var previewCue: (@MainActor (RecordingFeedbackCueSet) -> Void)?

    public init(host: SettingsProjectionHost = .detached()) {
        self.host = host
    }

    /// The stored recording settings, as one value.
    public var snapshot: TriggerSettingsSnapshot {
        TriggerSettingsSnapshot(settings: host.settings)
    }

    /// The last refusal's sentence, for the page footer; nil otherwise.
    public var refusalNote: String? { host.refusalNote }

    // MARK: Secondary shortcuts

    public func setCancelShortcut(_ shortcut: ShortcutDefinition?) {
        guard shortcut == nil || shortcut?.isStructurallyValid == true else { return }
        cancelShortcutError = nil
        update(origin: .page(.shortcuts)) { $0.triggers.cancelShortcut = shortcut }
    }

    // MARK: Bindings for the section views

    public var triggerOptionBindings: TriggerOptionBindings {
        TriggerOptionBindings(
            cancelShortcut: AuxiliaryShortcutBinding(
                shortcut: snapshot.triggers.cancelShortcut,
                error: cancelShortcutError,
                record: { [weak self] in self?.recordCancelShortcut() },
                clear: { [weak self] in self?.setCancelShortcut(nil) }
            ),
            autoSend: binding(\.triggers.autoSendEnabled, origin: .page(.shortcuts)),
            middleMouseToggle: binding(\.triggers.middleMouseToggleEnabled, origin: .page(.shortcuts)),
            middleMouseActivationDelayMilliseconds: Binding(
                get: { [weak self] in self?.snapshot.triggers.middleMouseActivationDelayMilliseconds ?? TriggerSettings.defaultMiddleMouseActivationDelayMilliseconds },
                set: { [weak self] value in
                    self?.update(origin: .page(.shortcuts)) { snapshot in
                        // Re-init clamps to the supported range.
                        snapshot.triggers = TriggerSettings(
                            cancelShortcut: snapshot.triggers.cancelShortcut,
                            autoSendEnabled: snapshot.triggers.autoSendEnabled,
                            middleMouseToggleEnabled: snapshot.triggers.middleMouseToggleEnabled,
                            middleMouseActivationDelayMilliseconds: value
                        )
                    }
                }
            ),
            refusalNote: { [weak self] in self?.refusalNote }
        )
    }

    public var recordingOptionBindings: RecordingOptionBindings {
        RecordingOptionBindings(
            soundFeedback: binding(\.recordingFeedback.soundFeedbackEnabled),
            cueSet: Binding(
                get: { [weak self] in self?.snapshot.recordingFeedback.cueSet ?? .kvoice },
                set: { [weak self] set in self?.update(origin: .page(.recording)) { $0.recordingFeedback.cueSet = set } }
            ),
            previewCue: previewCue,
            muteSystemAudio: binding(\.recordingFeedback.muteSystemAudioDuringRecording),
            preserveClipboard: binding(\.recordingFeedback.preserveTranscriptInClipboard),
            addSpaceAfterInsertion: binding(\.addSpaceAfterInsertion),
            automaticTextFormatting: binding(\.automaticTextFormatting),
            recorderStyle: Binding(
                get: { [weak self] in self?.snapshot.recorderStyle ?? .mini },
                set: { [weak self] style in self?.update(origin: .page(.recording)) { $0.recorderStyle = style } }
            ),
            maxRecordingSeconds: Binding(
                get: { [weak self] in
                    guard let self else { return RecordingDurationLimit.default.seconds }
                    let limit = RecordingDurationLimit(seconds: self.snapshot.maxRecordingSeconds)
                    // The picker's "No limit" is nil; the stored value is the
                    // technical ceiling.
                    return limit.isUnlimited ? nil : limit.seconds
                },
                set: { [weak self] seconds in
                    let limit = seconds.map(RecordingDurationLimit.init(seconds:)) ?? .noLimit
                    self?.update(origin: .page(.recording)) { $0.maxRecordingSeconds = limit.seconds }
                }
            ),
            refusalNote: { [weak self] in self?.refusalNote }
        )
    }

    /// The picker's view of the stored limit.
    public var recordingDurationLimit: RecordingDurationLimit {
        RecordingDurationLimit(seconds: snapshot.maxRecordingSeconds)
    }

    private func binding(
        _ keyPath: WritableKeyPath<TriggerSettingsSnapshot, Bool>,
        origin: SettingsOrigin = .page(.recording)
    ) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.snapshot[keyPath: keyPath] ?? false },
            set: { [weak self] value in self?.update(origin: origin) { $0[keyPath: keyPath] = value } }
        )
    }

    /// One edit → one intent with the whole snapshot (the reducer's row is
    /// per block, and a job snapshot freezes the block as one). Unchanged
    /// edits send nothing; a refusal is recorded by the host and the
    /// binding's next `get` already reads the stored value.
    private func update(origin: SettingsOrigin, _ change: (inout TriggerSettingsSnapshot) -> Void) {
        var next = snapshot
        change(&next)
        guard next != snapshot else { return }
        host.send(.setTriggers(next, origin: origin))
    }
}
