import XCTest
@testable import KvoiceUI

/// Later waves: tutorial pages. Covers the standalone `TutorialViewModel`
/// (Help › Quick Tour, the existing-user banner, and the wizard's Ready
/// link since the six-step wizard of 2026-09-16 — the wizard no longer
/// embeds the tour as a stage; `OnboardingViewModelTests` covers the link).
@MainActor
final class TutorialViewModelTests: XCTestCase {
    // MARK: TutorialPage

    func testPagesAreThreeInOrderWithNoGaps() {
        XCTAssertEqual(TutorialPage.allCases, [.textDestination, .menuBar, .makeItYours])
        XCTAssertEqual(TutorialPage.textDestination.next, .menuBar)
        XCTAssertEqual(TutorialPage.menuBar.next, .makeItYours)
        XCTAssertNil(TutorialPage.makeItYours.next)
        XCTAssertNil(TutorialPage.textDestination.previous)
        XCTAssertEqual(TutorialPage.makeItYours.previous, .menuBar)
        for page in TutorialPage.allCases {
            XCTAssertFalse(page.title.isEmpty)
            XCTAssertFalse(page.body.isEmpty)
            XCTAssertFalse(page.symbolName.isEmpty)
        }
    }

    // MARK: Standalone TutorialViewModel (Help › Show Tutorial)

    func testNextWalksForwardAndFinishesAfterTheLastPage() {
        var finishedCount = 0
        let model = TutorialViewModel(onFinished: { finishedCount += 1 })

        XCTAssertEqual(model.page, .textDestination)
        XCTAssertTrue(model.isFirstPage)
        XCTAssertFalse(model.isLastPage)
        XCTAssertEqual(model.progressLabel, "Page 1 of 3")

        model.next()
        XCTAssertEqual(model.page, .menuBar)
        model.next()
        XCTAssertEqual(model.page, .makeItYours)
        XCTAssertTrue(model.isLastPage)
        XCTAssertEqual(finishedCount, 0)

        model.next()
        XCTAssertTrue(model.isFinished)
        XCTAssertEqual(finishedCount, 1)

        // Finished is terminal: nothing further moves the page or re-fires.
        model.next()
        XCTAssertEqual(finishedCount, 1)
    }

    func testBackWalksBackwardAndStopsAtTheFirstPage() {
        let model = TutorialViewModel(page: .makeItYours)
        model.back()
        XCTAssertEqual(model.page, .menuBar)
        model.back()
        XCTAssertEqual(model.page, .textDestination)
        model.back()
        XCTAssertEqual(model.page, .textDestination, "back is inert on the first page")
    }

    func testSkipFinishesImmediatelyFromAnyPage() {
        var finishedCount = 0
        let model = TutorialViewModel(page: .menuBar, onFinished: { finishedCount += 1 })
        model.skip()
        XCTAssertTrue(model.isFinished)
        XCTAssertEqual(finishedCount, 1)
    }

    func testOpenMainWindowForwardsToTheHandler() {
        var opened: [MainWindowSection] = []
        let model = TutorialViewModel(openMainWindowHandler: { opened.append($0) })
        model.openMainWindow(section: .dictionary)
        XCTAssertEqual(opened, [.dictionary])
    }

    /// `TutorialWindowController.show()` restarts the tour so reopening it
    /// never resumes mid-way through a previous viewing.
    func testRestartReturnsToTheFirstPageUnlessFinished() {
        let model = TutorialViewModel(page: .makeItYours)
        model.restart()
        XCTAssertEqual(model.page, .textDestination)

        let finished = TutorialViewModel(page: .makeItYours)
        finished.skip()
        finished.restart()
        XCTAssertEqual(finished.page, .makeItYours, "a finished tour is not reopened by restart()")
    }

    func testCustomizePointersCoverTheFourDestinationsFromTheSpec() {
        XCTAssertEqual(
            Set(TutorialCustomizePointer.all.map(\.id)),
            [.dictionary, .aiActions, .models, .audioInput]
        )
    }
}
