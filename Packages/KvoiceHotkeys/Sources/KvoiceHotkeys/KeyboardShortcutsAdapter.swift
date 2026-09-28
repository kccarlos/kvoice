import AppKit
import Foundation
import KeyboardShortcuts
import KvoiceDomain

/// Errors raised while validating or installing the user-configured shortcut.
public enum HotkeyAdapterError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedKey(String)
    case unsupportedModifier(String)
    case systemConflict
    case applicationConflict
    case busy
    case registrationFailed
    /// A modifier-only key or the middle mouse trigger needs a global event
    /// monitor, which only fires for an Accessibility-trusted process.
    case accessibilityRequired
    /// ADR-026: the App Store edition has no global event monitors (they
    /// deliver only to an Accessibility-trusted process, which a sandboxed
    /// app cannot be), so a modifier-only key and the middle mouse trigger
    /// are refused up front rather than installed to never fire.
    case unavailableInAppStoreEdition

    public var errorDescription: String? {
        switch self {
        case .unsupportedKey(let key):
            return "The key \(key) is not supported for a global shortcut."
        case .unsupportedModifier(let modifier):
            return "The modifier \(modifier) is not supported for a global shortcut."
        case .systemConflict:
            return "That shortcut is already used by macOS."
        case .applicationConflict:
            return "That shortcut is already in use by another application."
        case .busy:
            return "Shortcut changes are available when KVoice is idle."
        case .registrationFailed:
            return "KVoice could not register that shortcut."
        case .accessibilityRequired:
            return "A modifier-only key needs Accessibility permission. Grant it in System Settings › Privacy & Security › Accessibility, or choose a key combination."
        case .unavailableInAppStoreEdition:
            return "The App Store edition cannot watch a single modifier key or the mouse while another app is in front. Choose a key combination."
        }
    }

    public var errorCode: KVoiceErrorCode {
        switch self {
        case .busy: return .appBusy
        case .accessibilityRequired: return .permissionAccessibilityDenied
        default: return .hotkeyRegistrationFailed
        }
    }
}

/// Secondary global shortcuts beside the recording shortcut.
///
/// One case today. The role enum, the per-role registration table, and the
/// recorder plumbing stay general so a future secondary shortcut is a new case
/// rather than a second code path. (An Append role existed until it was
/// removed on 2026-09-13.)
public enum AuxiliaryShortcutRole: String, Sendable, Equatable, CaseIterable {
    /// Custom Cancel Shortcut. Escape keeps working regardless; this is an
    /// extra trigger with the same C.7 semantics.
    case cancel

    /// The `KeyboardShortcuts.Name` the Carbon backend registers under.
    public var registrationName: String {
        switch self {
        case .cancel: return "kvoice.cancel"
        }
    }
}

/// Describes how much of the active-job Escape fallback is available.
public enum EscapeMonitorStatus: String, Equatable, Sendable {
    case inactive
    case degraded
    case active
}

/// AppKit event-monitor seam used by `ActiveJobEscapeMonitor`.
///
/// The production implementation below delegates to `NSEvent`; tests can
/// return nil for either registration without synthesizing global keyboard
/// events or depending on AppKit's event-monitor permission state.
@MainActor
public protocol EscapeMonitorFactory: AnyObject {
    func addLocalMonitor(handler: @escaping (NSEvent) -> NSEvent?) -> Any?
    func addGlobalMonitor(handler: @escaping (NSEvent) -> Void) -> Any?
    func removeMonitor(_ monitor: Any)
}

@MainActor
public final class NSEventEscapeMonitorFactory: EscapeMonitorFactory {
    public init() {}

    public func addLocalMonitor(handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
    }

    public func addGlobalMonitor(handler: @escaping (NSEvent) -> Void) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
    }

    public func removeMonitor(_ monitor: Any) {
        NSEvent.removeMonitor(monitor)
    }
}

/// The small surface the adapter needs from KeyboardShortcuts.  Keeping this
/// seam explicit makes conflict rollback and key-edge tests deterministic
/// without asking XCTest to synthesize Carbon events.
@MainActor
public protocol HotkeyRegistrationBackend: AnyObject {
    func register(
        _ shortcut: KeyboardShortcuts.Shortcut,
        onKeyDown: @escaping @MainActor () -> Void,
        onKeyUp: @escaping @MainActor () -> Void
    ) throws

    func unregister()
    func presentRecorder()
}

/// KeyboardShortcuts 3.0.1 implementation used by the production adapter.
///
/// The library's `isEnabled(for:)` result is checked immediately after
/// assigning the shortcut.  This catches Carbon registration failure while the
/// old shortcut can still be restored by the adapter's transaction boundary.
@MainActor
public final class KeyboardShortcutsRegistrationBackend: HotkeyRegistrationBackend {
    public static let recordingName = "kvoice.recording"

    private let name: KeyboardShortcuts.Name
    private var handlersInstalled = false

    /// One backend per `KeyboardShortcuts.Name`; the auxiliary shortcuts use
    /// their own names so the library keeps them apart.
    public init(name: String = KeyboardShortcutsRegistrationBackend.recordingName) {
        self.name = KeyboardShortcuts.Name(name)
    }

    public func register(
        _ shortcut: KeyboardShortcuts.Shortcut,
        onKeyDown: @escaping @MainActor () -> Void,
        onKeyUp: @escaping @MainActor () -> Void
    ) throws {
        if shortcut.isTakenBySystem {
            throw HotkeyAdapterError.systemConflict
        }

        if Self.isTakenByApplicationMenu(shortcut) {
            throw HotkeyAdapterError.applicationConflict
        }

        if !handlersInstalled {
            KeyboardShortcuts.onKeyDown(for: name) { @MainActor [weak self] in
                // The handler is replaced on every successful registration so
                // a stale closure cannot retain a previous owner.
                self?.keyDownHandler?()
            }
            KeyboardShortcuts.onKeyUp(for: name) { @MainActor [weak self] in
                self?.keyUpHandler?()
            }
            handlersInstalled = true
        }

        KeyboardShortcuts.setShortcut(shortcut, for: name)
        guard KeyboardShortcuts.isEnabled(for: name) else {
            throw HotkeyAdapterError.registrationFailed
        }

        keyDownHandler = onKeyDown
        keyUpHandler = onKeyUp
    }

    public func unregister() {
        keyDownHandler = nil
        keyUpHandler = nil
        KeyboardShortcuts.removeHandler(for: name)
        KeyboardShortcuts.setShortcut(nil, for: name)
        handlersInstalled = false
    }

    public func presentRecorder() {
        // The owning settings view may use `KeyboardShortcuts.RecorderCocoa`.
        // The backend intentionally does not create a window or activate the
        // target application from a service call.
    }

    private var keyDownHandler: (@MainActor () -> Void)?
    private var keyUpHandler: (@MainActor () -> Void)?

    private static func isTakenByApplicationMenu(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        guard
            let mainMenu = NSApp.mainMenu,
            let keyEquivalent = menuKeyEquivalent(for: shortcut.key)
        else {
            return false
        }

        let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let shortcutModifiers = shortcut.modifiers.intersection(relevantModifiers)

        func containsConflict(in menu: NSMenu) -> Bool {
            for item in menu.items {
                var itemKey = item.keyEquivalent
                let itemModifiers = item.keyEquivalentModifierMask.intersection(relevantModifiers)

                // AppKit represents a shifted alphabetic key as an uppercase
                // key equivalent plus the shift mask. KeyboardShortcuts uses
                // the lowercase representation, so normalize both sides.
                if itemModifiers.contains(.shift), itemKey.lowercased() != itemKey {
                    itemKey = itemKey.lowercased()
                }

                if itemKey == keyEquivalent, itemModifiers == shortcutModifiers {
                    return true
                }

                if let submenu = item.submenu, containsConflict(in: submenu) {
                    return true
                }
            }
            return false
        }

        return containsConflict(in: mainMenu)
    }

    private static func menuKeyEquivalent(for key: KeyboardShortcuts.Key?) -> String? {
        guard let key else { return nil }

        let letters: [(String, KeyboardShortcuts.Key)] = [
            ("a", .a), ("b", .b), ("c", .c), ("d", .d), ("e", .e), ("f", .f),
            ("g", .g), ("h", .h), ("i", .i), ("j", .j), ("k", .k), ("l", .l),
            ("m", .m), ("n", .n), ("o", .o), ("p", .p), ("q", .q), ("r", .r),
            ("s", .s), ("t", .t), ("u", .u), ("v", .v), ("w", .w), ("x", .x),
            ("y", .y), ("z", .z)
        ]
        if let letter = letters.first(where: { $0.1 == key }) {
            return letter.0
        }

        let digits: [(String, KeyboardShortcuts.Key)] = [
            ("0", .zero), ("1", .one), ("2", .two), ("3", .three), ("4", .four),
            ("5", .five), ("6", .six), ("7", .seven), ("8", .eight), ("9", .nine)
        ]
        if let digit = digits.first(where: { $0.1 == key }) {
            return digit.0
        }

        switch key {
        case .space: return " "
        case .tab: return "\t"
        case .return: return "\r"
        case .escape: return "\u{1b}"
        case .delete: return "\u{8}"
        case .deleteForward: return "\u{7f}"
        case .leftArrow: return "\u{f702}"
        case .rightArrow: return "\u{f703}"
        case .downArrow: return "\u{f701}"
        case .upArrow: return "\u{f700}"
        case .home: return "\u{f729}"
        case .end: return "\u{f72b}"
        case .pageUp: return "\u{f72c}"
        case .pageDown: return "\u{f72d}"
        default: return nil
        }
    }
}

/// Main-actor adapter translating KeyboardShortcuts callbacks into the domain's
/// semantic key edges.  It never records raw key codes or key characters.
@MainActor
public final class KeyboardShortcutsAdapter: @preconcurrency GlobalShortcutService {
    public private(set) var registrationState: ShortcutRegistrationState = .unregistered
    public private(set) var registeredShortcut: ShortcutDefinition?
    public private(set) var physicalKeyIsDown = false

    /// Called when the watchdog synthesizes a key-up.  The callback receives no
    /// keyboard data, only the bounded stop reason.
    public var onWatchdogStop: (@MainActor (KeyStateWatchdogStopReason) -> Void)? = nil

    /// Reports a shortcut recorded by `presentRecorder()`. The adapter does not
    /// register it itself: the coordinator owns persistence and registration.
    public var onShortcutRecorded: (@MainActor (ShortcutDefinition) -> Void)? = nil

    /// Reports a shortcut recorded by `presentAuxiliaryRecorder(for:)` for a
    /// secondary role; the coordinator persists and registers it through
    /// `registerAuxiliaryShortcut`.
    public var onAuxiliaryShortcutRecorded: (@MainActor (AuxiliaryShortcutRole, ShortcutDefinition) -> Void)? = nil

    private var recorderWindow: ShortcutRecorderWindowController?

    private let backend: any HotkeyRegistrationBackend
    private let modifierMonitor: ModifierOnlyShortcutMonitor
    private let auxiliaryBackendFactory: @MainActor (AuxiliaryShortcutRole) -> any HotkeyRegistrationBackend
    private let inputMonitorFactory: any InputEventMonitorFactory
    private let globalInputMonitorsAvailable: Bool
    private let watchdog: KeyStateWatchdog
    private let escapeMonitor: ActiveJobEscapeMonitor
    private let aiControlMonitor: RecordingAIControlMonitor
    private let middleMouseMonitor: MiddleMouseTriggerMonitor
    private var handler: (@MainActor (ShortcutEvent) -> Void)? = nil
    private var auxiliaryRegistrations: [AuxiliaryShortcutRole: AuxiliaryRegistration] = [:]

    /// One secondary shortcut: whichever path registered it, plus its own
    /// physical-hold bit so repeats collapse the same way as the primary.
    @MainActor
    private final class AuxiliaryRegistration {
        let shortcut: ShortcutDefinition
        let backend: (any HotkeyRegistrationBackend)?
        let monitor: ModifierOnlyShortcutMonitor?
        let handler: @MainActor (ShortcutEvent) -> Void
        var isDown = false

        init(
            shortcut: ShortcutDefinition,
            backend: (any HotkeyRegistrationBackend)?,
            monitor: ModifierOnlyShortcutMonitor?,
            handler: @escaping @MainActor (ShortcutEvent) -> Void
        ) {
            self.shortcut = shortcut
            self.backend = backend
            self.monitor = monitor
            self.handler = handler
        }

        func receive(_ event: ShortcutEvent) {
            switch event {
            case .keyDown:
                guard !isDown else { return }
                isDown = true
            case .keyUp:
                guard isDown else { return }
                isDown = false
            }
            handler(event)
        }

        func tearDown() {
            backend?.unregister()
            monitor?.stop()
            if isDown {
                isDown = false
                handler(.keyUp)
            }
        }
    }

    public init(
        backend: any HotkeyRegistrationBackend = KeyboardShortcutsRegistrationBackend(),
        maximumHoldDuration: Duration = .seconds(600),
        // Optional with a `nil` default, resolved in the body: a function
        // value produced by this init's default-argument generator (the
        // closure literal first, then `KeyStateWatchdog.systemSleep`) crashed
        // the task that later called it (SIGABRT "freed pointer was not the
        // last allocation" / SIGBUS in `swift_task_alloc`), while the same
        // value passed explicitly, or resolved here, did not. Swift 6.3.3.
        sleep: KeyStateWatchdog.Sleep? = nil,
        escapeMonitorFactory: any EscapeMonitorFactory = NSEventEscapeMonitorFactory(),
        inputMonitorFactory: any InputEventMonitorFactory = NSEventInputMonitorFactory(),
        // ADR-026: `DistributionEdition.hasGlobalInputMonitors`, passed by
        // the composition root. False refuses the modifier-only key and the
        // middle mouse trigger with `.unavailableInAppStoreEdition`.
        globalInputMonitorsAvailable: Bool = true,
        auxiliaryBackendFactory: @escaping @MainActor (AuxiliaryShortcutRole) -> any HotkeyRegistrationBackend = { role in
            KeyboardShortcutsRegistrationBackend(name: role.registrationName)
        }
    ) {
        self.backend = backend
        self.inputMonitorFactory = inputMonitorFactory
        self.globalInputMonitorsAvailable = globalInputMonitorsAvailable
        self.auxiliaryBackendFactory = auxiliaryBackendFactory
        self.modifierMonitor = ModifierOnlyShortcutMonitor(factory: inputMonitorFactory)
        let sleep = sleep ?? KeyStateWatchdog.systemSleep
        self.middleMouseMonitor = MiddleMouseTriggerMonitor(factory: inputMonitorFactory, sleep: sleep)
        self.escapeMonitor = ActiveJobEscapeMonitor(factory: escapeMonitorFactory)
        self.aiControlMonitor = RecordingAIControlMonitor(factory: escapeMonitorFactory)
        self.watchdog = KeyStateWatchdog(
            maximumDuration: maximumHoldDuration,
            sleep: sleep,
            onForcedStop: { _ in }
        )
        self.registeredShortcut = nil
        self.physicalKeyIsDown = false
        self.watchdog.onForcedStop = { [weak self] reason in
            self?.watchdogDidForceStop(reason)
        }
    }

    isolated deinit {
        watchdog.disarm()
        backend.unregister()
        modifierMonitor.stop()
        middleMouseMonitor.stop()
        for registration in auxiliaryRegistrations.values {
            registration.tearDown()
        }
    }

    /// The watchdog's bound on a hold with no key-up. The app shell should
    /// keep this at the recording ceiling (`AppSettings.maxRecordingSeconds`)
    /// so a 30-minute push-to-talk hold is not cut at ten minutes; the audio
    /// cap remains the hard bound either way.
    public var maximumHoldDuration: Duration {
        get { watchdog.maximumDuration }
        set { watchdog.maximumDuration = newValue }
    }

    public func register(
        _ shortcut: ShortcutDefinition,
        handler: @escaping @MainActor (ShortcutEvent) -> Void
    ) throws {
        // Validate before touching the live registration so a malformed
        // definition cannot disturb the working one.
        if shortcut.modifierOnlyKey == nil {
            _ = try shortcut.asKeyboardShortcut()
        }
        let previousShortcut = registeredShortcut
        let previousHandler = self.handler

        if physicalKeyIsDown {
            watchdog.shortcutRebound()
            physicalKeyIsDown = false
        }

        self.handler = handler

        do {
            try installPrimary(shortcut)
            registeredShortcut = shortcut
            registrationState = .registered(shortcut)
        } catch {
            // A registration attempt is atomic from the caller's point of
            // view.  Restore the previous callback and shortcut when possible.
            self.handler = previousHandler
            if let previousShortcut, (try? installPrimary(previousShortcut)) != nil {
                registeredShortcut = previousShortcut
                registrationState = .registered(previousShortcut)
            } else {
                uninstallPrimary()
                registeredShortcut = nil
                registrationState = .unregistered
            }

            let adapterError = (error as? HotkeyAdapterError) ?? .registrationFailed
            if registeredShortcut == nil {
                registrationState = .failed(adapterError.errorCode)
            }
            throw adapterError
        }
    }

    /// Picks the Carbon path for a key + modifier shortcut and the
    /// `flagsChanged` monitor for a lone modifier key. Exactly one is live.
    private func installPrimary(_ shortcut: ShortcutDefinition) throws {
        if let key = shortcut.modifierOnlyKey {
            guard globalInputMonitorsAvailable else {
                throw HotkeyAdapterError.unavailableInAppStoreEdition
            }
            backend.unregister()
            try modifierMonitor.start(
                key: key,
                onKeyDown: { [weak self] in self?.receive(.keyDown) },
                onKeyUp: { [weak self] in self?.receive(.keyUp) }
            )
        } else {
            modifierMonitor.stop()
            try backend.register(
                try shortcut.asKeyboardShortcut(),
                onKeyDown: { [weak self] in self?.receive(.keyDown) },
                onKeyUp: { [weak self] in self?.receive(.keyUp) }
            )
        }
    }

    private func uninstallPrimary() {
        backend.unregister()
        modifierMonitor.stop()
    }

    public func unregister() {
        if physicalKeyIsDown {
            physicalKeyIsDown = false
            watchdog.disarm()
            handler?(.keyUp)
        } else {
            watchdog.disarm()
        }

        uninstallPrimary()
        registeredShortcut = nil
        registrationState = .unregistered
        handler = nil
    }

    // MARK: Auxiliary shortcuts (cancel)

    public func auxiliaryShortcut(for role: AuxiliaryShortcutRole) -> ShortcutDefinition? {
        auxiliaryRegistrations[role]?.shortcut
    }

    /// Registers a secondary shortcut. Failure leaves any previous
    /// registration for the role in place. Both edges are delivered; the
    /// cancel handler should act on `.keyDown` only.
    public func registerAuxiliaryShortcut(
        _ role: AuxiliaryShortcutRole,
        _ shortcut: ShortcutDefinition,
        handler: @escaping @MainActor (ShortcutEvent) -> Void
    ) throws {
        if shortcut.modifierOnlyKey == nil {
            _ = try shortcut.asKeyboardShortcut()
        }
        if shortcut == registeredShortcut {
            throw HotkeyAdapterError.applicationConflict
        }
        if auxiliaryRegistrations.contains(where: { $0.key != role && $0.value.shortcut == shortcut }) {
            throw HotkeyAdapterError.applicationConflict
        }

        let registration: AuxiliaryRegistration
        if let key = shortcut.modifierOnlyKey {
            let monitor = ModifierOnlyShortcutMonitor(factory: inputMonitorFactory)
            let candidate = AuxiliaryRegistration(shortcut: shortcut, backend: nil, monitor: monitor, handler: handler)
            try monitor.start(
                key: key,
                onKeyDown: { [weak candidate] in candidate?.receive(.keyDown) },
                onKeyUp: { [weak candidate] in candidate?.receive(.keyUp) }
            )
            registration = candidate
        } else {
            let auxiliaryBackend = auxiliaryBackendFactory(role)
            let candidate = AuxiliaryRegistration(
                shortcut: shortcut,
                backend: auxiliaryBackend,
                monitor: nil,
                handler: handler
            )
            do {
                try auxiliaryBackend.register(
                    try shortcut.asKeyboardShortcut(),
                    onKeyDown: { [weak candidate] in candidate?.receive(.keyDown) },
                    onKeyUp: { [weak candidate] in candidate?.receive(.keyUp) }
                )
            } catch {
                auxiliaryBackend.unregister()
                throw (error as? HotkeyAdapterError) ?? .registrationFailed
            }
            registration = candidate
        }

        auxiliaryRegistrations[role]?.tearDown()
        auxiliaryRegistrations[role] = registration
    }

    public func unregisterAuxiliaryShortcut(_ role: AuxiliaryShortcutRole) {
        auxiliaryRegistrations.removeValue(forKey: role)?.tearDown()
    }

    // MARK: Middle mouse trigger

    public var isMiddleMouseTriggerActive: Bool {
        middleMouseMonitor.isActive
    }

    /// Enables or disables the middle mouse trigger. `handler` receives a
    /// `.keyDown` once the button has been held for `activationDelay`, and
    /// the matching `.keyUp` on release; feed both to
    /// `DictationController.handleShortcut(_:mode:trigger: .middleMouse)`.
    public func setMiddleMouseTrigger(
        enabled: Bool,
        activationDelay: Duration,
        handler: @escaping @MainActor (ShortcutEvent) -> Void
    ) throws {
        middleMouseMonitor.stop()
        guard enabled else { return }
        guard globalInputMonitorsAvailable else {
            throw HotkeyAdapterError.unavailableInAppStoreEdition
        }
        try middleMouseMonitor.start(activationDelay: activationDelay, handler: handler)
    }

    /// Shows the alternate-shortcut recorder.
    ///
    /// The window lives here rather than in the backend, which is deliberately
    /// registration-only, and rather than in KvoiceUI, which must not see
    /// `KeyboardShortcuts` types. The recorded value is reported as a domain
    /// `ShortcutDefinition` through `onShortcutRecorded`; the coordinator then
    /// persists and registers it through the ordinary settings path, so the
    /// registration transaction and its rollback still apply.
    public func presentRecorder() {
        backend.presentRecorder()
        presentRecorderWindow(current: registeredShortcut) { [weak self] definition in
            self?.onShortcutRecorded?(definition)
        }
    }

    /// The same recorder window for a secondary shortcut. The primary
    /// shortcut is suspended while it is open for the same reason as above.
    public func presentAuxiliaryRecorder(for role: AuxiliaryShortcutRole) {
        presentRecorderWindow(current: auxiliaryShortcut(for: role)) { [weak self] definition in
            self?.onAuxiliaryShortcutRecorded?(role, definition)
        }
    }

    private func presentRecorderWindow(
        current: ShortcutDefinition?,
        onRecorded: @escaping @MainActor (ShortcutDefinition) -> Void
    ) {
        if recorderWindow == nil {
            // Suspend the live hotkey for the duration. A Carbon hotkey is
            // consumed before the app sees the key, so otherwise pressing the
            // current shortcut would start dictation instead of being recorded.
            // The library's own `isPaused` switch is not public, so unregister.
            let restoreShortcut = registeredShortcut
            let restoreHandler = handler
            uninstallPrimary()

            var didRecordPrimary = false
            let recordsPrimary = current == restoreShortcut
            recorderWindow = ShortcutRecorderWindowController(
                currentShortcut: current,
                onRecorded: { definition in
                    // A recorded primary is registered by the coordinator
                    // through the ordinary settings path, so nothing is
                    // restored for it here; an auxiliary recording leaves the
                    // primary to be restored on close.
                    didRecordPrimary = recordsPrimary
                    onRecorded(definition)
                },
                onClose: { [weak self] in
                    guard let self else { return }
                    self.recorderWindow?.close()
                    self.recorderWindow = nil
                    if !didRecordPrimary,
                       let restoreShortcut,
                       let restoreHandler {
                        try? self.register(restoreShortcut, handler: restoreHandler)
                    }
                }
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        recorderWindow?.showWindow(nil)
        recorderWindow?.window?.makeKeyAndOrderFront(nil)
    }

    /// Starts the paired Escape monitors for one active dictation job.
    @discardableResult
    public func beginActiveJobEscapeMonitoring(
        handler: @escaping @MainActor () -> Void
    ) -> EscapeMonitorStatus {
        escapeMonitor.start(handler: handler)
    }

    /// Removes the Escape monitors as soon as the job reaches a terminal state.
    public func endActiveJobEscapeMonitoring() {
        escapeMonitor.stop()
    }

    public var isEscapeMonitoringActive: Bool {
        escapeMonitoringStatus == .active
    }

    /// Reports whether both local and global Escape observers were installed.
    /// A degraded result means one observer is available; callers should keep
    /// an explicit cancel/stop command visible in that case.
    public var escapeMonitoringStatus: EscapeMonitorStatus {
        escapeMonitor.status
    }

    /// ADR-021: starts the paired ⌘1–⌘0 / ⌘⇧A observers for one recording.
    /// Scoped strictly to `.recording` by the shell; the controller seam it
    /// feeds (`DictationController.setAIAction` / `setAIEnabled`) refuses
    /// anything else regardless.
    @discardableResult
    public func beginRecordingAIControlMonitoring(
        handler: @escaping @MainActor (RecordingAIControl) -> Void
    ) -> EscapeMonitorStatus {
        aiControlMonitor.start(handler: handler)
    }

    /// Removes the AI-control observers as soon as the recording ends.
    public func endRecordingAIControlMonitoring() {
        aiControlMonitor.stop()
    }

    /// Same reading as `escapeMonitoringStatus`: `.degraded` means the global
    /// observer is missing (no Accessibility trust) and the controls only
    /// work while kvoice is frontmost.
    public var recordingAIControlMonitoringStatus: EscapeMonitorStatus {
        aiControlMonitor.status
    }

    public func applicationDidResignActive() {
        watchdog.applicationDidResignActive()
    }

    public func displayWillSleep() {
        watchdog.displayWillSleep()
    }

    public func applicationWillTerminate() {
        watchdog.applicationWillTerminate()
    }

    private func receive(_ event: ShortcutEvent) {
        switch event {
        case .keyDown:
            guard !physicalKeyIsDown else {
                // KeyboardShortcuts can surface repeat presses; the domain sees
                // one semantic edge per physical hold.
                return
            }
            physicalKeyIsDown = true
            watchdog.arm()
            handler?(.keyDown)

        case .keyUp:
            guard physicalKeyIsDown else { return }
            physicalKeyIsDown = false
            watchdog.keyUpReceived()
            handler?(.keyUp)
        }
    }

    private func watchdogDidForceStop(_ reason: KeyStateWatchdogStopReason) {
        guard physicalKeyIsDown else { return }
        physicalKeyIsDown = false
        handler?(.keyUp)
        onWatchdogStop?(reason)
    }
}

/// A paired local/global Escape observer.  It is active only while a job is
/// active, observes hardware Escape (key code 53), and always returns the local
/// event so the foreground app may process Escape too.
@MainActor
public final class ActiveJobEscapeMonitor {
    public private(set) var status: EscapeMonitorStatus = .inactive

    private let factory: any EscapeMonitorFactory
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var handler: (@MainActor () -> Void)?

    public init(factory: any EscapeMonitorFactory = NSEventEscapeMonitorFactory()) {
        self.factory = factory
    }

    public var isActive: Bool {
        status == .active
    }

    isolated deinit {
        stop()
    }

    @discardableResult
    public func start(handler: @escaping @MainActor () -> Void) -> EscapeMonitorStatus {
        stop()
        self.handler = handler

        localMonitor = factory.addLocalMonitor { [weak self] event in
            guard Self.accepts(event) else { return event }
            self?.handler?()
            return event
        }

        globalMonitor = factory.addGlobalMonitor { [weak self] event in
            guard Self.accepts(event) else { return }
            self?.handler?()
        }

        status = Self.status(localMonitor: localMonitor, globalMonitor: globalMonitor)
        if status == .inactive {
            self.handler = nil
        }
        return status
    }

    public func stop() {
        if let localMonitor {
            factory.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            factory.removeMonitor(globalMonitor)
        }
        self.localMonitor = nil
        self.globalMonitor = nil
        handler = nil
        status = .inactive
    }

    /// Pure event predicate used by the monitor and deterministic tests.
    public static func accepts(keyCode: UInt16, isRepeat: Bool = false) -> Bool {
        keyCode == 53 && !isRepeat
    }

    private static func status(localMonitor: Any?, globalMonitor: Any?) -> EscapeMonitorStatus {
        switch (localMonitor != nil, globalMonitor != nil) {
        case (true, true): return .active
        case (true, false), (false, true): return .degraded
        case (false, false): return .inactive
        }
    }

    private static func accepts(_ event: NSEvent) -> Bool {
        accepts(keyCode: event.keyCode, isRepeat: event.isARepeat)
    }
}

// Internal rather than private so the round-trip against
// `Shortcut.asShortcutDefinition()` can be tested directly.
extension ShortcutDefinition {
    func asKeyboardShortcut() throws -> KeyboardShortcuts.Shortcut {
        guard let key = KeyboardShortcutKeyMap.key(for: self.key) else {
            throw HotkeyAdapterError.unsupportedKey(self.key)
        }

        var modifiers: NSEvent.ModifierFlags = []
        for rawModifier in self.modifiers {
            let normalized = rawModifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            switch normalized {
            case "command", "cmd", "⌘": modifiers.insert(.command)
            case "option", "alt", "⌥": modifiers.insert(.option)
            case "control", "ctrl", "^": modifiers.insert(.control)
            case "shift", "⇧": modifiers.insert(.shift)
            case "function", "fn": modifiers.insert(.function)
            case "capslock", "caps-lock", "caps_lock": modifiers.insert(.capsLock)
            default: throw HotkeyAdapterError.unsupportedModifier(rawModifier)
            }
        }

        guard !modifiers.isEmpty else {
            throw HotkeyAdapterError.unsupportedModifier("none")
        }
        return KeyboardShortcuts.Shortcut(key, modifiers: modifiers)
    }
}

extension KeyboardShortcuts.Shortcut {
    /// Reverse of `ShortcutDefinition.asKeyboardShortcut()`, so a recorded
    /// vendor shortcut can leave this package as a domain value.
    ///
    /// Unnamed keys fall back to the `keycode:<n>` spelling that the forward
    /// map already accepts, so any recordable key round-trips.
    func asShortcutDefinition() -> ShortcutDefinition {
        // Canonical macOS display order.
        var names: [String] = []
        if modifiers.contains(.control) { names.append("control") }
        if modifiers.contains(.option) { names.append("option") }
        if modifiers.contains(.shift) { names.append("shift") }
        if modifiers.contains(.command) { names.append("command") }
        if modifiers.contains(.function) { names.append("function") }
        if modifiers.contains(.capsLock) { names.append("capslock") }

        return ShortcutDefinition(
            key: KeyboardShortcutKeyMap.name(for: key) ?? "keycode:\(key?.rawValue ?? -1)",
            modifiers: names
        )
    }
}

private enum KeyboardShortcutKeyMap {
    /// Inverse of `namedKeys`. Built once; the forward table is the only place
    /// key spellings are defined.
    static func name(for key: KeyboardShortcuts.Key?) -> String? {
        guard let key else { return nil }
        return reverseKeys[key]
    }

    private static let reverseKeys: [KeyboardShortcuts.Key: String] = {
        var result: [KeyboardShortcuts.Key: String] = [:]
        for (name, key) in namedKeys where result[key] == nil {
            result[key] = name
        }
        // `namedKeys` maps several spellings onto one key; pin the canonical
        // spelling so round-tripping is stable regardless of dictionary order.
        let canonical: [KeyboardShortcuts.Key: String] = [
            .return: "return", .space: "space", .escape: "escape",
            .deleteForward: "deleteforward", .upArrow: "up", .downArrow: "down",
            .leftArrow: "left", .rightArrow: "right"
        ]
        for (key, name) in canonical {
            result[key] = name
        }
        return result
    }()

    static func key(for name: String) -> KeyboardShortcuts.Key? {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized.hasPrefix("keycode:"),
           let rawValue = Int(normalized.dropFirst("keycode:".count))
        {
            return KeyboardShortcuts.Key(rawValue: rawValue)
        }

        return namedKeys[normalized]
    }

    private static let namedKeys: [String: KeyboardShortcuts.Key] = [
        "a": .a, "b": .b, "c": .c, "d": .d, "e": .e, "f": .f,
        "g": .g, "h": .h, "i": .i, "j": .j, "k": .k, "l": .l,
        "m": .m, "n": .n, "o": .o, "p": .p, "q": .q, "r": .r,
        "s": .s, "t": .t, "u": .u, "v": .v, "w": .w, "x": .x,
        "y": .y, "z": .z,
        "0": .zero, "1": .one, "2": .two, "3": .three, "4": .four,
        "5": .five, "6": .six, "7": .seven, "8": .eight, "9": .nine,
        "return": .return, "enter": .return, "space": .space, "tab": .tab,
        "escape": .escape, "esc": .escape, "delete": .delete,
        "forwarddelete": .deleteForward, "deleteforward": .deleteForward,
        "home": .home, "end": .end, "pageup": .pageUp, "pagedown": .pageDown,
        "up": .upArrow, "uparrow": .upArrow, "down": .downArrow,
        "downarrow": .downArrow, "left": .leftArrow, "leftarrow": .leftArrow,
        "right": .rightArrow, "rightarrow": .rightArrow,
        "backslash": .backslash, "backtick": .backtick, "comma": .comma,
        "equal": .equal, "minus": .minus, "period": .period, "quote": .quote,
        "semicolon": .semicolon, "slash": .slash, "leftbracket": .leftBracket,
        "rightbracket": .rightBracket,
        "f1": .f1, "f2": .f2, "f3": .f3, "f4": .f4, "f5": .f5,
        "f6": .f6, "f7": .f7, "f8": .f8, "f9": .f9, "f10": .f10,
        "f11": .f11, "f12": .f12, "f13": .f13, "f14": .f14, "f15": .f15,
        "f16": .f16, "f17": .f17, "f18": .f18, "f19": .f19, "f20": .f20
    ]
}
