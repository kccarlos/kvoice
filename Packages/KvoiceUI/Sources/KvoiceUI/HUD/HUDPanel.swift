import AppKit

/// Borderless, non-activating host for the render-only HUD.
@MainActor
public final class HUDPanel: NSPanel {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public init(contentView: NSView? = nil) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 88),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        ignoresMouseEvents = true
        isMovable = false
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isExcludedFromWindowsMenu = true
        self.contentView = contentView
    }

    /// Showing is deliberately separate from `makeKeyAndOrderFront`: the HUD
    /// must never activate itself or steal the target application's focus.
    public func showWithoutActivating() {
        orderFrontRegardless()
    }
}
