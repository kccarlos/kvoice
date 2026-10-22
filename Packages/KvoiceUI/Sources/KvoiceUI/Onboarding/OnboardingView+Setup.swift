import AppKit
import KvoiceDomain
import SwiftUI

// The setup wizard's Welcome, Model, Microphone and Accessibility screens
// (split from `OnboardingView.swift`, Q2b).
extension OnboardingView {
    // MARK: Welcome

    var welcomeStage: some View {
        VStack(alignment: .leading, spacing: 16) {
            WelcomeHero(keyCaps: viewModel.heroKeyCaps, reduceMotion: reduceMotion)

            VStack(alignment: .leading, spacing: 4) {
                Text("Your voice, typed — on this Mac.")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.kv.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Hold your shortcut, speak, and let go. KVoice transcribes on this Mac and places the text at your cursor, in any app.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.kv.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 20, alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 10) {
                promise("Audio never leaves this Mac")
                promise("No account, no analytics")
                promise("Works offline once the model is in")
                promise("AI polish is optional and off")
            }
        }
    }

    func promise(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            WizardCheckMark(side: 11, lineWidth: 2.4, color: Color.kv.ok)
                .frame(width: 20, height: 20)
                .background(Color.kv.okSoft, in: Circle())
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.kv.text)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Model

    var modelStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            let isSystemManaged = viewModel.modelEntry?.isSystemManaged == true
            let paused = viewModel.modelPausedProgress
            WizardCard(
                glyph: isSystemManaged ? WizardGlyph.apple : WizardGlyph.wave,
                tileFill: isSystemManaged ? .ink : .voice,
                title: viewModel.modelDisplayName,
                detail: viewModel.modelDetailLine,
                chip: viewModel.modelChip,
                edge: viewModel.modelCardIsFailed ? .err : nil,
                reduceMotion: reduceMotion
            ) {
                if let line = viewModel.modelCardLine {
                    cardLine(line.text, emphasized: line.emphasized)
                }

                if let paused {
                    ProgressStrip(fraction: paused.fraction, label: paused.label, trailing: paused.trailing, reduceMotion: reduceMotion)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Model progress")
                        .accessibilityValue(paused.label)
                } else if let activity = viewModel.modelActivityDescription {
                    ProgressStrip(
                        fraction: viewModel.modelProgress,
                        label: activity,
                        trailing: viewModel.modelProgressPercentDescription,
                        reduceMotion: reduceMotion
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Model progress")
                    .accessibilityValue(viewModel.modelProgress.map { "\(Int($0 * 100)) percent. \(activity)" } ?? activity)
                }

                if let notice = viewModel.modelNotice {
                    CardAlert(text: notice, tone: .cursor)
                }
                if paused == nil, let failure = viewModel.modelFailureMessage {
                    CardAlert(text: failure, tone: viewModel.modelCardIsFailed ? .err : .warn)
                        .accessibilityLabel("Model problem: \(failure)")
                }
                if let noSpace = viewModel.modelNoSpaceMessage {
                    CardAlert(text: noSpace, tone: .warn)
                }

                if viewModel.modelCanCancel {
                    Button("Cancel Download") {
                        viewModel.handleModelAction(.cancel)
                    }
                    .buttonStyle(WizardButtonStyle())
                    .accessibilityHint("Stops the download. Downloaded bytes are kept so it can be resumed.")
                }

                if let alternativeTitle = viewModel.alternativeModelTitle,
                   let alternativeNote = viewModel.alternativeModelNote {
                    // 2026-09-29: the other model, one click away, with what
                    // choosing it costs said up front.
                    cardSection {
                        HStack(spacing: 12) {
                            Text(verbatim: alternativeNote)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.kv.text2)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(alternativeTitle) { viewModel.useAlternativeModel() }
                                .buttonStyle(WizardButtonStyle(size: .alt))
                        }
                    }
                }

                if viewModel.modelShowsFoot {
                    cardSection {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            if let estimate = viewModel.modelSpaceEstimateDescription {
                                HStack(spacing: 4) {
                                    Text("Download size")
                                    Text(verbatim: estimate)
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(Color.kv.text2)
                                .accessibilityElement(children: .combine)
                            }
                            Spacer(minLength: 8)
                            Button("Choose Existing…") {
                                viewModel.handleModelAction(.chooseExisting)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.kv.cursorInk)
                            .disabled(viewModel.modelIsBusy)
                            .accessibilityHint("Pick a folder that already contains a verified KVoice model package.")
                        }
                    }
                }
            }

            if let note = viewModel.modelStepNote {
                noteText(note)
            }
        }
    }

    // MARK: Microphone

    var microphoneStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            let card = viewModel.microphonePermissionCard
            WizardCard(
                glyph: WizardGlyph.mic,
                tileFill: .voice,
                title: card.kind.title,
                detail: String(localized: "Used only while you hold or toggle the shortcut", bundle: .module),
                chip: viewModel.microphoneChip(),
                edge: microphoneIsDenied ? .warn : nil,
                drawsCheck: true,
                glowTrigger: microphoneGlow,
                reduceMotion: reduceMotion
            ) {
                cardLine(viewModel.microphoneCardLine)
                if viewModel.isRequestingMicrophonePermission {
                    CardAlert(text: String(localized: "macOS is asking for permission. Choose Allow in the dialog.", bundle: .module), tone: .cursor)
                }
                if microphoneIsDenied {
                    CardAlert(text: String(localized: "KVoice can’t hear you. Turn KVoice on in System Settings › Privacy & Security › Microphone — this screen updates by itself.", bundle: .module), tone: .warn)
                    if viewModel.systemSettingsOpenFailed == .microphone {
                        writtenPath(card.kind, failed: true)
                    }
                    Button("Check Again") {
                        Task { @MainActor in
                            await viewModel.refreshMicrophoneStatus()
                        }
                    }
                    .buttonStyle(WizardButtonStyle())
                    .accessibilityHint("Reads the permission again after you change it in System Settings. It is also re-read automatically while this screen is open.")
                }
                if viewModel.microphoneAuthorization != .granted {
                    lastChecked(card)
                }
            }

            if viewModel.microphoneAuthorization == .granted {
                levelTest
            } else if viewModel.microphoneAuthorization == .notDetermined, !viewModel.isRequestingMicrophonePermission {
                noteText(String(localized: "macOS will ask once. Choose Allow in the dialog.", bundle: .module))
            }
        }
    }

    var levelTest: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Level test")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                inputPicker
            }
            LevelMeter(value: viewModel.microphoneTest.meterValue)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Microphone level")
                .accessibilityValue(viewModel.microphoneTest.meterAccessibilityValue)
            HStack(spacing: 6) {
                if case .failed = viewModel.microphoneTestState {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.kv.warn)
                        .accessibilityHidden(true)
                }
                Text(verbatim: viewModel.microphoneLevelStatus)
                    .font(.system(size: 12, weight: viewModel.microphoneTestState.isSuccessful ? .semibold : .regular))
                    .foregroundStyle(viewModel.microphoneTestState.isSuccessful ? Color.kv.okInk : Color.kv.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(14)
        .background(Color.kv.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The level test's input, "MacBook Pro Microphone ▾": a menu of the
    /// system default and the connected inputs (the same setting as
    /// Settings › Microphone). Picking another input asks for the test
    /// again. Without the shell's model it is the input's name alone.
    @ViewBuilder
    var inputPicker: some View {
        let name = viewModel.currentInputDeviceName ?? String(localized: "No input device", bundle: .module)
        if let audioInput {
            Menu {
                Picker(selection: Binding<String?>(
                    get: { audioInput.settings.mode == .customDevice ? audioInput.customDeviceUID : nil },
                    set: { uid in
                        audioInput.selectDevice(uid: uid, origin: .wizard)
                        viewModel.microphoneInputChanged()
                    }
                )) {
                    Text("System Default").tag(String?.none)
                    ForEach(audioInput.devices) { device in
                        Text(verbatim: device.name).tag(Optional(device.uid))
                    }
                } label: {
                    Text("Input")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(verbatim: "\(name) ▾")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.kv.text2)
                    .lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(viewModel.microphoneTest.isRunning)
            .onAppear { audioInput.refresh() }
            .accessibilityLabel("Input device")
            .accessibilityValue(Text(verbatim: name))
        } else {
            Text(verbatim: name)
                .font(.system(size: 13))
                .foregroundStyle(Color.kv.text2)
                .lineLimit(1)
                .accessibilityLabel("Input device: \(name)")
        }
    }

    var microphoneIsDenied: Bool {
        viewModel.microphoneAuthorization == .denied || viewModel.microphoneAuthorization == .restricted
    }

    // MARK: Accessibility

    var accessibilityStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            let card = viewModel.accessibilityPermissionCard
            let granted = viewModel.accessibilityStatus == .granted
            WizardCard(
                glyph: WizardGlyph.access,
                tileFill: .ok,
                title: card.kind.title,
                detail: viewModel.edition == .appStore
                    ? String(localized: "App Store edition · types the text for you", bundle: .module)
                    : String(localized: "Needed to place text in other apps", bundle: .module),
                chip: viewModel.accessibilityChip(),
                edge: viewModel.accessibilityIsWaitingForUser ? .warn : nil,
                drawsCheck: true,
                glowTrigger: accessibilityGlow,
                reduceMotion: reduceMotion
            ) {
                if granted {
                    cardLine(viewModel.edition == .appStore
                        ? String(localized: "Done. KVoice will type the text into your app.", bundle: .module)
                        : String(localized: "Done. Text will go straight to your cursor.", bundle: .module), emphasized: true)
                } else {
                    cardLine(viewModel.accessibilityCardLine)
                }
                if viewModel.isRequestingAccessibilityPermission {
                    CardAlert(text: String(localized: "macOS is showing the Accessibility prompt.", bundle: .module), tone: .cursor)
                } else if viewModel.accessibilityIsWaitingForUser {
                    // Accessibility has no deny: until the switch is on, this
                    // is waiting (amber), never "Denied". The alert carries
                    // the written path (FR-PERM-004).
                    CardAlert(text: String(localized: "Waiting for you to turn on KVoice in System Settings › Privacy & Security › Accessibility. This screen updates by itself once it is on.", bundle: .module), tone: .warn)
                }
                if !granted, viewModel.systemSettingsOpenFailed == .accessibility
                    || (!viewModel.accessibilityIsWaitingForUser && card.showsSystemSettingsPath()) {
                    writtenPath(card.kind, failed: viewModel.systemSettingsOpenFailed == .accessibility)
                }
                if !granted, viewModel.accessibilityIsWaitingForUser || viewModel.accessibilityStatus == .denied {
                    Button("Check Again") {
                        Task { @MainActor in
                            await viewModel.refreshAccessibilityStatus()
                        }
                    }
                    .buttonStyle(WizardButtonStyle())
                    .accessibilityHint("Reads the trust state again. It is also re-read every second while this screen is open.")
                }
                if !granted {
                    lastChecked(card)
                }
            }

            if !granted {
                // Both editions fall back to the clipboard without the grant.
                noteText(String(localized: "Without it, KVoice copies the text to the clipboard instead and you paste it yourself.", bundle: .module), size: 12)
            }
        }
    }
}
