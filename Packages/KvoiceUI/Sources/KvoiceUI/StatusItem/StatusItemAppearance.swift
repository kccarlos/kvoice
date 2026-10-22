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
        /// UI v2 fidelity F1 (Motion § 4·6): the halo follows the voice —
        /// opacity 0.25 + 0.75·level, scale 0.8 + 0.45·level — instead of
        /// pulsing on a clock. The level arrives on its own channel
        /// (`StatusItemIconController.apply(level:)`), never in this
        /// value, so the 60 ms poll's de-duplication still holds.
        public let followsLevel: Bool

        public init(
            tint: Tint,
            peakOpacity: Double,
            troughOpacity: Double,
            pulsePeriod: Double,
            followsLevel: Bool = false
        ) {
            self.tint = tint
            self.peakOpacity = peakOpacity
            self.troughOpacity = troughOpacity
            self.pulsePeriod = pulsePeriod
            self.followsLevel = followsLevel
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

    /// UI v2: a model download's progress, 0...1, drawn as a thin ring
    /// around the glyph *instead of* the badge (the download is the fix
    /// happening). Quantised to `progressStep` so the 60 ms poll applies a
    /// change about fifty times per download, not every poll. `nil` when no
    /// download with a known total is running, or a job is in flight (the
    /// glow wins: it is what the user is holding a key for).
    public let progress: Double?

    /// The ring advances in 2 % steps.
    public static let progressStep = 0.02

    public init(phase: Phase, glow: Glow?, badge: Badge? = nil, progress: Double? = nil) {
        self.phase = phase
        self.glow = glow
        self.badge = badge
        self.progress = progress
    }

    /// Recording: the design's orange halo, driven by the level (0.25 at
    /// silence, 1 at full voice). The period is the fallback pulse
    /// `Panel.dc.html` drew before the motion spec; it is not used while
    /// the halo follows the level.
    public static let recordingGlow = Glow(
        tint: .recording,
        peakOpacity: 1.0,
        troughOpacity: 0.25,
        pulsePeriod: 1.1,
        followsLevel: true
    )

    /// Processing: the design's blue halo breathing slowly (1.9 s,
    /// 0.35 ↔ 1, ease in-out) — the one loop the icon keeps, because
    /// there is no live signal to follow while text is being made.
    public static let processingGlow = Glow(
        tint: .processing,
        peakOpacity: 1.0,
        troughOpacity: 0.35,
        pulsePeriod: 1.9
    )

    /// `needsAttention` is the shell's standing readiness verdict (a missing
    /// model, a denied permission) and keeps the badge up while idle; a
    /// transient `blocked` or `failed` dictation state badges on its own.
    /// A download in flight replaces only the standing badge (the download
    /// is the fix); a blocked or failed job keeps its badge over the ring,
    /// as the panel keeps its warn / err card (Q2b).
    public init(dictationState: DictationState, needsAttention: Bool = false, downloadFraction: Double? = nil) {
        let base = Self(projecting: dictationState, needsAttention: needsAttention)
        let jobNeedsAttention: Bool
        switch dictationState {
        case .blocked, .failed: jobNeedsAttention = true
        default: jobNeedsAttention = false
        }
        guard base.phase == .idle, !jobNeedsAttention, let downloadFraction else {
            self = base
            return
        }
        let clamped = min(max(downloadFraction, 0), 1)
        let steps = (clamped / Self.progressStep + 1e-9).rounded(.down)
        let stepped = steps * Self.progressStep
        self.init(phase: .idle, glow: nil, badge: nil, progress: stepped)
    }

    private init(projecting dictationState: DictationState, needsAttention: Bool) {
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
        progress = nil
    }
}
