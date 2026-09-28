import Accelerate
import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation
import KvoiceDomain

/// The production `ParakeetRuntime` (ADR-019). This is the **only** file in
/// kvoice that imports FluidAudio, and the only place its types, Core ML's
/// `MLModel` / `MLComputeUnits`, and AVFoundation's `AVAudioPCMBuffer` appear
/// in this package; a source-scanning test enforces it. The per-model
/// pipelines below cannot move to sibling files without a second
/// `import FluidAudio` (each names a vendor manager or model type), which
/// rule 1 forbids; what needs no vendor type is split out instead — the
/// pure `*Support.swift` files (facts, chunking, CIF, text assembly) and
/// `CoreMLTensorSupport.swift` (tensor readers and padders over
/// `MLMultiArray` only).
///
/// Trust model, restated where it is enforced: the runtime is handed the
/// verified package's `model/` folder and builds every Core ML model from an
/// explicit file URL inside it. It never calls `AsrModels.load(from:)`,
/// `download`, `downloadAndLoad`, `loadFromCache` or `loadWithAutoRecovery`
/// (the TDT helpers that route through FluidAudio's `ModelHub` and would
/// re-download on a failed load), and it sets `ModelHub.offlineMode` so that
/// path would throw even if something reached it. The Unified managers'
/// `loadModels(from:)` and `StreamingNemotronMultilingualAsrManager
/// .loadModels(from:)` are `MLModel.load(contentsOf:)` over the given folder
/// and nothing else — read from the pinned source, not assumed. (The
/// Nemotron manager would also compile an `.mlpackage` it found beside a
/// missing `.mlmodelc` and cache the result next to it; kvoice's package
/// holds only compiled bundles and the validator refuses anything else, so
/// that branch is unreachable and the folder is never written.) SenseVoice
/// (2026-09-16) is driven over the library's public `SenseVoiceModels`
/// graphs, each built here with `MLModel.load(contentsOf:)` — its
/// `SenseVoiceModels.load(from:)` would pin the encoder's compute units
/// itself and compile a stray `.mlpackage`, and its `SenseVoiceManager`
/// strips the language tag before returning — so the pipeline
/// (`SenseVoicePipeline`) is the manager's five steps restated over the
/// same public pieces, keeping the tag. Paraformer (2026-09-16, third
/// model) is the same shape over `ParaformerModels`' public graphs and
/// initialiser (`ParaformerPipeline`): its `ParaformerModels.load(from:)`
/// pins the compute units itself and compiles a stray `.mlpackage`, and its
/// `ParaformerManager` keeps a literal `<unk>` in the text, truncates past
/// 512 frames with only a log line and never exposes the logits, so a
/// non-finite tensor would become text. Parakeet Realtime EOU
/// (2026-09-16, fourth model) is driven through `StreamingEouAsrManager`,
/// whose `loadModels(from:)` is `MLModel.load(contentsOf:)` over
/// `streaming_encoder`, `decoder` and `joint_decision` plus `vocab.json`
/// (`ParakeetEOUPipeline`); the fused decoder+joint it would also load
/// behind `FLUID_EOU_FUSED=1` is not published in the repository and not
/// part of the package, so that branch is unreachable.
public struct FluidAudioParakeetRuntime: ParakeetRuntime {
    public init() {
        // Before any FluidAudio loader is touched, as upstream documents.
        // Idempotent; a second engine instance sets the same value.
        ModelHub.offlineMode = true
    }

    // MARK: - Compute units

    /// The one mapping from kvoice's compute-unit vocabulary to Core ML's,
    /// mirroring `WhisperKitRuntimeFactory.computeOptions(for:)`.
    static func mlComputeUnits(for units: SpeechComputeUnits) -> MLComputeUnits {
        switch units {
        case .neuralEngineAndCPU: return .cpuAndNeuralEngine
        case .gpuAndCPU: return .cpuAndGPU
        case .all: return .all
        case .cpuOnly: return .cpuOnly
        }
    }

    private static func configuration(_ units: MLComputeUnits) -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        return configuration
    }

    // MARK: - ParakeetRuntime

    public func makeBatchDecoder(configuration: ParakeetRuntimeConfiguration) async throws -> any ParakeetBatchDecoder {
        switch configuration.variant {
        case .tdtV3:
            return try await TDTBatchDecoder(folder: configuration.modelFolderURL, units: configuration.computeUnits)
        case .unifiedEN:
            return try await UnifiedBatchDecoder(folder: configuration.modelFolderURL, units: configuration.computeUnits)
        case .nemotronMultilingual:
            return try await NemotronPipeline(folder: configuration.modelFolderURL, units: configuration.computeUnits)
        case .senseVoiceSmall:
            return try await SenseVoicePipeline(
                folder: configuration.modelFolderURL,
                graph: ParakeetModelVariant.senseVoiceEncoderGraph(for: configuration.computeUnits),
                units: configuration.computeUnits
            )
        case .paraformerLargeZh:
            return try await ParaformerPipeline(
                folder: configuration.modelFolderURL,
                precision: ParaformerGraph.shippedPrecision,
                units: configuration.computeUnits
            )
        case .parakeetEOU:
            return try await ParakeetEOUPipeline(folder: configuration.modelFolderURL, units: configuration.computeUnits)
        }
    }

    public func makeStreamingSession(configuration: ParakeetRuntimeConfiguration) async throws -> any ParakeetStreamingSession {
        switch configuration.variant {
        case .tdtV3:
            throw ParakeetTranscriptionError.streamingUnsupported(.tdtV3)
        case .unifiedEN:
            return try await UnifiedStreamingSession(folder: configuration.modelFolderURL, units: configuration.computeUnits)
        case .nemotronMultilingual:
            // Invariant: Nemotron streams over its resident pipeline (the
            // batch decoder's `makeStreamingSession`, which the engine asks
            // first), so a second graph set is never built here. Reached
            // only by a caller bypassing the engine.
            throw ParakeetTranscriptionError.streamingSessionUnavailable(.nemotronMultilingual)
        case .senseVoiceSmall:
            // Non-autoregressive: the whole utterance in one pass, no
            // partials to offer (the picker offers Batch only).
            throw ParakeetTranscriptionError.streamingUnsupported(.senseVoiceSmall)
        case .paraformerLargeZh:
            // Non-autoregressive as well (CIF fires over the whole window).
            throw ParakeetTranscriptionError.streamingUnsupported(.paraformerLargeZh)
        case .parakeetEOU:
            // The Nemotron shape: streams over the resident pipeline.
            throw ParakeetTranscriptionError.streamingSessionUnavailable(.parakeetEOU)
        }
    }
}

/// The `vocab.json` / `parakeet_vocab.json` shapes FluidAudio publishes: a
/// `{"<id>": "<token>"}` dictionary (the 0.6B Parakeets) or an array
/// (SenseVoice's 25,055 SentencePiece pieces; Paraformer's 8,404
/// CharTokenizer tokens; the 110M Parakeet). Parsed
/// here so the vocabulary comes from the verified file, not from a lookup.
private func loadFluidAudioVocabulary(at url: URL) throws -> [Int: String] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    var vocabulary: [Int: String] = [:]
    if let dictionary = object as? [String: String] {
        for (key, value) in dictionary {
            if let id = Int(key) { vocabulary[id] = value }
        }
    } else if let array = object as? [String] {
        for (index, token) in array.enumerated() { vocabulary[index] = token }
    }
    guard !vocabulary.isEmpty else {
        throw AsrModelsError.loadingFailed("The vocabulary file has an unexpected format.")
    }
    return vocabulary
}

// MARK: - Parakeet TDT v3

/// `AsrManager` over models this adapter constructed itself from the
/// verified folder. Upstream's own placement is kept: the preprocessor is a
/// CPU graph (Core ML maps 100 % of its ops to the CPU whatever is asked),
/// encoder, decoder and joint follow the user's choice.
private actor TDTBatchDecoder: ParakeetBatchDecoder {
    private var manager: AsrManager?

    init(folder: URL, units: SpeechComputeUnits) async throws {
        let chosen = FluidAudioParakeetRuntime.mlComputeUnits(for: units)
        let cpu = FluidAudioParakeetRuntime.mlComputeUnits(for: .cpuOnly)
        let preprocessor = try await MLModel.load(
            contentsOf: folder.appendingPathComponent(ModelNames.ASR.preprocessorFile, isDirectory: true),
            configuration: Self.configuration(cpu)
        )
        let encoder = try await MLModel.load(
            contentsOf: folder.appendingPathComponent(ParakeetEncoderPrecision.int8.encoderFileName, isDirectory: true),
            configuration: Self.configuration(chosen)
        )
        let decoder = try await MLModel.load(
            contentsOf: folder.appendingPathComponent(ModelNames.ASR.decoderFile, isDirectory: true),
            configuration: Self.configuration(chosen)
        )
        let joint = try await MLModel.load(
            contentsOf: folder.appendingPathComponent(ModelNames.ASR.jointV3File, isDirectory: true),
            configuration: Self.configuration(chosen)
        )
        let vocabulary = try loadFluidAudioVocabulary(
            at: folder.appendingPathComponent(ModelNames.ASR.vocabularyFile, isDirectory: false)
        )
        let models = AsrModels(
            encoder: encoder,
            preprocessor: preprocessor,
            decoder: decoder,
            joint: joint,
            configuration: Self.configuration(chosen),
            vocabulary: vocabulary,
            version: .v3
        )
        let version = AsrModelVersion.v3
        let manager = AsrManager(
            config: ASRConfig(
                tdtConfig: TdtConfig(blankId: version.blankId),
                encoderHiddenSize: version.encoderHiddenSize
            ),
            models: models
        )
        try await manager.loadModels(models)
        self.manager = manager
    }

    private static func configuration(_ units: MLComputeUnits) -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        return configuration
    }

    func transcribe(samples: [Float], languageHint: String?) async throws -> ParakeetTranscript {
        guard let manager else { throw ASRError.notInitialized }
        var state = try TdtDecoderState(decoderLayers: AsrModelVersion.v3.decoderLayers)
        let language = languageHint.flatMap(Language.init(rawValue:))
        let result = try await manager.transcribe(samples, decoderState: &state, language: language)
        let tokens = (result.tokenTimings ?? []).map {
            ParakeetTokenSpan(text: $0.token, start: $0.startTime, end: $0.endTime)
        }
        let rtf: Double? = result.duration > 0 ? result.processingTime / result.duration : nil
        return ParakeetTranscript(text: result.text, tokens: tokens, runtimeReportedRealTimeFactor: rtf)
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }
}

// MARK: - Parakeet Unified EN, batch

/// `UnifiedAsrManager.loadModels(from:)` is local-only. The library pins the
/// decoder and joint to the CPU (tiny per-token steps) and applies the
/// configuration's units to the encoder, coercing an int8 encoder under
/// `.all` to CPU + Neural Engine because Core ML's GPU path aborts on the
/// quantised ops; kvoice passes the user's choice through unchanged.
private actor UnifiedBatchDecoder: ParakeetBatchDecoder {
    private var manager: UnifiedAsrManager?
    private let sampleRate: Double

    init(folder: URL, units: SpeechComputeUnits) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = FluidAudioParakeetRuntime.mlComputeUnits(for: units)
        let manager = UnifiedAsrManager(configuration: configuration, encoderPrecision: .int8)
        try await manager.loadModels(from: folder)
        self.manager = manager
        self.sampleRate = Double(await manager.config.sampleRate)
    }

    func transcribe(samples: [Float], languageHint _: String?) async throws -> ParakeetTranscript {
        guard let manager else { throw ASRError.notInitialized }
        let result = try await manager.transcribeWithTimings(samples)
        let tokens = result.tokenTimings.map {
            ParakeetTokenSpan(text: $0.token, start: $0.startTime, end: $0.endTime)
        }
        return ParakeetTranscript(text: result.text, tokens: tokens, runtimeReportedRealTimeFactor: nil)
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }
}

// MARK: - Parakeet Unified EN, streaming

/// `StreamingUnifiedAsrManager` over the `70_13_13` int8 streaming export
/// (5.6 s left context, 1.04 s chunk, 1.04 s right → 2.08 s latency). The
/// manager takes `AVAudioPCMBuffer`; kvoice's chunks are already 16 kHz
/// mono Float32, so the buffer is a straight copy — no resampling happens.
private actor UnifiedStreamingSession: ParakeetStreamingSession {
    private var manager: StreamingUnifiedAsrManager?
    private let format: AVAudioFormat

    init(folder: URL, units: SpeechComputeUnits) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = FluidAudioParakeetRuntime.mlComputeUnits(for: units)
        let manager = StreamingUnifiedAsrManager(configuration: configuration, encoderPrecision: .int8)
        try await manager.loadModels(from: folder)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(await manager.config.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw ASRError.invalidAudioData
        }
        self.manager = manager
        self.format = format
    }

    func append(samples: [Float]) async throws -> String {
        guard let manager else { throw ASRError.notInitialized }
        guard !samples.isEmpty else { return await manager.getPartialTranscript() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw ASRError.invalidAudioData
        }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try await manager.appendAudio(buffer)
        try await manager.processBufferedAudio()
        return await manager.getPartialTranscript()
    }

    func finish() async throws -> String {
        guard let manager else { throw ASRError.notInitialized }
        return try await manager.finish()
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }
}

// MARK: - Nemotron 3.5 ASR Streaming Multilingual

/// One `StreamingNemotronMultilingualAsrManager` for both modes (ADR-019
/// amendment, 2026-09-16). `loadModels(from:)` is `MLModel.load(contentsOf:)`
/// over `encoder`, `decoder`, `joint` and the fused `decoder_joint` bundles
/// plus `metadata.json` (chunk geometry and the `prompt_dictionary`) and
/// `tokenizer.json`; the mel front end is the library's native Swift one.
/// The configuration's units apply to every graph — the library's own
/// default is CPU + Neural Engine, and it warns that `.all` sends the
/// quantised encoder to the GPU (slow, not fatal; measured 2026-09-16).
///
/// Batch is the streaming pipeline run to completion: `reset()`, the
/// language prompt, every sample through `process(samples:)` (a chunk per
/// 2.24 s) and `finish()`, which pads the tail chunk and returns the text
/// with the leading language tag stripped. A streaming session is the same
/// manager driven live; the engine guarantees the two never overlap
/// (`endStreaming` precedes the batch pass), and the session's `unload` is
/// a `reset()` so the graphs stay resident.
private actor NemotronPipeline: ParakeetBatchDecoder {
    private var manager: StreamingNemotronMultilingualAsrManager?

    init(folder: URL, units: SpeechComputeUnits) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = FluidAudioParakeetRuntime.mlComputeUnits(for: units)
        let manager = StreamingNemotronMultilingualAsrManager(configuration: configuration)
        try await manager.loadModels(from: folder)
        self.manager = manager
    }

    func transcribe(samples: [Float], languageHint: String?) async throws -> ParakeetTranscript {
        guard let manager else { throw ASRError.notInitialized }
        await manager.reset()
        await manager.setLanguage(languageHint)
        _ = try await manager.process(samples: samples)
        let (text, timings) = try await manager.finishWithTokenTimings()
        let tokens = timings.map {
            ParakeetTokenSpan(text: $0.token, start: $0.startTime, end: $0.endTime)
        }
        let detected = await manager.detectedLanguage()
            .flatMap(ParakeetModelVariant.nemotronLanguageCode(forReportedTag:))
        return ParakeetTranscript(text: text, tokens: tokens, runtimeReportedRealTimeFactor: nil, detectedLanguage: detected)
    }

    func makeStreamingSession(languageHint: String?) async throws -> (any ParakeetStreamingSession)? {
        guard let manager else { throw ASRError.notInitialized }
        await manager.reset()
        await manager.setLanguage(languageHint)
        return NemotronStreamingSession(manager: manager)
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }
}

/// The live half of `NemotronPipeline`: partial text is the tokens decoded
/// so far (RNNT commits, never revises). `unload` only resets the manager;
/// the pipeline that owns the graphs releases them.
private actor NemotronStreamingSession: ParakeetStreamingSession {
    private var manager: StreamingNemotronMultilingualAsrManager?

    init(manager: StreamingNemotronMultilingualAsrManager) {
        self.manager = manager
    }

    func append(samples: [Float]) async throws -> String {
        guard let manager else { throw ASRError.notInitialized }
        guard !samples.isEmpty else { return await manager.getPartialTranscript() }
        _ = try await manager.process(samples: samples)
        return await manager.getPartialTranscript()
    }

    func finish() async throws -> String {
        guard let manager else { throw ASRError.notInitialized }
        return try await manager.finish()
    }

    func unload() async {
        await manager?.reset()
        manager = nil
    }
}

// MARK: - SenseVoice Small

/// The SenseVoice pipeline over `SenseVoiceModels`' public graphs (ADR-019
/// amendment, 2026-09-16): waveform ×32768 → `SenseVoicePreprocessor`
/// (fp32, CPU only) → `[1, T, 560]` LFR features, zero-padded to the
/// smallest enumerated bucket → the encoder + CTC head with the language and
/// text-norm query indices → `ctc_logits [1, bucket + 4, 25055]` → greedy
/// CTC on the host (argmax per frame, drop blank 0, collapse repeats) →
/// the library's `decodeCtcTokenIds` → `SenseVoiceTranscriptParser`.
///
/// Why not `SenseVoiceManager.transcribe`: it strips every `<|…|>` tag
/// before returning, so the language the model detected is gone; and its
/// `SenseVoiceModels.load(from:)` fixes the encoder's compute units per
/// precision. The steps above are that manager's, restated over the same
/// public models with the tag kept and the units kvoice chose.
///
/// The graph is chosen by the compute-unit setting before this is built
/// (`ParakeetModelVariant.senseVoiceEncoderGraph`): int8 on the Neural
/// Engine, fp32 elsewhere, because the fp16/int8 exports produce NaN on the
/// CPU/GPU fp16 path. A NaN logit tensor is still checked for and refused
/// (`ASRError.processingFailed`) so a misplaced graph is an error, never
/// garbage text. Recordings longer than the preprocessor's 30 s input
/// ceiling are cut by `SenseVoiceAudioChunker` and joined by
/// `SenseVoiceTranscriptJoiner`; a window under its 0.2 s floor is
/// zero-padded. The library's manager has neither guard.
actor SenseVoicePipeline: ParakeetBatchDecoder {
    private var models: SenseVoiceModels?
    private let graph: SenseVoiceEncoderGraph
    private let unitsDescription: String

    init(folder: URL, graph: SenseVoiceEncoderGraph, units: SpeechComputeUnits) async throws {
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        let encoderConfiguration = MLModelConfiguration()
        encoderConfiguration.computeUnits = FluidAudioParakeetRuntime.mlComputeUnits(for: units)
        let preprocessor = try await MLModel.load(
            contentsOf: folder.appendingPathComponent(SenseVoiceEncoderGraph.preprocessorBundle, isDirectory: true),
            configuration: cpu
        )
        let encoder = try await MLModel.load(
            contentsOf: folder.appendingPathComponent(graph.bundle, isDirectory: true),
            configuration: encoderConfiguration
        )
        let vocabulary = try loadFluidAudioVocabulary(
            at: folder.appendingPathComponent(ModelNames.SenseVoice.vocabularyFile, isDirectory: false)
        )
        self.models = SenseVoiceModels(preprocessor: preprocessor, encoder: encoder, vocabulary: vocabulary)
        self.graph = graph
        self.unitsDescription = "\(graph.rawValue) under \(units.displayName)"
    }

    func transcribe(samples: [Float], languageHint: String?) async throws -> ParakeetTranscript {
        guard let models else { throw ASRError.notInitialized }
        let language = ParakeetModelVariant.senseVoiceLanguageEmbedding(forLanguageCode: languageHint)
            ?? SenseVoiceEncoderGraph.autoDetectLanguage
        var texts: [String] = []
        var tokens: [ParakeetTokenSpan] = []
        var detected: String?
        for window in SenseVoiceAudioChunker.windows(for: samples) {
            // Too short to decode → skipped; under the preprocessor's
            // floor → zero-padded (the pure rule, tested in the support file).
            guard let audio = SenseVoiceAudioChunker.prepared(Array(samples[window])) else { continue }
            let offsetSeconds = Double(window.lowerBound) / Double(SenseVoiceConfig.sampleRate)
            let decoded = try Self.decodeWindow(audio, language: language, graph: graph, models: models, units: unitsDescription)
            let parsed = SenseVoiceTranscriptParser.parse(decoded.raw)
            texts.append(parsed.text)
            if detected == nil { detected = parsed.language }
            tokens.append(contentsOf: decoded.spans.map {
                ParakeetTokenSpan(text: $0.text, start: $0.start + offsetSeconds, end: $0.end + offsetSeconds)
            })
        }
        return ParakeetTranscript(
            text: SenseVoiceTranscriptJoiner.join(texts),
            tokens: tokens,
            runtimeReportedRealTimeFactor: nil,
            detectedLanguage: detected
        )
    }

    func unload() async {
        models = nil
    }

    // MARK: Pipeline steps

    private struct DecodedWindow {
        let raw: String
        let spans: [ParakeetTokenSpan]
    }

    private static func decodeWindow(
        _ samples: [Float], language: Int32, graph: SenseVoiceEncoderGraph, models: SenseVoiceModels, units: String
    ) throws -> DecodedWindow {
        let features = try runFunASRPreprocessor(samples, preprocessor: models.preprocessor, model: "SenseVoice")
        let (logits, validFrames) = try runEncoder(features, language: language, graph: graph, encoder: models.encoder)
        let ids = try greedyCTC(logits, frames: validFrames, units: units)
        // Every kept token, with the frame it was emitted on.
        var pieces: [Int] = []
        var spans: [ParakeetTokenSpan] = []
        for (frame, id) in ids {
            pieces.append(id)
            guard let piece = models.vocabulary[id], !piece.hasPrefix("<|") else { continue }
            let start = Double(max(0, frame - SenseVoiceEncoderGraph.queryTokenCount)) * SenseVoiceEncoderGraph.secondsPerFrame
            spans.append(ParakeetTokenSpan(text: piece, start: start, end: start + SenseVoiceEncoderGraph.secondsPerFrame))
        }
        return DecodedWindow(raw: decodeCtcTokenIds(pieces, vocabulary: models.vocabulary), spans: spans)
    }

    /// `features [1, T, 560]` padded to the graph's shape → (`ctc_logits`,
    /// 4 + T). The chunker keeps T under the largest bucket; the `min` is
    /// the last line of defence against a truncating encoder.
    private static func runEncoder(
        _ features: MLMultiArray, language: Int32, graph: SenseVoiceEncoderGraph, encoder: MLModel
    ) throws -> (MLMultiArray, Int) {
        let frames = min(features.shape[1].intValue, SenseVoiceEncoderGraph.maxFrames)
        let bucket = graph.paddedFrames(for: frames)
        let speech = try FeatureTensors.zeroPadded(features, frames: frames, bucket: bucket, dimension: SenseVoiceConfig.featureDim)
        let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "speech": MLFeatureValue(multiArray: speech),
            "speech_lengths": MLFeatureValue(multiArray: try FeatureTensors.scalar(Int32(frames))),
            "language": MLFeatureValue(multiArray: try FeatureTensors.scalar(language)),
            "textnorm": MLFeatureValue(multiArray: try FeatureTensors.scalar(SenseVoiceEncoderGraph.textNormWithITN))
        ]))
        guard let logits = output.featureValue(for: "ctc_logits")?.multiArrayValue else {
            throw ASRError.processingFailed("SenseVoice encoder produced no ctc_logits")
        }
        return (logits, SenseVoiceEncoderGraph.queryTokenCount + frames)
    }

    /// Argmax per valid frame (`LogitRows.argmax`, which refuses a
    /// non-finite row — the symptom of the fp16/int8 encoder off the Neural
    /// Engine), then `SenseVoiceCTCDecoder.collapse` (blank dropped, repeats
    /// merged).
    private static func greedyCTC(
        _ logits: MLMultiArray, frames validFrames: Int, units: String
    ) throws -> [(frame: Int, id: Int)] {
        let argmax = try LogitRows.argmax(logits, rows: validFrames, model: "SenseVoice encoder", units: units)
        return SenseVoiceCTCDecoder.collapse(argmax)
    }
}

// MARK: - Shared FunASR pieces

/// `waveform [1, N]` in kaldi's int16 range → `features [1, T, 560]`. The
/// SenseVoice and Paraformer packages ship the same fp32 CPU front-end graph
/// (digest-identical `model.mil` and weights), so one call serves both. The
/// tensor readers and padders the pipelines share (`LogitRows`,
/// `FeatureTensors`) live in `CoreMLTensorSupport.swift`, which names no
/// FluidAudio type.
private func runFunASRPreprocessor(_ samples: [Float], preprocessor: MLModel, model: String) throws -> MLMultiArray {
    let waveform = try MLMultiArray(shape: [1, NSNumber(value: samples.count)], dataType: .float32)
    let pointer = waveform.dataPointer.assumingMemoryBound(to: Float32.self)
    var scale = SenseVoiceConfig.waveformScale
    samples.withUnsafeBufferPointer { source in
        vDSP_vsmul(source.baseAddress!, 1, &scale, pointer, 1, vDSP_Length(samples.count))
    }
    let output = try preprocessor.prediction(from: MLDictionaryFeatureProvider(
        dictionary: ["waveform": MLFeatureValue(multiArray: waveform)]
    ))
    guard let features = output.featureValue(for: "features")?.multiArrayValue else {
        throw ASRError.processingFailed("\(model) preprocessor produced no features")
    }
    return features
}

// MARK: - Paraformer-large zh

/// The Paraformer pipeline over `ParaformerModels`' public graphs (ADR-019
/// amendment, 2026-09-16, third model): waveform ×32768 →
/// `ParaformerPreprocessor` (fp32, CPU only; the same graph as SenseVoice's)
/// → `[1, T, 560]` LFR features, zero-padded to the smallest enumerated
/// bucket → the SANM encoder → `enc_out [1, bucket, 512]` → the CIF-alphas
/// graph → `alphas [1, bucket]` → `ParaformerCIF.integrateAndFire` on the
/// host (one acoustic embedding per character, plus the frame each fired
/// on) → the parallel decoder over `enc [1, 512, 512]` and `ac [1, 128,
/// 512]` (both fixed shapes, zero-padded) → `logits [1, 128, 8404]` → one
/// argmax per token → `ParaformerTextAssembler`.
///
/// Why not `ParaformerManager.transcribe`: it keeps a literal `<unk>` in
/// the text, truncates audio past 512 frames with only a log line, and
/// never exposes the logits — so a graph producing NaN on some device
/// would become inserted text. `ParaformerModels.load(from:)` would also
/// pin the compute units itself (CPU + Neural Engine) and compile a stray
/// `.mlpackage`. The steps above are the manager's, restated over the same
/// public models under the units kvoice chose; parity with the manager's
/// own text was checked on the live samples before the throwaway
/// comparison was deleted (Changelog).
///
/// One export per graph (the int8 pair — the card measures it
/// accuracy-neutral, and the live samples decoded character-identical to
/// fp16). The encoder is NaN off the Neural Engine and there is no fp32
/// export, so the variant refuses GPU + CPU and CPU only before this is
/// built; here the encoder output is checked row by row and a non-finite
/// row is refused (`ASRError.processingFailed`) naming the units — the
/// check must sit on `enc_out`, because the CIF-alphas graph turns NaN
/// into `sigmoid(NaN) = 0` and the symptom downstream is an empty
/// transcript, not a NaN. The logits are checked the same way.
/// Recordings are cut into ≤15 s windows by `SenseVoiceAudioChunker` (the
/// preprocessor's 30 s ceiling, the decoder's 512-frame / 128-token cap,
/// and upstream's "under 20 s" recommendation all point the same way) and
/// joined by `SenseVoiceTranscriptJoiner`; a window under the 0.2 s floor
/// is zero-padded.
actor ParaformerPipeline: ParakeetBatchDecoder {
    private var models: ParaformerModels?
    private let unitsDescription: String

    init(folder: URL, precision: ParaformerGraph.Precision, units: SpeechComputeUnits) async throws {
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        let chosen = MLModelConfiguration()
        chosen.computeUnits = FluidAudioParakeetRuntime.mlComputeUnits(for: units)
        let preprocessor = try await MLModel.load(
            contentsOf: folder.appendingPathComponent(ParaformerGraph.preprocessorBundle, isDirectory: true),
            configuration: cpu
        )
        let encoder = try await MLModel.load(
            contentsOf: folder.appendingPathComponent(precision.encoderBundle, isDirectory: true),
            configuration: chosen
        )
        let cifAlphas = try await MLModel.load(
            contentsOf: folder.appendingPathComponent(ParaformerGraph.cifAlphasBundle, isDirectory: true),
            configuration: chosen
        )
        let decoder = try await MLModel.load(
            contentsOf: folder.appendingPathComponent(precision.decoderBundle, isDirectory: true),
            configuration: chosen
        )
        let vocabulary = try loadFluidAudioVocabulary(
            at: folder.appendingPathComponent(ParaformerGraph.vocabularyFile, isDirectory: false)
        )
        self.models = ParaformerModels(
            preprocessor: preprocessor, encoder: encoder, cifAlphas: cifAlphas, decoder: decoder, vocabulary: vocabulary
        )
        self.unitsDescription = "\(precision.rawValue) under \(units.displayName)"
    }

    func transcribe(samples: [Float], languageHint _: String?) async throws -> ParakeetTranscript {
        guard let models else { throw ASRError.notInitialized }
        var texts: [String] = []
        var tokens: [ParakeetTokenSpan] = []
        for window in SenseVoiceAudioChunker.windows(for: samples, maxSeconds: ParaformerGraph.maxWindowSeconds) {
            guard let audio = SenseVoiceAudioChunker.prepared(Array(samples[window])) else { continue }
            let offsetSeconds = Double(window.lowerBound) / Double(ParaformerConfig.sampleRate)
            let decoded = try Self.decodeWindow(audio, models: models, units: unitsDescription)
            texts.append(decoded.text)
            tokens.append(contentsOf: decoded.spans.map {
                ParakeetTokenSpan(text: $0.text, start: $0.start + offsetSeconds, end: $0.end + offsetSeconds)
            })
        }
        return ParakeetTranscript(
            text: SenseVoiceTranscriptJoiner.join(texts),
            tokens: tokens,
            runtimeReportedRealTimeFactor: nil,
            detectedLanguage: "zh"
        )
    }

    func unload() async {
        models = nil
    }

    // MARK: Pipeline steps

    private struct DecodedWindow {
        let text: String
        let spans: [ParakeetTokenSpan]
    }

    private static func decodeWindow(_ samples: [Float], models: ParaformerModels, units: String) throws -> DecodedWindow {
        let features = try runFunASRPreprocessor(samples, preprocessor: models.preprocessor, model: "Paraformer")
        // The chunker keeps a window at ≤ 250 frames; the `min` is the last
        // line of defence for the decoder's fixed memory length.
        let frames = min(features.shape[1].intValue, ParaformerGraph.decoderEncoderFrames)
        let bucket = ParaformerGraph.bucket(forFrames: frames)
        let encoderOutput = try runEncoder(features, frames: frames, bucket: bucket, encoder: models.encoder)
        let rows = try LogitRows.rows(encoderOutput, count: frames, width: ParaformerGraph.encoderDim, model: "Paraformer encoder", units: units)
        let alphas = try runCifAlphas(encoderOutput, frames: frames, cifAlphas: models.cifAlphas)
        let fired = ParaformerCIF.integrateAndFire(encoderRows: rows, alphas: alphas)
        let tokenCount = min(fired.embeddings.count, ParaformerGraph.decoderMaxTokens)
        guard tokenCount > 0 else { return DecodedWindow(text: "", spans: []) }
        let logits = try runDecoder(
            rows, frames: frames, embeddings: Array(fired.embeddings.prefix(tokenCount)), decoder: models.decoder
        )
        let ids = try LogitRows.argmax(logits, rows: tokenCount, model: "Paraformer decoder", units: units)
        let words = ParaformerTextAssembler.words(ids, vocabulary: models.vocabulary)
        // A token's span runs from the previous fire frame to its own.
        let spans = words.map { word -> ParakeetTokenSpan in
            let start = word.firstPosition == 0 ? 0 : fired.fireFrames[word.firstPosition - 1]
            let end = fired.fireFrames[word.lastPosition]
            return ParakeetTokenSpan(
                text: word.text,
                start: Double(start) * ParaformerGraph.secondsPerFrame,
                end: Double(end) * ParaformerGraph.secondsPerFrame
            )
        }
        return DecodedWindow(text: ParaformerTextAssembler.join(words.map(\.text)), spans: spans)
    }

    /// `features [1, T, 560]` zero-padded to `[1, bucket, 560]` plus
    /// `speech_lengths [1]` → `enc_out [1, bucket, 512]`.
    private static func runEncoder(_ features: MLMultiArray, frames: Int, bucket: Int, encoder: MLModel) throws -> MLMultiArray {
        let speech = try FeatureTensors.zeroPadded(features, frames: frames, bucket: bucket, dimension: ParaformerGraph.featureDim)
        let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "speech": MLFeatureValue(multiArray: speech),
            "speech_lengths": MLFeatureValue(multiArray: try FeatureTensors.scalar(Int32(frames)))
        ]))
        guard let encoderOutput = output.featureValue(for: "enc_out")?.multiArrayValue else {
            throw ASRError.processingFailed("Paraformer encoder produced no enc_out")
        }
        return encoderOutput
    }

    /// `enc_out` → the first `frames` alphas. Finite by construction once
    /// `enc_out` has passed its check (a sigmoid), which is why the
    /// non-finite refusal sits on the encoder output and not here.
    private static func runCifAlphas(_ encoderOutput: MLMultiArray, frames: Int, cifAlphas: MLModel) throws -> [Float] {
        let output = try cifAlphas.prediction(from: MLDictionaryFeatureProvider(
            dictionary: ["enc_out": MLFeatureValue(multiArray: encoderOutput)]
        ))
        guard let array = output.featureValue(for: "alphas")?.multiArrayValue else {
            throw ASRError.processingFailed("Paraformer CIF-alphas graph produced no alphas")
        }
        let count = min(frames, array.count)
        var alphas = [Float](repeating: 0, count: count)
        if array.dataType == .float32 {
            let source = array.dataPointer.assumingMemoryBound(to: Float32.self)
            for index in 0..<count { alphas[index] = source[index] }
        } else {
            // `[1, T]` with T ≤ 256 per window: the boxed accessor is cheap
            // here and independent of the storage type.
            for index in 0..<count { alphas[index] = array[[0, NSNumber(value: index)]].floatValue }
        }
        return alphas
    }

    /// The fixed-shape decoder: `enc [1, 512, 512]` (the encoder rows,
    /// zero-padded), `elen [1]`, `ac [1, 128, 512]` (the fired embeddings,
    /// zero-padded), `tn [1]` → `logits [1, 128, 8404]`.
    private static func runDecoder(
        _ rows: [[Float]], frames: Int, embeddings: [[Float]], decoder: MLModel
    ) throws -> MLMultiArray {
        let dimension = ParaformerGraph.encoderDim
        let memoryFrames = ParaformerGraph.decoderEncoderFrames
        let maxTokens = ParaformerGraph.decoderMaxTokens
        let memory = try MLMultiArray(
            shape: [1, NSNumber(value: memoryFrames), NSNumber(value: dimension)], dataType: .float32
        )
        let memoryPointer = memory.dataPointer.assumingMemoryBound(to: Float32.self)
        memset(memoryPointer, 0, memoryFrames * dimension * MemoryLayout<Float32>.size)
        for (frame, row) in rows.prefix(frames).enumerated() {
            row.withUnsafeBufferPointer { (memoryPointer + frame * dimension).update(from: $0.baseAddress!, count: dimension) }
        }
        let acoustic = try MLMultiArray(
            shape: [1, NSNumber(value: maxTokens), NSNumber(value: dimension)], dataType: .float32
        )
        let acousticPointer = acoustic.dataPointer.assumingMemoryBound(to: Float32.self)
        memset(acousticPointer, 0, maxTokens * dimension * MemoryLayout<Float32>.size)
        for (token, embedding) in embeddings.prefix(maxTokens).enumerated() {
            embedding.withUnsafeBufferPointer { (acousticPointer + token * dimension).update(from: $0.baseAddress!, count: dimension) }
        }
        let output = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "enc": MLFeatureValue(multiArray: memory),
            "elen": MLFeatureValue(multiArray: try FeatureTensors.scalar(Int32(frames))),
            "ac": MLFeatureValue(multiArray: acoustic),
            "tn": MLFeatureValue(multiArray: try FeatureTensors.scalar(Int32(min(embeddings.count, maxTokens))))
        ]))
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw ASRError.processingFailed("Paraformer decoder produced no logits")
        }
        return logits
    }
}

// MARK: - Parakeet Realtime EOU 120M

/// One `StreamingEouAsrManager` for both modes (ADR-019 amendment,
/// 2026-09-16, fourth model), built with `chunkSize: .ms320` — the tier the
/// package ships — and the library's default 1.28 s end-of-utterance
/// debounce. `loadModels(from:)` is `MLModel.load(contentsOf:)` over
/// `streaming_encoder`, `decoder` and `joint_decision` plus the vocabulary,
/// under the configuration's units for every graph; the mel front end is
/// the library's native Swift one. The manager takes `AVAudioPCMBuffer`;
/// kvoice's samples are already 16 kHz mono Float32, so the buffer is a
/// straight copy — no resampling happens.
///
/// Batch is the streaming pipeline run to completion: `reset()`, every
/// sample appended and every full chunk decoded (`processBufferedAudio`),
/// then the tail padded with exactly the zeros the manager's own `finish()`
/// would add (`ParakeetEOUChunking.tailPaddingSamples`) and decoded the same
/// way — done here rather than through `finish()` because `finish()` clears
/// the per-token timestamps kvoice reads for the segment bounds. Text,
/// timestamps and raw pieces are read, then `reset()` clears the loopback
/// caches, the LSTM state and the leftover silence. A streaming session is
/// the same manager driven live; the engine guarantees the two never
/// overlap (`endStreaming` precedes the batch pass), and the session's
/// `unload` is a `reset()` so the graphs stay resident.
///
/// The `<EOU>` token stops the library's decode of the chunk it appears in
/// and is never appended to the text; `<EOB>` and `<unk>` would be, so the
/// text is passed through `ParakeetEOUTokens.cleaned`. The manager's
/// debounced `eouDetected` is the scalar the session reports and nothing
/// acts on (FR-AUD-007; the planned ADR-023).
private actor ParakeetEOUPipeline: ParakeetBatchDecoder {
    private var manager: StreamingEouAsrManager?
    private let format: AVAudioFormat

    init(folder: URL, units: SpeechComputeUnits) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = FluidAudioParakeetRuntime.mlComputeUnits(for: units)
        let manager = StreamingEouAsrManager(
            configuration: configuration,
            chunkSize: .ms320,
            eouDebounceMs: ParakeetEOUGraph.endOfUtteranceDebounceMilliseconds
        )
        try await manager.loadModels(from: folder)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(ParakeetEOUGraph.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw ASRError.invalidAudioData
        }
        self.manager = manager
        self.format = format
    }

    func transcribe(samples: [Float], languageHint _: String?) async throws -> ParakeetTranscript {
        guard let manager else { throw ASRError.notInitialized }
        await manager.reset()
        try await Self.feed(samples, to: manager, format: format)
        let padding = ParakeetEOUChunking.tailPaddingSamples(afterAppending: samples.count)
        if padding > 0 {
            try await Self.feed([Float](repeating: 0, count: padding), to: manager, format: format)
        }
        let text = await manager.getPartialTranscript()
        let spans = ParakeetEOUTokens.spans(
            timestampsMilliseconds: await manager.getTokenTimestampsMs(),
            pieces: await manager.getRawTokenStrings()
        )
        await manager.reset()
        return ParakeetTranscript(text: ParakeetEOUTokens.cleaned(text), tokens: spans, runtimeReportedRealTimeFactor: nil)
    }

    func makeStreamingSession(languageHint _: String?) async throws -> (any ParakeetStreamingSession)? {
        guard let manager else { throw ASRError.notInitialized }
        await manager.reset()
        return ParakeetEOUStreamingSession(manager: manager, format: format)
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }

    /// Appends the samples and decodes every full chunk they complete.
    static func feed(_ samples: [Float], to manager: StreamingEouAsrManager, format: AVAudioFormat) async throws {
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw ASRError.invalidAudioData
        }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try await manager.appendAudio(buffer)
        try await manager.processBufferedAudio()
    }
}

/// The live half of `ParakeetEOUPipeline`: partial text is the tokens
/// decoded so far (RNNT commits, never revises), a new partial per 320 ms of
/// audio once the first 630 ms chunk is in. `endOfUtteranceDetected` is the
/// manager's debounced flag — sticky for the rest of the session in 0.15.7
/// (it is cleared only by `reset()`), so the engine sees at most one
/// `false → true` change per session. `unload` only resets the manager; the
/// pipeline that owns the graphs releases them.
private actor ParakeetEOUStreamingSession: ParakeetStreamingSession {
    private var manager: StreamingEouAsrManager?
    private let format: AVAudioFormat

    init(manager: StreamingEouAsrManager, format: AVAudioFormat) {
        self.manager = manager
        self.format = format
    }

    func append(samples: [Float]) async throws -> String {
        guard let manager else { throw ASRError.notInitialized }
        try await ParakeetEOUPipeline.feed(samples, to: manager, format: format)
        return ParakeetEOUTokens.cleaned(await manager.getPartialTranscript())
    }

    func finish() async throws -> String {
        guard let manager else { throw ASRError.notInitialized }
        return ParakeetEOUTokens.cleaned(try await manager.finish())
    }

    func endOfUtteranceDetected() async -> Bool {
        guard let manager else { return false }
        return await manager.eouDetected
    }

    func unload() async {
        await manager?.reset()
        manager = nil
    }
}
