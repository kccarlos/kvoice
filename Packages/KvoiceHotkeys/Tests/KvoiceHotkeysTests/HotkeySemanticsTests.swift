import AppKit
import KeyboardShortcuts
import XCTest
@testable import KvoiceDomain
@testable import KvoiceHotkeys

@MainActor
final class HotkeySemanticsTests: XCTestCase {
    func testPushToTalkSuppressesRepeatsAndUnmatchedRelease() {
        var reducer = HotkeyEdgeReducer()
        let mode = RecordingInteraction.pushToTalk

        XCTAssertEqual(reducer.consume(.keyDown, mode: mode, isRecording: false), .start)
        XCTAssertEqual(
            reducer.consume(.keyDown, mode: mode, isRecording: true),
            .ignored(.repeatedKeyDown)
        )
        XCTAssertEqual(reducer.consume(.keyUp, mode: mode, isRecording: true), .stop)
        XCTAssertEqual(
            reducer.consume(.keyUp, mode: mode, isRecording: false),
            .ignored(.unmatchedKeyUp)
        )
        XCTAssertFalse(reducer.isPhysicalKeyDown)
    }

    func testToggleChangesStateOnKeyDownOnly() {
        var reducer = HotkeyEdgeReducer()
        let mode = RecordingInteraction.toggle

        XCTAssertEqual(reducer.consume(.keyDown, mode: mode, isRecording: false), .start)
        XCTAssertEqual(
            reducer.consume(.keyDown, mode: mode, isRecording: true),
            .ignored(.repeatedKeyDown)
        )
        XCTAssertEqual(
            reducer.consume(.keyUp, mode: mode, isRecording: true),
            .ignored(.toggleKeyUp)
        )
        XCTAssertEqual(reducer.consume(.keyDown, mode: mode, isRecording: true), .stop)
    }

    func testWatchdogStopsOnDisplaySleepAndDoesNotFireAfterExpectedRelease() {
        var reasons: [KeyStateWatchdogStopReason] = []
        let watchdog = KeyStateWatchdog(
            maximumDuration: .seconds(60),
            onForcedStop: { reasons.append($0) }
        )

        watchdog.arm()
        watchdog.displayWillSleep()
        XCTAssertEqual(reasons, [.displaySleep])
        XCTAssertFalse(watchdog.isArmed)

        watchdog.arm()
        watchdog.keyUpReceived()
        watchdog.applicationDidResignActive()
        XCTAssertEqual(reasons, [.displaySleep])
    }

    func testWatchdogMaximumDurationForcesAKeyUp() async {
        let expectation = expectation(description: "watchdog timeout")
        let watchdog = KeyStateWatchdog(
            maximumDuration: .seconds(1),
            sleep: { _ in },
            onForcedStop: { reason in
                XCTAssertEqual(reason, .maximumDuration)
                expectation.fulfill()
            }
        )

        watchdog.arm()
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertFalse(watchdog.isArmed)
    }

    func testAdapterEmitsOneSemanticDownUpForRepeatedCarbonEvents() throws {
        let backend = FakeRegistrationBackend()
        let adapter = KeyboardShortcutsAdapter(
            backend: backend,
            maximumHoldDuration: .seconds(60)
        )
        var events: [ShortcutEvent] = []

        try adapter.register(
            ShortcutDefinition(key: "space", modifiers: ["control"])
        ) { events.append($0) }

        backend.emitKeyDown()
        backend.emitKeyDown()
        backend.emitKeyUp()
        backend.emitKeyUp()

        XCTAssertEqual(events, [.keyDown, .keyUp])
        XCTAssertEqual(adapter.registrationState, .registered(
            ShortcutDefinition(key: "space", modifiers: ["control"])
        ))
    }

    /// Regression: the adapter's default sleep. The default-argument function
    /// value (a closure literal, then `KeyStateWatchdog.systemSleep`) produced a
    /// task that aborted in `swift_task_alloc`/`swift_task_dealloc` as soon as
    /// the watchdog armed; the default is now resolved inside the init.
    /// Passes an explicit hold duration so the sleep is long and the test
    /// never waits on it.
    func testAdapterDefaultSleepArmsAndDisarmsWithoutCrashing() throws {
        let backend = FakeRegistrationBackend()
        let adapter = KeyboardShortcutsAdapter(
            backend: backend,
            maximumHoldDuration: .seconds(60)
        )
        var events: [ShortcutEvent] = []

        try adapter.register(
            ShortcutDefinition(key: "space", modifiers: ["control"])
        ) { events.append($0) }

        backend.emitKeyDown()
        XCTAssertTrue(adapter.physicalKeyIsDown)
        adapter.unregister()
        XCTAssertEqual(events, [.keyDown, .keyUp])
        XCTAssertFalse(adapter.physicalKeyIsDown)
    }

    func testFailedRebindRestoresPriorShortcut() throws {
        let backend = FakeRegistrationBackend()
        let adapter = KeyboardShortcutsAdapter(backend: backend)
        let original = ShortcutDefinition(key: "space", modifiers: ["control"])
        let replacement = ShortcutDefinition(key: "d", modifiers: ["command", "shift"])

        try adapter.register(original) { _ in }
        backend.nextRegistrationError = .applicationConflict

        XCTAssertThrowsError(try adapter.register(replacement) { _ in }) { error in
            XCTAssertEqual(error as? HotkeyAdapterError, .applicationConflict)
        }
        XCTAssertEqual(adapter.registeredShortcut, original)
        XCTAssertEqual(adapter.registrationState, .registered(original))
        XCTAssertEqual(backend.registeredShortcut, original.asTestShortcut)
    }

    func testRecorderModelKeepsPriorBindingOnConflictAndClearsExplicitly() throws {
        let backend = FakeRegistrationBackend()
        let adapter = KeyboardShortcutsAdapter(backend: backend)
        let model = HotkeyRecorderModel(service: adapter)
        let original = ShortcutDefinition(key: "space", modifiers: ["control"])
        let replacement = ShortcutDefinition(key: "d", modifiers: ["command", "shift"])

        XCTAssertEqual(model.setShortcut(original), .registered(original))
        backend.nextRegistrationError = .applicationConflict
        XCTAssertEqual(
            model.setShortcut(replacement),
            .rejected(.applicationConflict)
        )
        XCTAssertEqual(model.shortcut, original)
        XCTAssertEqual(model.registrationState, .registered(original))
        XCTAssertEqual(model.feedback, .conflict)

        model.clearShortcut()
        XCTAssertNil(model.shortcut)
        XCTAssertEqual(model.registrationState, .unregistered)
        XCTAssertEqual(model.feedback, .cleared)
    }

    func testRecorderModelRejectsChangesWhileAJobIsActive() {
        let adapter = KeyboardShortcutsAdapter(backend: FakeRegistrationBackend())
        let model = HotkeyRecorderModel(service: adapter)
        let shortcut = ShortcutDefinition(key: "space", modifiers: ["control"])

        model.setJobActive(true)
        XCTAssertEqual(model.setShortcut(shortcut), .rejected(.busy))
        XCTAssertNil(model.shortcut)
        XCTAssertEqual(model.registrationState, .unregistered)

        model.setJobActive(false)
        XCTAssertEqual(model.setShortcut(shortcut), .registered(shortcut))
    }

    func testEscapePredicateAcceptsOnlyHardwareEscapeWithoutRepeat() {
        XCTAssertTrue(ActiveJobEscapeMonitor.accepts(keyCode: 53))
        XCTAssertFalse(ActiveJobEscapeMonitor.accepts(keyCode: 53, isRepeat: true))
        XCTAssertFalse(ActiveJobEscapeMonitor.accepts(keyCode: 49))
    }

    func testEscapeMonitorReportsActiveWhenBothObserversRegister() {
        let factory = FakeEscapeMonitorFactory(localToken: NSObject(), globalToken: NSObject())
        let monitor = ActiveJobEscapeMonitor(factory: factory)

        XCTAssertEqual(monitor.start {}, .active)
        XCTAssertEqual(monitor.status, .active)
        XCTAssertTrue(monitor.isActive)
    }

    func testEscapeMonitorReportsDegradedWhenLocalObserverRegistrationFails() {
        let factory = FakeEscapeMonitorFactory(localToken: nil, globalToken: NSObject())
        let monitor = ActiveJobEscapeMonitor(factory: factory)

        XCTAssertEqual(monitor.start {}, .degraded)
        XCTAssertEqual(monitor.status, .degraded)
        XCTAssertFalse(monitor.isActive)
    }

    func testEscapeMonitorReportsDegradedWhenGlobalObserverRegistrationFails() {
        let factory = FakeEscapeMonitorFactory(localToken: NSObject(), globalToken: nil)
        let monitor = ActiveJobEscapeMonitor(factory: factory)

        XCTAssertEqual(monitor.start {}, .degraded)
        XCTAssertEqual(monitor.status, .degraded)
        XCTAssertFalse(monitor.isActive)
    }

    func testEscapeMonitorReportsInactiveWhenBothObserverRegistrationsFail() {
        let factory = FakeEscapeMonitorFactory(localToken: nil, globalToken: nil)
        let monitor = ActiveJobEscapeMonitor(factory: factory)

        XCTAssertEqual(monitor.start {}, .inactive)
        XCTAssertEqual(monitor.status, .inactive)
        XCTAssertFalse(monitor.isActive)
    }

    // MARK: ADR-021: in-recorder AI controls

    func testRecordingAIControlPredicateAcceptsOnlyCommandDigitsAndCommandShiftA() {
        typealias Monitor = RecordingAIControlMonitor
        XCTAssertEqual(Monitor.control(characters: "1", modifierFlags: .command), .action(shortcutNumber: 1))
        XCTAssertEqual(Monitor.control(characters: "0", modifierFlags: .command), .action(shortcutNumber: 0))
        XCTAssertEqual(Monitor.control(characters: "9", modifierFlags: [.command, .numericPad]), .action(shortcutNumber: 9), "keypad digits count")
        XCTAssertEqual(Monitor.control(characters: "2", modifierFlags: [.command, .capsLock]), .action(shortcutNumber: 2), "caps lock is ignored")
        XCTAssertEqual(Monitor.control(characters: "a", modifierFlags: [.command, .shift]), .toggleAIEnabled)
        XCTAssertEqual(Monitor.control(characters: "A", modifierFlags: [.command, .shift]), .toggleAIEnabled)

        XCTAssertNil(Monitor.control(characters: "1", modifierFlags: .command, isRepeat: true), "no auto-repeat")
        XCTAssertNil(Monitor.control(characters: "1", modifierFlags: []), "a bare digit is typing")
        XCTAssertNil(Monitor.control(characters: "1", modifierFlags: [.command, .option]), "⌥⌘1 belongs to someone else")
        XCTAssertNil(Monitor.control(characters: "1", modifierFlags: [.command, .shift]), "⇧⌘1 is not an action key")
        XCTAssertNil(Monitor.control(characters: "a", modifierFlags: .command), "⌘A is select-all")
        XCTAssertNil(Monitor.control(characters: "b", modifierFlags: [.command, .shift]))
        XCTAssertNil(Monitor.control(characters: "12", modifierFlags: .command))
        XCTAssertNil(Monitor.control(characters: nil, modifierFlags: .command))
        XCTAssertNil(Monitor.control(characters: "\u{1B}", modifierFlags: .command), "Escape stays Escape")
    }

    func testRecordingAIControlMonitorDegradesLikeTheEscapeMonitor() {
        let both = RecordingAIControlMonitor(factory: FakeEscapeMonitorFactory(localToken: NSObject(), globalToken: NSObject()))
        XCTAssertEqual(both.start { _ in }, .active)
        XCTAssertTrue(both.isActive)
        both.stop()
        XCTAssertEqual(both.status, .inactive)

        let noGlobal = RecordingAIControlMonitor(factory: FakeEscapeMonitorFactory(localToken: NSObject(), globalToken: nil))
        XCTAssertEqual(noGlobal.start { _ in }, .degraded, "without Accessibility the controls work only while kvoice is frontmost")

        let none = RecordingAIControlMonitor(factory: FakeEscapeMonitorFactory(localToken: nil, globalToken: nil))
        XCTAssertEqual(none.start { _ in }, .inactive)
    }

    func testAdapterForwardsRecordingAIControlMonitorStatus() {
        let factory = FakeEscapeMonitorFactory(localToken: NSObject(), globalToken: NSObject())
        let adapter = KeyboardShortcutsAdapter(
            backend: FakeRegistrationBackend(),
            escapeMonitorFactory: factory
        )

        XCTAssertEqual(adapter.beginRecordingAIControlMonitoring { _ in }, .active)
        XCTAssertEqual(adapter.recordingAIControlMonitoringStatus, .active)
        adapter.endRecordingAIControlMonitoring()
        XCTAssertEqual(adapter.recordingAIControlMonitoringStatus, .inactive)
        XCTAssertEqual(factory.removedMonitorCount, 2, "both observers are removed when the recording ends")
    }

    func testAdapterForwardsEscapeMonitorStatus() {
        let factory = FakeEscapeMonitorFactory(localToken: nil, globalToken: NSObject())
        let adapter = KeyboardShortcutsAdapter(
            backend: FakeRegistrationBackend(),
            escapeMonitorFactory: factory
        )

        XCTAssertEqual(adapter.beginActiveJobEscapeMonitoring {}, .degraded)
        XCTAssertEqual(adapter.escapeMonitoringStatus, .degraded)
        XCTAssertFalse(adapter.isEscapeMonitoringActive)

        adapter.endActiveJobEscapeMonitoring()
        XCTAssertEqual(adapter.escapeMonitoringStatus, .inactive)
    }
}

@MainActor
private final class FakeRegistrationBackend: HotkeyRegistrationBackend {
    var registeredShortcut: KeyboardShortcuts.Shortcut?
    var nextRegistrationError: HotkeyAdapterError?
    private var keyDown: (@MainActor () -> Void)?
    private var keyUp: (@MainActor () -> Void)?

    func register(
        _ shortcut: KeyboardShortcuts.Shortcut,
        onKeyDown: @escaping @MainActor () -> Void,
        onKeyUp: @escaping @MainActor () -> Void
    ) throws {
        if let nextRegistrationError {
            self.nextRegistrationError = nil
            throw nextRegistrationError
        }
        registeredShortcut = shortcut
        keyDown = onKeyDown
        keyUp = onKeyUp
    }

    func unregister() {
        registeredShortcut = nil
        keyDown = nil
        keyUp = nil
    }

    func presentRecorder() {}

    func emitKeyDown() {
        keyDown?()
    }

    func emitKeyUp() {
        keyUp?()
    }
}

@MainActor
private final class FakeEscapeMonitorFactory: EscapeMonitorFactory {
    let localToken: Any?
    let globalToken: Any?
    private(set) var removedMonitorCount = 0

    init(localToken: Any?, globalToken: Any?) {
        self.localToken = localToken
        self.globalToken = globalToken
    }

    func addLocalMonitor(handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        localToken
    }

    func addGlobalMonitor(handler: @escaping (NSEvent) -> Void) -> Any? {
        globalToken
    }

    func removeMonitor(_: Any) {
        removedMonitorCount += 1
    }
}

private extension ShortcutDefinition {
    var asTestShortcut: KeyboardShortcuts.Shortcut {
        KeyboardShortcuts.Shortcut(
            key == "space" ? .space : .d,
            modifiers: key == "space" ? [.control] : [.command, .shift]
        )
    }
}
