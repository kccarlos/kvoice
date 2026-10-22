import AppKit
import SwiftUI
import XCTest
@testable import KvoiceUI

/// UI v2 design tokens: every token resolves to the design table's value in
/// both appearances, the SwiftUI side follows a forced colour scheme (the
/// Notch HUD), and the text pairs the design relies on clear WCAG AA.
@MainActor
final class DesignTokenTests: XCTestCase {
    private func srgbHex(_ color: NSColor, in appearanceName: NSAppearance.Name) throws -> UInt32 {
        let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB)
        }
        let resolved = try XCTUnwrap(result)
        func byte(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
        return byte(resolved.redComponent) << 16 | byte(resolved.greenComponent) << 8 | byte(resolved.blueComponent)
    }

    func testEveryTokenResolvesToItsDesignValueInBothAppearances() throws {
        for token in KVColorToken.allCases {
            XCTAssertEqual(try srgbHex(token.nsColor, in: .aqua), token.hex.light, "kv.\(token.rawValue) light")
            XCTAssertEqual(try srgbHex(token.nsColor, in: .darkAqua), token.hex.dark, "kv.\(token.rawValue) dark")
            XCTAssertEqual(
                try srgbHex(token.nsColor, in: .accessibilityHighContrastDarkAqua), token.hex.dark,
                "kv.\(token.rawValue) increased-contrast dark"
            )
        }
    }

    /// The design's brand rules: voice brightens one step in dark, cursor
    /// keeps one value so white text on the primary button reads in both.
    func testBrandRules() {
        XCTAssertEqual(KVColorToken.voice.hex.light, 0xF26B1D)
        XCTAssertEqual(KVColorToken.voice.hex.dark, 0xFF7A2F)
        XCTAssertEqual(KVColorToken.cursor.hex.light, KVColorToken.cursor.hex.dark)
        XCTAssertEqual(KVColorToken.ink.hex.light, 0x161D33)
        XCTAssertEqual(Set(KVColorToken.allCases.map(\.rawValue)).count, KVColorToken.allCases.count)
    }

    /// `.environment(\.colorScheme, .dark)` — how the Notch HUD forces its
    /// palette — must reach the dynamic tokens.
    func testSwiftUIColorFollowsTheEnvironmentColorScheme() {
        var light = EnvironmentValues()
        light.colorScheme = .light
        var dark = EnvironmentValues()
        dark.colorScheme = .dark
        func hex(_ resolved: Color.Resolved) -> UInt32 {
            func byte(_ value: Float) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
            return byte(resolved.red) << 16 | byte(resolved.green) << 8 | byte(resolved.blue)
        }
        XCTAssertEqual(hex(Color.kv.voice.resolve(in: light)), KVColorToken.voice.hex.light)
        XCTAssertEqual(hex(Color.kv.voice.resolve(in: dark)), KVColorToken.voice.hex.dark)
        XCTAssertEqual(hex(Color.kv.text2.resolve(in: dark)), KVColorToken.text2.hex.dark)
    }

    // MARK: - Contrast

    private static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    func testContrastHelperMatchesKnownValues() {
        XCTAssertEqual(Self.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(Self.contrast(0x777777, 0x777777), 1, accuracy: 0.001)
    }

    /// Secondary text, the coloured inks on their soft grounds (status
    /// pills, mode chips), the HUD's subtitle and amber hint, and white on
    /// the blue button all clear 4.5:1 in both appearances.
    func testTextPairsClearWCAGAAInBothAppearances() {
        let pairs: [(KVColorToken, KVColorToken)] = [
            (.text2, .bg), (.text2, .surface), (.text2, .hud), (.text2, .fill), (.text, .bg),
            (.cursorInk, .cursorSoft), (.voiceInk, .voiceSoft), (.okInk, .okSoft),
            (.warnInk, .warnSoft), (.errInk, .errSoft), (.warnInk, .hud),
            (.warnInk, .surface), (.errInk, .surface), (.cursorInk, .surface)
        ]
        for (text, ground) in pairs {
            XCTAssertGreaterThanOrEqual(Self.contrast(text.hex.light, ground.hex.light), 4.5, "\(text.rawValue) on \(ground.rawValue), light")
            XCTAssertGreaterThanOrEqual(Self.contrast(text.hex.dark, ground.hex.dark), 4.5, "\(text.rawValue) on \(ground.rawValue), dark")
        }
        XCTAssertGreaterThanOrEqual(Self.contrast(0xFFFFFF, KVColorToken.cursor.hex.light), 4.5, "white on kv.cursor")
    }

    func testToneShadesMapOntoTheirTokens() {
        XCTAssertEqual(KVTone.voice.solid, .voice)
        XCTAssertEqual(KVTone.voice.soft, .voiceSoft)
        XCTAssertEqual(KVTone.cursor.ink, .cursorInk)
        XCTAssertEqual(KVTone.warn.ink, .warnInk)
        XCTAssertEqual(KVTone.err.soft, .errSoft)
        XCTAssertEqual(KVTone.ok.solid, .ok)
        for tone in KVTone.allCases {
            XCTAssertNotEqual(tone.solid, tone.soft, "\(tone)")
        }
    }

    func testMetricScales() {
        XCTAssertEqual(KVSpacing.scale, [4, 8, 12, 16, 24, 32])
        XCTAssertEqual([KVRadius.control, KVRadius.card, KVRadius.panel], [6, 10, 16])
    }
}
