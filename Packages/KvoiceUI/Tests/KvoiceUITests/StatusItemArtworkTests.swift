import AppKit
import XCTest
@testable import KvoiceUI

/// The menu-bar glyph (its halo is drawn in code since fidelity F1), and the app icon's SVG sources, checked
/// against the real files in `Apps/KvoiceApp/Resources`. The shell has no
/// unit tests, so this is where a broken asset is caught: NSImage rejects an
/// SVG with a double hyphen inside a comment and returns nil without a word,
/// and a glyph that is not a template draws black on a dark menu bar.
@MainActor
final class StatusItemArtworkTests: XCTestCase {
    private static var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Apps/KvoiceApp/Resources", isDirectory: true)
    }

    private func resource(_ name: String) -> URL {
        Self.resources.appendingPathComponent("\(name).svg")
    }

    func testGlyphLoadsAsATemplateAtMenuBarHeight() throws {
        for name in [StatusItemArtwork.glyphResourceName] {
            let image = try XCTUnwrap(StatusItemArtwork.templateImage(contentsOf: resource(name)), name)
            XCTAssertTrue(image.isTemplate, "\(name) must be a template so AppKit tints and inverts it")
            XCTAssertEqual(image.size.height, StatusItemArtwork.imageHeight, accuracy: 0.001, name)
        }
    }

    /// Fidelity F1: the design's glyph — three bars and a microphone in a
    /// 20 × 16 drawing — one viewBox unit per point, 2 units of margin
    /// above and below so the image is the 20 pt the button is sized for.
    func testGlyphIsTheDesignsDrawingAtOnePointPerUnit() throws {
        XCTAssertEqual(try viewBox(StatusItemArtwork.glyphResourceName), "0 -2 20 20")
        let svg = try String(contentsOf: resource(StatusItemArtwork.glyphResourceName), encoding: .utf8)
        XCTAssertTrue(svg.contains("M2 7v2M5 5v6M8 3v10"), "the three level bars")
        XCTAssertTrue(svg.contains(#"stroke-width="1.6""#))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.resources.appendingPathComponent("MenuBarLogoGlow.svg").path), "the halo is drawn in code now")
    }

    func testMenuBarArtworkIsMonochrome() throws {
        // A template image uses alpha only; a colour here would be a design
        // mistake that the menu bar silently discards.
        for name in [StatusItemArtwork.glyphResourceName] {
            let svg = try String(contentsOf: resource(name), encoding: .utf8)
            let colours = matches(of: #"(?:fill|stroke)="([^"]+)""#, in: svg)
            XCTAssertFalse(colours.isEmpty, name)
            XCTAssertEqual(Set(colours).subtracting(["#000", "none"]), [], name)
        }
    }

    func testMissingFileGivesNilRatherThanAnEmptyImage() {
        XCTAssertNil(StatusItemArtwork.templateImage(contentsOf: resource("NoSuchArtwork")))
    }

    func testScalingKeepsTheAspectRatio() {
        let size = StatusItemArtwork.scaled(NSSize(width: 44, height: 40))
        XCTAssertEqual(size.height, StatusItemArtwork.imageHeight)
        XCTAssertEqual(size.width, StatusItemArtwork.imageHeight * 1.1, accuracy: 0.001)
        XCTAssertEqual(StatusItemArtwork.scaled(.zero), .zero)
    }

    /// Every SVG the app and the icon pipeline read: each must parse, and no
    /// comment may contain a double hyphen.
    func testEverySVGSourceLoadsAndHasNoDoubleHyphenInAComment() throws {
        let names = ["AppIcon", "AppIcon-16", "AppIcon-32", StatusItemArtwork.glyphResourceName]
        for name in names {
            let url = resource(name)
            XCTAssertNotNil(NSImage(contentsOf: url), "\(name).svg does not load")
            let svg = try String(contentsOf: url, encoding: .utf8)
            for comment in matches(of: #"<!--([\s\S]*?)-->"#, in: svg) {
                XCTAssertFalse(comment.contains("--"), "\(name).svg has a double hyphen in a comment")
            }
        }
    }

    func testSmallIconArtworkIsDrawnAtItsPixelSize() throws {
        // AppIconRenderer uses AppIcon-<n>.svg for the n-pixel images, so the
        // file must describe exactly n x n.
        for pixels in [16, 32] {
            XCTAssertEqual(try viewBox("AppIcon-\(pixels)"), "0 0 \(pixels) \(pixels)")
        }
    }

    // MARK: Helpers

    private func viewBox(_ name: String) throws -> String {
        let svg = try String(contentsOf: resource(name), encoding: .utf8)
        return try XCTUnwrap(matches(of: #"viewBox="([^"]+)""#, in: svg).first, name)
    }

    private func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
