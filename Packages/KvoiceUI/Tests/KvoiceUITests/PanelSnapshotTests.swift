import AppKit
import SwiftUI
import XCTest
@testable import KvoiceDomain
@testable import KvoiceUI

/// UI v2 wave 2 and fidelity F1, opt-in like `LayoutSnapshotTests`: every
/// status-panel state the app can reach, light and dark, and the menu-bar
/// icon in every state, on a light and a dark bar —
/// `panel/panel-<state>-<light|dark>.png`, `panel/icon-<state>.png`, and
/// `panel-contact-sheet.png` beside the folder. Set
/// `KVOICE_LAYOUT_SNAPSHOTS=<dir>`. Nothing is asserted about pixels. The
/// panel draws its own ground (`.standalone`, the chrome the app's
/// borderless panel uses) on the design's lavender backdrop; the drop
/// shadow is the window server's in the app and is approximated here.
@MainActor
final class PanelSnapshotTests: XCTestCase {
    private static let controllers = ControllerBox()

    final class ControllerBox: @unchecked Sendable {
        var items: [StatusItemIconController] = []
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func outputDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["KVOICE_LAYOUT_SNAPSHOTS"] else {
            throw XCTSkip("Set KVOICE_LAYOUT_SNAPSHOTS=<dir> to render layout snapshots")
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let out = root.appendingPathComponent("panel", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    func testRenderEveryPanelStateAndIcon() throws {
        let out = try outputDirectory()
        var sheet: [(String, NSImage)] = []

        for phase in Self.phases {
            for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let header = StatusMenuHeaderModel()
                header.apply(context: phase.header)
                header.apply(hud: phase.hud)
                let model = StatusPanelModel(header: header)
                model.apply(context: phase.context)
                model.isPresented = true
                model.now = { Self.now }
                let dark = appearance == .darkAqua
                let view = StatusPanelView(model: model, chrome: .standalone, overrides: .init(reduceMotion: true))
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.black.opacity(0.001))
                            // 0 20 50 rgba(22,29,51,.28) / rgba(0,0,0,.45)
                            .shadow(color: dark ? .black.opacity(0.45) : Color(red: 22 / 255, green: 29 / 255, blue: 51 / 255).opacity(0.28), radius: 25, y: 20)
                    )
                    .padding(20)
                    .frame(width: 360, height: phase.height, alignment: .top)
                    // The design's backdrop: #8E9CC8.
                    .background(Color(red: 0x8E / 255, green: 0x9C / 255, blue: 0xC8 / 255))
                let image = LayoutSnapshotTests.render(view, size: NSSize(width: 360, height: phase.height), appearance: appearance, scale: 2)
                try LayoutSnapshotTests.write(image, to: out.appendingPathComponent("panel-\(phase.name)-\(label).png"))
                sheet.append(("\(phase.name) · \(label)", image))
            }
        }

        let icons: [(String, StatusItemAppearance)] = [
            ("idle", StatusItemAppearance(dictationState: .idle)),
            ("recording", StatusItemAppearance(dictationState: .recording(RecordingState(jobID: JobID())))),
            ("processing", StatusItemAppearance(dictationState: .transcribing(JobID()))),
            ("attention", StatusItemAppearance(dictationState: .idle, needsAttention: true)),
            ("downloading", StatusItemAppearance(dictationState: .idle, needsAttention: true, downloadFraction: 0.42)),
        ]
        var iconImages: [(String, NSImage)] = []
        // Motion § 4·6 off Reduce Motion: the halo at full voice and in
        // silence (it must stay centred as it scales).
        let recording = StatusItemAppearance(dictationState: .recording(RecordingState(jobID: JobID())))
        let motion: [(String, StatusItemAppearance, Double?)] = icons.map { ($0.0, $0.1, nil) }
            + [("recording-loud", recording, 1), ("recording-silent", recording, 0)]
        for (name, appearance, level) in motion {
            let view = HStack(spacing: 0) {
                IconStrip(appearance: appearance, dark: false, box: Self.controllers, level: level)
                    .frame(width: 80, height: 44)
                    .background(Color(red: 0xEC / 255, green: 0xEC / 255, blue: 0xEF / 255))
                IconStrip(appearance: appearance, dark: true, box: Self.controllers, level: level)
                    .frame(width: 80, height: 44)
                    .background(Color(red: 0x23 / 255, green: 0x24 / 255, blue: 0x2A / 255))
            }
            .frame(width: 160, height: 44)
            let image = LayoutSnapshotTests.render(view, size: NSSize(width: 160, height: 44), appearance: .aqua, scale: 3)
            try LayoutSnapshotTests.write(image, to: out.appendingPathComponent("icon-\(name).png"))
            iconImages.append((name, image))
        }

        let contact = Self.contactSheet(panels: sheet, icons: iconImages)
        try LayoutSnapshotTests.write(contact, to: out.deletingLastPathComponent().appendingPathComponent("panel-contact-sheet.png"))
    }

    // MARK: Phases

    struct Phase {
        let name: String
        let header: StatusMenuHeaderContext
        let hud: HUDViewState
        let context: StatusPanelContext
        var height: CGFloat = 700
    }

    private static let last = StatusPanelContext.LastTranscription(
        text: "Let’s move the design review to Thursday and send the updated deck to Maya before Friday.",
        createdAt: now.addingTimeInterval(-125)
    )

    private static func context(
        readinessTitle: String = "Ready",
        isBlocked: Bool = false,
        fixTitle: String = "Fix in Permissions…",
        aiOn: Bool = true,
        canRecover: Bool = false,
        memory: StatusPanelContext.MemoryPressure? = nil,
        pausable: ModelID? = nil,
        last: StatusPanelContext.LastTranscription? = PanelSnapshotTests.last,
        idle: Bool = true,
        result: StatusPanelContext.JobResult? = nil
    ) -> StatusPanelContext {
        // As `updateStatusPanel()` builds it: AI off is the switch off with
        // the action and configuration still chosen; the switch and the
        // chips are enabled only while idle.
        let actions = ["Clean Up", "Polish", "Message", "Notes", "Translate"].enumerated().map { index, title in
            StatusPanelChoice(id: title, title: title, isSelected: index == 0, isEnabled: idle, command: .selectDefaultAction(UUID()))
        }
        var context = StatusPanelTests.context(
            readinessTitle: readinessTitle,
            isBlocked: isBlocked,
            fixTitle: fixTitle,
            ai: StatusPanelContext.AI(
                isOn: aiOn, canToggle: idle, help: nil,
                defaultActionName: "Clean Up", defaultActionBadge: "⌘1",
                configurationName: "Local Ollama",
                canChoose: idle,
                defaultActions: StatusPanelChooser(choices: actions),
                configurations: StatusPanelChooser(choices: [
                    StatusPanelChoice(id: "ollama", title: "Local Ollama", isSelected: true, isEnabled: idle, command: .selectConfiguration(UUID())),
                ])
            ),
            canRecoverFailedInsertion: canRecover,
            memoryPressure: memory
        )
        context.pausableDownload = pausable
        context.lastTranscription = last
        context.jobResult = result
        return context
    }

    private static let shortcut = "⌃⇧Space"

    static let phases: [Phase] = [
        Phase(name: "idle-ready", header: .init(shortcutGlyphs: shortcut), hud: .idle, context: context()),
        Phase(name: "idle-no-shortcut", header: .init(shortcutNote: "No Shortcut"), hud: .idle, context: context(last: nil)),
        Phase(name: "idle-ai-off", header: .init(shortcutGlyphs: shortcut), hud: .idle, context: context(aiOn: false)),
        Phase(
            name: "downloading",
            header: .init(modelReady: false, shortcutGlyphs: shortcut, attention: "Model not ready",
                          modelInstall: .init(modelName: "Whisper large-v3-turbo", fraction: 0.42)),
            hud: .idle,
            context: context(readinessTitle: "Model not ready", isBlocked: true, fixTitle: "Fix in Speech Models…", pausable: "whisper")
        ),
        Phase(
            name: "blocked-microphone",
            header: .init(shortcutGlyphs: shortcut, attention: "Microphone denied"),
            hud: .idle,
            context: context(readinessTitle: "Microphone denied", isBlocked: true)
        ),
        Phase(
            name: "memory-pressure",
            header: .init(shortcutGlyphs: shortcut),
            hud: .idle,
            context: context(memory: .init(canUnloadNow: true, isUnloading: false))
        ),
        Phase(
            name: "starting-mic",
            header: .init(dictationKind: .recording, shortcutGlyphs: shortcut),
            hud: HUDViewState(phase: .recording(HUDRecordingState(inputLevel: 0, elapsed: .zero, captureStarted: false))),
            context: context(idle: false)
        ),
        Phase(
            name: "recording",
            header: .init(dictationKind: .recording, shortcutGlyphs: shortcut),
            hud: HUDViewState(phase: .recording(HUDRecordingState(inputLevel: 0.7, elapsed: .seconds(7), captureStarted: true))),
            context: context(idle: false)
        ),
        Phase(
            name: "finishing-ai",
            header: .init(dictationKind: .processingAI),
            hud: HUDViewState(phase: .processingAI(HUDProcessingAIState(mode: .polish)), finishingCount: 1),
            context: context(idle: false)
        ),
        Phase(
            name: "inserted",
            header: .init(dictationKind: .completed),
            hud: HUDViewState(phase: .completed(HUDCompletionState(kind: .success))),
            context: context(idle: false, result: .init(text: "Let’s move the design review to Thursday and send the deck to Maya.", appName: "Notes"))
        ),
        Phase(
            name: "copied-to-clipboard",
            header: .init(dictationKind: .completed),
            hud: HUDViewState(phase: .completed(HUDCompletionState(kind: .clipboardFallback))),
            context: context(idle: false, result: .init(text: "ls -la", appName: "Terminal"))
        ),
        Phase(
            name: "not-inserted-kept",
            header: .init(dictationKind: .failed),
            hud: HUDViewState(
                phase: .failed(HUDFailureState(code: "insertionFailed", message: "The app lost focus before insertion.")),
                recoverableTranscript: "Let’s move the design review to Thursday and send the deck to Maya.",
                canRecoverFailedInsertion: true
            ),
            context: context(canRecover: true, idle: false)
        ),
    ]

    // MARK: Contact sheet

    /// The panels in a grid, light beside dark, each captioned, and the
    /// icon strips along the top — composed here so no image tool is needed.
    /// `tile` and `columns` default to the panel sheet's; the wizard sheet
    /// (`WizardSnapshotTests`) passes its own and no icons.
    static func contactSheet(
        panels: [(String, NSImage)],
        icons: [(String, NSImage)],
        tile: NSSize = NSSize(width: 360, height: 700),
        columns: Int = 6
    ) -> NSImage {
        let rows = Int((Double(panels.count) / Double(columns)).rounded(.up))
        let caption: CGFloat = 26
        let iconRow: CGFloat = icons.isEmpty ? 8 : 44 + caption + 16
        let size = NSSize(width: CGFloat(columns) * tile.width, height: iconRow + CGFloat(rows) * (tile.height + caption))
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(white: 0.96, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: 0x16 / 255, green: 0x1D / 255, blue: 0x33 / 255, alpha: 1),
        ]
        for (index, (name, icon)) in icons.enumerated() {
            let x = CGFloat(index) * 200 + 16
            let top = size.height - 8
            (name as NSString).draw(at: NSPoint(x: x, y: top - caption + 6), withAttributes: attributes)
            icon.draw(in: NSRect(x: x, y: top - caption - 44, width: 160, height: 44))
        }
        for (index, (name, panel)) in panels.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = CGFloat(column) * tile.width
            let top = size.height - iconRow - CGFloat(row) * (tile.height + caption)
            (name as NSString).draw(at: NSPoint(x: x + 20, y: top - caption + 6), withAttributes: attributes)
            let aspect = panel.size.height / max(panel.size.width, 1)
            let height = min(tile.height, tile.width * aspect)
            panel.draw(in: NSRect(x: x, y: top - caption - height, width: tile.width, height: height))
        }
        image.unlockFocus()
        return image
    }
}

/// A slice of a menu bar with the real `StatusItemIconController` drawing
/// the glyph, glow, badge and ring on an `NSButton`, in a light or a dark
/// bar. Reduce Motion is forced so the halo renders lit and still (0.8).
private struct IconStrip: NSViewRepresentable {
    let appearance: StatusItemAppearance
    let dark: Bool
    let box: PanelSnapshotTests.ControllerBox
    /// A level fed after the appearance, with Reduce Motion off; nil keeps
    /// Reduce Motion on (lit, still).
    var level: Double?

    private static var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Apps/KvoiceApp/Resources", isDirectory: true)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 44))
        container.wantsLayer = true
        container.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        container.layer?.backgroundColor = (dark
            ? NSColor(srgbRed: 0x23 / 255, green: 0x24 / 255, blue: 0x2A / 255, alpha: 1)
            : NSColor(srgbRed: 0xEC / 255, green: 0xEC / 255, blue: 0xEF / 255, alpha: 1)).cgColor
        let button = NSButton(frame: NSRect(x: 25, y: 10, width: 30, height: 24))
        button.contentTintColor = dark ? .white : .labelColor
        button.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        container.autoresizesSubviews = true
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        container.addSubview(button)
        let glyph = StatusItemArtwork.templateImage(contentsOf: Self.resources.appendingPathComponent("MenuBarLogo.svg"))
        let controller = StatusItemIconController(button: button, glyph: glyph)
        controller.reduceMotion = { level == nil }
        controller.apply(appearance)
        if let level {
            for _ in 0..<40 {
                controller.apply(level: level)
            }
        }
        box.items.append(controller)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
