import Foundation
import KvoiceDomain
import KvoiceTranscription
import XCTest
@testable import KvoiceAppleSpeech

/// Opt-in check against the real Speech framework on this Mac (ADR-025):
///
///     KVOICE_LIVE_MODEL_TESTS=1 ./Scripts/test.sh --filter AppleSpeechLiveTests
///
/// Reports the facts the ADR records — availability, the supported and
/// installed locales, the reservation cap — and, when the English assets are
/// installed for this test process, transcribes the bundled performance
/// sample through the real engine in batch and streaming and prints the
/// real-time factor, the result counts and the latency to the first partial.
/// Scalars only: no transcript is printed. It never installs assets — the
/// tester does that from Speech Models (or the `KVOICE_LIVE_INSTALL_ASSETS=1`
/// opt-in below, which reserves `en_US` for the *test* process — not the
/// app — and releases it again at the end).
///
/// Also the re-test after a macOS update: the locale list and the audio
/// format the platform asks for are OS facts, and both are printed.
final class AppleSpeechLiveTests: XCTestCase {
    private var runtime: SpeechFrameworkRuntime!

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KVOICE_LIVE_MODEL_TESTS"] == "1",
            "live Speech framework tests are opt-in (KVOICE_LIVE_MODEL_TESTS=1)"
        )
        runtime = SpeechFrameworkRuntime()
    }

    func testFactsTheADRRecords() async throws {
        let availability = await runtime.availability()
        print("apple-speech availability: \(availability)")
        let supported = await runtime.supportedLocaleIdentifiers()
        print("apple-speech supportedLocales (\(supported.count)): \(supported.joined(separator: " "))")
        let codes = AppleSpeechLocaleMapping.languageCodes(forSupportedLocales: supported)
        print("apple-speech languageCodes (\(codes.count)): \(codes.joined(separator: " "))")
        print("apple-speech maximumReservedLocales: \(await runtime.maximumReservedLocales)")
        print("apple-speech reservedLocales: \(await runtime.reservedLocaleIdentifiers())")
        guard availability == .available else { return }
        XCTAssertFalse(supported.isEmpty)
        for locale in ["en_US", "zh_CN", "ja_JP"] where supported.contains(locale) {
            print("apple-speech assetStatus \(locale): \(await runtime.assetStatus(localeIdentifier: locale))")
        }
        let shipped = TranscriptionLanguage.appleSpeechShippedLanguageCodes
        if codes != shipped {
            print("apple-speech NOTE: the observed codes differ from the catalog's shipped list — the overlay covers it; update `appleSpeechShippedLanguageCodes` when the deployment target moves")
        }
    }

    func testTranscribeTheBundledSampleBatchAndStreaming() async throws {
        let availability = await runtime.availability()
        try XCTSkipUnless(availability == .available, "no Speech framework here")
        let installedByThisTest = ProcessInfo.processInfo.environment["KVOICE_LIVE_INSTALL_ASSETS"] == "1"
        if installedByThisTest {
            try await runtime.installAssets(localeIdentifier: "en_US") { _ in }
            print("apple-speech installed en_US for the test process")
        }
        let status = await runtime.assetStatus(localeIdentifier: "en_US")
        try XCTSkipUnless(status == .installed, "en_US assets are not installed for this process (KVOICE_LIVE_INSTALL_ASSETS=1 reserves them)")
        let engine = AppleSpeechTranscriptionEngine(runtime: runtime, currentLocale: Locale(identifier: "en_US"))
        let package = InstalledModelPackage.systemManaged(modelID: AppleSpeechTranscriptionEngine.modelID, family: "apple-speech")
        let loadStart = ContinuousClock().now
        try await engine.load(package)
        print("apple-speech load+warmUp: \(loadStart.duration(to: ContinuousClock().now)); warmUp \(await engine.runtimeStatistics.lastWarmUpDuration.map { "\($0)" } ?? "skipped")")

        let sample = try PerformanceSampleAudio.load()
        for pass in 1...2 {
            let result = try await engine.transcribe(
                TranscriptionRequest(jobID: UUID(), audio: sample, languageHint: "en", initialPrompt: "Glossary: KVoice, WhisperKit.")
            ) { _ in }
            let statistics = await engine.runtimeStatistics
            print(String(
                format: "apple-speech batch pass %d: RTF %.3f, inference %@, %d chars, %d segments, punctuation %@, language %@",
                pass,
                statistics.lastRealTimeFactor ?? -1,
                "\(statistics.lastInferenceDuration ?? .zero)",
                result.text.count,
                result.segments.count,
                result.text.contains(where: { ".,?!".contains($0) }) ? "yes" : "no",
                result.detectedLanguage ?? "-"
            ))
            XCTAssertFalse(result.text.isEmpty)
            XCTAssertTrue(result.text.contains(where: { ".,?!".contains($0) }), "the model punctuates")
        }

        // Streaming, paced like the recorder: one 100 ms chunk per 100 ms.
        let partials = PartialTimeline()
        let jobID = UUID()
        let started = ContinuousClock().now
        try await engine.beginStreaming(jobID: jobID, languageHint: "en", initialPrompt: nil) { event in
            if case .partialText(let text) = event { await partials.record(characters: text.count, at: started.duration(to: ContinuousClock().now)) }
        }
        let chunk = 1_600
        var offset = 0
        let samples = Array(sample.samples)
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            await engine.appendStreamingAudio(AudioSampleChunk(samples: ContiguousArray(samples[offset..<end])), jobID: jobID)
            offset = end
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(1))
        await engine.endStreaming(jobID: jobID)
        let timeline = await partials.entries
        print("apple-speech streaming: \(timeline.count) partials over \(sample.duration); first at \(timeline.first.map { "\($0.at)" } ?? "-"), last \(timeline.last?.characters ?? 0) chars at \(timeline.last.map { "\($0.at)" } ?? "-")")
        XCTAssertFalse(timeline.isEmpty, "volatile results become partials")
        await engine.unload()
        if installedByThisTest {
            // Leave the Mac as it was found: the reservation belonged to the
            // test process, not to the app.
            let released = await runtime.releaseAssets(localeIdentifier: "en_US")
            print("apple-speech released the test process's en_US reservation: \(released)")
        }
    }
}

private actor PartialTimeline {
    struct Entry { let characters: Int; let at: Duration }
    private(set) var entries: [Entry] = []
    func record(characters: Int, at: Duration) { entries.append(Entry(characters: characters, at: at)) }
}
