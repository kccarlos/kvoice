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
        KVCardPage {
            feedbackSection
            recorderSection
            insertedTextSection
            durationSection
        }
    }

    // MARK: Recorder

    /// ADR-021. The picker is idle-gated by the reducer like every other
    /// control here (and disabled through the availability projection while
    /// a job runs); the preview beside it is a static sketch of the two
    /// shapes, not the live HUD.
    private var recorderSection: some View {
        // UI v2 fidelity F3 (Window.dc `isRecorder`): two pressable cards
        // drawing each recorder, not a segmented control over a sketch.
        let enabled = options.recorderStyle != nil && availability.isEnabled(.recorderStyle)
        return VStack(alignment: .leading, spacing: 6) {
            KVHeaderRow("Recorder") {
                SettingsResetRow(.recorderStyle, host: general.host, origin: .page(.recording))
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 2)
            HStack(spacing: 10) {
                RecorderStyleCard(style: .mini, selection: recorderStyleSelection)
                RecorderStyleCard(style: .notch, selection: recorderStyleSelection)
            }
            .disabled(!enabled)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Recorder style", bundle: .module))
            .accessibilityHint(options.recorderStyle == nil
                ? Text("Not adjustable in this build.", bundle: .module)
                : Text("Mini floats near the bottom of the screen; Notch hangs from the menu bar under the camera housing.", bundle: .module))
            let note = availability.isEnabled(.recorderStyle) ? options.refusalNote?() : availability.footnote(.recorderStyle, base: "")
            if let note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kv.text2)
                    .padding(.horizontal, 2)
            }
        }
    }

    private var feedbackSection: some View {
        KVCardSection {
            placeholderToggle(
                "Sound feedback",
                binding: options.soundFeedback,
                hint: "Plays a short sound when recording starts, stops, is cancelled, and when the text is inserted. The start sound plays once the microphone is actually delivering audio."
            )
            LabeledContent {
              HStack(spacing: 6) {
                KVSelect("Sound", selection: cueSetSelection, current: Self.cueSetTitle(cueSetSelection.wrappedValue)) {
                    Text("KVoice tones", bundle: .module).tag(RecordingFeedbackCueSet.kvoice)
                    Text("Classic system sounds", bundle: .module).tag(RecordingFeedbackCueSet.systemClassic)
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
            } label: {
                Text("Sound", bundle: .module)
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
        } header: {
            KVHeaderRow("While Recording") {
                SettingsResetRow(.recordingFeedback, host: general.host, origin: .page(.recording))
            }
        } footer: {
            SettingsFooter(note: options.refusalNote?()) {
                Text(availability.footnote(
                    .recordingFeedback,
                    base: pendingNote(String(localized: "Mute restores the volume on every exit.", bundle: .module))
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
        KVCardSection {
            // The job refusal applies to the rows, not the Section: the
            // footer's full-edition link (ADR-026) must never be dead.
            Group {
            placeholderToggle(
                "Add space after inserting",
                binding: options.addSpaceAfterInsertion,
                hint: "Appends one space to the inserted text so the next dictation continues the sentence. History keeps the text without it."
            )
            placeholderToggle(
                "Automatic text formatting",
                binding: options.automaticTextFormatting,
                hint: "Trims the ends and collapses runs of spaces in the inserted text. It never changes case or punctuation."
            )
            // ADR-026: the App Store edition always types, whatever the
            // stored value (a backup from the other edition may say off).
            Toggle(isOn: availability.edition == .appStore ? .constant(true) : $general.typedInsertionEnabled) {
                Text("Type into apps that block direct insertion", bundle: .module)
                Text(availability.edition == .appStore ? "Always on in this edition" : "Terminals and some web apps", bundle: .module)
            }
                    // ADR-026: held on in the App Store edition (typing is how
                // text is inserted there); the reason is in the footer.
                .disabled(!availability.isEnabled(.typedInsertion))
                .accessibilityLabel("Type into apps that block direct insertion")
                .accessibilityHint("When an app's text field cannot be written through Accessibility, KVoice types the text as keystrokes instead of copying it to the clipboard.")
            placeholderToggle(
                "Keep the transcript on the clipboard",
                binding: options.preserveClipboard,
                hint: "Also copies the inserted text to the clipboard. Off, a successful insertion never touches the clipboard."
            )
            }
            .disabled(!availability.isEnabled(.insertedText))
        } header: {
            KVHeaderRow("Inserted Text") {
                SettingsResetRow(
                    [.addSpaceAfterInsertion, .automaticTextFormatting, .typedInsertionEnabled],
                    host: general.host,
                    origin: .page(.recording)
                )
            }
        } footer: {
            SettingsFooter(note: options.refusalNote?() ?? general.refusalNote) {
                Text(availability.footnote(
                    .insertedText,
                    base: pendingNote(insertedTextFooter)
                ))
                // ADR-026: nil (nothing drawn) outside the App Store edition.
                FullEditionLink(url: availability.fullEditionLink)
            }
        }
    }

    /// ADR-026: the App Store edition types; the footer says so instead of
    /// describing Accessibility insertion it does not have.
    private var insertedTextFooter: String {
        let base = String(localized: "Accessibility insertion is always tried first.", bundle: .module)
        guard availability.edition == .appStore,
              let reason = availability.disabledReason(.typedInsertion) else { return base }
        return reason
    }

    // MARK: Duration

    private var durationSection: some View {
        KVCardSection {
            LabeledContent {
                KVSelect("Maximum recording length", selection: maxDurationSelection, current: Self.maxDurationTitle(maxDurationSelection.wrappedValue)) {
                    ForEach(RecordingOptionBindings.maxDurationChoices, id: \.title) { choice in
                        Text(domain: choice.title).tag(choice.seconds)
                    }
                }
            } label: {
                Text("Maximum recording length", bundle: .module)
            }
            .disabled(options.maxRecordingSeconds == nil || !availability.isEnabled(.recordingLength))
            .accessibilityLabel("Maximum recording length")
            .accessibilityHint(options.maxRecordingSeconds == nil
                ? "Not adjustable in this build. Recording stops after 10 minutes."
                : "Recording stops on its own at this length.")
        } header: {
            KVHeaderRow("Length") {
                SettingsResetRow(.maxRecordingSeconds, host: general.host, origin: .page(.recording))
            }
        } footer: {
            SettingsFooter(note: options.refusalNote?()) {
                Text(availability.footnote(
                    .recordingLength,
                    base: String(localized: "Recording stops on its own; the transcript is still inserted.", bundle: .module)
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

    static func cueSetTitle(_ set: RecordingFeedbackCueSet) -> String {
        switch set {
        case .kvoice: String(localized: "KVoice tones", bundle: .module)
        case .systemClassic: String(localized: "Classic system sounds", bundle: .module)
        case .system(let name): name
        }
    }

    static func maxDurationTitle(_ seconds: Int?) -> String {
        let title = RecordingOptionBindings.maxDurationChoices.first { $0.seconds == seconds }?.title ?? "10 minutes"
        return DomainCopy.localized(title)
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
/// One recorder choice (Window.dc `isRecorder`): a pressable card with a
/// 76 pt `wash` stage drawing that recorder, and its name with a one-line
/// description. Selected: 2 pt `cursor` border.
struct RecorderStyleCard: View {
    let style: HUDStyle
    @Binding var selection: HUDStyle
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let selected = selection == style
        Button {
            withAnimation(KVControlMotion.stateChange(reduceMotion: reduceMotion)) { selection = style }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                stage
                (Text(style == .mini ? "Mini" : "Notch", bundle: .module).font(.system(size: 13, weight: .semibold))
                    + Text(verbatim: " · ").font(.system(size: 12)).foregroundColor(Color.kv.text2)
                    + Text(style == .mini ? "floats where you’re looking" : "grows from the camera", bundle: .module)
                        .font(.system(size: 12)).foregroundColor(Color.kv.text2))
                    .foregroundStyle(Color.kv.text)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.kv.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.kv.cursor : Color.kv.line, lineWidth: selected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(style == .mini ? "Mini" : "Notch", bundle: .module))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(Text(verbatim: KVAccessibility.selectionValue(selected)))
    }

    private var stage: some View {
        ZStack(alignment: style == .notch ? .top : .center) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.kv.wash)
            if style == .mini {
                HStack(spacing: 8) {
                    Circle().fill(Color.kv.voice).frame(width: 18, height: 18)
                    Text("Recording", bundle: .module).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.kv.text)
                    Text(verbatim: "0:07").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.kv.text2)
                }
                .padding(.leading, 6).padding(.trailing, 12)
                .frame(height: 30)
                .background(Color.kv.surface, in: Capsule(style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 4)
            } else {
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1, green: 0x7A / 255, blue: 0x2F / 255)).frame(width: 14, height: 14)
                    Text("Recording", bundle: .module).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    Text(verbatim: "0:07").font(.system(size: 10)).foregroundStyle(Color(white: 0xA3 / 255))
                }
                .padding(.leading, 6).padding(.trailing, 12)
                .frame(height: 26)
                .background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous))
            }
        }
        .frame(height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }
}
