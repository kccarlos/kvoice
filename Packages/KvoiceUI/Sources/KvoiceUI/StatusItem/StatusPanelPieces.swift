import SwiftUI
import KvoiceDomain

// The status panel's drawn pieces (split from `StatusPanelView.swift`,
// Q2b): the panel chrome, the row / card / chip / link button styles, the
// flow layout, the key caps, the finishing badge, the primary glyph, the
// level bars and the download track. Panel-scoped — nothing outside the
// panel uses them; `KvoiceUI/Design/` holds the shared components.

extension View {
    /// `help(_:)` only when there is a tooltip — the menu's `toolTip`.
    @ViewBuilder
    func panelHelp(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            self.help(Text(verbatim: text))
        } else {
            self
        }
    }
}

// MARK: - Chrome

/// The panel's ground per host; see `StatusPanelView.Chrome`. The design's
/// panel is solid (`--panel`), not a material: the same in front of any
/// wallpaper, so Reduce Transparency changes nothing. Increase Contrast
/// strengthens the edge.
struct PanelChrome: ViewModifier {
    let chrome: StatusPanelView.Chrome
    let increasedContrast: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: StatusPanelView.cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        switch chrome {
        case .hosted:
            content
        case .standalone:
            content
                .background(PanelColor.panel, in: shape)
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(increasedContrast ? Color.primary.opacity(0.6) : PanelColor.edge, lineWidth: increasedContrast ? 1 : 0.5)
                }
        }
    }
}

// MARK: - Row style

/// A Control Center row: flat, with a rounded highlight under the pointer
/// and a stronger one while pressed or focused. A visible edge under
/// Increase Contrast.
struct PanelRowButtonStyle: ButtonStyle {
    /// Negative to let the highlight bleed past the row's own padding (the
    /// primary control sits in a wider block).
    var inset: CGFloat = 0
    var horizontalPadding: CGFloat = 6
    var verticalPadding: CGFloat = 5
    var dimsWhenDisabled = true
    /// 7 for the value rows, 6 for the foot rows (the design's radii).
    var radius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        PanelRowBody(configuration: configuration, inset: inset, horizontalPadding: horizontalPadding, verticalPadding: verticalPadding, dimsWhenDisabled: dimsWhenDisabled, radius: radius)
    }

    private struct PanelRowBody: View {
        let configuration: Configuration
        let inset: CGFloat
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        let dimsWhenDisabled: Bool
        let radius: CGFloat
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            configuration.label
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(fill)
                        .padding(inset)
                }
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color.kv.cursor.opacity(0.9), lineWidth: 2)
                            .padding(inset)
                    }
                }
                .opacity(isEnabled || !dimsWhenDisabled ? 1 : 0.55)
                .onHover { hovered = $0 && isEnabled }
                // Motion: presses answer in 120 ms.
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }

        private var fill: Color {
            let base = contrast == .increased ? 0.22 : 0.07
            if configuration.isPressed { return Color.primary.opacity(base + 0.08) }
            if hovered { return Color.primary.opacity(base) }
            return .clear
        }
    }
}

/// UI v2 card button: 26 pt, radius 7, 12 pt (the last transcription's
/// compact one: 24 pt, radius 6, 11 pt). Primary is the cursor fill with
/// white words, warn the warn-soft fill with warn ink, plain an outlined
/// surface button. Drawn rather than `.borderedProminent`, which greys out
/// in a panel that is not key.
struct CardButtonStyle: ButtonStyle {
    let emphasis: StatusPanelState.Row.Emphasis
    var compact = false
    let increasedContrast: Bool

    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, emphasis: emphasis, compact: compact, increasedContrast: increasedContrast)
    }

    private struct CardBody: View {
        let configuration: Configuration
        let emphasis: StatusPanelState.Row.Emphasis
        let compact: Bool
        let increasedContrast: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous)
            configuration.label
                .font(.system(size: compact ? 11 : 12, weight: emphasis == .plain ? .regular : .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, compact ? 9 : 10)
                .frame(height: compact ? 24 : 26)
                .background(background, in: shape)
                .overlay {
                    if emphasis == .plain {
                        shape.strokeBorder(increasedContrast ? Color.primary.opacity(0.6) : Color.kv.line, lineWidth: 1)
                    }
                }
                .overlay {
                    if isFocused {
                        shape.strokeBorder(Color.kv.cursor, lineWidth: 2).padding(-2)
                    }
                }
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .contentShape(shape)
                .fixedSize()
        }

        private var foreground: Color {
            switch emphasis {
            case .primary: return .white
            case .warn: return Color.kv.warnInk
            case .plain: return Color.kv.text
            }
        }

        private var background: Color {
            switch emphasis {
            case .primary: return Color.kv.cursor
            case .warn: return Color.kv.warnSoft
            case .plain: return PanelColor.surface
            }
        }
    }
}

/// UI v2 action chip: a 26 pt capsule. Lit — what the next dictation will
/// do — is the cursor fill with white semibold words; an action that is
/// not lit sits on the neutral fill; Off while AI is on is the design's
/// dashed outline with secondary words.
struct ChipButtonStyle: ButtonStyle {
    enum Kind {
        case lit
        case plain
        case off
    }

    let kind: Kind
    let increasedContrast: Bool

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, kind: kind, increasedContrast: increasedContrast)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let kind: Kind
        let increasedContrast: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let shape = Capsule(style: .continuous)
            configuration.label
                .font(.system(size: 12, weight: kind == .lit ? .semibold : .regular))
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(background, in: shape)
                .overlay {
                    if kind == .off {
                        shape.strokeBorder(
                            increasedContrast ? Color.primary.opacity(0.6) : Color.kv.line,
                            style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                        )
                    } else if increasedContrast && kind == .plain {
                        shape.strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
                    }
                }
                .overlay {
                    if isFocused {
                        shape.strokeBorder(Color.kv.cursor, lineWidth: 2).padding(-2)
                    }
                }
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeInOut(duration: 0.2), value: kind)
                .contentShape(shape)
                .fixedSize()
        }

        private var foreground: Color {
            switch kind {
            case .lit: return .white
            case .plain: return Color.kv.text
            case .off: return Color.kv.text2
            }
        }

        private var background: Color {
            switch kind {
            case .lit: return Color.kv.cursor
            case .plain: return PanelColor.fill
            case .off: return .clear
            }
        }
    }
}

/// A text link ("Set Shortcut…"): no ground, the cursor ring when focused,
/// a dimmer press.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkBody(configuration: configuration)
    }

    private struct LinkBody: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.6 : 1)
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.kv.cursor, lineWidth: 2)
                            .padding(-3)
                    }
                }
                .contentShape(Rectangle())
        }
    }
}

/// `.focused(_:equals:)` on one view of a group only.
struct FocusIf: ViewModifier {
    let active: Bool
    let focus: FocusState<StatusPanelModel.FocusTarget?>.Binding
    let target: StatusPanelModel.FocusTarget

    func body(content: Content) -> some View {
        if active {
            content.focused(focus, equals: target)
        } else {
            content
        }
    }
}

// MARK: - Pieces

/// "1 finishing": 17 pt, 6 pt sides, radius 9, the panel fill, 10 pt bold
/// secondary words. A label; the primary control's label reads it.
struct FinishingBadge: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.kv.text2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(PanelColor.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// The primary control's 40 pt disc, drawn as the design draws it
/// (`Panel.dc.html`): voice with a white mic to start; a 3 pt voice ring
/// while the mic comes up, which fills into the voice dot when sound
/// arrives (Motion § 1·2·3); the dot with a white stop square and a
/// voice-soft halo that follows the level (2 + 6·level pt; 5 pt still
/// under Reduce Motion) while recording; cursor-soft with a spinning arc
/// while finishing (a still hourglass under Reduce Motion); and after a job
/// the outcome — a cursor disc whose check draws itself, a warn-soft
/// clipboard, an err-soft "!". Disabled (no model) it is the neutral fill,
/// with the download arrow while a model comes in.
struct PrimaryGlyphView: View {
    let glyph: StatusPanelState.PrimaryGlyph
    let outcome: HUDGlyph?
    let downloading: Bool
    let enabled: Bool
    let level: Double
    let animates: Bool
    let reduceMotion: Bool
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .fill(discFill)
                .background {
                    if glyph == .stop {
                        Circle().fill(Color.kv.voiceSoft).padding(-haloWidth)
                    }
                }
            Circle()
                .strokeBorder(Color.kv.voice, lineWidth: glyph == .starting ? 3 : 0)
            mark
                .id(markKey)
                .transition(.opacity)
        }
        .frame(width: 40, height: 40)
        // Motion: colour 220 ms ease; the ring → dot and the shape
        // changes on the design's spring; Reduce Motion: 150 ms fades.
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.26, dampingFraction: 0.78), value: markKey)
        .animation(reduceMotion ? nil : .linear(duration: 0.07), value: level)
        .onAppear { updateMotion() }
        .onChange(of: glyph) { _, _ in updateMotion() }
        .onChange(of: animates) { _, _ in updateMotion() }
        .accessibilityHidden(true)
    }

    private var haloWidth: CGFloat {
        reduceMotion ? 5 : 2 + 6 * CGFloat(min(max(level, 0), 1))
    }

    /// What the disc says, for the transition between marks.
    private var markKey: String {
        "\(glyph)-\(String(describing: outcome?.mark))-\(downloading)-\(enabled)"
    }

    private var discFill: Color {
        switch glyph {
        case .start:
            return enabled ? Color.kv.voiceButton : PanelColor.fill
        case .starting:
            return .clear
        case .stop:
            return Color.kv.voice
        case .working:
            return Color.kv.cursorSoft
        case .attention where downloading && outcome == nil:
            return PanelColor.fill
        case .done, .attention:
            if let outcome {
                return outcome.fill == .solid ? outcome.tone.solid.color : outcome.tone.soft.color
            }
            // Idle with a blocked prerequisite.
            return glyph == .done ? Color.kv.cursor : Color.kv.warnSoft
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch glyph {
        case .start where downloading && !enabled, .attention where downloading && outcome == nil:
            PanelGlyph(mark: .down, color: Color.kv.text2)
        case .start:
            PanelGlyph(mark: .mic, color: enabled ? .white : Color.kv.text2)
        case .starting:
            EmptyView()
        case .stop:
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.white)
                .frame(width: 13, height: 13)
        case .working:
            if reduceMotion {
                Image(systemName: "hourglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.kv.cursor)
            } else {
                PanelGlyph(mark: .arc, color: Color.kv.cursor)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
            }
        case .done, .attention:
            outcomeMark
        }
    }

    @ViewBuilder
    private var outcomeMark: some View {
        if let outcome {
            let color = outcome.fill == .solid ? Color.white : outcome.tone.solid.color
            switch outcome.mark {
            case .symbol("checkmark"):
                DrawnCheck(color: color, reduceMotion: reduceMotion)
            case .symbol("doc.on.clipboard"):
                PanelGlyph(mark: .clip, color: color)
            case .symbol, .spinner, .none:
                PanelGlyph(mark: .bang, color: color)
            }
        } else if glyph == .done {
            DrawnCheck(color: .white, reduceMotion: reduceMotion)
        } else {
            PanelGlyph(mark: .bang, color: Color.kv.warn)
        }
    }

    private func updateMotion() {
        guard animates, glyph == .working else {
            spinning = false
            return
        }
        spinning = false
        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
            spinning = true
        }
    }
}

/// Five voice-orange bars, 3 pt wide and 3 pt apart in an 18 pt row, at
/// the design's peaks (7, 12, 16, 10, 6) scaled by the followed level —
/// live signal, so linear, and never a loop of its own.
struct LevelBars: View {
    let level: Double
    private static let peaks: [CGFloat] = [7, 12, 16, 10, 6]

    var body: some View {
        let scale = 0.45 + 0.55 * CGFloat(min(max(level, 0), 1))
        HStack(spacing: 3) {
            ForEach(Array(Self.peaks.enumerated()), id: \.offset) { _, peak in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.kv.voice)
                    .frame(width: 3, height: max(3, peak * scale))
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.07), value: level)
        .accessibilityHidden(true)
    }
}

/// The progress row's 5 pt cursor-blue bar on the panel fill: the shared
/// `KVProgressBar`, so a nil fraction (verifying, loading, the first Core ML
/// build, a download of unknown size) slides a segment across the track —
/// still under Reduce Motion — and a known one fills to it, easing over
/// 300 ms (Motion § 7). Before 2026-10-22 a nil fraction drew a still
/// segment whatever Reduce Motion said, so the panel looked stalled for the
/// minutes a first compile takes.
struct ProgressTrack: View {
    let fraction: Double?
    let reduceMotion: Bool

    var body: some View {
        KVProgressBar(fraction: fraction, reduceMotion: reduceMotion, height: 5, track: PanelColor.fill)
    }
}
