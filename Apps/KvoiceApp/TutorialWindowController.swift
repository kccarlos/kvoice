import AppKit
import KvoiceUI
import SwiftUI

/// The standalone "quick tour" window (Later waves: tutorial pages),
/// reachable from Help › Show Tutorial and from the existing-user banner in
/// the main window, without redoing the rest of setup. Sibling of
/// `OnboardingWindowController`, same reasoning: AppKit owns the one window's
/// lifetime so a second "Show Tutorial" click reuses it instead of stacking
/// duplicate windows, and SwiftUI owns everything inside it.
@MainActor
final class TutorialWindowController {
    private let window: NSWindow
    let viewModel: TutorialViewModel

    init(viewModel: TutorialViewModel) {
        self.viewModel = viewModel
        let hostingController = NSHostingController(rootView: TutorialView(viewModel: viewModel))
        window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "KVoice Tutorial", table: "Shell")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Same minimum as the setup window: the tour is meant to fit
        // alongside it without a second size to remember.
        window.setContentSize(OnboardingWindowController.defaultContentSize)
        window.contentMinSize = OnboardingWindowController.minimumContentSize
        window.center()
        window.setFrameAutosaveName("kvoice.Tutorial")
        window.isRestorable = false
    }

    var isVisible: Bool {
        window.isVisible
    }

    func show() {
        if !window.isVisible {
            window.center()
        }
        // Reopening always starts over rather than resuming mid-tour from an
        // earlier viewing (the window is kept, not recreated, between shows).
        viewModel.restart()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }
}
