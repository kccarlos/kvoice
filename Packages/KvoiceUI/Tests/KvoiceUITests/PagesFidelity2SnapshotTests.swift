import AppKit
import SwiftUI
import XCTest
import KvoiceDomain
@testable import KvoiceUI

/// UI v2 fidelity F3b, opt-in like the other snapshot suites: Dictionary,
/// AI Actions, History and the Speech Models header button inside the drawn
/// shell — light and dark at 960×640, light at 820×540 and 1280×800, the
/// App Store edition where a page differs, History with an entry selected
/// (Original and Enhanced), empty and with saving off —
/// `fidelity-pages-2/<page>[-<variant>]-<size>-<appearance>.png` plus
/// `fidelity-pages-2-contact-sheet.png` beside the folder. Set
/// `KVOICE_LAYOUT_SNAPSHOTS=<dir>`; set `KVOICE_PAGES=<raw,raw>` to render a
/// subset. Nothing is asserted about pixels.
@MainActor
final class PagesFidelity2SnapshotTests: XCTestCase {
    private static let pages: [MainWindowSection] = [.dictionary, .aiActions, .history, .models]

    static let designTerms = ["KVoice", "WhisperKit", "FluidAudio", "Parakeet", "Maya Chen", "SwiftUI", "Ollama", "Core ML", "Neural Engine", "Thursday stand-up"]

    func testRenderPages() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["KVOICE_LAYOUT_SNAPSHOTS"] else {
            throw XCTSkip("Set KVOICE_LAYOUT_SNAPSHOTS=<dir> to render layout snapshots")
        }
        let only = env["KVOICE_PAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        let out = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("fidelity-pages-2", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var sheet: [(String, NSImage)] = []

        func shoot(_ section: MainWindowSection, variant: String? = nil, edition: DistributionEdition = .developerID,
                   size: NSSize, appearance: (String, NSAppearance.Name)) async throws {
            let model = MainWindowModel(selection: section)
            model.readiness = .preview
            let page = await Self.content(for: section, variant: variant, edition: edition)
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
            guard section != .models else { continue }
            try await shoot(section, size: NSSize(width: 820, height: 540), appearance: ("light", .aqua))
            try await shoot(section, size: NSSize(width: 1_280, height: 800), appearance: ("light", .aqua))
            switch section {
            case .dictionary:
                try await shoot(section, variant: "editing", size: base, appearance: ("light", .aqua))
            case .aiActions:
                try await shoot(section, variant: "appstore", edition: .appStore, size: base, appearance: ("light", .aqua))
            case .history:
                for variant in ["original", "empty", "off"] {
                    try await shoot(section, variant: variant, size: base, appearance: ("light", .aqua))
                }
                try await shoot(section, variant: "original", size: base, appearance: ("dark", .darkAqua))
            default: break
            }
        }
        guard only == nil else { return }
        // ≤ 8000 px on the longest side (at 2×): 6 columns of 420 pt tiles.
        let contact = PanelSnapshotTests.contactSheet(panels: sheet, icons: [], tile: NSSize(width: 420, height: 280), columns: 6)
        try LayoutSnapshotTests.write(contact, to: out.deletingLastPathComponent().appendingPathComponent("fidelity-pages-2-contact-sheet.png"))
    }

    static func content(for section: MainWindowSection, variant: String?, edition: DistributionEdition) async -> AnyView {
        switch section {
        case .dictionary:
            let model = DictionaryViewModel(
                host: .detached(settings: AppSettings(dictionary: DictionarySettings(terms: designTerms))),
                catalogPromptTokenLimit: 224
            )
            await model.refresh()
            if variant == "editing", let entry = model.entries.dropFirst(4).first {
                model.beginEditing(entry.id)
            }
            return AnyView(DictionarySectionView(model: model, availability: WindowSnapshotTests.availability(for: edition)))
        case .history:
            var settings = AppSettings()
            if variant == "off" { settings.historyEnabled = false }
            let model = HistoryViewModel(
                repository: PreviewHistoryRepository(entries: variant == "empty" || variant == "off" ? [] : PreviewFixtures.historyEntries),
                host: .detached(settings: settings)
            )
            // The header's Transcribe File… needs a transcriber; never run.
            model.fileTranscriber = { _ in throw CancellationError() }
            model.startTestDictation = {}
            model.openDataPrivacy = {}
            await model.refresh()
            if let entry = model.entries.first(where: \.hasDistinctEnhancedText) ?? model.entries.first {
                model.selectedEntryID = entry.id
            }
            if variant == "original" { model.transcriptTab = .original }
            return AnyView(HistoryView(viewModel: model))
        default:
            return await WindowSnapshotTests.content(for: section, variant: variant, edition: edition)
        }
    }
}
