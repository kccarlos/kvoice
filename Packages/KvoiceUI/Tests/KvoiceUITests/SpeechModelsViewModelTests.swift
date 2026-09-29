import XCTest
import KvoiceAppCore
@testable import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceUI

/// ADR-017: the catalog half of the Models section derives its cards, offers
/// only the actions that fit each model's state, and filters. ADR-022
/// slice 7 part B: the language, per-model mode, and VAD rows are a
/// projection over `SettingsProjectionHost` — reading them is always live,
/// and writing them commits one `SettingsIntent` through the host rather
/// than forwarding a `SpeechModelAction` to the shell's `performer`.
@MainActor
final class SpeechModelsViewModelTests: XCTestCase {
    private let standard = SpeechModelCatalogEntry(
        id: "standard", displayName: "Whisper v3 Turbo", variantName: "Standard",
        family: "whisper-large-v3-turbo", runtime: .whisperKitCoreML, hosting: .onDevice,
        supportsStreaming: true, supportsBatch: true, downloadBytes: 650_000_000,
        languageSummary: "99 languages", summary: "Default.", isRecommended: true,
        revision: "rev", manifestResource: "standard", manifestSHA256: String(repeating: "a", count: 64)
    )
    private let high = SpeechModelCatalogEntry(
        id: "high", displayName: "Whisper v3 Turbo", variantName: "High-Accuracy",
        family: "whisper-large-v3-turbo", runtime: .whisperKitCoreML, hosting: .onDevice,
        supportsStreaming: true, supportsBatch: true, downloadBytes: 1_640_000_000,
        languageSummary: "99 languages", summary: "Bigger.", isRecommended: false,
        revision: "rev", manifestResource: "high", manifestSHA256: String(repeating: "b", count: 64)
    )
    private let reserved = SpeechModelCatalogEntry(
        id: "qwen", displayName: "Qwen3-ASR", variantName: "Standard",
        family: "qwen3-asr", runtime: .mlxQwen3ASR, hosting: .onDevice,
        supportsStreaming: true, supportsBatch: true, downloadBytes: 700_000_000,
        languageCodes: ["zh", "en"], languageSummary: "zh/en", summary: "Reserved.", isRecommended: false,
        revision: "rev", manifestResource: "qwen", manifestSHA256: String(repeating: "c", count: 64)
    )

    private func summary(_ id: ModelID) -> InstalledModelSummary {
        InstalledModelSummary(modelID: id, revision: "rev", ownership: .managedByKvoice)
    }

    private func snapshot(
        states: [ModelID: ModelLifecycleState],
        defaultID: ModelID = "standard",
        resident: ModelID? = nil,
        active: Bool = false,
        activity: ModelActivity = .idle
    ) -> SpeechModelsSnapshot {
        SpeechModelsSnapshot(
            catalog: SpeechModelCatalog(entries: [standard, high, reserved]),
            states: states,
            defaultModelID: defaultID,
            residentModelID: resident,
            dictationIsActive: active,
            activity: activity
        )
    }

    func testCardsDeriveStatusBadgesAndActionsFromState() {
        let model = SpeechModelsViewModel(snapshot: snapshot(
            states: ["standard": .ready(summary("standard")), "high": .absent],
            resident: "standard"
        ))

        let cards = model.cards
        XCTAssertEqual(cards.map(\.id), ["standard", "high", "qwen"])

        let standardCard = cards[0]
        XCTAssertTrue(standardCard.isDefault)
        XCTAssertTrue(standardCard.isResident)
        XCTAssertEqual(standardCard.statusDescription, "Default · Ready")
        XCTAssertEqual(standardCard.actions, [.delete], "the default cannot be 'used' again")
        XCTAssertEqual(standardCard.badges, ["On-Device", "Streaming or Batch", ModelSettingsViewModel.formatBytes(650_000_000)])
        XCTAssertEqual(standardCard.mode, .batch, "batch unless the user chose streaming")

        let highCard = cards[1]
        XCTAssertFalse(highCard.isDefault)
        XCTAssertEqual(highCard.statusDescription, "Not installed")
        XCTAssertEqual(highCard.actions, [.download])

        let reservedCard = cards[2]
        XCTAssertNil(reservedCard.state)
        XCTAssertFalse(reservedCard.isAvailableInThisBuild)
        XCTAssertEqual(reservedCard.statusDescription, "Not available in this version")
        XCTAssertTrue(reservedCard.actions.isEmpty)

        XCTAssertEqual(model.defaultCard?.id, "standard")
    }

    func testActionsPerLifecycleState() {
        XCTAssertEqual(SpeechModelsViewModel.actions(for: .absent, isDefault: false), [.download])
        XCTAssertEqual(SpeechModelsViewModel.actions(for: .downloadPaused(resumableBytes: 1), isDefault: false), [.resume])
        XCTAssertEqual(SpeechModelsViewModel.actions(for: .downloading(completed: 1, total: 2), isDefault: false), [.cancel])
        XCTAssertEqual(SpeechModelsViewModel.actions(for: .verifying(completedFiles: 1, totalFiles: 2), isDefault: false), [])
        XCTAssertEqual(SpeechModelsViewModel.actions(for: .loading, isDefault: true), [])
        XCTAssertEqual(SpeechModelsViewModel.actions(for: .ready(summary("x")), isDefault: false), [.use, .delete])
        XCTAssertEqual(SpeechModelsViewModel.actions(for: .ready(summary("x")), isDefault: true), [.delete])
        XCTAssertEqual(SpeechModelsViewModel.actions(for: .inference(summary("x"), jobID: UUID()), isDefault: true), [])
        XCTAssertEqual(SpeechModelsViewModel.actions(for: .error(ModelFailure(code: "c", message: "m")), isDefault: false), [.retry, .delete])
        XCTAssertEqual(SpeechModelsViewModel.actions(for: nil, isDefault: false), [])
    }

    func testRecommendedFilterKeepsRecommendedAndDefaultCards() {
        let model = SpeechModelsViewModel(snapshot: snapshot(
            states: ["standard": .absent, "high": .ready(summary("high"))],
            defaultID: "high"
        ))
        XCTAssertEqual(model.filter, .recommended)
        XCTAssertEqual(model.filteredCards.map(\.id), ["standard", "high"], "recommended plus the default")
        model.filter = .all
        XCTAssertEqual(model.filteredCards.map(\.id), ["standard", "high", "qwen"])
    }

    func testLifecycleActionsForwardToTheShellAndStayPendingUntilStateMoves() async {
        let recorder = ActionRecorder()
        let model = SpeechModelsViewModel(
            snapshot: snapshot(states: ["standard": .ready(summary("standard")), "high": .absent], resident: "standard"),
            pendingActionTimeout: .seconds(60),
            snapshotProvider: { nil },
            perform: { await recorder.record($0) }
        )
        let highCard = model.cards[1]

        model.perform(.download, on: highCard)
        XCTAssertTrue(model.isPending("high"))
        XCTAssertFalse(model.isEnabled(.download, for: model.cards[1]), "no double-click into two downloads")
        XCTAssertEqual(model.mutationDisabledReason(for: model.cards[1]), "Download…")
        await recorder.waitForCount(1)
        let actions = await recorder.actions
        XCTAssertEqual(actions, [.download("high")])

        // The next snapshot moves the card's state: the marker clears.
        model.apply(snapshot(
            states: ["standard": .ready(summary("standard")), "high": .downloading(completed: 1, total: 2)],
            resident: "standard"
        ))
        XCTAssertFalse(model.isPending("high"))
        XCTAssertEqual(model.cards[1].actions, [.cancel])
        XCTAssertEqual(model.cards[1].progress, 0.5)
        XCTAssertTrue(model.isEnabled(.cancel, for: model.cards[1]), "cancel is not a mutation")

        // Use switches the default; delete is confirmed by the view first
        // and then forwarded.
        model.apply(snapshot(
            states: ["standard": .ready(summary("standard")), "high": .ready(summary("high"))],
            resident: "standard"
        ))
        model.perform(.use, on: model.cards[1])
        model.perform(.delete, on: model.cards[0])
        await recorder.waitForCount(3)
        let later = await recorder.actions
        XCTAssertEqual(later, [.download("high"), .use("high"), .delete("standard")])
    }

    func testAPendingActionExpiresWhenTheShellNeverReacts() async throws {
        let clock = ParkingClock()
        let model = SpeechModelsViewModel(
            snapshot: snapshot(states: ["standard": .ready(summary("standard")), "high": .absent], resident: "standard"),
            pendingActionTimeout: .milliseconds(40),
            snapshotProvider: { nil },
            perform: { _ in },
            clock: clock
        )

        model.perform(.download, on: model.cards[1])
        XCTAssertTrue(model.isPending("high"))

        await clock.waitForSleepers(1)
        XCTAssertEqual(clock.pendingDurations, [.milliseconds(40)])
        let expiry = try XCTUnwrap(model.pendingTasks["high"])
        clock.advance(by: .milliseconds(39))
        XCTAssertTrue(model.isPending("high"), "the marker holds until the timeout has elapsed")
        clock.advance(by: .milliseconds(1))
        await awaitTask(expiry, "the pending-action timer never finished after its deadline")
        XCTAssertFalse(model.isPending("high"), "a shell that never answers must not lock the card for good")
        XCTAssertTrue(model.isEnabled(.download, for: model.cards[1]))
    }

    func testMutationsAreLockedWhileDictationIsActive() {
        let model = SpeechModelsViewModel(snapshot: snapshot(
            states: ["standard": .ready(summary("standard")), "high": .absent],
            resident: "standard",
            active: true
        ))
        let highCard = model.cards[1]
        XCTAssertFalse(model.isEnabled(.download, for: highCard))
        XCTAssertEqual(model.mutationDisabledReason(for: highCard), "Model changes are unavailable while dictation is running.")
        model.perform(.download, on: highCard)
        XCTAssertFalse(model.isPending("high"), "a refused action never becomes pending")
    }

    /// ADR-022 item 5: the engine-holding activities lock every card with
    /// the projection's own sentence; a package operation locks only its
    /// own card (through its state), so a second download can still be
    /// started — the shell pauses the first, as before.
    func testMutationsAreLockedWithAReasonWhileTheEngineIsHeld() {
        let states: [ModelID: ModelLifecycleState] = ["standard": .ready(summary("standard")), "high": .absent]
        let expectations: [(ModelActivity, SettingAvailabilityReason)] = [
            (.reloadingUnits, .reloadingComputeUnits),
            (.testing, .performanceTestRunning),
            (.transcribingFile, .fileTranscriptionRunning),
            (.unloading, .modelOperationInProgress)
        ]
        for (activity, reason) in expectations {
            let model = SpeechModelsViewModel(snapshot: snapshot(states: states, resident: "standard", activity: activity))
            let highCard = model.cards[1]
            XCTAssertFalse(model.isEnabled(.download, for: highCard), activity.name)
            XCTAssertEqual(model.mutationDisabledReason(for: highCard), DomainCopy.localized(reason.message), activity.name)
            XCTAssertFalse(model.isEnabled(.delete, for: model.cards[0]), activity.name)
        }
        // A download in its byte phase locks only its own card: Download on
        // another card pauses it (the documented behaviour).
        let downloading = SpeechModelsViewModel(snapshot: snapshot(
            states: ["standard": .ready(summary("standard")), "high": .downloading(completed: 1, total: 2)],
            resident: "standard",
            activity: .downloading("high")
        ))
        XCTAssertNil(downloading.engineActivityReason)
        XCTAssertTrue(downloading.isEnabled(.delete, for: downloading.cards[0]))
    }

    /// 2026-09-29: a load or a verification cannot be paused — cancelling
    /// one threw away the owner's 3.5-minute first compile — so every
    /// other card is locked with the sentence the shell would refuse with,
    /// the first compile's own ("first time only") included.
    func testALoadInFlightLocksEveryCardWithItsReason() {
        let cases: [(ModelActivity, ModelLifecycleState, SettingAvailabilityReason)] = [
            (.installing("standard"), .verifying(completedFiles: 1, totalFiles: 4), .modelLoadInProgress),
            (.installing("standard"), .loading, .modelLoadInProgress),
            (.installing("standard"), .optimizing, .modelOptimizing),
            (.downloading("standard"), .optimizing, .modelOptimizing),
            (.loading("standard"), .loading, .modelLoadInProgress)
        ]
        for (activity, state, reason) in cases {
            let model = SpeechModelsViewModel(snapshot: snapshot(
                states: ["standard": state, "high": .absent],
                activity: activity
            ))
            let highCard = model.cards[1]
            XCTAssertFalse(model.isEnabled(.download, for: highCard), "\(activity.name) \(state)")
            XCTAssertEqual(model.mutationDisabledReason(for: highCard), DomainCopy.localized(reason.message), "\(activity.name) \(state)")
        }
    }

    /// A refusal the shell reports after a click reads under the cards.
    func testTheShellsRefusalReadsAsTheSectionsNoteUntilNothingRuns() {
        var snapshot = snapshot(
            states: ["standard": .loading, "high": .absent],
            activity: .installing("standard")
        )
        snapshot.actionNote = "The speech model is loading. Model changes are available when it finishes."
        let model = SpeechModelsViewModel(snapshot: snapshot)
        XCTAssertEqual(model.refusalNote, snapshot.actionNote)

        snapshot.activity = .idle
        snapshot.states["standard"] = .ready(summary("standard"))
        let settled = SpeechModelsViewModel(snapshot: snapshot)
        XCTAssertNil(settled.refusalNote, "an operation would start now; the refusal is stale")
    }

    /// The language, per-model mode, and VAD rows commit through the host
    /// as soon as they are set — no poll lag, and no `SpeechModelAction`
    /// forwarded to the shell's `performer` (only the lifecycle actions use
    /// that door).
    func testSettingChangesCommitThroughTheHostAtOnce() {
        let harness = SettingsProjectionTestHarness()
        let model = SpeechModelsViewModel(
            host: harness.host,
            snapshot: snapshot(states: ["standard": .ready(summary("standard")), "high": .absent], resident: "standard"),
            snapshotProvider: { nil }
        )
        // Language names follow the interface language; pin English so the
        // assertion below does not depend on the machine's own language.
        model.languageNameLocale = Locale(identifier: "en")

        model.setMode(.streaming, for: "standard")
        XCTAssertEqual(model.mode(for: "standard"), .streaming)
        XCTAssertEqual(model.defaultCard?.mode, .streaming)
        let sentAfterMode = harness.sent.count
        model.setMode(.streaming, for: "standard")
        XCTAssertEqual(harness.sent.count, sentAfterMode, "an unchanged mode sends nothing")

        model.setTranscriptionLanguage("zh")
        XCTAssertEqual(model.transcriptionLanguage, "zh")
        XCTAssertEqual(model.transcriptionLanguageDisplayName, "Chinese")
        model.setTranscriptionLanguage(nil)
        XCTAssertEqual(model.transcriptionLanguageDisplayName, "Auto-detect")

        model.voiceActivityDetectionEnabled = false
        XCTAssertFalse(model.voiceActivityDetectionEnabled)

        XCTAssertEqual(harness.sent, [
            .setSpeechModelMode("standard", .streaming, origin: .page(.models)),
            .setTranscriptionLanguage("zh", origin: .page(.models)),
            .setTranscriptionLanguage(nil, origin: .page(.models)),
            .setVoiceActivityDetection(false, origin: .page(.models))
        ])
    }

    /// ADR-019: the four axes on the card — mode, punctuation, size,
    /// language coverage — plus the license line the CC-BY models require.
    func testCardShowsPunctuationAndLicenseWhenTheCatalogStatesThem() {
        let parakeet = SpeechModelCatalogEntry(
            id: "parakeet", displayName: "Parakeet Unified", variantName: "English",
            family: "parakeet-unified-en-0.6b", runtime: .fluidAudioParakeetUnified, hosting: .onDevice,
            supportsStreaming: true, supportsBatch: true, downloadBytes: 1_205_604_112,
            languageCodes: ["en"], languageSummary: "English only", summary: "Best English pick.", isRecommended: false,
            revision: "rev", manifestResource: "parakeet", manifestSHA256: String(repeating: "d", count: 64),
            punctuation: true, license: "CC-BY-4.0", attribution: "Parakeet Unified EN 0.6B by NVIDIA (CC-BY-4.0)."
        )
        let batchOnly = SpeechModelCatalogEntry(
            id: "tdt", displayName: "Parakeet TDT v3", variantName: "Multilingual",
            family: "parakeet-tdt-0.6b-v3", runtime: .fluidAudioParakeetTDT, hosting: .onDevice,
            supportsStreaming: false, supportsBatch: true, downloadBytes: 483_106_120,
            languageCodes: ["de", "en"], languageSummary: "25 European languages", summary: "Fast.", isRecommended: false,
            revision: "rev", manifestResource: "tdt", manifestSHA256: String(repeating: "e", count: 64),
            punctuation: false, license: "CC-BY-4.0"
        )
        let model = SpeechModelsViewModel(snapshot: SpeechModelsSnapshot(
            catalog: SpeechModelCatalog(entries: [standard, parakeet, batchOnly]),
            states: ["standard": .absent, "parakeet": .absent, "tdt": .absent],
            defaultModelID: "standard"
        ))
        let card = model.cards.first { $0.id == "parakeet" }!
        XCTAssertEqual(card.badges, [
            "On-Device", "Streaming or Batch", "Punctuation and capitalization", ModelSettingsViewModel.formatBytes(1_205_604_112)
        ])
        XCTAssertEqual(card.licenseLine, "CC-BY-4.0 · Parakeet Unified EN 0.6B by NVIDIA (CC-BY-4.0).")
        XCTAssertEqual(card.entry.availableModes, [.batch, .streaming])

        let tdt = model.cards.first { $0.id == "tdt" }!
        XCTAssertEqual(tdt.badges, ["On-Device", "Batch", "No punctuation", ModelSettingsViewModel.formatBytes(483_106_120)])
        XCTAssertEqual(tdt.licenseLine, "CC-BY-4.0")
        XCTAssertEqual(tdt.entry.availableModes, [.batch], "no streaming picker for a batch-only model")

        // An older entry that states neither shows no punctuation badge and no license line.
        let whisper = model.cards.first { $0.id == "standard" }!
        XCTAssertEqual(whisper.badges, ["On-Device", "Streaming or Batch", ModelSettingsViewModel.formatBytes(650_000_000)])
        XCTAssertNil(whisper.licenseLine)
    }

    func testLanguageOptionsFollowTheDefaultModelAndTheStoredLanguage() async {
        let harness = SettingsProjectionTestHarness()
        let model = SpeechModelsViewModel(host: harness.host, snapshot: snapshot(states: ["standard": .absent, "high": .absent]))
        XCTAssertEqual(model.languageOptions.count, TranscriptionLanguage.whisperLanguages.count)
        XCTAssertTrue(model.languageOptions.contains { $0.code == "yue" })

        // A reserved-runtime default with a language allowlist narrows it.
        model.apply(snapshot(states: ["standard": .absent, "high": .absent], defaultID: "qwen"))
        XCTAssertEqual(model.languageOptions.map(\.code), ["zh", "en"])

        // ADR-019 fallback rule: a selected language outside the default
        // model's coverage stays listed (so the picker shows it) and the
        // section warns, naming Whisper as the way out. The language is a
        // projection now, so a door other than this model commits it —
        // here, standing in for the status menu's `Language ▸` submenu.
        harness.commitFromElsewhere(.setTranscriptionLanguage("de", origin: .statusMenu))
        XCTAssertEqual(model.languageOptions.map(\.code), ["zh", "en", "de"])
        let warning = model.languageCoverageWarning
        XCTAssertEqual(warning?.contains("Qwen3-ASR — Standard does not support German"), true)
        XCTAssertEqual(warning?.contains("Whisper"), true)
        harness.commitFromElsewhere(.setTranscriptionLanguage("zh", origin: .statusMenu))
        XCTAssertNil(model.languageCoverageWarning)
        harness.commitFromElsewhere(.setTranscriptionLanguage(nil, origin: .statusMenu))
        XCTAssertNil(model.languageCoverageWarning, "auto-detect never warns")

        // Without a snapshot the section says so and shows nothing.
        let empty = SpeechModelsViewModel(snapshotProvider: { nil })
        await empty.refresh()
        XCTAssertFalse(empty.isAvailable)
        XCTAssertTrue(empty.cards.isEmpty)
        XCTAssertNil(empty.defaultCard)
        XCTAssertEqual(empty.transcriptionLanguageDisplayName, "Auto-detect")
    }
}

private actor ActionRecorder {
    private(set) var actions: [SpeechModelAction] = []

    func record(_ action: SpeechModelAction) {
        actions.append(action)
    }

    /// Forwarding happens on a detached-from-the-caller `Task`; wait for it
    /// rather than assuming one yield is enough.
    /// The 30 s deadline is a hang guard, not a timing assumption: a passing
    /// wait returns as soon as the action lands (a 2 s bound here could
    /// expire on a loaded CI runner).
    func waitForCount(
        _ count: Int,
        timeout: Duration = .seconds(30),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + timeout
        while actions.count < count {
            guard ContinuousClock.now < deadline else {
                XCTFail("\(count) action(s) never reached the shell (\(actions.count) did)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
