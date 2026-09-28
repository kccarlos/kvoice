import AppKit
import KeyboardShortcuts
import KvoiceDomain
import SwiftUI

/// Records an alternate global shortcut, showing what is being pressed as it
/// happens.
///
/// This deliberately does not use `KeyboardShortcuts.Recorder`. That control
/// only updates once it has accepted a complete shortcut and merely beeps at
/// anything it rejects, so there is no way to tell "not captured" from
/// "captured and refused" — and its menu-conflict check treats every
/// menu-matching combination as a conflict when it is driven by a binding
/// rather than a `Name`. A local event monitor gives live modifier feedback and
/// explicit reasons instead.
///
/// The recorder lives in this package because it is the only one allowed to see
/// `KeyboardShortcuts` types; it reports a domain `ShortcutDefinition`.
@MainActor
struct ShortcutRecorderView: View {
    let currentShortcut: ShortcutDefinition?
    let onRecorded: (ShortcutDefinition) -> Void
    let onCancel: () -> Void

    /// What the picker offers: a lone modifier key, or a recorded combination.
    enum Choice: Hashable {
        case modifierOnly(ShortcutDefinition.ModifierOnlyKey)
        case customCombination
    }

    /// The value the window will report.
    enum Recorded: Equatable {
        case combination(KeyboardShortcuts.Shortcut)
        case modifierOnly(ShortcutDefinition.ModifierOnlyKey)

        var definition: ShortcutDefinition {
            switch self {
            case .combination(let shortcut): return shortcut.asShortcutDefinition()
            case .modifierOnly(let key): return ShortcutDefinition(modifierOnly: key)
            }
        }
    }

    @State private var choice: Choice
    @State private var heldModifiers: NSEvent.ModifierFlags = []
    @State private var captured: Recorded?
    @State private var rejection: String?
    @State private var monitor: Any?

    init(
        currentShortcut: ShortcutDefinition?,
        onRecorded: @escaping (ShortcutDefinition) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.currentShortcut = currentShortcut
        self.onRecorded = onRecorded
        self.onCancel = onCancel
        // Open on the recommended key unless the user already has a
        // combination, in which case start where they are.
        if let key = currentShortcut?.modifierOnlyKey {
            _choice = State(initialValue: .modifierOnly(key))
            _captured = State(initialValue: .modifierOnly(key))
        } else if currentShortcut != nil {
            _choice = State(initialValue: .customCombination)
        } else {
            _choice = State(initialValue: .modifierOnly(.rightOption))
            _captured = State(initialValue: .modifierOnly(.rightOption))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a shortcut")
                .font(.headline)

            Picker("Trigger key", selection: $choice) {
                ForEach(ShortcutDefinition.ModifierOnlyKey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(Choice.modifierOnly(key))
                }
                Text("Custom key combination…").tag(Choice.customCombination)
            }
            .accessibilityLabel("Trigger key")
            .accessibilityHint("Right Option is recommended. A lone modifier key needs Accessibility permission; a key combination does not.")
            .onChange(of: choice) { _, newChoice in
                rejection = nil
                switch newChoice {
                case .modifierOnly(let key):
                    captured = .modifierOnly(key)
                case .customCombination:
                    captured = nil
                }
            }

            if isCustomCombination {
                Text("Press the combination you want. It needs at least one of Control, Option, or Command.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The key on its own starts and stops dictation, so it never types anything. Right Option is recommended because the left key is the one used for typing symbols.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Live readout. Updates on every modifier change, so it is obvious
            // the app is seeing the keys even before a full combination.
            GroupBox {
                HStack {
                    Text(liveDisplay)
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .foregroundStyle(captured == nil ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                        .accessibilityLabel(
                            captured == nil
                                ? "Waiting for a shortcut. Currently held: \(liveDisplay)"
                                : "Recorded \(liveDisplay)"
                        )
                }
            }

            if let rejection {
                Text(rejection)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let currentShortcut {
                Text("Current: \(Self.describe(currentShortcut))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Clear") {
                    captured = nil
                    rejection = nil
                }
                .disabled(captured == nil || !isCustomCombination)

                Spacer()

                Button("Cancel") {
                    onCancel()
                }

                Button("Use Shortcut") {
                    guard let captured else { return }
                    onRecorded(captured.definition)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(captured == nil)
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear(perform: startMonitoring)
        .onDisappear(perform: stopMonitoring)
    }

    private var isCustomCombination: Bool {
        choice == .customCombination
    }

    private var liveDisplay: String {
        switch captured {
        case .combination(let shortcut):
            return String(describing: shortcut)
        case .modifierOnly(let key):
            return key.displayName
        case nil:
            let symbols = Self.symbols(for: heldModifiers)
            return symbols.isEmpty ? "Press a combination…" : symbols
        }
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { event in
            // Returning nil swallows the event so it cannot beep, type into a
            // field, or reach a menu while recording. With a modifier-only
            // key selected the picker owns the choice, so keys pass through
            // (Return still confirms, Escape still cancels).
            guard isCustomCombination else {
                if event.type == .keyDown, event.keyCode == 53 {
                    onCancel()
                    return nil
                }
                return event
            }
            switch event.type {
            case .flagsChanged:
                heldModifiers = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                return nil
            case .keyDown:
                handleKeyDown(event)
                return nil
            default:
                return event
            }
        }
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        heldModifiers = []
    }

    private func handleKeyDown(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Bare Escape closes, matching the usual recorder convention. Escape
        // with modifiers stays recordable.
        if event.keyCode == 53, modifiers.subtracting(.function).isEmpty {
            onCancel()
            return
        }

        // Carbon registration needs a real modifier; Shift alone does not work,
        // and the adapter's forward mapping rejects a modifier-less shortcut.
        guard !modifiers.subtracting([.shift, .function, .capsLock]).isEmpty else {
            captured = nil
            rejection = "Add Control, Option, or Command — Shift alone will not register."
            return
        }

        guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
            captured = nil
            rejection = "That key cannot be used as a global shortcut."
            return
        }

        captured = .combination(shortcut)
        rejection = nil
    }

    private static func symbols(for modifiers: NSEvent.ModifierFlags) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result
    }

    /// Local formatting so this package does not depend on KvoiceUI.
    private static func describe(_ shortcut: ShortcutDefinition) -> String {
        if let key = shortcut.modifierOnlyKey {
            return key.displayName
        }
        let modifiers = shortcut.modifiers.map { $0.capitalized }
        let key = shortcut.key == " " ? "Space" : shortcut.key.capitalized
        return (modifiers + [key]).joined(separator: "-")
    }
}

@MainActor
final class ShortcutRecorderWindowController: NSWindowController {
    init(
        currentShortcut: ShortcutDefinition?,
        onRecorded: @escaping (ShortcutDefinition) -> Void,
        onClose: @escaping () -> Void
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "KVoice Shortcut"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.contentView = NSHostingView(
            rootView: ShortcutRecorderView(
                currentShortcut: currentShortcut,
                onRecorded: { definition in
                    onRecorded(definition)
                    onClose()
                },
                onCancel: onClose
            )
        )
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ShortcutRecorderWindowController does not support NSCoder construction")
    }
}
