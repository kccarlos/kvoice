import Foundation
import KvoiceDomain
import KvoiceTestSupport
import XCTest
@testable import KvoiceAppleSpeech

/// ADR-025: the engine over a scripted runtime — load, warm-up, the batch
/// pass, the streaming display, the dictionary as contextual strings, the
/// typed refusals, and the scalars it reports.
final class AppleSpeechTranscriptionEngineTests: XCTestCase {
    private var runtime: FakeAppleSpeechRuntime!
    private var diagnostics: RecordingDiagnostics!
    private var engine: AppleSpeechTranscriptionEngine!
    private let package = InstalledModelPackage.systemManaged(modelID: AppleSpeechTranscriptionEngine.modelID, family: "apple-speech")

    override func setUp() async throws {
        runtime = FakeAppleSpeechRuntime()
        diagnostics = RecordingDiagnostics()
        engine = AppleSpeechTranscriptionEngine(runtime: runtime, diagnostics: diagnostics, currentLocale: Locale(identifier: "en_US"))
    }

    private func recording(seconds: Double = 2) -> AudioRecording {
        let count = Int(seconds * 16_000)
        return AudioRecording(
            samples: ContiguousArray(repeating: 0.01, count: count),
            duration: .seconds(seconds),
            peakLevelDBFS: -20,
            clippedFrameCount: 0
        )
    }

    // MARK: Load

    func testLoadChecksAvailabilityReadsTheLocalesWarmsUpAndReportsReady() async throws {
        try await engine.load(package)
        await XCTAssertEqualAsync(await engine.loadedModelID, "apple-speech")
        guard case .ready(let summary) = await engine.state else { return XCTFail("expected ready") }
        XCTAssertEqual(summary.ownership, .systemManaged)
        XCTAssertEqual(summary.revision, InstalledModelPackage.systemManagedRevision)
        let supported = await engine.supportedLocaleIdentifiers
        await XCTAssertEqualAsync(supported, await runtime.supportedLocaleIdentifiers())
        // The warm-up ran one non-progressive session in the preferred
        // locale (en_US, installed) over the warm-up clip.
        let configurations = await runtime.sessionConfigurations
        XCTAssertEqual(configurations, [AppleSpeechSessionConfiguration(localeIdentifier: "en_US", progressive: false, contextualStrings: [])])
        let session = try await XCTUnwrapAsync(await runtime.sessions.first)
        await XCTAssertEqualAsync(await session.appendedSampleCounts, [WarmUpAudio.samples().count])
        await XCTAssertTrueAsync(await session.finished)
        let statistics = await engine.runtimeStatistics
        XCTAssertNotNil(statistics.lastLoadDuration)
        XCTAssertNotNil(statistics.lastWarmUpDuration)
        let events = await diagnostics.events
        XCTAssertEqual(events.map(\.name), [.modelWarmUpCompleted])
        await XCTAssertEqualAsync(await engine.promptTokenLimit, .phrases(100))
        await XCTAssertNilAsync(await engine.promptTokenCount(of: "anything"))
    }

    func testLoadSkipsTheWarmUpWhenTheLanguagesAssetsAreNotInstalled() async throws {
        await engine.setPreferredLanguageCode("zh")
        try await engine.load(package)
        await XCTAssertEqualAsync(await runtime.sessionConfigurations, [], "zh_CN is supported but not installed: no warm-up session")
        await XCTAssertNilAsync(await engine.runtimeStatistics.lastWarmUpDuration)
        guard case .ready = await engine.state else { return XCTFail("the load still stands") }
    }

    func testLoadRefusesOnAnOlderMacOSAsUnavailableWithTheReason() async throws {
        await runtime.set(availability: .requiresNewerMacOS)
        do {
            try await engine.load(package)
            XCTFail("expected a refusal")
        } catch let error as AppleSpeechTranscriptionError {
            XCTAssertEqual(error, .unavailable(.requiresNewerMacOS))
        }
        await XCTAssertEqualAsync(await engine.state, .unavailable(SystemManagedUnavailableReason.requiresNewerMacOS.modelFailure))
        await XCTAssertNilAsync(await engine.loadedModelID)
        let events = await diagnostics.events
        XCTAssertEqual(events.map(\.name), [.modelLoadCompleted])
        XCTAssertEqual(events.first?.attributes.reason?.rawValue, "requiresNewerMacOS")
    }

    func testLoadRefusesAPackageThatIsNotTheSystemEntry() async throws {
        let whisper = InstalledModelPackage.systemManaged(modelID: "whisper", family: "whisper")
        do {
            try await engine.load(whisper)
            XCTFail("expected a refusal")
        } catch let error as AppleSpeechTranscriptionError {
            XCTAssertEqual(error, .invalidModelPackage("whisper"))
        }
        await XCTAssertNilAsync(await engine.loadedModelID)
    }

    func testUnloadReleasesTheRetainedModels() async throws {
        try await engine.load(package)
        await engine.unload()
        await XCTAssertNilAsync(await engine.loadedModelID)
        await XCTAssertEqualAsync(await engine.state, .absent)
        await XCTAssertEqualAsync(await runtime.retentionReleases, 1)
        await XCTAssertNilAsync(await engine.promptTokenLimit)
    }

    // MARK: Batch

    func testBatchJoinsTheFinalizedPhrasesReportsSegmentsAndScalars() async throws {
        try await engine.load(package)
        await runtime.set(scriptedEvents: [
            .volatile(text: "hel", start: 0, end: 0.5),
            .finalized(text: " Hello there.", start: 0, end: 1.1),
            .finalized(text: "How are you?", start: 1.1, end: 2.0),
            .finalized(text: "   ", start: 2.0, end: 2.0)
        ])
        let request = TranscriptionRequest(jobID: UUID(), audio: recording(seconds: 2), languageHint: "en", initialPrompt: "Glossary: kvoice, WhisperKit.")
        let phases = PhaseCollector()
        let result = try await engine.transcribe(request) { event in await phases.add(event) }
        XCTAssertEqual(result.text, "Hello there. How are you?")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(result.modelID, "apple-speech")
        XCTAssertEqual(result.segments.map(\.text), ["Hello there.", "How are you?"])
        XCTAssertEqual(result.segments.first?.start, .zero)
        XCTAssertEqual(result.segments.last?.end, .seconds(2.0))
        XCTAssertNil(result.timings.runtimeReportedRealTimeFactor)
        await XCTAssertEqualAsync(await phases.events, [.phase(.preparingAudio), .phase(.encoding), .phase(.decoding), .phase(.finalizing)], "no partials on the batch pass")
        let statistics = await engine.runtimeStatistics
        XCTAssertNotNil(statistics.lastRealTimeFactor)
        XCTAssertNotNil(statistics.lastInferenceDuration)
        // The batch session: non-progressive, the dictionary as contextual strings, the whole clip appended once.
        let configuration = try await XCTUnwrapAsync(await runtime.sessionConfigurations.last)
        XCTAssertEqual(configuration, AppleSpeechSessionConfiguration(localeIdentifier: "en_US", progressive: false, contextualStrings: ["kvoice", "WhisperKit"]))
        let session = try await XCTUnwrapAsync(await runtime.sessions.last)
        await XCTAssertEqualAsync(await session.appendedSampleCounts, [32_000])
        await XCTAssertTrueAsync(await session.finished)
    }

    func testBatchWithNoFinalizedResultIsAnEmptyResultNotAFailure() async throws {
        try await engine.load(package)
        await runtime.set(scriptedEvents: [.volatile(text: "um", start: 0, end: 0.3)])
        let result = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: recording())) { _ in }
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.segments, [])
    }

    func testBatchUsesTheMacsLanguageWhenNoHintAndReportsCantoneseForHongKong() async throws {
        let engine = AppleSpeechTranscriptionEngine(runtime: runtime, currentLocale: Locale(identifier: "zh_HK"))
        await runtime.set(status: .installed, for: "zh_HK")
        try await engine.load(package)
        await runtime.set(scriptedEvents: [.finalized(text: "你好", start: 0, end: 1)])
        let result = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: recording())) { _ in }
        await XCTAssertEqualAsync(await runtime.sessionConfigurations.last?.localeIdentifier, "zh_HK")
        XCTAssertEqual(result.detectedLanguage, "yue")
        XCTAssertEqual(result.text, "你好")
    }

    func testTheContextualStringsAreCappedAtOneHundred() {
        let terms = (1...150).map { "term\($0)" }
        let strings = AppleSpeechTranscriptionEngine.contextualStrings(fromRendered: DictionaryPrompt.render(terms: terms))
        XCTAssertEqual(strings.count, AppleSpeechTranscriptionEngine.contextualStringsLimit)
        XCTAssertEqual(strings.first, "term1")
        XCTAssertEqual(strings.last, "term100")
        XCTAssertEqual(AppleSpeechTranscriptionEngine.contextualStrings(fromRendered: nil), [])
    }

    // MARK: Refusals

    func testAnUnsupportedLanguageIsRefusedBeforeAnySessionOpens() async throws {
        try await engine.load(package)
        let sessionsBefore = await runtime.sessions.count
        do {
            _ = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: recording(), languageHint: "fr")) { _ in }
            XCTFail("expected a refusal")
        } catch let error as AppleSpeechTranscriptionError {
            XCTAssertEqual(error, .unsupportedLanguage(code: "fr"))
            XCTAssertTrue(try XCTUnwrap(error.errorDescription).contains("French"))
        }
        await XCTAssertEqualAsync(await runtime.sessions.count, sessionsBefore)
        do {
            try await engine.beginStreaming(jobID: UUID(), languageHint: "fr", initialPrompt: nil) { _ in }
            XCTFail("expected a refusal")
        } catch let error as AppleSpeechTranscriptionError {
            XCTAssertEqual(error, .unsupportedLanguage(code: "fr"))
        }
    }

    func testMissingAssetsAndTheOtherRuntimeErrorsAreTypedAndWrapped() async throws {
        try await engine.load(package)
        await runtime.set(sessionError: .assetsNotInstalled(localeIdentifier: "zh_CN"))
        do {
            _ = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: recording(), languageHint: "zh")) { _ in }
            XCTFail("expected a refusal")
        } catch let error as AppleSpeechTranscriptionError {
            XCTAssertEqual(error, .assetsNotInstalled(localeIdentifier: "zh_CN"))
        }
        await runtime.set(sessionError: .insufficientResources)
        do {
            _ = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: recording())) { _ in }
            XCTFail("expected a failure")
        } catch let error as AppleSpeechTranscriptionError {
            XCTAssertEqual(error, .runtime(.insufficientResources))
        }
        await XCTAssertEqualAsync(await engine.loadedModelID, "apple-speech", "a failed pass leaves the model loaded")
    }

    func testTheEngineRefusesWithoutAModelTheWrongTaskAndTheWrongAudio() async throws {
        do {
            _ = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: recording())) { _ in }
            XCTFail()
        } catch let error as AppleSpeechTranscriptionError {
            XCTAssertEqual(error, .noModelLoaded)
        }
        try await engine.load(package)
        do {
            _ = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: recording(), task: .translate)) { _ in }
            XCTFail()
        } catch let error as AppleSpeechTranscriptionError {
            XCTAssertEqual(error, .unsupportedTask)
        }
        let stereo = AudioRecording(samples: [0, 0], sampleRate: 44_100, channelCount: 2, duration: .seconds(1), peakLevelDBFS: -20, clippedFrameCount: 0)
        do {
            _ = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: stereo)) { _ in }
            XCTFail()
        } catch let error as AppleSpeechTranscriptionError {
            XCTAssertEqual(error, .invalidAudio(sampleRate: 44_100, channelCount: 2))
        }
    }

    // MARK: Streaming

    func testStreamingPublishesFinalizedPlusVolatileTextOnChangeOnly() async throws {
        try await engine.load(package)
        await runtime.set(scriptedEvents: [
            .volatile(text: "Hel", start: 0, end: 0.3),
            .volatile(text: "Hello th", start: 0, end: 0.6),
            .volatile(text: "Hello th", start: 0, end: 0.7),
            .volatile(text: "Hello there.", start: 0, end: 1.0)
        ])
        let partials = PartialCollector()
        let jobID = UUID()
        try await engine.beginStreaming(jobID: jobID, languageHint: "en", initialPrompt: "Glossary: kvoice.") { event in
            if case .partialText(let text) = event { await partials.add(text) }
        }
        let chunk = AudioSampleChunk(samples: ContiguousArray(repeating: 0, count: 1_600))
        for _ in 0..<4 { await engine.appendStreamingAudio(chunk, jobID: jobID) }
        await XCTAssertEqualAsync(await partials.partials, ["Hel", "Hello th", "Hello there."])
        let configuration = try await XCTUnwrapAsync(await runtime.sessionConfigurations.last)
        XCTAssertEqual(configuration, AppleSpeechSessionConfiguration(localeIdentifier: "en_US", progressive: true, contextualStrings: ["kvoice"]))
        // A chunk for another job is dropped.
        await engine.appendStreamingAudio(chunk, jobID: UUID())
        let session = try await XCTUnwrapAsync(await runtime.sessions.last)
        await XCTAssertEqualAsync(await session.appendedSampleCounts.count, 4)
        await engine.endStreaming(jobID: jobID)
        await XCTAssertTrueAsync(await session.cancelled)
        // Nothing after the session ended.
        await engine.appendStreamingAudio(chunk, jobID: jobID)
        await XCTAssertEqualAsync(await partials.partials.count, 3)
        await engine.endStreaming(jobID: jobID) // idempotent
    }

    func testAFinalizedResultClosesTheRangeAndLaterVolatileTextAppends() async throws {
        try await engine.load(package)
        let partials = PartialCollector()
        let jobID = UUID()
        await runtime.set(scriptedEvents: [
            .volatile(text: "Hello", start: 0, end: 0.5),
            .finalized(text: "Hello there.", start: 0, end: 1),
            .volatile(text: "How", start: 1, end: 1.3)
        ])
        try await engine.beginStreaming(jobID: jobID, languageHint: nil, initialPrompt: nil) { event in
            if case .partialText(let text) = event { await partials.add(text) }
        }
        await XCTAssertEqualAsync(await runtime.sessionConfigurations.last?.localeIdentifier, "en_US", "no hint: the Mac's language")
        let chunk = AudioSampleChunk(samples: ContiguousArray(repeating: 0, count: 160))
        await engine.appendStreamingAudio(chunk, jobID: jobID)
        // The fake delivers finalized events on `finish`; the engine never
        // finishes a streaming session, so deliver them the way the platform
        // would — through the handler the runtime was given.
        let session = try await XCTUnwrapAsync(await runtime.sessions.last)
        try await session.finish()
        await engine.appendStreamingAudio(chunk, jobID: jobID)
        await XCTAssertEqualAsync(await partials.partials, ["Hello", "Hello there.", "Hello there. How"])
        await engine.endStreaming(jobID: jobID)
    }

    func testTheBatchPassTearsDownALiveStreamingSessionFirst() async throws {
        try await engine.load(package)
        let jobID = UUID()
        try await engine.beginStreaming(jobID: jobID, languageHint: "en", initialPrompt: nil) { _ in }
        let streamingSession = try await XCTUnwrapAsync(await runtime.sessions.last)
        await runtime.set(scriptedEvents: [.finalized(text: "Done.", start: 0, end: 1)])
        let result = try await engine.transcribe(TranscriptionRequest(jobID: jobID, audio: recording(), languageHint: "en")) { _ in }
        await XCTAssertTrueAsync(await streamingSession.cancelled)
        XCTAssertEqual(result.text, "Done.")
        await XCTAssertEqualAsync(await runtime.sessions.count, 3, "warm-up, streaming, batch")
        // A second streaming session while one is open is refused.
        try await engine.beginStreaming(jobID: jobID, languageHint: "en", initialPrompt: nil) { _ in }
        do {
            try await engine.beginStreaming(jobID: UUID(), languageHint: "en", initialPrompt: nil) { _ in }
            XCTFail()
        } catch let error as AppleSpeechTranscriptionError {
            XCTAssertEqual(error, .streamingSessionActive(jobID))
        }
        await engine.endStreaming(jobID: jobID)
    }

    // MARK: Helpers

    func testSegmentsAndJoinAreTrimmedAndOrdered() {
        let finals: [AppleSpeechResultEvent] = [
            .finalized(text: " A. ", start: -0.5, end: 1),
            .finalized(text: "", start: 1, end: 1),
            .finalized(text: "B?", start: 3, end: 2)
        ]
        let segments = AppleSpeechTranscriptionEngine.segments(from: finals)
        XCTAssertEqual(segments.map(\.text), ["A.", "B?"])
        XCTAssertEqual(segments[0].start, .zero, "a negative start clamps to zero")
        XCTAssertEqual(segments[1].end, .seconds(3), "an inverted range collapses to its start")
        XCTAssertEqual(AppleSpeechTranscriptionEngine.join([" A. ", "", "B?"]), "A. B?")
        XCTAssertEqual(AppleSpeechTranscriptionEngine.languageCode(forLocaleIdentifier: "zh_CN"), "zh")
        XCTAssertEqual(AppleSpeechTranscriptionEngine.languageCode(forLocaleIdentifier: "yue_CN"), "yue")
        XCTAssertEqual(AppleSpeechTranscriptionEngine.languageCode(forLocaleIdentifier: "zh_HK"), "yue")
        XCTAssertNil(AppleSpeechTranscriptionEngine.languageCode(forLocaleIdentifier: "mul_IN"))
        XCTAssertEqual(AppleSpeechTranscriptionEngine.realTimeFactor(inference: .seconds(1), audio: .seconds(4)), 0.25)
        XCTAssertNil(AppleSpeechTranscriptionEngine.realTimeFactor(inference: .seconds(1), audio: .zero))
    }
}

private actor PartialCollector {
    var partials: [String] = []
    func add(_ text: String) { partials.append(text) }
}

private actor PhaseCollector {
    var events: [TranscriptionEvent] = []
    func add(_ event: TranscriptionEvent) { events.append(event) }
}

actor RecordingDiagnostics: DiagnosticLogging {
    private(set) var events: [DiagnosticEvent] = []

    func log(_ event: DiagnosticEvent) async {
        events.append(event)
    }
}
