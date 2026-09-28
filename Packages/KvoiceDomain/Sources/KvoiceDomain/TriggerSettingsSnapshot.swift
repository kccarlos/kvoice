import Foundation

/// The settings blocks the Shortcuts and Recording sections edit
/// beside the General model: `AppSettings.triggers`, `.recordingFeedback`,
/// the duration limit (`maxRecordingSeconds`), the two inserted-text
/// options (`addSpaceAfterInsertion`, `automaticTextFormatting`), which
/// moved here from the Manage Models panel on 2026-09-13 because they shape
/// the inserted text, not the model, and the recorder style (ADR-021).
/// Travelling in this snapshot puts every one of them behind the shell's
/// idle gate: a job in flight keeps the values it started with. Lives in
/// KvoiceDomain (moved from KvoiceUI, ADR-022 slice 3) because
/// `SettingsIntent.setTriggers` carries it and KvoiceAppCore cannot see
/// KvoiceUI.
public struct TriggerSettingsSnapshot: Equatable, Sendable {
    public var triggers: TriggerSettings
    public var recordingFeedback: RecordingFeedbackSettings
    public var maxRecordingSeconds: Int
    public var addSpaceAfterInsertion: Bool
    public var automaticTextFormatting: Bool
    public var recorderStyle: HUDStyle

    public init(
        triggers: TriggerSettings = .init(),
        recordingFeedback: RecordingFeedbackSettings = .init(),
        maxRecordingSeconds: Int = RecordingDurationLimit.default.seconds,
        addSpaceAfterInsertion: Bool = false,
        automaticTextFormatting: Bool = false,
        recorderStyle: HUDStyle = .mini
    ) {
        self.triggers = triggers
        self.recordingFeedback = recordingFeedback
        self.maxRecordingSeconds = maxRecordingSeconds
        self.addSpaceAfterInsertion = addSpaceAfterInsertion
        self.automaticTextFormatting = automaticTextFormatting
        self.recorderStyle = recorderStyle
    }

    public init(settings: AppSettings) {
        self.init(
            triggers: settings.triggers,
            recordingFeedback: settings.recordingFeedback,
            maxRecordingSeconds: settings.maxRecordingSeconds,
            addSpaceAfterInsertion: settings.addSpaceAfterInsertion,
            automaticTextFormatting: settings.automaticTextFormatting,
            recorderStyle: settings.recorderStyle
        )
    }

    /// Writes the blocks back into a settings value.
    public func apply(to settings: inout AppSettings) {
        settings.triggers = triggers
        settings.recordingFeedback = recordingFeedback
        settings.maxRecordingSeconds = maxRecordingSeconds
        settings.addSpaceAfterInsertion = addSpaceAfterInsertion
        settings.automaticTextFormatting = automaticTextFormatting
        settings.recorderStyle = recorderStyle
    }
}
