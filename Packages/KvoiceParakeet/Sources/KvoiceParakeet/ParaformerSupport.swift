import Foundation
import KvoiceDomain

// The Paraformer-large facts that need no Core ML: the graphs and their
// fixed shapes, the host half of the CIF predictor (integrate-and-fire), and
// how the decoder's token ids become Mandarin text with the English BPE
// pieces rejoined. Everything here is pure and unit-tested; the
// FluidAudio-facing pipeline in `FluidAudioParakeetRuntime.swift` only calls
// it. Long recordings reuse `SenseVoiceAudioChunker` and
// `SenseVoiceTranscriptJoiner`: the two models share one FunASR front end
// (the preprocessor graph and weights are digest-identical) and one 30 s
// input ceiling.

/// The Paraformer-large graphs kvoice knows and the shapes they were
/// exported with (`FluidInference/paraformer-large-zh-coreml`, read from
/// each bundle's `model.mil` on 2026-09-16).
public enum ParaformerGraph {
    /// The encoder / decoder exports on the Hub. The package pins `int8`
    /// (the card: accuracy-neutral, half the size); `fp16` is kept so the
    /// opt-in live matrix test can load it from a scratch folder and the
    /// choice stays re-measurable.
    public enum Precision: String, Sendable, Equatable, CaseIterable {
        case int8
        case fp16

        public var encoderBundle: String {
            switch self {
            case .int8: return "ParaformerEncoder_int8.mlmodelc"
            case .fp16: return "ParaformerEncoder.mlmodelc"
            }
        }

        public var decoderBundle: String {
            switch self {
            case .int8: return "ParaformerDecoder_int8.mlmodelc"
            case .fp16: return "ParaformerDecoder.mlmodelc"
            }
        }
    }

    /// The precision the package ships.
    public static let shippedPrecision: Precision = .int8

    /// The fp32 CPU front end: kaldi fbank-80 → LFR (m = 7, n = 6 → 560-d)
    /// → CMVN as a Core ML graph, **the same graph as
    /// `SenseVoicePreprocessor.mlmodelc`** (`model.mil` and `weight.bin`
    /// digest-identical; only the metadata blobs naming the bundle differ),
    /// so everything measured for that graph holds:
    /// CPU only, 0.2–30 s of audio, one frame per 60 ms.
    public static let preprocessorBundle = "ParaformerPreprocessor.mlmodelc"
    /// The CIF predictor's conv1d + linear + sigmoid, `enc_out [1, T, 512]`
    /// → `alphas [1, T]`; the integrate-and-fire that follows is
    /// `ParaformerCIF` on the host, because it emits a dynamic token count
    /// a fixed-shape graph cannot express.
    public static let cifAlphasBundle = "ParaformerCifAlphas.mlmodelc"
    /// 8,404 CharTokenizer tokens as a JSON array: `<blank>`, `<s>`,
    /// `</s>`, then Chinese characters and English BPE pieces
    /// (`and@@`, `price`), `<unk>` last.
    public static let vocabularyFile = "vocab.json"

    public static let featureDim = 560
    public static let encoderDim = 512
    /// The encoder's and the CIF-alphas graph's enumerated sequence
    /// lengths (post-LFR frames); the host pads up to the smallest one
    /// ≥ the real length.
    public static let frameBuckets = [128, 256, 512, 1024, 1800]
    /// The decoder is a fixed-shape graph: `enc [1, 512, 512]` and
    /// `ac [1, 128, 512]`. 512 frames is 30.7 s of audio and 128 tokens
    /// is 128 characters; the chunker keeps every window far below both.
    public static let decoderEncoderFrames = 512
    public static let decoderMaxTokens = 128

    public static let blankTokenID = 0
    public static let sosTokenID = 1
    public static let eosTokenID = 2
    public static let unknownToken = "<unk>"
    /// FunASR's BPE continuation marker on an English piece (`comp@@` +
    /// `any` → `company`).
    public static let bpeContinuation = "@@"

    /// CifPredictorV2's threshold and the tail alpha appended after the
    /// last real frame so a partially integrated final character still
    /// fires.
    public static let cifThreshold: Float = 1.0
    public static let cifTailThreshold: Float = 0.45

    /// Kaldi feeds int16-range waveforms; the capture is [-1, 1].
    public static let waveformScale: Float = 32_768
    /// One LFR frame is six 10 ms fbank frames.
    public static let secondsPerFrame: Double = 0.06

    /// The preprocessor graph's `waveform` range (its `model.mil`
    /// `RangeDims`: 3,200–480,000 samples = 0.2–30 s).
    public static let minimumWaveformSamples = 3_200
    public static let maximumWaveformSamples = 480_000

    /// The window the chunker cuts a recording into. Upstream's own card
    /// recommends utterances under 20 s for this checkpoint; 15 s keeps a
    /// window at ≤ 250 frames (the 256 bucket, one fifth of the decoder's
    /// memory) and ≤ ~90 Mandarin characters (under the 128-token cap even
    /// for fast speech), and matches SenseVoice's measured window.
    public static let maxWindowSeconds: Double = 15

    public static func bucket(forFrames frames: Int) -> Int {
        frameBuckets.first { $0 >= frames } ?? maxFrames
    }

    public static var maxFrames: Int { frameBuckets.last ?? 1800 }
}

/// The host half of the CIF predictor (Continuous Integrate-and-Fire): a
/// port of FunASR's `cif` and of the library's own internal
/// `ParaformerCif.integrateAndFireWithFireFrames` (which is not public in
/// `0.15.7`, hence the port; the pinned source is the reference and the
/// arithmetic is line-for-line the same). Pure, so the firing rule is
/// unit-tested on tiny vectors.
///
/// Each frame's alpha is added to a running integral; while it stays under
/// the threshold the frame's encoder row is accumulated (weighted by its
/// alpha) into the pending token, and when it crosses, only the portion of
/// the alpha needed to reach the threshold is used, the token fires, and the
/// leftover seeds the next token. A tail frame (alpha 0.45, zero row) is
/// appended so a partially integrated last character still fires.
public enum ParaformerCIF {
    public struct Result: Equatable, Sendable {
        /// The acoustic embeddings `[L][D]` the decoder takes.
        public let embeddings: [[Float]]
        /// The frame index (0…T, T being the tail) each token fired on —
        /// FunASR's `pre_peak_index`, the source of the token spans.
        public let fireFrames: [Int]

        public init(embeddings: [[Float]], fireFrames: [Int]) {
            self.embeddings = embeddings
            self.fireFrames = fireFrames
        }
    }

    /// - Parameters:
    ///   - encoderRows: encoder output rows `[T][D]`, real frames only.
    ///   - alphas: the CIF-alphas graph's per-frame weights `[T]`.
    public static func integrateAndFire(encoderRows: [[Float]], alphas: [Float]) -> Result {
        let frames = min(encoderRows.count, alphas.count)
        let dimension = encoderRows.first?.count ?? ParaformerGraph.encoderDim
        let threshold = ParaformerGraph.cifThreshold
        var embeddings: [[Float]] = []
        var fireFrames: [Int] = []
        var integral: Float = 0
        var pending = [Float](repeating: 0, count: dimension)
        let zeroRow = [Float](repeating: 0, count: dimension)

        for frame in 0...frames {
            let alpha = frame < frames ? alphas[frame] : ParaformerGraph.cifTailThreshold
            let row = frame < frames ? encoderRows[frame] : zeroRow
            integral += alpha
            if integral < threshold {
                for index in 0..<dimension { pending[index] += alpha * row[index] }
            } else {
                let used = alpha - (integral - threshold)
                for index in 0..<dimension { pending[index] += used * row[index] }
                embeddings.append(pending)
                fireFrames.append(frame)
                integral -= threshold
                let leftover = alpha - used
                pending = row.map { $0 * leftover }
            }
        }
        return Result(embeddings: embeddings, fireFrames: fireFrames)
    }
}

/// Turns the decoder's per-token argmax ids into text. FunASR's
/// `sentence_postprocess`, restated: `<blank>`, `<s>`, `</s>` and `<unk>`
/// are dropped (the library's plain `decode` keeps a literal `<unk>`;
/// kvoice does not insert that into a document), an English BPE piece
/// ending in `@@` is glued to the pieces after it into one word, Chinese
/// characters are concatenated, and a space separates a Latin word from
/// its neighbours (`今天 hello 世界`). The one punctuation token in the
/// vocabulary (`.`) attaches to the word before it.
public enum ParaformerTextAssembler {
    /// One emitted word or character and the decoder positions it came
    /// from (a merged BPE word spans several), for the token spans.
    public struct Word: Equatable, Sendable {
        public let text: String
        public let firstPosition: Int
        public let lastPosition: Int

        public init(text: String, firstPosition: Int, lastPosition: Int) {
            self.text = text
            self.firstPosition = firstPosition
            self.lastPosition = lastPosition
        }
    }

    public static func words(_ ids: [Int], vocabulary: [Int: String]) -> [Word] {
        var words: [Word] = []
        var pendingText = ""
        var pendingFirst = 0
        for (position, id) in ids.enumerated() {
            guard id != ParaformerGraph.blankTokenID, id != ParaformerGraph.sosTokenID, id != ParaformerGraph.eosTokenID,
                  let token = vocabulary[id], !token.isEmpty, token != ParaformerGraph.unknownToken else { continue }
            if pendingText.isEmpty { pendingFirst = position }
            if token.hasSuffix(ParaformerGraph.bpeContinuation) {
                pendingText += token.dropLast(ParaformerGraph.bpeContinuation.count)
                continue
            }
            pendingText += token
            words.append(Word(text: pendingText, firstPosition: pendingFirst, lastPosition: position))
            pendingText = ""
        }
        // A `@@` piece with nothing after it (the decoder's token budget
        // ran out mid-word): emit what there is rather than lose it.
        if !pendingText.isEmpty {
            words.append(Word(text: pendingText, firstPosition: pendingFirst, lastPosition: ids.count - 1))
        }
        return words
    }

    /// The transcript for a token sequence.
    public static func text(_ ids: [Int], vocabulary: [Int: String]) -> String {
        join(words(ids, vocabulary: vocabulary).map(\.text))
    }

    /// `SenseVoiceTranscriptJoiner`'s rule (no space between CJK, a space
    /// around Latin words) with punctuation glued to the word before it.
    static func join(_ parts: [String]) -> String {
        var result = ""
        for part in parts where !part.isEmpty {
            if let last = result.unicodeScalars.last, let first = part.unicodeScalars.first,
               !(SenseVoiceTranscriptJoiner.isCJK(last) && SenseVoiceTranscriptJoiner.isCJK(first)),
               !Self.isPunctuation(first) {
                result += " "
            }
            result += part
        }
        return result
    }

    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .otherPunctuation, .closePunctuation, .finalPunctuation, .dashPunctuation, .connectorPunctuation:
            return true
        default:
            return false
        }
    }
}
