import AppKit
import SwiftUI
import XCTest
@testable import KvoiceUI

/// UI v2 shared components beyond the tokens: `StatusPill` (status is a
/// dot and words, never colour alone) and the keycap sizes.
@MainActor
final class DesignComponentTests: XCTestCase {
    func testStatusPillDotTakesTheSolidAndWordsStayQuietWhenGood() {
        XCTAssertEqual(StatusPill.dotToken(for: .ok), .ok)
        XCTAssertEqual(StatusPill.textToken(for: .ok), .text2)
        XCTAssertFalse(StatusPill.isEmphasized(.ok))
        XCTAssertEqual(StatusPill.dotToken(for: .neutral), .text2)
        XCTAssertEqual(StatusPill.textToken(for: .neutral), .text2)
    }

    func testStatusPillWordsTakeTheInkWhenTheyAskSomething() {
        for tone in [KVTone.warn, .err, .voice, .cursor] {
            XCTAssertEqual(StatusPill.dotToken(for: tone), tone.solid, "\(tone)")
            XCTAssertEqual(StatusPill.textToken(for: tone), tone.ink, "\(tone)")
            XCTAssertTrue(StatusPill.isEmphasized(tone), "\(tone)")
        }
    }

    /// The chip form (the wizard's cards) speaks in the tone's ink for every
    /// tone, on the tone's soft shade.
    func testFilledPillWordsTakeTheInkForEveryTone() {
        for tone in KVTone.allCases {
            XCTAssertEqual(StatusPill.textToken(for: tone, filled: true), tone.ink, "\(tone)")
        }
        XCTAssertEqual(KVColorToken.inkLine.hex.light, KVColorToken.ink.hex.light, "no outline on the light ground")
    }

    /// The one blue button is blue only while it can be pressed, and white
    /// on it reads (AA for 13 pt semibold needs 4.5:1).
    func testPrimaryButtonGroundAndContrast() {
        XCTAssertEqual(KVPrimaryButtonStyle.ground(isEnabled: true), .cursor)
        XCTAssertEqual(KVPrimaryButtonStyle.ground(isEnabled: false), .fill)
        XCTAssertGreaterThanOrEqual(DesignTokenTests.contrast(0xFFFFFF, KVColorToken.cursor.hex.light), 4.5)
    }

    /// The white mic on the Start Recording disc is a graphical object:
    /// 3:1 (WCAG 1.4.11) in both appearances.
    func testWhiteOnTheVoiceButtonClearsNonTextContrast() {
        let pair = KVColorToken.voiceButton.hex
        XCTAssertGreaterThanOrEqual(DesignTokenTests.contrast(0xFFFFFF, pair.light), 3, "light")
        XCTAssertGreaterThanOrEqual(DesignTokenTests.contrast(0xFFFFFF, pair.dark), 3, "dark")
    }

    /// One render (each costs ~0.4 s of the pre-commit gate); the panel
    /// gallery renders them in both appearances.
    func testComponentsRender() {
        let view = VStack(alignment: .leading, spacing: 8) {
            StatusPill(text: "Ready · Whisper large-v3-turbo")
            StatusPill(text: "Microphone denied", tone: .warn)
            Keycaps(["⌃", "⇧", "Space"], size: .medium)
            Keycaps(["⌃", "Space"], size: .large)
            Keycaps(["⌃", "Space"], size: .large, held: true, reduceMotion: false)
            StatusPill(text: "Not enabled yet", tone: .warn, filled: true)
        }
        .padding(8)
        let image = LayoutSnapshotTests.render(view, size: NSSize(width: 260, height: 200), appearance: .aqua)
        XCTAssertGreaterThan(image.size.width, 0)
    }
}
