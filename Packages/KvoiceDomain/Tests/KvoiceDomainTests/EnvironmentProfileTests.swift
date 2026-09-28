import XCTest
@testable import KvoiceDomain

/// ADR-022 slice 5: the observed facts are never persisted or exported.
final class EnvironmentProfileTests: XCTestCase {
    func testIsNeitherEncodableNorDecodable() {
        // The type is deliberately not Codable: no store can take it, and
        // no JSON (bundled, override, backup) can pretend to be it.
        XCTAssertFalse((EnvironmentProfile.self as Any) is any Encodable.Type)
        XCTAssertFalse((EnvironmentProfile.self as Any) is any Decodable.Type)
        // The same holds for the types that are: the guard is meaningful.
        XCTAssertTrue((AppSettings.self as Any) is any Encodable.Type)
        XCTAssertTrue((LocalState.self as Any) is any Encodable.Type)
    }

    func testDerivedFactsFollowTheEngineLimit() {
        XCTAssertNil(EnvironmentProfile.unknown.residentModelAcceptsPrompt)
        XCTAssertFalse(EnvironmentProfile.unknown.residentModelLoaded)
        XCTAssertNil(EnvironmentProfile.unknown.enginePromptTokenCap)

        let whisper = EnvironmentProfile(enginePromptTokenLimit: .tokens(111), residentModelID: "whisper")
        XCTAssertEqual(whisper.residentModelAcceptsPrompt, true)
        XCTAssertTrue(whisper.residentModelLoaded)
        XCTAssertEqual(whisper.enginePromptTokenCap, 111)

        let parakeet = EnvironmentProfile(enginePromptTokenLimit: .unsupported, residentModelID: "parakeet")
        XCTAssertEqual(parakeet.residentModelAcceptsPrompt, false)
        XCTAssertNil(parakeet.enginePromptTokenCap)
    }

    func testUnknownIsAllUnknown() {
        let unknown = EnvironmentProfile.unknown
        XCTAssertNil(unknown.hasNotch)
        XCTAssertNil(unknown.gpuCounterReadable)
        XCTAssertNil(unknown.accessibilityTrusted)
        XCTAssertNil(unknown.chromiumWebContentTarget)
        XCTAssertNil(unknown.lastRealTimeFactor)
        XCTAssertNil(unknown.residentFootprintBytes)
        XCTAssertNil(unknown.placement)
        XCTAssertNil(unknown.runtime)
        XCTAssertNil(unknown.machineClass)
        XCTAssertNil(unknown.appVersion)
        XCTAssertEqual(unknown.memoryPressureLevel, .normal)
        XCTAssertEqual(unknown.computeUnits, .default)
    }
}
