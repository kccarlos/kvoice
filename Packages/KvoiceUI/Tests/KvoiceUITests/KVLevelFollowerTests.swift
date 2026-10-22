import XCTest
@testable import KvoiceUI

/// Motion spec § 4·6: fast attack (0.6 per 16 ms tick), slow release
/// (0.15 per tick), converted to the feed's own interval.
final class KVLevelFollowerTests: XCTestCase {
    func testOneSpecTickIsTheSpecsFactor() {
        var rising = KVLevelFollower()
        XCTAssertEqual(rising.step(raw: 1), 0.6, accuracy: 1e-9)
        var falling = KVLevelFollower(level: 1)
        XCTAssertEqual(falling.step(raw: 0), 0.85, accuracy: 1e-9)
    }

    func testALongerIntervalIsSeveralTicks() {
        var once = KVLevelFollower()
        once.step(raw: 1, elapsed: 0.032)
        var twice = KVLevelFollower()
        twice.step(raw: 1)
        twice.step(raw: 1)
        XCTAssertEqual(once.level, twice.level, accuracy: 1e-9)
    }

    func testAttackIsFasterThanRelease() {
        var up = KVLevelFollower()
        up.step(raw: 1, elapsed: 0.05)
        var down = KVLevelFollower(level: 1)
        down.step(raw: 0, elapsed: 0.05)
        XCTAssertGreaterThan(up.level, 1 - down.level, "it rises faster than it falls")
        XCTAssertGreaterThan(up.level, 0.9, "about 50 ms to (nearly) arrive")
        XCTAssertGreaterThan(down.level, 0.5, "about 200 ms to let go")
    }

    func testClampsAndIgnoresNoTime() {
        var follower = KVLevelFollower(level: 2)
        XCTAssertEqual(follower.level, 1)
        XCTAssertEqual(follower.step(raw: .nan, elapsed: 0), 1, "no time, no change")
        follower.step(raw: -3, elapsed: 10)
        XCTAssertEqual(follower.level, 0, accuracy: 1e-6)
    }

    func testTheHaloFollowsTheWrittenRule() {
        XCTAssertEqual(KVLevelFollower.haloOpacity(level: 0, reduceMotion: false), 0.25)
        XCTAssertEqual(KVLevelFollower.haloOpacity(level: 1, reduceMotion: false), 1)
        XCTAssertEqual(KVLevelFollower.haloOpacity(level: 0.3, reduceMotion: true), 0.8, "Reduce Motion: lit, still")
        XCTAssertEqual(KVLevelFollower.haloScale(level: 1, reduceMotion: false), 1.25, accuracy: 1e-9)
        XCTAssertEqual(KVLevelFollower.haloScale(level: 1, reduceMotion: true), 1)
    }
}
