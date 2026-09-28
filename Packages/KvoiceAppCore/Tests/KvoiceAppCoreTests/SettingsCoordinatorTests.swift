import XCTest
import KvoiceDomain
@testable import KvoiceAppCore

/// ADR-022 item 4: the coordinator with a fake gate and an effect recorder.
@MainActor
final class SettingsCoordinatorTests: XCTestCase {
    private var gate = SettingsGate.idle
    private var effects: [SettingsEffect] = []
    private var refusals: [(SettingsIntent, SettingsRefusal)] = []

    private func makeCoordinator(settings: AppSettings = AppSettings()) -> SettingsCoordinator {
        let coordinator = SettingsCoordinator(
            settings: settings,
            gate: { [unowned self] in self.gate },
            effectRunner: { [unowned self] effect in self.effects.append(effect) }
        )
        coordinator.onRefusal = { [unowned self] intent, refusal in self.refusals.append((intent, refusal)) }
        return coordinator
    }

    func testAnAcceptedIntentCommitsStateRunsEffectsInOrderAndReturnsNil() {
        let coordinator = makeCoordinator()
        let refusal = coordinator.send(.setShowDockIcon(true, origin: .page(.general)))
        XCTAssertNil(refusal)
        XCTAssertTrue(coordinator.settings.showDockIcon)
        XCTAssertEqual(effects, [.applyActivationPolicy, .persist, .rebuildMenu])
        XCTAssertTrue(refusals.isEmpty)
    }

    func testARefusedIntentLeavesStateRunsNoEffectAndReportsTheRefusal() {
        let coordinator = makeCoordinator()
        gate = SettingsGate(dictation: .jobActive)
        let refusal = coordinator.send(.setShowDockIcon(true, origin: .page(.general)))
        XCTAssertEqual(refusal?.reason, .dictationInProgress)
        XCTAssertFalse(coordinator.settings.showDockIcon)
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(refusals.count, 1)
        XCTAssertEqual(refusals.first?.1.intent, "setShowDockIcon")
    }

    func testTheGateIsReadPerSend() {
        let coordinator = makeCoordinator()
        gate = SettingsGate(dictation: .jobActive)
        XCTAssertNotNil(coordinator.send(.setTypedInsertionEnabled(false, origin: .page(.recording))))
        gate = .idle
        XCTAssertNil(coordinator.send(.setTypedInsertionEnabled(false, origin: .page(.recording))))
        XCTAssertFalse(coordinator.settings.typedInsertionEnabled)
    }

    func testSecretsRunTheSaveEffectWithoutTouchingTheState() {
        let settings = AppSettings()
        let coordinator = makeCoordinator(settings: settings)
        let secrets = SecretSettings(apiKey: "sk-test")
        XCTAssertNil(coordinator.send(.setSecrets(secrets, origin: .page(.aiActions))))
        XCTAssertEqual(coordinator.settings, settings)
        XCTAssertEqual(effects, [.saveSecrets(secrets)])
    }

    func testLoadReplacesTheStateWithoutEffects() {
        let coordinator = makeCoordinator()
        var loaded = AppSettings()
        loaded.historyEnabled = false
        coordinator.load(loaded)
        XCTAssertEqual(coordinator.settings, loaded)
        XCTAssertTrue(effects.isEmpty)
    }

    func testSnapshotsDeliverTheCurrentValueThenEveryChange() async {
        let coordinator = makeCoordinator()
        let stream = coordinator.snapshots()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, AppSettings())

        coordinator.send(.setHistoryEnabled(false, origin: .page(.history)))
        let second = await iterator.next()
        XCTAssertEqual(second?.historyEnabled, false)

        coordinator.send(.setShowDockIcon(true, origin: .page(.general)))
        let third = await iterator.next()
        XCTAssertEqual(third?.showDockIcon, true)
    }

    func testSnapshotsKeepOnlyTheNewestValueForASlowConsumer() async {
        let coordinator = makeCoordinator()
        let stream = coordinator.snapshots()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        // Three changes before the consumer reads: it sees the last state,
        // never a backlog (same policy as `DictationController.snapshots()`).
        coordinator.send(.setLaunchAtLogin(true, origin: .page(.general)))
        coordinator.send(.setHistoryEnabled(false, origin: .page(.history)))
        coordinator.send(.setShowDockIcon(true, origin: .page(.general)))
        let latest = await iterator.next()
        XCTAssertEqual(latest?.launchAtLogin, true)
        XCTAssertEqual(latest?.historyEnabled, false)
        XCTAssertEqual(latest?.showDockIcon, true)
    }

    func testANoOpIntentAndARefusalPublishNoSnapshot() async {
        let coordinator = makeCoordinator()
        let stream = coordinator.snapshots()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        // Unchanged value: the reducer reports no change, nothing is yielded.
        coordinator.send(.setSelectedModel(nil, origin: .shell))
        coordinator.send(.setSelectedModel(nil, origin: .shell))
        // Refused: nothing is yielded either.
        gate = SettingsGate(dictation: .jobActive)
        coordinator.send(.setShowDockIcon(true, origin: .page(.general)))
        gate = .idle
        // The next real change is the first thing the consumer sees, and it
        // carries neither the refused nor a phantom write.
        coordinator.send(.setHistoryEnabled(false, origin: .page(.history)))
        let next = await iterator.next()
        XCTAssertEqual(next?.showDockIcon, false)
        XCTAssertEqual(next?.historyEnabled, false)
        XCTAssertNil(next?.selectedModel)
    }

    // MARK: Local state (ADR-022 slice 5)

    func testLocalStateIntentsCommitAndPersistThroughTheSameRunner() {
        let coordinator = makeCoordinator()
        XCTAssertEqual(coordinator.localState, .fresh)
        XCTAssertNil(coordinator.send(.setMainWindowSection("history", origin: .shell)))
        XCTAssertEqual(coordinator.localState.mainWindowSection, "history")
        XCTAssertEqual(effects, [.persistLocalState])
        // The settings blob is untouched by a local-state write, and vice
        // versa: two values, two intents, one owner.
        XCTAssertEqual(coordinator.settings, AppSettings())
        effects = []
        coordinator.send(.setHistoryEnabled(false, origin: .page(.history)))
        XCTAssertEqual(coordinator.localState.mainWindowSection, "history")
        XCTAssertFalse(effects.contains(.persistLocalState))
    }

    func testLocalStateRefusalLeavesTheStateAndReportsIt() {
        let coordinator = makeCoordinator()
        var refused: [(LocalStateIntent, SettingsRefusal)] = []
        coordinator.onLocalStateRefusal = { refused.append(($0, $1)) }
        gate = SettingsGate(settingsLoaded: false)
        let refusal = coordinator.send(.markTutorialSeen(origin: .shell))
        XCTAssertEqual(refusal?.reason, .notLoaded)
        XCTAssertEqual(coordinator.localState, .fresh)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(refused.count, 1)
        XCTAssertEqual(refused.first?.0, .markTutorialSeen(origin: .shell))
    }

    // MARK: Effective settings (ADR-022 slice 5)

    func testEffectiveTableFollowsCommitsLoadsAndTheEnvironment() {
        let coordinator = makeCoordinator()
        XCTAssertEqual(coordinator.effective.recorderStyle, Resolved(.mini, .default))
        XCTAssertEqual(coordinator.effective.dictionaryTokenBudget.value, nil)

        // A commit re-resolves.
        coordinator.send(.setTriggers(TriggerSettingsSnapshot(recorderStyle: .notch), origin: .page(.recording)))
        XCTAssertEqual(coordinator.effective.recorderStyle, Resolved(.notch, .user))

        // A load re-resolves too.
        coordinator.load(AppSettings())
        XCTAssertEqual(coordinator.effective.recorderStyle.provenance, .default)

        // The environment clamps: the Whisper cap under the catalog's.
        coordinator.observe(environment: EnvironmentProfile(
            enginePromptTokenLimit: .tokens(111), catalogPromptTokenLimit: 224, residentModelID: "whisper"
        ))
        XCTAssertEqual(coordinator.effective.dictionaryTokenBudget.value?.budget, 99)
        XCTAssertEqual(coordinator.effective.dictionaryTokenBudget.provenance, .limitedBy(SettingsResolver.enginePromptCapFact))
        XCTAssertEqual(coordinator.environment.residentModelID, "whisper")
        // Observing the environment runs no effect: nothing the user chose
        // changed.
        effects = []
        coordinator.observe(environment: EnvironmentProfile(memoryPressureLevel: .critical))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(coordinator.environment.memoryPressureLevel, .critical)
    }

    func testEffectsRunAgainstTheReResolvedTable() {
        // The runner reads `effective` while an effect runs, so the
        // re-resolve must precede the first effect.
        var seen: [Provenance] = []
        let box = CoordinatorBox()
        let observing = SettingsCoordinator(
            gate: { .idle },
            effectRunner: { _ in
                if let c = box.coordinator { seen.append(c.effective.recorderStyle.provenance) }
            }
        )
        box.coordinator = observing
        observing.send(.setTriggers(TriggerSettingsSnapshot(recorderStyle: .notch), origin: .page(.recording)))
        XCTAssertEqual(seen.first, .user)
    }

    func testDeveloperOverrideProvenanceReachesTheEffectiveTable() {
        var values = DeveloperDefaults.compiled
        values.hybridTapWindowMilliseconds = 300
        let loaded = LoadedDeveloperDefaults(values: values, overrideOutcome: .applied([.hybridTapWindowMilliseconds]))
        let coordinator = SettingsCoordinator(
            developerDefaults: loaded,
            gate: { [unowned self] in self.gate },
            effectRunner: { [unowned self] effect in self.effects.append(effect) }
        )
        XCTAssertEqual(coordinator.effective.hybridTapWindow, Resolved(.milliseconds(300), .override))
        XCTAssertEqual(coordinator.effective.doublePressWindow.provenance, .default)
    }

    func testResetToDefaultGoesThroughTheSameDoor() {
        var settings = AppSettings()
        settings.maxRecordingSeconds = 1_800
        let coordinator = makeCoordinator(settings: settings)
        XCTAssertTrue(coordinator.effective.maxRecordingSeconds.isChangedFromDefault)
        XCTAssertNil(coordinator.send(.resetToDefault(.maxRecordingSeconds, origin: .page(.recording))))
        XCTAssertEqual(coordinator.settings.maxRecordingSeconds, 600)
        XCTAssertFalse(coordinator.effective.maxRecordingSeconds.isChangedFromDefault)
        XCTAssertEqual(effects, [.applyTriggerSettings, .persist, .rebuildMenu])
    }

    func testLoadingLocalStateRunsNoEffect() {
        let coordinator = makeCoordinator()
        coordinator.load(localState: LocalState(tutorialSeen: true))
        XCTAssertTrue(coordinator.localState.tutorialSeen)
        XCTAssertEqual(effects, [])
    }

    func testEffectsSeeTheCommittedState() {
        // The shell's runner reads `currentSettings` (the coordinator's
        // state) while running an effect, so the commit must precede the
        // first effect.
        var seen: [Bool] = []
        var reader: SettingsCoordinator!
        reader = SettingsCoordinator(settings: AppSettings(), gate: { .idle }, effectRunner: { _ in
            seen.append(reader.settings.showDockIcon)
        })
        reader.send(.setShowDockIcon(true, origin: .page(.general)))
        XCTAssertEqual(seen, [true, true, true])
    }
}

@MainActor
private final class CoordinatorBox {
    var coordinator: SettingsCoordinator?
}
