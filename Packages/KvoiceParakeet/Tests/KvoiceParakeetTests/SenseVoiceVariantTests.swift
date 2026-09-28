import Foundation
import KvoiceDomain
import KvoiceModelManagement
import KvoiceTranscription
import XCTest
@testable import KvoiceParakeet

/// ADR-019 amendment (2026-09-16, second model): the SenseVoice Small
/// variant against the fake runtime and a fake-but-verifiable package, plus
/// the pure pieces the FluidAudio pipeline calls (tag parsing, the encoder
/// choice per compute-unit setting, the long-recording chunker, the join).
/// Nothing here loads Core ML or touches the network; the live checks are
/// `LiveSenseVoiceEncoderMatrixTests` and `LiveParakeetModelTests`.
final class SenseVoiceVariantTests: XCTestCase {
    private var fixtures: [FakeParakeetPackage] = []

    override func tearDown() {
        fixtures.forEach { $0.remove() }
        fixtures = []
        super.tearDown()
    }

    private func fixture() throws -> FakeParakeetPackage {
        let fixture = try FakeParakeetPackage.make(variant: .senseVoiceSmall)
        fixtures.append(fixture)
        return fixture
    }

    // MARK: Variant table

    func testVariantIsResolvedFromTheManifestAndDescribesThePackage() throws {
        let fixture = try fixture()
        XCTAssertEqual(ParakeetModelVariant(manifest: fixture.package.manifest), .senseVoiceSmall)
        XCTAssertEqual(fixture.package.manifest.family, "sensevoice-small")
        XCTAssertEqual(fixture.package.manifest.source.subdirectory, "", "published at the repository root")
        XCTAssertEqual(ParakeetModelVariant.senseVoiceSmall.requiredArtifactRoots, [
            "model/SenseVoicePreprocessor.mlmodelc",
            "model/SenseVoiceSmall_int8.mlmodelc",
            "model/SenseVoiceSmall_fp32.mlmodelc",
            "model/vocab.json"
        ])
        XCTAssertFalse(
            ParakeetModelVariant.senseVoiceSmall.requiredArtifactRoots.contains("model/" + SenseVoiceEncoderGraph.fp16NeuralEngine.bundle),
            "the fp16 export is not part of the package"
        )
        XCTAssertFalse(ParakeetModelVariant.senseVoiceSmall.supportsStreaming, "non-autoregressive: one pass, no partials")
        XCTAssertTrue(ParakeetModelVariant.senseVoiceSmall.emitsPunctuation, "under withitn; measured 2026-09-16")
        XCTAssertEqual(ParakeetModelVariant.senseVoiceSmall.languageCodes, ["zh", "en", "yue", "ja", "ko"])
        // Every choice is accepted — with the graph chosen per choice
        // (below), each pair run in its own process on 2026-09-16.
        for units in SpeechComputeUnits.allCases {
            XCTAssertTrue(ParakeetModelVariant.senseVoiceSmall.supportsComputeUnits(units), units.rawValue)
        }
        // The generator preset and the variant name the same bundles, with
        // the Neural Engine encoder as the graph the Runtime card plans.
        let configuration = try XCTUnwrap(
            ModelManifestGeneratorConfiguration.fluidAudio(modelID: KvoiceFluidAudioModels.senseVoiceSmallModelID)
        )
        XCTAssertEqual(
            Set(configuration.modelRoles.keys),
            Set(ParakeetModelVariant.senseVoiceSmall.requiredArtifactRoots.map { String($0.dropFirst("model/".count)) })
        )
        XCTAssertEqual(configuration.modelRoles["SenseVoicePreprocessor.mlmodelc"], .melSpectrogram)
        XCTAssertEqual(configuration.modelRoles["SenseVoiceSmall_int8.mlmodelc"], .audioEncoder)
        XCTAssertEqual(configuration.modelRoles["SenseVoiceSmall_fp32.mlmodelc"], .otherRequired)
        XCTAssertEqual(configuration.modelRoles["vocab.json"], .tokenizer)
        XCTAssertNil(configuration.modelRoles.values.first { $0 == .textDecoder }, "greedy CTC on the host: no decoder graph")
        XCTAssertEqual(configuration.source.subdirectory, "")
        XCTAssertEqual(configuration.tokenizer.relativeRoot, "model")
    }

    // MARK: The encoder per compute-unit choice

    func testANonNeuralEngineChoicePicksTheFP32Graph() {
        XCTAssertEqual(ParakeetModelVariant.senseVoiceEncoderGraph(for: .neuralEngineAndCPU), .int8NeuralEngine)
        XCTAssertEqual(ParakeetModelVariant.senseVoiceEncoderGraph(for: .cpuOnly), .fp32, "the fp16/int8 graphs are NaN on the CPU")
        XCTAssertEqual(ParakeetModelVariant.senseVoiceEncoderGraph(for: .gpuAndCPU), .fp32)
        XCTAssertEqual(ParakeetModelVariant.senseVoiceEncoderGraph(for: .all), .fp32, "the card measured all-NaN under .all as well")
        for units in SpeechComputeUnits.allCases {
            let graph = ParakeetModelVariant.senseVoiceEncoderGraph(for: units)
            XCTAssertTrue(
                ParakeetModelVariant.senseVoiceSmall.requiredArtifactRoots.contains("model/" + graph.bundle),
                "\(units.rawValue) picks a graph the package holds"
            )
        }
        XCTAssertEqual(SenseVoiceEncoderGraph.int8NeuralEngine.bundle, "SenseVoiceSmall_int8.mlmodelc")
        XCTAssertEqual(SenseVoiceEncoderGraph.fp32.bundle, "SenseVoiceSmall_fp32.mlmodelc")
        XCTAssertEqual(SenseVoiceEncoderGraph.fp16NeuralEngine.bundle, "SenseVoiceSmall.mlmodelc")
        XCTAssertEqual(SenseVoiceEncoderGraph.preprocessorBundle, "SenseVoicePreprocessor.mlmodelc")
        XCTAssertEqual(SenseVoiceEncoderGraph.textNormWithITN, 14)
        XCTAssertEqual(SenseVoiceEncoderGraph.bucket(forFrames: 1), 128)
        XCTAssertEqual(SenseVoiceEncoderGraph.bucket(forFrames: 128), 128)
        XCTAssertEqual(SenseVoiceEncoderGraph.bucket(forFrames: 129), 256)
        XCTAssertEqual(SenseVoiceEncoderGraph.bucket(forFrames: 1_700), 1_800)
        XCTAssertEqual(SenseVoiceEncoderGraph.bucket(forFrames: 5_000), 1_800, "clamped; the chunker keeps windows far below it")
        XCTAssertEqual(SenseVoiceEncoderGraph.minimumWaveformSamples, 3_200)
        XCTAssertEqual(SenseVoiceEncoderGraph.maximumWaveformSamples, 480_000)
        // The fp32 export is a fixed-shape graph: always the full 1,800.
        XCTAssertEqual(SenseVoiceEncoderGraph.int8NeuralEngine.paddedFrames(for: 200), 256)
        XCTAssertEqual(SenseVoiceEncoderGraph.fp16NeuralEngine.paddedFrames(for: 200), 256)
        XCTAssertEqual(SenseVoiceEncoderGraph.fp32.paddedFrames(for: 200), 1_800)
        XCTAssertEqual(SenseVoiceEncoderGraph.fp32.paddedFrames(for: 1), 1_800)
    }

    // MARK: Language hints and embeddings

    func testLanguageHintsAreTheFiveCodesAndMapToEmbeddingIndices() {
        let variant = ParakeetModelVariant.senseVoiceSmall
        let whisper = Set(TranscriptionLanguage.whisperLanguages.map(\.code))
        for code in TranscriptionLanguage.senseVoiceSmallLanguageCodes {
            XCTAssertTrue(whisper.contains(code), "\(code) is not a Whisper code")
            XCTAssertEqual(variant.runtimeLanguageHint(for: code), code)
            XCTAssertEqual(variant.reportedLanguage(forHint: code), code, "fallback when no tag was emitted")
            XCTAssertNotNil(ParakeetModelVariant.senseVoiceLanguageEmbedding(forLanguageCode: code), code)
        }
        // FunASR's lid_dict, restated on the card as lid_int_dict.
        XCTAssertEqual(ParakeetModelVariant.senseVoiceLanguageEmbedding(forLanguageCode: "zh"), 3)
        XCTAssertEqual(ParakeetModelVariant.senseVoiceLanguageEmbedding(forLanguageCode: "en"), 4)
        XCTAssertEqual(ParakeetModelVariant.senseVoiceLanguageEmbedding(forLanguageCode: "yue"), 7)
        XCTAssertEqual(ParakeetModelVariant.senseVoiceLanguageEmbedding(forLanguageCode: "ja"), 11)
        XCTAssertEqual(ParakeetModelVariant.senseVoiceLanguageEmbedding(forLanguageCode: "ko"), 12)
        XCTAssertNil(ParakeetModelVariant.senseVoiceLanguageEmbedding(forLanguageCode: "de"), "outside the five → auto (0)")
        XCTAssertNil(ParakeetModelVariant.senseVoiceLanguageEmbedding(forLanguageCode: nil))
        XCTAssertEqual(SenseVoiceEncoderGraph.autoDetectLanguage, 0)
        XCTAssertNil(variant.runtimeLanguageHint(for: "de"), "a hint outside coverage is dropped; the model detects")
        XCTAssertNil(variant.runtimeLanguageHint(for: nil))
        XCTAssertNil(variant.reportedLanguage(forHint: "de"))
        XCTAssertNil(variant.reportedLanguage(forHint: nil))
    }

    // MARK: Tag stripping

    func testTagsAreStrippedAndOnlyTheLanguageIsReported() {
        let chinese = SenseVoiceTranscriptParser.parse("<|zh|><|NEUTRAL|><|Speech|><|withitn|>今天天气很好，我们去公园散步吧。")
        XCTAssertEqual(chinese, .init(text: "今天天气很好，我们去公园散步吧。", language: "zh"))

        // SentencePiece's ▁ became a space before the tags reach the parser.
        let english = SenseVoiceTranscriptParser.parse("<|en|><|HAPPY|><|Speech|><|withitn|> Good morning. We have 12 new customers.")
        XCTAssertEqual(english.text, "Good morning. We have 12 new customers.")
        XCTAssertEqual(english.language, "en")

        let cantonese = SenseVoiceTranscriptParser.parse("<|yue|><|NEUTRAL|><|Speech|><|withitn|>今日天气好好。")
        XCTAssertEqual(cantonese.language, "yue")
        XCTAssertEqual(SenseVoiceTranscriptParser.parse("<|ja|><|NEUTRAL|><|Speech|><|woitn|>今日はいい天気ですね").language, "ja")
        XCTAssertEqual(SenseVoiceTranscriptParser.parse("<|ko|><|SAD|><|Speech|><|withitn|>오늘 날씨가 좋네요.").language, "ko")

        // Event tags mid-utterance go too, without leaving a double space.
        let laughter = SenseVoiceTranscriptParser.parse("<|en|><|NEUTRAL|><|Speech|><|withitn|> That was <|Laughter|> funny <|/Laughter|> indeed.")
        XCTAssertEqual(laughter.text, "That was funny indeed.")
        XCTAssertFalse(laughter.text.contains("<|"))

        // A language the model can name but kvoice does not offer is still
        // reported honestly; a non-language tag is not.
        XCTAssertEqual(SenseVoiceTranscriptParser.parse("<|de|><|NEUTRAL|><|Speech|><|withitn|>Guten Morgen.").language, "de")
        XCTAssertEqual(SenseVoiceTranscriptParser.parse("<|zh/en|><|NEUTRAL|><|Speech|><|withitn|>你好 hello").language, "zh")
        XCTAssertNil(SenseVoiceTranscriptParser.parse("<|nospeech|><|NEUTRAL|><|BGM|><|withitn|>").language)
        XCTAssertEqual(SenseVoiceTranscriptParser.parse("<|nospeech|><|NEUTRAL|><|BGM|><|withitn|>").text, "")
        XCTAssertNil(SenseVoiceTranscriptParser.parse("<|minnan|><|NEUTRAL|><|Speech|><|withitn|>x").language, "a dialect tag is not a Whisper code")
        XCTAssertNil(SenseVoiceTranscriptParser.parse("<|NEUTRAL|><|Speech|><|withitn|>no language tag").language)
        XCTAssertEqual(SenseVoiceTranscriptParser.parse("plain text without tags").text, "plain text without tags")
        XCTAssertNil(SenseVoiceTranscriptParser.parse("").language)
        XCTAssertEqual(SenseVoiceTranscriptParser.parse("").text, "")

        // Emotion and event names never survive, whatever the case.
        for tag in ["HAPPY", "SAD", "ANGRY", "NEUTRAL", "Speech", "BGM", "Applause", "Cry", "Event_UNK", "withitn", "woitn"] {
            let parsed = SenseVoiceTranscriptParser.parse("<|en|><|\(tag)|>hello")
            XCTAssertEqual(parsed.text, "hello", tag)
            XCTAssertEqual(parsed.language, "en", tag)
        }
        XCTAssertEqual(SenseVoiceTranscriptParser.languageCode(forTag: "en"), "en")
        XCTAssertEqual(SenseVoiceTranscriptParser.languageCode(forTag: "en/zh"), "en")
        XCTAssertNil(SenseVoiceTranscriptParser.languageCode(forTag: "Speech"))
        XCTAssertNil(SenseVoiceTranscriptParser.languageCode(forTag: "nospeech"))
    }

    // MARK: Long recordings

    func testChunkerKeepsWindowsUnderThePreprocessorCeilingAndCutsAtTheQuietestFrame() {
        let rate = 16_000
        XCTAssertEqual(SenseVoiceAudioChunker.defaultMaxSeconds, 15, "measured: 30 s windows drop words, 15 s do not")
        XCTAssertLessThanOrEqual(
            Int(SenseVoiceAudioChunker.defaultMaxSeconds * Double(rate)), SenseVoiceEncoderGraph.maximumWaveformSamples,
            "inside the preprocessor's 480,000-sample ceiling"
        )
        // 40 s of "speech": a tone everywhere except three 0.5 s silences
        // at 12 s, 26 s and 36 s.
        var samples = [Float](repeating: 0.3, count: 40 * rate)
        for silence in [12.0, 26.0, 36.0] {
            let start = Int(silence * Double(rate))
            for index in start..<(start + rate / 2) { samples[index] = 0 }
        }
        let windows = SenseVoiceAudioChunker.windows(for: samples)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.first?.lowerBound, 0)
        XCTAssertEqual(windows.last?.upperBound, samples.count)
        for (index, window) in windows.enumerated() {
            XCTAssertLessThanOrEqual(window.count, 15 * rate, "window \(index)")
            if index > 0 { XCTAssertEqual(window.lowerBound, windows[index - 1].upperBound, "contiguous") }
        }
        // The first cut lands inside the silence at 12 s (the quietest
        // frame of the 10–15 s search range), the second inside 26 s.
        XCTAssertTrue((12 * rate..<(12 * rate + rate / 2)).contains(windows[0].upperBound), "\(windows[0].upperBound)")
        XCTAssertTrue((26 * rate..<(26 * rate + rate / 2)).contains(windows[1].upperBound), "\(windows[1].upperBound)")

        // Short audio is one window; empty audio is one empty window.
        XCTAssertEqual(SenseVoiceAudioChunker.windows(for: [Float](repeating: 0.1, count: 10 * rate)), [0..<(10 * rate)])
        XCTAssertEqual(SenseVoiceAudioChunker.windows(for: []), [0..<0])
        // Exactly the maximum is not cut; one sample more is.
        XCTAssertEqual(SenseVoiceAudioChunker.windows(for: [Float](repeating: 0.1, count: 15 * rate)).count, 1)
        XCTAssertEqual(SenseVoiceAudioChunker.windows(for: [Float](repeating: 0.1, count: 15 * rate + 1)).count, 2)
        // No silence at all: still cut, still inside the search range.
        let loud = SenseVoiceAudioChunker.windows(for: [Float](repeating: 0.5, count: 22 * rate))
        XCTAssertEqual(loud.count, 2)
        XCTAssertTrue((10 * rate...15 * rate).contains(loud[0].upperBound))
        // A 140 s dictation is at least ten windows, none over the limit,
        // and the caller may still ask for the preprocessor's full 30 s.
        let long = SenseVoiceAudioChunker.windows(for: [Float](repeating: 0.2, count: 140 * rate))
        XCTAssertGreaterThanOrEqual(long.count, 10)
        XCTAssertTrue(long.allSatisfy { $0.count <= 15 * rate })
        XCTAssertEqual(long.map(\.count).reduce(0, +), 140 * rate)
        let thirty = SenseVoiceAudioChunker.windows(for: [Float](repeating: 0.2, count: 140 * rate), maxSeconds: 30, searchSeconds: 8)
        XCTAssertTrue(thirty.allSatisfy { $0.count <= SenseVoiceEncoderGraph.maximumWaveformSamples })
    }

    // MARK: Host CTC decode

    func testCTCCollapseDropsBlanksAndMergesConsecutiveRepeatsOnly() {
        let collapsed = SenseVoiceCTCDecoder.collapse([0, 5, 5, 0, 5, 7, 7, 0])
        XCTAssertEqual(collapsed.map(\.frame), [1, 4, 5])
        XCTAssertEqual(collapsed.map(\.id), [5, 5, 7], "a token after a blank is a new token — CTC's rule, the doubled-tail source")
        XCTAssertTrue(SenseVoiceCTCDecoder.collapse([]).isEmpty)
        XCTAssertTrue(SenseVoiceCTCDecoder.collapse([0, 0, 0]).isEmpty)
        XCTAssertEqual(SenseVoiceCTCDecoder.collapse([9, 9, 9]).map(\.id), [9])
        XCTAssertEqual(SenseVoiceCTCDecoder.collapse([3, 0, 3]).map(\.frame), [0, 2])
    }

    func testTagTokensSurviveTheDecodeAndAreStrippedByTheParser() {
        let vocabulary: [Int: String] = [
            0: "<unk>", 1: "<|zh|>", 2: "<|NEUTRAL|>", 3: "<|Speech|>", 4: "<|withitn|>",
            5: "今", 6: "天", 7: "▁hello", 8: "。"
        ]
        // The four query positions, then the transcript with CTC blanks
        // and a repeat.
        let ids = SenseVoiceCTCDecoder.collapse([1, 2, 3, 4, 0, 5, 5, 0, 6, 8, 0]).map(\.id)
        XCTAssertEqual(ids, [1, 2, 3, 4, 5, 6, 8])
        let raw = SenseVoiceCTCDecoder.detokenize(ids, vocabulary: vocabulary)
        XCTAssertEqual(raw, "<|zh|><|NEUTRAL|><|Speech|><|withitn|>今天。")
        XCTAssertEqual(SenseVoiceTranscriptParser.parse(raw), .init(text: "今天。", language: "zh"))
        // SentencePiece word boundaries become spaces and are trimmed.
        let english = SenseVoiceCTCDecoder.detokenize([1, 4, 7, 7], vocabulary: vocabulary)
        XCTAssertEqual(english, "<|zh|><|withitn|> hello hello")
        XCTAssertEqual(SenseVoiceTranscriptParser.parse(english).text, "hello hello")
        XCTAssertEqual(SenseVoiceCTCDecoder.detokenize([42], vocabulary: vocabulary), "", "an unknown id decodes to nothing")
    }

    func testWindowPreparationSkipsTheUndecodableAndPadsToThePreprocessorFloor() throws {
        XCTAssertNil(SenseVoiceAudioChunker.prepared([]))
        XCTAssertNil(SenseVoiceAudioChunker.prepared([Float](repeating: 0.1, count: 959)), "under one LFR frame")
        let oneFrame = try XCTUnwrap(SenseVoiceAudioChunker.prepared([Float](repeating: 0.1, count: 960)))
        XCTAssertEqual(oneFrame.count, 3_200, "padded to the preprocessor's floor")
        XCTAssertEqual(oneFrame[959], 0.1)
        XCTAssertEqual(oneFrame[960], 0, "zeros after the audio")
        XCTAssertEqual(SenseVoiceAudioChunker.prepared([Float](repeating: 0.1, count: 3_199))?.count, 3_200)
        let exact = [Float](repeating: 0.2, count: 3_200)
        XCTAssertEqual(SenseVoiceAudioChunker.prepared(exact), exact, "at the floor: untouched")
        let long = [Float](repeating: 0.2, count: 50_000)
        XCTAssertEqual(SenseVoiceAudioChunker.prepared(long), long)
    }

    func testJoinerSpacesWordsButNotCJKCharacters() {
        XCTAssertEqual(SenseVoiceTranscriptJoiner.join(["Good morning.", "How are you?"]), "Good morning. How are you?")
        XCTAssertEqual(SenseVoiceTranscriptJoiner.join(["今天天气很好，", "我们去公园。"]), "今天天气很好，我们去公园。")
        XCTAssertEqual(SenseVoiceTranscriptJoiner.join(["今日はいい天気", "ですね。"]), "今日はいい天気ですね。")
        XCTAssertEqual(SenseVoiceTranscriptJoiner.join(["오늘 날씨가", "좋네요."]), "오늘 날씨가 좋네요.", "Korean is space-delimited: a cut between words rejoins with a space")
        XCTAssertEqual(SenseVoiceTranscriptJoiner.join(["Hello", "你好"]), "Hello 你好", "a script change gets a space")
        XCTAssertEqual(SenseVoiceTranscriptJoiner.join(["", "  ", "one", "", "two "]), "one two")
        XCTAssertEqual(SenseVoiceTranscriptJoiner.join([]), "")
    }

    // MARK: Engine

    func testTranscribePassesTheCodeAndPrefersTheRuntimeReportedLanguage() async throws {
        let fixture = try fixture()
        let runtime = FakeParakeetRuntime()
        runtime.transcript = ParakeetTranscript(
            text: "今天天气很好，我们去公园散步吧。",
            tokens: [ParakeetTokenSpan(text: "今", start: 0.24, end: 0.30), ParakeetTokenSpan(text: "吧", start: 3.0, end: 3.06)],
            runtimeReportedRealTimeFactor: nil,
            detectedLanguage: "zh"
        )
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await engine.load(fixture.package)
        XCTAssertEqual(runtime.batchConfigurations, [
            ParakeetRuntimeConfiguration(
                variant: .senseVoiceSmall, modelFolderURL: fixture.package.modelFolderURL, computeUnits: .neuralEngineAndCPU
            )
        ])

        // The hint is the bare code; the language comes from the tag.
        let result = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: makeRecording(), languageHint: "en")) { _ in }
        XCTAssertEqual(runtime.lastLanguageHint, .some("en"))
        XCTAssertEqual(result.text, "今天天气很好，我们去公园散步吧。")
        XCTAssertEqual(result.detectedLanguage, "zh", "the tag the model emitted wins over the hint (a prior, not a constraint)")
        XCTAssertEqual(result.segments, [TranscriptSegment(start: .seconds(0.24), end: .seconds(3.06), text: "今天天气很好，我们去公园散步吧。")])
        XCTAssertEqual(result.modelID, KvoiceFluidAudioModels.senseVoiceSmallModelID)

        // No tag: the accepted hint is reported; an uncovered hint is auto.
        runtime.transcript = ParakeetTranscript(text: "hello", detectedLanguage: nil)
        let english = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: makeRecording(), languageHint: "en")) { _ in }
        XCTAssertEqual(english.detectedLanguage, "en")
        let auto = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: makeRecording(), languageHint: "de")) { _ in }
        XCTAssertEqual(runtime.lastLanguageHint, .some(nil))
        XCTAssertNil(auto.detectedLanguage)

        // No prompt (ADR-018 rule 3).
        let limit = await engine.promptTokenLimit
        XCTAssertEqual(limit, .unsupported)
    }

    func testStreamingIsRefusedAsBatchOnly() async throws {
        let fixture = try fixture()
        let runtime = FakeParakeetRuntime(decoderStreams: false)
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await engine.load(fixture.package)
        do {
            try await engine.beginStreaming(jobID: UUID(), languageHint: "zh", initialPrompt: nil) { _ in }
            XCTFail("expected streamingUnsupported")
        } catch let error as ParakeetTranscriptionError {
            XCTAssertEqual(error, .streamingUnsupported(.senseVoiceSmall))
        }
        XCTAssertTrue(runtime.streamingConfigurations.isEmpty)
        XCTAssertEqual(runtime.sharedSessionHints, [])
    }

    func testEveryComputeUnitChoiceReloadsRatherThanRefuses() async throws {
        let fixture = try fixture()
        let runtime = FakeParakeetRuntime()
        let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [fixture.anchor])
        try await engine.load(fixture.package)
        for units in [SpeechComputeUnits.gpuAndCPU, .all, .cpuOnly, .neuralEngineAndCPU] {
            try await engine.setComputeUnits(units)
            XCTAssertEqual(runtime.batchConfigurations.last?.computeUnits, units)
            // The runtime is handed the choice; which export it loads is
            // the variant's rule, checked above.
            XCTAssertEqual(
                ParakeetModelVariant.senseVoiceEncoderGraph(for: units),
                units == .neuralEngineAndCPU ? .int8NeuralEngine : .fp32
            )
        }
        XCTAssertEqual(runtime.batchConfigurations.count, 5, "one load plus four reloads")
    }

    func testLoadRefusesAPackageMissingEitherEncoderOrThePreprocessor() async throws {
        for missing in [
            "model/SenseVoiceSmall_fp32.mlmodelc", "model/SenseVoiceSmall_int8.mlmodelc", "model/SenseVoicePreprocessor.mlmodelc"
        ] {
            let fixture = try fixture()
            let runtime = FakeParakeetRuntime()
            let manifest = fixture.package.manifest
            let trimmed = ModelManifest(
                schemaVersion: 1, modelID: manifest.modelID, family: manifest.family, format: manifest.format,
                workingSpaceBytes: manifest.workingSpaceBytes, source: manifest.source,
                runtimeCompatibility: manifest.runtimeCompatibility, tokenizer: manifest.tokenizer,
                files: manifest.files.filter { !$0.path.hasPrefix(missing) }
            )
            let canonical = try WhisperModelReleaseTrustAnchor.canonicalData(for: trimmed)
            try canonical.write(to: fixture.root.appendingPathComponent("ModelManifest.json"))
            let anchor = try WhisperModelReleaseTrustAnchor(
                manifestData: canonical, manifestSHA256: WhisperModelReleaseTrustAnchor.digest(for: trimmed)
            )
            let trimmedEngine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [anchor])
            let package = InstalledModelPackage(
                manifest: trimmed, packageURL: fixture.root,
                modelFolderURL: fixture.package.modelFolderURL, tokenizerFolderURL: fixture.package.tokenizerFolderURL,
                ownership: .managedByKvoice
            )
            do {
                try await trimmedEngine.load(package)
                XCTFail("expected a validation failure for \(missing)")
            } catch let error as ParakeetTranscriptionError {
                if case .invalidModelPackage = error {} else { XCTFail("\(error)") }
            }
            XCTAssertTrue(runtime.batchConfigurations.isEmpty, "refused before the runtime is asked (\(missing))")
        }
    }
}
