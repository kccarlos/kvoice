import XCTest
import KvoiceDomain
@testable import KvoiceUI

/// Q3 (2026-10-22): one AI vocabulary on every surface. The panel's Off
/// chip, Home's hero chip, the HUD chip and Data & Privacy all say "AI off"
/// (zh-Hans "AI 已关闭"); the panel's old "AI Off" spelling is gone from the
/// code and the catalog.
@MainActor
final class AIActionsCopyTests: XCTestCase {
    func testEverySurfaceSaysAIOffTheSameWay() {
        XCTAssertEqual(AIActionsCopy.aiOff, "AI off")
        XCTAssertEqual(HUDAIIndicator(isEnabled: false).chipText, AIActionsCopy.aiOff)
        XCTAssertEqual(HUDAIIndicator(isEnabled: false).accessibilityDescription, AIActionsCopy.aiOff)
        let hero = HomeHeroState(
            readiness: MainWindowReadiness(title: "Ready", needsAttention: false, shortcutKeys: ["⌃", "Space"]),
            interaction: .pushToTalk, modelName: "M", microphoneName: "Mic", ai: .off
        )
        XCTAssertEqual(hero.aiChipTitle, AIActionsCopy.aiOff)
    }

    func testTheCatalogHasOneSpellingWithOneTranslation() throws {
        let catalog = try StringCatalog(relativePath: StringCatalog.kvoiceUI)
        XCTAssertNil(catalog.entries.first { $0.key == "AI Off" }, "the title-case spelling must not come back")
        let off = try XCTUnwrap(catalog.entries.first { $0.key == "AI off" })
        XCTAssertEqual(off.localizations["zh-Hans"]?.value, "AI 已关闭")
        let on = try XCTUnwrap(catalog.entries.first { $0.key == "AI on" })
        XCTAssertEqual(on.localizations["zh-Hans"]?.value, "AI 已开启")
    }

    /// The panel's Off chip is pressed by its accessibility label (the
    /// smoke harness does exactly that), so the label must be the shared
    /// word, not a literal of its own.
    func testThePanelOffChipReadsTheSharedWord() throws {
        let source = try String(
            contentsOf: StringCatalog.repositoryRoot
                .appendingPathComponent("Packages/KvoiceUI/Sources/KvoiceUI/StatusItem/StatusPanelView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("AIActionsCopy.aiOff"))
        XCTAssertFalse(source.contains("\"AI Off\""))
    }
}
