import Foundation
import KvoiceDomain

/// What the placement math needs to know about a screen, as plain values so
/// the frame computation is a pure function (`HUDPlacement.frame`) and can be
/// tested against a notched built-in display, a plain one, and an external
/// display without an `NSScreen`. `HUDController` fills it from `NSScreen`.
///
/// Coordinates are AppKit's: origin bottom-left, y grows upward.
public struct HUDScreenGeometry: Equatable, Sendable {
    /// `NSScreen.frame`.
    public var frame: CGRect
    /// `NSScreen.visibleFrame`: the frame minus the menu bar and the Dock.
    public var visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top` (macOS 12+): the height of the camera
    /// housing on a built-in display that has one, otherwise 0.
    public var safeAreaTopInset: CGFloat
    /// `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`: the visible
    /// strips either side of the housing, in global screen coordinates; nil
    /// when the top edge is not obscured. The housing itself is the gap
    /// between them.
    public var auxiliaryTopLeftArea: CGRect?
    public var auxiliaryTopRightArea: CGRect?

    public init(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTopInset: CGFloat = 0,
        auxiliaryTopLeftArea: CGRect? = nil,
        auxiliaryTopRightArea: CGRect? = nil
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTopInset = safeAreaTopInset
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }

    /// The camera housing as a rect in screen coordinates, or nil on a
    /// display without one. Derived from the two auxiliary areas rather
    /// than guessed from a model table, so a future housing width is right
    /// by construction.
    public var notch: CGRect? {
        guard safeAreaTopInset > 0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea,
              right.minX > left.maxX
        else { return nil }
        return CGRect(
            x: left.maxX,
            y: frame.maxY - safeAreaTopInset,
            width: right.minX - left.maxX,
            height: safeAreaTopInset
        )
    }

    /// Height of the menu bar as the system reports it through
    /// `visibleFrame`; 0 while the menu bar is hidden (a full-screen app, or
    /// "Automatically hide and show the menu bar").
    public var menuBarHeight: CGFloat {
        max(0, frame.maxY - visibleFrame.maxY)
    }

    /// The band along the top edge nothing may cover: the housing on a
    /// notched display (the menu bar is exactly that tall there), the menu
    /// bar elsewhere. The notch panel's top edge sits on this line, so it
    /// meets the menu bar without covering a single menu item.
    public var topObstructionHeight: CGFloat {
        max(safeAreaTopInset, menuBarHeight)
    }
}

/// Pure frame computation for the two recorder styles (ADR-021). Kept out of
/// `HUDController` so the geometry has unit tests that need no `NSScreen`.
public enum HUDPlacement {
    /// Room either side of the camera housing for the AI indicator on the
    /// left and the meter and clock on the right, so the panel is always
    /// wider than the housing it hangs from.
    public static let notchSidePadding: CGFloat = 56
    /// D.3's clamp: the mini pill keeps this much clear of the visible
    /// frame's edges.
    public static let miniInset: CGFloat = 8

    /// The width the notch-style content should be laid out at on `screen`:
    /// its own minimum, widened to clear the housing plus the side padding.
    public static func notchContentWidth(minimum: CGFloat, screen: HUDScreenGeometry) -> CGFloat {
        let housingWidth = screen.notch?.width ?? 0
        return max(minimum, housingWidth + 2 * notchSidePadding).rounded()
    }

    /// The panel frame for `style` given the content's fitting size.
    ///
    /// - Mini: D.3 — centred horizontally on the visible frame, bottom edge
    ///   22 % of the visible height above its bottom, clamped inside it.
    /// - Notch: hanging from the top obstruction line, centred on the
    ///   housing when there is one and on the screen otherwise, clamped
    ///   horizontally inside the screen. The height is the content's; the
    ///   panel therefore never reaches into the menu bar.
    public static func frame(
        for style: HUDStyle,
        contentSize: CGSize,
        screen: HUDScreenGeometry
    ) -> CGRect {
        switch style {
        case .mini:
            return miniFrame(contentSize: contentSize, visibleFrame: screen.visibleFrame)
        case .notch:
            return notchFrame(contentSize: contentSize, screen: screen)
        }
    }

    private static func miniFrame(contentSize: CGSize, visibleFrame: CGRect) -> CGRect {
        let width = contentSize.width
        let height = contentSize.height
        let desiredBottom = visibleFrame.minY + visibleFrame.height * 0.22
        let inset = miniInset

        let x = min(
            max(visibleFrame.minX + inset, visibleFrame.midX - width / 2),
            max(visibleFrame.minX + inset, visibleFrame.maxX - width - inset)
        )
        let y = min(
            max(visibleFrame.minY + inset, desiredBottom - height),
            max(visibleFrame.minY + inset, visibleFrame.maxY - height - inset)
        )
        return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height.rounded())
    }

    private static func notchFrame(contentSize: CGSize, screen: HUDScreenGeometry) -> CGRect {
        let width = contentSize.width
        let height = contentSize.height
        let frame = screen.frame
        let centreX = screen.notch?.midX ?? frame.midX
        let top = frame.maxY - screen.topObstructionHeight

        let x = min(
            max(frame.minX, centreX - width / 2),
            max(frame.minX, frame.maxX - width)
        )
        let y = max(frame.minY, top - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height.rounded())
    }
}
