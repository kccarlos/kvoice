import AppKit

/// Loads the menu-bar glyph (`Apps/KvoiceApp/Resources/MenuBarLogo.svg`) as
/// a template image at menu-bar size. The halo is drawn in code since UI v2
/// fidelity F1 (`StatusItemIconController`).
///
/// Lives here rather than in the app shell so the one property the menu bar
/// depends on, that both images are templates AppKit can tint and invert, is
/// unit-tested against the real files. `StatusItemIconController` finds the
/// URLs in the app bundle and hands them to `templateImage(contentsOf:)`.
public enum StatusItemArtwork {
    /// The glyph's resource name (an SVG in the app bundle).
    public static let glyphResourceName = "MenuBarLogo"

    /// Height of the image in points. The SVG's viewBox is 20 units tall
    /// around the design's 20 × 16 drawing, so one unit is one point.
    public static let imageHeight: CGFloat = 20

    /// The image at `url` as a template, scaled to `imageHeight` with its
    /// aspect ratio kept. Nil when the file is missing or is not an image
    /// NSImage can read (a double hyphen inside an SVG comment is the usual
    /// cause, and fails silently).
    @MainActor
    public static func templateImage(contentsOf url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = scaled(image.size)
        return image
    }

    static func scaled(_ size: NSSize) -> NSSize {
        guard size.height > 0 else { return size }
        return NSSize(width: (size.width / size.height) * imageHeight, height: imageHeight)
    }
}
