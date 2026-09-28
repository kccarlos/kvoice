import Foundation
import KvoiceDomain
import XCTest
@testable import KvoiceAppleIntelligence

/// Runs the real client against Apple's on-device model on the developer's
/// machine (ADR-024). Skipped unless `KVOICE_LIVE_AI_TESTS=1` is set *and*
/// `SystemLanguageModel.default.availability` is `.available`, so the
/// ordinary suite stays hermetic and model-free. This is also the re-test
/// procedure Apple asks for: the system model changes with OS releases, so
/// these run again after every macOS update (`/ai-live-check`).
///
/// What is printed: the availability, the context size, the supported
/// languages, token counts and durations — scalars. The model's reply is
/// asserted on and never printed, so a log of this run carries no model
/// output.
///
///     KVOICE_LIVE_AI_TESTS=1 ./Scripts/test.sh --filter AppleIntelligenceLiveTests
final class AppleIntelligenceLiveTests: XCTestCase {
    private var client: AppleIntelligenceProcessingClient!

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KVOICE_LIVE_AI_TESTS"] == "1",
            "live on-device tests are opt-in (KVOICE_LIVE_AI_TESTS=1)"
        )
        client = AppleIntelligenceProcessingClient()
    }

    /// The generation tests need the model; the facts test does not (the
    /// context size and the language list are readable while it downloads).
    private func skipUnlessAvailable() async throws {
        let availability = await client.availability()
        print("apple-intelligence availability: \(availability)")
        try XCTSkipUnless(availability.isAvailable, "Apple Intelligence is not available on this Mac: \(availability)")
    }

    private func settings() -> AIEndpointSettings {
        var settings = AIEndpointSettings(isEnabled: true, provider: .appleIntelligence)
        settings.seedBuiltInPromptModesIfNeeded()
        return settings
    }

    func testFactsTheADRRecords() async throws {
        let runtime = FoundationModelsRuntime()
        let availability = runtime.availability()
        print("apple-intelligence availability: \(availability)")
        let contextSize = await runtime.contextSize()
        let languages = await runtime.supportedLanguageIdentifiers()
        print("apple-intelligence contextSize: \(contextSize.map(String.init) ?? "unknown (the framework reports 0 while the model is not ready)")")
        print("apple-intelligence supportedLanguages (\(languages.count)): \(languages.joined(separator: " "))")
        XCTAssertFalse(languages.isEmpty)
        guard availability.isAvailable else { return }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(contextSize), 4096)
        let counted = try await runtime.tokenCount(instructions: "Reply briefly.", prompt: "hello world")
        print("apple-intelligence tokenCount(\"Reply briefly.\" + \"hello world\"): \(counted.map(String.init) ?? "unavailable before macOS 26.4")")
    }

    func testConnectionTestPassesRepeatedly() async throws {
        try await skipUnlessAvailable()
        for attempt in 1...3 {
            let started = ContinuousClock().now
            do {
                try await client.testConfiguration(settings())
            } catch {
                XCTFail("attempt \(attempt): \((error as? KVoiceError)?.code.rawValue ?? "\(error)")")
            }
            print("apple-intelligence connection test \(attempt): \(started.duration(to: ContinuousClock().now))")
        }
    }

    func testPolishReturnsCleanedText() async throws {
        try await skipUnlessAvailable()
        var settings = settings()
        settings.apply(promptMode: try XCTUnwrap(settings.promptModes.first { $0.builtInKey == BuiltInPromptModes.Key.clean }))
        let result = try await client.process(
            AIProcessRequest(
                jobID: UUID(),
                mode: .polish,
                rawTranscript: "um so like, please move the, uh, review to friday",
                modelID: "",
                targetLanguage: nil,
                polishPrompt: settings.promptConfiguration.polishPrompt,
                context: AIRequestContext(userProfile: "Role: engineer")
            ),
            settings: settings
        )
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertFalse(result.text.lowercased().contains("<transcript>"), "the envelope must not leak into the reply")
        print("apple-intelligence polish: \(result.text.count) characters in \(result.requestDuration)")
    }

    func testTranslateReturnsText() async throws {
        try await skipUnlessAvailable()
        var settings = settings()
        settings.translationLanguage = TranslationLanguage(bcp47: "zh-Hans", displayName: "Chinese (Simplified)")
        settings.mode = .translate
        let result = try await client.process(
            AIProcessRequest(
                jobID: UUID(),
                mode: .translate,
                rawTranscript: "Please move the review to Friday.",
                modelID: "",
                targetLanguage: settings.translationLanguage,
                polishPrompt: settings.promptConfiguration.polishPrompt
            ),
            settings: settings
        )
        XCTAssertFalse(result.text.isEmpty)
        print("apple-intelligence translate: \(result.text.count) characters in \(result.requestDuration)")
    }

    func testAnOversizedTranscriptFallsBackAsInputTooLong() async throws {
        try await skipUnlessAvailable()
        let long = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 600)
        do {
            _ = try await client.process(
                AIProcessRequest(jobID: UUID(), mode: .polish, rawTranscript: long, modelID: "", targetLanguage: nil, polishPrompt: "Clean up the transcript."),
                settings: settings()
            )
            XCTFail("expected a refusal")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .aiInputTooLong)
            print("apple-intelligence oversized: refused with tokenCount \(error.metadata.tokenCount.map(String.init) ?? "-")")
        }
    }
}

/// ADR-027: what can be read about Private Cloud Compute from a test
/// process — the availability and quota facts, and that the heuristic
/// correctly calls this unsigned process unentitled. **No request is sent**:
/// the test runner has neither the managed entitlement nor a provisioning
/// profile, so a real round trip is only possible from an entitled App Store
/// build (Docs/Verification.md, "Private Cloud Compute"). Opt-in separately
/// from the on-device tests (`KVOICE_LIVE_PCC_TESTS=1`) because reading the
/// facts may itself talk to Apple — that is one of the open questions.
///
///     KVOICE_LIVE_PCC_TESTS=1 ./Scripts/test.sh --filter PrivateCloudComputeLiveTests
final class PrivateCloudComputeLiveTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KVOICE_LIVE_PCC_TESTS"] == "1",
            "live Private Cloud Compute facts are opt-in (KVOICE_LIVE_PCC_TESTS=1)"
        )
    }

    func testFactsTheADRRecords() async throws {
        let runtime = PrivateCloudComputeRuntime()
        print("private-cloud-compute availability: \(runtime.availability())")
        let quota = runtime.quota().map { "\($0.status.rawValue), reset known: \($0.resetDate != nil), can request increase: \($0.canRequestIncrease)" }
        print("private-cloud-compute quota: \(quota ?? "unknown")")
        let contextSize = await runtime.contextSize()
        print("private-cloud-compute contextSize: \(contextSize.map(String.init) ?? "unknown")")
        let languages = await runtime.supportedLanguageIdentifiers()
        print("private-cloud-compute supportedLanguages (\(languages.count)): \(languages.joined(separator: " "))")
        XCTAssertFalse(
            PrivateCloudComputeSigning.currentProcessIsEntitled(bundle: Bundle(for: Self.self)),
            "the test runner carries no provisioning profile"
        )
    }
}
