import AppKit
import KvoiceUI

/// The shell's half of the menu-bar icon: find the bundled artwork and hand
/// it to `StatusItemIconController` (KvoiceUI), which draws the glyph, the
/// halo, the badge and the download ring.
extension StatusItemIconController {
    convenience init(button: NSButton) {
        self.init(
            button: button,
            glyph: Self.loadImage(named: StatusItemArtwork.glyphResourceName)
        )
    }

    /// Looked up by explicit URL rather than `NSImage(named:)`, which does not
    /// reliably resolve a bare `.svg` in the bundle's Resources. Returned as a
    /// template at menu-bar size.
    private static func loadImage(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg") else {
            return nil
        }
        return StatusItemArtwork.templateImage(contentsOf: url)
    }
}
