import Foundation
import XCTest
import KvoiceDomain
@testable import KvoiceInsertion

/// Electron/Chromium apps (the reported case was the Claude desktop app,
/// 2026-09-14) publish no focused element until an assistive client sets
/// `AXManualAccessibility` / `AXEnhancedUserInterface` on their application
/// element. The resolver performs that handshake and polls briefly; a
/// native app that really has nothing focused still ends in
/// `noFocusedElement`.
final class AXTargetResolverHandshakeTests: XCTestCase {
    private let target = TargetApplicationSnapshot(
        processIdentifier: 4242,
        bundleIdentifier: "com.anthropic.claudefordesktop",
        localizedName: "Claude",
        capturedAt: Date(timeIntervalSince1970: 1)
    )

    func testElectronStyleAppResolvesAfterTheHandshake() throws {
        let client = HandshakeClient(processIdentifier: 4242, focusedAfterHandshake: true)
        let resolver = AXTargetResolver(
            workspace: Workspace(processIdentifier: 4242, bundleIdentifier: "com.anthropic.claudefordesktop"),
            axClient: client,
            focusRetryCount: 3,
            focusRetryDelay: .zero
        )

        let element = try resolver.resolveFocusedElement(for: target)

        XCTAssertEqual(element.identifier, "electron-textarea")
        XCTAssertEqual(client.handshakes, [4242])
        XCTAssertEqual(client.systemWideQueries, 1, "the handshake is only tried after the ordinary query is empty")
        XCTAssertGreaterThanOrEqual(client.applicationQueries, 2)
    }

    func testNativeAppWithNothingFocusedStillReportsNoFocusedElement() {
        let client = HandshakeClient(processIdentifier: 4242, focusedAfterHandshake: false)
        let resolver = AXTargetResolver(
            workspace: Workspace(processIdentifier: 4242, bundleIdentifier: "com.anthropic.claudefordesktop"),
            axClient: client,
            focusRetryCount: 3,
            focusRetryDelay: .zero
        )

        XCTAssertThrowsError(try resolver.resolveFocusedElement(for: target)) { error in
            XCTAssertEqual(error as? AXTargetResolutionError, .noFocusedElement)
        }
        XCTAssertEqual(client.handshakes, [4242])
        // Bounded: one pre-handshake pair plus the retries, never a spin.
        XCTAssertEqual(client.applicationQueries, 1 + 3)
    }

    func testANativeAppThatAnswersAtOnceNeverGetsTheHandshake() throws {
        let client = HandshakeClient(processIdentifier: 4242, focusedAfterHandshake: true)
        client.focusedImmediately = true
        let resolver = AXTargetResolver(
            workspace: Workspace(processIdentifier: 4242, bundleIdentifier: "com.anthropic.claudefordesktop"),
            axClient: client,
            focusRetryDelay: .zero
        )

        _ = try resolver.resolveFocusedElement(for: target)

        XCTAssertTrue(client.handshakes.isEmpty)
        XCTAssertEqual(client.applicationQueries, 0)
    }
}

private struct Workspace: FrontmostApplicationProviding {
    let processIdentifier: pid_t
    let bundleIdentifier: String

    func frontmostApplication() -> FrontmostApplicationSnapshot? {
        FrontmostApplicationSnapshot(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            localizedName: "Claude"
        )
    }
}

/// Models Chromium: the application-scoped query answers only after the
/// handshake; the system-wide one never does (it lags further behind).
private final class HandshakeClient: AXElementClient, @unchecked Sendable {
    private let lock = NSLock()
    private let processIdentifier: pid_t
    private let focusedAfterHandshake: Bool
    var focusedImmediately = false
    private(set) var handshakes: [pid_t] = []
    private(set) var systemWideQueries = 0
    private(set) var applicationQueries = 0

    init(processIdentifier: pid_t, focusedAfterHandshake: Bool) {
        self.processIdentifier = processIdentifier
        self.focusedAfterHandshake = focusedAfterHandshake
    }

    func focusedElement() throws -> AXElementHandle? {
        lock.lock(); defer { lock.unlock() }
        systemWideQueries += 1
        return focusedImmediately ? AXElementHandle(identifier: "native-field") : nil
    }

    func focusedElement(inApplication pid: pid_t) throws -> AXElementHandle? {
        lock.lock(); defer { lock.unlock() }
        applicationQueries += 1
        guard focusedAfterHandshake, handshakes.contains(pid) else { return nil }
        return AXElementHandle(identifier: "electron-textarea")
    }

    func enableAccessibility(inApplication pid: pid_t) throws {
        lock.lock(); defer { lock.unlock() }
        handshakes.append(pid)
    }

    func processIdentifier(of _: AXElementHandle) throws -> pid_t { processIdentifier }
    func isEnabled(_: AXElementHandle) throws -> Bool { true }
    func isSecure(_: AXElementHandle) throws -> Bool { false }
    func isAttributeSettable(_: AXAttribute, on _: AXElementHandle) throws -> Bool { true }
    func value(_: AXAttribute, of _: AXElementHandle) throws -> AXAttributeValue? { nil }
    func set(_: AXAttributeValue, for _: AXAttribute, on _: AXElementHandle) throws {}
}
