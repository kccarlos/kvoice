import Foundation
import KvoiceAppCore
import KvoiceDomain
import Observation

/// Main-actor state for the nonsecret General and Dictation settings surfaces.
///
/// ADR-022 slice 7: a *projection* over `SettingsProjectionHost`. Recording
/// mode, the confirmed shortcut, Dock visibility, Launch at Login, the
/// typed-insertion tier, the memory opt-in and the interface language are
/// read straight from the coordinator's `AppSettings`; every edit is one
/// `SettingsIntent` through `host.send`, and a refusal leaves the stored
/// value (and so the control) where it was, with `refusalNote` set for the
/// page's footer. Nothing here is a copy the shell has to re-apply. What
/// the model does own is UI state that is not a setting: the launchd status
/// it last read, the pending relaunch prompt, and the shell routes.
@Observable
@MainActor
public final class GeneralSettingsViewModel {
    public static let recommendedShortcut = ShortcutDefinition(
        key: "space",
        modifiers: ["control", "shift"]
    )

    /// The coordinator projection and the intent door.
    public let host: SettingsProjectionHost

    public var recordingInteraction: RecordingInteraction {
        get { host.settings.recordingInteraction }
        set {
            guard newValue != recordingInteraction else { return }
            host.send(.setRecordingInteraction(newValue, origin: .page(.shortcuts)))
        }
    }

    /// The stored shortcut. Nil until a recorder selection is explicitly
    /// confirmed: kvoice never treats the recommendation as active merely
    /// because the model exists.
    public var confirmedShortcut: ShortcutDefinition? {
        host.settings.shortcut
    }

    public var showDockIcon: Bool {
        get { host.settings.showDockIcon }
        set {
            guard newValue != showDockIcon else { return }
            host.send(.setShowDockIcon(newValue, origin: .page(.general)))
        }
    }

    /// The user's request. The truth is `launchAtLoginStatus`; the stored
    /// flag is kept in step with it by `refreshLaunchAtLoginStatus()`.
    /// Setting it talks to `SMAppService` first and records what launchd
    /// actually did, so a denied registration never persists as "on".
    public var launchAtLogin: Bool {
        get { host.settings.launchAtLogin }
        set {
            guard newValue != launchAtLogin else { return }
            let registered = applyLaunchAtLogin(newValue)
            guard registered != launchAtLogin else { return }
            host.send(.setLaunchAtLogin(registered, origin: .page(.general)))
        }
    }

    /// Third insertion tier for targets whose focused element rejects
    /// Accessibility writes (terminals). Never touches the pasteboard.
    public var typedInsertionEnabled: Bool {
        get { host.settings.typedInsertionEnabled }
        set {
            guard newValue != typedInsertionEnabled else { return }
            host.send(.setTypedInsertionEnabled(newValue, origin: .page(.recording)))
        }
    }

    /// Later waves: memory-pressure warnings. Off by default; "Unload model
    /// now" is always offered under critical pressure, but only this opt-in
    /// makes it happen without being asked.
    public var freeModelMemoryUnderCriticalPressure: Bool {
        get { host.settings.freeModelMemoryUnderCriticalPressure }
        set {
            guard newValue != freeModelMemoryUnderCriticalPressure else { return }
            host.send(.setFreeModelMemoryUnderCriticalPressure(newValue, origin: .page(.general)))
        }
    }

    /// Settings › General › Interface language (product decision #9). A change
    /// is persisted at once and — only once the coordinator accepted it —
    /// mirrored into `AppleLanguages` through `applyLanguageOverride`; the
    /// new language shows only after a relaunch, so the view offers one
    /// (`isRelaunchForLanguagePending`). A refusal changes nothing.
    public var interfaceLanguage: InterfaceLanguage {
        get { host.settings.interfaceLanguage }
        set {
            guard newValue != interfaceLanguage else { return }
            guard host.send(.setInterfaceLanguage(newValue, origin: .page(.general))) == nil else { return }
            applyLanguageOverride(newValue)
            isRelaunchForLanguagePending = true
        }
    }

    /// True from a language change until the user relaunches or declines.
    public var isRelaunchForLanguagePending = false

    /// The last refusal's sentence, for the page footer; nil otherwise.
    public var refusalNote: String? { host.refusalNote }

    /// What `SMAppService` last reported. Read on demand — never assumed from
    /// the toggle — so a registration awaiting approval is shown as such.
    public private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .unknown
    public private(set) var launchAtLoginError: String?

    /// Settable so an app shell that builds this model before its services
    /// exist can install the real adapter later. Reads happen on demand, so
    /// swapping the service takes effect at the next refresh.
    @ObservationIgnored public var launchAtLoginService: any LaunchAtLoginService
    /// The Reset Onboarding route (FR-ONB-010). Settable for the same reason.
    @ObservationIgnored public var onResetOnboarding: @MainActor () -> Void
    /// The shell's Restart route, for "Relaunch Now" after a language change.
    /// Settable for the same reason as the others; a no-op without a shell.
    @ObservationIgnored public var onRestartApp: @MainActor () -> Void
    /// Writes the `AppleLanguages` mirror. The default writes the real
    /// defaults; tests inject a recorder.
    @ObservationIgnored public var applyLanguageOverride: @MainActor (InterfaceLanguage) -> Void

    public init(
        host: SettingsProjectionHost = .detached(),
        launchAtLoginService: any LaunchAtLoginService = UnavailableLaunchAtLoginService(),
        onResetOnboarding: @escaping @MainActor () -> Void = {},
        onRestartApp: @escaping @MainActor () -> Void = {},
        applyLanguageOverride: @escaping @MainActor (InterfaceLanguage) -> Void = {
            InterfaceLanguageOverride.apply($0)
        }
    ) {
        self.host = host
        self.launchAtLoginService = launchAtLoginService
        self.onResetOnboarding = onResetOnboarding
        self.onRestartApp = onRestartApp
        self.applyLanguageOverride = applyLanguageOverride
    }

    public var shortcutDescription: String {
        guard let confirmedShortcut else { return String(localized: "No shortcut confirmed", bundle: .module) }
        return Self.displayName(for: confirmedShortcut)
    }

    // MARK: Interface language

    /// "Relaunch Now" in the language prompt: the override is already
    /// written, so the relaunched app comes up in the new language.
    public func relaunchForLanguage() {
        isRelaunchForLanguagePending = false
        onRestartApp()
    }

    /// "Later": keep the setting; the next launch picks it up.
    public func deferRelaunchForLanguage() {
        isRelaunchForLanguagePending = false
    }

    /// Applies a recorder candidate only after its owning UI explicitly calls
    /// this confirmation method.  Empty shortcuts are never persisted.
    public func confirmShortcut(_ shortcut: ShortcutDefinition) {
        guard Self.isUsable(shortcut) else { return }
        guard shortcut != confirmedShortcut else { return }
        host.send(.setShortcut(shortcut, origin: .page(.shortcuts)))
    }

    public func confirmRecommendedShortcut() {
        confirmShortcut(Self.recommendedShortcut)
    }

    public func clearShortcut() {
        guard confirmedShortcut != nil else { return }
        host.send(.setShortcut(nil, origin: .page(.shortcuts)))
    }

    // MARK: Launch at Login

    /// Re-reads `SMAppService.status` and aligns the toggle with it. Called
    /// when the General tab appears and when the app becomes active, since the
    /// user can approve or remove the login item in System Settings at any
    /// time. This never registers or unregisters anything.
    public func refreshLaunchAtLoginStatus() {
        let status = launchAtLoginService.status()
        launchAtLoginStatus = status
        guard status != .unknown else { return }
        let registered = status.isRegistered
        // The stored flag follows launchd, never the other way round; a
        // refusal (a job in flight) is retried by the next refresh.
        if launchAtLogin != registered {
            host.send(.setLaunchAtLogin(registered, origin: .page(.general)))
        }
    }

    /// True when the only remaining step is the user's approval in System
    /// Settings. The view shows an Open button; it never re-prompts.
    public var launchAtLoginNeedsApproval: Bool {
        launchAtLoginStatus == .requiresApproval
    }

    @discardableResult
    public func openLoginItemsSettings() -> Bool {
        launchAtLoginService.openLoginItemsSettings()
    }

    /// Registers or unregisters the login item and returns what launchd
    /// reports afterwards (`enabled` itself when the status is unknown, as
    /// with the unavailable service in tests and previews).
    private func applyLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try launchAtLoginService.register()
            } else {
                try launchAtLoginService.unregister()
            }
            launchAtLoginError = nil
        } catch {
            // An adapter that authors its own `LocalizedError` copy is shown
            // verbatim. Anything else (an `SMAppService` NSError, say) would
            // read as "The operation couldn't be completed. (OSStatus error
            // -10814.)", which is not a sentence a user can act on (D.10).
            launchAtLoginError = (error as? LocalizedError)?.errorDescription
                ?? (enabled
                    ? String(localized: "KVoice could not register itself as a login item. You can add it in System Settings › General › Login Items.", bundle: .module)
                    : String(localized: "KVoice could not remove its login item. You can remove it in System Settings › General › Login Items.", bundle: .module))
        }
        // One read after the call is the whole feedback loop. A denial shows
        // up as `.requiresApproval` and stays visible; nothing retries.
        launchAtLoginStatus = launchAtLoginService.status()
        guard launchAtLoginStatus != .unknown else { return enabled }
        return launchAtLoginStatus.isRegistered
    }

    // MARK: Reset Onboarding

    /// Replays the education flow only (FR-ONB-010). Model, history, and
    /// settings are untouched — the confirmation in the view says so — and the
    /// actual reset lives with the app shell, which owns the completion flag.
    public func resetOnboarding() {
        onResetOnboarding()
    }

    nonisolated public static func displayName(for shortcut: ShortcutDefinition) -> String {
        // A lone modifier key (product decision #5) has no modifier list to join.
        if let key = shortcut.modifierOnlyKey {
            return key.displayName
        }
        let modifierNames: [String: String] = [
            "command": "Command",
            "cmd": "Command",
            "⌘": "Command",
            "option": "Option",
            "alt": "Option",
            "⌥": "Option",
            "control": "Control",
            "ctrl": "Control",
            "^": "Control",
            "shift": "Shift",
            "⇧": "Shift",
            "function": "Function",
            "fn": "Function",
            "capslock": "Caps Lock",
            "caps-lock": "Caps Lock",
            "caps_lock": "Caps Lock"
        ]
        let modifiers = shortcut.modifiers.compactMap {
            modifierNames[$0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        }
        let key = shortcut.key == " " ? "Space" : shortcut.key.capitalized
        return (modifiers + [key]).joined(separator: "-")
    }

    /// The same shortcut as key-equivalent glyphs (⌃⇧Space) — the form
    /// every menu on the Mac draws a shortcut in (D7a/N10). Settings pages
    /// keep `displayName(for:)`'s spelled-out form ("Control-Shift-Space");
    /// this is for a menu *title*, where the global hotkey is text (kvoice
    /// does not own a real `keyEquivalent` — that would let the menu fire
    /// it while open, a second trigger path; parked as P-D2).
    nonisolated public static func glyphs(for shortcut: ShortcutDefinition) -> String {
        if let key = shortcut.modifierOnlyKey {
            return key.displayName
        }
        // Apple's fixed on-screen order for key-equivalent glyphs: Control,
        // Option, Shift, Command.
        let order: [(names: Set<String>, glyph: String)] = [
            (["control", "ctrl", "^"], "⌃"),
            (["option", "alt", "⌥"], "⌥"),
            (["shift", "⇧"], "⇧"),
            (["command", "cmd", "⌘"], "⌘"),
            (["function", "fn"], "fn"),
            (["capslock", "caps-lock", "caps_lock"], "⇪")
        ]
        let present = Set(shortcut.modifiers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let glyphs = order.compactMap { entry in
            present.contains(where: entry.names.contains) ? entry.glyph : nil
        }
        let key = shortcut.key == " " ? "Space" : shortcut.key.capitalized
        return (glyphs + [key]).joined()
    }

    /// Either a known modifier-only key or a key with at least one supported,
    /// distinct modifier — the same rule the recorder and the hotkey adapter
    /// apply (`ShortcutDefinition.isStructurallyValid`).
    private static func isUsable(_ shortcut: ShortcutDefinition) -> Bool {
        shortcut.isStructurallyValid
    }
}
