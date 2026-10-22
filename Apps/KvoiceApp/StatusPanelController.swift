import AppKit
import KvoiceUI
import SwiftUI

/// Presents the status panel (P-D4) as the design draws it (UI v2 fidelity
/// F1, `Panel.dc.html`): an arrowless, solid panel under the status item —
/// not an `NSPopover`, whose arrow and system material (Liquid Glass on
/// macOS 26) the design does not have. Hosts `StatusPanelView` with the
/// `.standalone` chrome (the design's panel ground, 22 pt corner, .5 pt
/// edge) over the shell's `StatusPanelModel`. Owns the panel, the monitors
/// that live only while it is shown, and nothing else; the model and the
/// commands are the app delegate's (`AppDelegate+StatusPanel.swift`).
///
/// The contract the shell relies on is the popover's, unchanged: `toggle`,
/// `show`, `close`, `closeImmediately`, `isShown`, `ownsDeactivation` and
/// `model.requestClose`. What the popover gave for free is built here:
///
/// - *Window*: a borderless `.nonactivatingPanel` that can become key
///   (`KeyablePanel`), so `makeKey()` gives it the keys **without activating
///   the app** — `NSWorkspace.frontmostApplication`, which the insertion
///   tiers target, stays the user's app. The key window is ours while the
///   panel is open, though, which is why the panel is closed —
///   synchronously, `closeImmediately` — before any command that may insert
///   text (`StatusPanelCommand.closesPanelFirst`) and on the edge that ends
///   a recording (`AppDelegate.applyDictationSnapshot`): insertion posts to
///   the PID captured at job start, but the target's `AXFocusedUIElement`
///   may fail to resolve while our window is key.
/// - *Every Space and over full-screen apps*: `.canJoinAllSpaces`,
///   `.fullScreenAuxiliary`, `.transient`, at the status-bar level (the
///   chooser menus open above it).
/// - *Placement*: centred under the status item, kept 8 pt inside the
///   visible frame of the item's screen, 6 pt below the menu bar. A size
///   change keeps the top edge and is never animated (Motion: animate the
///   content inside a fixed panel, never the panel frame).
/// - *Shadow*: the window server's, from the panel's opaque shape — the
///   design's 50 pt blur would need a transparent margin that swallows
///   clicks next to the panel.
/// - *Show / close*: a 180 ms fade in, 120 ms out (Reduce Motion: 150 ms
///   fades, which the spec keeps); `closeImmediately` is instant.
/// - *Click-away*: a global mouse-down monitor (other apps), a local one
///   (our own windows other than the panel and the status item, whose
///   click toggles), and another app becoming active (⌘-Tab). Mouse events
///   need no permission.
/// - *Escape, ⌘H, ⌘,, ⌘Q, ↓, ↑, Return*: a local key-down monitor routes
///   through `StatusPanelKeyEquivalents` (pure, tested) into the model.
///   Tab / Shift-Tab: native (Full Keyboard Access).
/// - *Escape while a job runs*: the job's `ActiveJobEscapeMonitor` has a
///   local half installed before ours, so `AppDelegate.syncEscapeMonitoring`
///   skips it while the panel is shown; Escape closes the panel, the next
///   Escape cancels the job.
/// - *App activation*: a non-activating panel normally leaves the app
///   inactive; if the app was active (a KVoice window in front), closing
///   the key panel can still resign it, so `ownsDeactivation` keeps
///   `AppDelegate.applicationDidResignActive` from treating that as an
///   input-delivery boundary (it would force-stop a held push-to-talk
///   recording).
/// - *VoiceOver*: the panel is a popover-role window labelled "KVoice";
///   the rows, sections and chips carry their labels in the view.
@MainActor
final class StatusPanelController: NSObject {
    let model: StatusPanelModel
    private let panel: KeyablePanel
    private let hosting: NSHostingController<AnyView>
    private weak var anchor: NSStatusBarButton?
    private var keyMonitor: Any?
    private var clickAwayMonitor: Any?
    private var localClickMonitor: Any?
    private var deactivationObserver: NSObjectProtocol?
    private var otherAppObserver: NSObjectProtocol?
    /// The last content height the view reported.
    private var contentHeight: CGFloat = 0
    /// Set while a close is fading out, so a second close (or the toggle)
    /// does not run the teardown twice.
    private var isClosing = false
    /// True from a close until the app has finished resigning "active" for
    /// it; see the type comment. Cleared a beat after the close.
    private(set) var ownsDeactivation = false

    /// Gap between the menu bar and the panel's top edge.
    static let menuBarGap: CGFloat = 6
    /// The panel keeps this far inside the screen's visible frame.
    static let screenMargin: CGFloat = 8

    var isShown: Bool { panel.isVisible && !isClosing }

    init(model: StatusPanelModel) {
        self.model = model
        self.hosting = NSHostingController(rootView: AnyView(EmptyView()))
        self.panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: StatusPanelView.panelWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()
        hosting.rootView = AnyView(
            StatusPanelView(model: model, chrome: .standalone)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { [weak self] height in
                    self?.contentHeightChanged(height)
                }
        )
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.setAccessibilityRole(.popover)
        panel.setAccessibilityLabel("KVoice")
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        model.requestClose = { [weak self] in
            self?.closeImmediately()
        }
    }

    // MARK: Show / close

    /// Left-click on the status item: toggles the panel.
    func toggle(relativeTo button: NSStatusBarButton) {
        if isShown {
            close()
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard !isShown else { return }
        if isClosing {
            // A show during the fade-out: finish the close first.
            finishClose()
        }
        anchor = button
        model.focus = nil
        model.isPresented = true
        // Measure before showing so the panel opens at the phase's height
        // instead of resizing after its first layout.
        let measured = hosting.sizeThatFits(in: NSSize(width: StatusPanelView.panelWidth, height: 4_000)).height
        if measured > 0 {
            contentHeight = measured
        }
        panel.setFrame(frame(height: max(contentHeight, 200), under: button), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        // Key without activation: see the type comment.
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.reduceMotion ? 0.15 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        button.highlight(true)
        installMonitors()
        // The shadow was computed when the content was not drawn yet; redo
        // it once SwiftUI has drawn the rounded panel.
        DispatchQueue.main.async { [weak self] in
            self?.panel.invalidateShadow()
        }
    }

    /// The user's close (Escape, click-away, the toggle): a short fade.
    func close() {
        guard panel.isVisible, !isClosing else { return }
        isClosing = true
        ownsDeactivation = true
        removeMonitors()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.reduceMotion ? 0.15 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isClosing else { return }
                self.finishClose()
            }
        }
    }

    /// The close a command or a lifecycle edge needs *now*: before Insert
    /// Transcript Again, before a window opens, and on the edge that ends
    /// a recording. Synchronous and unanimated, so the target app's focused
    /// element can resolve once our window has stopped being key rather
    /// than racing a fade.
    func closeImmediately() {
        guard panel.isVisible else { return }
        isClosing = true
        ownsDeactivation = true
        finishClose()
    }

    private func finishClose() {
        removeMonitors()
        panel.orderOut(nil)
        panel.alphaValue = 1
        isClosing = false
        anchor?.highlight(false)
        model.isPresented = false
        model.focus = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.ownsDeactivation = false
        }
    }

    /// Monitors are removed on close; this covers a controller released
    /// while shown (`isolated deinit`, as `ActiveJobEscapeMonitor`).
    isolated deinit {
        removeMonitors()
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: Placement and sizing

    /// Centred under the status item, inside the item's screen, the top
    /// edge `menuBarGap` below the menu bar.
    private func frame(height: CGFloat, under button: NSStatusBarButton) -> NSRect {
        let width = StatusPanelView.panelWidth
        guard let window = button.window else {
            return NSRect(x: 0, y: 0, width: width, height: height)
        }
        let item = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.screens.first { $0.frame.intersects(item) } ?? NSScreen.main
        return Self.placement(item: item, visibleFrame: screen?.visibleFrame ?? item, size: NSSize(width: width, height: height))
    }

    /// Pure: where a panel of `size` goes under a status item at `item`
    /// (screen coordinates) on a screen whose visible frame is
    /// `visibleFrame`.
    static func placement(item: NSRect, visibleFrame: NSRect, size: NSSize) -> NSRect {
        let top = min(item.minY, visibleFrame.maxY) - menuBarGap
        var x = item.midX - size.width / 2
        x = min(x, visibleFrame.maxX - screenMargin - size.width)
        x = max(x, visibleFrame.minX + screenMargin)
        return NSRect(x: x.rounded(), y: (top - size.height).rounded(), width: size.width, height: size.height)
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard height > 0, height != contentHeight else { return }
        contentHeight = height
        guard panel.isVisible else { return }
        // The top edge stays where it is; the frame is never animated.
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: false)
        // A transparent window's shadow is computed from its content; redo
        // it for the new shape.
        panel.invalidateShadow()
    }

    // MARK: Monitors

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only keys addressed to the panel itself: a chooser `Menu`
            // open over it tracks ↓ / ↑ / Return / Escape itself.
            guard let self, self.isShown, event.window === self.panel else { return event }
            return self.handle(keyDown: event) ? nil : event
        }
        // Click-away in other apps. Global monitors only see other apps'
        // events, so the status item's own click (which toggles) is never
        // doubled.
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            // A hop rather than `assumeIsolated`: the thread a global
            // monitor's block runs on is not documented.
            Task { @MainActor in
                self?.close()
            }
        }
        // Click-away in our own windows (a KVoice window, the HUD), but not
        // the panel and not the status item, whose click toggles.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel, event.window !== self.anchor?.window, event.window?.level != .popUpMenu {
                self.close()
            }
            return event
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
        // ⌘-Tab or a click in the Dock: another app came to the front.
        otherAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
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
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let deactivationObserver {
            NotificationCenter.default.removeObserver(deactivationObserver)
            self.deactivationObserver = nil
        }
        if let otherAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(otherAppObserver)
            self.otherAppObserver = nil
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

/// A borderless, non-activating panel that still takes the keys (a
/// borderless window refuses key status by default).
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
