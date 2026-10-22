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
        // UI v2 fidelity F3 (Window.dc `microphone`): Input Device rows
        // with a segmented mode, the Priority list as its own card, and
        // the Level Test card with the 32-segment meter.
        KVCardPage {
            KVCardSection {
                SettingsFactRow("Currently using", currentDeviceName)
                if let inputSelection {
                    @Bindable var model = inputSelection
                    LabeledContent {
                        KVSegmented("Input mode", selection: $model.mode, options: [
                            (.systemDefault, String(localized: "System Default", bundle: .module)),
                            (.customDevice, String(localized: "Custom Device", bundle: .module)),
                            (.prioritized, String(localized: "Prioritized", bundle: .module))
                        ])
                        .accessibilityHint(Text("System Default follows System Settings. Custom Device pins one microphone. Prioritized uses the first connected device from your list.", bundle: .module))
                    } label: {
                        Text("Input mode")
                        if let note = inputSelection.selectionNote { Text(note) }
                    }
                    if inputSelection.mode == .customDevice {
                        customDevicePicker(inputSelection)
                    }
                    if let note = inputSelection.bluetoothInputNote {
                        BluetoothInputNote(text: note)
                    }
                } else {
                    SettingsFactRow("Input mode", "System Default")
                }
            } header: {
                KVHeaderRow("Input Device") {
                    if let inputSelection {
                        Button("Refresh Devices") { inputSelection.refresh() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.kv.cursorInk)
                            .accessibilityHint("Re-reads the connected input devices.")
                    }
                }
            } footer: {
                SettingsFooter(note: inputSelection?.refusalNote) {
                    if inputSelection == nil {
                        Text("KVoice follows the system default input in this build. Change it in System Settings › Sound › Input.")
                    }
                }
            }
            if let inputSelection, inputSelection.mode == .prioritized {
                KVCardSection {
                    prioritizedList(inputSelection)
                } header: {
                    KVHeaderRow("Priority") { addDeviceMenu(inputSelection) }
                } footer: {
                    Text("The first connected device wins; a disconnected device falls back to the next one, then to the system default.")
                }
            }
            levelTestSection
        }
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

    private var levelTestSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Level Test")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 2)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 10) {
                KVLevelSegmentsView(level: microphoneTest.meterValue)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Microphone level", bundle: .module))
                    .accessibilityValue(Text(verbatim: microphoneTest.meterAccessibilityValue))
                HStack(alignment: .center, spacing: 12) {
                    Text(microphoneTest.statusDescription)
                        .font(.system(size: 12, weight: levelTestSucceeded ? .semibold : .regular))
                        .foregroundStyle(microphoneTestFailed ? Color.kv.warnInk : levelTestSucceeded ? Color.kv.okInk : Color.kv.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if microphoneTest.isRunning {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                    }
                    Button(microphoneTest.isRunning ? "Listening…" : "Run Level Test") {
                        Task { @MainActor in
                            await microphoneTest.run(authorization: microphoneIsGranted ? .granted : .denied)
                        }
                    }
                    .buttonStyle(KVButtonStyle(height: 26))
                    .disabled(microphoneTest.isRunning || !microphoneIsGranted)
                    .accessibilityHint(microphoneIsGranted
                        ? "Captures three seconds and shows the peak level. Nothing is saved."
                        : "Grant Microphone permission in the Permissions section first.")
                }
            }
            .padding(14)
            .background(Color.kv.surface, in: RoundedRectangle(cornerRadius: KVCardLayout.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: KVCardLayout.cardRadius, style: .continuous).strokeBorder(Color.kv.line, lineWidth: 1))
            .animation(reduceMotion ? nil : .default, value: microphoneTest.isRunning)
            Text("The level test keeps no audio. It uses the device chosen above.")
                .font(.system(size: 11))
                .foregroundStyle(Color.kv.text2)
                .padding(.horizontal, 2)
        }
    }

    private var levelTestSucceeded: Bool {
        if case .completed = microphoneTest.state { return true }
        return false
    }

    private var currentDeviceName: String {
        if let inputSelection {
            return inputSelection.currentDeviceName
        }
        return microphoneTest.inputDeviceName ?? String(localized: "No input device", bundle: .module)
    }

    private func customDevicePicker(_ model: AudioInputViewModel) -> some View {
        @Bindable var model = model
        let current = model.customDeviceUID.map { uid in
            model.devices.first { $0.uid == uid }?.name ?? String(localized: "Disconnected device", bundle: .module)
        } ?? String(localized: "Choose a device…", bundle: .module)
        return LabeledContent {
            KVSelect("Custom input device", selection: $model.customDeviceUID, current: current) {
                Text("Choose a device…").tag(String?.none)
                ForEach(model.devices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
                if let uid = model.customDeviceUID, !model.devices.contains(where: { $0.uid == uid }) {
                    Text("Disconnected device").tag(Optional(uid))
                }
            }
        } label: {
            Text("Device")
        }
    }

    private func addDeviceMenu(_ model: AudioInputViewModel) -> some View {
        Menu {
            let candidates = model.devicesAvailableToAdd
            if candidates.isEmpty {
                Text("Every connected device is listed")
            }
            ForEach(candidates) { device in
                Button(device.name) { model.addToPriority(uid: device.uid) }
            }
        } label: {
            Text("Add Device…").font(.system(size: 11)).foregroundStyle(Color.kv.cursorInk)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityHint("Adds a connected device to the end of the list.")
    }

    @ViewBuilder
    private func prioritizedList(_ model: AudioInputViewModel) -> some View {
        let listed = model.prioritizedDevices
        if listed.isEmpty {
            Text("No devices in the list yet.")
                .foregroundStyle(Color.kv.text2)
        }
        ForEach(Array(listed.enumerated()), id: \.element.uid) { index, device in
            HStack(spacing: 12) {
                Text(verbatim: "\(index + 1)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.kv.text2)
                    .frame(width: 20, height: 20)
                    .background(Color.kv.fill, in: Circle())
                    .accessibilityHidden(true)
                Text(device.name)
                    .font(.system(size: 13))
                    .foregroundStyle(device.isAvailable ? Color.kv.text : Color.kv.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !device.isAvailable {
                    KVChip(String(localized: "Not connected", bundle: .module), tone: .neutral, dot: false)
                } else if device.name == model.currentDeviceName {
                    KVChip(String(localized: "In use", bundle: .module), tone: .ok, dot: false)
                }
                HStack(spacing: 0) {
                    Button { model.movePriority(uid: device.uid, by: -1) } label: { Text(verbatim: "↑").frame(width: 14) }
                        .disabled(index == 0)
                        .accessibilityLabel("Move \(device.name) up")
                    Button { model.movePriority(uid: device.uid, by: 1) } label: { Text(verbatim: "↓").frame(width: 14) }
                        .disabled(index == listed.count - 1)
                        .accessibilityLabel("Move \(device.name) down")
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.kv.text2)
                .buttonStyle(.plain)
                Button(role: .destructive) {
                    model.removeFromPriority(uid: device.uid)
                } label: {
                    Image(systemName: "minus.circle").foregroundStyle(Color.kv.text2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(device.name) from the list")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: "\(index + 1). \(device.name)"))
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

/// Window.dc `isLevel`: 32 segments 26 pt high, 3 pt apart; lit segments
/// are `voice`, from the 23rd `warn`, from the 27th `err`; unlit `fill`.
struct KVLevelSegmentsView: View {
    let level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lit = KVLevelSegments.lit(level: level)
        HStack(spacing: 3) {
            ForEach(0..<KVLevelSegments.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index < lit ? KVLevelSegments.tone(index).solid.color : Color.kv.fill)
                    .frame(height: 24)
            }
        }
        .frame(height: 26)
        // Motion §4·6: bar changes are 70 ms linear (live signal).
        .animation(reduceMotion ? nil : .linear(duration: 0.07), value: lit)
    }
}

enum KVLevelSegments {
    static let count = 32

    /// Lit segments for a 0…1 level.
    static func lit(level: Double) -> Int {
        Int((min(1, max(0, level)) * Double(count)).rounded())
    }

    static func tone(_ index: Int) -> KVTone {
        index >= 26 ? .err : index >= 22 ? .warn : .voice
    }
}
