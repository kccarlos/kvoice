import KvoiceDomain

/// Records diagnostic events for adapters that emit them fire-and-forget
/// (`Task { await diagnostics.log(event) }`), so a test cannot await the
/// emission itself.
///
/// `events(named:count:)` parks until the expected events have arrived — no
/// polling budget that a loaded machine can exhaust. The ten-second bound is
/// a hang guard for a genuinely missing event, never reached on a pass.
/// `eventsAfterSettling(named:)` is for asserting that an event did *not*
/// happen: it gives stray emissions a short, bounded chance to land, which
/// can only make a negative assertion stricter.
public actor RecordingDiagnosticLog: DiagnosticLogging {
    private var recorded: [DiagnosticEvent] = []
    private var waiters: [(name: DiagnosticEventName, count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    public init() {}

    public func log(_ event: DiagnosticEvent) async {
        recorded.append(event)
        let ready = waiters.filter { matching($0.name) >= $0.count }
        waiters.removeAll { matching($0.name) >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    /// How many `events(named:count:)` calls are parked right now.
    public var pendingWaitCount: Int { waiters.count }

    /// Every event recorded so far, in arrival order.
    public var allEvents: [DiagnosticEvent] { recorded }

    /// Waits until at least `count` events named `name` were logged, then
    /// returns all of them.
    public func events(named name: DiagnosticEventName, count: Int = 1) async -> [DiagnosticEvent] {
        if matching(name) < count {
            let hangGuard = Task { [weak self] in
                // Cancelled once this wait is satisfied: it must then do
                // nothing, or it would release a later waiter early.
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                await self?.releaseWaiters()
            }
            await withCheckedContinuation { continuation in
                waiters.append((name, count, continuation))
            }
            hangGuard.cancel()
        }
        return recorded.filter { $0.name == name }
    }

    /// The events named `name` after a short settling window (20 yields and
    /// 5 ms sleeps, or less once one has arrived). For negative assertions.
    public func eventsAfterSettling(named name: DiagnosticEventName) async -> [DiagnosticEvent] {
        for _ in 0..<20 where matching(name) == 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return recorded.filter { $0.name == name }
    }

    private func matching(_ name: DiagnosticEventName) -> Int {
        recorded.lazy.filter { $0.name == name }.count
    }

    private func releaseWaiters() {
        let all = waiters
        waiters.removeAll()
        all.forEach { $0.continuation.resume() }
    }
}
