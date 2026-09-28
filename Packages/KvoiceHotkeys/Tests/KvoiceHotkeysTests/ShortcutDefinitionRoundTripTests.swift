import KeyboardShortcuts
import XCTest
@testable import KvoiceDomain
@testable import KvoiceHotkeys

/// `presentRecorder()` was a no-op, so the recommended Control-Shift-Space was
/// the only reachable shortcut. Recording now converts a vendor shortcut back
/// into a domain value, and that reverse mapping has to agree with the forward
/// one or a recorded shortcut would fail to register.
final class ShortcutDefinitionRoundTripTests: XCTestCase {
    func testRecommendedShortcutRoundTrips() throws {
        let definition = ShortcutDefinition(key: "space", modifiers: ["control", "shift"])

        let vendor = KeyboardShortcuts.Shortcut(.space, modifiers: [.control, .shift])
        let recovered = vendor.asShortcutDefinition()

        XCTAssertEqual(recovered.key, "space")
        XCTAssertEqual(Set(recovered.modifiers), Set(definition.modifiers))
    }

    func testModifiersUseCanonicalMacOSOrder() {
        let vendor = KeyboardShortcuts.Shortcut(
            .k,
            modifiers: [.command, .shift, .option, .control]
        )

        XCTAssertEqual(
            vendor.asShortcutDefinition().modifiers,
            ["control", "option", "shift", "command"]
        )
    }

    func testNamedKeysRoundTripThroughTheForwardMap() throws {
        let cases: [(KeyboardShortcuts.Key, String)] = [
            (.space, "space"),
            (.return, "return"),
            (.escape, "escape"),
            (.upArrow, "up"),
            (.downArrow, "down"),
            (.leftArrow, "left"),
            (.rightArrow, "right"),
            (.a, "a"),
            (.zero, "0"),
            (.f5, "f5"),
            (.comma, "comma")
        ]

        for (key, expectedName) in cases {
            let definition = KeyboardShortcuts.Shortcut(key, modifiers: [.control])
                .asShortcutDefinition()
            XCTAssertEqual(definition.key, expectedName, "unexpected name for \(key)")

            // The forward direction must accept what the reverse produced,
            // otherwise a recorded shortcut cannot be registered.
            let reencoded = try definition.asKeyboardShortcut()
            XCTAssertEqual(
                reencoded,
                KeyboardShortcuts.Shortcut(key, modifiers: [.control]),
                "round trip changed the shortcut for \(expectedName)"
            )
        }
    }

    func testRecordedShortcutWithoutAModifierIsRejectedByTheForwardMap() {
        // The recorder UI requires a modifier; this guards the contract.
        let definition = KeyboardShortcuts.Shortcut(.space, modifiers: [])
            .asShortcutDefinition()

        XCTAssertTrue(definition.modifiers.isEmpty)
        XCTAssertThrowsError(try definition.asKeyboardShortcut())
    }
}
