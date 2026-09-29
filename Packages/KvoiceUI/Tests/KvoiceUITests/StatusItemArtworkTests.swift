import AppKit
import XCTest
@testable import KvoiceUI

/// The menu-bar glyph and its halo, and the app icon's SVG sources, checked
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

    func testGlyphAndHaloLoadAsTemplatesAtMenuBarHeight() throws {
        for name in [StatusItemArtwork.glyphResourceName, StatusItemArtwork.haloResourceName] {
            let image = try XCTUnwrap(StatusItemArtwork.templateImage(contentsOf: resource(name)), name)
            XCTAssertTrue(image.isTemplate, "\(name) must be a template so AppKit tints and inverts it")
            XCTAssertEqual(image.size.height, StatusItemArtwork.imageHeight, accuracy: 0.001, name)
        }
    }

    func testGlyphAndHaloShareOneSizeSoTheGlyphDoesNotJumpWhenTheGlowAppears() throws {
        let glyph = try XCTUnwrap(StatusItemArtwork.templateImage(contentsOf: resource(StatusItemArtwork.glyphResourceName)))
        let halo = try XCTUnwrap(StatusItemArtwork.templateImage(contentsOf: resource(StatusItemArtwork.haloResourceName)))
        XCTAssertEqual(glyph.size, halo.size)
        XCTAssertEqual(try viewBox(StatusItemArtwork.glyphResourceName), try viewBox(StatusItemArtwork.haloResourceName))
    }

    func testMenuBarArtworkIsMonochrome() throws {
        // A template image uses alpha only; a colour here would be a design
        // mistake that the menu bar silently discards.
        for name in [StatusItemArtwork.glyphResourceName, StatusItemArtwork.haloResourceName] {
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
        let names = ["AppIcon", "AppIcon-16", "AppIcon-32", StatusItemArtwork.glyphResourceName, StatusItemArtwork.haloResourceName]
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
