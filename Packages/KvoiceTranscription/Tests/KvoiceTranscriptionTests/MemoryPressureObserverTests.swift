import Dispatch
import XCTest
@testable import KvoiceTranscription
import KvoiceDomain

/// A fake `DispatchSourceMemoryPressure` the tests fire directly, since GCD
/// has no API to synthesize a real kernel memory-pressure note from inside a
/// test process (`SystemMemoryPressureObserver.swift`'s doc comment).
private final class FakeMemoryPressureDispatchSource: MemoryPressureDispatchSource {
    private(set) var event: DispatchSource.MemoryPressureEvent = []
    private(set) var activateCallCount = 0
    private(set) var cancelCallCount = 0
    private var handler: (() -> Void)?

    func setEventHandler(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func activate() { activateCallCount += 1 }
    func cancel() { cancelCallCount += 1 }

    func fire(_ event: DispatchSource.MemoryPressureEvent) {
        self.event = event
        handler?()
    }
}

final class MemoryPressureObserverTests: XCTestCase {
    // MARK: Level mapping

    func testLevelMapsEventBitsAndCriticalWinsOverWarning() {
        XCTAssertEqual(SystemMemoryPressureObserver.level(for: []), .normal)
        XCTAssertEqual(SystemMemoryPressureObserver.level(for: .normal), .normal)
        XCTAssertEqual(SystemMemoryPressureObserver.level(for: .warning), .warning)
        XCTAssertEqual(SystemMemoryPressureObserver.level(for: .critical), .critical)
        XCTAssertEqual(SystemMemoryPressureObserver.level(for: [.warning, .critical]), .critical)
    }

    // MARK: Adapter behind the fake source

    func testActivatesTheSourceOnceAndStartsAtNormal() async {
        let source = FakeMemoryPressureDispatchSource()
        let observer = SystemMemoryPressureObserver(source: source)

        XCTAssertEqual(source.activateCallCount, 1)
        let level = await observer.currentLevel
        XCTAssertEqual(level, .normal)
    }

    func testCurrentLevelFollowsEachFiredEvent() async {
        let source = FakeMemoryPressureDispatchSource()
        let observer = SystemMemoryPressureObserver(source: source)

        source.fire(.warning)
        var level = await observer.currentLevel
        XCTAssertEqual(level, .warning)

        source.fire(.critical)
        level = await observer.currentLevel
        XCTAssertEqual(level, .critical)

        source.fire(.normal)
        level = await observer.currentLevel
        XCTAssertEqual(level, .normal)
    }

    /// The stream delivers each distinct level once; a duplicate firing of
    /// the same bits (the kernel can re-notify without a real change) is
    /// swallowed rather than delivered twice.
    func testChangesStreamDeliversDistinctLevelsOnlyNoDuplicates() async {
        let source = FakeMemoryPressureDispatchSource()
        let observer = SystemMemoryPressureObserver(source: source)
        var iterator = observer.changes().makeAsyncIterator()

        source.fire(.warning)
        source.fire(.warning)
        source.fire(.critical)
        source.fire(.critical)
        source.fire(.normal)

        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()
        XCTAssertEqual(first, .warning)
        XCTAssertEqual(second, .critical)
        XCTAssertEqual(third, .normal)
    }

    func testEachSubscriberReceivesEveryChangeIndependently() async {
        let source = FakeMemoryPressureDispatchSource()
        let observer = SystemMemoryPressureObserver(source: source)
        var iteratorA = observer.changes().makeAsyncIterator()
        var iteratorB = observer.changes().makeAsyncIterator()

        source.fire(.critical)

        let a = await iteratorA.next()
        let b = await iteratorB.next()
        XCTAssertEqual(a, .critical)
        XCTAssertEqual(b, .critical)
    }

    func testDeinitCancelsTheSource() {
        let source = FakeMemoryPressureDispatchSource()
        var observer: SystemMemoryPressureObserver? = SystemMemoryPressureObserver(source: source)
        _ = observer
        observer = nil
        XCTAssertEqual(source.cancelCallCount, 1)
    }
}
