import SwiftUI

/// UI v2 fidelity F1: the status panel's stroke icons, drawn from the
/// design's SVG path data (`Panel.dc.html`, a 16-unit grid) rather than SF
/// Symbols, so the marks match the design line for line. Each is a `Shape`
/// scaled from the 16-unit grid into its frame; the call site strokes it
/// with the design's width (1.9 for the primary glyph, 2 for the row
/// tiles) and round caps and joins.
struct PanelGlyphShape: Shape {
    enum Mark: Equatable, Sendable {
        /// `M8 2v6.5M5 6.8a3 3 0 0 0 6 0M8 11.5v2.5`
        case mic
        /// `M8 2.5a5.5 5.5 0 1 1-5.5 5.5` — the spinner's open ring.
        case arc
        /// `M3.5 8.3 6.6 11.2 12.5 4.8`
        case check
        /// `M8 3.5v5.5M8 12v.5`
        case bang
        /// `M8 2.5v8M4.5 7.5 8 11l3.5-3.5M3 13.5h10`
        case down
        /// `M5.5 3h5v2h-5zM4 4H3.5v9.5h9V4H12M6 8.5h4M6 11h3`
        case clip
        /// Row tile: `M3 6v4M6 4v8M9 2.5v11M12 5v6`
        case bars
        /// Row tile: `M2.5 8h11M8 2.5c2 2 2 9 0 11M8 2.5c-2 2-2 9 0 11`
        case globe
    }

    var mark: Mark

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        let origin = CGPoint(x: rect.midX - 8 * scale, y: rect.midY - 8 * scale)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        var path = Path()
        func line(_ points: [(CGFloat, CGFloat)]) {
            guard let first = points.first else { return }
            path.move(to: p(first.0, first.1))
            for point in points.dropFirst() {
                path.addLine(to: p(point.0, point.1))
            }
        }
        /// An arc sampled from `from` to `to` degrees (0 = +x, 90 = down,
        /// the SVG's y-down sense), either direction — explicit so the
        /// sweep never depends on `addArc`'s flipped `clockwise` flag.
        func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, from: Double, to: Double, moveFirst: Bool = true) {
            let steps = 32
            for index in 0...steps {
                let degrees = from + (to - from) * Double(index) / Double(steps)
                let radians = degrees * .pi / 180
                let point = p(cx + r * CGFloat(cos(radians)), cy + r * CGFloat(sin(radians)))
                if index == 0, moveFirst {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
        }
        switch mark {
        case .mic:
            line([(8, 2), (8, 8.5)])
            // a3 3 0 0 0 6 0 from (5, 6.8): the lower half, left to right.
            arc(8, 6.8, 3, from: 180, to: 0)
            line([(8, 11.5), (8, 14)])
        case .arc:
            // From twelve o'clock, clockwise on screen, three quarters round.
            arc(8, 8, 5.5, from: -90, to: 180)
        case .check:
            line([(3.5, 8.3), (6.6, 11.2), (12.5, 4.8)])
        case .bang:
            line([(8, 3.5), (8, 9)])
            line([(8, 12), (8, 12.5)])
        case .down:
            line([(8, 2.5), (8, 10.5)])
            line([(4.5, 7.5), (8, 11), (11.5, 7.5)])
            line([(3, 13.5), (13, 13.5)])
        case .clip:
            line([(5.5, 3), (10.5, 3), (10.5, 5), (5.5, 5)])
            path.closeSubpath()
            line([(4, 4), (3.5, 4), (3.5, 13.5), (12.5, 13.5), (12.5, 4), (12, 4)])
            line([(6, 8.5), (10, 8.5)])
            line([(6, 11), (9, 11)])
        case .bars:
            line([(3, 6), (3, 10)])
            line([(6, 4), (6, 12)])
            line([(9, 2.5), (9, 13.5)])
            line([(12, 5), (12, 11)])
        case .globe:
            line([(2.5, 8), (13.5, 8)])
            path.move(to: p(8, 2.5))
            path.addCurve(to: p(8, 13.5), control1: p(10, 4.5), control2: p(10, 11.5))
            path.move(to: p(8, 2.5))
            path.addCurve(to: p(8, 13.5), control1: p(6, 4.5), control2: p(6, 11.5))
        }
        return path
    }
}

/// A design mark stroked at its size: 17 pt / 1.9 for the primary glyph,
/// 11 pt / 2 for a row tile.
struct PanelGlyph: View {
    let mark: PanelGlyphShape.Mark
    var size: CGFloat = 17
    var lineWidth: CGFloat = 1.9
    var color: Color

    var body: some View {
        PanelGlyphShape(mark: mark)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth * size / 16, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The design's row tile: a 20 pt rounded square (radius 6) in a tone's
/// solid colour with an 11 pt white stroke mark.
struct PanelIconTile: View {
    let mark: PanelGlyphShape.Mark
    let tone: KVTone
    var isEnabled = true

    var body: some View {
        // The design strokes the 16-unit grid at 2 units into an 11 pt
        // box, so the drawn line is 2 × 11 / 16 pt.
        PanelGlyph(mark: mark, size: 11, lineWidth: 2, color: .white)
            .frame(width: 20, height: 20)
            .background(
                (isEnabled ? tone.solid : KVColorToken.text2).color.opacity(isEnabled ? 1 : 0.5),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// The check that draws itself (Motion § 10·12 and the handoff's "check
/// draws 240 ms easeOut, 60 ms in"). Under Reduce Motion it is simply there.
struct DrawnCheck: View {
    var size: CGFloat = 17
    var lineWidth: CGFloat = 1.9
    var color: Color
    let reduceMotion: Bool
    @State private var drawn: CGFloat = 0

    var body: some View {
        PanelGlyphShape(mark: .check)
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
            .accessibilityHidden(true)
    }
}

/// The panel's own colours where `Panel.dc.html` deviates from the shared
/// tokens (`Tokens.dc.html`): the panel ground, a slightly bluer dark
/// surface and fill, a grey key cap, and the card hairline. Scoped to the
/// panel so the rest of the app keeps the shared tokens; the deviations are
/// listed as design problems in the F1 fidelity notes.
enum PanelColor {
    static let panel = dynamic("panel")
    static let surface = dynamic("surface")
    static let fill = dynamic("fill")
    static let key = dynamic("key")
    static let keyLine = dynamic("key-line")
    /// rgba(22,29,51,.08) light, rgba(255,255,255,.06) dark.
    static let cardLine = Color(nsColor: NSColor(name: NSColor.Name("kv.panel.card-line")) { appearance in
        isDark(appearance)
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06)
            : NSColor(srgbRed: 22 / 255, green: 29 / 255, blue: 51 / 255, alpha: 0.08)
    })
    /// The panel's edge: a .5 pt ring, rgba(22,29,51,.18) light and
    /// rgba(255,255,255,.14) dark (the design's shadow's second layer).
    static let edge = Color(nsColor: NSColor(name: NSColor.Name("kv.panel.edge")) { appearance in
        isDark(appearance)
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14)
            : NSColor(srgbRed: 22 / 255, green: 29 / 255, blue: 51 / 255, alpha: 0.18)
    })

    /// `Panel.dc.html`'s values, light and dark: the one table the
    /// colours above are built from (and the tests read).
    static func hex(_ name: String) -> (light: UInt32, dark: UInt32)? {
        switch name {
        case "panel": return (0xF7F7F9, 0x1E2029)
        case "surface": return (0xFFFFFF, 0x282B36)
        case "fill": return (0xEDEDF1, 0x363948)
        case "key": return (0xF5F5F7, 0x3A3B43)
        case "key-line": return (0xDCDCE2, 0x4A4B55)
        default: return nil
        }
    }

    private static func dynamic(_ name: String) -> Color {
        let pair = hex(name) ?? (0, 0)
        return Color(nsColor: NSColor(name: NSColor.Name("kv.panel.\(name)")) { appearance in
            KVColorToken.srgb(isDark(appearance) ? pair.dark : pair.light)
        })
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }
}
