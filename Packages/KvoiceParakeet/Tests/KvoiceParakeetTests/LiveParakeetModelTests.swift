import AVFoundation
import Foundation
import KvoiceDomain
import KvoiceModelManagement
import KvoiceTranscription
import XCTest
@testable import KvoiceParakeet

/// Opt-in measurement against the real Parakeet packages:
///
///     KVOICE_LIVE_MODEL_TESTS=1 ./Scripts/test.sh --filter LiveParakeetModelTests
///
/// Expects the pinned files laid out as `~/Models/<catalog id>/model/…` (the
/// folders `Docs/Model-Packages.md` describes for regenerating the
/// manifests); writes the bundled catalog's canonical `ModelManifest.json`
/// beside `model/` so the package verifies exactly as an installed one, then
/// loads each model through the real FluidAudio runtime, plans placement,
/// and transcribes the bundled performance sample twice. Prints scalars
/// only. `KVOICE_LIVE_MODEL_ID` narrows it to one catalog entry and
/// `KVOICE_LIVE_RUNTIME_UNITS` to one compute-unit choice.
final class LiveParakeetModelTests: XCTestCase {
    static let fluidAudioRuntimes: Set<SpeechModelRuntime> = [
        .fluidAudioParakeetTDT, .fluidAudioParakeetUnified, .fluidAudioNemotronStreaming, .fluidAudioSenseVoice,
        .fluidAudioParaformer, .fluidAudioParakeetEOU
    ]

    func testLoadAndTranscribeTheBundledSampleWithTheRealRuntime() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KVOICE_LIVE_MODEL_TESTS"] == "1",
            "opt-in: needs the Parakeet packages under ~/Models and a minute of wall time"
        )
        let environment = ProcessInfo.processInfo.environment
        let loaded = try BundledSpeechModelCatalogLoader().load()
        let wanted = environment["KVOICE_LIVE_MODEL_ID"]
        let entries = loaded.catalog.entries.filter {
            Self.fluidAudioRuntimes.contains($0.runtime) && (wanted == nil || $0.id == wanted)
        }
        XCTAssertFalse(entries.isEmpty)
        let units = environment["KVOICE_LIVE_RUNTIME_UNITS"]
            .flatMap(SpeechComputeUnits.init(rawValue:))
            .map { [$0] } ?? [SpeechComputeUnits.default]
        let sample = try PerformanceSampleAudio.load()
        let reporter = CoreMLModelPlacementReporter()
        // The Runtime card's memory figure (`phys_footprint`), read before
        // and after the load so the table can quote what the graphs cost.
        let telemetry = SystemRuntimeTelemetryProvider()

        for entry in entries {
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Models/\(entry.id)", isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("model").path) else {
                print("[live-parakeet] \(entry.id): no package at \(root.path), skipped")
                continue
            }
            let anchor = try XCTUnwrap(loaded.anchor(for: entry.id))
            try WhisperModelReleaseTrustAnchor.canonicalData(for: anchor.manifest)
                .write(to: root.appendingPathComponent("ModelManifest.json"), options: .atomic)
            let package = try ModelPackageVerifier(trustedRelease: anchor).makePackage(at: root, ownership: .externalReadOnly)
            try ModelPackageVerifier(trustedRelease: anchor).verify(package)

            let engine = ParakeetTranscriptionEngine(runtime: FluidAudioParakeetRuntime(), trustedReleases: [anchor])
            for choice in units {
                try await engine.setComputeUnits(choice)
                let footprintBefore = telemetry.memoryFootprintBytes() ?? 0
                try await engine.load(package)
                let load = await engine.runtimeStatistics.lastLoadDuration
                let footprintAfter = telemetry.memoryFootprintBytes() ?? 0
                let placement = await reporter.placement(for: package, computeUnits: choice)
                var factors: [Double] = []
                var text = ""
                for _ in 0..<2 {
                    let request = TranscriptionRequest(jobID: UUID(), audio: sample, languageHint: "en")
                    let result = try await engine.transcribe(request, events: { _ in })
                    factors.append(await engine.runtimeStatistics.lastRealTimeFactor ?? .nan)
                    text = result.text
                }
                XCTAssertFalse(text.isEmpty, "\(entry.id) produced no text for the sample")
                // The sample is synthetic speech bundled in the repository
                // (provenance in PerformanceSampleAudio.swift), not a user
                // recording, so its transcript may be printed here.
                print("[live-parakeet] \(entry.id) text: \(text)")
                print(
                    "[live-parakeet] \(entry.id) \(choice.rawValue): load \(load.map { "\($0)" } ?? "n/a"), "
                    + "rtf first \(String(format: "%.3f", factors[0])) second \(String(format: "%.3f", factors[1])), "
                    + "encoder \(placement.encoder?.summary ?? "unavailable"), decoder \(placement.decoder?.summary ?? "unavailable"), "
                    + "footprint +\((Int64(footprintAfter) - Int64(footprintBefore)) / 1_048_576) MB (\(footprintAfter / 1_048_576) MB total), "
                    + "words \(text.split(separator: " ").count), punctuation \(text.contains(where: { ".,?!".contains($0) }))"
                )
                if entry.supportsStreaming {
                    let collector = LivePartialCollector()
                    let jobID = UUID()
                    let start = ContinuousClock.now
                    try await engine.beginStreaming(jobID: jobID, languageHint: "en", initialPrompt: nil) { event in
                        switch event {
                        case let .partialText(partial): await collector.add(partial)
                        case let .endOfUtteranceDetected(detected): await collector.endOfUtterance(detected)
                        default: break
                        }
                    }
                    let chunkSize = 16_000 / 10
                    var offset = 0
                    while offset < sample.samples.count {
                        let end = min(offset + chunkSize, sample.samples.count)
                        await engine.appendStreamingAudio(
                            AudioSampleChunk(samples: ContiguousArray(sample.samples[offset..<end])),
                            jobID: jobID
                        )
                        offset = end
                    }
                    await engine.awaitStreamingPasses()
                    await engine.endStreaming(jobID: jobID)
                    let partials = await collector.partials
                    let endOfUtterance = await collector.endOfUtteranceEvents
                    let streamingWall = ContinuousClock.now - start
                    print(
                        "[live-parakeet] \(entry.id) streaming: \(partials.count) partials in "
                        + "\(streamingWall), final partial words \(partials.last?.split(separator: " ").count ?? 0), "
                        + "end-of-utterance events \(endOfUtterance)"
                    )
                    XCTAssertFalse(partials.isEmpty, "streaming produced no partial text")
                }
                await engine.unload()
            }
        }
    }
}

/// ADR-019 amendment (2026-09-16): every Whisper code kvoice offers for
/// Nemotron resolves to a `prompt_dictionary` key of the real
/// `metadata.json`, and to a distinct prompt from "auto" — so a hint is
/// never silently the default prompt. Reads the file only; no Core ML.
///
///     KVOICE_LIVE_MODEL_TESTS=1 ./Scripts/test.sh --filter LiveNemotronPromptDictionaryTests
final class LiveNemotronPromptDictionaryTests: XCTestCase {
    func testEveryCoveredCodeResolvesToItsOwnPromptID() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KVOICE_LIVE_MODEL_TESTS"] == "1",
            "opt-in: needs the Nemotron package under ~/Models"
        )
        let metadata = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Models/\(KvoiceFluidAudioModels.nemotronMultilingualModelID)/model/metadata.json")
        guard FileManager.default.fileExists(atPath: metadata.path) else {
            throw XCTSkip("no package at \(metadata.path)")
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        let dictionary = try XCTUnwrap(object["prompt_dictionary"] as? [String: Int])
        let auto = try XCTUnwrap(object["default_prompt_id"] as? Int)
        XCTAssertEqual(dictionary["auto"], auto)
        for code in TranscriptionLanguage.nemotronMultilingualLanguageCodes {
            let key = try XCTUnwrap(ParakeetModelVariant.nemotronPromptKey(forLanguageCode: code), code)
            let id = try XCTUnwrap(dictionary[key], "\(code) → \(key) is not a prompt_dictionary key")
            XCTAssertNotEqual(id, auto, "\(code) would be the auto prompt")
        }
        // Every dictionary key with a Whisper code is offered (no coverage
        // silently dropped when the file changes).
        let whisper = Set(TranscriptionLanguage.whisperLanguages.map(\.code))
        let offered = Set(TranscriptionLanguage.nemotronMultilingualLanguageCodes)
        for key in dictionary.keys where key != "auto" {
            let bare = String(key.split(separator: "-").first!).lowercased()
            if whisper.contains(bare) {
                XCTAssertTrue(offered.contains(bare), "\(key) has a Whisper code but is not offered")
            }
        }
    }
}

/// Opt-in check of a FluidAudio model on audio of the caller's choosing —
/// the way to exercise a language the bundled English sample cannot (the
/// Nemotron zh/ja path was checked on 2026-09-16 with `say -v Tingting` /
/// `say -v Kyoko` output). Prints the text and the reported language only
/// when the file is the caller's own synthetic speech; a recording of a
/// person is never printed here, so pass `KVOICE_LIVE_PRINT_TEXT=1` only
/// for synthetic audio.
///
///     KVOICE_LIVE_MODEL_TESTS=1 KVOICE_LIVE_MODEL_ID=nemotron-3.5-asr-streaming-multilingual-0.6b-coreml \
///     KVOICE_LIVE_AUDIO_FILE=/path/to/16k-mono.wav KVOICE_LIVE_LANGUAGE=zh KVOICE_LIVE_PRINT_TEXT=1 \
///     ./Scripts/test.sh --filter LiveParakeetAudioFileTests
final class LiveParakeetAudioFileTests: XCTestCase {
    func testTranscribeTheGivenFileWithTheGivenHint() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["KVOICE_LIVE_MODEL_TESTS"] == "1", "opt-in")
        guard let path = environment["KVOICE_LIVE_AUDIO_FILE"], let modelID = environment["KVOICE_LIVE_MODEL_ID"] else {
            throw XCTSkip("set KVOICE_LIVE_AUDIO_FILE and KVOICE_LIVE_MODEL_ID")
        }
        let loaded = try BundledSpeechModelCatalogLoader().load()
        let entry = try XCTUnwrap(loaded.catalog.entry(id: modelID))
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Models/\(entry.id)", isDirectory: true)
        let anchor = try XCTUnwrap(loaded.anchor(for: entry.id))
        try WhisperModelReleaseTrustAnchor.canonicalData(for: anchor.manifest)
            .write(to: root.appendingPathComponent("ModelManifest.json"), options: .atomic)
        let package = try ModelPackageVerifier(trustedRelease: anchor).makePackage(at: root, ownership: .externalReadOnly)
        try ModelPackageVerifier(trustedRelease: anchor).verify(package)

        let samples = try LiveAudioFile.samples(atPath: path)
        let recording = AudioRecording(
            samples: samples,
            duration: .seconds(Double(samples.count) / 16_000),
            peakLevelDBFS: -12,
            clippedFrameCount: 0
        )

        let engine = ParakeetTranscriptionEngine(runtime: FluidAudioParakeetRuntime(), trustedReleases: [anchor])
        try await engine.load(package)
        let hint = environment["KVOICE_LIVE_LANGUAGE"]
        let result = try await engine.transcribe(TranscriptionRequest(jobID: UUID(), audio: recording, languageHint: hint)) { _ in }
        let rtf = await engine.runtimeStatistics.lastRealTimeFactor
        XCTAssertFalse(result.text.isEmpty)
        print(
            "[live-audio] \(entry.id) hint \(hint ?? "auto"): reported language \(result.detectedLanguage ?? "none"), "
            + "\(result.text.count) characters, rtf \(rtf.map { String(format: "%.3f", $0) } ?? "n/a")"
        )
        if environment["KVOICE_LIVE_PRINT_TEXT"] == "1" {
            print("[live-audio] text: \(result.text)")
        }
        await engine.unload()
    }
}

/// ADR-022 item 8: the first pass after a load versus the steady state,
/// with and without the engine's warm-up, for each Parakeet package under
/// `~/Models`. Same env vars as the test above; Neural Engine + CPU only.
///
///     KVOICE_LIVE_MODEL_TESTS=1 ./Scripts/test.sh --filter LiveParakeetWarmUpTests
final class LiveParakeetWarmUpTests: XCTestCase {
    func testWarmUpRemovesTheFirstPassPenalty() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KVOICE_LIVE_MODEL_TESTS"] == "1",
            "opt-in: needs the Parakeet packages under ~/Models and a minute of wall time"
        )
        let environment = ProcessInfo.processInfo.environment
        let loaded = try BundledSpeechModelCatalogLoader().load()
        let wanted = environment["KVOICE_LIVE_MODEL_ID"]
        let entries = loaded.catalog.entries.filter {
            LiveParakeetModelTests.fluidAudioRuntimes.contains($0.runtime) && (wanted == nil || $0.id == wanted)
        }
        let sample = try PerformanceSampleAudio.load()
        let clock = ContinuousClock()
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let audioSeconds = seconds(sample.duration)

        for entry in entries {
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Models/\(entry.id)", isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("model").path) else {
                print("[live-warmup] \(entry.id): no package at \(root.path), skipped")
                continue
            }
            let anchor = try XCTUnwrap(loaded.anchor(for: entry.id))
            try WhisperModelReleaseTrustAnchor.canonicalData(for: anchor.manifest)
                .write(to: root.appendingPathComponent("ModelManifest.json"), options: .atomic)
            let package = try ModelPackageVerifier(trustedRelease: anchor).makePackage(at: root, ownership: .externalReadOnly)
            let variant = try ParakeetModelPackageValidator(trustedReleases: [anchor]).validate(package)

            // Without a warm-up: the raw decoder, first pass cold.
            let runtime = FluidAudioParakeetRuntime()
            let raw = try await runtime.makeBatchDecoder(configuration: ParakeetRuntimeConfiguration(
                variant: variant, modelFolderURL: package.modelFolderURL, computeUnits: .default
            ))
            var cold: [Double] = []
            for _ in 0..<2 {
                let start = clock.now
                _ = try await raw.transcribe(samples: Array(sample.samples), languageHint: variant.runtimeLanguageHint(for: "en"))
                cold.append(seconds(clock.now - start) / audioSeconds)
            }
            await raw.unload()

            // With the engine's warm-up: first real pass after `load`.
            let engine = ParakeetTranscriptionEngine(runtime: runtime, trustedReleases: [anchor])
            try await engine.load(package)
            // The second load in this process: Core ML's compile is cached,
            // so this is the "warm" load figure the Changelog tables quote.
            let warmLoad = await engine.runtimeStatistics.lastLoadDuration
            let warmUp = await engine.runtimeStatistics.lastWarmUpDuration
            var warmed: [Double] = []
            for _ in 0..<2 {
                let request = TranscriptionRequest(jobID: UUID(), audio: sample, languageHint: "en")
                _ = try await engine.transcribe(request, events: { _ in })
                warmed.append(await engine.runtimeStatistics.lastRealTimeFactor ?? .nan)
            }
            await engine.unload()
            print(
                "[live-warmup] \(entry.id): warm load \(warmLoad.map { "\($0)" } ?? "n/a"); without warm-up rtf first "
                + "\(String(format: "%.3f", cold[0])) second \(String(format: "%.3f", cold[1])); "
                + "warm-up \(warmUp.map { "\($0)" } ?? "n/a"), with warm-up rtf first "
                + "\(String(format: "%.3f", warmed[0])) second \(String(format: "%.3f", warmed[1]))"
            )
        }
    }
}

/// ADR-019 amendment (2026-09-16, SenseVoice): one (encoder export,
/// compute-unit choice) pair per process, straight on the pipeline — how
/// the "int8 on the Neural Engine, fp32 elsewhere" rule was measured and
/// how it is re-measured. Loads from a folder of the caller's choosing (a
/// scratch download holding all three exports; the verified package holds
/// two), so the fp16 export and the misplaced pairs can be checked without
/// a package. A NaN tensor is reported as a thrown error, not as text.
/// Prints scalars and, since the sample is synthetic, the text.
///
///     KVOICE_LIVE_MODEL_TESTS=1 KVOICE_LIVE_SENSEVOICE_FOLDER=/path/to/model \
///     KVOICE_LIVE_SENSEVOICE_GRAPH=int8NeuralEngine KVOICE_LIVE_RUNTIME_UNITS=cpuOnly \
///     ./Scripts/test.sh --filter LiveSenseVoiceEncoderMatrixTests
final class LiveSenseVoiceEncoderMatrixTests: XCTestCase {
    func testOneGraphUnderOneComputeUnitChoice() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["KVOICE_LIVE_MODEL_TESTS"] == "1", "opt-in")
        guard let folder = environment["KVOICE_LIVE_SENSEVOICE_FOLDER"],
              let graph = environment["KVOICE_LIVE_SENSEVOICE_GRAPH"].flatMap(SenseVoiceEncoderGraph.init(rawValue:)),
              let units = environment["KVOICE_LIVE_RUNTIME_UNITS"].flatMap(SpeechComputeUnits.init(rawValue:)) else {
            throw XCTSkip("set KVOICE_LIVE_SENSEVOICE_FOLDER, KVOICE_LIVE_SENSEVOICE_GRAPH and KVOICE_LIVE_RUNTIME_UNITS")
        }
        let sample = try PerformanceSampleAudio.load()
        let telemetry = SystemRuntimeTelemetryProvider()
        let clock = ContinuousClock()
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let audioSeconds = seconds(sample.duration)
        let footprintBefore = telemetry.memoryFootprintBytes() ?? 0
        let loadStart = clock.now
        let pipeline = try await SenseVoicePipeline(folder: URL(fileURLWithPath: folder, isDirectory: true), graph: graph, units: units)
        let load = seconds(clock.now - loadStart)
        let footprintAfter = telemetry.memoryFootprintBytes() ?? 0
        var factors: [Double] = []
        var text = ""
        var language: String?
        do {
            for _ in 0..<3 {
                let start = clock.now
                let transcript = try await pipeline.transcribe(samples: Array(sample.samples), languageHint: environment["KVOICE_LIVE_LANGUAGE"])
                factors.append(seconds(clock.now - start) / audioSeconds)
                text = transcript.text
                language = transcript.detectedLanguage
            }
        } catch {
            print("[live-sensevoice] \(graph.rawValue) \(units.rawValue): load \(String(format: "%.2f", load)) s, REFUSED: \(error)")
            await pipeline.unload()
            return
        }
        print(
            "[live-sensevoice] \(graph.rawValue) \(units.rawValue): load \(String(format: "%.2f", load)) s, rtf "
            + factors.map { String(format: "%.3f", $0) }.joined(separator: " / ")
            + ", footprint +\((Int64(footprintAfter) - Int64(footprintBefore)) / 1_048_576) MB (\(footprintAfter / 1_048_576) MB total), "
            + "language \(language ?? "none"), words \(text.split(separator: " ").count), "
            + "punctuation \(text.contains(where: { ".,?!".contains($0) }))"
        )
        print("[live-sensevoice] text: \(text)")
        await pipeline.unload()
    }
}

/// ADR-019 amendment (2026-09-16, Paraformer): one (precision, compute-unit
/// choice) pair per process, straight on the pipeline — how the int8-only
/// package decision was measured and how it is re-measured. Loads from a
/// folder of the caller's choosing (a scratch download holding both the
/// int8 and fp16 exports; the verified package holds int8), so the fp16
/// pair stays checkable without a package. A non-finite tensor is reported
/// as a thrown error, not as text. The bundled sample is English, which
/// this Mandarin model cannot transcribe, so pass a 16 kHz mono Mandarin
/// file (`say -v Tingting` output) as `KVOICE_LIVE_AUDIO_FILE`; the text is
/// printed only with `KVOICE_LIVE_PRINT_TEXT=1` (synthetic speech only).
///
///     KVOICE_LIVE_MODEL_TESTS=1 KVOICE_LIVE_PARAFORMER_FOLDER=/path/to/model \
///     KVOICE_LIVE_PARAFORMER_PRECISION=int8 KVOICE_LIVE_RUNTIME_UNITS=cpuOnly \
///     KVOICE_LIVE_AUDIO_FILE=/path/to/zh-16k-mono.wav KVOICE_LIVE_PRINT_TEXT=1 \
///     ./Scripts/test.sh --filter LiveParaformerMatrixTests
final class LiveParaformerMatrixTests: XCTestCase {
    func testOnePrecisionUnderOneComputeUnitChoice() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["KVOICE_LIVE_MODEL_TESTS"] == "1", "opt-in")
        guard let folder = environment["KVOICE_LIVE_PARAFORMER_FOLDER"],
              let precision = environment["KVOICE_LIVE_PARAFORMER_PRECISION"].flatMap(ParaformerGraph.Precision.init(rawValue:)),
              let units = environment["KVOICE_LIVE_RUNTIME_UNITS"].flatMap(SpeechComputeUnits.init(rawValue:)) else {
            throw XCTSkip("set KVOICE_LIVE_PARAFORMER_FOLDER, KVOICE_LIVE_PARAFORMER_PRECISION and KVOICE_LIVE_RUNTIME_UNITS")
        }
        let samples: [Float]
        let audioSeconds: Double
        if let path = environment["KVOICE_LIVE_AUDIO_FILE"] {
            samples = Array(try LiveAudioFile.samples(atPath: path))
            audioSeconds = Double(samples.count) / 16_000
        } else {
            let sample = try PerformanceSampleAudio.load()
            samples = Array(sample.samples)
            audioSeconds = Double(sample.duration.components.seconds) + Double(sample.duration.components.attoseconds) / 1e18
        }
        let telemetry = SystemRuntimeTelemetryProvider()
        let clock = ContinuousClock()
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let footprintBefore = telemetry.memoryFootprintBytes() ?? 0
        let loadStart = clock.now
        let pipeline = try await ParaformerPipeline(folder: URL(fileURLWithPath: folder, isDirectory: true), precision: precision, units: units)
        let load = seconds(clock.now - loadStart)
        let footprintAfter = telemetry.memoryFootprintBytes() ?? 0
        var factors: [Double] = []
        var text = ""
        var spans = 0
        do {
            for _ in 0..<3 {
                let start = clock.now
                let transcript = try await pipeline.transcribe(samples: samples, languageHint: nil)
                factors.append(seconds(clock.now - start) / audioSeconds)
                text = transcript.text
                spans = transcript.tokens.count
            }
        } catch {
            print("[live-paraformer] \(precision.rawValue) \(units.rawValue): load \(String(format: "%.2f", load)) s, REFUSED: \(error)")
            await pipeline.unload()
            return
        }
        print(
            "[live-paraformer] \(precision.rawValue) \(units.rawValue): load \(String(format: "%.2f", load)) s, rtf "
            + factors.map { String(format: "%.3f", $0) }.joined(separator: " / ")
            + ", footprint +\((Int64(footprintAfter) - Int64(footprintBefore)) / 1_048_576) MB (\(footprintAfter / 1_048_576) MB total), "
            + "characters \(text.count), spans \(spans), punctuation \(text.contains(where: { "，。？！,.?!".contains($0) }))"
        )
        if environment["KVOICE_LIVE_PRINT_TEXT"] == "1" {
            print("[live-paraformer] text: \(text)")
        }
        await pipeline.unload()
    }
}

/// ADR-019 amendment (2026-09-16, Parakeet EOU): the streaming session
/// paced like the recorder — one 320 ms shift per append, waiting for the
/// pass after each — so the per-chunk latency (append → partial) is the
/// compute a live partial costs, and with 3 s of silence appended to the
/// bundled sample so the `<EOU>` token and the library's 1.28 s debounce
/// have room to fire. Reports how many partials, when the end-of-utterance
/// scalar was published (the ADR-023 seam — nothing acts on it) and the
/// per-append latency percentiles. Neural Engine + CPU unless
/// `KVOICE_LIVE_RUNTIME_UNITS` says otherwise.
///
///     KVOICE_LIVE_MODEL_TESTS=1 ./Scripts/test.sh --filter LiveParakeetEOUSignalTests
final class LiveParakeetEOUSignalTests: XCTestCase {
    func testPacedStreamingPublishesPartialsAndTheEndOfUtteranceScalar() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["KVOICE_LIVE_MODEL_TESTS"] == "1", "opt-in")
        let loaded = try BundledSpeechModelCatalogLoader().load()
        let entry = try XCTUnwrap(loaded.catalog.entry(id: KvoiceFluidAudioModels.parakeetEOUModelID))
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Models/\(entry.id)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("model").path) else {
            throw XCTSkip("no package at \(root.path)")
        }
        let anchor = try XCTUnwrap(loaded.anchor(for: entry.id))
        try WhisperModelReleaseTrustAnchor.canonicalData(for: anchor.manifest)
            .write(to: root.appendingPathComponent("ModelManifest.json"), options: .atomic)
        let package = try ModelPackageVerifier(trustedRelease: anchor).makePackage(at: root, ownership: .externalReadOnly)
        try ModelPackageVerifier(trustedRelease: anchor).verify(package)
        let units = environment["KVOICE_LIVE_RUNTIME_UNITS"].flatMap(SpeechComputeUnits.init(rawValue:)) ?? .default

        let engine = ParakeetTranscriptionEngine(runtime: FluidAudioParakeetRuntime(), trustedReleases: [anchor])
        try await engine.setComputeUnits(units)
        try await engine.load(package)
        let sample = try PerformanceSampleAudio.load()
        var samples = Array(sample.samples)
        samples.append(contentsOf: [Float](repeating: 0, count: 3 * 16_000))

        let collector = LivePartialCollector()
        let jobID = UUID()
        try await engine.beginStreaming(jobID: jobID, languageHint: "en", initialPrompt: nil) { event in
            switch event {
            case let .partialText(partial): await collector.add(partial)
            case let .endOfUtteranceDetected(detected): await collector.endOfUtterance(detected)
            default: break
            }
        }
        let clock = ContinuousClock()
        var latencies: [Double] = []
        var appendsBeforeEndOfUtterance: Int?
        var offset = 0
        var appends = 0
        while offset < samples.count {
            let end = min(offset + ParakeetEOUGraph.shiftSamples, samples.count)
            let start = clock.now
            await engine.appendStreamingAudio(AudioSampleChunk(samples: ContiguousArray(samples[offset..<end])), jobID: jobID)
            await engine.awaitStreamingPasses()
            let elapsed = clock.now - start
            latencies.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            appends += 1
            if appendsBeforeEndOfUtterance == nil, await collector.endOfUtteranceEvents.contains(true) {
                appendsBeforeEndOfUtterance = appends
            }
            offset = end
        }
        await engine.endStreaming(jobID: jobID)
        let partials = await collector.partials
        let events = await collector.endOfUtteranceEvents
        let sorted = latencies.sorted()
        func percentile(_ p: Double) -> String {
            String(format: "%.0f ms", sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1_000)
        }
        let speechEnd = Double(sample.samples.count) / 16_000
        let eouAt = appendsBeforeEndOfUtterance.map { Double($0 * ParakeetEOUGraph.shiftSamples) / 16_000 }
        print(
            "[live-eou] \(units.rawValue): \(appends) appends of 320 ms, \(partials.count) partials, "
            + "append→partial latency p50 \(percentile(0.5)) p90 \(percentile(0.9)) max \(percentile(1)); "
            + "end-of-utterance events \(events)"
            + (eouAt.map { String(format: ", first true after %.2f s of audio (speech ends at %.2f s)", $0, speechEnd) } ?? ", never true")
            + "; final partial words \(partials.last?.split(separator: " ").count ?? 0)"
        )
        print("[live-eou] final partial: \(partials.last ?? "")")
        XCTAssertFalse(partials.isEmpty)
        await engine.unload()
    }
}

/// A 16 kHz mono WAV as Float32 samples, for the file-driven live tests.
enum LiveAudioFile {
    static func samples(atPath path: String) throws -> ContiguousArray<Float> {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw XCTSkip("the file must be 16 kHz mono; convert with afconvert -f WAVE -d LEI16@16000 -c 1")
        }
        try file.read(into: buffer)
        return ContiguousArray(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength)))
    }
}

private actor LivePartialCollector {
    var partials: [String] = []
    /// The ADR-023 seam's scalar, as published (on change only).
    var endOfUtteranceEvents: [Bool] = []
    func add(_ text: String) { partials.append(text) }
    func endOfUtterance(_ detected: Bool) { endOfUtteranceEvents.append(detected) }
}
