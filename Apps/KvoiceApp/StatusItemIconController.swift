import AppKit
import KvoiceUI

/// Draws the menu-bar logo, its glow, and the D.1 warning badge.
///
/// The glyph is the status button's own image, so AppKit keeps handling template
/// tinting and the inversion that happens while the menu is open. The glow is a
/// separate overlay whose layer opacity is animated, because a glow baked into a
/// single image cannot pulse. The badge is a second, tiny overlay that is shown
/// or hidden; nothing about it animates.
///
/// Both images come from the same SVG viewBox, so the glyph never changes size
/// when the glow appears; the halo bleeds into margin that is already there. See
/// the comments in `Resources/MenuBarLogo.svg`.
///
/// Cost model: `apply(_:)` is called from a 60 ms poll and returns immediately
/// when the appearance is unchanged. A real change does one frame calculation
/// and installs one Core Animation opacity animation, which then runs on the
/// render server with no per-frame work in the app.
@MainActor
final class StatusItemIconController {
    /// Height of the image in points. The artwork occupies 658/838 of the
    /// viewBox height, so a 20pt image draws a ~15.7pt glyph, which matches the
    /// weight of Apple's own menu-bar glyphs in a 22pt menu bar.
    private static let imageHeight: CGFloat = 20

    private static let pulseAnimationKey = "kvoice.glow.pulse"

    private let button: NSButton
    private let glowView: GlowOverlayView?
    private let badgeView: BadgeOverlayView

    /// The last appearance actually applied, so a 60 ms poll that changes
    /// nothing does not restart the animation.
    private var applied: StatusItemAppearance?

    /// Fails soft: with no bundled artwork the item keeps its text title rather
    /// than becoming an invisible gap in the menu bar.
    init(button: NSButton) {
        self.button = button

        let badge = BadgeOverlayView()
        badge.isHidden = true
        badge.autoresizingMask = [.minXMargin, .minYMargin]
        self.badgeView = badge

        guard let glyph = Self.loadImage(named: "MenuBarLogo") else {
            self.glowView = nil
            button.image = nil
            button.title = "KVoice"
            button.addSubview(badge)
            return
        }

        glyph.isTemplate = true
        glyph.size = Self.scaled(glyph.size)
        button.image = glyph
        button.imagePosition = .imageOnly
        button.title = ""

        guard let halo = Self.loadImage(named: "MenuBarLogoGlow") else {
            self.glowView = nil
            button.addSubview(badge)
            return
        }
        halo.isTemplate = true
        halo.size = Self.scaled(halo.size)

        let overlay = GlowOverlayView(image: halo)
        overlay.wantsLayer = true
        overlay.layer?.opacity = 0
        overlay.isHidden = true
        // Keeps the halo centred on the glyph if the item is ever resized.
        overlay.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        button.addSubview(overlay)
        self.glowView = overlay
        // Above the glow so the badge stays legible while the halo pulses.
        button.addSubview(badge)
    }

    func apply(_ appearance: StatusItemAppearance) {
        guard applied != appearance else { return }
        applied = appearance

        applyBadge(appearance.badge)

        guard let glowView else { return }
        layoutGlowView(glowView)

        guard let glow = appearance.glow else {
            glowView.layer?.removeAnimation(forKey: Self.pulseAnimationKey)
            glowView.layer?.opacity = 0
            glowView.isHidden = true
            return
        }

        glowView.tint = Self.color(for: glow.tint)
        glowView.isHidden = false

        // Replaced wholesale rather than adjusted: the phase changed, so the
        // previous pulse is not worth preserving.
        glowView.layer?.removeAnimation(forKey: Self.pulseAnimationKey)
        glowView.layer?.opacity = Float(glow.peakOpacity)

        // FR-HUD-006 / NFR-A11Y-002: under Reduce Motion the halo is a steady
        // light rather than a pulse. The state is still visible; it just
        // does not breathe.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = glow.troughOpacity
        pulse.toValue = glow.peakOpacity
        // One full dim -> bright -> dim cycle is the stated period, and
        // autoreverse plays it in two halves.
        pulse.duration = glow.pulsePeriod / 2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowView.layer?.add(pulse, forKey: Self.pulseAnimationKey)
    }

    /// Called when the menu bar's appearance may have changed, since the tinted
    /// halo is rendered once per tint and is not automatically re-derived.
    /// The overlays also redraw themselves from
    /// `viewDidChangeEffectiveAppearance`, so this is only needed for a
    /// change the view hierarchy does not observe.
    func refreshForAppearanceChange() {
        glowView?.needsDisplay = true
        badgeView.needsDisplay = true
    }

    // MARK: Layout

    private func layoutGlowView(_ glowView: GlowOverlayView) {
        let size = glowView.image.size
        let bounds = button.bounds
        glowView.frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func applyBadge(_ badge: StatusItemAppearance.Badge?) {
        guard badge != nil else {
            badgeView.isHidden = true
            return
        }
        // Top-right corner of the glyph, overlapping it slightly so the dot
        // reads as attached to the icon rather than floating in the bar.
        let glyphSize = button.image?.size ?? NSSize(width: Self.imageHeight, height: Self.imageHeight)
        let bounds = button.bounds
        let glyphOrigin = NSPoint(
            x: (bounds.width - glyphSize.width) / 2,
            y: (bounds.height - glyphSize.height) / 2
        )
        let diameter = BadgeOverlayView.diameter
        badgeView.frame = NSRect(
            x: glyphOrigin.x + glyphSize.width - diameter + 2,
            y: glyphOrigin.y + glyphSize.height - diameter + 1,
            width: diameter,
            height: diameter
        )
        badgeView.isHidden = false
    }

    // MARK: Assets

    private static func scaled(_ size: NSSize) -> NSSize {
        guard size.height > 0 else { return size }
        return NSSize(
            width: (size.width / size.height) * imageHeight,
            height: imageHeight
        )
    }

    /// Looked up by explicit URL rather than `NSImage(named:)`, which does not
    /// reliably resolve a bare `.svg` in the bundle's Resources.
    private static func loadImage(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private static func color(for tint: StatusItemAppearance.Tint) -> NSColor {
        switch tint {
        case .recording:
            // The system red, so it carries the same "capturing" meaning as the
            // recording indicators elsewhere in macOS.
            return .systemRed
        case .processing:
            return .controlAccentColor
        }
    }
}

/// Draws a tinted template image and lets every click through to the button
/// underneath.
private final class GlowOverlayView: NSView {
    let image: NSImage

    var tint: NSColor = .systemRed {
        didSet {
            guard tint != oldValue else { return }
            needsDisplay = true
        }
    }

    init(image: NSImage) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GlowOverlayView does not support NSCoder construction")
    }

    /// The overlay is decoration. Without this it would swallow clicks on the
    /// status item and the menu would stop opening.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The accent colour is resolved at draw time, so a light/dark or accent
    /// change needs a redraw to pick up the new value.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(origin: .zero, size: bounds.size)
        image.draw(in: rect)
        tint.set()
        rect.fill(using: .sourceAtop)
    }
}

/// A small orange dot with a hairline ring in the menu-bar background colour,
/// so it separates from the glyph on both light and dark bars. Static: the
/// badge never animates.
private final class BadgeOverlayView: NSView {
    static let diameter: CGFloat = 7

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BadgeOverlayView does not support NSCoder construction")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let ring = NSBezierPath(ovalIn: bounds)
        NSColor.windowBackgroundColor.setFill()
        ring.fill()
        let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        NSColor.systemOrange.setFill()
        dot.fill()
    }
}
