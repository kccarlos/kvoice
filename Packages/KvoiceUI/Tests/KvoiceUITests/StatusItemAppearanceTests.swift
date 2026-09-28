import XCTest
@testable import KvoiceDomain
@testable import KvoiceUI

/// The menu-bar icon glows while recording and while a job is being processed.
/// The mapping is tested rather than the drawing: what matters here is that
/// equal states produce equal appearances, because the app shell diffs them at
/// 60 ms intervals to decide whether to restart the pulse animation.
final class StatusItemAppearanceTests: XCTestCase {
    private func appearance(_ state: DictationState) -> StatusItemAppearance {
        StatusItemAppearance(dictationState: state)
    }

    private let job = JobID()

    // MARK: Phases

    func testRecordingGlowsRed() {
        let recording = appearance(.recording(RecordingState(jobID: job)))
        XCTAssertEqual(recording.phase, .recording)
        XCTAssertEqual(recording.glow?.tint, .recording)
    }

    func testEveryProcessingStageGlows() {
        let stages: [DictationState] = [
            .finalizing(job),
            .transcribing(job),
            .processingAI(job, .polish),
            .inserting(job)
        ]
        for state in stages {
            let result = appearance(state)
            XCTAssertEqual(result.phase, .processing, "\(state.kind) should read as processing")
            XCTAssertEqual(result.glow?.tint, .processing, "\(state.kind) should glow")
        }
    }

    /// A glow left on after the job ended would read as "still busy".
    func testInertAndTerminalStatesDoNotGlow() {
        let states: [DictationState] = [
            .idle,
            .blocked(BlockReason(code: "micDenied", message: "Microphone denied")),
            .completed(job, CompletionSummary(insertion: .inserted(method: .selectedTextAttribute))),
            .failed(job, UserFacingFailure(code: "audioFailed", message: "Capture failed")),
            .terminating(job)
        ]
        for state in states {
            let result = appearance(state)
            XCTAssertEqual(result.phase, .idle, "\(state.kind) should not be a busy phase")
            XCTAssertNil(result.glow, "\(state.kind) must not glow")
        }
    }

    // MARK: Diffing

    /// The app shell applies an appearance only when it differs. If equality
    /// were wrong, the pulse would be torn down and rebuilt ~16 times a second
    /// and read as a flicker.
    func testSameStateProducesEqualAppearance() {
        let first = appearance(.transcribing(job))
        let second = appearance(.transcribing(job))
        XCTAssertEqual(first, second)
    }

    /// Two different jobs in the same stage must not count as a change either.
    func testAppearanceIgnoresJobIdentity() {
        XCTAssertEqual(appearance(.transcribing(JobID())), appearance(.transcribing(JobID())))
    }

    func testRecordingAndProcessingAreDistinguishable() {
        XCTAssertNotEqual(
            appearance(.recording(RecordingState(jobID: job))),
            appearance(.transcribing(job))
        )
    }

    // MARK: Animation values

    func testPulseValuesAreUsableForAnAnimation() {
        let glows = [StatusItemAppearance.recordingGlow, StatusItemAppearance.processingGlow]
        for glow in glows {
            XCTAssertGreaterThan(glow.pulsePeriod, 0, "a zero period would divide by zero")
            XCTAssertGreaterThan(glow.peakOpacity, glow.troughOpacity)
            XCTAssertLessThanOrEqual(glow.peakOpacity, 1)
            // Above zero so the glow breathes instead of blinking off entirely.
            XCTAssertGreaterThan(glow.troughOpacity, 0)
        }
    }

    /// Recording is the state the user is actively holding a key for, so it is
    /// the more urgent cue of the two.
    func testRecordingPulsesFasterAndBrighterThanProcessing() {
        let recording = StatusItemAppearance.recordingGlow
        let processing = StatusItemAppearance.processingGlow
        XCTAssertLessThan(recording.pulsePeriod, processing.pulsePeriod)
        XCTAssertGreaterThan(recording.peakOpacity, processing.peakOpacity)
    }

    // MARK: D.1 warning badge

    func testBlockedAndFailedCarryTheWarningBadgeWithoutGlowing() {
        let blocked = appearance(.blocked(BlockReason(code: "micDenied", message: "Microphone denied")))
        XCTAssertEqual(blocked.badge, .warning)
        XCTAssertNil(blocked.glow)
        let failed = appearance(.failed(job, UserFacingFailure(code: "audioFailed", message: "Capture failed")))
        XCTAssertEqual(failed.badge, .warning)
    }

    func testStandingAttentionBadgesIdleOnly() {
        XCTAssertEqual(StatusItemAppearance(dictationState: .idle, needsAttention: true).badge, .warning)
        XCTAssertNil(StatusItemAppearance(dictationState: .idle).badge)
        XCTAssertNil(
            StatusItemAppearance(dictationState: .recording(RecordingState(jobID: job)), needsAttention: true).badge,
            "a recording in progress proves the prerequisites are met"
        )
        XCTAssertNotEqual(
            StatusItemAppearance(dictationState: .idle, needsAttention: true),
            StatusItemAppearance(dictationState: .idle),
            "the badge is part of equality so the shell re-applies it"
        )
    }
}
