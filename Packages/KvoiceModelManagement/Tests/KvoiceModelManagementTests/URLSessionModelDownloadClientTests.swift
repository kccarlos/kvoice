import Foundation
import KvoiceModelManagement
import XCTest

/// 2026-09-16 slice-4 review: `download(_:)` must honour Swift task
/// cancellation, not just the client's own `cancel()`. The shell awaits a
/// cancelled model task before beginning the next one, so a transfer that
/// only unwound when its file finished would hold the next Download for
/// minutes on a slow link.
final class URLSessionModelDownloadClientTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        temporaryURLs.removeAll()
        StallingURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> URLSessionModelDownloadClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StallingURLProtocol.self]
        return URLSessionModelDownloadClient(configuration: configuration)
    }

    private func destination() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvoice-download-\(UUID().uuidString)", isDirectory: true)
        temporaryURLs.append(directory)
        return directory.appendingPathComponent("file.bin")
    }

    func testCancellingTheTaskMidTransferThrowsCancellationErrorPromptly() async throws {
        let client = makeClient()
        let destination = destination()
        let task = Task {
            try await client.download(
                from: URL(string: "https://stall.invalid/model.bin")!,
                to: destination,
                resumeData: nil,
                progress: { _, _ in }
            )
        }
        // Provably in flight: the stub has been asked to load and is holding.
        try await waitUntilTrue { StallingURLProtocol.startedCount == 1 }

        let cancelledAt = ContinuousClock.now
        task.cancel()
        do {
            try await task.value
            XCTFail("a cancelled download must throw")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - cancelledAt, .seconds(2), "must not wait for the transfer")
        try await waitUntilTrue { StallingURLProtocol.stoppedCount == 1 }

        // The client is reusable afterwards: a second download starts a new
        // transfer (the `activeTask == nil` precondition holds).
        let second = Task {
            try await client.download(
                from: URL(string: "https://stall.invalid/second.bin")!,
                to: destination,
                resumeData: nil,
                progress: { _, _ in }
            )
        }
        try await waitUntilTrue { StallingURLProtocol.startedCount == 2 }
        second.cancel()
        _ = try? await second.value
    }

    func testATaskCancelledBeforeEntryThrowsWithoutStartingATransfer() async throws {
        let client = makeClient()
        let destination = destination()
        let task = Task {
            // Cancel before the body reaches `download`, so the handler runs
            // before the URLSession task exists.
            withUnsafeCurrentTask { $0?.cancel() }
            try await client.download(
                from: URL(string: "https://stall.invalid/model.bin")!,
                to: destination,
                resumeData: nil,
                progress: { _, _ in }
            )
        }
        do {
            try await task.value
            XCTFail("must throw")
        } catch is CancellationError {}
        XCTAssertEqual(StallingURLProtocol.startedCount, 0, "no transfer was created")
    }
}

/// Accepts every request and never answers, so a download is provably in
/// flight until it is cancelled.
private final class StallingURLProtocol: URLProtocol {
    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0
        private var stopped = 0
        var startedCount: Int { lock.withLock { started } }
        var stoppedCount: Int { lock.withLock { stopped } }
        func recordStart() { lock.withLock { started += 1 } }
        func recordStop() { lock.withLock { stopped += 1 } }
        func reset() { lock.withLock { started = 0; stopped = 0 } }
    }

    private static let counters = Counters()

    static var startedCount: Int { counters.startedCount }
    static var stoppedCount: Int { counters.stoppedCount }
    static func reset() { counters.reset() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() { Self.counters.recordStart() }
    override func stopLoading() { Self.counters.recordStop() }
}
