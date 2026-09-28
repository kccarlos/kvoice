import Foundation
import KvoiceDomain

/// The two turns `DictationController` hands out to runners (ADR-022 item
/// 7): the engine — one pass at a time, FIFO in job order — and insertion —
/// recording order, never interleaved, a retry waits for the insertion in
/// progress. With one job both are granted at once, so the single-job path
/// never suspends here. Waiters are `CheckedContinuation`s resumed by the
/// coordinator itself: on release, and with `false` when the waiting job
/// left the phase its turn was for (`abandonStaleWaiters`, from every
/// runner change), so a cancelled or quit job can never be left suspended.
/// Same actor as `DictationController.swift`.
extension DictationController {
    // MARK: - Engine turn (one pass at a time, in job order)

    /// Returns true when the job may use the engine; false when quitting has
    /// begun (`terminating`) or its wait was abandoned (the job was cancelled
    /// or quit while queued). Jobs reach `.transcribing` in recording order —
    /// only one records at a time — so FIFO arrival order is recording order.
    func acquireEngine(for jobID: JobID) async -> Bool {
        if terminating { return false }
        if engineHolder == nil, engineWaiters.isEmpty {
            engineHolder = jobID
            return true
        }
        return await withCheckedContinuation { continuation in
            engineWaiters.append((jobID, continuation))
        }
    }

    func releaseEngine(for jobID: JobID) {
        guard engineHolder == jobID else { return }
        engineHolder = nil
        grantEngineIfPossible()
    }

    /// Nothing is granted once quitting began (`terminating`). A job already
    /// queued stays queued until its own runner quits and leaves
    /// `.transcribing`, when `abandonStaleWaiters` resumes it with false; it
    /// is never turned into a new pass.
    func grantEngineIfPossible() {
        guard !terminating, engineHolder == nil, !engineWaiters.isEmpty else { return }
        let next = engineWaiters.removeFirst()
        engineHolder = next.jobID
        next.continuation.resume(returning: true)
    }

    // MARK: - Insertion turn (recording order, never interleaved)

    /// Returns true when the job may insert: nothing else is inserting and
    /// every older job is terminal or gone. A newer job whose AI finished
    /// first waits here; a retry of an older failed job waits for the
    /// insertion in progress. False when quitting has begun (`terminating`)
    /// or the wait was abandoned.
    func acquireInsertionTurn(for jobID: JobID) async -> Bool {
        if terminating { return false }
        if insertionHolder == nil, olderJobsDone(before: jobID) {
            insertionHolder = jobID
            return true
        }
        return await withCheckedContinuation { continuation in
            insertionWaiters.append((jobID, continuation))
        }
    }

    func releaseInsertionTurn(for jobID: JobID) {
        guard insertionHolder == jobID else { return }
        insertionHolder = nil
        grantInsertionIfPossible()
    }

    func grantInsertionIfPossible() {
        guard !terminating, insertionHolder == nil else { return }
        // Start order, not arrival order: the earliest job whose older jobs
        // are all done goes next.
        let ordered = insertionWaiters.enumerated().sorted { lhs, rhs in
            startIndex(of: lhs.element.jobID) < startIndex(of: rhs.element.jobID)
        }
        guard let next = ordered.first(where: { olderJobsDone(before: $0.element.jobID) }) else { return }
        insertionWaiters.remove(at: next.offset)
        insertionHolder = next.element.jobID
        next.element.continuation.resume(returning: true)
    }

    func startIndex(of jobID: JobID) -> Int {
        runners.firstIndex { $0.jobID == jobID } ?? Int.max
    }

    func olderJobsDone(before jobID: JobID) -> Bool {
        guard let index = runners.firstIndex(where: { $0.jobID == jobID }) else { return true }
        return runners[..<index].allSatisfy(\.isTerminal)
    }

    /// A queued job that left the phase its turn was for (Escape while
    /// transcribing, quit) is resumed with `false` so its task can end.
    func abandonStaleWaiters() {
        let stale = engineWaiters.filter { runner(for: $0.jobID)?.state.kind != .transcribing }
        engineWaiters.removeAll { waiter in stale.contains { $0.jobID == waiter.jobID } }
        for waiter in stale { waiter.continuation.resume(returning: false) }
        let staleInsertions = insertionWaiters.filter { runner(for: $0.jobID)?.state.kind != .inserting }
        insertionWaiters.removeAll { waiter in staleInsertions.contains { $0.jobID == waiter.jobID } }
        for waiter in staleInsertions { waiter.continuation.resume(returning: false) }
    }
}
