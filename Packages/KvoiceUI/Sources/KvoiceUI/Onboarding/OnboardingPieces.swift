import KvoiceDomain
import SwiftUI

// UI v2 fidelity F4: the setup wizard's drawn pieces (Wizard.dc.html) and
// their motion (Motion.dc.html § 9, § 10·12, § 11, § 4·6). Every piece takes
// `reduceMotion` from the view, because the snapshots force it.

// MARK: Motion constants

enum WizardMotion {
    /// Motion's springy cubic-bezier(.34,1.56,.64,1).
    static func spring(_ duration: Double) -> Animation {
        .timingCurve(0.34, 1.56, 0.64, 1, duration: duration)
    }

    /// § 9: the page's slide, cubic-bezier(.2,.8,.2,1) 260 ms; under Reduce
    /// Motion a 150 ms crossfade.
    static func page(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.26)
    }

    /// § 9: insertion moves 24 pt in from the side you go, plus a fade;
    /// removal only fades. Reduce Motion: crossfade only.
    static func pageTransition(forward: Bool, reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .offset(x: forward ? 24 : -24).combined(with: .opacity),
            removal: .opacity
        )
    }
}

// MARK: Buttons

/// Wizard.dc's `btn()`: 30 pt, radius 8, 13 pt — the card actions. `.alt`
/// and `.fix` sizes are the 28 pt / 12 pt alternative-model button and the
/// checklist's 26 pt Fix…. `.danger` is outlined in err; `.muted` is the
/// design's unavailable test button (fill ground, secondary text, no
/// border). Presses dim for 120 ms (Motion's press rule).
struct WizardButtonStyle: ButtonStyle {
    enum Kind { case standard, danger, link, muted }
    enum Size {
        case card, alt, fix

        var height: CGFloat { self == .card ? 30 : self == .alt ? 28 : 26 }
        var font: CGFloat { self == .card ? 13 : 12 }
        var radius: CGFloat { self == .card ? 8 : 7 }
        var padding: CGFloat { self == .card ? 13 : self == .alt ? 12 : 10 }
    }

    var kind: Kind = .standard
    var size: Size = .card
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        configuration.label
            .font(.system(size: size.font))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .link ? 4 : size.padding)
            .frame(height: size.height)
            .background {
                switch kind {
                case .standard: shape.fill(Color.kv.surface)
                case .muted: shape.fill(Color.kv.fill)
                case .danger, .link: Color.clear
                }
            }
            .overlay {
                switch kind {
                case .standard: shape.strokeBorder(Color.kv.line, lineWidth: 1)
                case .danger: shape.strokeBorder(Color.kv.err, lineWidth: 1)
                case .muted, .link: EmptyView()
                }
            }
            .contentShape(shape)
            .opacity((isEnabled || kind == .muted ? 1 : 0.45) * (configuration.isPressed ? 0.75 : 1))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .fixedSize()
    }

    private var foreground: Color {
        switch kind {
        case .standard: return Color.kv.text
        case .danger: return Color.kv.errInk
        case .link: return Color.kv.cursorInk
        case .muted: return Color.kv.text2
        }
    }
}

// MARK: Glyphs

/// The design's check, "M3.5 8.3 6.6 11.2 12.5 4.8" on the 16 grid; trim it
/// to draw it.
struct WizardCheck: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        var path = Path()
        path.move(to: CGPoint(x: 3.5 * scale, y: 8.3 * scale))
        path.addLine(to: CGPoint(x: 6.6 * scale, y: 11.2 * scale))
        path.addLine(to: CGPoint(x: 12.5 * scale, y: 4.8 * scale))
        return path.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// A drawn check of `side` points with `width` stroke on the 16 grid.
struct WizardCheckMark: View {
    var side: CGFloat
    var lineWidth: CGFloat
    var color: Color = .white
    var drawn: CGFloat = 1

    var body: some View {
        WizardCheck()
            .trim(from: 0, to: drawn)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth * side / 16, lineCap: .round, lineJoin: .round))
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// The design's tile glyphs (Wizard.dc `I`).
enum WizardGlyph {
    static let wave = "M3 6v4M6 4v8M9 2.5v11M12 5v6"
    static let mic = "M8 2v6.5M5 6.8a3 3 0 0 0 6 0M8 11.5v2.5"
    static let access = "M8 2.6a1.1 1.1 0 1 1 0 .01M3.5 5.5h9M8 5.5v4M8 9.5l-2.5 4M8 9.5l2.5 4"
    static let apple = "M8 3.5c1-1.2 2.2-1 2.2-1M5.5 5c-2 0-3 1.8-3 3.8 0 2.4 1.6 4.7 3 4.7.8 0 1.2-.4 2.5-.4s1.7.4 2.5.4c1.4 0 3-2.3 3-4.7 0-2-1-3.8-3-3.8-1 0-1.7.5-2.5.5S6.5 5 5.5 5z"
    static let book = "M3 3h7.5a2 2 0 0 1 2 2v8H5a2 2 0 0 1-2-2zM3 11a2 2 0 0 1 2-2h7.5"
    static let sparkle = "M8 2.5 9.2 6.8 13.5 8 9.2 9.2 8 13.5 6.8 9.2 2.5 8 6.8 6.8z"
}

/// Wizard.dc's tile: 40 pt radius 10 with an 18 pt glyph (stroke 1.7), or
/// the Ready links' 26 pt radius 7 with a 13 pt glyph (stroke 1.8).
struct WizardTile: View {
    let glyph: String
    let fill: KVColorToken
    var side: CGFloat = 40

    var body: some View {
        let glyphSide: CGFloat = side > 30 ? 18 : 13
        let stroke: CGFloat = side > 30 ? 1.7 : 1.8
        KVDesignGlyph(data: glyph)
            .stroke(.white, style: StrokeStyle(lineWidth: stroke * glyphSide / 16, lineCap: .round, lineJoin: .round))
            .frame(width: glyphSide, height: glyphSide)
            .frame(width: side, height: side)
            .background(fill.color, in: RoundedRectangle(cornerRadius: side > 30 ? 10 : 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: Spinner

/// The design's spinner (an open arc, `kvspin` 1 s linear). Reduce Motion:
/// Motion's static hourglass.
struct WizardSpinner: View {
    var color: Color
    var side: CGFloat = 13
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            Image(systemName: "hourglass")
                .font(.system(size: side * 0.85, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        } else {
            TimelineView(.animation) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(color, style: StrokeStyle(lineWidth: 2 * side / 16, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
            .frame(width: side, height: side)
            .accessibilityHidden(true)
        }
    }
}

// MARK: Step bar

/// One step bar dot: blue check for done, ink with its number (and a 4 pt
/// cursor-soft ring) for the current step, amber dashed for skipped, grey
/// for not reached. Colours change over 200 ms (Motion § 9).
struct StepDot: View {
    let state: OnboardingStepState
    let number: Int

    var body: some View {
        ZStack {
            Circle().fill(Color.kv.cursorSoft)
                .padding(-4)
                .opacity(state == .current ? 1 : 0)
            switch state {
            case .done:
                Circle().fill(Color.kv.cursor)
                WizardCheckMark(side: 10, lineWidth: 2.8)
            case .current:
                Circle().fill(Color.kv.ink)
                number(color: .white)
            case .skipped:
                Circle().fill(Color.kv.bg)
                Circle().strokeBorder(Color.kv.warn, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                Text(verbatim: "–")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.kv.warnInk)
            case .todo:
                Circle().fill(Color.kv.bg)
                Circle().strokeBorder(Color.kv.line, lineWidth: 1.5)
                number(color: Color.kv.text2)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private func number(color: Color) -> some View {
        Text(verbatim: "\(number)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
    }
}

/// The 2 pt line into a step: `line` grey, filled with `cursor` from the
/// left when lit. The fill grows with Motion § 9's 260 ms spring; under
/// Reduce Motion it fades.
struct StepConnector: View {
    let lit: Bool
    let reduceMotion: Bool

    var body: some View {
        Rectangle().fill(Color.kv.line)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.kv.cursor)
                    .scaleEffect(x: reduceMotion || lit ? 1 : 0.001, y: 1, anchor: .leading)
                    .opacity(reduceMotion && !lit ? 0 : 1)
            }
            .frame(height: 2)
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : WizardMotion.spring(0.26), value: lit)
    }
}

// MARK: Card pieces

/// A card's status chip (24 pt, the tone's soft ground and ink, a 7 pt
/// dot). With `drawsCheck` (the permission cards, Motion § 10) an ok chip
/// shows a check in place of the dot, drawn over 240 ms after a 120 ms
/// delay when the chip turns ok; colours change over 240 ms.
struct WizardChip: View {
    let chip: OnboardingStatusChip
    var drawsCheck = false
    let reduceMotion: Bool
    @State private var drawn: CGFloat = 1

    var body: some View {
        let showsCheck = drawsCheck && chip.tone == .ok
        HStack(spacing: 6) {
            if showsCheck {
                WizardCheckMark(side: 11, lineWidth: 2.8, color: Color.kv.ok, drawn: drawn)
                    .frame(width: 11, height: 11)
            } else {
                Circle().fill(chip.tone.solid.color).frame(width: 7, height: 7)
            }
            Text(verbatim: chip.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(chip.tone.ink.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(chip.tone.soft.color, in: Capsule(style: .continuous))
        .fixedSize()
        .animation(.easeInOut(duration: 0.24), value: chip.tone)
        .onChange(of: chip.tone) { _, tone in
            guard drawsCheck, tone == .ok, !reduceMotion else { return }
            drawn = 0
            withAnimation(.easeOut(duration: 0.24).delay(0.12)) { drawn = 1 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: chip.title))
    }
}

/// The hero card of a step: a 40 pt tile, the thing being set up and one
/// detail line, a status chip, then the step's own lines, alerts and
/// buttons. Its edge takes a tone when something needs the user. A change
/// of `glowTrigger` plays Motion § 10's one-time glow (700 ms: 1 pt ok ring
/// plus an 8 pt ok-soft halo at 40 %, then back to the line).
struct WizardCard<Content: View>: View {
    let glyph: String
    let tileFill: KVColorToken
    let title: String
    let detail: String?
    let chip: OnboardingStatusChip
    var edge: KVTone?
    var drawsCheck = false
    var glowTrigger = 0
    let reduceMotion: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                WizardTile(glyph: glyph, fill: tileFill)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.kv.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(verbatim: detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.kv.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                WizardChip(chip: chip, drawsCheck: drawsCheck, reduceMotion: reduceMotion)
                    .accessibilityLabel(Text(verbatim: "\(title) status: \(chip.title)"))
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.kv.surface, in: shape)
        .overlay {
            shape.strokeBorder(edge.map { $0.solid.color } ?? Color.kv.line, lineWidth: 1)
                .animation(.easeInOut(duration: 0.3), value: edge)
        }
        .keyframeAnimator(initialValue: 0.0, trigger: glowTrigger) { card, glow in
            card
                .overlay {
                    shape.strokeBorder(Color.kv.ok, lineWidth: 1).opacity(min(1, glow * 2.5))
                }
                .background {
                    // The card is opaque, so only the halo outside it shows.
                    shape.fill(Color.kv.okSoft).padding(-8 * glow).opacity(glow > 0 ? 1 : 0)
                }
        } keyframes: { _ in
            LinearKeyframe(1, duration: 0.28)
            LinearKeyframe(0, duration: 0.42)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A tinted sentence inside a card: what happened and what to do next.
struct CardAlert: View {
    let text: String
    let tone: KVTone

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .foregroundStyle(tone.ink.color)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(tone.soft.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Color.kv.line2).frame(height: 1)
    }
}

/// The model card's progress: a 6 pt cursor bar (`KVProgressBar`: a sliding
/// segment when Core ML reports no fraction, still under Reduce Motion), the
/// activity on the left and the percentage on the right. The width eases
/// over 300 ms (Motion § 7) and the percentage rolls.
struct ProgressStrip: View {
    let fraction: Double?
    let label: String
    let trailing: String?
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            KVProgressBar(fraction: fraction, reduceMotion: reduceMotion, height: 6)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: label)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let trailing {
                    Text(verbatim: trailing)
                        .font(KVFont.metric(size: 12, weight: .regular))
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .timingCurve(0.34, 1.4, 0.64, 1, duration: 0.32), value: trailing)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.kv.text2)
        }
    }
}

// MARK: Microphone

/// The level test's 24 segments: voice, then warn from 16, err from 20, lit
/// by the test's meter value through Motion § 4·6's follower (fast attack,
/// slow release); segments change over 70 ms linear. Fixed size, so a tick
/// never triggers layout.
struct LevelMeter: View {
    let value: Double
    @State private var follower = KVLevelFollower()
    @State private var lastTick = Date()

    var body: some View {
        let lit = Int((follower.level * 24).rounded())
        HStack(spacing: 3) {
            ForEach(0..<24, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index < lit ? color(for: index) : Color.kv.fill)
                    .frame(height: 22)
            }
        }
        .frame(height: 28)
        .animation(.linear(duration: 0.07), value: lit)
        .onAppear { follower = KVLevelFollower(level: value) }
        .onChange(of: value) { _, raw in
            let now = Date()
            follower.step(raw: raw, elapsed: min(0.25, now.timeIntervalSince(lastTick)))
            lastTick = now
        }
    }

    private func color(for index: Int) -> Color {
        index >= 20 ? Color.kv.err : index >= 16 ? Color.kv.warn : Color.kv.voice
    }
}

// MARK: Shortcut

/// A mode card's six-bar glyph: what the key does over time.
struct ModeGlyph: View {
    let interaction: RecordingInteraction
    let selected: Bool

    private var pattern: [Bool] {
        switch interaction {
        case .pushToTalk: return [true, true, true, true, true, true]
        case .toggle: return [true, false, false, false, false, true]
        case .hybrid: return [true, true, false, false, true, false]
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(pattern.enumerated()), id: \.offset) { _, on in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(on ? (selected ? Color.kv.voice : Color.kv.text2) : Color.kv.fill)
                    .frame(width: 7, height: on ? 12 : 4)
            }
        }
        .frame(height: 16)
        .animation(.easeInOut(duration: 0.2), value: selected)
        .accessibilityHidden(true)
    }
}

/// A pie that fills clockwise from 12 o'clock: Motion § 11's
/// AngularGradient orb.
struct OrbPie: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard progress > 0 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(1, progress)), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Motion § 11's orb (40 pt): dashed while waiting; held, it fills with
/// voice as the hold grows (full at 1.2 s) and swells to 1.08; released
/// after 0.6 s it turns ok at 1.05 and the check draws (0.22 s easeOut,
/// 80 ms delay); a short press drains back. Toggle's first press shows a
/// full voice orb. Reduce Motion: no scaling or draining, colours change.
struct TryOrb: View {
    let progress: Double
    let live: Bool
    let done: Bool
    let reduceMotion: Bool
    @State private var drawn: CGFloat = 0

    var body: some View {
        ZStack {
            if done {
                Circle().fill(Color.kv.ok)
                WizardCheckMark(side: 20, lineWidth: 2.4, drawn: drawn)
            } else if live {
                Circle().fill(Color.kv.fill)
                OrbPie(progress: progress).fill(Color.kv.voice)
            } else {
                Circle().strokeBorder(Color.kv.line, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                OrbPie(progress: progress).fill(Color.kv.voice)
            }
        }
        .frame(width: 40, height: 40)
        .scaleEffect(reduceMotion ? 1 : (done ? 1.05 : live ? 1.08 : 1))
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : WizardMotion.spring(0.26), value: done)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : WizardMotion.spring(0.26), value: live)
        .animation(reduceMotion ? nil : (live ? .linear(duration: 0.1) : .easeOut(duration: 0.26)), value: progress)
        .onAppear { drawn = done ? 1 : 0 }
        .onChange(of: done) { _, isDone in
            guard isDone else { drawn = 0; return }
            if reduceMotion {
                drawn = 1
            } else {
                drawn = 0
                withAnimation(.easeOut(duration: 0.22).delay(0.08)) { drawn = 1 }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The "Recording keys" box's caret: 2 × 16 pt cursor, blinking at 1 s
/// (steps), still under Reduce Motion.
struct WizardCaret: View {
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            caret(visible: true)
        } else {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                caret(visible: Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0)
            }
        }
    }

    private func caret(visible: Bool) -> some View {
        Rectangle()
            .fill(Color.kv.cursor)
            .frame(width: 2, height: 16)
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(true)
    }
}

// MARK: Ready

/// The Ready checklist's leading mark. Motion § 12: arriving on Ready, the
/// ready checks scale .4 → 1 (300 ms spring) and fade in (160 ms), 60 ms
/// apart — `shown` goes true once per arrival. Reduce Motion: no scale.
struct ChecklistIcon: View {
    let status: OnboardingReadinessStatus
    let busy: Bool
    let index: Int
    let shown: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if busy {
                // Wizard.dc's busy ring: cursor with a cursor-soft quarter.
                if reduceMotion {
                    Circle().strokeBorder(Color.kv.cursor, lineWidth: 2)
                    WizardSpinner(color: Color.kv.cursor, side: 11, reduceMotion: true)
                } else {
                    Circle().strokeBorder(Color.kv.cursorSoft, lineWidth: 2)
                    WizardSpinner(color: Color.kv.cursor, side: 18, reduceMotion: false)
                }
            } else {
                switch status {
                case .ready:
                    ZStack {
                        Circle().fill(Color.kv.ok)
                        WizardCheckMark(side: 10, lineWidth: 2.8)
                    }
                    .scaleEffect(reduceMotion || shown ? 1 : 0.4)
                    .opacity(reduceMotion || shown ? 1 : 0)
                    .animation(reduceMotion ? nil : WizardMotion.spring(0.3).delay(Double(index) * 0.06), value: shown)
                case .blocked:
                    Circle().fill(Color.kv.warnSoft)
                    Circle().strokeBorder(Color.kv.warn, lineWidth: 1.5)
                    Text(verbatim: "!")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Color.kv.warnInk)
                case .deferred, .notReady:
                    Circle().strokeBorder(Color.kv.text2, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

/// Ready's recording box meter: 14 voice bars (4 pt, the design's heights
/// scaled by the live level) and nothing else, in a fixed 22 pt row so a
/// level tick re-renders the bars only (Motion: "meter ticks must not
/// trigger layout"). Bars move 70 ms linear.
struct DictationTestMeter: View {
    let level: OnboardingLiveLevel
    private static let heights: [CGFloat] = [8, 14, 20, 12, 18, 9, 15, 22, 11, 7, 13, 19, 10, 6]

    var body: some View {
        let value = level.level
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(Self.heights.enumerated()), id: \.offset) { _, height in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.kv.voice)
                    .frame(width: 4, height: max(3, height * (0.25 + 0.75 * value)))
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.07), value: value)
        .accessibilityHidden(true)
    }
}
