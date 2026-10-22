import Foundation
import KvoiceDomain
import XCTest
@testable import KvoiceUI

/// 2026-10-22: the Mini recorder truncated "Starting mic…" and the action
/// chip ("Clean… ⌘1"). `HUDHeaderFit` decides the title row's degrade
/// order — the full chip, then the chip without its ⌘-number, then (only
/// for a long name the user typed) a truncated chip — and the title keeps
/// its full width. These run the widest strings the product ships, in
/// English and Simplified Chinese, through both recorder styles.
final class HUDHeaderFitTests: XCTestCase {
    private var ui: StringCatalog!
    private var domain: StringCatalog!

    override func setUpWithError() throws {
        ui = try StringCatalog(relativePath: StringCatalog.kvoiceUI)
        domain = try StringCatalog(relativePath: StringCatalog.domainCopy)
    }

    private func zh(_ key: String, in catalog: StringCatalog) throws -> String {
        try XCTUnwrap(catalog.value(for: key, language: "zh-Hans"), key)
    }

    /// The recording titles of one interface language, each with the
    /// widest clock it can show beside it: "Starting mic…" always reads
    /// 0:00, "Recording" up to 10:00.
    private func titles(chinese: Bool) throws -> [(title: String, clock: String)] {
        chinese
            ? [(try zh("Starting mic…", in: ui), "0:00"), (try zh("Recording", in: ui), "10:00")]
            : [("Starting mic…", "0:00"), ("Recording", "10:00")]
    }

    /// Every chip the recorder can show in one language: each built-in's
    /// name as that language displays it (2026-10-22), with the widest
    /// ⌘-number, plus AI on and AI off.
    private func indicators(chinese: Bool) throws -> [HUDAIIndicator] {
        var all: [HUDAIIndicator] = try BuiltInPromptModes.all.map { mode in
            HUDAIIndicator(isEnabled: true, actionName: chinese ? try zh(mode.name, in: domain) : mode.name, shortcutBadge: "⌘0")
        }
        all.append(HUDAIIndicator(isEnabled: false, actionName: "Translate 2", shortcutBadge: "⌘0"))
        all.append(HUDAIIndicator(isEnabled: true))
        return all
    }

    func testEveryBuiltInNameAndStatusReadsInFullInBothStyles() throws {
        for style in HUDStyle.allCases {
            for chinese in [false, true] {
                for (title, clock) in try titles(chinese: chinese) {
                for ai in try indicators(chinese: chinese) {
                    let fit = HUDHeaderFit.resolve(
                        title: title, ai: ai, finishingBadge: nil, style: style, notchWidth: nil, clockText: clock
                    )
                    XCTAssertTrue(fit.titleFits, "\(style) “\(title)” truncated beside “\(ai.chipText)”")
                    XCTAssertNil(fit.chipMaxWidth, "\(style) “\(ai.chipText)” truncated beside “\(title)”")
                }
                }
            }
        }
    }

    func testTheShortcutGoesBeforeTheNameIsTruncated() {
        // The owner's case: 89 + 6 + 80 pt in a 174 pt row.
        let cleanUp = HUDAIIndicator(isEnabled: true, actionName: "Clean Up", shortcutBadge: "⌘1")
        let starting = HUDHeaderFit.resolve(
            title: "Starting mic…", ai: cleanUp, finishingBadge: nil, style: .mini, notchWidth: nil, clockText: "0:00"
        )
        XCTAssertFalse(starting.showsShortcut, "the ⌘-number is dropped first")
        XCTAssertNil(starting.chipMaxWidth, "and the name then fits whole")
        XCTAssertTrue(starting.titleFits)

        let recording = HUDHeaderFit.resolve(
            title: "Recording", ai: cleanUp, finishingBadge: nil, style: .mini, notchWidth: nil, clockText: "0:07"
        )
        XCTAssertTrue(recording.showsShortcut, "the design's “Clean Up ⌘1” where it fits")
        XCTAssertNil(recording.chipMaxWidth)

        let notch = HUDHeaderFit.resolve(
            title: "Starting mic…", ai: cleanUp, finishingBadge: nil, style: .notch, notchWidth: nil, clockText: "0:00"
        )
        XCTAssertTrue(notch.showsShortcut, "the notch is wider")
    }

    /// With a previous job finishing (the overlapping-jobs developer flag)
    /// the badge keeps its width and the AI chip gives way first; "Recording"
    /// stays whole beside every built-in name in both languages and both
    /// styles. (Mini cannot fit "Starting mic…", or the symbol chips "AI
    /// on" / "AI off", together with the badge and the title; there the
    /// chip shrinks first and the title loses the last few points —
    /// KNOWN_ISSUES.)
    func testTheFinishingBadgeKeepsTheRecordingTitleWhole() throws {
        for style in HUDStyle.allCases {
            for (badge, title, chinese) in [
                ("1 finishing", "Recording", false),
                (try zh("%lld finishing", in: ui).replacingOccurrences(of: "%lld", with: "1"), try zh("Recording", in: ui), true),
            ] {
                for ai in try indicators(chinese: chinese) where ai.chipSymbolName == nil {
                    let fit = HUDHeaderFit.resolve(
                        title: title, ai: ai, finishingBadge: badge, style: style, notchWidth: nil, clockText: "10:00"
                    )
                    XCTAssertTrue(fit.titleFits, "\(style) “\(title)” truncated beside “\(ai.chipText)” and the badge")
                }
            }
        }
    }

    func testALongCustomNameTruncatesTheChipNotTheTitle() {
        let long = HUDAIIndicator(isEnabled: true, actionName: "Rewrite for the quarterly investor newsletter", shortcutBadge: "⌘4")
        for style in HUDStyle.allCases {
            let fit = HUDHeaderFit.resolve(
                title: "Starting mic…", ai: long, finishingBadge: nil, style: style, notchWidth: nil, clockText: "0:00"
            )
            XCTAssertFalse(fit.showsShortcut, "\(style)")
            XCTAssertNotNil(fit.chipMaxWidth, "\(style): the chip takes the room that is left")
            XCTAssertTrue(fit.titleFits, "\(style)")
        }
    }

    func testNoChipLeavesTheRowAlone() {
        XCTAssertEqual(
            HUDHeaderFit.resolve(title: "Transcribing locally", ai: nil, finishingBadge: nil, style: .mini, notchWidth: nil, clockText: "0:00"),
            .unconstrained
        )
    }

    @MainActor
    func testTheGeometryMirrorsTheView() {
        XCTAssertEqual(HUDHeaderFit.miniPanelWidth, HUDView.panelWidth)
        XCTAssertEqual(HUDHeaderFit.notchPanelWidth, HUDView.notchPanelWidth)
        XCTAssertEqual(
            HUDHeaderFit.meterWidth,
            CGFloat(HUDMeter.peaks.count) * 3 + CGFloat(HUDMeter.peaks.count - 1) * 2
        )
        // 316 − 11 − 14 − 30 − 10 − 10 − (23 meter + 10 + 34 clock).
        XCTAssertEqual(HUDHeaderFit.rowWidth(style: .mini, notchWidth: nil, clockText: "0:00"), 174)
    }
}
