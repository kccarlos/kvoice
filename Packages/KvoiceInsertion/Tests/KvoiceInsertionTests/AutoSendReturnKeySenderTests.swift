import Foundation
import XCTest
@testable import KvoiceDomain
@testable import KvoiceInsertion

/// Auto-send's Return key (opt-in): the same two safety rules as typed
/// insertion, and only ever a Return through the ADR-016 poster.
final class AutoSendReturnKeySenderTests: XCTestCase {
    private let target = TargetApplicationSnapshot(
        processIdentifier: 42,
        bundleIdentifier: "com.apple.TextEdit",
        localizedName: "TextEdit",
        capturedAt: Date(timeIntervalSince1970: 1)
    )

    func testReturnIsPostedToTheTargetPIDOnlyWhenTrustedAndStillFrontmost() async throws {
        let poster = ReturnRecordingPoster()
        let sender = AutoSendReturnKeySender(
            workspace: FixedFrontmost(pid: 42),
            trust: FixedTrust(trusted: true),
            poster: poster
        )
        try await sender.sendReturnKey(to: target, jobID: UUID())
        XCTAssertEqual(poster.returnPIDs, [42])
        XCTAssertTrue(poster.chunks.isEmpty, "the Return is a key event, not typed text")
    }

    func testUntrustedProcessNeverPosts() async {
        let poster = ReturnRecordingPoster()
        let sender = AutoSendReturnKeySender(
            workspace: FixedFrontmost(pid: 42),
            trust: FixedTrust(trusted: false),
            poster: poster
        )
        do {
            try await sender.sendReturnKey(to: target, jobID: UUID())
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AutoSendError, .accessibilityNotTrusted)
        }
        XCTAssertTrue(poster.returnPIDs.isEmpty)
    }

    func testTargetSwitchRefusesTheReturn() async {
        let poster = ReturnRecordingPoster()
        for frontmost in [FixedFrontmost(pid: 7), FixedFrontmost(pid: nil)] {
            let sender = AutoSendReturnKeySender(
                workspace: frontmost,
                trust: FixedTrust(trusted: true),
                poster: poster
            )
            do {
                try await sender.sendReturnKey(to: target, jobID: UUID())
                XCTFail("expected a refusal")
            } catch {
                XCTAssertEqual(error as? AutoSendError, .targetApplicationChanged)
            }
        }
        XCTAssertTrue(poster.returnPIDs.isEmpty)
    }

    func testDefaultReturnImplementationTypesACarriageReturn() throws {
        // A poster that only knows typed chunks still sends a Return, so a
        // test double or an alternate poster cannot silently drop auto-send.
        let poster = ChunkOnlyPoster()
        try poster.postReturnKey(to: 9)
        XCTAssertEqual(poster.chunks, [ChunkOnlyPoster.Posted(chunk: "\r", pid: 9)])
    }
}

private struct FixedFrontmost: FrontmostApplicationProviding {
    let pid: pid_t?

    func frontmostApplication() -> FrontmostApplicationSnapshot? {
        pid.map { FrontmostApplicationSnapshot(processIdentifier: $0, bundleIdentifier: "com.apple.TextEdit", localizedName: "TextEdit") }
    }
}

private struct FixedTrust: AccessibilityTrustProviding {
    let trusted: Bool
    func isTrusted(prompt _: Bool) -> Bool { trusted }
}

private final class ReturnRecordingPoster: KeyboardEventPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedReturns: [pid_t] = []
    private var storedChunks: [String] = []

    var returnPIDs: [pid_t] { lock.lock(); defer { lock.unlock() }; return storedReturns }
    var chunks: [String] { lock.lock(); defer { lock.unlock() }; return storedChunks }

    func postUnicodeChunk(_ chunk: String, to _: pid_t) throws {
        lock.lock(); storedChunks.append(chunk); lock.unlock()
    }

    func postReturnKey(to processIdentifier: pid_t) throws {
        lock.lock(); storedReturns.append(processIdentifier); lock.unlock()
    }
}

private final class ChunkOnlyPoster: KeyboardEventPosting, @unchecked Sendable {
    struct Posted: Equatable {
        let chunk: String
        let pid: pid_t
    }

    private let lock = NSLock()
    private var storage: [Posted] = []
    var chunks: [Posted] { lock.lock(); defer { lock.unlock() }; return storage }

    func postUnicodeChunk(_ chunk: String, to processIdentifier: pid_t) throws {
        lock.lock(); storage.append(Posted(chunk: chunk, pid: processIdentifier)); lock.unlock()
    }
}
