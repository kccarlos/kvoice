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

    func testRecordingGlowsInTheRecordingTint() {
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

    /// Fidelity F1 (Motion § 4·6): recording follows the voice; processing,
    /// which has no live signal, keeps the design's slow 1.9 s breath.
    func testRecordingFollowsTheLevelAndProcessingBreathesSlowly() {
        let recording = StatusItemAppearance.recordingGlow
        let processing = StatusItemAppearance.processingGlow
        XCTAssertTrue(recording.followsLevel)
        XCTAssertFalse(processing.followsLevel)
        XCTAssertEqual(recording.troughOpacity, 0.25, "the written rule's floor: 0.25 + 0.75·level")
        XCTAssertEqual(processing.pulsePeriod, 1.9)
        XCTAssertEqual(processing.troughOpacity, 0.35)
        XCTAssertLessThan(recording.pulsePeriod, processing.pulsePeriod)
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

/// UI v2: the download ring and the icon's colours.
final class StatusItemDownloadRingTests: XCTestCase {
    private let job = JobID()

    func testAnIdleDownloadRingsInsteadOfTheBadge() {
        let result = StatusItemAppearance(dictationState: .idle, needsAttention: true, downloadFraction: 0.42)
        XCTAssertEqual(result.phase, .idle)
        XCTAssertNil(result.glow)
        XCTAssertNil(result.badge, "the ring replaces the dot while the fix is happening")
        XCTAssertEqual(try XCTUnwrap(result.progress), 0.42, accuracy: 1e-9)
    }

    func testAJobInFlightWinsOverTheRing() {
        let recording = StatusItemAppearance(dictationState: .recording(RecordingState(jobID: job)), downloadFraction: 0.5)
        XCTAssertEqual(recording.glow?.tint, .recording)
        XCTAssertNil(recording.progress)
        let processing = StatusItemAppearance(dictationState: .transcribing(job), downloadFraction: 0.5)
        XCTAssertEqual(processing.glow?.tint, .processing)
        XCTAssertNil(processing.progress)
    }

    /// Q2b: a job that ended blocked or failed keeps its warning badge
    /// while a download runs — the panel shows its warn / err card then,
    /// and the ring must not hide that something went wrong.
    func testABlockedOrFailedJobKeepsItsBadgeOverTheRing() {
        let failed = StatusItemAppearance(
            dictationState: .failed(job, UserFacingFailure(code: .clipboardWriteFailed)),
            downloadFraction: 0.5
        )
        XCTAssertEqual(failed.badge, .warning)
        XCTAssertNil(failed.progress)
        let blocked = StatusItemAppearance(dictationState: .blocked(.modelUnavailable), downloadFraction: 0.5)
        XCTAssertEqual(blocked.badge, .warning)
        XCTAssertNil(blocked.progress)
        let completed = StatusItemAppearance(
            dictationState: .completed(job, CompletionSummary(insertion: .inserted(method: .selectedTextAttribute))),
            downloadFraction: 0.5
        )
        XCTAssertNotNil(completed.progress, "an ended job with nothing wrong shows the download")
    }

    func testAnUnknownTotalKeepsTheBadge() {
        let result = StatusItemAppearance(dictationState: .idle, needsAttention: true, downloadFraction: nil)
        XCTAssertEqual(result.badge, .warning)
        XCTAssertNil(result.progress)
    }

    /// The 60 ms poll must not re-apply for every byte: fractions inside one
    /// 2 % step are the same appearance.
    func testTheRingIsQuantisedToTwoPercentSteps() {
        let a = StatusItemAppearance(dictationState: .idle, downloadFraction: 0.421)
        let b = StatusItemAppearance(dictationState: .idle, downloadFraction: 0.439)
        let c = StatusItemAppearance(dictationState: .idle, downloadFraction: 0.441)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(b, c)
        XCTAssertEqual(StatusItemAppearance(dictationState: .idle, downloadFraction: 1.4).progress, 1)
        XCTAssertEqual(StatusItemAppearance(dictationState: .idle, downloadFraction: -1).progress, 0)
    }

    /// Fidelity F1: the halo colours and the badge are `Panel.dc.html`'s
    /// literal values — the same on a light and a dark bar.
    @MainActor
    func testTheIconSpeaksTheDesignColours() {
        XCTAssertEqual(StatusItemIconController.token(for: .recording), .voice)
        XCTAssertEqual(StatusItemIconController.token(for: .processing), .cursor)
        let orange = StatusItemIconController.haloColor(for: .recording)
        XCTAssertEqual(orange.redComponent, 1, accuracy: 0.002)
        XCTAssertEqual(orange.greenComponent, 122 / 255, accuracy: 0.002)
        XCTAssertEqual(orange.alphaComponent, 0.85, accuracy: 0.002)
        let blue = StatusItemIconController.haloColor(for: .processing)
        XCTAssertEqual(blue.blueComponent, 235 / 255, accuracy: 0.002)
        XCTAssertEqual(blue.alphaComponent, 0.7, accuracy: 0.002)
        let badge = StatusItemIconController.badgeColor
        XCTAssertEqual(badge.redComponent, 0xF2 / 255, accuracy: 0.002)
        XCTAssertEqual(badge.greenComponent, 0x9A / 255, accuracy: 0.002)
        XCTAssertEqual(badge.blueComponent, 0, accuracy: 0.002)
    }

    /// The design's 26 pt ring and 30 pt halo, fitted to the status
    /// button where the bar is shorter than the design's.
    @MainActor
    func testTheOverlaysFitTheBar() {
        XCTAssertEqual(StatusItemIconController.ringDiameter(forButtonHeight: 37), 26)
        XCTAssertEqual(StatusItemIconController.ringDiameter(forButtonHeight: 22), 22)
        XCTAssertEqual(StatusItemIconController.haloDiameter, 30)
    }
}
