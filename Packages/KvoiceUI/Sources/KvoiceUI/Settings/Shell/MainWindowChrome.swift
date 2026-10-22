import AppKit
import SwiftUI

/// The main window's chrome (UI v2 fidelity F2): no toolbar and no visible
/// title — the drawn sidebar runs to the top with the traffic lights in it.
/// The title stays set (`MainWindowView`'s `WindowTitleBridge` keeps it on
/// the selected page) for VoiceOver and the Window list. Here rather than
/// in the app's window controller so a test can hold it to that.
@MainActor
public enum MainWindowChrome {
    /// The hosting controller must not manage the window's title bar.
    /// `sizingOptions`: SwiftUI's ideal size must not grow the window (it
    /// grew to fit the History split view, 1054×1194). `sceneBridgingOptions`:
    /// by default (`.title` and `.toolbars`) SwiftUI's bar-appearance bridge
    /// sets `titleVisibility = .visible` again whenever a page's
    /// `.navigationTitle` changes — the AI Actions, General and Speech Models
    /// pages carry one — so the page name appeared beside the traffic lights
    /// after the first page switch (owner report 2026-10-21).
    public static func configure<Content: View>(_ hosting: NSHostingController<Content>) {
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = []
    }

    /// Full-size content under a transparent, title-less title bar.
    public static func configure(_ window: NSWindow) {
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
    }
}
