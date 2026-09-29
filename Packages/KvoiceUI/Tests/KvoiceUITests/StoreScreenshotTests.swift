import AppKit
import SwiftUI
import XCTest
import KvoiceDomain
@testable import KvoiceUI

/// The Mac App Store screenshots, the public README's copies of them, and
/// the README banner, rendered from the real views through
/// `LayoutSnapshotTests.render` — the App Store edition's pages, a caption
/// above each, in the app icon's palette (ink, orange, blue; the colours are
/// listed in `Apps/KvoiceApp/Resources/AppIcon.svg`). Opt-in like the design
/// gallery: set
/// `KVOICE_STORE_SCREENSHOTS=<dir>` (normally the repository's `Public`
/// folder, as an absolute path) and the files land in
///
/// - `<dir>/appstore/screenshots/en-US/kvoice-<n>-<name>.jpg` — 2880×1800,
///   a size App Store Connect accepts for macOS;
/// - `<dir>/Docs/assets/screenshots/kvoice-<n>-<name>.jpg` — 1440×900 for
///   the README;
/// - `<dir>/Docs/assets/kvoice-banner.jpg` — 1280×640, the README's hero;
/// - `<dir>/Docs/assets/social-preview.png` — 1280×640, the GitHub social
///   preview (uploaded by hand in the repository's settings; a PNG because
///   GitHub recompresses it).
///
/// Run `./Scripts/make_app_icon.sh` first after an icon change: the banner
/// and the social preview draw `Docs/assets/kvoice-icon.png`.
///
/// Skipped otherwise, so the suite stays fast. The harness's limits
/// (`Docs/Design/README.md`) apply: no materials, toggles draw off; the
/// pages are shown without the sidebar, whose offscreen selection draws
/// black. Nothing here is personal: every value is a fixture.
@MainActor
final class StoreScreenshotTests: XCTestCase {
    private static let canvas = NSSize(width: 1440, height: 900)
    private static let banner = NSSize(width: 1280, height: 640)

    private func root() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["KVOICE_STORE_SCREENSHOTS"] else {
            throw XCTSkip("Set KVOICE_STORE_SCREENSHOTS=<dir> to render the store screenshots")
        }
        return URL(fileURLWithPath: directory, isDirectory: true)
    }

    func testRenderStoreScreenshotsAndBanner() throws {
        let root = try root()
        let store = root.appendingPathComponent("appstore/screenshots/en-US", isDirectory: true)
        let readme = root.appendingPathComponent("Docs/assets/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readme, withIntermediateDirectories: true)

        let shots: [(String, LocalizedStringKey, LocalizedStringKey, AnyView)] = [
            (
                "1-dictate",
                "Hold a key. Speak. It's typed.",
                "Your words, cleaned up by AI if you like, typed into the app you are already using.",
                AnyView(DictationScene())
            ),
            (
                // The Actions list only: the AI Actions page's configuration
                // footer names Private Cloud Compute, which no build offers yet.
                "2-ai-actions",
                "Speak once. Get an email, a translation, notes.",
                "Thirteen AI actions turn what you said into finished text: polish, message, TODO list, summary, Q&A and more.",
                AnyView(StoreWindowFrame(title: "AI Actions") {
                    PromptModeSettingsView(viewModel: .previewSeeded())
                })
            ),
            (
                "3-models",
                "Speech recognition on your Mac",
                "Whisper, Parakeet, Apple Speech and more. Works offline once a model is installed.",
                AnyView(StoreWindowFrame(title: "Speech Models") { DesignGalleryTests.seededModelsSection() })
            ),
            (
                "4-private",
                "Private by design",
                "Your voice stays on your Mac. No account, no analytics, no tracking.",
                AnyView(StoreWindowFrame(title: "Welcome to KVoice") {
                    OnboardingView(viewModel: OnboardingViewModel(edition: .appStore))
                })
            ),
        ]
        for (name, caption, subtitle, content) in shots {
            let view = StoreShot(caption: caption, subtitle: subtitle) { content }
            try Self.writeJPEG(
                LayoutSnapshotTests.render(view, size: Self.canvas, appearance: .aqua, scale: 2),
                to: store.appendingPathComponent("kvoice-\(name).jpg")
            )
            try Self.writeJPEG(
                LayoutSnapshotTests.render(view, size: Self.canvas, appearance: .aqua),
                to: readme.appendingPathComponent("kvoice-\(name).jpg")
            )
        }

        let icon = try XCTUnwrap(NSImage(contentsOf: Self.repositoryRoot.appendingPathComponent("Docs/assets/kvoice-icon.png")))
        // JPEG: the gradient makes a PNG of this size about 600 KB.
        try Self.writeJPEG(
            LayoutSnapshotTests.render(StoreBanner(icon: icon), size: Self.banner, appearance: .aqua),
            to: root.appendingPathComponent("Docs/assets/kvoice-banner.jpg")
        )
        try Self.writePNG(
            LayoutSnapshotTests.render(SocialPreview(icon: icon), size: Self.banner, appearance: .aqua),
            to: root.appendingPathComponent("Docs/assets/social-preview.png")
        )
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "StoreScreenshot", code: 2)
        }
        try png.write(to: url)
    }

    /// `Packages/KvoiceUI/Tests/KvoiceUITests/<this file>` → the repository.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func writeJPEG(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw NSError(domain: "StoreScreenshot", code: 1)
        }
        try jpeg.write(to: url)
    }
}

// MARK: - Composition

/// The app icon's palette (AppIcon.svg): the ink tile, the orange of the
/// sound waves and the blue of the text cursor.
private let inkTop = Color(red: 0x26 / 255, green: 0x30 / 255, blue: 0x4F / 255)
private let inkBottom = Color(red: 0x0C / 255, green: 0x10 / 255, blue: 0x22 / 255)
private let waveLight = Color(red: 0xFF / 255, green: 0xB0 / 255, blue: 0x2E / 255)
private let waveDeep = Color(red: 0xFF / 255, green: 0x6A / 255, blue: 0x2B / 255)
private let cursorBlue = Color(red: 0x3D / 255, green: 0x8B / 255, blue: 0xFF / 255)

/// The ink gradient with a warm orange glow low on the left and a cool blue
/// one high on the right: the icon's colours, spread across a page.
private struct BrandBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(colors: [inkTop, inkBottom], startPoint: .top, endPoint: .bottom)
                RadialGradient(
                    colors: [waveDeep.opacity(0.30), waveDeep.opacity(0)],
                    center: UnitPoint(x: 0.08, y: 0.95),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.45
                )
                RadialGradient(
                    colors: [cursorBlue.opacity(0.30), cursorBlue.opacity(0)],
                    center: UnitPoint(x: 0.95, y: 0.02),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.5
                )
            }
        }
    }
}

/// The app icon with a soft light behind it, so the ink tile stands off the
/// ink background instead of sinking into it.
private struct HaloedIcon: View {
    let icon: NSImage
    let side: CGFloat

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color(red: 0.55, green: 0.66, blue: 1).opacity(0.42), .clear],
                center: .center,
                startRadius: side * 0.2,
                endRadius: side * 0.62
            )
            .frame(width: side * 1.4, height: side * 1.4)
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
        }
        .frame(width: side, height: side)
    }
}

/// A short orange-to-blue rule, the accent above each caption.
private struct AccentRule: View {
    var width: CGFloat = 72

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [waveLight, waveDeep, cursorBlue], startPoint: .leading, endPoint: .trailing))
            .frame(width: width, height: 6)
    }
}

/// One store screenshot: caption and subtitle over the brand gradient, the
/// app content below.
private struct StoreShot<Content: View>: View {
    let caption: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            BrandBackdrop()
            VStack(spacing: 14) {
                AccentRule()
                    .padding(.bottom, 4)
                Text(caption)
                    .font(.system(size: 50, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                content()
                    .frame(width: 1120, height: 640)
                    .padding(.top, 22)
            }
            .padding(.top, 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .light)
    }
}

/// A plain window around a page: a title bar with the three window
/// buttons and the page's name, rounded corners and a shadow. The real
/// window has a sidebar, which does not render cleanly offscreen.
private struct StoreWindowFrame<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.26)).frame(width: 12, height: 12)
                    Spacer()
                }
                .padding(.leading, 14)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 36)
            .background(Color(white: 0.965))
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.black.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
    }
}

/// The first screenshot: a document being dictated into, under a menu bar
/// with the Notch recorder (the one recorder style that renders offscreen
/// as it looks on screen) showing the live transcript.
private struct DictationScene: View {
    private let typed = "Notes from Tuesday: the beta goes out on Friday, the release notes are nearly done, and we"
    private let partial = "should ship the menu bar work first and then look at the onboarding copy"

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Rectangle().fill(Color.black.opacity(0.88)).frame(height: 28)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 190, height: 34)
            }
            ZStack(alignment: .top) {
                document
                    .padding(.horizontal, 90)
                    .padding(.top, 70)
                HUDView(
                    state: HUDViewState(
                        phase: .recording(HUDRecordingState(
                            inputLevel: 0.55,
                            elapsed: .seconds(9),
                            mode: .pushToTalk,
                            ai: HUDAIIndicator(isEnabled: true, actionName: "Clean Up", shortcutBadge: "⌘1")
                        )),
                        partialTranscript: partial
                    ),
                    style: .notch,
                    notchWidth: 560
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // Behind the notch's overhang too, not only under the document.
        .background(Color(white: 0.93))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
    }

    private var document: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "Weekly sync")
                .font(.system(size: 26, weight: .bold))
            (
                Text(verbatim: typed)
                    .font(.system(size: 19))
                + Text(verbatim: " |")
                    .font(.system(size: 19, weight: .light))
                    .foregroundColor(.accentColor)
            )
            .lineSpacing(6)
            ForEach(0..<9, id: \.self) { index in
                Capsule()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: CGFloat(520 + (index * 97) % 300), height: 12)
            }
        }
        .foregroundStyle(Color(white: 0.12))
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

/// The README banner: the icon, the name, the one-line pitch and three
/// facts, in the icon's palette.
private struct StoreBanner: View {
    let icon: NSImage

    var body: some View {
        ZStack {
            BrandBackdrop()
            HStack(spacing: 40) {
                HaloedIcon(icon: icon, side: 320)
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: "KVoice")
                        .font(.system(size: 84, weight: .bold, design: .rounded))
                    AccentRule(width: 96)
                    Headline(size: 40)
                    Text(verbatim: "Polished, summarized or translated, typed where your cursor is.")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        BrandChip(text: "Dictation + AI actions", tint: waveDeep)
                        BrandChip(text: "On-device speech", tint: cursorBlue)
                        BrandChip(text: "Free & open source", tint: .white)
                    }
                    .padding(.top, 6)
                }
                .foregroundStyle(.white)
                .frame(width: 760, alignment: .leading)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}

/// "Speak once. Get finished text in any app." with "finished text" in the
/// waves' orange.
private struct Headline: View {
    let size: CGFloat

    var body: some View {
        (
            Text(verbatim: "Speak once. Get ")
            + Text(verbatim: "finished text").foregroundColor(waveLight)
            + Text(verbatim: " in any app.")
        )
        .font(.system(size: size, weight: .semibold, design: .rounded))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A fact in a capsule, outlined in one of the icon's colours.
private struct BrandChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 19, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.55), lineWidth: 1.5))
    }
}

/// The GitHub social preview (1280×640): centred, with a wide margin,
/// because GitHub crops the edges in some places it shows the card.
private struct SocialPreview: View {
    let icon: NSImage

    var body: some View {
        ZStack {
            BrandBackdrop()
            VStack(spacing: 20) {
                HStack(spacing: 26) {
                    HaloedIcon(icon: icon, side: 190)
                    Text(verbatim: "KVoice")
                        .font(.system(size: 104, weight: .bold, design: .rounded))
                }
                Headline(size: 46)
                AccentRule(width: 120)
                    .padding(.vertical, 4)
                Text(verbatim: "Dictation + AI actions for the Mac  ·  On-device speech  ·  Free & open source")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .foregroundStyle(.white)
            .padding(60)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}
