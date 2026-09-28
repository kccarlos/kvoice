import XCTest
@testable import KvoiceDomain

/// ADR-022 item 1: the developer-defaults source. Three guarantees — the
/// bundled JSON equals the compiled values, every key decodes when missing,
/// and no contract is a tunable.
final class DeveloperDefaultsTests: XCTestCase {
    /// `Apps/KvoiceApp/Resources/kvoice.defaults.json`, reached from the
    /// repo path because SwiftPM tests have no app bundle.
    private static var bundledJSONURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KvoiceDomainTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // KvoiceDomain
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Apps/KvoiceApp/Resources/kvoice.defaults.json")
    }

    func testBundledJSONMatchesTheCompiledDefaults() throws {
        let data = try Data(contentsOf: Self.bundledJSONURL)
        let decoded = try JSONDecoder().decode(DeveloperDefaults.self, from: data)
        XCTAssertEqual(decoded, .compiled, "kvoice.defaults.json and DeveloperDefaults.compiled must agree")
        // Every key is present in the file (not merely defaulted on decode),
        // so a developer reading the file sees the whole table.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(DeveloperDefaults.keys))
    }

    func testEveryKeyDecodesWhenMissing() throws {
        // A file with every key removed one at a time still decodes to the
        // compiled value for that key.
        let encoder = JSONEncoder()
        let full = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try encoder.encode(DeveloperDefaults.compiled)) as? [String: Any]
        )
        XCTAssertEqual(Set(full.keys), Set(DeveloperDefaults.keys))
        for key in DeveloperDefaults.keys {
            var partial = full
            partial.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: partial)
            let decoded = try JSONDecoder().decode(DeveloperDefaults.self, from: data)
            XCTAssertEqual(decoded, .compiled, "missing \(key) must fall back to the compiled value")
        }
        // The empty object is the degenerate case.
        XCTAssertEqual(try JSONDecoder().decode(DeveloperDefaults.self, from: Data("{}".utf8)), .compiled)
    }

    func testAPartialFileOverridesOnlyTheKeysItNames() throws {
        let data = Data(#"{"hybridTapWindowMilliseconds": 300, "overlappingJobs": true}"#.utf8)
        let decoded = try JSONDecoder().decode(DeveloperDefaults.self, from: data)
        XCTAssertEqual(decoded.hybridTapWindowMilliseconds, 300)
        XCTAssertTrue(decoded.overlappingJobs)
        var expected = DeveloperDefaults.compiled
        expected.hybridTapWindowMilliseconds = 300
        expected.overlappingJobs = true
        XCTAssertEqual(decoded, expected)
    }

    func testUnknownKeysAreIgnored() throws {
        let data = Data(#"{"notATunable": 1}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(DeveloperDefaults.self, from: data), .compiled)
    }

    func testNoContractIsATunable() {
        for key in DeveloperDefaults.keys {
            let words = Set(DeveloperDefaults.words(in: key))
            let named = words.intersection(DeveloperDefaults.forbiddenKeyWords)
            XCTAssertTrue(
                named.isEmpty,
                "\(key) names a contract (\(named.sorted())); pins, digests, trust, tiers, pasteboard, secure fields and diagnostics stay code"
            )
        }
        // The word splitter the guard relies on.
        XCTAssertEqual(DeveloperDefaults.words(in: "axFocusRetryCount"), ["ax", "focus", "retry", "count"])
        XCTAssertEqual(DeveloperDefaults.words(in: "silencePeakThresholdDBFS"), ["silence", "peak", "threshold", "dbfs"])
        XCTAssertEqual(DeveloperDefaults.words(in: "overlappingJobs"), ["overlapping", "jobs"])
        // And that it would catch what it exists to catch.
        XCTAssertFalse(Set(DeveloperDefaults.words(in: "whisperKitPinVersion")).isDisjoint(with: DeveloperDefaults.forbiddenKeyWords))
        XCTAssertFalse(Set(DeveloperDefaults.words(in: "insertionTierOrder")).isDisjoint(with: DeveloperDefaults.forbiddenKeyWords))
        XCTAssertFalse(Set(DeveloperDefaults.words(in: "allowPasteboardOnSuccess")).isDisjoint(with: DeveloperDefaults.forbiddenKeyWords))
    }

    func testCompiledValuesPassValidation() {
        XCTAssertNil(DeveloperDefaults.compiled.validationFailure)
        // Every numeric key has a bound, so a new field cannot be added
        // without deciding its range.
        for key in DeveloperDefaults.CodingKeys.allCases where key != .overlappingJobs {
            XCTAssertNotNil(DeveloperDefaults.validationBounds[key], "\(key) needs a validation bound")
        }
    }

    func testOutOfRangeValueNamesItsKey() throws {
        var bad = DeveloperDefaults.compiled
        bad.silencePeakThresholdDBFS = -1_000
        XCTAssertEqual(bad.validationFailure, .silencePeakThresholdDBFS)
        bad = .compiled
        bad.automaticBackupRetentionCount = 0
        XCTAssertEqual(bad.validationFailure, .automaticBackupRetentionCount)
        bad = .compiled
        bad.dictionaryReserveFraction = .nan
        XCTAssertEqual(bad.validationFailure, .dictionaryReserveFraction)
        // The quiet gate must sit above the silence gate.
        bad = .compiled
        bad.quietPeakThresholdDBFS = -60
        XCTAssertEqual(bad.validationFailure, .quietPeakThresholdDBFS)
    }

    func testDerivedViewsMirrorTheStaticDefaults() {
        let compiled = DeveloperDefaults.compiled
        XCTAssertEqual(compiled.speechGate, SpeechGate.Thresholds.compiled)
        XCTAssertEqual(compiled.speechGate.silencePeakDBFS, SpeechGate.silencePeakThresholdDBFS)
        XCTAssertEqual(compiled.speechGate.quietPeakDBFS, SpeechGate.quietPeakThresholdDBFS)
        XCTAssertEqual(compiled.speechGate.signalPeakDBFS, SpeechGate.signalPeakThresholdDBFS)
        XCTAssertEqual(compiled.speechGate.trailingSilenceKeepSeconds, SpeechGate.trailingSilenceKeepSeconds)
        XCTAssertEqual(compiled.hybridTapWindow, TriggerSettings.hybridTapWindow)
        XCTAssertEqual(compiled.doublePressWindow, TriggerSettings.doublePressWindow)
        XCTAssertEqual(compiled.dictionaryReserveFraction, DictionaryTokenBudget.reserveFraction)
        XCTAssertEqual(compiled.hudDismissTimings, .compiled)
        XCTAssertEqual(compiled.runtimeExpectations, .compiled)
        XCTAssertEqual(compiled.runtimeExpectations.expectedMaximumRealTimeFactor(for: .cpuOnly), 15.0)
        XCTAssertEqual(compiled.runtimeExpectations.expectedMaximumRealTimeFactor(for: .all), 0.35)
        XCTAssertEqual(compiled.runtimeExpectations.expectedMaximumRealTimeFactor(for: .gpuAndCPU), 0.90)
        XCTAssertFalse(compiled.overlappingJobs, "ADR-022 item 7: overlapping jobs ship off")
    }

    func testSpeechGateFunctionsHonourInjectedThresholds() {
        // A quiet gate raised to −10 dBFS makes a −20 dBFS "thank you" a
        // hallucination; the compiled −28 keeps it.
        XCTAssertFalse(SpeechGate.isLikelyHallucination("Thank you.", peakLevelDBFS: -20))
        let raised = SpeechGate.Thresholds(quietPeakDBFS: -10)
        XCTAssertTrue(SpeechGate.isLikelyHallucination("Thank you.", peakLevelDBFS: -20, thresholds: raised))

        let quiet = [Float](repeating: 0.001, count: 16_000) // ≈ −60 dBFS
        XCTAssertTrue(SpeechGate.isSilent(quiet))
        XCTAssertFalse(SpeechGate.isSilent(quiet, thresholds: SpeechGate.Thresholds(silencePeakDBFS: -70)))
    }
}
