import SwiftUI
import XCTest
import KvoiceDomain
@testable import KvoiceUI

/// UI v2 fidelity F2: the seams behind the drawn shell and Home — the
/// design glyph parser, the auto-fit grid, Home's padding clamp and compact
/// figures, the drawn sidebar's keyboard model, and the test-dictation sheet.
@MainActor
final class MainWindowFidelityTests: XCTestCase {
    // MARK: Design glyphs

    func testEveryDesignGlyphParsesInsideTheSixteenGrid() {
        for section in MainWindowSection.allCases {
            let box = KVDesignPath.parse(section.designGlyph).boundingRect
            XCTAssertFalse(box.isEmpty, "\(section)")
            XCTAssertGreaterThanOrEqual(box.minX, 1, "\(section)")
            XCTAssertGreaterThanOrEqual(box.minY, 1, "\(section)")
            XCTAssertLessThanOrEqual(box.maxX, 15, "\(section)")
            XCTAssertLessThanOrEqual(box.maxY, 15, "\(section)")
        }
    }

    func testArcsBecomeTheDesignsCircles() {
        // `M8 2.5a5.5 5.5 0 1 1 0 11 5.5 5.5 0 0 1 0-11z`: a 5.5 circle at 8,8.
        let box = KVDesignPath.parse("M8 2.5a5.5 5.5 0 1 1 0 11 5.5 5.5 0 0 1 0-11z").boundingRect
        XCTAssertEqual(box.minX, 2.5, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 13.5, accuracy: 0.01)
        XCTAssertEqual(box.minY, 2.5, accuracy: 0.01)
        XCTAssertEqual(box.maxY, 13.5, accuracy: 0.01)
    }

    func testRelativeAndImplicitCommandsFollowSVG() {
        // Implicit line-tos after M, then relative h and an absolute V.
        let box = KVDesignPath.parse("M2.5 7.5 8 3l5.5 4.5V13h-11z").boundingRect
        XCTAssertEqual(box, CGRect(x: 2.5, y: 3, width: 11, height: 10))
        XCTAssertTrue(KVDesignPath.parse("M1 1 Q 3 3").boundingRect.isEmpty, "unknown commands stop the parse")
    }

    // MARK: Layout

    func testAutoFitGridMatchesCSSAutoFit() {
        func columns(_ width: CGFloat) -> Int { KVAutoFitGrid.columns(width: width, minimum: 180, spacing: 12, count: 4) }
        XCTAssertEqual(columns(920), 4)
        XCTAssertEqual(columns(756), 4)
        XCTAssertEqual(columns(755), 3)
        XCTAssertEqual(columns(372), 2)
        XCTAssertEqual(columns(371), 1)
        XCTAssertEqual(columns(120), 1, "minmax(min(180px, 100%)) never overflows")
        XCTAssertEqual(KVAutoFitGrid.columns(width: 2_000, minimum: 180, spacing: 12, count: 4), 4, "auto-fit collapses empty tracks")
    }

    func testHomeSidePaddingClampsFourPercentOfTheWindow() {
        XCTAssertEqual(HomeLayout.sidePadding(windowWidth: 820), 33)
        XCTAssertEqual(HomeLayout.sidePadding(windowWidth: 960), 38)
        XCTAssertEqual(HomeLayout.sidePadding(windowWidth: 1_280), 48)
        XCTAssertEqual(HomeLayout.sidePadding(windowWidth: 1_600), 48)
        XCTAssertEqual(HomeLayout.sidePadding(windowWidth: 300), 16)
    }

    func testHomeFiguresUseTheDesignsCompactDuration() {
        XCTAssertEqual(HomeSummary.compactDuration(0), "0s")
        XCTAssertEqual(HomeSummary.compactDuration(45.4), "45s")
        XCTAssertEqual(HomeSummary.compactDuration(31 * 60), "31m")
        XCTAssertEqual(HomeSummary.compactDuration(2 * 3_600 + 31 * 60 + 20), "2h 31m")
    }

    func testOnlyHomeHidesThePageHeader() {
        XCTAssertEqual(MainWindowSection.allCases.filter { !$0.showsPageHeader }, [.home])
    }

    // MARK: Drawn sidebar keyboard model

    func testArrowKeysWalkTheSidebarInOrderAndStopAtTheEnds() {
        let order = MainWindowSectionGroup.allCases.flatMap(\.sections)
        XCTAssertEqual(MainWindowSection.sidebarNeighbour(of: order[0], step: 1), order[1])
        XCTAssertEqual(MainWindowSection.sidebarNeighbour(of: order[0], step: -1), order[0])
        XCTAssertEqual(MainWindowSection.sidebarNeighbour(of: order[order.count - 1], step: 1), order[order.count - 1])
        // Across a group boundary: History → Shortcuts.
        XCTAssertEqual(MainWindowSection.sidebarNeighbour(of: .history, step: 1), .shortcuts)
    }

    func testTypeToSelectCyclesOneLetterAndMatchesPrefixes() {
        // "S…": Shortcuts, Speech Models, then back.
        XCTAssertEqual(MainWindowSection.typeSelect("s", from: .home), .shortcuts)
        XCTAssertEqual(MainWindowSection.typeSelect("s", from: .shortcuts), .models)
        XCTAssertEqual(MainWindowSection.typeSelect("s", from: .models), .shortcuts)
        XCTAssertEqual(MainWindowSection.typeSelect("sp", from: .shortcuts), .models)
        XCTAssertEqual(MainWindowSection.typeSelect("HIST", from: .home), .history)
        XCTAssertNil(MainWindowSection.typeSelect("zz", from: .home))
    }

    // MARK: Test dictation sheet

    func testTestDictationRunsFromStartToResult() {
        let model = HomeTestDictationModel()
        var stops = 0
        model.onStart = { true }
        model.onStop = { stops += 1 }
        model.present()
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.phase, .ready)
        model.start()
        XCTAssertEqual(model.phase, .starting)
        XCTAssertTrue(model.ownsTest)
        model.setRecording(true)
        XCTAssertEqual(model.phase, .recording)
        model.stop()
        XCTAssertEqual(model.phase, .finishing)
        XCTAssertEqual(stops, 1)
        model.finish(.transcript("  Hello there. "))
        XCTAssertEqual(model.phase, .result("Hello there."))
        XCTAssertFalse(model.ownsTest)
    }

    func testTestDictationExplainsWhyItCannotRun() {
        let model = HomeTestDictationModel()
        model.onStart = { false }
        model.present()
        model.start()
        guard case .failed = model.phase else { return XCTFail("\(model.phase)") }
        let empty = HomeTestDictationModel()
        empty.onStart = { true }
        empty.present()
        empty.start()
        empty.finish(.transcript("   "))
        guard case .failed = empty.phase else { return XCTFail("\(empty.phase)") }
        let noMic = HomeTestDictationModel()
        noMic.onStart = { true }
        noMic.present()
        noMic.start()
        noMic.startDidFail()
        guard case .failed = noMic.phase else { return XCTFail("\(noMic.phase)") }
    }

    func testClosingTheSheetCancelsATestInFlightAndIgnoresItsResult() {
        let model = HomeTestDictationModel()
        var cancels = 0
        model.onStart = { true }
        model.onCancel = { cancels += 1 }
        model.present()
        model.start()
        model.setRecording(true)
        model.dismiss()
        XCTAssertEqual(cancels, 1)
        XCTAssertFalse(model.isPresented)
        model.finish(.transcript("late"))
        XCTAssertEqual(model.phase, .ready, "a result after closing is dropped")
        // Closing an idle sheet cancels nothing; Escape (nil) returns to ready.
        model.present()
        model.dismiss()
        XCTAssertEqual(cancels, 1)
        model.present()
        model.start()
        model.finish(nil)
        XCTAssertEqual(model.phase, .ready)
    }

    func testRecordingIsIgnoredUnlessTheSheetStartedIt() {
        let model = HomeTestDictationModel()
        model.setRecording(true)
        XCTAssertEqual(model.phase, .ready, "a normal dictation never flips the sheet")
    }
}
