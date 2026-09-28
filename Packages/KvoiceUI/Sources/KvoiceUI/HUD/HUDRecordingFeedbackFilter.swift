import Foundation

/// Rate-limits and smooths the recording feedback the shell pushes into the
/// HUD (spec D.5: meter at most 20 Hz, elapsed at most 10 Hz, RMS-derived
/// activity with smoothing).
///
/// The shell polls the dictation controller every ~60 ms and calls
/// `HUDController.show` with a fresh snapshot each time, so without this the
/// meter would jump to every raw RMS reading and read as a strobe. The filter
/// is a pure value type with an explicit clock so it can be unit-tested; the
/// controller owns one instance and feeds it `ContinuousClock.now`.
///
/// Output states are quantised (level to 1/50, elapsed to whole seconds) so
/// that consecutive outputs compare equal once the meter settles, which is
/// what lets `HUDController` skip re-rendering an unchanged snapshot.
public struct HUDRecordingFeedbackFilter: Sendable {
    /// 20 Hz.
    public static let meterInterval: Duration = .milliseconds(50)
    /// The meter rises quickly so speech onsets register…
    public var attack: Double = 0.6
    /// …and falls slowly so the bars decay instead of flickering off between
    /// syllables.
    public var release: Double = 0.18

    private var smoothedLevel: Double = 0
    private var lastMeterUpdate: ContinuousClock.Instant?
    private var lastOutput: HUDRecordingState?

    public init() {}

    /// The recording state to render for `state`, or `state` itself when it is
    /// not a recording phase (which also resets the filter).
    public mutating func apply(_ state: HUDViewState, now: ContinuousClock.Instant) -> HUDViewState {
        guard case .recording(let incoming) = state.phase else {
            reset()
            return state
        }

        if let lastMeterUpdate, let lastOutput, now - lastMeterUpdate < Self.meterInterval {
            // Inside the meter budget: keep showing the previous meter and
            // clock. Everything else rides along from the incoming state —
            // the AI indicator (ADR-021) can change on a key press between
            // two meter ticks and must not wait for the next one.
            let held = HUDRecordingState(
                inputLevel: lastOutput.inputLevel,
                elapsed: lastOutput.elapsed,
                mode: incoming.mode,
                maximumDuration: incoming.maximumDuration,
                ai: incoming.ai,
                // Same reason: the start cue and the title flip together.
                captureStarted: incoming.captureStarted
            )
            return HUDViewState(phase: .recording(held), partialTranscript: state.partialTranscript)
        }

        let target = incoming.inputLevel
        let coefficient = target > smoothedLevel ? attack : release
        smoothedLevel += (target - smoothedLevel) * coefficient
        // Snap to a 1/50 grid so the decay converges to a stable value rather
        // than producing a new, slightly different state on every poll.
        let quantised = (smoothedLevel * 50).rounded() / 50
        if quantised == 0 { smoothedLevel = 0 }

        let output = HUDRecordingState(
            inputLevel: quantised,
            // Displayed at whole seconds, so nothing finer can change the
            // rendered state; this is well inside the 10 Hz elapsed budget.
            elapsed: .seconds(max(0, incoming.elapsed.components.seconds)),
            mode: incoming.mode,
            // Carried, not defaulted: the filter once rebuilt the state with
            // the 600 s default and the "No limit" / 30-minute warning copy
            // never reached the screen.
            maximumDuration: incoming.maximumDuration,
            ai: incoming.ai,
            captureStarted: incoming.captureStarted
        )
        lastMeterUpdate = now
        lastOutput = output
        // The partial transcript rides along unchanged (ADR-017); it is
        // rate-limited by the streaming session, not by the meter budget.
        return HUDViewState(phase: .recording(output), partialTranscript: state.partialTranscript)
    }

    public mutating func reset() {
        smoothedLevel = 0
        lastMeterUpdate = nil
        lastOutput = nil
    }
}
