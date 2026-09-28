import AppKit
import SwiftUI
import XCTest
import KvoiceDomain
@testable import KvoiceUI

/// Opt-in offscreen renders of every main-window section at several window
/// sizes, for a layout audit without a screen: set
/// `KVOICE_LAYOUT_SNAPSHOTS=/some/dir` and the PNGs land there. Skipped
/// otherwise, so the suite stays fast. Nothing is asserted about pixels —
/// the images are for a human (or a tool that reads images) to look at.
/// Found the 2026-09-14 detail-column overflow (see `MainWindowView`).
/// Offscreen quirks to ignore are listed in `Docs/Design/README.md` (the
/// harness artifacts: materials, glass, the sidebar highlight, the title
/// bar); nested split views (History) may render blank.
@MainActor
final class LayoutSnapshotTests: XCTestCase {
    /// Windows stay alive until the process exits: releasing a hosting
    /// window mid-test crashed AppKit at teardown.
    static var windows: [NSWindow] = []

    func testRenderEverySectionAtSeveralSizes() throws {
        guard let directory = ProcessInfo.processInfo.environment["KVOICE_LAYOUT_SNAPSHOTS"] else {
            throw XCTSkip("Set KVOICE_LAYOUT_SNAPSHOTS=<dir> to render layout snapshots")
        }
        let outputURL = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let sizes: [(String, NSSize)] = [
            ("820x540", NSSize(width: 820, height: 540)),
            ("720x480", NSSize(width: 720, height: 480)),
            ("1000x700", NSSize(width: 1000, height: 700)),
        ]
        for section in MainWindowSection.allCases {
            for (label, size) in sizes {
                let model = MainWindowModel(selection: section)
                let view = MainWindowView(model: model) { section in
                    Self.content(for: section)
                }
                let image = Self.render(view, size: size, hostInController: section != .history)
                let fileURL = outputURL.appendingPathComponent("\(section.rawValue)-\(label).png")
                try Self.write(image, to: fileURL)
            }
        }
    }

    /// ADR-022 slice 5: the Recording page with every section changed from
    /// default (the `SettingsResetRow` affordance visible) beside the plain
    /// page rendered by `testRenderEverySectionAtSeveralSizes`:
    /// `recording-changed-820x540.png`.
    func testRenderRecordingSectionChangedFromDefault() throws {
        guard let directory = ProcessInfo.processInfo.environment["KVOICE_LAYOUT_SNAPSHOTS"] else {
            throw XCTSkip("Set KVOICE_LAYOUT_SNAPSHOTS=<dir> to render layout snapshots")
        }
        let outputURL = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        var settings = AppSettings()
        settings.shortcut = GeneralSettingsViewModel.recommendedShortcut
        settings.maxRecordingSeconds = 1_800
        settings.recorderStyle = .notch
        settings.recordingFeedback.cueSet = .systemClassic
        settings.automaticTextFormatting = true
        // One host, shared with `general`, like the real shell: `SettingsResetRow`
        // now reads `general.host.effective` directly (ADR-022 slice 7 part B).
        let host = SettingsProjectionHost.detached(settings: settings)
        let triggers = TriggerSettingsViewModel(host: host)
        triggers.previewCue = { _ in }
        let general = GeneralSettingsViewModel(host: host)
        let model = MainWindowModel(selection: .recording)
        let view = MainWindowView(model: model) { _ in
            AnyView(RecordingSectionView(
                general: general,
                options: triggers.recordingOptionBindings
            ))
        }
        let image = Self.render(view, size: NSSize(width: 820, height: 540))
        try Self.write(image, to: outputURL.appendingPathComponent("recording-changed-820x540.png"))
    }

    /// The recording HUD before and after the first buffer with signal
    /// (2026-09-16), in both recorder styles: `hud-<style>-<state>.png`.
    func testRenderRecordingHUDStartingAndLive() throws {
        guard let directory = ProcessInfo.processInfo.environment["KVOICE_LAYOUT_SNAPSHOTS"] else {
            throw XCTSkip("Set KVOICE_LAYOUT_SNAPSHOTS=<dir> to render layout snapshots")
        }
        let outputURL = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let ai = HUDAIIndicator(isEnabled: true, actionName: "Polish", shortcutBadge: "⌘1")
        let states: [(String, HUDViewState)] = [
            ("starting", HUDViewState(phase: .recording(HUDRecordingState(mode: .pushToTalk, ai: ai, captureStarted: false)))),
            ("live", HUDViewState(phase: .recording(HUDRecordingState(inputLevel: 0.6, elapsed: .seconds(7), mode: .pushToTalk, ai: ai))))
        ]
        for style in [HUDStyle.mini, .notch] {
            for (label, state) in states {
                let view = HUDView(state: state, style: style, notchWidth: 420)
                    .padding(24)
                    .frame(width: 520, height: 140)
                let image = Self.render(view, size: NSSize(width: 520, height: 140))
                try Self.write(image, to: outputURL.appendingPathComponent("hud-\(style == .mini ? "mini" : "notch")-\(label).png"))
            }
        }
    }

    static func content(for section: MainWindowSection) -> AnyView {
        switch section {
        case .history:
            return AnyView(HistoryView(viewModel: HistoryViewModel(
                repository: PreviewHistoryRepository()
            )))
        case .aiActions:
            return AnyView(AIActionsSectionView(ai: .previewConfigured(), modes: .previewSeeded()))
        case .models:
            return AnyView(ModelSettingsView(viewModel: ModelSettingsViewModel()))
        case .permissions:
            return AnyView(PermissionsSectionView(general: GeneralSettingsView.previewModel(withShortcut: true)))
        case .dictionary:
            return AnyView(DictionarySectionView(model: DictionaryViewModel()))
        case .audioInput:
            return AnyView(AudioInputSectionView())
        case .shortcuts:
            return AnyView(ShortcutsSectionView(general: GeneralSettingsView.previewModel(withShortcut: true)))
        case .recording:
            // Bound to a live model so the sound picker and Preview render
            // enabled, as they do in the app.
            let triggers = TriggerSettingsViewModel()
            triggers.previewCue = { _ in }
            return AnyView(RecordingSectionView(
                general: GeneralSettingsView.previewModel(withShortcut: true),
                options: triggers.recordingOptionBindings
            ))
        case .dataPrivacy:
            return AnyView(DataPrivacySectionView(
                history: HistoryViewModel(repository: PreviewHistoryRepository()),
                privacy: PrivacyAboutViewModel(appVersion: "0.1.0", buildNumber: "12", copyToPasteboard: { _ in })
            ))
        case .general:
            return AnyView(GeneralSectionView(viewModel: GeneralSettingsView.previewModel(withShortcut: true)))
        case .help:
            return AnyView(HelpSectionView(viewModel: HelpViewModel(openURL: { _ in true })))
        }
    }

    /// Renders `view` in an offscreen window at `size` (points), at 1× so
    /// the PNGs stay small enough to commit. `appearance` picks light or
    /// dark; `DesignGalleryTests` renders both. Kept internal so the gallery
    /// test reuses the same window setup and the two galleries never drift.
    static func render<V: View>(
        _ view: V,
        size: NSSize,
        appearance: NSAppearance.Name = .darkAqua,
        hostInController: Bool = true,
        scale: CGFloat = 1
    ) -> NSImage {
        let window: NSWindow
        let hosting: NSView
        if hostInController {
            // NSHostingController in a real window, like MainWindowController:
            // the sidebar's vibrant list only draws offscreen when the window
            // owns a content view controller (an NSHostingView alone leaves
            // the sidebar blank).
            let controller = NSHostingController(rootView: view)
            // Like MainWindowController: the window owns the size, SwiftUI's
            // ideal size must not grow it.
            controller.sizingOptions = []
            window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .resizable, .fullSizeContentView]
            hosting = controller.view
        } else {
            // The History section's nested split view throws inside AppKit
            // layout when hosted through a controller offscreen (SIGTRAP in
            // `_crashOnException`), so it keeps the plain hosting view and
            // renders without the sidebar.
            let hostingView = NSHostingView(rootView: view)
            hostingView.sizingOptions = []
            window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            hosting = hostingView
        }
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI settle its first layout pass.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        hosting.layoutSubtreeIfNeeded()
        let image = capture(hosting, window: window, size: size, scale: scale)
        window.orderOut(nil)
        windows.append(window)
        return image
    }

    /// Renders `view` once at `sizes.first`, then — without recreating the
    /// window — resizes the *same* hosting view/window through the rest of
    /// `sizes` in order and captures after each resize. `render(_:size:...)`
    /// creates a fresh window per size, which never exercises whatever a
    /// `NavigationSplitView` does when an *already-laid-out* column
    /// configuration is asked to relayout narrower — the 2026-09-16 History
    /// list-disappears-on-resize report only reproduces this way, not at any
    /// single fixed size. `hostInController` is always false: History's
    /// nested split view is the only caller and cannot be hosted through a
    /// controller offscreen (see `render`).
    static func renderResizeSequence<V: View>(
        _ view: V,
        sizes: [NSSize],
        appearance: NSAppearance.Name = .darkAqua
    ) -> [NSImage] {
        precondition(!sizes.isEmpty)
        let hostingView = NSHostingView(rootView: view)
        hostingView.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: sizes[0]),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false

        var images: [NSImage] = []
        for (index, size) in sizes.enumerated() {
            window.setContentSize(size)
            hostingView.frame = NSRect(origin: .zero, size: size)
            hostingView.layoutSubtreeIfNeeded()
            // The first size gets the same 0.3 s settle as `render`; a resize
            // is user-driven and AppKit/SwiftUI relayout synchronously, so a
            // short pass is enough and keeps the sequence fast.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: index == 0 ? 0.3 : 0.05))
            hostingView.layoutSubtreeIfNeeded()
            images.append(capture(hostingView, window: window, size: size))
        }
        window.orderOut(nil)
        windows.append(window)
        return images
    }

    /// The bitmap capture shared by `render` and `renderResizeSequence`:
    /// draws `hosting` at `size` into a 1× opaque bitmap flattened onto the
    /// window's own background (see the inline notes below for why it is
    /// flattened rather than composited with alpha).
    private static func capture(_ hosting: NSView, window: NSWindow, size: NSSize, scale: CGFloat = 1) -> NSImage {
        // A 1× rep, not `bitmapImageRepForCachingDisplay` (which follows the
        // main screen's 2× backing and doubles every file). `scale` 2 is for
        // the store screenshots (`StoreScreenshotTests`) only.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        // Flatten onto the window background: `cacheDisplay` leaves the
        // vibrant sidebar partly transparent, and that alpha gradient made
        // every main-window PNG ~110 KB; opaque, the same image is ~10 KB.
        let opaque = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            // 32-bit XRGB: a packed 24-bit rep is not a drawable context.
            bitsPerPixel: 32
        )!
        opaque.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: opaque)
        // Fill with the window background resolved under the window's
        // appearance, then composite the render *over* it: `draw(in:)`
        // alone copies, which replaced the fill with the render's
        // transparent pixels and made every uncovered region — the vibrant
        // sidebar, a material, the title-bar strip — a black artifact in the
        // 2026-09-16 galleries. Light flattens onto white, dark onto the
        // dark window grey.
        window.appearance?.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        rep.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: nil
        )
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(opaque)
        return image
    }

    static func write(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "LayoutSnapshot", code: 1)
        }
        try png.write(to: url)
    }
}
