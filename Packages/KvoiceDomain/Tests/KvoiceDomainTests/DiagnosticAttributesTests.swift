import XCTest
@testable import KvoiceDomain

/// `DiagnosticAttributes.publicFields` is the OSLog projection of the typed
/// attributes. A field added to the struct but not to the projection is
/// silently dropped from `log stream` — which happened to `tokenCount` on
/// 2026-09-14 — so every non-nil stored property must appear by name.
final class DiagnosticAttributesTests: XCTestCase {
    func testEveryPopulatedAttributeAppearsInThePublicFields() {
        let attributes = DiagnosticAttributes(
            reason: "dictionaryPromptTruncated",
            site: "verifyCaret",
            segmentCount: 2,
            tokenCount: 7,
            engineStartMilliseconds: 180,
            captureStartMilliseconds: 250,
            leadingPeakDBFS: -31.5,
            recordingSeconds: 3.4,
            sttMilliseconds: 610,
            realTimeFactor: 0.18,
            aiMilliseconds: 900,
            insertionMilliseconds: 30,
            streaming: true,
            instanceCount: 2
        )

        let names = Set(attributes.publicFields.map(\.0))
        for child in Mirror(reflecting: attributes).children {
            guard let label = child.label, !Self.isNil(child.value) else { continue }
            XCTAssertTrue(names.contains(label), "\(label) is set but missing from publicFields")
        }
        XCTAssertTrue(attributes.publicFields.contains { $0 == ("tokenCount", "7") })
        XCTAssertTrue(attributes.publicFields.contains { $0 == ("site", "verifyCaret") })
        XCTAssertTrue(attributes.publicFields.contains { $0 == ("recordingSeconds", "3.4") })
        XCTAssertTrue(attributes.publicFields.contains { $0 == ("realTimeFactor", "0.18") })
        XCTAssertTrue(attributes.publicFields.contains { $0 == ("streaming", "true") })
        XCTAssertTrue(attributes.publicFields.contains { $0 == ("instanceCount", "2") })
    }

    /// The per-job timing scalars (2026-09-16) survive the JSON-lines
    /// encoding the file logger uses, as numbers rather than strings.
    func testTimingScalarsRoundTripThroughJSON() throws {
        let attributes = DiagnosticAttributes(
            engineStartMilliseconds: 180,
            captureStartMilliseconds: 250,
            leadingPeakDBFS: -31.5,
            recordingSeconds: 3.4,
            sttMilliseconds: 610,
            realTimeFactor: 0.18,
            aiMilliseconds: nil,
            insertionMilliseconds: 30,
            streaming: false
        )
        let data = try JSONEncoder().encode(attributes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["engineStartMilliseconds"] as? Int, 180)
        XCTAssertEqual(object["captureStartMilliseconds"] as? Int, 250)
        XCTAssertEqual(object["leadingPeakDBFS"] as? Double, -31.5)
        XCTAssertEqual(object["recordingSeconds"] as? Double, 3.4)
        XCTAssertEqual(object["sttMilliseconds"] as? Int, 610)
        XCTAssertEqual(object["realTimeFactor"] as? Double, 0.18)
        XCTAssertNil(object["aiMilliseconds"], "an absent phase is absent, not zero")
        XCTAssertEqual(object["streaming"] as? Bool, false)
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticAttributes.self, from: data), attributes)
    }

    /// ADR-022 item 9: `site` is a bounded token like `reason` — a path, a
    /// message, or a transcript fragment cannot become one.
    func testSiteIsABoundedTokenNeverFreeText() {
        XCTAssertEqual(DiagnosticAttributes(site: "insert.typedRecheck").site?.rawValue, "insert.typedRecheck")
        XCTAssertNil(DiagnosticAttributes(site: "/Users/someone/Models").site)
        XCTAssertNil(DiagnosticAttributes(site: "hello world").site)
        XCTAssertNil(DiagnosticAttributes(site: "").site)
    }

    private static func isNil(_ value: Any) -> Bool {
        if case Optional<Any>.none = value { return true }
        return false
    }
}
