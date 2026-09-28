import AppKit
import KvoiceUI
import SwiftUI

/// AppKit owns the lifetime of the one first-run window while SwiftUI owns
/// the screen content. Reusing one controller prevents duplicate setup
/// windows when a user opens Setup from the menu more than once.
///
/// `NSObject` + `NSWindowDelegate` only for `windowWillClose(_:)`: the
/// hotkey-test hook (`OnboardingViewModel.beginHotkeyTest()/endHotkeyTest()`)
/// is normally torn down by `OnboardingView`'s
/// `.task(id: hotkeyTestIsAvailable)` cancelling when the indicator leaves
/// the Shortcut page or the view goes away, but the window closing —
/// the red button, `close()` below, or `applicationShouldTerminate` — is a
/// separate path that must not depend on that task's timing (2026-09-14
/// review: a leaked hook swallows every shortcut press until relaunch).
/// `endHotkeyTest()` is idempotent, so calling it here even when the hook was
/// already removed is harmless.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let viewModel: OnboardingViewModel

    /// `aiSettingsViewModel` backs the AI Actions link on the Ready page
    /// (the Optional AI step left the wizard on 2026-09-16). `showSetup()` in
    /// `AppDelegate+Onboarding.swift` constructs this controller with the
    /// view model only, so when it is not passed the controller resolves it
    /// from the app delegate and installs the shell hooks the setup screens
    /// need (System Settings deep links, input device name, space estimate).
    init(
        viewModel: OnboardingViewModel,
        aiSettingsViewModel: AISettingsViewModel? = nil
    ) {
        let appDelegate = NSApp.delegate as? AppDelegate
        appDelegate?.installOnboardingSurfaceHooks()
        let aiViewModel = aiSettingsViewModel ?? appDelegate?.aiSettingsViewModel

        self.viewModel = viewModel
        let hostingController = NSHostingController(
            rootView: OnboardingView(
                viewModel: viewModel,
                aiSettingsViewModel: aiViewModel
            )
        )
        window = NSWindow(
            contentViewController: hostingController
        )
        window.title = String(localized: "KVoice Setup", table: "Shell")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // The window, not the view, owns its size (see "SwiftUI conventions"
        // in Docs/Architecture.md). One size fits every screen: the tallest
        // regular screen (Ready, with the readiness list and the test field)
        // fits without scrolling, and the Optional AI form scrolls inside
        // the same frame rather than pushing the window taller.
        window.setContentSize(Self.defaultContentSize)
        window.contentMinSize = Self.minimumContentSize
        window.center()
        window.setFrameAutosaveName("kvoice.Onboarding")
        window.isRestorable = false
        super.init()
        window.delegate = self
    }

    /// The red close button (and any programmatic `window.close()`). Belt
    /// and braces alongside `.task(id: hotkeyTestIsAvailable)`'s own
    /// teardown; see the type doc comment.
    func windowWillClose(_ notification: Notification) {
        viewModel.endHotkeyTest()
    }

    static let defaultContentSize = NSSize(width: 640, height: 640)
    static let minimumContentSize = NSSize(width: 560, height: 520)

    var isVisible: Bool {
        window.isVisible
    }

    func show() {
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// After a TCC prompt returns. The prompt takes activation with it and
    /// leaves the setup window behind whatever was in front; this brings it
    /// back without moving or resizing it. A window the user has closed is
    /// left closed.
    func restoreFocus() {
        guard window.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// `orderOut`, not `window.close()`: `isReleasedWhenClosed = false` keeps
    /// the window alive for reuse and `orderOut` does not post
    /// `windowWillClose`, so this calls `endHotkeyTest()` itself.
    func close() {
        window.orderOut(nil)
        viewModel.endHotkeyTest()
    }
}
