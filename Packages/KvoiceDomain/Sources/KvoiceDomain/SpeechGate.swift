import Foundation

/// Keeps silence and near-silence away from the model and rejects the
/// model's well-known silence hallucinations when the audio was quiet.
///
/// Whisper (large-v3 included) emits "Thank you.", "Thanks for watching.",
/// and a short list of similar phrases when it is handed empty or near-empty
/// audio; this is a property of the model, not a bug kvoice can fix in the
/// decoder. Both transcription paths gate it with these rules:
/// `DictationController.finalizeRecording` for the batch pass, and
/// `WhisperStreamingSession` for every ADR-017 streaming pass. The gate lives
/// in the domain so neither package depends on the other for it.
///
/// Peak level is the only energy figure the recording carries. Speech peaks
/// sit around -20…-6 dBFS; a quiet room's noise floor peaks well below
/// -45 dBFS. The phrase list is the set Whisper large-v3 is documented to
/// emit on empty or near-empty audio; it is only consulted when the recording
/// was quiet, so a user who really says "thank you" into a live microphone is
/// never dropped.
public enum SpeechGate {
    /// The energy thresholds the gate reads, as one value so a caller that
    /// was composed with `DeveloperDefaults` (ADR-022 slice 5) passes them
    /// through in one argument. Every function below takes
    /// `thresholds: Thresholds = .compiled`, and the `static let`s that
    /// follow are the compiled values — the `DeveloperDefaults` fields are
    /// the source, these mirror them so a caller with no defaults in hand
    /// (a test, a preview) still gets the shipped behaviour.
    public struct Thresholds: Sendable, Equatable {
        /// Below this peak the recording is silence (FR-AUD-008).
        public var silencePeakDBFS: Float
        /// At or below this peak a known hallucination phrase is dropped.
        public var quietPeakDBFS: Float
        /// A buffer at or below this carried no signal.
        public var signalPeakDBFS: Float
        /// Silence kept after the last audible frame when the tail is trimmed.
        public var trailingSilenceKeepSeconds: Double

        public init(
            silencePeakDBFS: Float = SpeechGate.silencePeakThresholdDBFS,
            quietPeakDBFS: Float = SpeechGate.quietPeakThresholdDBFS,
            signalPeakDBFS: Float = SpeechGate.signalPeakThresholdDBFS,
            trailingSilenceKeepSeconds: Double = SpeechGate.trailingSilenceKeepSeconds
        ) {
            self.silencePeakDBFS = silencePeakDBFS
            self.quietPeakDBFS = quietPeakDBFS
            self.signalPeakDBFS = signalPeakDBFS
            self.trailingSilenceKeepSeconds = trailingSilenceKeepSeconds
        }

        /// The shipped values (`DeveloperDefaults.compiled.speechGate`).
        public static let compiled = Thresholds()
    }

    /// Below this the recording is treated as silence (FR-AUD-008).
    public static let silencePeakThresholdDBFS: Float = -45
    /// Below this a transcript matching a known hallucination is discarded.
    public static let quietPeakThresholdDBFS: Float = -28
    /// Returned for audio with no energy at all (every sample zero).
    public static let silenceFloorDBFS: Float = -160
    /// A tap buffer whose peak is at or below this carried no signal: digital
    /// silence is reported at the meter's floor (-120 dBFS in the recorder,
    /// -160 here), and anything above it is a live microphone, however quiet
    /// the room (the quietest real opening measured on 2026-09-16 was
    /// -48.7 dBFS). Shared by the recorder, which drops the buffers before
    /// the first one above it (the zero-fill a Bluetooth route delivers
    /// while it switches), and the controller, which plays the start cue
    /// and stamps `captureStartMilliseconds` at that same buffer.
    public static let signalPeakThresholdDBFS: Float = -100

    static let hallucinationPhrases: [String] = [
        "thank you", "thanks", "thank you for watching", "thanks for watching",
        "thank you very much", "thank you so much", "you", "bye", "goodbye",
        "subtitles by", "subtitled by", "amara.org", "please subscribe",
        "like and subscribe", "see you next time", "see you in the next video",
        "the end", "music", "silence", "applause", "字幕", "謝謝", "谢谢",
        "谢谢观看", "謝謝觀看", "請訂閱", "请订阅", "ご視聴ありがとうございました"
    ]

    public static func isLikelyHallucination(
        _ text: String,
        peakLevelDBFS: Float,
        thresholds: Thresholds = .compiled
    ) -> Bool {
        guard peakLevelDBFS <= thresholds.quietPeakDBFS else { return false }
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
        guard !normalized.isEmpty else { return true }
        return hallucinationPhrases.contains { phrase in
            normalized == phrase || normalized.hasPrefix(phrase + ".") || normalized.hasPrefix(phrase + "!")
        }
    }

    /// Peak level of a run of Float32 samples in dBFS (0 dBFS = full scale).
    /// Non-finite samples are ignored rather than poisoning the peak. Used by
    /// the streaming session, whose window never passes through the recorder's
    /// meter; the batch path reads the recorder's own `peakLevelDBFS`.
    public static func peakLevelDBFS(of samples: some Sequence<Float>) -> Float {
        var peak: Float = 0
        for sample in samples where sample.isFinite {
            peak = max(peak, abs(sample))
        }
        guard peak > 0 else { return silenceFloorDBFS }
        return max(silenceFloorDBFS, 20 * log10(peak))
    }

    /// True when the samples never rise above the silence threshold.
    public static func isSilent(_ samples: some Sequence<Float>, thresholds: Thresholds = .compiled) -> Bool {
        peakLevelDBFS(of: samples) <= thresholds.silencePeakDBFS
    }

    // MARK: - Trailing silence (2026-09-13 "Thank you." tail)

    /// Frame length for the trailing-silence scan. 50 ms resolves a word
    /// boundary well enough and keeps the scan cheap on a ten-minute recording.
    public static let trailingSilenceFrameSeconds: Double = 0.05
    /// Silence kept after the last audible frame so a soft final consonant or
    /// a trailing breath of a real word is never cut off the model's input.
    public static let trailingSilenceKeepSeconds: Double = 0.4
    /// A recording shorter than this is never trimmed: Whisper needs some
    /// context and the gain is negligible.
    public static let trailingSilenceMinimumSeconds: Double = 1.0

    /// Number of leading samples to keep so that the trailing near-silence
    /// (frame peak at or below `silencePeakThresholdDBFS`) is removed apart
    /// from `trailingSilenceKeepSeconds`. Returns `samples.count` when there
    /// is nothing to trim or the recording is too short.
    ///
    /// Why this exists: the user often stops speaking but keeps the shortcut
    /// held for a second or two. The recording's overall peak is then loud,
    /// so the whole-recording gates above do not apply, and Whisper hands
    /// back its stock silence phrase ("Thank you.") for the empty tail. Not
    /// feeding it that tail is the cheapest fix; the segment check below is
    /// the second line.
    public static func trailingSilenceTrimmedCount(
        of samples: some RandomAccessCollection<Float>,
        sampleRate: Double = 16_000,
        thresholds: Thresholds = .compiled
    ) -> Int {
        let count = samples.count
        let minimum = Int(trailingSilenceMinimumSeconds * sampleRate)
        guard count > minimum else { return count }
        let frameLength = max(1, Int(trailingSilenceFrameSeconds * sampleRate))
        let threshold = pow(10, thresholds.silencePeakDBFS / 20)

        // Scan frames from the end; stop at the first frame that is audible.
        var audibleEnd = 0
        var frameEnd = count
        scan: while frameEnd > 0 {
            let frameStart = max(0, frameEnd - frameLength)
            let lower = samples.index(samples.startIndex, offsetBy: frameStart)
            let upper = samples.index(samples.startIndex, offsetBy: frameEnd)
            for sample in samples[lower..<upper] where sample.isFinite && abs(sample) > threshold {
                audibleEnd = frameEnd
                break scan
            }
            frameEnd = frameStart
        }

        let keep = audibleEnd + Int(thresholds.trailingSilenceKeepSeconds * sampleRate)
        return min(count, max(minimum, keep))
    }

    /// The recording with its trailing near-silence removed, for the model's
    /// input only. `peakLevelDBFS` and `clippedFrameCount` are unchanged
    /// (the trimmed tail is by definition below the peak); `duration` is
    /// the trimmed length so the request describes the audio it carries.
    /// Callers keep the *original* recording for history and stored audio —
    /// the user's recording length is a fact about the recording, not about
    /// what the model was shown.
    public static func trimmingTrailingSilence(
        _ recording: AudioRecording,
        thresholds: Thresholds = .compiled
    ) -> AudioRecording {
        let keep = trailingSilenceTrimmedCount(
            of: recording.samples, sampleRate: recording.sampleRate, thresholds: thresholds
        )
        guard keep < recording.samples.count else { return recording }
        let seconds = Double(keep) / recording.sampleRate
        return AudioRecording(
            id: recording.id,
            samples: ContiguousArray(recording.samples.prefix(keep)),
            sampleRate: recording.sampleRate,
            channelCount: recording.channelCount,
            duration: .seconds(seconds),
            peakLevelDBFS: recording.peakLevelDBFS,
            clippedFrameCount: recording.clippedFrameCount
        )
    }

    /// Peak level of the audio a segment spans, in dBFS. The range is clamped
    /// to the samples: Whisper pads short audio to its 30 s window, so the
    /// last segment's `end` can run past the real audio (WhisperKit
    /// `SegmentSeeker`), and a segment that lies entirely in the padding is
    /// silence by construction.
    public static func peakLevelDBFS(
        of samples: some RandomAccessCollection<Float>,
        in segment: TranscriptSegment,
        sampleRate: Double = 16_000
    ) -> Float {
        let count = samples.count
        let start = min(count, max(0, Int(seconds(segment.start) * sampleRate)))
        let end = min(count, max(start, Int((seconds(segment.end) * sampleRate).rounded(.up))))
        guard end > start else { return silenceFloorDBFS }
        let lower = samples.index(samples.startIndex, offsetBy: start)
        let upper = samples.index(samples.startIndex, offsetBy: end)
        return peakLevelDBFS(of: samples[lower..<upper])
    }

    /// The result of `strippingTrailingHallucinations`.
    public struct TrailingHallucinationStrip: Sendable, Equatable {
        /// The transcript with the dropped segments' text removed from its end.
        public let text: String
        public let segments: [TranscriptSegment]
        /// How many trailing segments were dropped; a scalar fit for diagnostics.
        public let droppedSegmentCount: Int
    }

    /// Drops trailing segments whose text is a known silence hallucination
    /// *and* whose own audio peaks at or below `quietPeakThresholdDBFS`,
    /// repeating while the new last segment also qualifies. Energy-conditioned
    /// on purpose: a spoken "thank you" sits on audible audio and is kept, so
    /// this is never a blind word filter. `samples` must be the audio the
    /// model was given (segment timestamps are relative to it).
    ///
    /// The kept text is `text` with each dropped segment's text removed from
    /// the end, so the surviving transcript keeps the model's own spacing and
    /// punctuation; if the segment texts do not line up with `text` (a
    /// runtime that joins them differently), the kept segments are joined
    /// with single spaces instead. Nothing is dropped when there are no
    /// timestamps to check against.
    public static func strippingTrailingHallucinations(
        text: String,
        segments: [TranscriptSegment],
        samples: some RandomAccessCollection<Float>,
        sampleRate: Double = 16_000,
        thresholds: Thresholds = .compiled
    ) -> TrailingHallucinationStrip {
        var kept = segments
        var dropped: [TranscriptSegment] = []
        while let last = kept.last {
            let peak = peakLevelDBFS(of: samples, in: last, sampleRate: sampleRate)
            guard isLikelyHallucination(last.text, peakLevelDBFS: peak, thresholds: thresholds) else { break }
            dropped.append(kept.removeLast())
        }
        guard !dropped.isEmpty else {
            return TrailingHallucinationStrip(text: text, segments: segments, droppedSegmentCount: 0)
        }

        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var suffixMatched = true
        for segment in dropped {
            let piece = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            guard remaining.hasSuffix(piece) else {
                suffixMatched = false
                break
            }
            remaining.removeLast(piece.count)
            remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !suffixMatched {
            remaining = kept
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return TrailingHallucinationStrip(
            text: remaining,
            segments: kept,
            droppedSegmentCount: dropped.count
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
