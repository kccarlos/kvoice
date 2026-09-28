import SwiftUI
import KvoiceAppCore
import KvoiceDomain

/// The recording options (`AppSettings.recordingFeedback`, the duration
/// limit, and the two inserted-text options). Each is an optional binding:
/// nil renders the control disabled with a note, so the section renders
/// before the app shell binds the real values
/// (`SettingsSurface.recordingOptionBindings`); the view needs no change.
public struct RecordingOptionBindings {
    public var soundFeedback: Binding<Bool>?
    /// `RecordingFeedbackSettings.cueSet` (2026-09-16): kvoice's tones, the
    /// classic alert-sound mapping, or one alert sound for every cue.
    public var cueSet: Binding<RecordingFeedbackCueSet>?
    /// Plays the start cue of the given set, committed or not, so the user
    /// can hear a choice before picking it. Installed by the shell on the
    /// KvoiceAudio player; nil renders the Preview button disabled.
    public var previewCue: (@MainActor (RecordingFeedbackCueSet) -> Void)?
    public var muteSystemAudio: Binding<Bool>?
    public var preserveClipboard: Binding<Bool>?
    /// `AppSettings.addSpaceAfterInsertion`: a trailing space on the
    /// inserted text so the next dictation continues the sentence.
    public var addSpaceAfterInsertion: Binding<Bool>?
    /// `AppSettings.automaticTextFormatting`: whitespace normalisation of
    /// the inserted text (see KNOWN_ISSUES "Accepted deviations").
    public var automaticTextFormatting: Binding<Bool>?
    /// `AppSettings.recorderStyle` (ADR-021): the floating pill or the
    /// shape under the camera housing.
    public var recorderStyle: Binding<HUDStyle>?
    /// Seconds; nil for no limit (the shell maps it to
    /// `RecordingDurationLimit.noLimit`). The choices are product decision #10.
    public var maxRecordingSeconds: Binding<Int?>?
    /// ADR-022 slice 7: the last refusal's sentence from the trigger model's
    /// projection host, read live; nil when the last edit was accepted.
    public var refusalNote: (@MainActor () -> String?)?

    public init(
        soundFeedback: Binding<Bool>? = nil,
        cueSet: Binding<RecordingFeedbackCueSet>? = nil,
        previewCue: (@MainActor (RecordingFeedbackCueSet) -> Void)? = nil,
        muteSystemAudio: Binding<Bool>? = nil,
        preserveClipboard: Binding<Bool>? = nil,
        addSpaceAfterInsertion: Binding<Bool>? = nil,
        automaticTextFormatting: Binding<Bool>? = nil,
        recorderStyle: Binding<HUDStyle>? = nil,
        maxRecordingSeconds: Binding<Int?>? = nil,
        refusalNote: (@MainActor () -> String?)? = nil
    ) {
        self.soundFeedback = soundFeedback
        self.cueSet = cueSet
        self.previewCue = previewCue
        self.muteSystemAudio = muteSystemAudio
        self.preserveClipboard = preserveClipboard
        self.addSpaceAfterInsertion = addSpaceAfterInsertion
        self.automaticTextFormatting = automaticTextFormatting
        self.recorderStyle = recorderStyle
        self.maxRecordingSeconds = maxRecordingSeconds
        self.refusalNote = refusalNote
    }

    /// Product decision #10: 10 minutes (default), 30 minutes, 1 hour, no limit.
    public static let maxDurationChoices: [(seconds: Int?, title: String)] = [
        (600, "10 minutes"),
        (1_800, "30 minutes"),
        (3_600, "1 hour"),
        (nil, "No limit")
    ]
}

/// The Recording section: feedback while recording, the inserted-text
/// options (including the typed-insertion tier), and the duration limit —
/// one grouped form, most-used first.
@MainActor
public struct RecordingSectionView: View {
    @Bindable private var general: GeneralSettingsViewModel
    private let options: RecordingOptionBindings
    /// ADR-022 item 3: every control here is a recording setting, disabled
    /// with a footnote while a job holds its settings snapshot.
    private let availability: SettingsAvailabilityModel
    /// The Audio Input model, for the Bluetooth start-latency note
    /// (2026-09-16); nil (previews, tests) shows no note.
    private let inputSelection: AudioInputViewModel?

    public init(
        general: GeneralSettingsViewModel = .init(),
        options: RecordingOptionBindings = .init(),
        availability: SettingsAvailabilityModel = .init(),
        inputSelection: AudioInputViewModel? = nil
    ) {
        self.general = general
        self.options = options
        self.availability = availability
        self.inputSelection = inputSelection
    }

    public var body: some View {
        Form {
            feedbackSection
            recorderSection
            insertedTextSection
            durationSection
        }
        .formStyle(.grouped)
    }

    // MARK: Recorder

    /// ADR-021. The picker is idle-gated by the reducer like every other
    /// control here (and disabled through the availability projection while
    /// a job runs); the preview beside it is a static sketch of the two
    /// shapes, not the live HUD.
    private var recorderSection: some View {
        Section {
            Picker("Recorder style", selection: recorderStyleSelection) {
                Text("Mini").tag(HUDStyle.mini)
                Text("Notch").tag(HUDStyle.notch)
            }
            .pickerStyle(.segmented)
            .disabled(options.recorderStyle == nil || !availability.isEnabled(.recorderStyle))
            .accessibilityLabel("Recorder style")
            .accessibilityHint(options.recorderStyle == nil
                ? "Not adjustable in this build."
                : "Mini floats near the bottom of the screen; Notch hangs from the menu bar under the camera housing.")
            RecorderStylePreview(style: recorderStyleSelection.wrappedValue)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            SettingsResetRow(.recorderStyle, host: general.host, origin: .page(.recording))
        } header: {
            Text("Recorder")
        } footer: {
            SettingsFooter(note: options.refusalNote?()) {
                Text(availability.footnote(
                    .recorderStyle,
                    base: String(localized: "Both styles show the level, the time, and the AI controls; Notch hangs under the camera housing.", bundle: .module)
                ))
            }
        }
    }

    // MARK: While recording

    private var feedbackSection: some View {
        Section {
            placeholderToggle(
                "Sound feedback",
                binding: options.soundFeedback,
                hint: "Plays a short sound when recording starts, stops, is cancelled, and when the text is inserted. The start sound plays once the microphone is actually delivering audio."
            )
            HStack {
                Picker("Sound", selection: cueSetSelection) {
                    Text("KVoice tones").tag(RecordingFeedbackCueSet.kvoice)
                    Text("Classic system sounds").tag(RecordingFeedbackCueSet.systemClassic)
                    Divider()
                    ForEach(RecordingFeedbackCueSet.systemSoundNames, id: \.self) { name in
                        Text(verbatim: name).tag(RecordingFeedbackCueSet.system(name: name))
                    }
                }
                .disabled(options.cueSet == nil || soundFeedbackIsOff)
                .accessibilityLabel("Sound")
                .accessibilityHint(options.cueSet == nil
                    ? "Not adjustable in this build."
                    : "KVoice tones are four short notes played at media volume. Classic uses the Tink, Pop, Funk and Purr alert sounds; a named sound is used for every cue.")
                Button("Preview") {
                    options.previewCue?(cueSetSelection.wrappedValue)
                }
                .disabled(options.previewCue == nil || options.cueSet == nil)
                .accessibilityHint("Plays the start sound of the selected set.")
            }
            // On one row, not the Section (a Section modifier applies to
            // every row): re-read the devices so the note tracks the
            // current input.
            .task { inputSelection?.refresh() }
            if let note = inputSelection?.bluetoothInputNote {
                BluetoothInputNote(text: note)
            }
            placeholderToggle(
                "Mute system audio while recording",
                binding: options.muteSystemAudio,
                hint: "Turns the output volume down to zero while you dictate and restores it afterwards. Playback is not paused."
            )
            // The feedback block is one row of the resolver (sound, cue
            // set, mute, and keep-on-clipboard from the section below).
            SettingsResetRow(.recordingFeedback, host: general.host, origin: .page(.recording))
        } header: {
            Text("While Recording")
        } footer: {
            SettingsFooter(note: options.refusalNote?()) {
                Text(availability.footnote(
                    .recordingFeedback,
                    base: pendingNote(String(localized: "What you hear while dictating. Mute restores the volume on every exit.", bundle: .module))
                ))
            }
        }
        .disabled(!availability.isEnabled(.recordingFeedback))
    }

    private var soundFeedbackIsOff: Bool {
        options.soundFeedback.map { !$0.wrappedValue } ?? false
    }

    private var cueSetSelection: Binding<RecordingFeedbackCueSet> {
        options.cueSet ?? .constant(.kvoice)
    }

    // MARK: Inserted text

    private var insertedTextSection: some View {
        Section {
            placeholderToggle(
                "Add space after inserting",
                binding: options.addSpaceAfterInsertion,
                hint: "Appends one space to the inserted text so the next dictation continues the sentence. History keeps the text without it."
            )
            .controlSize(.mini)
            placeholderToggle(
                "Automatic text formatting",
                binding: options.automaticTextFormatting,
                hint: "Trims the ends and collapses runs of spaces in the inserted text. It never changes case or punctuation."
            )
            .controlSize(.mini)
            Toggle(
                "Type into apps that block direct insertion (terminals)",
                // ADR-026: the App Store edition always types, whatever the
                // stored value (a backup from the other edition may say off).
                isOn: availability.edition == .appStore ? .constant(true) : $general.typedInsertionEnabled
            )
                .controlSize(.mini)
                // ADR-026: held on in the App Store edition (typing is how
                // text is inserted there); the reason is in the footer.
                .disabled(!availability.isEnabled(.typedInsertion))
                .accessibilityLabel("Type into apps that block direct insertion")
                .accessibilityHint("When an app's text field cannot be written through Accessibility, KVoice types the text as keystrokes instead of copying it to the clipboard.")
            placeholderToggle(
                "Keep the transcript on the clipboard after inserting",
                binding: options.preserveClipboard,
                hint: "Also copies the inserted text to the clipboard. Off, a successful insertion never touches the clipboard."
            )
            .controlSize(.mini)
            SettingsResetRow(
                [.addSpaceAfterInsertion, .automaticTextFormatting, .typedInsertionEnabled],
                host: general.host,
                origin: .page(.recording)
            )
        } header: {
            Text("Inserted Text")
        } footer: {
            SettingsFooter(note: options.refusalNote?() ?? general.refusalNote) {
                Text(availability.footnote(
                    .insertedText,
                    base: pendingNote(insertedTextFooter)
                ))
            }
        }
        .disabled(!availability.isEnabled(.insertedText))
    }

    /// ADR-026: the App Store edition types; the footer says so instead of
    /// describing Accessibility insertion it does not have.
    private var insertedTextFooter: String {
        let base = String(localized: "How the finished text reaches the app. Accessibility insertion is always tried first.", bundle: .module)
        guard availability.edition == .appStore,
              let reason = availability.disabledReason(.typedInsertion) else { return base }
        return reason
    }

    // MARK: Duration

    private var durationSection: some View {
        Section {
            Picker("Maximum recording length", selection: maxDurationSelection) {
                ForEach(RecordingOptionBindings.maxDurationChoices, id: \.title) { choice in
                    Text(domain: choice.title).tag(choice.seconds)
                }
            }
            .disabled(options.maxRecordingSeconds == nil || !availability.isEnabled(.recordingLength))
            .accessibilityLabel("Maximum recording length")
            .accessibilityHint(options.maxRecordingSeconds == nil
                ? "Not adjustable in this build. Recording stops after 10 minutes."
                : "Recording stops on its own at this length.")
            SettingsResetRow(.maxRecordingSeconds, host: general.host, origin: .page(.recording))
        } header: {
            Text("Length")
        } footer: {
            SettingsFooter(note: options.refusalNote?()) {
                Text(availability.footnote(
                    .recordingLength,
                    base: String(localized: "Recording stops on its own at this length; the transcript is still inserted.", bundle: .module)
                ))
            }
        }
    }

    // MARK: Helpers

    private var hasUnboundOptions: Bool {
        options.soundFeedback == nil
            || options.cueSet == nil
            || options.muteSystemAudio == nil
            || options.preserveClipboard == nil
            || options.addSpaceAfterInsertion == nil
            || options.automaticTextFormatting == nil
            || options.maxRecordingSeconds == nil
    }

    /// Appends the "dimmed options" note while the shell has not bound the
    /// controls, so a preview or test build says why they are disabled.
    private func pendingNote(_ base: String) -> String {
        hasUnboundOptions ? base + " " + String(localized: "Dimmed options are not adjustable in this build yet.", bundle: .module) : base
    }

    private func placeholderToggle(_ title: LocalizedStringKey, binding: Binding<Bool>?, hint: LocalizedStringKey) -> some View {
        Toggle(title, isOn: binding ?? .constant(false))
            .disabled(binding == nil)
            .accessibilityLabel(title)
            .accessibilityHint(binding == nil ? "Not adjustable in this build." : hint)
    }

    private var maxDurationSelection: Binding<Int?> {
        options.maxRecordingSeconds ?? .constant(600)
    }

    private var recorderStyleSelection: Binding<HUDStyle> {
        options.recorderStyle ?? .constant(.mini)
    }
}

/// A static sketch of the two recorder styles for the Recording section: a
/// screen outline with the menu bar, the housing, and the panel where the
/// chosen style puts it. Shapes only, no live state — the real HUD is a
/// separate non-activating panel and cannot be embedded in a form.
struct RecorderStylePreview: View {
    let style: HUDStyle

    var body: some View {
        HStack(spacing: 16) {
            sketch(.mini)
            sketch(.notch)
        }
        .padding(.vertical, 4)
    }

    private func sketch(_ sketched: HUDStyle) -> some View {
        let selected = sketched == style
        return VStack(spacing: 6) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 160, height: 100)
                // Menu bar with the camera housing.
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 160, height: 10)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6, style: .continuous))
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.black.opacity(0.75))
                    .frame(width: 34, height: 8)
                    .offset(y: 1)
                // The panel.
                Group {
                    if sketched == .notch {
                        UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.85))
                            .frame(width: 72, height: 16)
                            .offset(y: 10)
                    } else {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.regularMaterial)
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                            .frame(width: 72, height: 18)
                            .offset(y: 66)
                    }
                }
            }
            .frame(width: 160, height: 100)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1)
            }
            Text(sketched == .mini ? "Mini" : "Notch")
                .font(.caption)
                .foregroundStyle(selected ? .primary : .secondary)
        }
    }
}
