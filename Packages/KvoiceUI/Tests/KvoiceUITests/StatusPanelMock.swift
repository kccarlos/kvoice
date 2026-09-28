import SwiftUI

/// A **mock**, not product code — and since P-D4 landed the same day, the
/// **spec** the product panel was built from: these renders were reviewed and
/// approved, and `StatusPanelView` (KvoiceUI) is this shape
/// made real over `StatusPanelModel`. Kept so the gallery can still render
/// the approved design next to the real one (`Docs/Design/mock/` vs
/// `Docs/Design/after/panel-*`); nothing in the app references it.
///
/// Origin: the Control-Center-style status panel the 2026-09-16 design
/// review proposed for the menu-bar drop-down
/// (`Docs/Design/Design-Review-2026-09-16.md`, "The drop-down decision").
/// It lives in the test target so `DesignGalleryTests` can render it into
/// `Docs/Design/mock/` through the offscreen harness; nothing in the app
/// references it. Static data only — no view model, no settings, no shell.
///
/// The shape follows macOS's Control Center *Sound* module, which was
/// named as the reference: a titled glass panel, one primary control at the
/// top, icon-led rows with a value and a chevron for detail, a section of
/// switches, and "… Settings…" at the foot. Every item the `NSMenu` shows
/// today is present somewhere in it (nothing is removed), so the comparison
/// in the review is row-for-row.
struct StatusPanelMock: View {
    /// Idle (no meter — the microphone is closed), recording (meter + clock),
    /// downloading a model (progress replaces the meter row), blocked
    /// (readiness line names the fix). Review 2026-09-16.
    enum Phase { case idle, recording, downloading, blocked }

    let phase: Phase

    static let panelWidth: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            primaryBlock
            sectionDivider
            dictationSection
            sectionDivider
            aiSection
            sectionDivider
            footBlock
        }
        .frame(width: Self.panelWidth)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
    }

    // MARK: Primary block — the "slider" of the Sound module

    /// Start/Stop Recording as the one prominent control, the shortcut
    /// beside it as key glyphs (a menu shows key equivalents the same way),
    /// the readiness line under it, and a live input meter.
    private var primaryBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(phase == .recording ? Color.red : (phase == .blocked ? Color.secondary : Color.accentColor))
                        .frame(width: 30, height: 30)
                    Image(systemName: phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(phase == .recording ? "Stop Recording" : "Start Recording")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(phase == .blocked ? .secondary : .primary)
                    Text(readinessLine)
                        .font(.system(size: 11))
                        .foregroundStyle(phase == .blocked ? Color.orange : Color.secondary)
                }
                Spacer(minLength: 0)
                KeyGlyphs(["⌃", "⇧", "Space"])
            }
            // The meter exists only while a job is recording — the microphone
            // is never open otherwise (product rule 2026-09-16). While a model
            // downloads, its progress takes the row instead.
            if phase == .recording {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    LevelBar(level: 0.62)
                    Text("0:07")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if phase == .downloading {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    LevelBar(level: 0.42)
                    Text("Downloading Nemotron… 42 %")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if phase == .recording {
                HStack(spacing: 8) {
                    rowIcon("xmark.circle", tint: .secondary)
                    Text("Cancel Dictation")
                        .font(.system(size: 13))
                    Spacer()
                    KeyGlyphs(["esc"])
                }
                .padding(.vertical, 2)
            } else if phase == .blocked {
                HStack(spacing: 8) {
                    rowIcon("wrench.and.screwdriver", tint: .orange)
                    Text("Fix in Speech Models…")
                        .font(.system(size: 13))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            } else {
                // Request: Copy Last Transcription stays reachable here.
                HStack(spacing: 8) {
                    rowIcon("doc.on.doc", tint: .secondary)
                    Text("Copy Last Transcription")
                        .font(.system(size: 13))
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var readinessLine: String {
        switch phase {
        case .idle: return "Ready · Whisper v3 Turbo"
        case .recording: return "Recording · MacBook Pro Microphone"
        case .downloading: return "Ready · Whisper v3 Turbo"
        case .blocked: return "Model not ready"
        }
    }

    // MARK: Dictation rows — the "Output" device rows

    private var dictationSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Dictation")
            detailRow("waveform", "Model", value: "Whisper large-v3-turbo")
            detailRow("globe", "Language", value: "Auto-detect")
            detailRow("mic", "Microphone", value: "MacBook Pro Microphone")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    // MARK: AI rows — the switch

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("AI")
            HStack(spacing: 10) {
                rowIcon("sparkles", tint: .accentColor)
                Text("Use AI Actions")
                    .font(.system(size: 13))
                Spacer()
                Toggle("AI Actions", isOn: .constant(true))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            detailRow("text.badge.checkmark", "Default Action", value: "Polish  ⌘1")
            detailRow("server.rack", "Configuration", value: "Local Ollama")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    // MARK: Foot — "Sound Settings…"

    private var footBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Request: every App-group command visible, no submenu.
            footRow("History", shortcut: "⌘H")
            footRow("Settings…", shortcut: "⌘,")
            footRow("Setup Guide…", shortcut: "")
            footRow("Help", shortcut: "")
            footRow("About", shortcut: "")
            footRow("Quit kvoice", shortcut: "⌘Q")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    // MARK: Pieces

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
    }

    private func rowIcon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
            .background(tint.opacity(0.12), in: Circle())
    }

    private func detailRow(_ symbol: String, _ title: String, value: String) -> some View {
        HStack(spacing: 10) {
            rowIcon(symbol, tint: .primary)
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func footRow(_ title: String, shortcut: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Text(shortcut)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }

    /// The product panel would use Liquid Glass on macOS 26 and later
    /// (`glassEffect(.regular, in:)`) and the regular material below it.
    /// The offscreen harness cannot composite either against a real
    /// desktop — glass renders fully transparent and a material only
    /// partly — so the mock draws the material over a window-colour wash,
    /// which is what both look like at rest over a flat desktop.
    private var panelBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.72)
            Rectangle().fill(.regularMaterial)
        }
    }
}

/// The mock's card — the window-colour wash, the material, the 22 pt
/// clip, the hairline and the shadow — around any content, so the gallery
/// can draw the real `StatusPanelView` (hosted chrome, no background of
/// its own: the `NSPopover` draws it in the app) the way the mock drew
/// itself. Neither Liquid Glass nor the popover's material composites
/// offscreen; glass flattens the colours inside it too, so the product's
/// standalone chrome is not used for renders.
struct MockPanelCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background {
                ZStack {
                    Color(nsColor: .windowBackgroundColor).opacity(0.72)
                    Rectangle().fill(.regularMaterial)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
    }
}

/// Key-cap glyphs for a shortcut, the way Control Center and menus show
/// key equivalents: tertiary, small, never a control.
private struct KeyGlyphs: View {
    let keys: [String]
    init(_ keys: [String]) { self.keys = keys }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
    }
}

/// A slim horizontal level bar — the module's slider, read-only.
private struct LevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Color.accentColor).frame(width: proxy.size.width * level)
            }
        }
        .frame(height: 6)
    }
}

/// A stand-in for the desktop under the panel, so the material and the
/// glass have something to blur in the offscreen render.
struct MockDesktopBackdrop: View {
    var body: some View {
        // Flat, not a gradient: a gradient makes the PNG several times
        // larger for no review value.
        Color(red: 0.56, green: 0.64, blue: 0.82)
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<14, id: \.self) { index in
                    Capsule()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: CGFloat(120 + (index * 37) % 260), height: 8)
                }
            }
            .padding(24)
        }
    }
}
