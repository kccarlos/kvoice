import Foundation
import KvoiceAppCore
import KvoiceDomain
@testable import KvoiceUI

/// ADR-022 slice 7: what every projection test needs — a real
/// `SettingsCoordinator` over a settable gate, an effect recorder, and a
/// recorder of every intent the view model sent (with its origin), wrapped
/// in a `SettingsProjectionHost`.
///
/// The coordinator is real on purpose: a refusal in these tests is the
/// reducer's own refusal under `gate = .jobActive`, not a stub's, so the
/// "snaps back with a note" contract is tested against the same code the
/// app runs. Nothing here waits on time or a stream.
@MainActor
final class SettingsProjectionTestHarness {
    let coordinator: SettingsCoordinator
    let host: SettingsProjectionHost

    init(settings: AppSettings = AppSettings(), localState: LocalState = .fresh) {
        // The closures below capture a box rather than `self`, because the
        // coordinator must exist before `self` is fully initialised.
        let box = Box()
        let coordinator = SettingsCoordinator(
            settings: settings,
            localState: localState,
            gate: { box.gate },
            effectRunner: { box.effects.append($0) }
        )
        self.coordinator = coordinator
        self.host = SettingsProjectionHost(
            coordinator: coordinator,
            send: { intent in
                box.sent.append(intent)
                return coordinator.send(intent)
            },
            sendLocalState: { intent in
                box.sentLocalState.append(intent)
                return coordinator.send(intent)
            }
        )
        self.box = box
    }

    @MainActor
    private final class Box {
        var gate = SettingsGate()
        var effects: [SettingsEffect] = []
        var sent: [SettingsIntent] = []
        var sentLocalState: [LocalStateIntent] = []
    }

    private let box: Box

    var settings: AppSettings { host.settings }
    var localState: LocalState { host.localState }

    /// A dictation job holds its snapshot: every idle-gated intent is refused.
    func startJob() { box.gate = SettingsGate(dictation: .jobActive) }
    func endJob() { box.gate = SettingsGate() }

    /// A change made from another door (an import, the status menu), so a
    /// test can assert the projection follows it with nothing re-applied.
    func commitFromElsewhere(_ intent: SettingsIntent) {
        _ = coordinator.send(intent)
    }

    func commitFromElsewhere(_ intent: LocalStateIntent) {
        _ = coordinator.send(intent)
    }

    func clearRecords() {
        box.effects.removeAll()
        box.sent.removeAll()
        box.sentLocalState.removeAll()
    }
}

extension SettingsProjectionTestHarness {
    /// The facts the reducer reads; `startJob()` / `endJob()` or assign.
    var gate: SettingsGate {
        get { box.gate }
        set { box.gate = newValue }
    }
    var effects: [SettingsEffect] { box.effects }
    /// Every `SettingsIntent` the view model handed the host, in order.
    var sent: [SettingsIntent] { box.sent }
    var sentLocalState: [LocalStateIntent] { box.sentLocalState }
}
