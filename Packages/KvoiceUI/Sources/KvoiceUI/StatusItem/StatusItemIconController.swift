import AppKit
import QuartzCore

/// Draws the menu-bar icon as `Panel.dc.html` draws it (UI v2 fidelity F1):
/// the template glyph (three level bars and a microphone), a soft round
/// halo *behind* it while recording (orange) or processing (blue), the
/// attention dot, and the download ring. In KvoiceUI rather than the app
/// shell so the offscreen gallery renders the real thing; the shell loads
/// the bundled glyph and hands it over
/// (`Apps/KvoiceApp/StatusItemIconController.swift`).
///
/// The glyph is the status button's own image, so AppKit keeps handling
/// template tinting and the inversion while the menu is open. The halo is a
/// radial-gradient layer under it; the dot and the ring are tiny overlays
/// above it. None takes clicks.
///
/// Motion (`Motion.dc.html` § 4·6): the recording halo follows the voice —
/// opacity 0.25 + 0.75·level, scale 0.8 + 0.45·level, through
/// `KVLevelFollower` (fast attack, slow release) — fed by `apply(level:)`
/// from the recorder's rendered state; it is set without implicit
/// animation, so a tick is a property write on the render server and no
/// layout. Processing has no live signal, so it keeps the design's slow
/// breath (1.9 s, 0.35 ↔ 1). Reduce Motion: both halos stay lit, still, at
/// 0.8.
///
/// Cost model: `apply(_:)` is called from a 60 ms poll and returns at once
/// when the appearance is unchanged.
@MainActor
public final class StatusItemIconController {
    private static let pulseAnimationKey = "kvoice.halo.pulse"

    /// The design's halo: a 30 pt circle (the 26 pt icon box, 2 pt
    /// outset) whose gradient fades out at 70 % of its radius.
    public static let haloDiameter: CGFloat = 30
    /// The design's ring: the 26 pt icon box, 2.5 pt thick.
    static let ringDesignDiameter: CGFloat = 26
    static let ringLineWidth: CGFloat = 2.5

    private let button: NSButton
    private let haloView: HaloOverlayView?
    /// The glyph again, above the halo: a subview always draws over the
    /// button's own image, so while the halo is lit the glyph is redrawn
    /// on top of it in the bar's label colour.
    private let glyphView: GlyphOverlayView?
    private let badgeView: BadgeOverlayView
    private let ringView: ProgressRingOverlayView
    private var follower = KVLevelFollower()
    private var lastLevelTick: Date?

    /// The last appearance actually applied, so a 60 ms poll that changes
    /// nothing does not restart the animation.
    private var applied: StatusItemAppearance?

    /// Fails soft: with no artwork (`glyph` nil) the item keeps a text
    /// title rather than becoming an invisible gap in the menu bar.
    public init(button: NSButton, glyph: NSImage?) {
        self.button = button

        let badge = BadgeOverlayView()
        badge.isHidden = true
        self.badgeView = badge

        let ring = ProgressRingOverlayView()
        ring.isHidden = true
        ring.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        self.ringView = ring

        guard let glyph else {
            self.haloView = nil
            self.glyphView = nil
            button.image = nil
            button.title = "KVoice"
            button.addSubview(badge)
            return
        }

        button.image = glyph
        button.imagePosition = .imageOnly
        button.title = ""

        // The design puts the halo *behind* the glyph. A subview always
        // draws over the button's own image, so the halo is a subview and
        // the glyph is drawn once more above it (`GlyphOverlayView`).
        let halo = HaloOverlayView()
        halo.isHidden = true
        halo.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        button.addSubview(halo)
        self.haloView = halo
        let overGlyph = GlyphOverlayView(image: glyph)
        overGlyph.isHidden = true
        overGlyph.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        button.addSubview(overGlyph)
        self.glyphView = overGlyph
        button.addSubview(ring)
        button.addSubview(badge)
    }

    /// Reduce Motion, read when an appearance or a level is applied. The
    /// gallery injects it; the app reads the system setting.
    public var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    public func apply(_ appearance: StatusItemAppearance) {
        guard applied != appearance else { return }
        let previous = applied
        applied = appearance

        applyBadge(appearance.badge)
        applyProgress(appearance.progress)

        // A ring step leaves the halo alone: restarting the pulse on every
        // 2 % of a download would read as a flicker.
        if let previous, previous.glow == appearance.glow { return }

        guard let haloView else { return }
        layoutHalo(haloView)
        haloView.layer?.removeAnimation(forKey: Self.pulseAnimationKey)

        guard let glow = appearance.glow else {
            haloView.isHidden = true
            glyphView?.isHidden = true
            return
        }

        haloView.color = Self.haloColor(for: glow.tint)
        haloView.isHidden = false
        if let glyphView {
            let size = glyphView.image.size
            glyphView.frame = NSRect(x: glyphCenter.x - size.width / 2, y: glyphCenter.y - size.height / 2, width: size.width, height: size.height)
            glyphView.isHidden = false
        }

        if glow.followsLevel {
            // Starts from silence; `apply(level:)` takes it from here.
            follower = KVLevelFollower()
            lastLevelTick = nil
            setHalo(level: 0)
            return
        }

        setHalo(opacity: reduceMotion() ? 0.8 : glow.peakOpacity, scale: 1)
        guard !reduceMotion() else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = glow.troughOpacity
        pulse.toValue = glow.peakOpacity
        // One full dim → bright → dim cycle is the stated period, and
        // autoreverse plays it in two halves.
        pulse.duration = glow.pulsePeriod / 2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        haloView.layer?.add(pulse, forKey: Self.pulseAnimationKey)
    }

    /// The recorder's input level (0…1) while recording, at the feed's own
    /// rate (20 Hz). Ignored unless the applied glow follows the level.
    public func apply(level raw: Double) {
        guard applied?.glow?.followsLevel == true else { return }
        let now = Date()
        let elapsed = lastLevelTick.map { min(max(now.timeIntervalSince($0), 0.016), 0.2) } ?? 0.05
        lastLevelTick = now
        setHalo(level: follower.step(raw: raw, elapsed: elapsed))
    }

    private func setHalo(level: Double) {
        let still = reduceMotion()
        setHalo(
            opacity: KVLevelFollower.haloOpacity(level: level, reduceMotion: still),
            scale: KVLevelFollower.haloScale(level: level, reduceMotion: still)
        )
    }

    private func setHalo(opacity: Double, scale: Double) {
        guard let haloView, let layer = haloView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = Float(opacity)
        // The gradient scales about its own centre (its anchor point).
        haloView.setScale(scale)
        CATransaction.commit()
    }

    /// Called when the menu bar's appearance may have changed. The overlays
    /// also redraw themselves from `viewDidChangeEffectiveAppearance`.
    public func refreshForAppearanceChange() {
        haloView?.needsDisplay = true
        glyphView?.needsDisplay = true
        badgeView.needsDisplay = true
        ringView.needsDisplay = true
    }

    // MARK: Layout

    /// The glyph's centre in the button: AppKit centres the image.
    private var glyphCenter: NSPoint {
        NSPoint(x: button.bounds.midX, y: button.bounds.midY)
    }

    private func layoutHalo(_ haloView: HaloOverlayView) {
        let side = Self.haloDiameter
        haloView.frame = NSRect(x: glyphCenter.x - side / 2, y: glyphCenter.y - side / 2, width: side, height: side)
    }

    /// `Panel.dc.html`: an 8 pt dot with a 1.5 pt ring in the bar's colour,
    /// at the top-right corner of the 26 pt icon box (top 1, right 0) —
    /// moved down just enough to stay inside a short bar.
    private func applyBadge(_ badge: StatusItemAppearance.Badge?) {
        guard badge != nil else {
            badgeView.isHidden = true
            return
        }
        let side = BadgeOverlayView.outerDiameter
        let bounds = button.bounds
        let box = Self.ringDesignDiameter / 2
        let centerX = glyphCenter.x + box - BadgeOverlayView.dotDiameter / 2
        // Design: the dot's top is 1 pt below the box's top.
        var offsetUp = box - 1 - BadgeOverlayView.dotDiameter / 2
        offsetUp = min(offsetUp, bounds.height / 2 - side / 2)
        let centerY = button.isFlipped ? glyphCenter.y - offsetUp : glyphCenter.y + offsetUp
        badgeView.frame = NSRect(x: centerX - side / 2, y: centerY - side / 2, width: side, height: side)
        badgeView.isHidden = false
    }

    private func applyProgress(_ progress: Double?) {
        guard let progress, button.image != nil else {
            ringView.isHidden = true
            return
        }
        let side = Self.ringDiameter(forButtonHeight: button.bounds.height)
        ringView.frame = NSRect(x: glyphCenter.x - side / 2, y: glyphCenter.y - side / 2, width: side, height: side)
        ringView.fraction = progress
        ringView.isHidden = false
    }

    /// The design's 26 pt ring, or the button's height where the bar is
    /// shorter (22–24 pt without a notch), so the ring is never clipped.
    public static func ringDiameter(forButtonHeight height: CGFloat) -> CGFloat {
        guard height > 0 else { return ringDesignDiameter }
        return min(ringDesignDiameter, height)
    }

    // MARK: Colours

    /// The design's two meanings — voice orange while sound is heard,
    /// cursor blue while text is made — as tokens (for the panel and tests).
    public static func token(for tint: StatusItemAppearance.Tint) -> KVColorToken {
        switch tint {
        case .recording: return .voice
        case .processing: return .cursor
        }
    }

    /// The halos' literal colours in `Panel.dc.html`, the same on either
    /// bar: rgba(255,122,47,.85) and rgba(47,111,235,.7).
    public static func haloColor(for tint: StatusItemAppearance.Tint) -> NSColor {
        switch tint {
        case .recording: return NSColor(srgbRed: 1, green: 122 / 255, blue: 47 / 255, alpha: 0.85)
        case .processing: return NSColor(srgbRed: 47 / 255, green: 111 / 255, blue: 235 / 255, alpha: 0.7)
        }
    }

    /// The attention dot: `Panel.dc.html`'s #F29A00 (not a token).
    public static let badgeColor = NSColor(srgbRed: 0xF2 / 255, green: 0x9A / 255, blue: 0, alpha: 1)
}

/// The halo: a circle filled with a radial gradient from the tint at the
/// centre to clear at 70 % of the radius. Decoration; takes no clicks.
private final class HaloOverlayView: NSView {
    private let gradient = CAGradientLayer()

    var color: NSColor = .clear {
        didSet { updateColors() }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: StatusItemIconController.haloDiameter, height: StatusItemIconController.haloDiameter))
        let host = CALayer()
        layer = host
        wantsLayer = true
        gradient.type = .radial
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.locations = [0, 0.7, 1]
        host.addSublayer(gradient)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HaloOverlayView does not support NSCoder construction")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.bounds = bounds
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    func setScale(_ scale: Double) {
        gradient.transform = CATransform3DMakeScale(scale, scale, 1)
    }

    private func updateColors() {
        gradient.colors = [color.cgColor, color.withAlphaComponent(0).cgColor, color.withAlphaComponent(0).cgColor]
        gradient.bounds = bounds
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

/// The template glyph drawn in the bar's label colour, above the halo.
private final class GlyphOverlayView: NSView {
    let image: NSImage

    init(image: NSImage) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GlyphOverlayView does not support NSCoder construction")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Tinted in an image of its own, so `.sourceAtop` composites
        // against the glyph alone, never against what is drawn beneath.
        let image = self.image
        var tint = NSColor.labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
        }
        let tinted = NSImage(size: bounds.size, flipped: false) { rect in
            image.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: bounds)
    }
}

/// The attention dot: 8 pt #F29A00 inside a 1.5 pt ring in the bar's
/// colour (#ECECEF / #23242A — the design's bars; a real bar is
/// translucent, so this is the nearest fixed colour). Static.
private final class BadgeOverlayView: NSView {
    static let dotDiameter: CGFloat = 8
    static let ringWidth: CGFloat = 1.5
    static var outerDiameter: CGFloat { dotDiameter + 2 * ringWidth }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.outerDiameter, height: Self.outerDiameter))
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
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? KVColorToken.srgb(0x23242A) : KVColorToken.srgb(0xECECEF)).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        StatusItemIconController.badgeColor.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: Self.ringWidth, dy: Self.ringWidth)).fill()
    }
}

/// The download ring: a 2.5 pt band — a grey track, rgba(128,128,140,.35),
/// and a cursor-blue (#2F6FEB) arc from twelve o'clock, clockwise, with
/// square ends (the design's conic gradient). Static: it advances when the
/// fraction does and never animates on its own.
private final class ProgressRingOverlayView: NSView {
    var fraction: Double = 0 {
        didSet {
            guard fraction != oldValue else { return }
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: StatusItemIconController.ringDesignDiameter, height: StatusItemIconController.ringDesignDiameter))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ProgressRingOverlayView does not support NSCoder construction")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let line = StatusItemIconController.ringLineWidth
        let rect = bounds.insetBy(dx: line / 2, dy: line / 2)
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = line
        NSColor(srgbRed: 128 / 255, green: 128 / 255, blue: 140 / 255, alpha: 0.35).setStroke()
        track.stroke()

        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return }
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let arc = NSBezierPath()
        let start: CGFloat = isFlipped ? -90 : 90
        let sweep = CGFloat(clamped) * 360
        arc.appendArc(
            withCenter: center,
            radius: rect.width / 2,
            startAngle: start,
            endAngle: isFlipped ? start + sweep : start - sweep,
            clockwise: !isFlipped
        )
        arc.lineWidth = line
        arc.lineCapStyle = .butt
        NSColor(srgbRed: 0x2F / 255, green: 0x6F / 255, blue: 0xEB / 255, alpha: 1).setStroke()
        arc.stroke()
    }
}
