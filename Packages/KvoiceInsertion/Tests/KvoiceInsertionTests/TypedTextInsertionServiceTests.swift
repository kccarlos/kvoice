import Foundation
import XCTest
@testable import KvoiceDomain
@testable import KvoiceInsertion
import KvoiceTestSupport

/// ADR-026: the App Store edition's insertion — typed events only, no
/// Accessibility element, the clipboard only when typing is unavailable
/// before the first event, and never after it.
final class TypedTextInsertionServiceTests: XCTestCase {
    private let target = TargetApplicationSnapshot(
        processIdentifier: 42,
        bundleIdentifier: "com.apple.TextEdit",
        localizedName: "TextEdit",
        capturedAt: Date(timeIntervalSince1970: 1)
    )
    private static let textEdit = FrontmostApplicationSnapshot(
        processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit", localizedName: "TextEdit"
    )
    private static let notes = FrontmostApplicationSnapshot(
        processIdentifier: 43, bundleIdentifier: "com.apple.Notes", localizedName: "Notes"
    )

    private func makeService(
        frontmost: [FrontmostApplicationSnapshot?] = [textEdit],
        granted: Bool = true,
        secureInput: Bool = false,
        poster: TypedOnlyPoster = TypedOnlyPoster(),
        clipboard: TypedOnlyClipboard = TypedOnlyClipboard(),
        diagnostics: (any DiagnosticLogging)? = nil
    ) -> TypedTextInsertionService {
        TypedTextInsertionService(
            workspace: SequencedFrontmost(frontmost),
            access: FixedPostEventAccess(granted: granted),
            secureInput: FixedSecureInput(enabled: secureInput),
            keyPoster: poster,
            clipboard: clipboard,
            typedChunkPacing: .zero,
            diagnostics: diagnostics
        )
    }

    func testTypesSanitizedChunksToTheTargetPIDAndNeverTouchesTheClipboard() async throws {
        let poster = TypedOnlyPoster()
        let clipboard = TypedOnlyClipboard()
        let service = makeService(poster: poster, clipboard: clipboard)
        let text = "Hello\nworld\tthis is a longer sentence"
        let outcome = try await service.insert(text, into: target, jobID: UUID())
        XCTAssertEqual(outcome, .inserted(method: .typedKeyboardEvents))
        XCTAssertEqual(poster.chunks.joined(), "Hello world this is a longer sentence")
        XCTAssertTrue(poster.chunks.count > 1, "chunked at the ADR-016 limit")
        XCTAssertTrue(poster.chunks.allSatisfy { $0.utf16.count <= TypedTextChunker.maxUTF16UnitsPerChunk })
        XCTAssertEqual(Set(poster.pids), [42])
        XCTAssertEqual(clipboard.writes, [], "FR-AX-009: never the pasteboard on success")
    }

    func testWithoutThePostEventGrantItCopiesAndPostsNothing() async throws {
        let poster = TypedOnlyPoster()
        let clipboard = TypedOnlyClipboard()
        let diagnostics = RecordingDiagnosticLog()
        let service = makeService(granted: false, poster: poster, clipboard: clipboard, diagnostics: diagnostics)
        let outcome = try await service.insert("hi", into: target, jobID: UUID())
        XCTAssertEqual(outcome, .copiedToClipboard(reason: .permissionNotGranted))
        XCTAssertEqual(ClipboardFallbackReason.permissionNotGranted.errorCode, .permissionAccessibilityDenied,
                       "the same copy as a missing Accessibility grant")
        XCTAssertEqual(poster.chunks, [])
        XCTAssertEqual(clipboard.writes, ["hi"])
        let status = await diagnostics.events(named: .permissionAccessibilityStatus)
        XCTAssertEqual(status.first?.attributes.reason?.rawValue, "postEventNotGranted")
    }

    func testAnotherFrontmostAppIsAClipboardFallback() async throws {
        let poster = TypedOnlyPoster()
        let clipboard = TypedOnlyClipboard()
        let service = makeService(frontmost: [Self.notes], poster: poster, clipboard: clipboard)
        let outcome = try await service.insert("hi", into: target, jobID: UUID())
        XCTAssertEqual(outcome, .copiedToClipboard(reason: .targetApplicationChanged))
        XCTAssertEqual(poster.chunks, [])
    }

    /// Same PID, different bundle identifier (a PID reused after a quit):
    /// not the target.
    func testBundleIdentifierMustMatchToo() async throws {
        let reused = FrontmostApplicationSnapshot(processIdentifier: 42, bundleIdentifier: "com.example.Other", localizedName: "Other")
        let service = makeService(frontmost: [reused])
        let outcome = try await service.insert("hi", into: target, jobID: UUID())
        XCTAssertEqual(outcome, .copiedToClipboard(reason: .targetApplicationChanged))
    }

    func testNoFrontmostAppIsAClipboardFallback() async throws {
        let service = makeService(frontmost: [nil])
        let outcome = try await service.insert("hi", into: target, jobID: UUID())
        XCTAssertEqual(outcome, .copiedToClipboard(reason: .noFrontmostApplication))
    }

    /// The coarse secure-field refusal: while any process has Secure Event
    /// Input on (a focused password field), nothing is typed.
    func testSecureEventInputRefusesTyping() async throws {
        let poster = TypedOnlyPoster()
        let service = makeService(secureInput: true, poster: poster)
        let outcome = try await service.insert("hunter2", into: target, jobID: UUID())
        XCTAssertEqual(outcome, .copiedToClipboard(reason: .secureTarget))
        XCTAssertEqual(poster.chunks, [])
    }

    func testOversizedTextIsAClipboardFallback() async throws {
        let poster = TypedOnlyPoster()
        let service = makeService(poster: poster)
        let huge = String(repeating: "a", count: AXInsertionLimits.maxUTF16Units + 1)
        let outcome = try await service.insert(huge, into: target, jobID: UUID())
        XCTAssertEqual(outcome, .copiedToClipboard(reason: .textTooLarge))
        XCTAssertEqual(poster.chunks, [])
    }

    /// Focus moving to a password field mid-typing stops typing: Secure
    /// Event Input is re-read before every chunk after the first.
    func testSecureInputTurningOnMidTypingStopsWithoutACopy() async {
        let poster = TypedOnlyPoster()
        let clipboard = TypedOnlyClipboard()
        let service = TypedTextInsertionService(
            workspace: SequencedFrontmost([Self.textEdit]),
            access: FixedPostEventAccess(granted: true),
            secureInput: SequencedSecureInput([false, true]),
            keyPoster: poster,
            clipboard: clipboard,
            typedChunkPacing: .zero
        )
        do {
            _ = try await service.insert(String(repeating: "word ", count: 20), into: target, jobID: UUID())
            XCTFail("expected an uncertain insertion")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .accessibilityVerifyFailed)
            XCTAssertEqual(error.metadata.site?.rawValue, "secureEventInput")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(poster.chunks.count, 1)
        XCTAssertEqual(clipboard.writes, [])
    }

    /// Cancelled before the first event: a plain cancellation — nothing
    /// typed, the clipboard untouched.
    func testCancelledBeforeTheFirstChunkPostsNothingAndCopiesNothing() async {
        let poster = TypedOnlyPoster()
        let clipboard = TypedOnlyClipboard()
        let service = TypedTextInsertionService(
            workspace: CancellingFrontmost(Self.textEdit),
            access: FixedPostEventAccess(granted: true),
            secureInput: FixedSecureInput(enabled: false),
            keyPoster: poster,
            clipboard: clipboard,
            typedChunkPacing: .zero
        )
        let target = self.target
        let task = Task { try await service.insert("hello", into: target, jobID: UUID()) }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(poster.chunks, [])
        XCTAssertEqual(clipboard.writes, [])
    }

    /// Cancelled during the pacing sleep after the first event: uncertain,
    /// never a copy of text that is partly in the target already.
    func testCancelledDuringPacingAfterTheFirstChunkIsUncertain() async {
        let poster = TypedOnlyPoster(cancelOnFirstPost: true)
        let clipboard = TypedOnlyClipboard()
        let service = TypedTextInsertionService(
            workspace: SequencedFrontmost([Self.textEdit]),
            access: FixedPostEventAccess(granted: true),
            secureInput: FixedSecureInput(enabled: false),
            keyPoster: poster,
            clipboard: clipboard,
            // Long enough that only cancellation can end it.
            typedChunkPacing: .seconds(60)
        )
        let target = self.target
        let task = Task { try await service.insert(String(repeating: "word ", count: 20), into: target, jobID: UUID()) }
        do {
            _ = try await task.value
            XCTFail("expected an uncertain insertion")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .accessibilityVerifyFailed)
            XCTAssertEqual(error.metadata.site?.rawValue, "cancelledAfterMutation")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(poster.chunks.count, 1)
        XCTAssertEqual(clipboard.writes, [])
    }

    /// Focus leaving the target after the first event stops typing and is
    /// reported as uncertain — the partial text is never re-sent through
    /// the clipboard.
    func testTargetChangeAfterTheFirstChunkStopsTypingWithoutACopy() async {
        let poster = TypedOnlyPoster()
        let clipboard = TypedOnlyClipboard()
        let service = makeService(frontmost: [Self.textEdit, Self.notes], poster: poster, clipboard: clipboard)
        do {
            _ = try await service.insert(String(repeating: "word ", count: 20), into: target, jobID: UUID())
            XCTFail("expected an uncertain insertion")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .accessibilityVerifyFailed)
            XCTAssertEqual(error.metadata.site?.rawValue, "typedTargetChanged")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(poster.chunks.count, 1)
        XCTAssertEqual(clipboard.writes, [])
    }

    func testPosterFailureAfterTheFirstChunkIsUncertain() async {
        let poster = TypedOnlyPoster(failAt: 1)
        let clipboard = TypedOnlyClipboard()
        let service = makeService(poster: poster, clipboard: clipboard)
        do {
            _ = try await service.insert(String(repeating: "word ", count: 20), into: target, jobID: UUID())
            XCTFail("expected an uncertain insertion")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .accessibilityVerifyFailed)
            XCTAssertEqual(error.metadata.site?.rawValue, "typedPoster")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(clipboard.writes, [])
    }

    /// Reading another app's selection is Accessibility; the switch that
    /// turns typing off is held on by the settings page and ignored here.
    func testNoSelectionReadingAndTheTypingSwitchIsIgnored() async throws {
        let poster = TypedOnlyPoster()
        let service = makeService(poster: poster)
        let selection = await service.readFocusedSelection()
        XCTAssertNil(selection)
        service.setTypedInsertionEnabled(false)
        let outcome = try await service.insert("still typed", into: target, jobID: UUID())
        XCTAssertEqual(outcome, .inserted(method: .typedKeyboardEvents))
    }

    func testCaptureTargetIsTheFrontmostApplication() async {
        let service = makeService()
        let captured = await service.captureTargetApplication()
        XCTAssertEqual(captured?.processIdentifier, 42)
        XCTAssertEqual(captured?.bundleIdentifier, "com.apple.TextEdit")
    }

    func testDirectCopyWritesTheClipboardOnce() async throws {
        let clipboard = TypedOnlyClipboard()
        let service = makeService(clipboard: clipboard)
        try await service.copyToClipboard("copy me", jobID: UUID())
        XCTAssertEqual(clipboard.writes, ["copy me"])
    }

    func testCompletedInsertionLogsTheTypedStrategyOnly() async throws {
        let diagnostics = RecordingDiagnosticLog()
        let service = makeService(diagnostics: diagnostics)
        _ = try await service.insert("secret words", into: target, jobID: UUID())
        let completed = await diagnostics.events(named: .insertionCompleted)
        XCTAssertEqual(completed.first?.attributes.strategy, .typedKeyboardEvents)
        let encoded = try JSONEncoder().encode(completed.first?.attributes)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret"), "rule 3: scalars only")
    }

    /// ADR-022 item 9: a clipboard write that fails inside the fallback is
    /// the one `insertion.failed` line, naming the gate that fell back.
    func testFailedFallbackCopyIsLoggedOnceWithItsGate() async throws {
        let diagnostics = RecordingDiagnosticLog()
        let service = makeService(
            granted: false,
            clipboard: TypedOnlyClipboard(failure: KVoiceError(code: .clipboardWriteFailed)),
            diagnostics: diagnostics
        )
        do {
            _ = try await service.insert("copy me", into: target, jobID: UUID())
            XCTFail("expected the clipboard failure to propagate")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .clipboardWriteFailed)
        }
        let failed = await diagnostics.events(named: .insertionFailed)
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?.attributes.reason?.rawValue, "clipboardWriteFailed")
        XCTAssertEqual(failed.first?.attributes.site?.rawValue, "postEventNotGranted")
        let encoded = try JSONEncoder().encode(failed.first)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("copy me"))
    }

    // MARK: The PostEvent adapters

    func testPostEventTrustProviderPromptsOnlyWhenAsked() {
        let access = CountingPostEventAccess(granted: false)
        let trust = EventPostingTrustProvider(access: access)
        XCTAssertFalse(trust.isTrusted(prompt: false))
        XCTAssertEqual(access.requests, 0)
        XCTAssertFalse(trust.isTrusted(prompt: true))
        XCTAssertEqual(access.requests, 1)
    }

    func testPostEventPermissionAdapterPromptsOnlyWhenAsked() async {
        let access = CountingPostEventAccess(granted: true)
        let adapter = EventPostingPermissionAdapter(access: access)
        let refreshed = await adapter.isTrusted(prompt: false)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(access.requests, 0)
        _ = await adapter.isTrusted(prompt: true)
        XCTAssertEqual(access.requests, 1)
    }

    /// Auto-send's Return works in the App Store edition through the same
    /// PostEvent grant, not Accessibility trust.
    func testAutoSendUsesThePostEventGrantInTheAppStoreEdition() async throws {
        let poster = TypedOnlyPoster()
        let sender = AutoSendReturnKeySender(
            workspace: SequencedFrontmost([Self.textEdit]),
            trust: EventPostingTrustProvider(access: FixedPostEventAccess(granted: true)),
            poster: poster
        )
        try await sender.sendReturnKey(to: target, jobID: UUID())
        XCTAssertEqual(poster.returns, [42])
    }
}

// MARK: - Doubles

private final class SequencedFrontmost: FrontmostApplicationProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [FrontmostApplicationSnapshot?]

    init(_ snapshots: [FrontmostApplicationSnapshot?]) {
        self.snapshots = snapshots
    }

    /// Each call takes the next snapshot; the last one repeats.
    func frontmostApplication() -> FrontmostApplicationSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard !snapshots.isEmpty else { return nil }
        return snapshots.count == 1 ? snapshots[0] : snapshots.removeFirst()
    }
}

/// Cancels the task that asks — the first frontmost read happens inside
/// `insert`, before any event, so the cancellation lands deterministically.
private struct CancellingFrontmost: FrontmostApplicationProviding {
    let snapshot: FrontmostApplicationSnapshot
    init(_ snapshot: FrontmostApplicationSnapshot) { self.snapshot = snapshot }

    func frontmostApplication() -> FrontmostApplicationSnapshot? {
        withUnsafeCurrentTask { $0?.cancel() }
        return snapshot
    }
}

private final class SequencedSecureInput: SecureEventInputProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]
    init(_ values: [Bool]) { self.values = values }

    var isSecureEventInputEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return values.count == 1 ? values[0] : values.removeFirst()
    }
}

private struct FixedPostEventAccess: EventPostingAccessProviding {
    let granted: Bool
    func isGranted() -> Bool { granted }
    func request() -> Bool { granted }
}

private final class CountingPostEventAccess: EventPostingAccessProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let granted: Bool
    private var requestCount = 0

    init(granted: Bool) {
        self.granted = granted
    }

    var requests: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    func isGranted() -> Bool { granted }

    func request() -> Bool {
        lock.lock()
        requestCount += 1
        lock.unlock()
        return granted
    }
}

private struct FixedSecureInput: SecureEventInputProviding {
    let enabled: Bool
    var isSecureEventInputEnabled: Bool { enabled }
}

final class TypedOnlyPoster: KeyboardEventPosting, @unchecked Sendable {
    private let lock = NSLock()
    private let failAt: Int?
    private let cancelOnFirstPost: Bool
    private var posted: [(String, pid_t)] = []
    private var returnPIDs: [pid_t] = []

    init(failAt: Int? = nil, cancelOnFirstPost: Bool = false) {
        self.failAt = failAt
        self.cancelOnFirstPost = cancelOnFirstPost
    }

    var chunks: [String] {
        lock.lock()
        defer { lock.unlock() }
        return posted.map(\.0)
    }

    var pids: [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return posted.map(\.1)
    }

    var returns: [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return returnPIDs
    }

    func postUnicodeChunk(_ chunk: String, to processIdentifier: pid_t) throws {
        lock.lock()
        defer { lock.unlock() }
        if posted.count == failAt { throw TypedKeyboardEventError.eventCreationFailed }
        posted.append((chunk, processIdentifier))
        if cancelOnFirstPost, posted.count == 1 {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    func postReturnKey(to processIdentifier: pid_t) throws {
        lock.lock()
        defer { lock.unlock() }
        returnPIDs.append(processIdentifier)
    }
}

final class TypedOnlyClipboard: ClipboardWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private let failure: Error?

    init(failure: Error? = nil) {
        self.failure = failure
    }

    var writes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func write(_ text: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        storage.append(text)
    }
}

