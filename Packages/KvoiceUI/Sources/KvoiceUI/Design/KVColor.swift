import AppKit
import SwiftUI

/// UI v2 design tokens (the "kvoice UI v2" design language): two brand
/// colours with one meaning each — **voice** (orange: sound is being heard)
/// and **cursor** (blue: text and the cursor, the app's AccentColor) — the
/// **ink** of the app icon's background, and neutral greys for everything
/// else. Every token is a light/dark pair; views reference the semantic name
/// (`Color.kv.voice`), never a literal colour such as `.orange`.
///
/// The pairs live in code rather than in an asset catalog because the
/// package (and its tests) cannot see the app target's catalog; each token is
/// a dynamic `NSColor` that resolves against the drawing appearance, so a
/// view under `.environment(\.colorScheme, .dark)` (the Notch HUD) gets the
/// dark value whatever the system appearance.
public enum KVColorToken: String, CaseIterable, Sendable {
    case bg
    case sidebar
    case surface
    case wash
    case line
    case line2 = "line-2"
    case text
    case text2 = "text-2"
    case fill
    case fill2 = "fill-2"
    case voice
    /// The filled Start Recording disc: a step darker than `voice` so white
    /// on it reads at small sizes.
    case voiceButton = "voice-btn"
    case voiceInk = "voice-ink"
    case voiceSoft = "voice-soft"
    case cursor
    case cursorInk = "cursor-ink"
    case cursorSoft = "cursor-soft"
    case select
    case ink
    case ink2 = "ink-2"
    case inkText = "ink-text"
    /// The ink hero's outline: invisible on the light ground (it equals
    /// `ink`), a lifted edge in dark where ink meets a dark window.
    case inkLine = "ink-line"
    case ok
    case okInk = "ok-ink"
    case okSoft = "ok-soft"
    case warn
    case warnInk = "warn-ink"
    case warnSoft = "warn-soft"
    case err
    case errInk = "err-ink"
    case errSoft = "err-soft"
    case key
    case keyLine = "key-line"
    /// The recorder HUD's Mini surface.
    case hud
    /// An unlit meter bar.
    case meterOff = "meter-off"
    /// The design's neutral icon-tile grey (Shortcuts, General, Help in the
    /// sidebar): a solid, never text — use `text2` for secondary words.
    case grey

    /// The design table's `(light, dark)` values as 0xRRGGBB.
    public var hex: (light: UInt32, dark: UInt32) {
        switch self {
        case .bg: return (0xFFFFFF, 0x1C1D22)
        case .sidebar: return (0xF1F1F4, 0x24252B)
        case .surface: return (0xFFFFFF, 0x26272D)
        case .wash: return (0xF5F5F7, 0x2C2D34)
        case .line: return (0xE3E3E8, 0x3A3B43)
        case .line2: return (0xECECF0, 0x32333A)
        case .text: return (0x1D1D1F, 0xF2F2F5)
        case .text2: return (0x5E5E66, 0xA3A4AE)
        case .fill: return (0xEDEDF1, 0x35363E)
        case .fill2: return (0xE2E2E8, 0x41424B)
        case .voice: return (0xF26B1D, 0xFF7A2F)
        case .voiceButton: return (0xE35F12, 0xF26B1D)
        case .voiceInk: return (0xB84A0B, 0xFFA36B)
        case .voiceSoft: return (0xFFF1E8, 0x3A2416)
        case .cursor: return (0x2F6FEB, 0x2F6FEB)
        case .cursorInk: return (0x1F5BD6, 0x8AB0FA)
        case .cursorSoft: return (0xEAF1FE, 0x1E2A45)
        case .select: return (0xDCE6FB, 0x2B3B5E)
        case .ink: return (0x161D33, 0x121933)
        case .ink2: return (0x2A3556, 0x26304F)
        case .inkText: return (0xE4E8F4, 0xD5DAEA)
        case .inkLine: return (0x161D33, 0x2C3658)
        case .ok: return (0x1E8E4E, 0x3DCB7A)
        case .okInk: return (0x17703D, 0x6BDB9A)
        case .okSoft: return (0xE9F6EE, 0x183324)
        case .warn: return (0xE39A00, 0xFFB940)
        case .warnInk: return (0x8A5300, 0xFFC966)
        case .warnSoft: return (0xFFF4E0, 0x3A2C12)
        case .err: return (0xD0342C, 0xFF6159)
        case .errInk: return (0xB02A23, 0xFF8A84)
        case .errSoft: return (0xFDECEB, 0x3D1C1B)
        case .key: return (0xFFFFFF, 0x3A3B43)
        case .keyLine: return (0xD9D9DF, 0x4A4B55)
        case .hud: return (0xFFFFFF, 0x23252E)
        case .meterOff: return (0xD9D9DF, 0x4A4B55)
        case .grey: return (0x8A8A93, 0x6E6E78)
        }
    }

    /// The dynamic AppKit colour: light under Aqua, dark under Dark Aqua
    /// (and the high-contrast variants of each).
    public var nsColor: NSColor {
        let pair = hex
        return NSColor(name: NSColor.Name("kv.\(rawValue)")) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
                .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
            return Self.srgb(isDark ? pair.dark : pair.light)
        }
    }

    public var color: Color { Color(nsColor: nsColor) }

    static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// `Color.kv.voice` and friends. A namespace, so call sites read like the
/// design (`kv.voice`) and a typo is a compile error.
public enum KVPalette {
    public static let bg = KVColorToken.bg.color
    public static let sidebar = KVColorToken.sidebar.color
    public static let surface = KVColorToken.surface.color
    public static let wash = KVColorToken.wash.color
    public static let line = KVColorToken.line.color
    public static let line2 = KVColorToken.line2.color
    public static let text = KVColorToken.text.color
    public static let text2 = KVColorToken.text2.color
    public static let fill = KVColorToken.fill.color
    public static let fill2 = KVColorToken.fill2.color
    public static let voice = KVColorToken.voice.color
    public static let voiceButton = KVColorToken.voiceButton.color
    public static let voiceInk = KVColorToken.voiceInk.color
    public static let voiceSoft = KVColorToken.voiceSoft.color
    public static let cursor = KVColorToken.cursor.color
    public static let cursorInk = KVColorToken.cursorInk.color
    public static let cursorSoft = KVColorToken.cursorSoft.color
    public static let select = KVColorToken.select.color
    public static let ink = KVColorToken.ink.color
    public static let ink2 = KVColorToken.ink2.color
    public static let inkText = KVColorToken.inkText.color
    public static let inkLine = KVColorToken.inkLine.color
    public static let ok = KVColorToken.ok.color
    public static let okInk = KVColorToken.okInk.color
    public static let okSoft = KVColorToken.okSoft.color
    public static let warn = KVColorToken.warn.color
    public static let warnInk = KVColorToken.warnInk.color
    public static let warnSoft = KVColorToken.warnSoft.color
    public static let err = KVColorToken.err.color
    public static let errInk = KVColorToken.errInk.color
    public static let errSoft = KVColorToken.errSoft.color
    public static let key = KVColorToken.key.color
    public static let keyLine = KVColorToken.keyLine.color
    public static let hud = KVColorToken.hud.color
    public static let meterOff = KVColorToken.meterOff.color
    public static let grey = KVColorToken.grey.color
}

public extension Color {
    /// The UI v2 semantic palette: `Color.kv.voice`, `Color.kv.text2`, ….
    static var kv: KVPalette.Type { KVPalette.self }
}

/// The meaning a coloured element carries, mapped onto its three token
/// shades: `solid` (a filled glyph or dot), `ink` (text and strokes on a
/// light ground), and `soft` (a tinted background). Status is never colour
/// alone — every use pairs it with a word or a symbol.
public enum KVTone: String, Equatable, Sendable, CaseIterable {
    /// Sound is being heard: recording, the meter, the starting ring.
    case voice
    /// Text and the cursor: transcribing, polishing, inserted, AI actions.
    case cursor
    /// Ready, granted.
    case ok
    /// Needs the user; nothing broke.
    case warn
    /// Failed.
    case err
    /// No meaning: greys.
    case neutral

    public var solid: KVColorToken {
        switch self {
        case .voice: return .voice
        case .cursor: return .cursor
        case .ok: return .ok
        case .warn: return .warn
        case .err: return .err
        case .neutral: return .text2
        }
    }

    public var ink: KVColorToken {
        switch self {
        case .voice: return .voiceInk
        case .cursor: return .cursorInk
        case .ok: return .okInk
        case .warn: return .warnInk
        case .err: return .errInk
        case .neutral: return .text2
        }
    }

    public var soft: KVColorToken {
        switch self {
        case .voice: return .voiceSoft
        case .cursor: return .cursorSoft
        case .ok: return .okSoft
        case .warn: return .warnSoft
        case .err: return .errSoft
        case .neutral: return .fill
        }
    }
}
