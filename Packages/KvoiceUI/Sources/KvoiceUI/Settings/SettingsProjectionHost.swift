import Foundation
import KvoiceAppCore
import KvoiceDomain
import Observation

/// ADR-022 slice 7: the one thing a settings page view model owns instead
/// of a copy of `AppSettings`.
///
/// A page view model is a *projection*: it reads the coordinator's values
/// through `settings` / `localState` / `effective` / `environment` (each a
/// pass-through to `SettingsCoordinator`, `@Observable`, so a SwiftUI body
/// that reads them re-renders on the next commit), and every edit is a
/// `SettingsIntent` or `LocalStateIntent` handed to `send`. The host owns
/// nothing else: no stored `AppSettings`, no slice of one, nothing the shell
/// has to re-apply. What used to be the `.hydrate([projection])` effect is
/// therefore impossible to forget — there is no second copy to hydrate.
///
/// **Refusals.** `send` returns the reducer's `SettingsRefusal?`. The state
/// is then untouched, so a bound control already shows the stored value;
/// the host stores the refusal's sentence in `refusalNote` (a page renders
/// it as its footer note) and the mutation is what makes SwiftUI re-read the
/// bindings, so a toggle that was clicked snaps back in the same turn. The
/// note clears on the next accepted send.
///
/// **The draft rule.** A control that cannot commit per keystroke (a text
/// field, the shortcut recorder) keeps a *draft* as local UI state — `@State`
/// in the view, or a plain stored property on the view model — and commits
/// it as one intent on submit / end of editing. A draft is never a second
/// source of truth: it is discarded when the projected value changes
/// underneath it (`.onChange(of: projectedValue) { draft = $0 }`), and a
/// refused commit leaves the draft in place with `refusalNote` set so the
/// user can retry or revert. `DictionaryTermCell` in
/// `DictionarySectionView` is the reference implementation.
///
/// **Sends are synchronous.** `SettingsCoordinator.send` is a `@MainActor`
/// function, and a SwiftUI `Binding` setter cannot await; a synchronous
/// send is what lets the refusal snap the control back in the same run-loop
/// turn. The shell's closure is `AppDelegate.sendSettingsIntent`, which
/// also recomputes the availability table after the commit.
///
/// **Tests** build the host over a real `SettingsCoordinator` with a fake
/// gate and an effect recorder (`SettingsProjectionHostTests`,
/// `SettingsProjectionTestHarness`), so a refusal is the reducer's own
/// refusal rather than a stub's.
@Observable
@MainActor
public final class SettingsProjectionHost {
    /// The coordinator this host projects. Read its values through the
    /// pass-throughs below; never call `send` on it directly from a view
    /// model — the host's `send` is the door that records refusals.
    @ObservationIgnored public let coordinator: SettingsCoordinator

    /// The sentence for the last refusal, or nil. Cleared by the next
    /// accepted send or by `clearRefusalNote()`.
    public private(set) var refusalNote: String?

    private let settingsSender: @MainActor (SettingsIntent) -> SettingsRefusal?
    private let localStateSender: @MainActor (LocalStateIntent) -> SettingsRefusal?

    /// - Parameters:
    ///   - coordinator: the single source of truth.
    ///   - send: the shell's door (`AppDelegate.sendSettingsIntent`); the
    ///     default is the coordinator's own `send`, which is right for a
    ///     preview or a test but skips the shell's availability refresh.
    ///   - sendLocalState: the local-state door, same rule.
    public init(
        coordinator: SettingsCoordinator,
        send: (@MainActor (SettingsIntent) -> SettingsRefusal?)? = nil,
        sendLocalState: (@MainActor (LocalStateIntent) -> SettingsRefusal?)? = nil
    ) {
        self.coordinator = coordinator
        self.settingsSender = send ?? { [coordinator] in coordinator.send($0) }
        self.localStateSender = sendLocalState ?? { [coordinator] in coordinator.send($0) }
    }

    /// A host over a fresh coordinator that accepts everything and runs no
    /// effect: what a preview or a view-only test needs. Never used by the
    /// shell.
    public static func detached(settings: AppSettings = AppSettings(), localState: LocalState = .fresh) -> SettingsProjectionHost {
        SettingsProjectionHost(
            coordinator: SettingsCoordinator(
                settings: settings,
                localState: localState,
                gate: { SettingsGate() },
                effectRunner: { _ in }
            )
        )
    }

    // MARK: Reading

    public var settings: AppSettings { coordinator.settings }
    public var localState: LocalState { coordinator.localState }
    public var effective: EffectiveSettings { coordinator.effective }
    public var environment: EnvironmentProfile { coordinator.environment }

    // MARK: Writing

    /// Sends one intent. Returns the refusal (and records its note) when
    /// the gate refused it; nil when it was committed.
    @discardableResult
    public func send(_ intent: SettingsIntent) -> SettingsRefusal? {
        let refusal = settingsSender(intent)
        record(refusal)
        return refusal
    }

    @discardableResult
    public func send(_ intent: LocalStateIntent) -> SettingsRefusal? {
        let refusal = localStateSender(intent)
        record(refusal)
        return refusal
    }

    public func clearRefusalNote() {
        if refusalNote != nil { refusalNote = nil }
    }

    private func record(_ refusal: SettingsRefusal?) {
        // Assigned unconditionally on a refusal (even the same sentence
        // twice): the mutation is what re-renders the page so a bound
        // control re-reads the stored value.
        if let refusal {
            refusalNote = Self.note(for: refusal)
        } else if refusalNote != nil {
            refusalNote = nil
        }
    }

    /// The user-facing sentence for a refusal. The typed note on the
    /// refusal picks the specific sentence; every other reason reads as the
    /// generic one the pages already used.
    public static func note(for refusal: SettingsRefusal) -> String {
        switch refusal.note {
        case .dictionaryKeepsListDuringDictation:
            return String(localized: "Finish the current dictation first — a running dictation keeps the list it started with.", bundle: .module)
        case nil:
            return String(localized: "Finish the current dictation first.", bundle: .module)
        }
    }
}
