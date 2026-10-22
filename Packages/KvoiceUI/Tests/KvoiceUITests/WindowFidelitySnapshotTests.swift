import AppKit
import SwiftUI
import XCTest
import KvoiceDomain
@testable import KvoiceUI

/// UI v2 fidelity F2, opt-in like the other snapshot suites: the whole main
/// window (drawn sidebar + Home) at the four design breakpoints in light and
/// dark, Home's other states, a page with the shared header, and the Try a
/// Test Dictation sheet — `fidelity-window/…png` and
/// `fidelity-window-contact-sheet.png` beside it. Set
/// `KVOICE_LAYOUT_SNAPSHOTS=<dir>`. Nothing is asserted about pixels.
@MainActor
final class WindowFidelitySnapshotTests: XCTestCase {
    private static let sizes = [
        NSSize(width: 820, height: 540), NSSize(width: 960, height: 640),
        NSSize(width: 1_280, height: 800), NSSize(width: 1_600, height: 1_000)
    ]
    private static let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    func testRenderShellAndHome() async throws {
        guard let directory = ProcessInfo.processInfo.environment["KVOICE_LAYOUT_SNAPSHOTS"] else {
            throw XCTSkip("Set KVOICE_LAYOUT_SNAPSHOTS=<dir> to render layout snapshots")
        }
        let out = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("fidelity-window", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var sheet: [(String, NSImage)] = []

        func home(_ hero: HomeHeroState, entries: [HistoryEntry], historyOn: Bool = true) async -> (MainWindowModel, AnyView) {
            let model = MainWindowModel(selection: .home)
            model.readiness = hero.readiness
            model.home = hero
            var settings = AppSettings()
            settings.historyEnabled = historyOn
            let history = HistoryViewModel(repository: PreviewHistoryRepository(entries: entries), host: .detached(settings: settings))
            await history.refreshHome()
            return (model, AnyView(HomeView(model: model, history: history, testDictation: HomeTestDictationModel())))
        }
        func shoot(_ label: String, _ model: MainWindowModel, _ page: AnyView, _ size: NSSize, _ appearance: (String, NSAppearance.Name)) throws {
            let image = LayoutSnapshotTests.render(
                MainWindowView(model: model) { _ in page },
                size: size, appearance: appearance.1, hostInController: true, scale: 2
            )
            let name = "\(label)-\(Int(size.width))x\(Int(size.height))-\(appearance.0)"
            try LayoutSnapshotTests.write(image, to: out.appendingPathComponent("\(name).png"))
            sheet.append((name, image))
        }

        for size in Self.sizes {
            for appearance in Self.appearances {
                let (model, page) = await home(.preview, entries: PreviewFixtures.historyEntries)
                try shoot("home", model, page, size, appearance)
            }
        }
        let attention = HomeHeroState(
            readiness: MainWindowReadiness(title: "Accessibility off — clipboard only", needsAttention: true, shortcutKeys: ["⌃", "⇧", "Space"]),
            interaction: .toggle, modelName: "Whisper large-v3-turbo", microphoneName: "MacBook Pro Microphone", ai: .off
        )
        let noShortcut = HomeHeroState(
            readiness: MainWindowReadiness(title: "Ready", needsAttention: false, shortcutKeys: []),
            interaction: .pushToTalk, modelName: "Parakeet TDT v3", microphoneName: "Studio Display Microphone", ai: .off
        )
        for (name, hero, entries, historyOn) in [
            ("home-attention", attention, PreviewFixtures.historyEntries, true),
            ("home-no-shortcut", noShortcut, [], true),
            ("home-empty", HomeHeroState.preview, [], true),
            ("home-history-off", HomeHeroState.preview, [], false)
        ] as [(String, HomeHeroState, [HistoryEntry], Bool)] {
            let (model, page) = await home(hero, entries: entries, historyOn: historyOn)
            try shoot(name, model, page, NSSize(width: 960, height: 640), Self.appearances[0])
        }
        // A page under the shared header (Window.dc), light and dark.
        for appearance in Self.appearances {
            let model = MainWindowModel(selection: .shortcuts)
            model.readiness = .preview
            let page = await WindowSnapshotTests.content(for: .shortcuts, variant: nil, edition: .developerID)
            try shoot("shortcuts", model, page, NSSize(width: 960, height: 640), appearance)
        }
        // The Try a Test Dictation sheet in each phase.
        let phases: [(String, (HomeTestDictationModel) -> Void)] = [
            ("ready", { _ in }),
            ("recording", { $0.start(); $0.setRecording(true) }),
            ("finishing", { $0.start(); $0.setRecording(true); $0.stop() }),
            ("result", { $0.start(); $0.finish(.transcript("Let’s move the design review to Thursday and send the updated deck to Maya before Friday.")) }),
            ("failed", { $0.start(); $0.finish(.failed(message: "The speech model is not loaded yet.")) })
        ]
        for (name, drive) in phases {
            for appearance in Self.appearances where name == "result" || appearance.0 == "light" {
                let model = HomeTestDictationModel()
                model.onStart = { true }
                model.present()
                drive(model)
                let size = NSSize(width: 440, height: 300)
                let image = LayoutSnapshotTests.render(
                    HomeTestDictationSheet(model: model).frame(width: size.width, height: size.height, alignment: .top).background(Color.kv.surface),
                    size: size, appearance: appearance.1, scale: 2
                )
                let label = "test-dictation-\(name)-\(appearance.0)"
                try LayoutSnapshotTests.write(image, to: out.appendingPathComponent("\(label).png"))
                sheet.append((label, image))
            }
        }
        let contact = PanelSnapshotTests.contactSheet(panels: sheet, icons: [], tile: NSSize(width: 640, height: 430), columns: 4)
        try LayoutSnapshotTests.write(contact, to: out.deletingLastPathComponent().appendingPathComponent("fidelity-window-contact-sheet.png"))
    }
}
