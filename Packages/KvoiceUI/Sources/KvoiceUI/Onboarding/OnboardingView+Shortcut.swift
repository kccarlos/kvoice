import AppKit
import KvoiceDomain
import SwiftUI

// The setup wizard's Shortcut screen and its Try It check (split from
// `OnboardingView.swift`, Q2b).
extension OnboardingView {
    // MARK: Shortcut

    var shortcutStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            modeCards

            shortcutBox

            if viewModel.shortcutRecorderIsOpen {
                noteText(String(localized: "A lone modifier like Right Option works, or a key with at least one modifier.", bundle: .module))
            } else if viewModel.shortcut == nil {
                noteText(String(localized: "\(GeneralSettingsViewModel.displayName(for: GeneralSettingsViewModel.recommendedShortcut)) is recommended but is not claimed until you confirm it.", bundle: .module))
            }

            if viewModel.hotkeyTestIsAvailable, !viewModel.shortcutRecorderIsOpen {
                hotkeyTestSection
            }
        }
    }

    /// The three trigger modes as cards (P-W3: the same three as Settings ›
    /// Shortcuts). Selected: a 2 pt cursor edge and a voice glyph.
    var modeCards: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach([RecordingInteraction.pushToTalk, .toggle, .hybrid], id: \.self) { interaction in
                let selected = viewModel.recordingInteraction == interaction
                Button {
                    viewModel.setRecordingInteraction(interaction)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        ModeGlyph(interaction: interaction, selected: selected)
                        Text(verbatim: OnboardingViewModel.name(for: interaction))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.kv.text)
                        Text(verbatim: OnboardingViewModel.summary(for: interaction))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.kv.text2)
                            .lineSpacing(1)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.kv.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Color.kv.cursor : Color.kv.line, lineWidth: selected ? 2 : 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .animation(.easeInOut(duration: 0.2), value: selected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: OnboardingViewModel.name(for: interaction)))
                .accessibilityHint(Text(verbatim: OnboardingViewModel.summary(for: interaction)))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityValue(Text(verbatim: KVAccessibility.selectionValue(selected)))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording interaction")
    }

    /// The keys box: the recorded keys (sinking while the check holds them,
    /// Motion § 11), or the recording state while the recorder window is
    /// open — a 2 pt cursor edge, "Press the keys you want…" with a caret,
    /// and Cancel — or the conflict sentence when the keys are taken.
    var shortcutBox: some View {
        let recording = viewModel.shortcutRecorderIsOpen
        let held = viewModel.hotkeyTestIsAvailable && viewModel.hotkeyTestSnapshot.isDown
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    if recording {
                        HStack(spacing: 3) {
                            Text("Press the keys you want…")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.kv.text)
                            WizardCaret(reduceMotion: reduceMotion)
                        }
                    } else if viewModel.shortcutKeyCaps.isEmpty {
                        Text("No shortcut recorded")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.kv.text2)
                    } else {
                        Keycaps(viewModel.shortcutKeyCaps, size: .large, held: held, reduceMotion: reduceMotion)
                    }
                }
                .frame(minHeight: 40)
                Spacer(minLength: 8)
                WizardChip(chip: viewModel.shortcutChip, reduceMotion: reduceMotion)
            }
            if !recording, let shortcutError = viewModel.shortcutError {
                Text(verbatim: shortcutError)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kv.errInk)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if recording {
                    Button("Cancel") {
                        viewModel.cancelShortcutRecording()
                    }
                    .buttonStyle(WizardButtonStyle())
                    .accessibilityHint("Closes the recorder without changing the shortcut.")
                } else {
                    Button(shortcutRecordTitle) {
                        viewModel.requestShortcutRecording()
                    }
                    .buttonStyle(WizardButtonStyle())
                    .accessibilityHint("Open the recorder and press the key combination you want.")
                    if viewModel.shortcut != GeneralSettingsViewModel.recommendedShortcut || viewModel.shortcutIsTaken {
                        // Recording used to be the only path, and it silently
                        // installed this value instead of recording.
                        Button("Use \(GeneralSettingsViewModel.glyphs(for: GeneralSettingsViewModel.recommendedShortcut))") {
                            viewModel.useRecommendedShortcut()
                        }
                        .buttonStyle(WizardButtonStyle(kind: .link))
                        .accessibilityLabel("Use Recommended Shortcut")
                        .accessibilityHint(
                            "Use \(GeneralSettingsViewModel.displayName(for: GeneralSettingsViewModel.recommendedShortcut))."
                        )
                    }
                }
            }
        }
        .padding(14)
        .background(Color.kv.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(recording ? Color.kv.cursor : Color.kv.line, lineWidth: recording ? 2 : 1)
        }
        .animation(.easeInOut(duration: 0.2), value: recording)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shortcut, \(viewModel.shortcutChip.title)")
    }

    /// "Record Shortcut…" with nothing set, "Record Again…" after a
    /// conflict, "Change…" once one is registered.
    var shortcutRecordTitle: String {
        if viewModel.shortcut == nil { return String(localized: "Record Shortcut…", bundle: .module) }
        if case .failed = viewModel.shortcutRegistrationState { return String(localized: "Record Again…", bundle: .module) }
        return String(localized: "Change…", bundle: .module)
    }

    // MARK: Hotkey test (Try It)

    /// Later waves: onboarding hotkey test; its own step until the 2026-09-16
    /// six-step wizard (P-W1) folded it under the recorder. A live indicator
    /// lit by the real global shortcut — never a button in this window — so
    /// the check proves the shortcut works while kvoice is not focused, the
    /// same way it will every day. Orange while held, green once detected
    /// (Motion § 11: the orb fills with the hold, a release before 0.6 s
    /// drains it).
    var hotkeyTestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            let snapshot = viewModel.hotkeyTestSnapshot
            let live = viewModel.hotkeyTestIsLive
            HStack(spacing: 12) {
                TryOrb(
                    progress: viewModel.recordingInteraction == .toggle && live ? 1 : viewModel.hotkeyTestHoldProgress,
                    live: live,
                    done: snapshot.isDone,
                    reduceMotion: reduceMotion
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: viewModel.hotkeyTestTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.kv.text)
                    Text(verbatim: viewModel.hotkeyTestDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.kv.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if live, viewModel.recordingInteraction != .toggle {
                    Capsule().fill(Color.kv.fill)
                        .frame(width: 90, height: 6)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.kv.voice)
                                .frame(width: 90 * viewModel.hotkeyTestHoldProgress, height: 6)
                                .animation(reduceMotion ? nil : .linear(duration: 0.1), value: viewModel.hotkeyTestHoldProgress)
                        }
                        .accessibilityHidden(true)
                }
            }
            .padding(14)
            .background(live ? Color.kv.voiceSoft : snapshot.isDone ? Color.kv.okSoft : Color.kv.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.kv.voice, lineWidth: 1)
                    .opacity(live ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.2), value: live)
            .animation(.easeInOut(duration: 0.2), value: snapshot.isDone)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Shortcut test")
            .accessibilityValue(viewModel.hotkeyTestStatusDescription)

            DisclosureGroup("Shortcut didn't register?") {
                VStack(alignment: .leading, spacing: 10) {
                    Group {
                        if viewModel.edition == .appStore {
                            Text("Some apps and system shortcuts can claim a key combination first. Try a different shortcut. The App Store edition needs a key combination; a lone modifier key cannot be detected.")
                        } else {
                            Text("Some apps and system shortcuts can claim a key combination first. Try a different shortcut, or make sure KVoice has Accessibility if you picked a lone modifier key.")
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kv.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    // ADR-026: the App Store edition's pointer to the full
                    // edition, where a lone modifier key works.
                    FullEditionLink(url: viewModel.fullEditionLink)
                        .font(.system(size: 12))
                    HStack {
                        Button("Choose Another Shortcut…") {
                            viewModel.requestShortcutRecording()
                        }
                        .buttonStyle(WizardButtonStyle(size: .alt))
                        if viewModel.shortcut?.isModifierOnly == true, viewModel.edition == .developerID {
                            Button("Open Accessibility Settings") {
                                viewModel.openSystemSettings(for: .accessibility)
                            }
                            .buttonStyle(WizardButtonStyle(size: .alt))
                        }
                    }
                }
                .padding(.top, 6)
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.kv.text2)
            .accessibilityHint("A lone modifier key such as Right Option needs Accessibility permission to be detected.")
        }
    }
}
