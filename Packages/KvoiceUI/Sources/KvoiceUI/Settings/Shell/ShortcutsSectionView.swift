import SwiftUI
import KvoiceAppCore
import KvoiceDomain

/// One secondary shortcut (Cancel) as the section sees it: the
/// current value plus the record and clear routes. Recording goes through the
/// hotkey adapter's recorder window, so the view never sees a vendor type.
public struct AuxiliaryShortcutBinding {
    public var shortcut: ShortcutDefinition?
    /// Registration feedback for the last attempt (a conflict, say).
    public var error: String?
    public var record: @MainActor () -> Void
    public var clear: @MainActor () -> Void

    public init(
        shortcut: ShortcutDefinition? = nil,
        error: String? = nil,
        record: @escaping @MainActor () -> Void = {},
        clear: @escaping @MainActor () -> Void = {}
    ) {
        self.shortcut = shortcut
        self.error = error
        self.record = record
        self.clear = clear
    }
}

/// The advanced trigger controls (product decision #5). Each is optional so the
/// section renders — disabled, with a note — before the app shell binds the
/// real values; the shell fills them in `SettingsSurface.triggerOptionBindings`.
public struct TriggerOptionBindings {
    public var cancelShortcut: AuxiliaryShortcutBinding?
    public var autoSend: Binding<Bool>?
    public var middleMouseToggle: Binding<Bool>?
    /// Milliseconds within `TriggerSettings.middleMouseActivationDelayRange`.
    public var middleMouseActivationDelayMilliseconds: Binding<Int>?
    /// ADR-022 slice 7: the last refusal's sentence from the trigger model's
    /// projection host, read live (a closure, so the section re-renders on
    /// it); nil when the last edit was accepted.
    public var refusalNote: (@MainActor () -> String?)?

    public init(
        cancelShortcut: AuxiliaryShortcutBinding? = nil,
        autoSend: Binding<Bool>? = nil,
        middleMouseToggle: Binding<Bool>? = nil,
        middleMouseActivationDelayMilliseconds: Binding<Int>? = nil,
        refusalNote: (@MainActor () -> String?)? = nil
    ) {
        self.cancelShortcut = cancelShortcut
        self.autoSend = autoSend
        self.middleMouseToggle = middleMouseToggle
        self.middleMouseActivationDelayMilliseconds = middleMouseActivationDelayMilliseconds
        self.refusalNote = refusalNote
    }

    var isBound: Bool {
        cancelShortcut != nil || autoSend != nil || middleMouseToggle != nil
    }
}

/// The Shortcuts section: the recording shortcut and trigger mode
/// (Push-to-Talk / Toggle / Hybrid), then the secondary triggers — the
/// Cancel shortcut, double-press auto-send, and the middle mouse button —
/// as one grouped form.
@MainActor
public struct ShortcutsSectionView: View {
    @Bindable private var general: GeneralSettingsViewModel
    private let onChooseShortcut: @MainActor () -> Void
    private let triggers: TriggerOptionBindings
    /// ADR-022 item 3: every control here is a recording setting, disabled
    /// with a footnote while a job holds its settings snapshot.
    private let availability: SettingsAvailabilityModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        general: GeneralSettingsViewModel = .init(),
        onChooseShortcut: @escaping @MainActor () -> Void = {},
        triggers: TriggerOptionBindings = .init(),
        availability: SettingsAvailabilityModel = .init()
    ) {
        self.general = general
        self.onChooseShortcut = onChooseShortcut
        self.triggers = triggers
        self.availability = availability
    }

    public var body: some View {
        Form {
            recordingShortcutSection
            secondaryTriggersSection
        }
        .formStyle(.grouped)
    }

    // MARK: Recording shortcut

    private var recordingShortcutSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                SettingsFactRow("Recording shortcut", general.shortcutDescription, systemImage: "keyboard")

                // Two buttons side by side when there is room, stacked when
                // the pane is narrow.
                ViewThatFits(in: .horizontal) {
                    HStack { shortcutButtons }
                    VStack(alignment: .leading, spacing: 6) { shortcutButtons }
                }
            }
            .animation(reduceMotion ? nil : .default, value: general.confirmedShortcut)

            Picker("Trigger", selection: $general.recordingInteraction) {
                Text("Push-to-Talk (hold)")
                    .tag(RecordingInteraction.pushToTalk)
                Text("Toggle (press to start, press to stop)")
                    .tag(RecordingInteraction.toggle)
                Text("Hybrid (tap to toggle, hold to talk)")
                    .tag(RecordingInteraction.hybrid)
            }
            .accessibilityLabel("Trigger mode")
            .accessibilityHint("Choose whether holding or pressing the shortcut controls recording. Hybrid treats a quick tap as a toggle and a hold as push-to-talk.")
        } header: {
            Text("Recording Shortcut")
        } footer: {
            SettingsFooter(note: general.refusalNote) {
                Text(availability.footnote(
                    .shortcut,
                    base: String(localized: "The key that starts a dictation. Push-to-Talk is the safe default.", bundle: .module)
                ))
            }
        }
        .disabled(!availability.isEnabled(.shortcut))
    }

    @ViewBuilder
    private var shortcutButtons: some View {
        Button {
            if general.confirmedShortcut == nil {
                general.confirmRecommendedShortcut()
            } else {
                onChooseShortcut()
            }
        } label: {
            Text(general.confirmedShortcut == nil
                ? "Use Recommended Shortcut"
                : "Choose Another Shortcut…")
        }
        .accessibilityLabel(general.confirmedShortcut == nil
            ? "Use recommended shortcut"
            : "Choose another shortcut")
        .accessibilityHint("The shortcut is not active until it is confirmed. Right Option on its own is offered in the recorder.")

        if general.confirmedShortcut != nil {
            Button("Clear Shortcut", role: .destructive) {
                general.clearShortcut()
            }
            .accessibilityLabel("Clear confirmed shortcut")
            .accessibilityHint("Disables the global recording shortcut until another one is confirmed.")
        }
    }

    // MARK: Secondary triggers

    private var secondaryTriggersSection: some View {
        Section {
            // The job refusal applies to the rows, not the Section: the
            // footer's full-edition link (ADR-026) must never be dead.
            Group {
            auxiliaryRow(
                String(localized: "Cancel shortcut", bundle: .module),
                binding: triggers.cancelShortcut,
                hint: "An extra way to cancel a dictation in progress. Escape always cancels."
            )
            placeholderToggle(
                "Double-press to send (press Return after inserting)",
                binding: triggers.autoSend,
                hint: "Press the recording shortcut twice quickly while recording to have KVoice press Return once the text is inserted. Never used when the text went to the clipboard."
            )
            .controlSize(.mini)

            placeholderToggle(
                "Middle mouse button toggles recording",
                binding: triggers.middleMouseToggle,
                hint: "Hold the middle mouse button past the activation delay to start; press it again to stop. Ordinary middle clicks pass through. Needs Accessibility permission."
            )
            .controlSize(.mini)
            // ADR-026: not in the App Store edition (no global monitor).
            .disabled(!availability.isEnabled(.middleMouseTrigger))
            if triggers.middleMouseToggle?.wrappedValue == true, let delay = triggers.middleMouseActivationDelayMilliseconds {
                middleMouseDelaySlider(delay)
            }
            SettingsResetRow(.triggers, host: general.host, origin: .page(.shortcuts))
            }
            .disabled(!availability.isEnabled(.triggers))
        } header: {
            Text("More Ways to Trigger")
        } footer: {
            SettingsFooter(note: triggers.refusalNote?()) {
                Text(availability.footnote(.triggers, base: footerText))
                // ADR-026: nil (nothing drawn) outside the App Store edition.
                FullEditionLink(url: availability.fullEditionLink)
            }
        }
    }

    private var footerText: String {
        // ADR-026: the App Store edition has no global Escape monitor; its
        // sentence (the middle mouse row's reason) replaces the claim.
        if availability.edition == .appStore, let reason = availability.disabledReason(.middleMouseTrigger) {
            return String(localized: "Extras beside the recording shortcut.", bundle: .module) + " " + reason
        }
        let base = String(localized: "Extras beside the recording shortcut. Escape always cancels.", bundle: .module)
        return triggers.isBound ? base : base + " " + String(localized: "Dimmed options are not adjustable in this build yet.", bundle: .module)
    }

    /// `title` is a resolved `String` (it is lowercased into the button
    /// labels); `hint` is a key so the literal at the call site localizes.
    private func auxiliaryRow(_ title: String, binding: AuxiliaryShortcutBinding?, hint: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Value and buttons on one line when there is room; the buttons
            // move under the value when the pane is narrow.
            ViewThatFits(in: .horizontal) {
                HStack {
                    SettingsFactRow(
                        LocalizedStringKey(title),
                        binding?.shortcut.map(GeneralSettingsViewModel.displayName(for:)) ?? String(localized: "None", bundle: .module)
                    )
                    Spacer(minLength: 8)
                    auxiliaryButtons(title, binding: binding, hint: hint)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFactRow(
                        LocalizedStringKey(title),
                        binding?.shortcut.map(GeneralSettingsViewModel.displayName(for:)) ?? String(localized: "None", bundle: .module)
                    )
                    HStack { auxiliaryButtons(title, binding: binding, hint: hint) }
                }
            }
            if let error = binding?.error {
                StatusLabel(error, symbol: "exclamationmark.triangle.fill", tone: .attention)
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(title) error: \(error)")
            }
        }
    }

    @ViewBuilder
    private func auxiliaryButtons(_ title: String, binding: AuxiliaryShortcutBinding?, hint: LocalizedStringKey) -> some View {
        Button("Record…") {
            binding?.record()
        }
        .disabled(binding == nil)
        .accessibilityLabel("Record \(title.lowercased())")
        .accessibilityHint(binding == nil ? "Not adjustable in this build." : hint)
        if binding?.shortcut != nil {
            Button("Clear", role: .destructive) {
                binding?.clear()
            }
            .accessibilityLabel("Clear \(title.lowercased())")
        }
    }

    private func placeholderToggle(_ title: LocalizedStringKey, binding: Binding<Bool>?, hint: LocalizedStringKey) -> some View {
        Toggle(title, isOn: binding ?? .constant(false))
            .disabled(binding == nil)
            .accessibilityLabel(title)
            .accessibilityHint(binding == nil ? "Not adjustable in this build." : hint)
    }

    private func middleMouseDelaySlider(_ delay: Binding<Int>) -> some View {
        let range = TriggerSettings.middleMouseActivationDelayRange
        let value = Binding<Double>(
            get: { Double(delay.wrappedValue) },
            set: { delay.wrappedValue = Int($0.rounded()) }
        )
        return VStack(alignment: .leading, spacing: 2) {
            Slider(value: value, in: Double(range.lowerBound)...Double(range.upperBound), step: 50) {
                Text("Activation delay")
            } minimumValueLabel: {
                Text("0 s")
            } maximumValueLabel: {
                Text("2 s")
            }
            .accessibilityLabel("Middle mouse activation delay")
            .accessibilityValue("\(delay.wrappedValue) milliseconds")
            Text("Hold for \(delay.wrappedValue) ms before recording starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
