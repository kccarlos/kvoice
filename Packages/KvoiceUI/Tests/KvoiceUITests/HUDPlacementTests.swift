import AppKit
import XCTest
import KvoiceDomain
@testable import KvoiceUI

/// ADR-021: the recorder styles. Placement is a pure function of screen
/// geometry, so each display shape is a fixture rather than a Mac.
@MainActor
final class HUDPlacementTests: XCTestCase {
    /// A 14" MacBook Pro-shaped display: 1512×982 points, a 37 pt housing
    /// (the menu bar is the same height there), auxiliary areas either side.
    /// The housing is drawn wider than the real one so the width rule has
    /// something to widen past.
    private let notched = HUDScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945),
        safeAreaTopInset: 37,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 945, width: 626, height: 37),
        auxiliaryTopRightArea: CGRect(x: 886, y: 945, width: 626, height: 37)
    )
    /// A plain built-in display with a 24 pt menu bar.
    private let plain = HUDScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876)
    )
    /// An external display to the right of the built-in one, with a 24 pt
    /// menu bar and a Dock on its left edge.
    private let external = HUDScreenGeometry(
        frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512 + 80, y: -200, width: 2560 - 80, height: 1440 - 24)
    )
    private let content = CGSize(width: 380, height: 72)

    // MARK: Geometry

    func testNotchIsTheGapBetweenTheAuxiliaryAreas() {
        XCTAssertEqual(notched.notch, CGRect(x: 626, y: 945, width: 260, height: 37))
        XCTAssertEqual(notched.menuBarHeight, 37)
        XCTAssertEqual(notched.topObstructionHeight, 37)
        XCTAssertNil(plain.notch)
        XCTAssertEqual(plain.topObstructionHeight, 24)
        XCTAssertEqual(external.topObstructionHeight, 24)
    }

    func testAHiddenMenuBarLeavesNoObstructionOnAPlainDisplay() {
        var fullScreen = plain
        fullScreen.visibleFrame = fullScreen.frame
        XCTAssertEqual(fullScreen.topObstructionHeight, 0)
        // The housing is physical; it stays even when the menu bar hides.
        var notchedFullScreen = notched
        notchedFullScreen.visibleFrame = notchedFullScreen.frame
        XCTAssertEqual(notchedFullScreen.topObstructionHeight, 37)
    }

    // MARK: Notch style

    func testNotchStyleHangsCentredUnderTheHousingWithoutTouchingTheMenuBar() {
        let width = HUDPlacement.notchContentWidth(minimum: HUDView.notchPanelWidth, screen: notched)
        XCTAssertEqual(width, 260 + 2 * HUDPlacement.notchSidePadding, "wider than the housing plus room for the meter and time")
        XCTAssertGreaterThan(width, HUDView.notchPanelWidth)
        let frame = HUDPlacement.frame(for: .notch, contentSize: CGSize(width: width, height: 44), screen: notched)

        XCTAssertEqual(frame.maxY, 945, "the top edge meets the bottom of the menu bar / housing")
        XCTAssertEqual(frame.midX, 756, "centred on the housing")
        XCTAssertEqual(frame.height, 44)
        XCTAssertLessThanOrEqual(frame.maxY, notched.frame.maxY - notched.menuBarHeight, "never over the menu bar")
    }

    func testNotchStyleFallsBackToTopCentreBelowTheMenuBarWithoutAHousing() {
        let width = HUDPlacement.notchContentWidth(minimum: HUDView.notchPanelWidth, screen: plain)
        XCTAssertEqual(width, HUDView.notchPanelWidth)
        let frame = HUDPlacement.frame(for: .notch, contentSize: CGSize(width: width, height: 44), screen: plain)
        XCTAssertEqual(frame.maxY, 876, "below the 24 pt menu bar")
        XCTAssertEqual(frame.midX, 720)
    }

    func testNotchStyleOnAnExternalDisplayUsesThatDisplaysMenuBarAndOrigin() {
        let frame = HUDPlacement.frame(for: .notch, contentSize: CGSize(width: 360, height: 44), screen: external)
        XCTAssertEqual(frame.maxY, -200 + 1440 - 24)
        XCTAssertEqual(frame.midX, 1512 + 1280, "centred on the display's own frame, not the Dock-reduced one")
        XCTAssertTrue(external.frame.contains(frame))
    }

    func testNotchStyleIsClampedInsideANarrowScreen() {
        let narrow = HUDScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 300, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 300, height: 576)
        )
        let frame = HUDPlacement.frame(for: .notch, contentSize: CGSize(width: 360, height: 44), screen: narrow)
        XCTAssertEqual(frame.minX, 0)
    }

    // MARK: Mini style (D.3, unchanged)

    func testMiniStyleKeepsTheDThreeGeometry() {
        let frame = HUDPlacement.frame(for: .mini, contentSize: content, screen: plain)
        XCTAssertEqual(frame.midX, 720)
        XCTAssertEqual(frame.minY, (876 * 0.22 - 72).rounded(), "bottom edge 22 % of the visible height above its bottom")
        XCTAssertEqual(frame.size, content)
    }

    func testMiniStyleIsClampedInsideTheVisibleFrame() {
        let short = HUDScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 200, height: 100),
            visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 80)
        )
        let frame = HUDPlacement.frame(for: .mini, contentSize: content, screen: short)
        XCTAssertEqual(frame.minX, HUDPlacement.miniInset)
        XCTAssertEqual(frame.minY, HUDPlacement.miniInset)
    }

    // MARK: Controller

    func testControllerLaysOutTheStyleItWasShownWithAndReRendersOnAStyleChange() {
        let controller = HUDController(announce: { _ in })
        let recording = HUDViewState(phase: .recording(HUDRecordingState(elapsed: .seconds(1))))
        controller.show(recording, style: .notch)
        XCTAssertEqual(controller.renderStyle, .notch)
        XCTAssertEqual(controller.renderCount, 1)
        let notchFrame = controller.panel?.frame
        XCTAssertNotNil(notchFrame)

        controller.show(recording, style: .notch)
        XCTAssertEqual(controller.renderCount, 1, "same state and style: no re-render")

        controller.show(recording, style: .mini)
        XCTAssertEqual(controller.renderStyle, .mini)
        XCTAssertEqual(controller.renderCount, 2, "a style change re-lays out even with the same state")
        XCTAssertNotEqual(controller.panel?.frame, notchFrame)
        controller.dismiss()
    }

    func testRecoverableTranscriptFailureTakesMiniPlacementEvenInNotchStyle() {
        let controller = HUDController(announce: { _ in })
        let failure = HUDViewState(
            phase: .failed(HUDFailureState(code: "insertion.failed", message: "Could not insert.")),
            recoverableTranscript: "the exact text"
        )
        controller.show(failure, style: .notch)
        XCTAssertEqual(HUDController.effectiveStyle(.notch, for: failure), .mini)
        XCTAssertEqual(controller.renderStyle, .notch, "the requested style is remembered for the change check")
        let frame = controller.panel!.frame
        let geometry = HUDController.geometry(of: controller.recordingScreen)
        let notchTop = geometry.frame.maxY - geometry.topObstructionHeight
        XCTAssertLessThan(frame.maxY, notchTop - 1, "not glued under the menu bar")
        XCTAssertEqual(frame.width, HUDView.recoveryPanelWidth, "the wide Mini recovery layout, with Mini geometry")
        XCTAssertEqual(frame, HUDPlacement.frame(for: .mini, contentSize: frame.size, screen: geometry))
        controller.dismiss()
    }
}
