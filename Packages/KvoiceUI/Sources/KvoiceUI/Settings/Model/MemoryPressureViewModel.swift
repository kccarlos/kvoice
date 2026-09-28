import Foundation
import KvoiceAppCore
import KvoiceDomain
import Observation

/// Shell state for the memory-pressure warning (Later waves): the level, the
/// "Unload model now" action shared by the status menu and the Runtime
/// card's banner, and the opt-in automatic unload under `.critical`.
///
/// One instance lives for the app's lifetime as an `AppDelegate` property
/// (the `generalSettingsViewModel` pattern), not scoped to the Settings
/// window: the status menu's line and the automatic-unload behavior must
/// both work whether or not Settings is open, so the level and the decision
/// to auto-unload cannot live only inside a view scoped to that window.
///
/// ADR-022 slice 7: the opt-in is a read-only projection of
/// `AppSettings.freeModelMemoryUnderCriticalPressure` through the host —
/// the General page writes it; nothing here holds a copy.
@Observable
@MainActor
public final class MemoryPressureViewModel {
    /// The coordinator projection (read only here).
    public let host: SettingsProjectionHost
    public private(set) var level: MemoryPressureLevel
    public private(set) var isUnloading = false
    public private(set) var unloadError: String?

    private let isIdleProvider: @MainActor () -> Bool
    private let unloadAction: @MainActor () async throws -> Void
    /// Fired once per distinct level change, never per poll. The default is
    /// a no-op; the shell installs the diagnostic here.
    private let onLevelChange: @MainActor (MemoryPressureLevel) -> Void

    public init(
        host: SettingsProjectionHost = .detached(),
        level: MemoryPressureLevel = .normal,
        isIdle: @escaping @MainActor () -> Bool = { true },
        unload: @escaping @MainActor () async throws -> Void = {},
        onLevelChange: @escaping @MainActor (MemoryPressureLevel) -> Void = { _ in }
    ) {
        self.host = host
        self.level = level
        self.isIdleProvider = isIdle
        self.unloadAction = unload
        self.onLevelChange = onLevelChange
    }

    /// Settings › General's opt-in, read from the stored settings; off by
    /// default.
    public var autoUnloadEnabled: Bool { host.settings.freeModelMemoryUnderCriticalPressure }

    // MARK: Inputs

    /// Applies an observed level change. De-duplicated: a repeat of the
    /// current level (the observer already de-duplicates, but a second
    /// caller — a resumed stream, a test — must not double-fire) is ignored.
    /// Fires the diagnostic hook exactly once for a real change and, only
    /// when the user opted in and the system is idle, starts an automatic
    /// unload on the transition into `.critical`.
    public func apply(level newLevel: MemoryPressureLevel) {
        guard newLevel != level else { return }
        level = newLevel
        onLevelChange(newLevel)
        guard newLevel == .critical, autoUnloadEnabled, unloadDisabledReason == nil else { return }
        unloadNow()
    }

    // MARK: Derived state

    /// The Runtime card shows its amber banner at both `.warning` and
    /// `.critical`; only `.critical` additionally offers the unload button.
    public var showsBanner: Bool { level != .normal }
    public var isCritical: Bool { level == .critical }

    /// Why "Unload model now" is disabled, or nil when it can run. Mirrors
    /// `RuntimeCardViewModel.controlsDisabledReason`'s shape so both surfaces
    /// read the same way.
    public var unloadDisabledReason: String? {
        if isUnloading { return String(localized: "Unloading…", bundle: .module) }
        if !isIdleProvider() { return String(localized: "Finish the current dictation first.", bundle: .module) }
        return nil
    }

    public var canUnloadNow: Bool { unloadDisabledReason == nil }

    // MARK: Actions

    /// "Unload model now" — the status-menu item and the banner's button
    /// both call this, so they share one in-flight state and one error.
    public func unloadNow() {
        guard canUnloadNow else { return }
        isUnloading = true
        unloadError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.unloadAction()
            } catch {
                self.unloadError = Self.message(for: error)
            }
            self.isUnloading = false
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? KVoiceError, error.code == .appBusy {
            return String(localized: "Finish the current dictation first.", bundle: .module)
        }
        return String(localized: "Could not unload the model: \(error.localizedDescription)", bundle: .module)
    }
}
