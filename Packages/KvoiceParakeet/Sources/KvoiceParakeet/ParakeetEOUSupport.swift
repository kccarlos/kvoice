import Foundation
import KvoiceDomain

// The Parakeet Realtime EOU facts that need no Core ML and no FluidAudio:
// the graphs and the 320 ms tier's chunk geometry (read from the pinned
// `StreamingChunkSize.ms320` and the bundle's `model.mil` on 2026-09-16),
// how the batch pass pads its tail so the last chunk is decoded before the
// timings are read, how the manager's per-token millisecond timestamps
// become `ParakeetTokenSpan`s, and which literal special pieces never reach
// the transcript. Everything here is pure and unit-tested; the
// FluidAudio-facing pipeline in `FluidAudioParakeetRuntime.swift` only
// calls it.

/// The Parakeet Realtime EOU 120M graphs kvoice knows, at the one chunk
/// tier the package ships (`FluidInference/parakeet-realtime-eou-120m-coreml`,
/// folder `320ms/`).
public enum ParakeetEOUGraph {
    /// The cache-aware streaming FastConformer encoder (17 layers, fp16):
    /// `audio_signal [1, 128, 64]` mel frames plus the loopback state
    /// (`pre_cache [1, 128, 9]`, `cache_last_channel [17, 1, 70, 512]`,
    /// `cache_last_time [17, 1, 512, 8]`, `cache_last_channel_len [1]`) →
    /// `encoded_output [1, 512, 8]` and the new state. The graph the Runtime
    /// card plans; it runs in both modes.
    public static let encoderBundle = "streaming_encoder.mlmodelc"
    /// The 1-layer, 640-unit LSTM prediction network — one step per emitted
    /// token, state carried across chunks.
    public static let decoderBundle = "decoder.mlmodelc"
    /// The joint network: `encoder_step [1, 512, 1]` × `decoder_step
    /// [1, 640, 1]` → `token_id` over 1,027 classes (1,024 pieces, `<EOU>`,
    /// `<EOB>`, blank).
    public static let jointBundle = "joint_decision.mlmodelc"
    /// 1,026 SentencePiece pieces as a `{"<id>": "<piece>"}` dictionary:
    /// `<unk>` at 0, lowercase English pieces, `<EOU>` at 1024 and `<EOB>`
    /// at 1025; the blank (1026) is not in the file.
    public static let vocabularyFile = "vocab.json"
    /// Published beside the bundles but not part of the package: `0.15.7`'s
    /// manager computes the mel front end in Swift and never loads it.
    public static let preprocessorBundleNotDownloaded = "parakeet_eou_preprocessor.mlmodelc"

    /// The tier the package ships and the manager is built with. The
    /// library's default is 160 ms; the card measures 320 ms at 4.87 % WER
    /// against 8.29 % (LibriSpeech test-clean, Apple M2).
    public static let chunkTierMilliseconds = 320
    public static let sampleRate = 16_000
    /// Samples the encoder consumes per pass: 64 mel frames → `(64 − 1) ×
    /// 160` samples, i.e. 630 ms of audio per chunk — more than the tier
    /// name, because the chunk overlaps the previous one.
    public static let chunkSamples = 10_080
    /// Samples the buffer advances per pass: 32 mel frames × 160 = the 320
    /// ms of new audio each partial covers.
    public static let shiftSamples = 5_120
    /// Encoder output frames decoded per chunk (`valid_out_len`).
    public static let validOutputFrames = 4
    /// One decoded frame = `shiftSamples / validOutputFrames` samples = 80 ms.
    public static var secondsPerFrame: Double {
        Double(shiftSamples) / Double(validOutputFrames) / Double(sampleRate)
    }

    /// The joint's special token ids (`RnntDecoder` in the pinned source;
    /// the card: "EOU token: ID 1024").
    public static let endOfUtteranceTokenID = 1024
    public static let endOfBackchannelTokenID = 1025
    public static let blankTokenID = 1026

    /// The wall-clock silence after the first `<EOU>` before the manager
    /// confirms the utterance ended (`eouDebounceMs`); the library's
    /// default, kept as is. Only newly decoded words reset it.
    public static let endOfUtteranceDebounceMilliseconds = 1_280
}

/// The batch pass is the streaming manager run to completion over the
/// whole recording, and its `finish()` both pads the tail chunk and clears
/// the per-token timestamps. To read the timings, kvoice pads the tail
/// itself with exactly the zeros `finish()` would add, drains the buffer,
/// reads text + timings, then resets — so the decoded tail is identical.
public enum ParakeetEOUChunking {
    /// How many samples of the `appended` total are still buffered after
    /// the manager has consumed every full chunk: fewer than a chunk when
    /// the recording is shorter than one, otherwise what the last shift
    /// left behind (always at least `chunk − shift`, since chunks overlap).
    public static func bufferedSamples(afterAppending appended: Int) -> Int {
        let chunk = ParakeetEOUGraph.chunkSamples
        let shift = ParakeetEOUGraph.shiftSamples
        guard appended >= chunk else { return appended }
        let passes = (appended - chunk) / shift + 1
        return appended - passes * shift
    }

    /// The zeros to append so the buffered tail becomes exactly one chunk
    /// (the manager's own `finish()` padding), or 0 when nothing is
    /// buffered — a recording of no samples has no tail to decode.
    public static func tailPaddingSamples(afterAppending appended: Int) -> Int {
        let buffered = bufferedSamples(afterAppending: appended)
        guard buffered > 0 else { return 0 }
        return ParakeetEOUGraph.chunkSamples - buffered
    }
}

/// The manager's per-token output → spans and text.
public enum ParakeetEOUTokens {
    /// One span per token: the manager's millisecond timestamp (the encoder
    /// frame the token was emitted on × 80 ms) as the start, one frame
    /// later as the end. The piece text keeps SentencePiece's `▁` replaced
    /// by a space so a span reads as the word it starts. Lengths that
    /// disagree (never observed; the manager appends both arrays together)
    /// are truncated to the shorter, not padded.
    public static func spans(timestampsMilliseconds: [Int], pieces: [String]) -> [ParakeetTokenSpan] {
        zip(timestampsMilliseconds, pieces).map { milliseconds, piece in
            let start = Double(milliseconds) / 1_000
            return ParakeetTokenSpan(
                text: piece.replacingOccurrences(of: "\u{2581}", with: " "),
                start: start,
                end: start + ParakeetEOUGraph.secondsPerFrame
            )
        }
    }

    /// The literal special pieces the vocabulary can decode into text. The
    /// library's decoder stops at `<EOU>` (id 1024) and never appends it,
    /// but `<EOB>` (1025, NeMo's end-of-backchannel marker) and `<unk>` (0)
    /// would come through `Tokenizer.decode` as literal text; nothing in
    /// dictation wants either.
    public static let specialPieces: Set<String> = ["<EOU>", "<EOB>", "<unk>"]

    /// The manager's text with every special piece removed and the
    /// whitespace that leaves collapsed to single spaces, trimmed.
    public static func cleaned(_ text: String) -> String {
        var cleaned = text
        for piece in specialPieces {
            cleaned = cleaned.replacingOccurrences(of: piece, with: " ")
        }
        return cleaned.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
    }
}
