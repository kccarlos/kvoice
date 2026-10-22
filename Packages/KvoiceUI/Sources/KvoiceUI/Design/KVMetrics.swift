import SwiftUI

/// UI v2 corner radii: controls 6, cards 10, panels 16, and the capsule for
/// the HUD and chips (use `Capsule`, not a radius).
public enum KVRadius {
    public static let control: CGFloat = 6
    public static let card: CGFloat = 10
    public static let panel: CGFloat = 16
}

/// UI v2 spacing scale: 4 · 8 · 12 · 16 · 24 · 32.
public enum KVSpacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let s: CGFloat = 12
    public static let m: CGFloat = 16
    public static let l: CGFloat = 24
    public static let xl: CGFloat = 32

    public static let scale: [CGFloat] = [xxs, xs, s, m, l, xl]
}

/// UI v2 type ramp, all SF Pro at system sizes: pageTitle 22 bold (Window.dc header; F2),
/// sectionTitle 17 semibold, body 13, footnote 12 (secondary colour at the
/// call site), and metrics in SF Mono with tabular digits.
public enum KVFont {
    public static let pageTitle = Font.system(size: 22, weight: .bold)
    public static let sectionTitle = Font.system(size: 17, weight: .semibold)
    public static let body = Font.system(size: 13)
    public static let footnote = Font.system(size: 12)

    /// "0:07", "1,284": monospaced so a ticking value never reflows.
    public static func metric(size: CGFloat = 12, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced).monospacedDigit()
    }
}
