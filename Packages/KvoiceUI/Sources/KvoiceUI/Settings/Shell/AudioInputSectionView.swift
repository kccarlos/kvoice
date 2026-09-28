import SwiftUI
import KvoiceDomain

/// The Audio Input section: the device kvoice will record from, the input
/// mode (System Default / Custom Device / Prioritized list), and the level
/// test. Without an `inputSelection` model (the shell passes one built on
/// CoreAudio) it shows the system default and says choosing is unavailable.
@MainActor
public struct AudioInputSectionView: View {
    private let microphoneTest: MicrophoneTestViewModel
    private let permissions: PermissionStatusViewModel
    private let inputSelection: AudioInputViewModel?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        microphoneTest: MicrophoneTestViewModel = .init(),
        permissions: PermissionStatusViewModel = .init(),
        inputSelection: AudioInputViewModel? = nil
    ) {
        self.microphoneTest = microphoneTest
        self.permissions = permissions
        self.inputSelection = inputSelection
    }

    public var body: some View {
        Form {
            Section {
                SettingsFactRow("Currently using", currentDeviceName, systemImage: "mic")
                if let note = inputSelection?.selectionNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = inputSelection?.bluetoothInputNote {
                    BluetoothInputNote(text: note)
                }
                if let inputSelection {
                    @Bindable var model = inputSelection
                    Picker("Input mode", selection: $model.mode) {
                        Text("System Default").tag(AudioInputMode.systemDefault)
                        Text("Custom Device").tag(AudioInputMode.customDevice)
                        Text("Prioritized").tag(AudioInputMode.prioritized)
                    }
                    .accessibilityLabel("Input mode")
                    .accessibilityHint("System Default follows System Settings. Custom Device pins one microphone. Prioritized uses the first connected device from your list.")

                    switch inputSelection.mode {
                    case .systemDefault:
                        EmptyView()
                    case .customDevice:
                        customDevicePicker(inputSelection)
                    case .prioritized:
                        prioritizedList(inputSelection)
                    }

                    Button("Refresh Devices") {
                        inputSelection.refresh()
                    }
                    .accessibilityHint("Re-reads the connected input devices.")
                } else {
                    SettingsFactRow("Input mode", "System Default")
                }
            } header: {
                Text("Input Device")
            } footer: {
                SettingsFooter(note: inputSelection?.refusalNote) {
                    Text(inputSelection == nil
                        ? "KVoice follows the system default input in this build. Change it in System Settings › Sound › Input."
                        : "Devices are remembered by hardware identity; a disconnected device falls back to the system default.")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: microphoneTest.meterValue)
                        .tint(.accentColor)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: microphoneTest.meterValue)
                        .accessibilityLabel("Microphone level")
                        .accessibilityValue(microphoneTest.meterAccessibilityValue)

                    Group {
                        if microphoneTestFailed {
                            StatusLabel(microphoneTest.statusDescription, symbol: "exclamationmark.triangle.fill", tone: .attention)
                                .labelStyle(.titleAndIcon)
                        } else {
                            Text(microphoneTest.statusDescription)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button(microphoneTest.isRunning ? "Listening…" : "Run Level Test") {
                            Task { @MainActor in
                                await microphoneTest.run(authorization: microphoneIsGranted ? .granted : .denied)
                            }
                        }
                        .disabled(microphoneTest.isRunning || !microphoneIsGranted)
                        .accessibilityHint(microphoneIsGranted
                            ? "Captures three seconds and shows the peak level. Nothing is saved."
                            : "Grant Microphone permission in the Permissions section first.")

                        if microphoneTest.isRunning {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .animation(reduceMotion ? nil : .default, value: microphoneTest.isRunning)
            } header: {
                Text("Level Test")
            } footer: {
                Text("The level test keeps no audio; the meter shows the peak once the test finishes. It uses the device chosen above.")
            }
        }
        .formStyle(.grouped)
        .task {
            microphoneTest.refreshInputDevice()
            inputSelection?.refresh()
            await permissions.pollWhileVisible()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            microphoneTest.refreshInputDevice()
            inputSelection?.refresh()
        }
    }

    private var currentDeviceName: String {
        if let inputSelection {
            return inputSelection.currentDeviceName
        }
        return microphoneTest.inputDeviceName ?? String(localized: "No input device", bundle: .module)
    }

    private func customDevicePicker(_ model: AudioInputViewModel) -> some View {
        @Bindable var model = model
        return Picker("Device", selection: $model.customDeviceUID) {
            Text("Choose a device…").tag(String?.none)
            ForEach(model.devices) { device in
                Text(device.name).tag(Optional(device.uid))
            }
            if let uid = model.customDeviceUID, !model.devices.contains(where: { $0.uid == uid }) {
                Text("Disconnected device").tag(Optional(uid))
            }
        }
        .accessibilityLabel("Custom input device")
    }

    private func prioritizedList(_ model: AudioInputViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let listed = model.prioritizedDevices
            if listed.isEmpty {
                Text("No devices in the list yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(listed.enumerated()), id: \.element.uid) { index, device in
                HStack {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(device.name)
                        .foregroundStyle(device.isAvailable ? .primary : .secondary)
                    if !device.isAvailable {
                        StatusLabel(String(localized: "Not connected", bundle: .module), symbol: "exclamationmark.circle.fill", tone: .attention)
                            .font(.caption)
                            .labelStyle(.titleAndIcon)
                    }
                    Spacer()
                    Button {
                        model.movePriority(uid: device.uid, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(index == 0)
                    .accessibilityLabel("Move \(device.name) up")
                    Button {
                        model.movePriority(uid: device.uid, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(index == listed.count - 1)
                    .accessibilityLabel("Move \(device.name) down")
                    Button(role: .destructive) {
                        model.removeFromPriority(uid: device.uid)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .accessibilityLabel("Remove \(device.name) from the list")
                }
                .buttonStyle(.borderless)
            }
            Menu("Add Device") {
                let candidates = model.devicesAvailableToAdd
                if candidates.isEmpty {
                    Text("Every connected device is listed")
                }
                ForEach(candidates) { device in
                    Button(device.name) {
                        model.addToPriority(uid: device.uid)
                    }
                }
            }
            .accessibilityHint("Adds a connected device to the end of the list.")
        }
    }

    private var microphoneIsGranted: Bool {
        permissions.microphone.presentedState() == .granted
    }

    private var microphoneTestFailed: Bool {
        if case .failed = microphoneTest.state { return true }
        return false
    }
}

/// The Bluetooth start-latency advice (2026-09-16), one row shared by the
/// Audio Input and Recording pages. Text only: the transport is a fact the
/// user cannot change from here.
struct BluetoothInputNote: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "wave.3.right")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
