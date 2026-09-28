import Foundation
import KvoiceDomain
import KvoiceTestSupport
import XCTest
@testable import KvoiceAppleSpeech

/// ADR-025: the `SystemManagedModelAssets` adapter — the platform's answers
/// as the library's states, the language mapped the same way the engine
/// maps it, and every error typed.
final class AppleSpeechModelAssetsTests: XCTestCase {
    private var runtime: FakeAppleSpeechRuntime!
    private var assets: AppleSpeechModelAssets!

    override func setUp() async throws {
        runtime = FakeAppleSpeechRuntime()
        assets = AppleSpeechModelAssets(runtime: runtime, currentLocale: Locale(identifier: "en_US"))
    }

    func testStatesFollowThePlatformPerLanguage() async {
        await XCTAssertEqualAsync(await assets.assetState(languageCode: "en"), .installed)
        await XCTAssertEqualAsync(await assets.assetState(languageCode: nil), .installed, "automatic is the Mac's language, en_US")
        await XCTAssertEqualAsync(await assets.assetState(languageCode: "zh"), .notInstalled)
        await runtime.set(status: .downloading, for: "zh_CN")
        await XCTAssertEqualAsync(await assets.assetState(languageCode: "zh"), .downloading(fraction: 0))
        await XCTAssertEqualAsync(await assets.assetState(languageCode: "fr"), .unavailable(.languageUnsupported))
        await runtime.set(availability: .deviceNotEligible)
        await XCTAssertEqualAsync(await assets.assetState(languageCode: "en"), .unavailable(.deviceNotEligible))
        await runtime.set(availability: .requiresNewerMacOS)
        await XCTAssertEqualAsync(await assets.assetState(languageCode: "en"), .unavailable(.requiresNewerMacOS))
        await XCTAssertEqualAsync(await assets.supportedLanguageCodes(), [], "nothing is supported below macOS 26")
    }

    func testSupportedLanguageCodesAreTheMappingOverThePlatformsLocales() async {
        await XCTAssertEqualAsync(await assets.supportedLanguageCodes(), ["en", "es", "ja", "yue", "zh"])
    }

    func testInstallMapsTheLanguageReportsProgressAndReservesTheLocale() async throws {
        let progress = ProgressCollector()
        try await assets.installAssets(languageCode: "zh") { fraction in progress.add(fraction) }
        await XCTAssertEqualAsync(await runtime.installedLocales, ["zh_CN"])
        await XCTAssertEqualAsync(await runtime.reserved, ["zh_CN"])
        await XCTAssertEqualAsync(await assets.assetState(languageCode: "zh"), .installed)
        XCTAssertEqual(progress.fractions, [0.1, 0.5, 1])
    }

    func testInstallRefusalsAreTyped() async {
        await runtime.set(installError: .tooManyReservedLocales(limit: 5))
        await XCTAssertThrowsSystemManaged(.tooManyReservedLocales) { try await self.assets.installAssets(languageCode: "zh") { _ in } }
        await runtime.set(installError: .downloadFailed)
        await XCTAssertThrowsSystemManaged(.downloadFailed) { try await self.assets.installAssets(languageCode: "zh") { _ in } }
        await runtime.set(installError: .assetsNotInstalled(localeIdentifier: "zh_CN"))
        await XCTAssertThrowsSystemManaged(.assetsMissing) { try await self.assets.installAssets(languageCode: "zh") { _ in } }
        await runtime.set(installError: nil)
        await XCTAssertThrowsSystemManaged(.unavailable(.languageUnsupported)) { try await self.assets.installAssets(languageCode: "fr") { _ in } }
        await runtime.set(availability: .requiresNewerMacOS)
        await XCTAssertThrowsSystemManaged(.unavailable(.requiresNewerMacOS)) { try await self.assets.installAssets(languageCode: "en") { _ in } }
        await XCTAssertEqualAsync(await runtime.installedLocales, [])
    }

    func testReleaseMapsTheLanguageAndIsHarmlessWhenNothingIsReserved() async throws {
        try await assets.installAssets(languageCode: "en") { _ in }
        try await assets.releaseAssets(languageCode: "en")
        await XCTAssertEqualAsync(await runtime.releasedLocales, ["en_US"])
        await XCTAssertEqualAsync(await runtime.reserved, [])
        try await assets.releaseAssets(languageCode: "fr") // unsupported: nothing to release
        try await assets.releaseAssets(languageCode: "ja")
        await XCTAssertEqualAsync(await runtime.releasedLocales, ["en_US", "ja_JP"])
        await runtime.set(availability: .requiresNewerMacOS)
        try await assets.releaseAssets(languageCode: "en")
        await XCTAssertEqualAsync(await runtime.releasedLocales.count, 2, "no framework, no call")
    }

    func testEveryRuntimeErrorMapsToADomainError() {
        XCTAssertEqual(AppleSpeechModelAssets.mapped(.unavailable(.requiresNewerMacOS)), .unavailable(.requiresNewerMacOS))
        XCTAssertEqual(AppleSpeechModelAssets.mapped(.unavailable(.deviceNotEligible)), .unavailable(.deviceNotEligible))
        XCTAssertEqual(AppleSpeechModelAssets.mapped(.unsupportedLanguage(code: "fr")), .unavailable(.languageUnsupported))
        XCTAssertEqual(AppleSpeechModelAssets.mapped(.tooManyReservedLocales(limit: 5)), .tooManyReservedLocales)
        XCTAssertEqual(AppleSpeechModelAssets.mapped(.assetsNotInstalled(localeIdentifier: "x")), .assetsMissing)
        XCTAssertEqual(AppleSpeechModelAssets.mapped(.downloadFailed), .downloadFailed)
        XCTAssertEqual(AppleSpeechModelAssets.mapped(.analysisFailed), .downloadFailed)
    }

    private func XCTAssertThrowsSystemManaged(
        _ expected: SystemManagedAssetError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as SystemManagedAssetError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

/// The progress closure is synchronous, so a lock rather than an actor.
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    var fractions: [Double] { lock.withLock { stored } }

    func add(_ fraction: Double) { lock.withLock { stored.append(fraction) } }
}
