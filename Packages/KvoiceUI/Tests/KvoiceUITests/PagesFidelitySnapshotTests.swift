import AppKit
import SwiftUI
import XCTest
import KvoiceDomain
@testable import KvoiceUI

/// UI v2 fidelity F3, opt-in like the other snapshot suites: every main-window
/// page inside the drawn shell — light and dark at 960×640, light at 820×540
/// and 1280×800, and the App Store edition where a page differs —
/// `fidelity-pages/<page>[-<variant>]-<size>-<appearance>.png` plus
/// `fidelity-pages-contact-sheet.png` beside the folder. Set
/// `KVOICE_LAYOUT_SNAPSHOTS=<dir>`; set `KVOICE_PAGES=<raw,raw>` to render a
/// subset. Nothing is asserted about pixels.
@MainActor
final class PagesFidelitySnapshotTests: XCTestCase {
    private static let pages: [MainWindowSection] = [
        .shortcuts, .recording, .models, .audioInput, .dictionary, .aiActions,
        .history, .dataPrivacy, .permissions, .general, .help
    ]

    func testRenderPages() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["KVOICE_LAYOUT_SNAPSHOTS"] else {
            throw XCTSkip("Set KVOICE_LAYOUT_SNAPSHOTS=<dir> to render layout snapshots")
        }
        let only = env["KVOICE_PAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        let out = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("fidelity-pages", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var sheet: [(String, NSImage)] = []

        func shoot(_ section: MainWindowSection, variant: String? = nil, edition: DistributionEdition = .developerID,
                   size: NSSize, appearance: (String, NSAppearance.Name)) async throws {
            let model = MainWindowModel(selection: section)
            model.readiness = variant == "attention"
                ? MainWindowReadiness(title: "Needs attention", needsAttention: true, shortcutKeys: ["⌃", "⇧", "Space"])
                : .preview
            let page = await WindowSnapshotTests.content(for: section, variant: variant, edition: edition)
            let image = LayoutSnapshotTests.render(
                MainWindowView(model: model) { _ in page },
                size: size, appearance: appearance.1, hostInController: true, scale: 2
            )
            let suffix = variant.map { "-\($0)" } ?? ""
            let name = "\(section.rawValue)\(suffix)-\(Int(size.width))x\(Int(size.height))-\(appearance.0)"
            try LayoutSnapshotTests.write(image, to: out.appendingPathComponent("\(name).png"))
            sheet.append((name, image))
        }

        let base = NSSize(width: 960, height: 640)
        for section in Self.pages where only?.contains(section.rawValue) ?? true {
            try await shoot(section, size: base, appearance: ("light", .aqua))
            try await shoot(section, size: base, appearance: ("dark", .darkAqua))
            try await shoot(section, size: NSSize(width: 820, height: 540), appearance: ("light", .aqua))
            try await shoot(section, size: NSSize(width: 1_280, height: 800), appearance: ("light", .aqua))
            switch section {
            case .recording, .shortcuts, .aiActions, .permissions, .dataPrivacy, .general, .models:
                try await shoot(section, variant: "appstore", edition: .appStore, size: base, appearance: ("light", .aqua))
            default: break
            }
            if section == .permissions {
                try await shoot(section, variant: "attention", size: base, appearance: ("light", .aqua))
                try await shoot(section, variant: "attention", size: base, appearance: ("dark", .darkAqua))
            }
            if section == .history {
                try await shoot(section, variant: "empty", size: base, appearance: ("light", .aqua))
            }
        }
        guard only == nil else { return }
        // ≤ 8000 px on the longest side (at 2×): 8 columns of 420 pt tiles.
        let contact = PanelSnapshotTests.contactSheet(panels: sheet, icons: [], tile: NSSize(width: 420, height: 280), columns: 8)
        try LayoutSnapshotTests.write(contact, to: out.deletingLastPathComponent().appendingPathComponent("fidelity-pages-contact-sheet.png"))
    }
}
