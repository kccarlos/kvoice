import XCTest
import KvoiceDomain
@testable import KvoicePersistence

/// ADR-022 slice 5: the bundled + override merge, and the one scalar line
/// each outcome produces.
final class DeveloperDefaultsLoaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvoice-defaults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, as name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private var bundled: URL {
        get throws {
            let data = try JSONEncoder().encode(DeveloperDefaults.compiled)
            let url = directory.appendingPathComponent("kvoice.defaults.json")
            try data.write(to: url)
            return url
        }
    }

    func testNoFilesGivesTheCompiledValues() {
        let loaded = DeveloperDefaultsLoader(bundledURL: nil, overrideURL: nil).load()
        XCTAssertEqual(loaded, .compiled)
        XCTAssertEqual(loaded.provenance(of: .hybridTapWindowMilliseconds), .default)
        XCTAssertNil(DeveloperDefaultsLoader.diagnosticEvent(for: loaded.overrideOutcome), "an absent file logs nothing")
    }

    func testMissingOverrideFileIsAbsentNotRejected() throws {
        let loader = DeveloperDefaultsLoader(
            bundledURL: try bundled,
            overrideURL: directory.appendingPathComponent("config.override.json")
        )
        XCTAssertEqual(loader.load(), .compiled)
    }

    func testPartialOverrideChangesOnlyItsKeysAndReportsProvenance() throws {
        let override = try write(#"{"hybridTapWindowMilliseconds": 320, "overlappingJobs": true, "unknownKey": 9}"#, as: "config.override.json")
        let loaded = DeveloperDefaultsLoader(bundledURL: try bundled, overrideURL: override).load()
        var expected = DeveloperDefaults.compiled
        expected.hybridTapWindowMilliseconds = 320
        expected.overlappingJobs = true
        XCTAssertEqual(loaded.values, expected)
        XCTAssertEqual(loaded.overriddenKeys, [.hybridTapWindowMilliseconds, .overlappingJobs])
        XCTAssertEqual(loaded.provenance(of: .hybridTapWindowMilliseconds), .override)
        XCTAssertEqual(loaded.provenance(of: .overlappingJobs), .override)
        XCTAssertEqual(loaded.provenance(of: .quietPeakThresholdDBFS), .default)

        let event = try XCTUnwrap(DeveloperDefaultsLoader.diagnosticEvent(for: loaded.overrideOutcome))
        XCTAssertEqual(event.name, .configOverrideLoaded)
        XCTAssertEqual(event.attributes.fileCount, 2)
        XCTAssertNil(event.attributes.site)
    }

    func testOverrideWithOnlyUnknownKeysAppliesNothing() throws {
        let override = try write(#"{"notATunable": true}"#, as: "config.override.json")
        let loaded = DeveloperDefaultsLoader(bundledURL: nil, overrideURL: override).load()
        XCTAssertEqual(loaded.values, .compiled)
        XCTAssertEqual(loaded.overrideOutcome, .applied([]))
    }

    func testMalformedOverrideIsIgnoredWholeWithOneLine() throws {
        let override = try write("{ this is not json", as: "config.override.json")
        let loaded = DeveloperDefaultsLoader(bundledURL: nil, overrideURL: override).load()
        XCTAssertEqual(loaded.values, .compiled)
        XCTAssertEqual(loaded.overrideOutcome, .rejected(reason: .malformed, key: nil))
        let event = try XCTUnwrap(DeveloperDefaultsLoader.diagnosticEvent(for: loaded.overrideOutcome))
        XCTAssertEqual(event.name, .configOverrideRejected)
        XCTAssertEqual(event.attributes.reason?.rawValue, "malformed")
    }

    func testArrayAtTheTopLevelIsRejected() throws {
        let override = try write("[1, 2]", as: "config.override.json")
        let loaded = DeveloperDefaultsLoader(bundledURL: nil, overrideURL: override).load()
        XCTAssertEqual(loaded.overrideOutcome, .rejected(reason: .notAnObject, key: nil))
    }

    func testWrongValueTypeIsMalformed() throws {
        let override = try write(#"{"axFocusRetryCount": "four"}"#, as: "config.override.json")
        let loaded = DeveloperDefaultsLoader(bundledURL: nil, overrideURL: override).load()
        XCTAssertEqual(loaded.values, .compiled)
        XCTAssertEqual(loaded.overrideOutcome, .rejected(reason: .malformed, key: nil))
    }

    func testOutOfRangeValueRejectsTheWholeFileAndNamesTheKey() throws {
        // A good key beside a bad one: neither applies.
        let override = try write(#"{"hybridTapWindowMilliseconds": 320, "silencePeakThresholdDBFS": -1000}"#, as: "config.override.json")
        let loaded = DeveloperDefaultsLoader(bundledURL: nil, overrideURL: override).load()
        XCTAssertEqual(loaded.values, .compiled, "a rejected file applies none of its keys")
        XCTAssertEqual(loaded.overrideOutcome, .rejected(reason: .outOfRange, key: .silencePeakThresholdDBFS))
        let event = try XCTUnwrap(DeveloperDefaultsLoader.diagnosticEvent(for: loaded.overrideOutcome))
        XCTAssertEqual(event.name, .configOverrideRejected)
        XCTAssertEqual(event.attributes.reason?.rawValue, "outOfRange")
        XCTAssertEqual(event.attributes.site?.rawValue, "silencePeakThresholdDBFS")
    }

    func testAnUnreadableBundledFileFallsBackToCompiled() throws {
        let bad = try write("nope", as: "kvoice.defaults.json")
        XCTAssertEqual(DeveloperDefaultsLoader(bundledURL: bad, overrideURL: nil).load(), .compiled)
    }

    func testLoadLogsExactlyOneLineForAnAppliedOverride() async throws {
        let override = try write(#"{"typedChunkPacingMilliseconds": 5}"#, as: "config.override.json")
        let logger = RecordingLogger()
        let loaded = await DeveloperDefaultsLoader(bundledURL: nil, overrideURL: override).load(diagnostics: logger)
        XCTAssertEqual(loaded.values.typedChunkPacingMilliseconds, 5)
        let events = await logger.events
        XCTAssertEqual(events.map(\.name), [.configOverrideLoaded])
    }

    func testStandardPathsPointAtApplicationSupport() throws {
        let url = try XCTUnwrap(DeveloperDefaultsLoader.defaultOverrideURL())
        XCTAssertTrue(url.path.hasSuffix("/kvoice/config.override.json"))
        XCTAssertTrue(url.path.contains("/Library/Application Support/"))
    }
}

private actor RecordingLogger: DiagnosticLogging {
    var events: [DiagnosticEvent] = []
    func log(_ event: DiagnosticEvent) async { events.append(event) }
}
