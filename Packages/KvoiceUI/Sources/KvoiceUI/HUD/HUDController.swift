import AppKit
import KvoiceDomain
import SwiftUI

/// Main-actor owner of the non-activating HUD panel.  It accepts immutable
/// render snapshots and never talks to AX, audio, network, or persistence.
///
/// The app shell calls `show(_:on:)` on every state poll (~16 Hz), so this
/// controller is built to make the common call a no-op: an unchanged
/// snapshot returns before touching AppKit, recording feedback is smoothed
/// and rate-limited by `HUDRecordingFeedbackFilter`, the frame is only set
/// when it differs, and a panel that is already on screen is not ordered
/// front again.
@MainActor
public final class HUDController {
    /// The snapshot most recently rendered — or, after an auto-dismissal, the
    /// snapshot that was dismissed, so the shell re-sending it does not bring
    /// the panel back. Explicit `dismiss()` resets it to `.idle`.
    public private(set) var renderState: HUDViewState = .idle
    /// ADR-021: the recorder style the visible panel was laid out with. The
    /// shell passes the *job's* style on every `show`, so a Settings change
    /// mid-dictation never reaches a panel that is already up.
    public private(set) var renderStyle: HUDStyle = .mini
    public private(set) var isVisible = false
    public private(set) var panel: HUDPanel?
    public private(set) weak var recordingScreen: NSScreen?
    /// Number of times the panel content was actually re-rendered. A scalar
    /// for tests and diagnostics; it carries no state content.
    public private(set) var renderCount = 0

    /// ADR-022 item 6: the shell's handlers for the failure HUD's Copy and
    /// Insert Again buttons. Set once at launch (`AppDelegate+Menu`); nil
    /// renders the buttons disabled rather than hiding them, so a missing
    /// wiring is visible instead of silent.
    public var recoveryActions: HUDRecoveryActions?

    /// UI v2 fidelity F5: Model unavailable's "Open Speech Models to
    /// reinstall" link. Set once at launch (`AppDelegate+Menu`); nil renders
    /// the line as plain text.
    public var openSpeechModels: (@MainActor @Sendable () -> Void)?

    /// P-D3: the status menu's header row follows the *rendered* state —
    /// the one that went through `HUDRecordingFeedbackFilter` — so its
    /// meter and clock are the HUD's own 20 Hz smoothed feed rather than a
    /// second smoothing of the raw level. Called with every state that
    /// changes what is rendered and with `.idle` on every dismissal; never
    /// called with a level outside a recording, because the filter only
    /// produces one for `.recording`. Set once at launch
    /// (`AppDelegate+Menu.installStatusItem`); nil is a no-op.
    public var renderedStateObserver: (@MainActor (HUDViewState) -> Void)?

    /// ADR-022 slice 5: the D.4 exit timings, from the developer defaults
    /// the shell loaded. The shell's own terminal-dismissal timer
    /// (`AppDelegate+Menu.scheduleTerminalDismissal`) reads the same value
    /// so the two never disagree.
    public let dismissTimings: HUDDismissTimings

    /// UI v2 fidelity F5 (Motion § 1·2·3): how long the panel stays ordered
    /// in after a dismissal so the exit can play (the pill drops to .92 and
    /// fades in 180 ms; the notch shrinks back). The logical state —
    /// `isVisible`, `renderState`, the observer's `.idle` — changes at once;
    /// only `orderOut` waits. Zero (the default, and every test that does
    /// not ask for it) orders out at once; the app passes `exitDuration`.
    public let exitDelay: Duration
    public static let exitDuration: Duration = .milliseconds(240)
    /// Bumped each time the panel goes from hidden to shown, so the view
    /// starts a fresh tree and plays its entrance (`HUDView.Presentation`).
    public private(set) var presentationID = 0
    private var hideTask: Task<Void, Never>?

    /// Internal (not private) so tests can await the timer they advanced.
    private(set) var dismissalTask: Task<Void, Never>?
    /// Times the auto-dismissal; tests inject a `ParkingClock`.
    private let clock: any KvoiceClock
    private var renderGeneration = 0
    private var feedbackFilter = HUDRecordingFeedbackFilter()
    private let announce: @MainActor (String) -> Void

    /// `announce` is how a state change reaches VoiceOver; the default posts
    /// an `announcementRequested` notification when VoiceOver is running.
    public init(
        announce: (@MainActor (String) -> Void)? = nil,
        dismissTimings: HUDDismissTimings = .compiled,
        clock: any KvoiceClock = SystemKvoiceClock(),
        exitDelay: Duration = .zero
    ) {
        self.announce = announce ?? Self.postVoiceOverAnnouncement
        self.dismissTimings = dismissTimings
        self.clock = clock
        self.exitDelay = exitDelay
    }

    isolated deinit {
        dismissalTask?.cancel()
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    /// Renders a new immutable state without activating the panel or changing
    /// the key/main window of the foreground application. `style` is the
    /// recorder style for this state (ADR-021); the shell reads it from the
    /// job's settings snapshot so it is stable for the life of a job.
    public func show(_ state: HUDViewState, on screen: NSScreen? = nil, style: HUDStyle = .mini) {
        guard state.isVisible else {
            dismiss()
            return
        }

        let rendered = feedbackFilter.apply(state, now: ContinuousClock.now)
        guard rendered != renderState || style != renderStyle else {
            // Same snapshot as last time: either it is already on screen, or
            // it auto-dismissed and must stay dismissed until the state moves.
            return
        }
        renderedStateObserver?(rendered)

        dismissalTask?.cancel()
        dismissalTask = nil
        renderGeneration += 1

        let previousKind = renderState.phase.kind
        renderState = rendered
        renderStyle = style
        renderCount += 1

        // D.3: the panel stays on the screen the recording started on. The
        // screen is captured by the first visible state of a job and dropped
        // when the panel goes away.
        if recordingScreen == nil {
            recordingScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        }

        let hudPanel = ensurePanel()
        // A panel that is hidden — or still playing its exit — enters anew.
        let entering = !isVisible
        if entering {
            hideTask?.cancel()
            hideTask = nil
            presentationID += 1
        }
        // Keep regular HUD states transparent to mouse input. A retained
        // transcript is the explicit recovery surface, and Model
        // unavailable's link takes its one click — both without making the
        // nonactivating panel key or main.
        let ignoresMouse = rendered.recoverableTranscript == nil && !rendered.offersSpeechModelsLink
        if hudPanel.ignoresMouseEvents != ignoresMouse {
            hudPanel.ignoresMouseEvents = ignoresMouse
        }
        let geometry = Self.geometry(of: recordingScreen)
        // The recoverable-transcript failure is the one state that needs the
        // wide, selectable Mini layout; it takes Mini geometry too, so it is
        // never a tall light box glued under the menu bar.
        let effectiveStyle = Self.effectiveStyle(style, for: rendered)
        updateContent(of: hudPanel, with: rendered, style: effectiveStyle, geometry: geometry)
        position(hudPanel, style: effectiveStyle, geometry: geometry)
        if !hudPanel.isVisible {
            hudPanel.showWithoutActivating()
        }
        isVisible = true
        if entering {
            // The window shadow is computed from the content; refresh it
            // once the entrance has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak hudPanel] in
                hudPanel?.invalidateShadow()
            }
        }

        if previousKind != rendered.phase.kind, let announcement = rendered.accessibilityAnnouncement {
            announce(announcement)
        }

        guard let duration = rendered.autoDismissAfter(timings: dismissTimings) else { return }
        let generation = renderGeneration
        dismissalTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.autoDismissIfCurrent(generation)
        }
    }

    /// Hides the panel and forgets the rendered state, so the next `show`
    /// of any visible state renders it.
    public func dismiss() {
        dismissalTask?.cancel()
        dismissalTask = nil
        renderGeneration += 1
        renderState = .idle
        feedbackFilter.reset()
        hidePanel()
        renderedStateObserver?(.idle)
    }

    /// The timed exit for a terminal state. Unlike `dismiss()` this keeps
    /// `renderState`, because the shell keeps polling the same terminal state
    /// until its own dismissal lands and must not re-show the panel.
    private func autoDismissIfCurrent(_ generation: Int) {
        guard renderGeneration == generation else { return }
        dismissalTask = nil
        hidePanel()
    }

    private func hidePanel() {
        let wasVisible = isVisible
        isVisible = false
        panel?.ignoresMouseEvents = true
        recordingScreen = nil
        // Already hidden with an exit playing (the auto-dismissal fired,
        // then the shell's own dismissal lands): let that exit finish.
        if !wasVisible, hideTask != nil { return }
        guard wasVisible, exitDelay > .zero, let panel, panel.isVisible,
              let hostingView = panel.contentView as? HUDHostingView else {
            hideTask?.cancel()
            hideTask = nil
            panel?.orderOut(nil)
            return
        }
        // Play the exit on the last content, then order out — unless a new
        // `show` takes the panel back first (it cancels this task).
        hostingView.rootView = hostingView.rootView.withPresentation(.live(id: presentationID, shown: false))
        hideTask?.cancel()
        hideTask = Task { [weak self, clock, exitDelay] in
            do {
                try await clock.sleep(for: exitDelay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, !self.isVisible else { return }
            self.hideTask = nil
            self.panel?.orderOut(nil)
        }
    }

    private func ensurePanel() -> HUDPanel {
        if let panel {
            return panel
        }

        let hudPanel = HUDPanel(contentView: HUDHostingView(rootView: HUDView(
            state: renderState, recoveryActions: recoveryActions, openSpeechModels: openSpeechModels,
            presentation: .live(id: presentationID, shown: true)
        )))
        panel = hudPanel
        return hudPanel
    }

    private func updateContent(
        of panel: HUDPanel,
        with state: HUDViewState,
        style: HUDStyle,
        geometry: HUDScreenGeometry
    ) {
        let notchWidth = HUDPlacement.notchContentWidth(minimum: HUDView.notchPanelWidth, screen: geometry)
        let view = HUDView(
            state: state, style: style, notchWidth: notchWidth, recoveryActions: recoveryActions,
            openSpeechModels: openSpeechModels, presentation: .live(id: presentationID, shown: true)
        )
        guard let hostingView = panel.contentView as? HUDHostingView else {
            panel.contentView = HUDHostingView(rootView: view)
            return
        }
        hostingView.rootView = view
        hostingView.invalidateIntrinsicContentSize()
    }

    /// The style a state is actually laid out with: the recoverable-
    /// transcript failure falls back to Mini in both content and placement.
    static func effectiveStyle(_ style: HUDStyle, for state: HUDViewState) -> HUDStyle {
        state.recoverableTranscript == nil ? style : .mini
    }

    /// The pure placement inputs for `screen` (`HUDPlacement`), read from
    /// `NSScreen`'s safe-area and auxiliary-area properties — the only
    /// supported way to learn where the camera housing is.
    public static func geometry(of screen: NSScreen?) -> HUDScreenGeometry {
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            let fallback = NSRect(x: 0, y: 0, width: 1440, height: 900)
            return HUDScreenGeometry(frame: fallback, visibleFrame: fallback)
        }
        return HUDScreenGeometry(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }

    private func position(_ panel: HUDPanel, style: HUDStyle, geometry: HUDScreenGeometry) {
        panel.contentView?.layoutSubtreeIfNeeded()
        let fittingSize = panel.contentView?.fittingSize ?? panel.frame.size
        let contentSize: CGSize
        switch style {
        case .mini:
            contentSize = CGSize(
                width: max(HUDView.panelWidth, fittingSize.width),
                height: max(HUDView.minimumPanelHeight, fittingSize.height)
            )
        case .notch:
            contentSize = CGSize(
                width: max(HUDPlacement.notchContentWidth(minimum: HUDView.notchPanelWidth, screen: geometry), fittingSize.width),
                height: max(HUDView.notchHeight(for: renderState), fittingSize.height)
            )
        }

        let frame = HUDPlacement.frame(for: style, contentSize: contentSize, screen: geometry)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: false)
    }

    private static func postVoiceOverAnnouncement(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}

/// The HUD's hosting view. `acceptsFirstMouse` is what lets the recovery
/// buttons (ADR-022 item 6) act on the first click: the panel is never key
/// (`HUDPanel.canBecomeKey` is false), and without this AppKit would spend
/// the click on "activating" a window that cannot be activated.
@MainActor
final class HUDHostingView: NSHostingView<HUDView> {
    required init(rootView: HUDView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HUDHostingView is never unarchived")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
