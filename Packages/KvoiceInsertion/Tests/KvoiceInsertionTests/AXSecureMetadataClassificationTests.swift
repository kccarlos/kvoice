import XCTest
@testable import KvoiceDomain
@testable import KvoiceInsertion

/// `AXSubrole` is optional in the Accessibility API. Requiring it classified
/// TextEdit's document area (AXRole=AXTextArea, no subrole) as `.unavailable`,
/// which failed closed and sent every dictation to the clipboard instead of the
/// caret. These pin both halves: the common case must be editable, and anything
/// ambiguous or secure must still fail closed.
final class AXSecureMetadataClassificationTests: XCTestCase {
    // MARK: The regression

    func testTextAreaWithoutASubroleIsEditable() {
        XCTAssertEqual(
            NativeAXElementClient.classify(role: "AXTextArea", subrole: nil),
            .notSecure,
            "TextEdit's document area reports no subrole and must be writable"
        )
    }

    func testKnownTextRolesWithoutASubroleAreEditable() {
        for role in ["AXTextField", "AXTextArea", "AXTextView", "AXSearchField", "AXComboBox", "AXWebArea"] {
            XCTAssertEqual(
                NativeAXElementClient.classify(role: role, subrole: nil),
                .notSecure,
                "\(role) with no subrole must be writable"
            )
        }
    }

    func testEmptySubroleIsTreatedAsAbsent() {
        XCTAssertEqual(
            NativeAXElementClient.classify(role: "AXTextArea", subrole: "   "),
            .notSecure
        )
    }

    // MARK: Security must still fail closed

    func testSecureTextFieldRoleIsSecureEvenWithoutASubrole() {
        XCTAssertEqual(
            NativeAXElementClient.classify(role: "AXSecureTextField", subrole: nil),
            .secure,
            "a password field must never be classified as writable"
        )
    }

    func testSecureSubrolesAreSecure() {
        for subrole in ["AXSecureTextField", "AXSecureTextFieldSubrole"] {
            XCTAssertEqual(
                NativeAXElementClient.classify(role: "AXTextField", subrole: subrole),
                .secure
            )
        }
    }

    func testMissingOrEmptyRoleIsUnavailable() {
        XCTAssertEqual(NativeAXElementClient.classify(role: nil, subrole: nil), .unavailable)
        XCTAssertEqual(NativeAXElementClient.classify(role: "", subrole: nil), .unavailable)
        XCTAssertEqual(NativeAXElementClient.classify(role: "  ", subrole: "AXTextArea"), .unavailable)
    }

    func testUnknownRoleIsUnavailable() {
        XCTAssertEqual(
            NativeAXElementClient.classify(role: "AXButton", subrole: nil),
            .unavailable,
            "a non-text control must not be written to"
        )
        XCTAssertEqual(
            NativeAXElementClient.classify(role: "AXUnknownThing", subrole: nil),
            .unavailable
        )
    }

    func testUnknownSubroleOnATextRoleIsUnavailable() {
        XCTAssertEqual(
            NativeAXElementClient.classify(role: "AXTextField", subrole: "AXSomethingNew"),
            .unavailable,
            "a present but unrecognised subrole stays ambiguous"
        )
    }

    // MARK: AXEnabled

    /// `AXEnabled` is optional too. Plain text areas generally omit it, and
    /// treating absence as "disabled" made them all `notEditable`.
    func testAbsentEnabledAttributeMeansEnabled() throws {
        XCTAssertTrue(
            try NativeAXElementClient.isEnabled(enabledAttribute: nil),
            "an element that does not publish AXEnabled is not disabled"
        )
    }

    func testExplicitEnabledValueIsHonoured() throws {
        XCTAssertTrue(try NativeAXElementClient.isEnabled(enabledAttribute: .boolean(true)))
        XCTAssertFalse(
            try NativeAXElementClient.isEnabled(enabledAttribute: .boolean(false)),
            "an explicitly disabled element must not be written to"
        )
    }

    func testNonBooleanEnabledValueIsRejected() {
        XCTAssertThrowsError(
            try NativeAXElementClient.isEnabled(enabledAttribute: .string("yes"))
        ) { error in
            XCTAssertEqual(error as? AXClientError, .unsupportedValue)
        }
    }

    func testRecognisedPairsRemainEditable() {
        let pairs = [
            ("AXTextField", "AXStandardTextField"),
            ("AXTextArea", "AXStandardTextArea"),
            ("AXSearchField", "AXSearchField"),
            ("AXComboBox", "AXComboBox"),
            ("AXWebArea", "AXWebArea")
        ]
        for (role, subrole) in pairs {
            XCTAssertEqual(
                NativeAXElementClient.classify(role: role, subrole: subrole),
                .notSecure,
                "\(role)/\(subrole) must remain writable"
            )
        }
    }
}
