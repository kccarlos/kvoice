import XCTest
@testable import KvoiceTranscription

/// ADR-017: the LocalAgreement-2 session commits only what two consecutive
/// passes agree on, cuts the audio window at the committed boundary, forces a
/// cut when the window outgrows the policy, and joins CJK text without spaces.
/// The silence gate (`SpeechGate`, shared with the batch pass) keeps a silent
/// window away from the runtime and drops hallucinated segments over quiet
/// audio.
final class WhisperStreamingSessionTests: XCTestCase {
    private let rate = Int(WhisperStreamingPolicy.sampleRate)

    func testPassIsNotDueBeforeOneSecondOfNewAudioAndNotWhileOneIsRunning() {
        var session = WhisperStreamingSession()
        XCTAssertFalse(session.isPassDue)
        session.append(speech(seconds: 0.5))
        XCTAssertFalse(session.isPassDue)
        session.append(speech(seconds: 0.5))
        XCTAssertTrue(session.isPassDue)

        let window = session.beginPass()
        XCTAssertEqual(window?.count, rate)
        XCTAssertFalse(session.isPassDue, "a pass is in flight")
        session.append(speech(seconds: 2))
        XCTAssertFalse(session.isPassDue, "still in flight")
        session.abandonPass()
        XCTAssertTrue(session.isPassDue, "abandoned audio is still new")
        XCTAssertEqual(session.beginPass()?.count, 3 * rate, "the next pass covers everything")
    }

    func testTwoAgreeingPassesCommitThePrefixAndCutTheWindow() {
        var session = WhisperStreamingSession()
        session.append(speech(seconds: 2))
        let first = session.beginPass()!
        let partial1 = session.apply(
            result(segments: [(0, 1, "hello"), (1, 2, "wor")]),
            windowSampleCount: first.count
        )
        XCTAssertEqual(partial1, "hello wor")
        XCTAssertEqual(session.committedText, "")
        XCTAssertEqual(session.tentativeText, "hello wor")
        XCTAssertEqual(session.windowSeconds, 2, accuracy: 0.001, "first pass commits nothing")

        session.append(speech(seconds: 1))
        let second = session.beginPass()!
        XCTAssertEqual(second.count, 3 * rate)
        let partial2 = session.apply(
            result(segments: [(0, 1, "hello"), (1, 2.5, "world again")]),
            windowSampleCount: second.count
        )
        XCTAssertEqual(session.committedText, "hello")
        XCTAssertEqual(session.tentativeText, "world again")
        XCTAssertEqual(partial2, "hello world again")
        XCTAssertEqual(session.windowSeconds, 2, accuracy: 0.001, "cut at the committed segment's end")
        XCTAssertEqual(session.windowStartSeconds, 1, accuracy: 0.001)

        // The window changed, so agreement starts over: one more pass alone
        // commits nothing even though it repeats the tentative text.
        session.append(speech(seconds: 1))
        let third = session.beginPass()!
        _ = session.apply(result(segments: [(0, 1.5, "world again")]), windowSampleCount: third.count)
        XCTAssertEqual(session.committedText, "hello")
        session.append(speech(seconds: 1))
        let fourth = session.beginPass()!
        _ = session.apply(result(segments: [(0, 1.5, "world again"), (1.5, 2, "ok")]), windowSampleCount: fourth.count)
        XCTAssertEqual(session.committedText, "hello world again")
        XCTAssertEqual(session.tentativeText, "ok")
    }

    func testDisagreementCommitsNothing() {
        var session = WhisperStreamingSession()
        session.append(speech(seconds: 2))
        let first = session.beginPass()!
        _ = session.apply(result(segments: [(0, 1, "hello")]), windowSampleCount: first.count)
        session.append(speech(seconds: 1))
        let second = session.beginPass()!
        let partial = session.apply(result(segments: [(0, 1, "yellow"), (1, 2, "hello")]), windowSampleCount: second.count)
        XCTAssertEqual(session.committedText, "")
        XCTAssertEqual(partial, "yellow hello")
        XCTAssertEqual(session.windowSeconds, 3, accuracy: 0.001)
    }

    func testCJKAwareJoining() {
        XCTAssertEqual(WhisperStreamingSession.join("你好", "世界"), "你好世界")
        XCTAssertEqual(WhisperStreamingSession.join("hello", "world"), "hello world")
        XCTAssertEqual(WhisperStreamingSession.join("你好", "，再见"), "你好，再见")
        XCTAssertEqual(WhisperStreamingSession.join("hello", "你好"), "hello 你好")
        XCTAssertEqual(WhisperStreamingSession.join("", "x"), "x")
        XCTAssertEqual(WhisperStreamingSession.join("x", ""), "x")
        XCTAssertEqual(WhisperStreamingSession.normalise("  a \n b  "), "a b")
        XCTAssertNil(WhisperStreamingSession.normalise(" \n"))
    }

    func testForcedCutAtMaximumWindowCommitsAllButTheLastSegment() {
        var session = WhisperStreamingSession(policy: WhisperStreamingPolicy(maximumWindowSeconds: 5))
        session.append(speech(seconds: 6))
        let window = session.beginPass()!
        let partial = session.apply(
            result(segments: [(0, 2, "one"), (2, 4, "two"), (4, 5.5, "three")]),
            windowSampleCount: window.count
        )
        XCTAssertEqual(session.committedText, "one two")
        XCTAssertEqual(session.tentativeText, "three")
        XCTAssertEqual(partial, "one two three")
        XCTAssertEqual(session.windowSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(session.windowStartSeconds, 4, accuracy: 0.001)
    }

    func testForcedCutWithOneSegmentPrefersASilenceWhenVADIsOn() {
        var session = WhisperStreamingSession(policy: WhisperStreamingPolicy(maximumWindowSeconds: 5))
        var audio = tone(seconds: 3)
        audio.append(contentsOf: silence(seconds: 0.5))
        audio.append(contentsOf: tone(seconds: 2.5))
        session.append(audio)
        let window = session.beginPass()!
        _ = session.apply(result(segments: [(0, 6, "all of it")]), windowSampleCount: window.count)
        XCTAssertEqual(session.committedText, "all of it")
        XCTAssertEqual(session.tentativeText, "")
        XCTAssertEqual(session.windowStartSeconds, 3.25, accuracy: 0.11, "cut at the silence centre")
    }

    func testForcedCutWithOneSegmentFallsBackNearTheEndWhenVADIsOff() {
        var session = WhisperStreamingSession(
            policy: WhisperStreamingPolicy(maximumWindowSeconds: 5, voiceActivityDetectionEnabled: false)
        )
        var audio = tone(seconds: 3)
        audio.append(contentsOf: silence(seconds: 0.5))
        audio.append(contentsOf: tone(seconds: 2.5))
        session.append(audio)
        let window = session.beginPass()!
        _ = session.apply(result(segments: [(0, 6, "all of it")]), windowSampleCount: window.count)
        XCTAssertEqual(session.windowStartSeconds, 4, accuracy: 0.001, "two seconds before the end of the pass")
    }

    func testEnergyVADFindsTheLastQualifyingSilence() {
        let policy = WhisperStreamingPolicy()
        var audio = tone(seconds: 1)
        audio.append(contentsOf: silence(seconds: 0.4))
        audio.append(contentsOf: tone(seconds: 1))
        audio.append(contentsOf: silence(seconds: 0.1)) // too short to count
        audio.append(contentsOf: tone(seconds: 0.5))
        let center = EnergyVoiceActivity.lastSilenceCenter(
            in: audio, seenSeconds: 3, notBefore: 0, policy: policy
        )
        XCTAssertEqual(try XCTUnwrap(center), 1.2, accuracy: 0.11)
        XCTAssertNil(EnergyVoiceActivity.lastSilenceCenter(in: audio, seenSeconds: 3, notBefore: 2, policy: policy))
        XCTAssertNil(EnergyVoiceActivity.lastSilenceCenter(in: tone(seconds: 2), seenSeconds: 2, notBefore: 0, policy: policy))
    }

    // MARK: Silence gate (shared with the batch pass)

    func testSilentWindowIsNotDecodedAndDoesNotAccumulate() {
        var session = WhisperStreamingSession()
        session.append(silence(seconds: 2))
        XCTAssertTrue(session.isPassDue, "the timing rule alone would run a pass")
        XCTAssertNil(session.beginPass(), "a silent window never reaches the runtime")
        XCTAssertEqual(session.passCount, 0)
        XCTAssertEqual(session.skippedSilentPassCount, 1)
        XCTAssertEqual(session.partialText, "")
        XCTAssertFalse(session.isPassDue, "the silent audio counts as consumed")
        XCTAssertEqual(session.windowSeconds, 1, accuracy: 0.001, "trimmed to one second of context")
        XCTAssertEqual(session.windowStartSeconds, 1, accuracy: 0.001)

        // Speech after the silence is decoded with the kept context in front.
        session.append(speech(seconds: 1))
        let window = session.beginPass()
        XCTAssertEqual(window?.count, 2 * rate)
        XCTAssertEqual(session.passCount, 1)
    }

    func testHallucinatedSegmentOverQuietAudioIsDropped() {
        var session = WhisperStreamingSession()
        session.append(quiet(seconds: 2)) // above the silence floor, below the quiet threshold
        let window = session.beginPass()!
        let partial = session.apply(result(segments: [(0, 1.5, "Thank you.")]), windowSampleCount: window.count)
        XCTAssertEqual(partial, "", "a silence hallucination is never shown as tentative text")
        XCTAssertEqual(session.tentativeText, "")

        // Nor can two agreeing passes commit it.
        session.append(quiet(seconds: 1))
        let second = session.beginPass()!
        _ = session.apply(result(segments: [(0, 1.5, "Thank you.")]), windowSampleCount: second.count)
        XCTAssertEqual(session.committedText, "")
        XCTAssertEqual(session.partialText, "")

        // Real words over the same quiet audio still pass through.
        session.append(quiet(seconds: 1))
        let third = session.beginPass()!
        let words = session.apply(
            result(segments: [(0, 1, "Thank you."), (1, 3, "the meeting notes are ready")]),
            windowSampleCount: third.count
        )
        XCTAssertEqual(words, "the meeting notes are ready")
    }

    func testThankYouOverLoudAudioIsKept() {
        var session = WhisperStreamingSession()
        session.append(speech(seconds: 2))
        let window = session.beginPass()!
        let partial = session.apply(result(segments: [(0, 1.5, "Thank you.")]), windowSampleCount: window.count)
        XCTAssertEqual(partial, "Thank you.", "a spoken thank-you into a live microphone is never dropped")
    }

    /// The held-key tail: a loud window whose last segment sits on quiet
    /// audio. The whole-window peak is speech level, so only a per-segment
    /// check can tell the hallucinated tail from a spoken "thank you".
    func testThankYouOverTheQuietTailOfALoudWindowIsDroppedPerSegment() {
        var session = WhisperStreamingSession()
        session.append(speech(seconds: 2) + quiet(seconds: 2))
        let window = session.beginPass()!
        let partial = session.apply(
            result(segments: [(0, 2, "hello there"), (2, 4, "Thank you.")]),
            windowSampleCount: window.count
        )
        XCTAssertEqual(partial, "hello there")
        XCTAssertEqual(session.droppedHallucinationSegmentCount, 1)

        // The same segment over audible audio is kept.
        var loud = WhisperStreamingSession()
        loud.append(speech(seconds: 4))
        let loudWindow = loud.beginPass()!
        XCTAssertEqual(
            loud.apply(result(segments: [(0, 2, "hello there"), (2, 4, "Thank you.")]), windowSampleCount: loudWindow.count),
            "hello there Thank you."
        )
        XCTAssertEqual(loud.droppedHallucinationSegmentCount, 0)

        // A segment without usable timestamps falls back to the pass peak:
        // over a loud window it is kept, exactly as before.
        var untimed = WhisperStreamingSession()
        untimed.append(speech(seconds: 2) + quiet(seconds: 2))
        let untimedWindow = untimed.beginPass()!
        XCTAssertEqual(
            untimed.apply(result(segments: [(0, 0, "Thank you.")]), windowSampleCount: untimedWindow.count),
            "Thank you."
        )
    }

    // MARK: Helpers

    /// All-zero samples: below `SpeechGate.silencePeakThresholdDBFS`.
    private func silence(seconds: Double) -> ContiguousArray<Float> {
        ContiguousArray(repeating: 0, count: Int(seconds * Double(rate)))
    }

    /// A -40 dBFS tone: audible to the gate but within the quiet band where
    /// `SpeechGate` consults its hallucination list.
    private func quiet(seconds: Double) -> ContiguousArray<Float> {
        tone(seconds: seconds, amplitude: 0.01)
    }

    /// Speech-level filler (about -10 dBFS) for tests about pass timing and
    /// agreement, which are not about the gate.
    private func speech(seconds: Double) -> ContiguousArray<Float> {
        tone(seconds: seconds)
    }

    private func tone(seconds: Double, amplitude: Float = 0.3) -> ContiguousArray<Float> {
        ContiguousArray((0..<Int(seconds * Double(rate))).map { index in
            Float(sin(Double(index) / Double(rate) * 2 * .pi * 220)) * amplitude
        })
    }

    private func result(segments: [(Double, Double, String)]) -> WhisperRuntimeResult {
        WhisperRuntimeResult(
            text: segments.map(\.2).joined(separator: " "),
            detectedLanguage: "en",
            segments: segments.map { WhisperRuntimeSegment(start: .seconds($0.0), end: .seconds($0.1), text: $0.2) },
            runtimeReportedRealTimeFactor: nil
        )
    }
}
