import Foundation
import KvoiceDomain
import Observation

/// The observable behind the status menu's header row (P-D3). Two inputs,
/// both pushed by the shell on the main actor, one projected output:
///
/// - `apply(context:)` from `AppDelegate.updateMenu(for:)` — the lifecycle
///   kind, readiness, shortcut readout, blocked reason, model install;
/// - `apply(hud:)` from `HUDController.renderedStateObserver` — the HUD's
///   rendered state, which is where the 20 Hz smoothed level and the
///   whole-second clock live while a job records.
///
/// The model owns no task, timer, stream or audio handle: it cannot
/// observe a level on its own, so it cannot show one while idle (the
/// condition on P-D3). `recordingFeed` is the testable form of that
/// rule — nil in every state but a live recording.
///
/// Holds no reference to the shell: the row's click goes through the menu
/// item's own target/action (`StatusMenuHeaderItemView`), so nothing here
/// can retain the app delegate.
@Observable
@MainActor
public final class StatusMenuHeaderModel {
    public private(set) var state: StatusMenuHeaderState = .idle
    public private(set) var context = StatusMenuHeaderContext()
    public private(set) var hud: HUDViewState = .idle
    /// The menu highlights the row — under the pointer or reached with the
    /// arrow keys; `StatusMenuHeaderItemView` reads `NSMenuItem.isHighlighted`
    /// and sets this. The view draws the selection background and switches
    /// the text to `selectedMenuItemTextColor`.
    public var isHighlighted = false
    /// The menu is open, so the row is in a window (`viewDidMoveToWindow`).
    /// The pulse only runs while this is true; a closed menu animates
    /// nothing.
    public var isMenuOpen = false

    public init() {}

    public func apply(context: StatusMenuHeaderContext) {
        guard context != self.context else { return }
        self.context = context
        project()
    }

    public func apply(hud: HUDViewState) {
        guard hud != self.hud else { return }
        self.hud = hud
        project()
    }

    /// The level and clock the row draws, or nil when it draws none. Nil
    /// whenever the dictation is not `.recording` with capture started —
    /// including idle, whatever `hud` says — so a test can assert the
    /// no-meter-outside-a-recording rule directly.
    public var recordingFeed: (level: Double, elapsed: Duration)? {
        guard case .meter(let level, let elapsed) = state.trailing else { return nil }
        return (level, elapsed)
    }

    private func project() {
        let next = StatusMenuHeaderState(context: context, hud: hud)
        guard next != state else { return }
        state = next
    }
}
