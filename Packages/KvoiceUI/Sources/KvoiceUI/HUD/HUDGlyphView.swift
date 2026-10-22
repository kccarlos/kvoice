import SwiftUI

/// The recorder's leading glyph (UI v2, `Recorder.dc.html`; motion from
/// `Motion.dc.html` § 1·2·3). One view that morphs rather than a cross-fade
/// between glyphs:
///
/// - the Starting ring (2.5 pt, voice) fills into the solid dot on the first
///   buffer — the fill and the ring width animate together (220 ms);
/// - the live dot wears a voice-soft halo of `2 + 6·level` pt that follows
///   the level (`KVLevelFollower`, as the status panel's disc; a still 5 pt
///   under Reduce Motion);
/// - on release the dot shrinks to .45 (220 ms) while the meter folds into
///   it, then reopens as the cursor-soft disc with the spinner on the
///   design's overshoot curve (cubic-bezier(.34,1.56,.64,1), 260 ms);
/// - Inserted's check draws itself (240 ms easeOut, 60 ms delay).
///
/// Colours change over 220 ms ease. Reduce Motion: no scale, no draw, the
/// spinner is a still hourglass; colours still change (150 ms).
///
/// The marks are the design's 16-grid strokes (`KVDesignGlyph`), 15 pt at
/// 1.9 on Mini's 30 pt disc and 13 pt at 2 on Notch's 24 pt one. On the
/// notch, which is always black, the colours are the design's literals.
struct HUDGlyphView: View {
    let glyph: HUDGlyph
    let diameter: CGFloat
    let onNotch: Bool
    /// The followed level (0…1) for the halo; ignored unless the dot is live.
    let level: Double
    let reduceMotion: Bool

    @State private var shown: HUDGlyph?
    @State private var scale: CGFloat = 1
    /// The newest glyph asked for: a fold's completion applies this, not
    /// the glyph it started with, so a phase that moves on during the
    /// 220 ms fold (a short tap's failure, a quick Inserted) is not
    /// overwritten by a stale spinner.
    @State private var latest: HUDGlyph?

    private var current: HUDGlyph { shown ?? glyph }

    var body: some View {
        let current = current
        ZStack {
            Circle()
                .fill(Self.discFill(current, onNotch: onNotch))
                .background {
                    if Self.isLiveDot(current) {
                        Circle()
                            .fill(onNotch ? Self.notchHalo : Color.kv.voiceSoft)
                            .padding(-haloWidth)
                            .animation(reduceMotion ? nil : .linear(duration: 0.07), value: level)
                    }
                }
            Circle()
                .strokeBorder(Self.solid(current.tone, onNotch: onNotch), lineWidth: current.fill == .ring ? 2.5 : 0)
            mark(current)
                .id(Self.markKey(current))
                .transition(.opacity.animation(.easeOut(duration: 0.16)))
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(scale)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.22), value: current)
        .onAppear { shown = glyph }
        .onChange(of: glyph) { old, new in morph(from: old, to: new) }
        .accessibilityHidden(true)
    }

    private var haloWidth: CGFloat {
        reduceMotion ? 5 : 2 + 6 * CGFloat(min(max(level, 0), 1))
    }

    /// The handoff: from the live dot into a processing phase the dot first
    /// shrinks, then reopens as the new glyph. Every other change is the
    /// colour / ring morph alone.
    private func morph(from old: HUDGlyph, to new: HUDGlyph) {
        latest = new
        guard !reduceMotion, Self.isLiveDot(old), new.mark == .spinner else {
            shown = new
            scale = 1
            return
        }
        withAnimation(.easeOut(duration: 0.22)) {
            scale = 0.45
        } completion: {
            shown = latest ?? new
            withAnimation(.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.26)) {
                scale = 1
            }
        }
    }

    @ViewBuilder
    private func mark(_ glyph: HUDGlyph) -> some View {
        let size: CGFloat = onNotch ? 13 : 15
        let width: CGFloat = onNotch ? 2 : 1.9
        let color = glyph.fill == .solid ? Color.white : Self.markColor(glyph.tone, onNotch: onNotch)
        switch glyph.mark {
        case .none:
            EmptyView()
        case .spinner:
            if reduceMotion {
                Image(systemName: "hourglass")
                    .font(.system(size: size * 0.9, weight: .semibold))
                    .foregroundStyle(color)
            } else {
                HUDSpinner(color: color, size: size, lineWidth: width)
            }
        case .symbol(let name):
            if name == "checkmark" {
                HUDDrawnMark(path: HUDMarkPath.check, color: color, size: size, lineWidth: width, reduceMotion: reduceMotion)
            } else {
                KVDesignGlyph(data: HUDMarkPath.forSymbol(name))
                    .stroke(color, style: StrokeStyle(lineWidth: width * size / 16, lineCap: .round, lineJoin: .round))
                    .frame(width: size, height: size)
            }
        }
    }

    // MARK: Colours

    static let notchHalo = Color(red: 1, green: 122 / 255, blue: 47 / 255).opacity(0.25)

    static func isLiveDot(_ glyph: HUDGlyph) -> Bool {
        glyph.tone == .voice && glyph.fill == .solid
    }

    /// The tone's solid colour; on the notch the design's literals
    /// (#FF7A2F, #2F6FEB, #FFB940, #FF6159).
    static func solid(_ tone: KVTone, onNotch: Bool) -> Color {
        guard onNotch else { return tone.solid.color }
        switch tone {
        case .voice: return Color(red: 1, green: 122 / 255, blue: 47 / 255)
        case .cursor: return Color(red: 47 / 255, green: 111 / 255, blue: 235 / 255)
        case .warn: return Color(red: 1, green: 185 / 255, blue: 64 / 255)
        case .err: return Color(red: 1, green: 97 / 255, blue: 89 / 255)
        default: return tone.solid.color
        }
    }

    /// A soft disc's stroke: the tone's ink for voice, its solid colour
    /// otherwise (the design's `T.ink`).
    static func markColor(_ tone: KVTone, onNotch: Bool) -> Color {
        if !onNotch, tone == .voice { return Color.kv.voiceInk }
        return solid(tone, onNotch: onNotch)
    }

    static func discFill(_ glyph: HUDGlyph, onNotch: Bool) -> Color {
        switch glyph.fill {
        case .ring: return Self.solid(glyph.tone, onNotch: onNotch).opacity(0)
        case .solid: return Self.solid(glyph.tone, onNotch: onNotch)
        case .soft: return onNotch ? Color.white.opacity(0.08) : glyph.tone.soft.color
        }
    }

    static func markKey(_ glyph: HUDGlyph) -> String {
        "\(glyph.mark)-\(glyph.fill)"
    }
}

/// The design's mark paths (`Recorder.dc.html`, a 16-unit grid).
enum HUDMarkPath {
    static let mic = "M8 2.5v6M5.2 6.8a2.8 2.8 0 0 0 5.6 0M8 11v2.5"
    static let arc = "M8 2.5a5.5 5.5 0 1 1-5.5 5.5"
    static let check = "M3.5 8.3 6.6 11.2 12.5 4.8"
    static let bang = "M8 3.5v5.5M8 12v.5"
    static let cross = "M4.5 4.5l7 7M11.5 4.5l-7 7"
    static let clip = "M5.5 3h5v2h-5zM4 4H3.5v9.5h9V4H12M6 8.5h4M6 11h3"

    /// `HUDGlyphMark.symbol` names stay the state's vocabulary (the status
    /// panel reads them too); the recorder draws the design's mark for each.
    static func forSymbol(_ name: String) -> String {
        switch name {
        case "mic", "mic.fill": return mic
        case "checkmark": return check
        case "xmark": return cross
        case "doc.on.clipboard": return clip
        default: return bang
        }
    }
}

/// A mark that draws itself once when it appears (Inserted's check:
/// 240 ms easeOut after 60 ms); complete at once under Reduce Motion.
private struct HUDDrawnMark: View {
    let path: String
    let color: Color
    let size: CGFloat
    let lineWidth: CGFloat
    let reduceMotion: Bool
    @State private var drawn: CGFloat = 0

    var body: some View {
        KVDesignGlyph(data: path)
            .trim(from: 0, to: reduceMotion ? 1 : drawn)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth * size / 16, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .onAppear {
                guard !reduceMotion else { return }
                drawn = 0
                withAnimation(.easeOut(duration: 0.24).delay(0.06)) {
                    drawn = 1
                }
            }
    }
}

/// The design's open arc turning once a second (`kvspin`, linear). Only
/// built when Reduce Motion is off; the glyph shows a still hourglass then.
private struct HUDSpinner: View {
    let color: Color
    let size: CGFloat
    let lineWidth: CGFloat

    @State private var turning = false

    var body: some View {
        KVDesignGlyph(data: HUDMarkPath.arc)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth * size / 16, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    turning = true
                }
            }
    }
}
