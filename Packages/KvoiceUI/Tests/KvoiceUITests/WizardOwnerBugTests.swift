import Foundation
import XCTest
@testable import KvoiceUI

/// Owner-reported wizard bugs (2026-10-21) at their seams.
@MainActor
final class WizardOwnerBugTests: XCTestCase {
    // MARK: Welcome hero bars

    /// The bars' pulse is a pure function of the clock (Wizard.dc
    /// `kvlevel`): .45 → 1 → .45 over 900 ms with the design's per-bar
    /// leads. It replaced a `repeatForever` animation that also animated
    /// the bars' positions and left them swinging left of their column.
    func testHeroBarsFollowTheDesignPulse() {
        XCTAssertEqual(HeroBarsMotion.heights.count, 7)
        // Bar 2 (index 1) has no lead: rest, peak, rest.
        XCTAssertEqual(HeroBarsMotion.scale(bar: 1, at: 0), 0.45, accuracy: 0.0001)
        XCTAssertEqual(HeroBarsMotion.scale(bar: 1, at: 0.45), 1, accuracy: 0.0001)
        XCTAssertEqual(HeroBarsMotion.scale(bar: 1, at: 0.9), 0.45, accuracy: 0.0001)
        // Leads: bars 1, 4, 7 run 600 ms ahead, bars 3, 6 run 300 ms ahead.
        XCTAssertEqual([0, 1, 2, 3, 4, 5, 6].map(HeroBarsMotion.lead(bar:)), [0.6, 0, 0.3, 0.6, 0, 0.3, 0.6])
        XCTAssertEqual(HeroBarsMotion.scale(bar: 0, at: 0.3), HeroBarsMotion.scale(bar: 1, at: 0.9), accuracy: 0.0001)
        XCTAssertEqual(HeroBarsMotion.scale(bar: 2, at: 0.15), 1, accuracy: 0.0001)
        // Always within the design's range, at any time.
        for step in 0..<200 {
            let time = 1_000_000 + Double(step) * 0.037
            for bar in 0..<7 {
                let scale = HeroBarsMotion.scale(bar: bar, at: time)
                XCTAssertGreaterThanOrEqual(scale, 0.45 - 0.0001)
                XCTAssertLessThanOrEqual(scale, 1 + 0.0001)
            }
        }
    }

    // MARK: Ready links after reopening

    /// Setup Guide… after Finish used to reopen the finished Ready page,
    /// where both links, Back, the test, Fix… and Finish were inert.
    /// Presenting a finished guide now starts it over, and the links work
    /// once it is back on Ready.
    func testPresentingAFinishedGuideStartsItOverAndTheLinksWork() async {
        var tours = 0
        var sections: [MainWindowSection] = []
        let model = OnboardingViewModel(stage: .ready)
        model.openTutorialHandler = { tours += 1 }
        model.openMainWindowHandler = { sections.append($0) }
        model.finishOnboarding()
        XCTAssertTrue(model.isFinished)
        model.openQuickTour()
        model.openAIActionsSetup()
        XCTAssertEqual(tours, 0, "the finished page's links are inert — the reported symptom")

        model.prepareForPresentation()
        XCTAssertEqual(model.stage, .welcome)
        XCTAssertFalse(model.isFinished)

        await model.performPrimaryAction()
        while model.stage != .ready {
            let before = model.stage
            model.performSkipAction()
            if model.stage == before { break }
        }
        XCTAssertEqual(model.stage, .ready)
        XCTAssertTrue(model.canGoBack)
        model.openQuickTour()
        model.openAIActionsSetup()
        XCTAssertEqual(tours, 1)
        XCTAssertEqual(sections, [.aiActions])
    }

    /// The other cause of the dead links: the setup window looked its app
    /// delegate up with `NSApp.delegate as? AppDelegate`, which is always
    /// nil under `@NSApplicationDelegateAdaptor` (`NSApp.delegate` is
    /// SwiftUI's adaptor), so the shell hooks — both links among them —
    /// were never installed. No app source may spell that cast again.
    func testTheAppNeverLooksItsDelegateUpThroughNSApp() throws {
        let apps = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KvoiceUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // KvoiceUI
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Apps")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: apps, includingPropertiesForKeys: nil))
        let sources = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(sources.isEmpty)
        XCTAssertTrue(
            try String(contentsOf: apps.appendingPathComponent("KvoiceApp/KvoiceApp.swift"), encoding: .utf8)
                .contains("@NSApplicationDelegateAdaptor"),
            "if the adaptor goes, revisit this rule"
        )
        let offenders = try sources.filter { url in
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            return code.range(of: #"\.delegate\s+as[?!]\s+AppDelegate"#, options: .regularExpression) != nil
        }
        XCTAssertEqual(offenders.map(\.lastPathComponent), [])
    }

    /// A guide closed mid-way keeps its place when shown again.
    func testPresentingAnUnfinishedGuideKeepsItsPlace() {
        let model = OnboardingViewModel(stage: .accessibility)
        model.prepareForPresentation()
        XCTAssertEqual(model.stage, .accessibility)
        let ready = OnboardingViewModel(stage: .ready)
        ready.prepareForPresentation()
        XCTAssertEqual(ready.stage, .ready)
    }
}
