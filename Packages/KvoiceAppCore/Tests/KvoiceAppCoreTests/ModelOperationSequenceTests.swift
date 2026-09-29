import KvoiceAppCore
import KvoiceDomain
import XCTest

/// 2026-09-29 (swift-reviewer): the shell never cancels the previous model
/// task — it may be the launch restore mid-compile — and a superseded
/// download is cancelled at the library before anything waits.
@MainActor
final class ModelOperationSequenceTests: XCTestCase {
    private final class Log {
        var steps: [String] = []
    }

    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            guard !open else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    /// A previous task that parks until released and records whether it
    /// saw a cancellation.
    private func parkedPrevious(_ gate: Gate, log: Log) -> Task<Void, Never> {
        Task { @MainActor in
            await gate.wait()
            log.steps.append(Task.isCancelled ? "previous:cancelled" : "previous:done")
        }
    }

    func testStartWaitsForThePreviousTaskWithoutCancellingIt() async {
        let log = Log()
        let gate = Gate()
        let previous = parkedPrevious(gate, log: log)
        let run = Task { @MainActor in
            await ModelOperationSequence.run(
                .start, downloadID: nil, previous: previous,
                cancelDownload: { _ in log.steps.append("cancel") },
                waitUntilIdle: { log.steps.append("idle") },
                body: { log.steps.append("body") }
            )
        }
        await Task.yield()
        XCTAssertEqual(log.steps, [], "the body waits its turn")
        await gate.release()
        await run.value
        XCTAssertEqual(log.steps, ["previous:done", "body"])
    }

    func testSupersedeCancelsOnlyTheDownloadThenWaitsForThePreviousAndIdle() async {
        let log = Log()
        let gate = Gate()
        let previous = parkedPrevious(gate, log: log)
        let run = Task { @MainActor in
            await ModelOperationSequence.run(
                .supersedeDownload, downloadID: "whisper", previous: previous,
                cancelDownload: { id in
                    log.steps.append("cancel:\(id)")
                    await gate.release()
                },
                waitUntilIdle: { log.steps.append("idle") },
                body: { log.steps.append("body") }
            )
        }
        await run.value
        XCTAssertEqual(log.steps, ["cancel:whisper", "previous:done", "idle", "body"])
        XCTAssertFalse(log.steps.contains("previous:cancelled"), "the previous task is never cancelled")
    }

    func testARefusalRunsNothing() async {
        let log = Log()
        await ModelOperationSequence.run(
            .refuse(.modelOptimizing), downloadID: "whisper", previous: nil,
            cancelDownload: { _ in log.steps.append("cancel") },
            waitUntilIdle: { log.steps.append("idle") },
            body: { log.steps.append("body") }
        )
        XCTAssertEqual(log.steps, [])
    }
}
