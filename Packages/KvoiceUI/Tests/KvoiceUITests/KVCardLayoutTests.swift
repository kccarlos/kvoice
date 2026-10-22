import XCTest
@testable import KvoiceUI

/// UI v2 wave 5b: the card layout's breakpoints (Docs/Design/Cards-Layout-Plan.md).
final class KVCardLayoutTests: XCTestCase {
    func testContentColumnIsCappedAndPadded() {
        XCTAssertEqual(KVCardLayout.contentWidth(forPageWidth: 600), 528)
        XCTAssertEqual(KVCardLayout.contentWidth(forPageWidth: 1380), KVCardLayout.maxContentWidth)
        XCTAssertEqual(KVCardLayout.contentWidth(forPageWidth: 10), 0)
    }

    func testRowsStackOnlyBelowTheBreakpoint() {
        XCTAssertFalse(KVCardLayout.isStacked(pageWidth: 0), "an unmeasured page is treated as wide")
        XCTAssertFalse(KVCardLayout.isStacked(pageWidth: 600), "the 820 pt minimum window keeps rows side by side")
        XCTAssertFalse(KVCardLayout.isStacked(pageWidth: 520 + 2 * KVCardLayout.sidePadding))
        XCTAssertTrue(KVCardLayout.isStacked(pageWidth: 519 + 2 * KVCardLayout.sidePadding))
    }
}

/// UI v2 fidelity F3: the Microphone page's 32-segment level meter.
final class KVLevelSegmentsTests: XCTestCase {
    func testLevelLightsSegmentsAndColoursTheTop() {
        XCTAssertEqual(KVLevelSegments.lit(level: 0), 0)
        XCTAssertEqual(KVLevelSegments.lit(level: 0.5625), 18)
        XCTAssertEqual(KVLevelSegments.lit(level: 2), 32, "clamped")
        XCTAssertEqual(KVLevelSegments.lit(level: -1), 0, "clamped")
        XCTAssertEqual(KVLevelSegments.tone(21), .voice)
        XCTAssertEqual(KVLevelSegments.tone(22), .warn)
        XCTAssertEqual(KVLevelSegments.tone(26), .err)
    }
}
