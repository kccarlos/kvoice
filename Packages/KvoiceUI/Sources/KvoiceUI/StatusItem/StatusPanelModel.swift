import Foundation
import KvoiceDomain
import Observation

/// The observable behind the status panel (P-D4). One projection for the
/// whole panel, over two inputs the shell already keeps:
///
/// - the **header row's model** (`StatusMenuHeaderModel`), *shared* with
///   the menu's P-D3 row — the same instance, fed by `updateMenu(for:)`
///   (context) and `HUDController.renderedStateObserver` (the HUD's
///   rendered level and clock). The panel builds no second feed: it reads
///   `header.state`, so its meter is the HUD's, at the HUD's rate, and
///   exists only when the header's does — while a job is recording, never
///   idle, the microphone never opened for the panel;
/// - `apply(context:)` from the end of `updateMenu(for:)` — the readiness
///   line, the value rows and choosers, the AI block, the state rows.
///
/// `state` is computed on read so SwiftUI tracks both inputs; the
/// projection is a few strings and is cheap at the HUD's 20 Hz.
///
/// Commands: the view calls `perform(_:)`; the model consults
/// `StatusPanelCommand.closesPanelFirst`, asks the presenter to close when
/// needed (`requestClose`), and hands the command to `handler`. Both
/// closures are installed by the shell with `[weak self]` captures; the
/// model holds nothing of the app delegate.
@Observable
@MainActor
public final class StatusPanelModel {
    /// Where the row focus is: the primary control or a row. Driven by
    /// ↓ / ↑ through `moveFocus`, bound to the view's `@FocusState`.
    public enum FocusTarget: Hashable, Sendable {
        case primary
        case row(StatusPanelState.Row.ID)
    }

    public let header: StatusMenuHeaderModel
    public private(set) var context = StatusPanelContext()
    /// The panel is on screen (`StatusPanelController` sets it around show
    /// and close). The starting glyph pulses only while this is true.
    public var isPresented = false
    /// The focused control, or nil when the panel has no keyboard focus.
    public var focus: FocusTarget?

    /// Runs a command on the shell. Installed by `AppDelegate`; a no-op
    /// until then so the view is safe to render (the gallery).
    public var handler: @MainActor (StatusPanelCommand) -> Void = { _ in }
    /// Closes the panel before a command that must not run under it
    /// (`StatusPanelCommand.closesPanelFirst`). Installed by the presenter.
    public var requestClose: @MainActor () -> Void = {}

    public init(header: StatusMenuHeaderModel) {
        self.header = header
    }

    public var state: StatusPanelState {
        StatusPanelState(header: header.state, headerContext: header.context, context: context)
    }

    public func apply(context: StatusPanelContext) {
        guard context != self.context else { return }
        self.context = context
    }

    /// The level and clock the panel draws, or nil: the same seam as
    /// `StatusMenuHeaderModel.recordingFeed`, so the no-meter-outside-a-
    /// recording rule is asserted at the panel too.
    public var recordingFeed: (level: Double, elapsed: Duration)? {
        header.recordingFeed
    }

    // MARK: Commands

    public func perform(_ command: StatusPanelCommand) {
        if command.closesPanelFirst {
            requestClose()
        }
        handler(command)
    }

    // MARK: Focus

    /// The focusable targets in reading order: the primary control when
    /// enabled, then every enabled row.
    public var focusOrder: [FocusTarget] {
        let state = state
        var order: [FocusTarget] = []
        if state.primaryIsEnabled {
            order.append(.primary)
        }
        order += state.rowsInOrder.filter(\.isEnabled).map { .row($0.id) }
        return order
    }

    /// ↓ (`forward`) / ↑ (`!forward`): to the next or previous enabled
    /// target, from the first or last when nothing is focused, stopping at
    /// the ends (a menu wraps; a Control Center module does not).
    public func moveFocus(forward: Bool) {
        let order = focusOrder
        guard !order.isEmpty else {
            focus = nil
            return
        }
        guard let focus, let index = order.firstIndex(of: focus) else {
            self.focus = forward ? order.first : order.last
            return
        }
        let next = forward ? index + 1 : index - 1
        guard order.indices.contains(next) else { return }
        self.focus = order[next]
    }

    /// Return on the focused target: the primary's `toggleDictation`, a
    /// command row's command, the AI switch's `toggleAI`. A chooser row has
    /// no single command (its choices do); Return leaves it alone so the
    /// system's Space-opens-the-menu behaviour is not doubled. Returns
    /// whether anything ran.
    @discardableResult
    public func activateFocusedRow() -> Bool {
        let state = state
        switch focus {
        case .primary?:
            guard state.primaryIsEnabled else { return false }
            perform(.toggleDictation)
            return true
        case .row(let id)?:
            guard let row = state.rowsInOrder.first(where: { $0.id == id }),
                  row.isEnabled, let command = row.command else { return false }
            perform(command)
            return true
        case nil:
            return false
        }
    }
}
