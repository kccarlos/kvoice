import Foundation
import KvoiceDomain

// MARK: - Per-job timing (2026-09-16)

/// The instants a dictation job crossed each reducer boundary, on the
/// controller's injected clock (never `Date()` differences, so the test clock
/// decides what a test measures). One per
/// job, and turned into scalars by `measure(at:)` for the single timing
/// line. It holds no text, no audio, and no target identity by construction.
/// Since the ADR-022 slice 6 split it is owned by `DictationJobRunner`, one
/// per runner; the coordinator never reads it.
struct JobTimeline: Sendable, Equatable {
    let jobID: JobID
    /// The start command (or the `.start` transition for direct callers).
    let startCommandAt: ContinuousClock.Instant
    /// `AudioCaptureService.start` returned: the input engine is running.
    private(set) var engineStartedAt: ContinuousClock.Instant?
    /// The first captured buffer with signal.
    private(set) var captureStartedAt: ContinuousClock.Instant?
    /// Peak of the recording's first `leadingPeakWindow`, in dBFS.
    private(set) var leadingPeakDBFS: Float?
    /// The user's stop edge or the hard cap: `.finalizing`.
    private(set) var stoppedAt: ContinuousClock.Instant?
    private(set) var transcribingAt: ContinuousClock.Instant?
    private(set) var transcribedAt: ContinuousClock.Instant?
    /// Set only when the job entered `.processingAI`.
    private(set) var aiStartedAt: ContinuousClock.Instant?
    private(set) var insertingAt: ContinuousClock.Instant?
    private(set) var recordingDuration: Duration?
    private(set) var streaming = false
    /// Insert Again ran: the total no longer means anything.
    private(set) var retried = false

    init(jobID: JobID, startCommandAt: ContinuousClock.Instant) {
        self.jobID = jobID
        self.startCommandAt = startCommandAt
    }

    mutating func recordEngineStarted(at instant: ContinuousClock.Instant, for jobID: JobID) {
        guard self.jobID == jobID, engineStartedAt == nil else { return }
        engineStartedAt = instant
    }

    mutating func recordCaptureStarted(at instant: ContinuousClock.Instant, for jobID: JobID) {
        guard self.jobID == jobID, captureStartedAt == nil else { return }
        captureStartedAt = instant
    }

    /// The length and the opening peak of the captured audio. The window is
    /// measured here, once, from the samples the pipeline already holds; the
    /// samples themselves go no further.
    mutating func recordRecording(_ recording: AudioRecording, for jobID: JobID) {
        guard self.jobID == jobID else { return }
        recordingDuration = recording.duration
        let window = Int(Self.seconds(DictationController.leadingPeakWindow) * recording.sampleRate)
        leadingPeakDBFS = SpeechGate.peakLevelDBFS(of: recording.samples.prefix(window))
    }

    mutating func recordStopped(at instant: ContinuousClock.Instant, streaming: Bool) {
        guard stoppedAt == nil else { return }
        stoppedAt = instant
        self.streaming = streaming
    }

    mutating func recordTranscribing(at instant: ContinuousClock.Instant) {
        transcribingAt = instant
    }

    mutating func recordTranscribed(at instant: ContinuousClock.Instant, aiStarted: Bool) {
        transcribedAt = instant
        if aiStarted {
            aiStartedAt = instant
        } else {
            insertingAt = instant
        }
    }

    mutating func recordInserting(at instant: ContinuousClock.Instant) {
        insertingAt = instant
    }

    mutating func recordRetry(at instant: ContinuousClock.Instant) {
        insertingAt = instant
        retried = true
    }

    /// The scalars for the timing line, as of `now` (the terminal
    /// transition). A phase the job never entered is nil, never zero.
    struct Measurement: Sendable, Equatable {
        var engineStartMilliseconds: Int?
        var captureStartMilliseconds: Int?
        var leadingPeakDBFS: Double?
        var recordingSeconds: Double?
        var sttMilliseconds: Int?
        var realTimeFactor: Double?
        var aiMilliseconds: Int?
        var insertionMilliseconds: Int?
        /// Stop-of-recording to the terminal state; nil after Insert Again.
        var totalMilliseconds: Int?
        var streaming: Bool
    }

    func measure(at now: ContinuousClock.Instant) -> Measurement {
        let recordingSeconds = recordingDuration.map { duration in
            (Self.seconds(duration) * 10).rounded() / 10
        }
        let sttMilliseconds = pair(transcribingAt, transcribedAt).map { Self.milliseconds($1 - $0) }
        var realTimeFactor: Double?
        if let sttMilliseconds, let recordingDuration, recordingDuration > .zero {
            let factor = Double(sttMilliseconds) / 1_000 / Self.seconds(recordingDuration)
            realTimeFactor = (factor * 100).rounded() / 100
        }
        // The AI phase ends where insertion begins; a job still in the AI
        // phase when it fails is measured to the failure.
        let aiMilliseconds = aiStartedAt.map { Self.milliseconds((insertingAt ?? now) - $0) }
        return Measurement(
            engineStartMilliseconds: engineStartedAt.map { Self.milliseconds($0 - startCommandAt) },
            captureStartMilliseconds: captureStartedAt.map { Self.milliseconds($0 - startCommandAt) },
            leadingPeakDBFS: leadingPeakDBFS.map { (Double($0) * 10).rounded() / 10 },
            recordingSeconds: recordingSeconds,
            sttMilliseconds: sttMilliseconds,
            realTimeFactor: realTimeFactor,
            aiMilliseconds: aiMilliseconds,
            insertionMilliseconds: insertingAt.map { Self.milliseconds(now - $0) },
            totalMilliseconds: retried ? nil : stoppedAt.map { Self.milliseconds(now - $0) },
            streaming: streaming
        )
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

private func pair<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
