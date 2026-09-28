import Foundation
import XCTest
@testable import KvoiceInsertion

final class AccessibilityPermissionAdapterTests: XCTestCase {
    func testAdapterForwardsPromptFlagWithoutPromptingAtInitialization() async {
        let calls = PromptCalls()
        let adapter = SystemAccessibilityPermissionAdapter { prompt in
            calls.append(prompt)
            return prompt
        }

        XCTAssertEqual(calls.values, [])
        let refreshResult = await adapter.isTrusted(prompt: false)
        let promptResult = await adapter.isTrusted(prompt: true)
        XCTAssertFalse(refreshResult)
        XCTAssertTrue(promptResult)
        XCTAssertEqual(calls.values, [false, true])
    }

    func testBestEffortAccessibilitySettingsURLIsScopedToAccessibility() {
        let url = SystemAccessibilityPermissionAdapter.accessibilitySettingsURL

        XCTAssertEqual(url?.scheme, "x-apple.systempreferences")
        XCTAssertTrue(url?.absoluteString.contains("Privacy_Accessibility") == true)
    }
}

private final class PromptCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Bool) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
