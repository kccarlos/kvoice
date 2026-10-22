import AppKit
import KvoiceDomain
import SwiftUI
@testable import KvoiceUI
import XCTest

/// fix/post-0.1.7 — "Interface language can't be changed, it's greyed out".
/// `KVCard` sets `KVRowToggleStyle` for its rows; a `KVSelect` in a card
/// inherited it, and the inline picker inside its menu turns each choice
/// into a toggle, which AppKit could not bridge into an `NSMenuItem`: every
/// choice of every `KVSelect` in a card was drawn disabled. The closed
/// control looked normal, so no offscreen render or binding test could see
/// it. This opens the real `NSMenu` and reads its items.
///
/// Opt-in (`KVOICE_LIVE_UI_TESTS=1`): it needs a window server, puts a small
/// window on screen for under a second and clicks into it, which the
/// pre-commit suite must not do.
@MainActor
final class KVSelectMenuLiveTests: XCTestCase {
    private struct Probe: View {
        @State var language: InterfaceLanguage = .system

        var body: some View {
            KVCard {
                KVSelect("Interface language", selection: $language, current: GeneralSectionView.languageTitle(language)) {
                    Text("Follow System", bundle: .module).tag(InterfaceLanguage.system)
                    Text(verbatim: "English").tag(InterfaceLanguage.english)
                    Text(verbatim: "简体中文").tag(InterfaceLanguage.simplifiedChinese)
                }
            }
            .frame(width: 240)
            .padding(20)
        }
    }

    /// The default suite's guard for the same fix: the live test above is
    /// opt-in, so the reset that makes the choices enabled is pinned in the
    /// source. `KVCard` is the only place that sets a toggle style.
    func testTheSelectsMenuResetsTheCardsToggleStyle() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/KvoiceUI/Design")
        let controls = try String(contentsOf: sources.appendingPathComponent("KVControls.swift"), encoding: .utf8)
        let select = try XCTUnwrap(controls.range(of: "public struct KVSelect")).upperBound
        let body = controls[select...].prefix(2_000)
        XCTAssertTrue(body.contains(".pickerStyle(.inline)"))
        XCTAssertTrue(body.contains(".toggleStyle(.automatic)"), "KVSelect's menu must not inherit KVCard's row toggle style")
        let cards = try String(contentsOf: sources.appendingPathComponent("KVCards.swift"), encoding: .utf8)
        XCTAssertTrue(cards.contains(".toggleStyle(KVRowToggleStyle())"), "if KVCard stops setting it, this guard can go")
    }

    func testAKVSelectInACardOffersEnabledChoices() throws {
        guard ProcessInfo.processInfo.environment["KVOICE_LIVE_UI_TESTS"] == "1" else {
            throw XCTSkip("Set KVOICE_LIVE_UI_TESTS=1 to open a KVSelect's real menu on screen")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let hosting = NSHostingView(rootView: Probe())
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        for _ in 0..<10 { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }

        let catcher = MenuCatcher()
        NotificationCenter.default.addObserver(catcher, selector: #selector(MenuCatcher.began(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        defer { NotificationCenter.default.removeObserver(catcher) }

        // The select sits at the card row's leading edge: padding 20 + the
        // row's 14 pt inset, vertically centred.
        let point = NSPoint(x: 20 + KVCardLayout.rowHorizontalPadding + 20, y: size.height / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
            for _ in 0..<5 { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            if !catcher.items.isEmpty { break }
        }
        let items = catcher.items

        XCTAssertEqual(items.map(\.title), ["Follow System", "English", "简体中文"], "the click opened the select's menu")
        for item in items {
            XCTAssertTrue(item.enabled, "\(item.title) is disabled in a card's KVSelect")
        }
    }
}

/// Reads the menu the moment it starts tracking (the notification is posted
/// synchronously on the main thread, inside the click) and closes it.
@MainActor
private final class MenuCatcher: NSObject {
    var items: [(title: String, enabled: Bool)] = []

    @objc func began(_ note: Notification) {
        guard let menu = note.object as? NSMenu else { return }
        items = menu.items.filter { !$0.isSeparatorItem && !$0.title.isEmpty }.map { ($0.title, $0.isEnabled) }
        // Closed once its tracking loop runs; a cancel from inside the
        // begin notification is too early to take.
        menu.perform(#selector(NSMenu.cancelTrackingWithoutAnimation), with: nil, afterDelay: 0.05, inModes: [.eventTracking, .default, .modalPanel])
    }
}
