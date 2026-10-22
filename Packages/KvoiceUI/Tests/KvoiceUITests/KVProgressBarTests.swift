@testable import KvoiceUI
import XCTest

/// fix/post-0.1.7: the status panel's progress bar stood still while a
/// model loaded (a nil fraction drew a fixed segment). The bar is now the
/// shared `KVProgressBar`; this pins how it chooses to move.
final class KVProgressBarTests: XCTestCase {
    func testOnlyAKnownFractionIsDeterminate() {
        XCTAssertEqual(KVProgressMotion.style(fraction: 0.5, reduceMotion: false), .determinate(0.5))
        XCTAssertEqual(KVProgressMotion.style(fraction: 0.5, reduceMotion: true), .determinate(0.5), "a real fraction still advances under Reduce Motion")
        XCTAssertEqual(KVProgressMotion.style(fraction: 1.4, reduceMotion: false), .determinate(1))
        XCTAssertEqual(KVProgressMotion.style(fraction: nil, reduceMotion: false), .sliding)
        XCTAssertEqual(KVProgressMotion.style(fraction: nil, reduceMotion: true), .still)
    }

    /// The sliding segment enters from the left edge and leaves past the
    /// right one once per period, so it is visibly moving at every moment.
    func testTheSlidingSegmentCrossesTheTrack() {
        let period = KVProgressMotion.slidePeriod
        XCTAssertEqual(KVProgressMotion.slideOffset(at: 0), -KVProgressMotion.segment, accuracy: 1e-9)
        XCTAssertEqual(KVProgressMotion.slideOffset(at: period * 0.999), 1, accuracy: 0.01)
        XCTAssertLessThan(KVProgressMotion.slideOffset(at: period * 0.25), KVProgressMotion.slideOffset(at: period * 0.5))
        XCTAssertEqual(KVProgressMotion.slideOffset(at: period * 3.5), KVProgressMotion.slideOffset(at: period * 0.5), accuracy: 1e-9)
    }
}
