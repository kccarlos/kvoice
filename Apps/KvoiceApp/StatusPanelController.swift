import AppKit
import KvoiceUI
import SwiftUI

/// Presents the status panel (P-D4) as a transient `NSPopover` anchored to
/// the status item's button, hosting `StatusPanelView` over the shell's
/// `StatusPanelModel`. Owns the popover, the two event monitors that live
/// only while it is shown, and nothing else; the model and the commands
/// are the app delegate's (`AppDelegate+StatusPanel.swift`).
///
/// **What is native and what is built** (the design review's table,
/// `Docs/Design/Design-Review-2026-09-16.md` § 1; the human rows are in
/// `Docs/Verification.md`):
///
/// - *Chrome*: the popover's own material — Liquid Glass on macOS 26 —,
///   arrow, edge, shadow, Reduce Transparency: native. The view draws no
///   background of its own inside it (`StatusPanelView.Chrome.hosted`).
/// - *Click-away*: `behavior = .transient` is native once the popover's
///   window is key (below); a global mouse-down monitor closes it as well,
///   for the case where it is not. Mouse events need no permission.
/// - *Escape, ⌘H, ⌘,, ⌘Q, ↓, ↑, Return*: built — a local key-down monitor
///   routes through `StatusPanelKeyEquivalents` (pure, tested) into the
///   model. Tab / Shift-Tab between the controls: native (Full Keyboard
///   Access). Type-select: not built; the right-click menu has it.
/// - *Keyboard reaching the panel at all*: `_NSPopoverWindow` is a
///   non-activating panel that can become key (probed on macOS 26 with a
///   throwaway status-item app, 2026-09-16), so `makeKey()` after `show`
///   gives it the keys **without activating the app** —
///   `NSWorkspace.frontmostApplication`, which the insertion tiers target,
///   stays the user's app, and the app is not activated the way a window
///   would. The key window is ours while the panel is open, though, which
///   is why the panel is closed — synchronously, `closeImmediately` —
///   before any command that may insert text
///   (`StatusPanelCommand.closesPanelFirst`) and on the edge that ends a
///   recording (`AppDelegate.applyDictationSnapshot`): insertion posts to
///   the PID captured at job start, so nothing types into the popover, but
///   the target's `AXFocusedUIElement` may fail to resolve while our
///   window is key, and the typed tier would then post to a PID with no
///   key window and the text would be dropped.
/// - *Escape while a job runs*: the job's `ActiveJobEscapeMonitor` has a
///   local half installed before ours, so `AppDelegate.syncEscapeMonitoring`
///   skips it while the panel is shown; Escape closes the panel, the next
///   Escape cancels the job.
/// - *App activation*: `makeKey()` makes `NSApp.isActive` read true and the
///   close resigns it; `AppDelegate.applicationDidBecomeActive` /
///   `DidResignActive` skip their window-activation work for the panel
///   (`isShown`, `ownsDeactivation`).
/// - *Reduce Motion*: `animates` follows the system setting at show time;
///   the resize between phases (idle → recording adds the meter row) is
///   set with a zero-duration context under it.
/// - *Resize*: the view reports its ideal height (`onGeometryChange` on the
///   fixed-height content); the popover's `contentSize` follows. The
///   hosting controller has `sizingOptions = []` so SwiftUI never fights
///   the popover for the frame.
/// - *VoiceOver*: the popover is announced natively; the rows, sections and
///   the switch carry their labels in the view.
@MainActor
final class StatusPanelController: NSObject, NSPopoverDelegate {
    let model: StatusPanelModel
    private let popover = NSPopover()
    private let hosting: NSHostingController<AnyView>
    private weak var anchor: NSStatusBarButton?
    private var keyMonitor: Any?
    private var clickAwayMonitor: Any?
    private var deactivationObserver: NSObjectProtocol?
    /// The last content height the view reported, so a show can size the
    /// popover before its first layout instead of at the default size.
    private var contentHeight: CGFloat = 0
    /// Set when the popover is asked to close for a command, so the close
    /// notification does not run a second time on the same close.
    private var isClosing = false
    /// True from a close until the app has finished resigning "active" for
    /// it: the panel's window was key, so closing it resigns active, and
    /// `AppDelegate.applicationDidResignActive` must not treat that as an
    /// input-delivery boundary (it would force-stop a held push-to-talk
    /// recording). Cleared a beat after the close notification, which is
    /// after the deactivation AppKit posts on the same turn.
    private(set) var ownsDeactivation = false

    var isShown: Bool { popover.isShown }

    init(model: StatusPanelModel) {
        self.model = model
        // The root reports its ideal height; `contentHeightChanged` is
        // installed after `super.init` because it captures self.
        self.hosting = NSHostingController(rootView: AnyView(EmptyView()))
        super.init()
        hosting.rootView = AnyView(
            StatusPanelView(model: model, chrome: .hosted)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { [weak self] height in
                    self?.contentHeightChanged(height)
                }
        )
        hosting.sizingOptions = []
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self
        model.requestClose = { [weak self] in
            self?.closeImmediately()
        }
    }

    // MARK: Show / close

    /// Left-click on the status item: toggles the panel.
    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            close()
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard !popover.isShown else { return }
        anchor = button
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.focus = nil
        model.isPresented = true
        // Measure before showing so the popover opens at the phase's height
        // instead of resizing after its first layout; `onGeometryChange`
        // keeps it in step from then on.
        let measured = hosting.sizeThatFits(in: NSSize(width: StatusPanelView.panelWidth, height: 4_000)).height
        if measured > 0 {
            contentHeight = measured
        }
        popover.contentSize = NSSize(width: StatusPanelView.panelWidth, height: max(contentHeight, 200))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Key without activation: see the type comment. `makeKey` on a
        // non-activating panel routes key events here while the frontmost
        // application stays the user's.
        hosting.view.window?.makeKey()
        button.highlight(true)
        installMonitors()
    }

    /// The user's close (Escape, click-away, the toggle): animated unless
    /// Reduce Motion. `performClose` is asynchronous when animated; the
    /// delegate callback finishes the teardown either way.
    func close() {
        guard popover.isShown, !isClosing else { return }
        isClosing = true
        ownsDeactivation = true
        popover.performClose(nil)
    }

    /// The close a command or a lifecycle edge needs *now*: before Insert
    /// Transcript Again, before a window opens, and on the edge that ends
    /// a recording. Synchronous and unanimated, so the target app's focused
    /// element can resolve once our window has stopped being key rather
    /// than racing a fade; `show` restores `animates`.
    func closeImmediately() {
        guard popover.isShown, !isClosing else { return }
        isClosing = true
        ownsDeactivation = true
        popover.animates = false
        popover.close()
    }

    func popoverDidClose(_ notification: Notification) {
        isClosing = false
        removeMonitors()
        anchor?.highlight(false)
        model.isPresented = false
        model.focus = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.ownsDeactivation = false
        }
    }

    /// Monitors are removed in `popoverDidClose`; this covers a controller
    /// released while shown (`isolated deinit`, as `ActiveJobEscapeMonitor`).
    isolated deinit {
        removeMonitors()
    }

    // MARK: Sizing

    private func contentHeightChanged(_ height: CGFloat) {
        guard height > 0, height != contentHeight else { return }
        contentHeight = height
        guard popover.isShown else { return }
        let size = NSSize(width: StatusPanelView.panelWidth, height: height)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                popover.contentSize = size
            }
        } else {
            popover.contentSize = size
        }
    }

    // MARK: Monitors

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only keys addressed to the popover's own window: a chooser
            // `Menu` open over it tracks ↓ / ↑ / Return / Escape itself.
            guard let self, self.popover.isShown, event.window === self.hosting.view.window else { return event }
            return self.handle(keyDown: event) ? nil : event
        }
        // Belt and braces for click-away: a transient popover closes on a
        // click outside once its window is key; this covers the case where
        // it is not. Global monitors only see other apps' events, so the
        // status item's own click (which toggles) is never doubled.
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            // A hop rather than `assumeIsolated`: the thread a global
            // monitor's block runs on is not documented.
            Task { @MainActor in
                self?.close()
            }
        }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close()
            }
        }
    }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let clickAwayMonitor {
            NSEvent.removeMonitor(clickAwayMonitor)
            self.clickAwayMonitor = nil
        }
        if let deactivationObserver {
            NotificationCenter.default.removeObserver(deactivationObserver)
            self.deactivationObserver = nil
        }
    }

    /// True when the key was ours (consumed).
    private func handle(keyDown event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .capsLock, .numericPad, .function])
        let action = StatusPanelKeyEquivalents.action(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            command: flags == .command
        )
        guard flags.isEmpty || flags == .command, let action else { return false }
        switch action {
        case .close:
            close()
        case .command(let command):
            model.perform(command)
        case .focusNext:
            model.moveFocus(forward: true)
        case .focusPrevious:
            model.moveFocus(forward: false)
        case .activateFocused:
            return model.activateFocusedRow()
        }
        return true
    }
}
