import SwiftUI

/// UI v2 fidelity F2: the design's own 16-grid line glyphs (Window.dc /
/// Home.dc tile icons), drawn from their SVG path data instead of the
/// nearest SF Symbol. `KVDesignPath.parse` reads the subset the design uses
/// (M L H V C A Z, absolute and relative); the shape scales the 16-unit box
/// to its frame and is meant to be stroked.
struct KVDesignGlyph: Shape {
    let data: String

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
        return KVDesignPath.parse(data).applying(transform)
    }
}

enum KVDesignPath {
    /// Parses SVG path data into a `Path` in its own coordinate space.
    /// Unknown commands end the parse (a design typo must not crash).
    static func parse(_ data: String) -> Path {
        var tokens = Tokenizer(data)
        var path = Path()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var command: Character = "M"
        while let next = tokens.peekCommand() ?? (tokens.hasNumber ? command : nil) {
            if tokens.peekCommand() != nil { tokens.consumeCommand() }
            command = next
            let relative = command.isLowercase
            func point() -> CGPoint? {
                guard let x = tokens.number(), let y = tokens.number() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command.uppercased().first! {
            case "M":
                guard let p = point() else { return path }
                path.move(to: p)
                current = p
                start = p
                // Further pairs after a move are line-tos.
                command = relative ? "l" : "L"
            case "L":
                guard let p = point() else { return path }
                path.addLine(to: p)
                current = p
            case "H":
                guard let x = tokens.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case "V":
                guard let y = tokens.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case "C":
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
            case "A":
                guard let rx = tokens.number(), let ry = tokens.number(), let rotation = tokens.number(),
                      let large = tokens.flag(), let sweep = tokens.flag(), let p = point() else { return path }
                addArc(to: &path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, largeArc: large, sweep: sweep)
                current = p
            case "Z":
                path.closeSubpath()
                current = start
            default:
                return path
            }
        }
        return path
    }

    /// SVG endpoint arc → centre parameterisation (SVG 1.1 F.6.5), drawn as
    /// one `addArc` on a circle (the design's arcs are all circular, so
    /// `ry` and the rotation are only used to scale an undersized radius).
    private static func addArc(
        to path: inout Path, from p0: CGPoint, to p1: CGPoint,
        rx: CGFloat, ry: CGFloat, rotation: CGFloat, largeArc: Bool, sweep: Bool
    ) {
        var r = abs(rx)
        guard r > 0, p0 != p1 else { path.addLine(to: p1); return }
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let d2 = dx * dx + dy * dy
        if d2 > r * r { r = sqrt(d2) }
        let factor = sqrt(max(0, (r * r - d2) / d2)) * (largeArc == sweep ? -1 : 1)
        let cx = (p0.x + p1.x) / 2 + factor * dy
        let cy = (p0.y + p1.y) / 2 - factor * dx
        let a0 = atan2(p0.y - cy, p0.x - cx)
        let a1 = atan2(p1.y - cy, p1.x - cx)
        // SVG's y axis points down, so sweep = 1 (positive angle) is
        // clockwise on screen — `addArc(clockwise:)` is in flipped space.
        path.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .radians(Double(a0)), endAngle: .radians(Double(a1)), clockwise: !sweep)
    }

    private struct Tokenizer {
        private let scalars: [Character]
        private var index = 0

        init(_ data: String) { scalars = Array(data) }

        private mutating func skipSeparators() {
            while index < scalars.count, scalars[index] == " " || scalars[index] == "," || scalars[index] == "\n" { index += 1 }
        }

        mutating func peekCommand() -> Character? {
            skipSeparators()
            guard index < scalars.count, scalars[index].isLetter else { return nil }
            return scalars[index]
        }

        mutating func consumeCommand() { index += 1 }

        var hasNumber: Bool {
            var probe = self
            probe.skipSeparators()
            guard probe.index < probe.scalars.count else { return false }
            let c = probe.scalars[probe.index]
            return c.isNumber || c == "-" || c == "."
        }

        /// One arc flag: a single 0 or 1, which SVG allows without a separator.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < scalars.count, scalars[index] == "0" || scalars[index] == "1" else { return nil }
            defer { index += 1 }
            return scalars[index] == "1"
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            var text = ""
            var seenDot = false
            if index < scalars.count, scalars[index] == "-" { text.append("-"); index += 1 }
            while index < scalars.count {
                let c = scalars[index]
                if c.isNumber { text.append(c) } else if c == ".", !seenDot { seenDot = true; text.append(c) } else { break }
                index += 1
            }
            return Double(text).map { CGFloat($0) }
        }
    }
}

/// The design's tile glyphs, by meaning (Window.dc `I`).
enum KVGlyphs {
    static let home = "M2.5 7.5 8 3l5.5 4.5V13h-11z"
    static let clock = "M8 2.5a5.5 5.5 0 1 1 0 11 5.5 5.5 0 0 1 0-11zM8 5v3l2 1.5"
    static let keys = "M2.5 5h11v6h-11zM5 8h6"
    static let mic = "M8 2.5v6M5.2 6.8a2.8 2.8 0 0 0 5.6 0M8 11v2.5"
    static let wave = "M3 6v4M6 4v8M9 2.5v11M12 5v6"
    static let rec = "M8 4.5a3.5 3.5 0 1 1 0 7 3.5 3.5 0 0 1 0-7z"
    static let book = "M3 3h7.5a2 2 0 0 1 2 2v8H5a2 2 0 0 1-2-2zM3 11a2 2 0 0 1 2-2h7.5"
    static let spark = "M8 2.5 9.2 6.8 13.5 8 9.2 9.2 8 13.5 6.8 9.2 2.5 8 6.8 6.8z"
    static let shield = "M8 2.5 13 4.5v3.5c0 3-2.2 4.8-5 5.5-2.8-.7-5-2.5-5-5.5V4.5zM5.8 8.2l1.6 1.5 2.9-3"
    static let gear = "M8 5.5a2.5 2.5 0 1 1 0 5 2.5 2.5 0 0 1 0-5zM8 1.8v2M8 12.2v2M1.8 8h2M12.2 8h2M3.6 3.6l1.4 1.4M11 11l1.4 1.4M3.6 12.4 5 11M11 5l1.4-1.4"
    static let lock = "M4 7.5h8V13H4zM5.5 7.5V5.5a2.5 2.5 0 0 1 5 0v2"
    static let access = "M8 2.6a1.1 1.1 0 1 1 0 .01M3.5 5.5h9M8 5.5v4M8 9.5l-2.5 4M8 9.5l2.5 4"
    static let help = "M8 2.5a5.5 5.5 0 1 1 0 11 5.5 5.5 0 0 1 0-11zM6.3 6.3a1.8 1.8 0 1 1 2.4 1.7c-.5.2-.7.6-.7 1.1M8 11.2v.1"
}

/// A section's colour tile with the design glyph: the sidebar's 20 pt
/// (radius 5, stroke 1.9 on a 12 pt glyph) and the page header's 36 pt
/// (radius 9, stroke 1.7 on an 18 pt glyph).
struct KVGlyphTile: View {
    let glyph: String
    let fill: KVColorToken
    var side: CGFloat = 20

    var body: some View {
        let large = side > 30
        KVDesignGlyph(data: glyph)
            .stroke(.white, style: StrokeStyle(lineWidth: (large ? 1.7 : 1.9) * glyphSide / 16, lineCap: .round, lineJoin: .round))
            .frame(width: glyphSide, height: glyphSide)
            .frame(width: side, height: side)
            .background(fill.color, in: RoundedRectangle(cornerRadius: large ? 9 : 5, style: .continuous))
            .accessibilityHidden(true)
    }

    private var glyphSide: CGFloat { side > 30 ? 18 : 12 }
}
