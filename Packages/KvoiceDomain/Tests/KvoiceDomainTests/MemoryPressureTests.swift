import XCTest
@testable import KvoiceDomain

final class MemoryPressureTests: XCTestCase {
    func testLevelOrdersNormalBelowWarningBelowCritical() {
        XCTAssertLessThan(MemoryPressureLevel.normal, .warning)
        XCTAssertLessThan(MemoryPressureLevel.warning, .critical)
        XCTAssertLessThan(MemoryPressureLevel.normal, .critical)
        XCTAssertFalse(MemoryPressureLevel.critical < .warning)
    }

    func testFootprintBucketBandsAroundTheShippedModelsRange() {
        XCTAssertEqual(MemoryFootprintBucket.token(forBytes: 100 * 1_048_576).rawValue, "lt256mb")
        XCTAssertEqual(MemoryFootprintBucket.token(forBytes: 300 * 1_048_576).rawValue, "256to512mb")
        XCTAssertEqual(MemoryFootprintBucket.token(forBytes: 632 * 1_048_576).rawValue, "512mbto1gb")
        XCTAssertEqual(MemoryFootprintBucket.token(forBytes: 1_200 * 1_048_576).rawValue, "1to1.5gb")
        XCTAssertEqual(MemoryFootprintBucket.token(forBytes: 1_700 * 1_048_576).rawValue, "1.5to2gb")
        XCTAssertEqual(MemoryFootprintBucket.token(forBytes: 3_000 * 1_048_576).rawValue, "gte2gb")
        // Boundaries are inclusive on the low end of each band.
        XCTAssertEqual(MemoryFootprintBucket.token(forBytes: 1_024 * 1_048_576).rawValue, "1to1.5gb")
    }
}
