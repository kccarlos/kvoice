import AppKit
import KvoiceDomain

/// How the recorder's title row fits its chips (2026-10-22). The Mini pill
/// is 316 pt wide, and with the glyph, the meter and the clock taken there
/// are about 174 pt left for the title and the AI chip: "Starting mic…"
/// (89 pt) beside "Clean Up ⌘1" (80 pt) already overflowed, and SwiftUI
/// truncated both ("Starting mi…", "Clean… ⌘1"). The design never shows a
/// truncated title, so the row now degrades in a fixed order:
///
/// 1. everything at its full width;
/// 2. the AI chip without its ⌘-number (the number is also in the menu and
///    on the AI Actions page; the name is the information);
/// 3. the AI chip's name truncated to the room left (only a long name the
///    user typed gets here — every built-in name fits at step 2, tested).
///
/// The title is never truncated while it fits the row on its own; the
/// "1 finishing" badge keeps its width (it is short and fixed). Widths are
/// measured with the system font at the view's sizes, so the choice is a
/// pure function the tests run on the longest built-in strings in both
/// languages (`HUDHeaderFitTests`).
struct HUDHeaderFit: Equatable {
    /// Show the AI chip's ⌘-number.
    let showsShortcut: Bool
    /// The most the AI chip may take; nil when it fits whole.
    let chipMaxWidth: CGFloat?
    /// The title has its full width (never truncated).
    let titleFits: Bool

    static let unconstrained = HUDHeaderFit(showsShortcut: true, chipMaxWidth: nil, titleFits: true)

    // MARK: Geometry (mirrors `HUDView`; `HUDHeaderFitTests` checks the copies)

    static let miniPanelWidth: CGFloat = 316
    static let notchPanelWidth: CGFloat = 380
    /// The five-bar meter: 3 pt bars, 2 pt apart (`HUDMeter`).
    static let meterWidth: CGFloat = 5 * 3 + 4 * 2

    /// The room the title and the chips share, for the style.
    static func rowWidth(style: HUDStyle, notchWidth: CGFloat?, clockText: String) -> CGFloat {
        let trailing = meterWidth + 10 + max(34, measure(clockText, size: 12, weight: .semibold, monospaced: true))
        switch style {
        case .mini:
            // padding 11 + 14, glyph 30, two HStack gaps of 10.
            return miniPanelWidth - 11 - 14 - 30 - 10 - 10 - trailing
        case .notch:
            // padding 12 + 16, glyph 24, three HStack gaps of 10 (the chip
            // sits in the outer row there, beside the glyph).
            return (notchWidth ?? notchPanelWidth) - 12 - 16 - 24 - 10 - 10 - 10 - trailing
        }
    }

    /// The gap between the title and the chips: 6 in Mini's inner row; on
    /// the notch the chip is a sibling of the title column (one gap of 10,
    /// already in `rowWidth`).
    static func titleGap(style: HUDStyle) -> CGFloat { style == .mini ? 6 : 0 }

    /// `ModeChip`'s width: 7 pt padding each side, the struck or sparkles
    /// symbol (9 pt) and its 4 pt gap, the name, and the shortcut after a
    /// 4 pt gap, all at 10 pt bold.
    static func chipWidth(text: String, hasSymbol: Bool, shortcut: String?) -> CGFloat {
        var width = 14 + measure(text, size: 10, weight: .bold)
        if hasSymbol { width += 9 + 4 }
        if let shortcut { width += 4 + measure(shortcut, size: 10, weight: .bold) }
        return width
    }

    static func titleWidth(_ title: String, style: HUDStyle) -> CGFloat {
        measure(title, size: style == .mini ? 13 : 12, weight: .semibold)
    }

    // MARK: The choice

    static func resolve(
        title: String,
        ai: HUDAIIndicator?,
        finishingBadge: String?,
        style: HUDStyle,
        notchWidth: CGFloat?,
        clockText: String
    ) -> HUDHeaderFit {
        guard let ai else { return .unconstrained }
        let row = rowWidth(style: style, notchWidth: notchWidth, clockText: clockText)
        let gap = titleGap(style: style)
        // Beside the AI chip: 6 pt in Mini's row, 10 pt in the notch's.
        let badge = finishingBadge.map { chipWidth(text: $0, hasSymbol: false, shortcut: nil) + (style == .mini ? 6 : 10) } ?? 0
        let titleWidth = titleWidth(title, style: style)
        let room = row - titleWidth - gap - badge - safety
        let hasSymbol = ai.chipSymbolName != nil
        if chipWidth(text: ai.chipText, hasSymbol: hasSymbol, shortcut: ai.chipShortcut) <= room {
            return HUDHeaderFit(showsShortcut: true, chipMaxWidth: nil, titleFits: true)
        }
        if chipWidth(text: ai.chipText, hasSymbol: hasSymbol, shortcut: nil) <= room {
            return HUDHeaderFit(showsShortcut: false, chipMaxWidth: nil, titleFits: true)
        }
        // A name too long for any room: the chip takes what is left, never
        // less than its symbol and an ellipsis, and the title keeps its own.
        let minimumChip = chipWidth(text: "…", hasSymbol: hasSymbol, shortcut: nil)
        return HUDHeaderFit(
            showsShortcut: false,
            chipMaxWidth: max(minimumChip, room),
            titleFits: titleWidth + gap + badge + minimumChip <= row
        )
    }

    /// Slack for the difference between AppKit's measurement and SwiftUI's
    /// text layout (sub-point rounding, the capsule's hairline).
    static let safety: CGFloat = 4

    static func measure(_ text: String, size: CGFloat, weight: NSFont.Weight, monospaced: Bool = false) -> CGFloat {
        let font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
