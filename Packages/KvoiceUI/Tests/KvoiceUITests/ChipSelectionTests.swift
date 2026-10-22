import AppKit
import XCTest
import KvoiceDomain
@testable import KvoiceUI

/// Q3 leftover (b): the Dictionary's chips select several terms again
/// (⌘-click, ⇧-click, ⌘A) and Delete removes them together, as the
/// pre-UI-v2 table did.
final class ChipSelectionTests: XCTestCase {
    private let order = ["a", "b", "c", "d", "e"]

    func testPlainClickSelectsOnlyThatChip() {
        var selection = ChipSelection<String>()
        selection.click("b", .plain, order: order)
        selection.click("d", .plain, order: order)
        XCTAssertEqual(selection.ids, ["d"])
        XCTAssertEqual(selection.anchor, "d")
    }

    func testCommandClickTogglesAndKeepsTheRest() {
        var selection = ChipSelection<String>()
        selection.click("a", .plain, order: order)
        selection.click("c", .toggle, order: order)
        selection.click("e", .toggle, order: order)
        XCTAssertEqual(selection.ids, ["a", "c", "e"])
        selection.click("c", .toggle, order: order)
        XCTAssertEqual(selection.ids, ["a", "e"])
    }

    func testShiftClickSelectsTheRangeFromTheAnchorInDisplayOrder() {
        var selection = ChipSelection<String>()
        selection.click("d", .plain, order: order)
        selection.click("b", .extend, order: order)
        XCTAssertEqual(selection.ids, ["b", "c", "d"])
        // The anchor stays, so a second ⇧-click re-draws the range from it.
        selection.click("e", .extend, order: order)
        XCTAssertEqual(selection.ids, ["d", "e"])
    }

    func testShiftClickWithoutAnAnchorIsAPlainClick() {
        var selection = ChipSelection<String>()
        selection.click("c", .extend, order: order)
        XCTAssertEqual(selection.ids, ["c"])
    }

    func testSelectAllClearAndDroppedIDs() {
        var selection = ChipSelection<String>()
        selection.selectAll(order)
        XCTAssertEqual(selection.count, 5)
        selection.keep(only: ["a", "b"])
        XCTAssertEqual(selection.ids, ["a", "b"])
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.anchor)
    }

    func testDeleteRemovesTheSelectionOnlyWhenTheFocusedChipIsInIt() {
        var selection = ChipSelection<String>()
        selection.click("a", .plain, order: order)
        selection.click("b", .toggle, order: order)
        XCTAssertEqual(selection.removalTargets(focused: "b"), ["a", "b"])
        XCTAssertEqual(selection.removalTargets(focused: "e"), ["e"])
        XCTAssertEqual(selection.removalTargets(focused: nil), ["a", "b"])
        XCTAssertEqual(ChipSelection<String>().removalTargets(focused: "c"), ["c"])
    }

    @MainActor
    func testModifierKeysMapToTheClickKinds() {
        XCTAssertEqual(DictionaryChipClick.kind(for: []), ChipSelection<DictionaryEntry.ID>.Click.plain)
        XCTAssertEqual(DictionaryChipClick.kind(for: [.command]), .toggle)
        XCTAssertEqual(DictionaryChipClick.kind(for: [.shift]), .extend)
        XCTAssertEqual(DictionaryChipClick.kind(for: [.option]), .plain)
    }
}
