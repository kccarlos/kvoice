import Foundation
import KvoiceDomain

// The SenseVoice facts that need no Core ML: which encoder export a
// compute-unit choice loads, how the model's tag run is turned into text plus
// a language, how a long recording is cut for a fixed-length encoder, and how
// the pieces are joined back. Everything here is pure and unit-tested; the
// FluidAudio-facing pipeline in `FluidAudioParakeetRuntime.swift` only calls
// it.

/// The SenseVoice encoder exports kvoice knows and the query indices the
/// encoder takes beside the features.
public enum SenseVoiceEncoderGraph: String, Sendable, Equatable, CaseIterable {
    /// `SenseVoiceSmall_int8.mlmodelc`: int8 weights, fp16 activations —
    /// numerically correct on the Neural Engine only (NaN on the CPU/GPU
    /// fp16 path, like the fp16 export). Half the fp16 export's size and
    /// accuracy-neutral on the card's canonical sets. The package's
    /// Neural Engine graph.
    case int8NeuralEngine
    /// `SenseVoiceSmall_fp32.mlmodelc`: correct on every device, ~4× the
    /// int8 footprint. The package's graph for every non-ANE choice. Unlike
    /// the fp16/int8 exports it is **not** an enumerated-shape model — its
    /// `speech` input is fixed at `[1, 1800, 560]` (read from its
    /// `model.mil`, 2026-09-16), so every pass pads to the full 1,800
    /// frames whatever the audio length, and the library's own `--fp32`
    /// path, which pads to the smallest bucket, fails on this export with
    /// a shape mismatch under 0.15.7. `paddedFrames(for:)` carries the
    /// difference.
    case fp32
    /// `SenseVoiceSmall.mlmodelc`, the fp16 export. **Not in the package**
    /// (`ParakeetModelVariant.requiredArtifactRoots` never names it, so a
    /// package holding it fails verification): the same Neural-Engine-only
    /// limit as int8 at twice the size, no accuracy gain. Kept so the opt-in
    /// live matrix test can load it from a scratch folder and the choice
    /// stays re-measurable.
    case fp16NeuralEngine

    /// The compiled bundle name under `model/`.
    public var bundle: String {
        switch self {
        case .int8NeuralEngine: return "SenseVoiceSmall_int8.mlmodelc"
        case .fp32: return "SenseVoiceSmall_fp32.mlmodelc"
        case .fp16NeuralEngine: return "SenseVoiceSmall.mlmodelc"
        }
    }

    /// The fp32 CPU front end (kaldi fbank-80 → LFR m=7/n=6 → CMVN as a
    /// Core ML graph). Always loaded CPU-only: the power spectrum and log
    /// overflow fp16 and the framing convolutions do not compile for the
    /// Neural Engine (the card and the library agree).
    public static let preprocessorBundle = "SenseVoicePreprocessor.mlmodelc"

    /// The `textnorm` query index kvoice always sends: `withitn` (14) makes
    /// the model write punctuation and inverse text normalisation (digits,
    /// units); `woitn` (15, the library's default) writes neither. Measured
    /// on 2026-09-16 with the bundled sample — see the Changelog.
    public static let textNormWithITN: Int32 = 14

    /// The `language` query index for auto-detect.
    public static let autoDetectLanguage: Int32 = 0

    /// One LFR frame is six 10 ms fbank frames, so a CTC frame index is
    /// `index × 0.06 s` of audio (used for the token spans).
    public static let secondsPerFrame: Double = 0.06

    /// The query positions the encoder prepends to the CTC output (language,
    /// two event/emotion slots, text-norm); the transcript starts after them.
    public static let queryTokenCount = 4

    /// The fp16/int8 encoders' enumerated sequence lengths (post-LFR
    /// frames); the host pads features up to the smallest one ≥ the real
    /// length. The fp32 encoder takes only the last.
    public static let frameBuckets = [128, 256, 512, 1024, 1800]

    /// The padded frame count this graph is fed for `frames` real ones.
    public func paddedFrames(for frames: Int) -> Int {
        switch self {
        case .int8NeuralEngine, .fp16NeuralEngine: return Self.bucket(forFrames: frames)
        case .fp32: return Self.maxFrames
        }
    }

    /// The largest bucket, ≈108 s of audio. The preprocessor's own input
    /// range (below) is the tighter limit; this one is never reached.
    public static var maxFrames: Int { frameBuckets.last ?? 1800 }

    /// The preprocessor graph's `waveform` length range, read from Core ML's
    /// refusal on 2026-09-16 ("Size … of dimension (1) is not in allowed
    /// range (3200..480000)"): **0.2 s to 30 s** of 16 kHz audio. Anything
    /// longer must be cut first (`SenseVoiceAudioChunker`); anything shorter
    /// is zero-padded to the minimum. The library's manager has neither
    /// guard and throws on a 31 s clip.
    public static let minimumWaveformSamples = 3_200
    public static let maximumWaveformSamples = 480_000

    public static func bucket(forFrames frames: Int) -> Int {
        frameBuckets.first { $0 >= frames } ?? maxFrames
    }

    /// The CTC blank id (`<unk>`, 0).
    public static let blankTokenID = 0
}

/// Turns the detokenised CTC string — `<|zh|><|NEUTRAL|><|Speech|><|withitn|>
/// 今天天气很好。` — into the transcript and the language the model reported.
///
/// Every `<|…|>` tag is removed wherever it appears (event tags such as
/// `<|Laughter|>` can occur mid-utterance); the emotion and event tags are
/// dropped without being recorded anywhere (rule: they never reach the
/// transcript, history or diagnostics). Only the language tag is kept, as
/// a Whisper code.
public enum SenseVoiceTranscriptParser {
    public struct Result: Sendable, Equatable {
        public let text: String
        /// The Whisper code of the leading language tag, or nil for auto
        /// results without one, `<|nospeech|>`, and tags that are not a
        /// Whisper language.
        public let language: String?

        public init(text: String, language: String?) {
            self.text = text
            self.language = language
        }
    }

    private static let tagPattern: NSRegularExpression = {
        // A literal pattern; a failure here is a programming error, not a
        // run-time condition (and `/health` flags force-tries).
        guard let pattern = try? NSRegularExpression(pattern: "<\\|([^|<>]*)\\|>") else {
            preconditionFailure("the SenseVoice tag pattern must compile")
        }
        return pattern
    }()

    public static func parse(_ raw: String) -> Result {
        let nsRaw = raw as NSString
        let matches = tagPattern.matches(in: raw, range: NSRange(location: 0, length: nsRaw.length))
        var language: String?
        for match in matches {
            let name = nsRaw.substring(with: match.range(at: 1))
            if let code = languageCode(forTag: name) {
                language = code
                break
            }
            // A tag before the language tag is never a language.
            if name == "nospeech" { break }
        }
        let stripped = tagPattern.stringByReplacingMatches(
            in: raw, range: NSRange(location: 0, length: nsRaw.length), withTemplate: " "
        )
        return Result(text: collapseWhitespace(stripped), language: language)
    }

    /// The Whisper code a SenseVoice language tag names: an exact code
    /// (`zh`, `en`, `de`, …), or the first half of a bilingual tag
    /// (`zh/en` → `zh`). `nospeech`, the Chinese dialect tags (`minnan`,
    /// `wuyu`, `dialect`), the emotion and event tags map to nothing.
    public static func languageCode(forTag tag: String) -> String? {
        let candidate = tag.split(separator: "/", maxSplits: 1).first.map(String.init) ?? tag
        return whisperCodes.contains(candidate) ? candidate : nil
    }

    private static let whisperCodes = Set(TranscriptionLanguage.whisperLanguages.map(\.code))

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Cuts a recording into windows SenseVoice decodes well: at most
/// `maxSeconds` each, cut at the quietest 20 ms frame in the last
/// `searchSeconds` of a full window so a word is not split at an arbitrary
/// sample. Pure; the runtime transcribes each window and
/// `SenseVoiceTranscriptJoiner` joins the texts.
///
/// Why 15 s and not the preprocessor's 30 s ceiling: measured on
/// 2026-09-16 with a 140 s synthetic loop of one sentence, 30 s windows
/// lost a word or two in about half the repetitions ("Good morning send me
/// the quarterly report", "have2 customers"); 15 s windows returned 18 of
/// 20 verbatim. The model was trained on short utterances and its
/// published accuracy is on them. 15 s → 250 LFR frames, the 256 bucket.
public enum SenseVoiceAudioChunker {
    public static let defaultMaxSeconds: Double = 15
    public static let defaultSearchSeconds: Double = 5
    static let frameSeconds: Double = 0.02

    /// The samples the pipeline hands the preprocessor for one window, or
    /// nil for a window too short to hold one LFR frame (60 ms = 960
    /// samples: nothing to decode). A window under the preprocessor's
    /// 3,200-sample floor is zero-padded up to it.
    public static func prepared(_ window: [Float]) -> [Float]? {
        guard window.count >= minimumDecodableSamples else { return nil }
        guard window.count < SenseVoiceEncoderGraph.minimumWaveformSamples else { return window }
        return window + [Float](repeating: 0, count: SenseVoiceEncoderGraph.minimumWaveformSamples - window.count)
    }

    /// One LFR frame at 16 kHz.
    public static let minimumDecodableSamples = 960

    public static func windows(
        for samples: [Float],
        sampleRate: Int = 16_000,
        maxSeconds: Double = defaultMaxSeconds,
        searchSeconds: Double = defaultSearchSeconds
    ) -> [Range<Int>] {
        let maxSamples = max(1, Int(maxSeconds * Double(sampleRate)))
        let searchSamples = min(maxSamples, max(1, Int(searchSeconds * Double(sampleRate))))
        let frame = max(1, Int(frameSeconds * Double(sampleRate)))
        var windows: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxSamples {
            let searchStart = start + maxSamples - searchSamples
            let searchEnd = start + maxSamples
            var quietest = searchEnd - frame
            var quietestEnergy = Float.greatestFiniteMagnitude
            var cursor = searchStart
            while cursor + frame <= searchEnd {
                var energy: Float = 0
                for index in cursor..<(cursor + frame) {
                    energy += samples[index] * samples[index]
                }
                if energy < quietestEnergy {
                    quietestEnergy = energy
                    quietest = cursor
                }
                cursor += frame
            }
            // Cut in the middle of the quiet frame.
            let cut = quietest + frame / 2
            windows.append(start..<cut)
            start = cut
        }
        if start < samples.count || windows.isEmpty {
            windows.append(start..<samples.count)
        }
        return windows
    }
}

/// The host half of greedy CTC, kept pure: the per-frame argmax comes from
/// vDSP in the FluidAudio file, everything after it is here.
public enum SenseVoiceCTCDecoder {
    /// Drops the blank (`<unk>`, 0) and merges a token repeated on
    /// consecutive frames; a token that recurs after a blank is kept
    /// again (CTC's rule, and the source of the doubled-tail quirk). The
    /// frame is the index the token was first emitted on.
    public static func collapse(_ argmaxPerFrame: [Int]) -> [(frame: Int, id: Int)] {
        var ids: [(frame: Int, id: Int)] = []
        var previous = -1
        for (frame, id) in argmaxPerFrame.enumerated() {
            if id != SenseVoiceEncoderGraph.blankTokenID, id != previous {
                ids.append((frame, id))
            }
            previous = id
        }
        return ids
    }

    /// The vocabulary pieces joined (SentencePiece `▁` → space) — a mirror
    /// of the library's public `decodeCtcTokenIds`, which the runtime
    /// calls, so the tag path (ids → `<|zh|>…` → parser) is testable
    /// without FluidAudio. Three lines; if the library's changes, the
    /// pinned source is the reference.
    public static func detokenize(_ ids: [Int], vocabulary: [Int: String]) -> String {
        ids.compactMap { vocabulary[$0] }
            .joined()
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Joins per-window transcripts: a space between words, nothing between
/// two CJK ideographs or kana (Chinese and Japanese text carries no word
/// spaces; a window boundary must not insert one). Hangul is *not* CJK
/// here: Korean is space-delimited, so a cut between two Korean words
/// rejoins with a space.
public enum SenseVoiceTranscriptJoiner {
    public static func join(_ parts: [String]) -> String {
        var result = ""
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let last = result.unicodeScalars.last, let first = trimmed.unicodeScalars.first,
               !(isCJK(last) && isCJK(first)) {
                result += " "
            }
            result += trimmed
        }
        return result
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, // CJK punctuation
             0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0xFF00...0xFFEF: // Full-width forms
            return true
        default:
            return false
        }
    }
}
