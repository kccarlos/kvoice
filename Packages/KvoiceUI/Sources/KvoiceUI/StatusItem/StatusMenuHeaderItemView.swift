import AppKit
import SwiftUI

/// The `NSMenuItem.view` host for `StatusMenuHeaderView` (P-D3). It goes on
/// the Start Recording item itself — the item keeps its title, target,
/// action and enabled state — so the menu's own machinery still owns what
/// a custom view would otherwise lose:
///
/// - **Keyboard.** Arrow keys highlight an enabled item whether or not it
///   has a view; `NSMenuItem.isHighlighted` flips and AppKit redraws the
///   view, which is where `draw(_:)` reads it (the documented mechanism,
///   the same one the pointer uses). Return sends the item's action.
///   Type-select and key equivalents "continue to use the key equivalent
///   and title as normal" (`NSMenuItem.view`).
/// - **VoiceOver.** The view is not an accessibility element and hides its
///   children, so the menu item — title "Start Recording  ⌃⇧Space", role
///   menu item — is what is read, as before.
/// - **Click.** A view swallows the click the menu would have handled, so
///   `mouseUp` ends tracking and performs the item's action through the
///   menu (`performActionForItem(at:)`), which is also what posts the
///   `NSMenu` action notifications.
/// - **Highlight.** `NSMenu` draws no selection behind a view; a
///   `.selection` `NSVisualEffectView` (emphasized, behind-window, the
///   material a plain item's highlight is made of) is shown while
///   `isHighlighted`, inset like a plain item's rounded highlight.
///
/// Sizing: the frame height is the row height and the width at `install`
/// time is the minimum the menu will give it (`NSMenuItem.view`: "the
/// view's width at the time setView: is called will be treated as the
/// minimum width"); `autoresizingMask` `.width` stretches it to the menu.
/// `NSHostingView.sizingOptions = []` so SwiftUI never fights that frame.
///
/// If manual testing finds the keyboard cannot reach the row, the
/// documented fallback is in `Docs/Architecture.md` (a separate, disabled
/// header item above a plain Start Recording item); nothing else changes.
@MainActor
public final class StatusMenuHeaderItemView: NSView {
    public let model: StatusMenuHeaderModel
    private let highlight = NSVisualEffectView()
    private let hosting: NSHostingView<StatusMenuHeaderView>
    /// A plain item's highlight is inset from the menu edge and rounded;
    /// these match the system look closely enough to read as one menu.
    private static let highlightInsets = NSEdgeInsets(top: 0, left: 5, bottom: 0, right: 5)
    private static let highlightCornerRadius: CGFloat = 5

    /// Puts the row on `item` and returns the host. `item` keeps everything
    /// it had; only its drawing moves into the view.
    @discardableResult
    public static func install(on item: NSMenuItem, model: StatusMenuHeaderModel) -> StatusMenuHeaderItemView {
        let view = StatusMenuHeaderItemView(model: model)
        item.view = view
        return view
    }

    public init(model: StatusMenuHeaderModel) {
        self.model = model
        self.hosting = NSHostingView(rootView: StatusMenuHeaderView(model: model))
        super.init(frame: NSRect(x: 0, y: 0, width: StatusMenuHeaderView.minimumWidth, height: StatusMenuHeaderView.rowHeight))
        autoresizingMask = [.width]

        highlight.material = .selection
        highlight.blendingMode = .behindWindow
        highlight.state = .active
        highlight.isEmphasized = true
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = Self.highlightCornerRadius
        highlight.layer?.cornerCurve = .continuous
        highlight.isHidden = true
        highlight.autoresizingMask = [.width, .height]
        highlight.frame = bounds.insetBy(Self.highlightInsets)
        addSubview(highlight)

        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = bounds
        addSubview(hosting)

        // The menu item is the accessibility element; see the type comment.
        setAccessibilityElement(false)
        hosting.setAccessibilityElement(false)
        hosting.setAccessibilityChildren([])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StatusMenuHeaderItemView is built in code")
    }

    // MARK: Highlight

    /// AppKit redraws a menu item's view when its highlight changes; this
    /// is the one place the state is read, for both the pointer and the
    /// arrow keys.
    public override func draw(_ dirtyRect: NSRect) {
        syncHighlight()
        super.draw(dirtyRect)
    }

    /// The view is added to a window when the menu opens and removed when
    /// it closes (`NSMenuItem.view`); a closed menu highlights nothing and
    /// animates nothing.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        model.isMenuOpen = window != nil
        if window == nil, enclosingMenuItem != nil {
            setHighlighted(false)
        } else {
            syncHighlight()
        }
    }

    /// Outside a menu (the offscreen gallery) there is nothing to consult,
    /// and whatever was set stays.
    private func syncHighlight() {
        guard let item = enclosingMenuItem else { return }
        setHighlighted(item.isHighlighted)
    }

    fileprivate func setHighlighted(_ highlighted: Bool) {
        if highlight.isHidden == highlighted {
            highlight.isHidden = !highlighted
        }
        if model.isHighlighted != highlighted {
            model.isHighlighted = highlighted
        }
    }

    public var isHighlightVisible: Bool { !highlight.isHidden }

    // MARK: Click

    /// Swallowed: the menu's own tracking would otherwise see a press on
    /// a view as nothing, and a press must not fall through to the window.
    public override func mouseDown(with event: NSEvent) {}

    public override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        performItemAction()
    }

    /// Ends tracking, then sends the item's action the way the menu would
    /// have — through `performActionForItem(at:)`, so the target/action
    /// pair and the `NSMenu` action notifications are the item's own. A
    /// disabled item (model not ready, a job finishing) does nothing, like
    /// a disabled plain item.
    public func performItemAction() {
        guard let item = enclosingMenuItem, item.isEnabled, let menu = item.menu else { return }
        let index = menu.index(of: item)
        guard index >= 0 else { return }
        menu.cancelTracking()
        menu.performActionForItem(at: index)
    }
}

private extension NSRect {
    func insetBy(_ insets: NSEdgeInsets) -> NSRect {
        NSRect(
            x: minX + insets.left,
            y: minY + insets.bottom,
            width: width - insets.left - insets.right,
            height: height - insets.top - insets.bottom
        )
    }
}

public extension StatusMenuHeaderItemView {
    /// For the offscreen gallery only, where there is no menu to highlight
    /// the item: shows the selection background and tells the model.
    func setHighlightedForGallery(_ highlighted: Bool) {
        setHighlighted(highlighted)
    }
}
