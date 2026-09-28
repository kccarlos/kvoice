import XCTest
import KvoiceDomain
@testable import KvoiceDiagnostics

final class KvoiceDiagnosticsTests: XCTestCase {
    func testInMemoryLoggerRetainsOnlyDiagnosticEnvelope() async {
        let logger = InMemoryDiagnosticLogger()
        await logger.log(DiagnosticEvent(name: .appReady, result: .success))

        let events = await logger.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.name, .appReady)
    }
}
