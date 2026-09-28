import KvoiceDomain

/// How the menu-bar item should look for a given dictation state.
///
/// Pure and `Equatable` on purpose. The app shell polls dictation state roughly
/// every 60 ms, so it derives an appearance and compares it against the one
/// already applied; only a real change touches AppKit. Restarting a pulse
/// animation sixteen times a second would look like a flicker rather than a
/// glow, so this equality is what makes the animation stable.
///
/// Mirrors `HUDViewState`: domain state in, presentation values out, no AppKit.
public struct StatusItemAppearance: Equatable, Sendable {
    /// What the user is being told, independent of how it is drawn.
    public enum Phase: String, Equatable, Sendable, CaseIterable {
        /// Nothing in flight.
        case idle
        /// Capturing audio.
        case recording
        /// Audio captured; transcription, AI, or insertion is running.
        case processing
    }

    /// Named rather than a colour, so this stays free of AppKit and testable.
    /// `StatusItemIconController` maps each case to an `NSColor`.
    public enum Tint: String, Equatable, Sendable {
        case recording
        case processing
    }

    public struct Glow: Equatable, Sendable {
        public let tint: Tint
        /// Opacity at the brightest point of the pulse, 0...1.
        public let peakOpacity: Double
        /// Opacity at the dimmest point. Kept above zero so the glow reads as
        /// breathing rather than blinking.
        public let troughOpacity: Double
        /// Seconds for one dim → bright → dim cycle.
        public let pulsePeriod: Double

        public init(
            tint: Tint,
            peakOpacity: Double,
            troughOpacity: Double,
            pulsePeriod: Double
        ) {
            self.tint = tint
            self.peakOpacity = peakOpacity
            self.troughOpacity = troughOpacity
            self.pulsePeriod = pulsePeriod
        }
    }

    /// D.1: "Blocked: warning badge". A small mark on the glyph that says the
    /// next shortcut press will not record until something is fixed.
    public enum Badge: String, Equatable, Sendable {
        case warning
    }

    public let phase: Phase

    /// `nil` when the item should show the plain glyph.
    public let glow: Glow?

    /// `nil` when nothing needs the user's attention.
    public let badge: Badge?

    public init(phase: Phase, glow: Glow?, badge: Badge? = nil) {
        self.phase = phase
        self.glow = glow
        self.badge = badge
    }

    /// Recording pulses faster and brighter than processing: it is the state the
    /// user is actively holding a key for, and the one where a missed cue costs
    /// them a lost recording.
    public static let recordingGlow = Glow(
        tint: .recording,
        peakOpacity: 1.0,
        troughOpacity: 0.35,
        pulsePeriod: 1.1
    )

    public static let processingGlow = Glow(
        tint: .processing,
        peakOpacity: 0.85,
        troughOpacity: 0.3,
        pulsePeriod: 1.9
    )

    /// `needsAttention` is the shell's standing readiness verdict (a missing
    /// model, a denied permission) and keeps the badge up while idle; a
    /// transient `blocked` or `failed` dictation state badges on its own.
    public init(dictationState: DictationState, needsAttention: Bool = false) {
        switch dictationState {
        case .recording:
            phase = .recording
            glow = Self.recordingGlow
            badge = nil

        case .finalizing, .transcribing, .processingAI, .inserting:
            phase = .processing
            glow = Self.processingGlow
            badge = nil

        case .blocked, .failed:
            phase = .idle
            glow = nil
            badge = .warning

        // Terminal and inert states show the plain glyph. `completed` and
        // `failed` are deliberately not glowing: the HUD already reports the
        // outcome, and leaving the menu bar lit after a job ended would read as
        // "still busy".
        case .idle, .completed, .terminating:
            phase = .idle
            glow = nil
            badge = needsAttention ? .warning : nil
        }
    }
}
