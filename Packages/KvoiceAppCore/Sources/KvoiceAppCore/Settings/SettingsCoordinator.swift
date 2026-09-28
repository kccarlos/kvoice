import Foundation
import KvoiceDomain
import Observation

/// ADR-022 item 4: owns the single `AppSettings` value — and, since slice
/// 5, the single `LocalState` value beside it.
///
/// Nobody else stores the truth: the shell's `currentSettings` /
/// `currentLocalState` are projections of `settings` / `localState`, and
/// every write is a `SettingsIntent` or a `LocalStateIntent` sent here. `send(_:)` asks the shell for the current `SettingsGate`, runs the
/// pure `SettingsReducer`, commits the new state, hands each
/// `SettingsEffect` to the shell's runner in order, publishes a snapshot,
/// and returns the refusal (if any) so the caller can put its control back.
///
/// Same shape as `DictationController`: `@Observable` for a SwiftUI
/// projection, plus `snapshots()` — an `AsyncStream` that delivers the
/// current value first and then every change, newest-value buffered — for
/// consumers on their own clock. The settings view models are projections
/// over the `@Observable` side through `SettingsProjectionHost` (KvoiceUI;
/// ADR-022 slice 7 part A: General, triggers, audio input, Dictionary,
/// Data & Privacy, the memory opt-in, the wizard); a page needs no stream
/// because a SwiftUI body that reads `settings` re-renders on the commit.
@MainActor
@Observable
public final class SettingsCoordinator {
    /// The one `AppSettings` value. Read freely; write only through `send`.
    public private(set) var settings: AppSettings
    /// The one `LocalState` value (ADR-022 slice 5). Read freely; write only
    /// through `send(_ intent: LocalStateIntent)`. Never exported: the
    /// backup envelope wraps `settings` alone.
    public private(set) var localState: LocalState
    /// The developer layer as loaded at launch (ADR-022 slice 5). Fixed for
    /// the process; the resolver reads it and its per-key provenance.
    public let developerDefaults: LoadedDeveloperDefaults
    /// The observed facts as last published by the shell
    /// (`observe(environment:)`). Never persisted.
    public private(set) var environment: EnvironmentProfile
    /// `SettingsResolver.resolve(user:defaults:environment:)` over the
    /// three values above, recomputed on every commit, load, and
    /// environment change. The pages read provenance from here.
    public private(set) var effective: EffectiveSettings

    @ObservationIgnored private let gate: @MainActor () -> SettingsGate
    @ObservationIgnored private let effectRunner: @MainActor (SettingsEffect) -> Void
    /// Observed by the shell for one scalar diagnostic line per refusal.
    @ObservationIgnored public var onRefusal: @MainActor (SettingsIntent, SettingsRefusal) -> Void = { _, _ in }
    @ObservationIgnored public var onLocalStateRefusal: @MainActor (LocalStateIntent, SettingsRefusal) -> Void = { _, _ in }
    @ObservationIgnored private var continuations: [UUID: AsyncStream<AppSettings>.Continuation] = [:]

    public init(
        settings: AppSettings = AppSettings(),
        localState: LocalState = .fresh,
        developerDefaults: LoadedDeveloperDefaults = .compiled,
        environment: EnvironmentProfile = .unknown,
        gate: @escaping @MainActor () -> SettingsGate,
        effectRunner: @escaping @MainActor (SettingsEffect) -> Void
    ) {
        self.settings = settings
        self.localState = localState
        self.developerDefaults = developerDefaults
        self.environment = environment
        self.effective = Self.resolve(settings, developerDefaults, environment)
        self.gate = gate
        self.effectRunner = effectRunner
    }

    private static func resolve(
        _ settings: AppSettings, _ defaults: LoadedDeveloperDefaults, _ environment: EnvironmentProfile
    ) -> EffectiveSettings {
        SettingsResolver.resolve(
            user: settings,
            defaults: defaults.values,
            environment: environment,
            overriddenKeys: Set(defaults.overriddenKeys)
        )
    }

    /// The shell publishes a fresh `EnvironmentProfile` (the slow poll, a
    /// memory-pressure change); the effective table follows. Equality-
    /// guarded so a poll that observed nothing new re-renders nothing.
    public func observe(environment: EnvironmentProfile) {
        guard environment != self.environment else { return }
        self.environment = environment
        refreshEffective()
    }

    private func refreshEffective() {
        let next = Self.resolve(settings, developerDefaults, environment)
        if next != effective { effective = next }
    }

    /// Decides, commits, runs the effects, publishes. Returns the refusal
    /// when the gate refused; the state is then untouched and no effect ran.
    @discardableResult
    public func send(_ intent: SettingsIntent) -> SettingsRefusal? {
        let result = SettingsReducer.reduce(state: settings, intent: intent, gate: gate())
        if let refusal = result.refusal {
            onRefusal(intent, refusal)
            return refusal
        }
        let changed = result.state != settings
        settings = result.state
        if changed { refreshEffective() }
        for effect in result.effects {
            effectRunner(effect)
        }
        if changed { publish() }
        return nil
    }

    /// The local-state counterpart of `send`: `LocalStateReducer` under the
    /// same gate, the same effect runner, the same refusal hook. Local
    /// state has no snapshot stream — nothing outside the shell projects it.
    @discardableResult
    public func send(_ intent: LocalStateIntent) -> SettingsRefusal? {
        let result = LocalStateReducer.reduce(state: localState, intent: intent, gate: gate())
        if let refusal = result.refusal {
            onLocalStateRefusal(intent, refusal)
            return refusal
        }
        localState = result.state
        for effect in result.effects {
            effectRunner(effect)
        }
        return nil
    }

    /// Hydration from disk (the launch load): replaces the state without
    /// running the reducer or any effect. The shell applies the load's own
    /// derived effects itself, exactly as before the coordinator existed.
    public func load(_ loaded: AppSettings) {
        settings = loaded
        refreshEffective()
        publish()
    }

    /// Hydration of the local blob (the launch load).
    public func load(localState loaded: LocalState) {
        localState = loaded
    }

    /// Delivers the current value immediately, then every change. Each
    /// subscriber keeps only the newest value.
    public func snapshots() -> AsyncStream<AppSettings> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AppSettings>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations.removeValue(forKey: id) }
        }
        continuations[id] = continuation
        continuation.yield(settings)
        return stream
    }

    private func publish() {
        for continuation in continuations.values {
            continuation.yield(settings)
        }
    }
}
