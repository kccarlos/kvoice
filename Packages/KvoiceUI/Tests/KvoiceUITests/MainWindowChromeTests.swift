import AppKit
import SwiftUI
import XCTest
@testable import KvoiceUI

/// The main window shows no title text on any page (owner report
/// 2026-10-21): SwiftUI's scene bridging turned `titleVisibility` back on
/// when a page's `.navigationTitle` changed.
@MainActor
final class MainWindowChromeTests: XCTestCase {
    /// Kept alive to process exit, like `LayoutSnapshotTests.windows`:
    /// releasing a hosting window mid-test crashed AppKit at teardown.
    static var windows: [NSWindow] = []

    func testTheTitleStaysHiddenAcrossPageSwitches() {
        let model = MainWindowModel(selection: .shortcuts)
        let view = MainWindowView(model: model) { section in
            // Pages that publish a navigation title, like AI Actions,
            // General and Speech Models do.
            AnyView(Text(verbatim: section.title).navigationTitle(section.title))
        }
        let hosting = NSHostingController(rootView: view)
        MainWindowChrome.configure(hosting)
        XCTAssertEqual(hosting.sceneBridgingOptions, [])
        XCTAssertEqual(hosting.sizingOptions, [])
        let window = NSWindow(contentViewController: hosting)
        MainWindowChrome.configure(window)
        Self.windows.append(window)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        window.setContentSize(NSSize(width: 820, height: 540))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        // Two switches are enough: the first reproduces the bug (red
        // without `sceneBridgingOptions = []`), History is the page with
        // its own split view.
        for section in [MainWindowSection.aiActions, .history] {
            model.select(section)
            hosting.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            XCTAssertEqual(window.titleVisibility, .hidden, "title text shown on \(section)")
            XCTAssertEqual(window.title, section.title, "the hidden title still names the page for VoiceOver")
        }
    }
}
