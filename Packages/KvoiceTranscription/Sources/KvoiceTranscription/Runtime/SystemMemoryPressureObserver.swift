import Dispatch
import Foundation
import KvoiceDomain

/// The subset of `DispatchSourceMemoryPressure` this file needs, so a fake
/// can drive `SystemMemoryPressureObserver` in tests. GCD's real source
/// cannot be made to report pressure from inside a test process (there is no
/// API to synthesize a kernel memory-pressure note), and the project's tests
/// stay deterministic (tests stay fast and deterministic) — so the mapping and
/// dedup logic below is exercised through this seam instead.
protocol MemoryPressureDispatchSource: AnyObject {
    /// The event bits as of the most recent firing.
    var event: DispatchSource.MemoryPressureEvent { get }
    func setEventHandler(_ handler: @escaping () -> Void)
    func activate()
    func cancel()
}

/// Wraps the real `DispatchSourceMemoryPressure` GCD creates. The only place
/// in the project that constructs one (rule 1) — see
/// `MemoryPressureObserving`'s doc comment (KvoiceDomain) for why system-wide
/// pressure, not this process's footprint, is the trigger.
///
/// The registered mask is `[.warning, .critical, .normal]`, not just
/// `[.warning, .critical]`: `DispatchSourceMemoryPressure` only delivers a
/// transition whose bit is part of the registered mask (confirmed against
/// Apple's docs and reference implementations — leaving `.normal` out is a
/// documented mistake that makes "pressure cleared" silently undetectable,
/// not merely unreported), and the shell's "back to normal clears the
/// banner" behavior needs that transition. `.warning`/`.critical` are still
/// the only levels this feature *acts* on; `.normal` exists solely so a
/// return to it is observable at all.
private final class SystemDispatchMemoryPressureSource: MemoryPressureDispatchSource {
    private let source: DispatchSourceMemoryPressure

    init(queue: DispatchQueue) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: queue)
    }

    var event: DispatchSource.MemoryPressureEvent { source.data }

    func setEventHandler(_ handler: @escaping () -> Void) {
        source.setEventHandler(handler: handler)
    }

    func activate() { source.activate() }
    func cancel() { source.cancel() }
}

/// `MemoryPressureObserving` over `DispatchSource.makeMemoryPressureSource`.
/// One instance is created at launch and lives for the process. `changes()`
/// supports multiple concurrent subscriptions (each call gets its own
/// `AsyncStream`), though today only `AppDelegate+Memory.swift` reads one
/// and fans the level out to a single shared `MemoryPressureViewModel` that
/// the status menu and the Runtime card's banner both read from.
public final class SystemMemoryPressureObserver: MemoryPressureObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var level: MemoryPressureLevel = .normal
    private var continuations: [UUID: AsyncStream<MemoryPressureLevel>.Continuation] = [:]
    private let dispatchSource: any MemoryPressureDispatchSource

    public convenience init() {
        self.init(source: SystemDispatchMemoryPressureSource(
            queue: DispatchQueue(label: "io.github.kccarlos.kvoice.memory-pressure")
        ))
    }

    /// Test seam: a fake source's stored handler is invoked directly by the
    /// test, bypassing the kernel entirely.
    init(source: any MemoryPressureDispatchSource) {
        dispatchSource = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.handle(self.dispatchSource.event)
        }
        source.activate()
    }

    deinit { dispatchSource.cancel() }

    public var currentLevel: MemoryPressureLevel {
        get async { readLevel() }
    }

    /// A plain synchronous function, not inlined into the async getter: GCD
    /// locks are flagged when locked/unlocked directly inside an `async`
    /// function body (priority-inversion risk), so the critical section
    /// lives in its own nonisolated function instead.
    private func readLevel() -> MemoryPressureLevel {
        lock.lock()
        defer { lock.unlock() }
        return level
    }

    public func changes() -> AsyncStream<MemoryPressureLevel> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    /// Maps the source's event bits to one level and broadcasts only on an
    /// actual change (de-duplicated consecutive values, per the protocol).
    func handle(_ event: DispatchSource.MemoryPressureEvent) {
        let newLevel = Self.level(for: event)
        lock.lock()
        guard newLevel != level else {
            lock.unlock()
            return
        }
        level = newLevel
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(newLevel)
        }
    }

    /// Critical wins when both bits are set (the kernel can coalesce a fast
    /// warning→critical climb into one delivery).
    static func level(for event: DispatchSource.MemoryPressureEvent) -> MemoryPressureLevel {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .warning }
        return .normal
    }
}
