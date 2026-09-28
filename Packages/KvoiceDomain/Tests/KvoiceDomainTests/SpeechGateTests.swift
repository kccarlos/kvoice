import XCTest
@testable import KvoiceDomain

/// `SpeechGate` is shared by the batch pass (`DictationController`) and the
/// streaming session, so its rules are pinned here at the domain seam.
final class SpeechGateTests: XCTestCase {
    func testPhraseMatchingIsBoundedToQuietAudio() {
        XCTAssertTrue(SpeechGate.isLikelyHallucination("Thank you.", peakLevelDBFS: -35))
        XCTAssertTrue(SpeechGate.isLikelyHallucination("  thanks for watching!  ", peakLevelDBFS: -35))
        XCTAssertTrue(SpeechGate.isLikelyHallucination("谢谢观看", peakLevelDBFS: -35))
        XCTAssertTrue(SpeechGate.isLikelyHallucination("...", peakLevelDBFS: -35), "punctuation alone is nothing")
        XCTAssertFalse(SpeechGate.isLikelyHallucination("Thank you.", peakLevelDBFS: -12))
        XCTAssertFalse(SpeechGate.isLikelyHallucination("Thank you for the meeting notes", peakLevelDBFS: -35))
    }

    func testPeakLevelIsMeasuredInDBFSAndSilenceIsBelowTheThreshold() {
        XCTAssertEqual(SpeechGate.peakLevelDBFS(of: [Float]()), SpeechGate.silenceFloorDBFS)
        XCTAssertEqual(SpeechGate.peakLevelDBFS(of: [0, 0, 0]), SpeechGate.silenceFloorDBFS)
        XCTAssertEqual(SpeechGate.peakLevelDBFS(of: [0.1, -1, 0.2]), 0, accuracy: 0.001, "full scale")
        XCTAssertEqual(SpeechGate.peakLevelDBFS(of: [0.01, -0.001]), -40, accuracy: 0.001)
        XCTAssertEqual(SpeechGate.peakLevelDBFS(of: [.nan, .infinity, 0.5]), -6.02, accuracy: 0.01, "non-finite samples are ignored")

        XCTAssertTrue(SpeechGate.isSilent(ContiguousArray(repeating: 0.001, count: 16_000)), "-60 dBFS is silence")
        XCTAssertFalse(SpeechGate.isSilent([0.01]), "-40 dBFS is quiet, not silent")
        XCTAssertLessThan(SpeechGate.silencePeakThresholdDBFS, SpeechGate.quietPeakThresholdDBFS)
    }

    // MARK: Trailing silence trim (the held-key "Thank you." tail)

    func testTrailingSilenceTrimKeepsATailAndNeverGoesBelowTheMinimum() {
        // Two seconds of speech followed by two seconds of a quiet room.
        let recording = AudioRecording(
            samples: speech(seconds: 2) + roomNoise(seconds: 2),
            duration: .seconds(4),
            peakLevelDBFS: -10,
            clippedFrameCount: 0
        )
        let trimmed = SpeechGate.trimmingTrailingSilence(recording)
        XCTAssertEqual(trimmed.samples.count, Int(2.4 * 16_000), accuracy: 800,
                       "the tail is cut back to about 0.4 s after the last audible frame")
        XCTAssertEqual(trimmed.duration, .seconds(Double(trimmed.samples.count) / 16_000))
        XCTAssertEqual(trimmed.peakLevelDBFS, -10, "the peak is a fact about the recording, not the tail")
        XCTAssertEqual(trimmed.id, recording.id)
        XCTAssertEqual(recording.samples.count, 4 * 16_000, "the original is untouched")

        // Nothing to trim: an unchanged recording comes back as-is.
        let loud = AudioRecording(samples: speech(seconds: 3), duration: .seconds(3), peakLevelDBFS: -10, clippedFrameCount: 0)
        XCTAssertEqual(SpeechGate.trimmingTrailingSilence(loud), loud)

        // A short word followed by silence keeps at least one second.
        let short = speech(seconds: 0.3) + roomNoise(seconds: 1.5)
        XCTAssertEqual(SpeechGate.trailingSilenceTrimmedCount(of: short), 16_000, "never below 1 s")
        XCTAssertEqual(SpeechGate.trailingSilenceTrimmedCount(of: speech(seconds: 0.5)), 8_000, "too short to trim at all")

        // Silence quieter than the floor but not zero is still trimmed;
        // non-finite samples never count as audible.
        var odd = speech(seconds: 2) + roomNoise(seconds: 2)
        odd[odd.count - 1] = .nan
        XCTAssertLessThan(SpeechGate.trailingSilenceTrimmedCount(of: odd), 3 * 16_000)
    }

    func testTrailingQuietHallucinationSegmentIsDroppedAndALoudOneIsKept() {
        // "hello" over speech, then "Thank you." over the quiet tail.
        let samples = speech(seconds: 2) + quiet(seconds: 2)
        let segments = [
            TranscriptSegment(start: .zero, end: .seconds(2), text: " Hello there."),
            TranscriptSegment(start: .seconds(2), end: .seconds(4), text: " Thank you.")
        ]
        let quietTail = SpeechGate.strippingTrailingHallucinations(
            text: " Hello there. Thank you.", segments: segments, samples: samples
        )
        XCTAssertEqual(quietTail.text, "Hello there.")
        XCTAssertEqual(quietTail.segments, Array(segments.prefix(1)))
        XCTAssertEqual(quietTail.droppedSegmentCount, 1)

        // Segment `end` past the real audio (Whisper's 30 s padding) is clamped;
        // a segment wholly in the padding is silence and is dropped.
        let padded = [
            TranscriptSegment(start: .zero, end: .seconds(2), text: " Hello there."),
            TranscriptSegment(start: .seconds(4), end: .seconds(30), text: " Thank you.")
        ]
        let overrun = SpeechGate.strippingTrailingHallucinations(
            text: " Hello there. Thank you.", segments: padded, samples: samples
        )
        XCTAssertEqual(overrun.text, "Hello there.")
        XCTAssertEqual(overrun.droppedSegmentCount, 1)

        // The same words over audible audio are speech and stay.
        let spoken = SpeechGate.strippingTrailingHallucinations(
            text: " Hello there. Thank you.", segments: segments, samples: speech(seconds: 4)
        )
        XCTAssertEqual(spoken.text, " Hello there. Thank you.", "untouched text when nothing is dropped")
        XCTAssertEqual(spoken.droppedSegmentCount, 0)

        // A quiet last segment that is real words is not a hallucination.
        let words = [
            TranscriptSegment(start: .zero, end: .seconds(2), text: " Hello there."),
            TranscriptSegment(start: .seconds(2), end: .seconds(4), text: " the notes are ready")
        ]
        XCTAssertEqual(
            SpeechGate.strippingTrailingHallucinations(text: "x", segments: words, samples: samples).droppedSegmentCount,
            0
        )

        // No timestamps, no segments: nothing to check, nothing dropped.
        XCTAssertEqual(
            SpeechGate.strippingTrailingHallucinations(text: "Thank you.", segments: [], samples: quiet(seconds: 2)).text,
            "Thank you."
        )
    }

    /// `WhisperTranscriptionEngine.ShortClipPadding` pads a batch clip at or
    /// under WhisperKit's `windowClipTime` (1.0 s) with trailing zeros up to
    /// 1.5 s (24,000 samples at 16 kHz) so the encoder is reached at all. If
    /// the model hallucinates a closing phrase over that padded (silent)
    /// region, the existing energy-conditioned drop must still catch it —
    /// the same mechanism already covers WhisperKit's own 30 s window
    /// padding above.
    func testHallucinationOverAShortClipsPaddedTailIsDropped() {
        let spokenSampleCount = Int(0.6 * 16_000)
        let paddedSampleCount = Int(1.5 * 16_000)
        let samples = speech(seconds: 0.6) + ContiguousArray<Float>(
            repeating: 0, count: paddedSampleCount - spokenSampleCount
        )
        let segments = [
            TranscriptSegment(start: .zero, end: .seconds(0.6), text: " Yes."),
            TranscriptSegment(start: .seconds(0.6), end: .seconds(1.5), text: " Thank you.")
        ]
        let stripped = SpeechGate.strippingTrailingHallucinations(
            text: " Yes. Thank you.", segments: segments, samples: samples
        )
        XCTAssertEqual(stripped.text, "Yes.")
        XCTAssertEqual(stripped.segments, Array(segments.prefix(1)))
        XCTAssertEqual(stripped.droppedSegmentCount, 1)
    }

    func testTwoTrailingQuietPhrasesAreBothDroppedAndTextIsRebuiltIfSuffixesDoNotMatch() {
        let samples = speech(seconds: 2) + quiet(seconds: 3)
        let segments = [
            TranscriptSegment(start: .zero, end: .seconds(2), text: " Meeting at noon."),
            TranscriptSegment(start: .seconds(2), end: .seconds(3.5), text: " Thank you."),
            TranscriptSegment(start: .seconds(3.5), end: .seconds(5), text: " Bye.")
        ]
        let strip = SpeechGate.strippingTrailingHallucinations(
            text: "Meeting at noon. Thank you. Bye.", segments: segments, samples: samples
        )
        XCTAssertEqual(strip.text, "Meeting at noon.")
        XCTAssertEqual(strip.droppedSegmentCount, 2)
        XCTAssertEqual(strip.segments.count, 1)

        // Runtime text that does not end with the segment texts: fall back to
        // joining the kept segments rather than guessing at the suffix.
        let rebuilt = SpeechGate.strippingTrailingHallucinations(
            text: "Meeting at noon, thank you, bye", segments: segments, samples: samples
        )
        XCTAssertEqual(rebuilt.text, "Meeting at noon.")
        XCTAssertEqual(rebuilt.droppedSegmentCount, 2)

        // Everything hallucinated over quiet audio leaves an empty transcript,
        // which the caller treats as no speech.
        let all = SpeechGate.strippingTrailingHallucinations(
            text: "Thank you. Bye.", segments: Array(segments.dropFirst()), samples: quiet(seconds: 5)
        )
        XCTAssertEqual(all.text, "")
        XCTAssertEqual(all.droppedSegmentCount, 2)
    }

    // MARK: Helpers

    /// About -10 dBFS.
    private func speech(seconds: Double) -> ContiguousArray<Float> {
        tone(seconds: seconds, amplitude: 0.3)
    }

    /// About -40 dBFS: above the silence floor, inside the quiet band.
    private func quiet(seconds: Double) -> ContiguousArray<Float> {
        tone(seconds: seconds, amplitude: 0.01)
    }

    /// About -60 dBFS: a quiet room, below the silence threshold.
    private func roomNoise(seconds: Double) -> ContiguousArray<Float> {
        tone(seconds: seconds, amplitude: 0.001)
    }

    private func tone(seconds: Double, amplitude: Float) -> ContiguousArray<Float> {
        ContiguousArray((0..<Int(seconds * 16_000)).map { index in
            Float(sin(Double(index) / 16_000 * 2 * .pi * 220)) * amplitude
        })
    }
}
