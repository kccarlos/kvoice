import XCTest
@testable import KvoiceDiagnostics
@testable import KvoiceDomain

/// The file sink exists because OSLog is not always readable, so it has to be
/// dependable on its own: append-only, valid JSON lines, and bounded in size.
final class FileDiagnosticLoggerTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kvoice-diag-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testAppendsOneJSONLinePerEvent() async throws {
        let fileURL = directory.appendingPathComponent("diagnostics.jsonl")
        let logger = FileDiagnosticLogger(fileURL: fileURL)

        await logger.log(
            DiagnosticEvent(
                name: .insertionClipboardFallback,
                result: .warning,
                attributes: DiagnosticAttributes(reason: "notEditable")
            )
        )
        await logger.log(
            DiagnosticEvent(name: .insertionCompleted, result: .success)
        )

        let lines = try String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)

        // Each line must decode independently.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let first = try decoder.decode(DiagnosticEvent.self, from: Data(lines[0].utf8))
        XCTAssertEqual(first.name, .insertionClipboardFallback)
        XCTAssertEqual(first.result, .warning)
        XCTAssertEqual(first.attributes.reason?.rawValue, "notEditable")

        let second = try decoder.decode(DiagnosticEvent.self, from: Data(lines[1].utf8))
        XCTAssertEqual(second.name, .insertionCompleted)
    }

    func testCreatesMissingDirectory() async throws {
        let fileURL = directory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("diagnostics.jsonl")
        let logger = FileDiagnosticLogger(fileURL: fileURL)

        await logger.log(DiagnosticEvent(name: .appLaunch))

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testRotationBoundsTheFileAndKeepsValidLines() async throws {
        let fileURL = directory.appendingPathComponent("diagnostics.jsonl")
        // Small cap so a handful of events triggers rotation.
        let logger = FileDiagnosticLogger(fileURL: fileURL, maximumBytes: 2_048)

        for _ in 0..<200 {
            await logger.log(
                DiagnosticEvent(
                    name: .insertionClipboardFallback,
                    result: .warning,
                    attributes: DiagnosticAttributes(reason: "timeout")
                )
            )
        }

        let size = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? Int ?? 0
        XCTAssertLessThan(size, 8_192, "rotation must bound the file")

        // Every retained line must still be parseable — rotation must cut on a
        // line boundary, not mid-object.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = try String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.isEmpty }
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertNoThrow(
                try decoder.decode(DiagnosticEvent.self, from: Data(line.utf8)),
                "rotation left a truncated line"
            )
        }
    }

    func testCompositeForwardsToEverySink() async throws {
        let fileURL = directory.appendingPathComponent("diagnostics.jsonl")
        let memory = InMemoryDiagnosticLogger()
        let composite = CompositeDiagnosticLogger([
            memory,
            FileDiagnosticLogger(fileURL: fileURL)
        ])

        await composite.log(DiagnosticEvent(name: .insertionCompleted, result: .success))

        let events = await memory.events
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
