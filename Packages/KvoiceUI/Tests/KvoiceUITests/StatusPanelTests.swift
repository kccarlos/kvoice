import AppKit
import SwiftUI
import XCTest
@testable import KvoiceDomain
@testable import KvoiceUI

/// P-D4: the status panel — the projection per phase (idle, recording,
/// downloading, blocked, finishing, outcome, terminating), the
/// no-meter-outside-a-recording rule at the panel's seam, the command
/// hooks, the close-first policy, the key routing, the focus order, and
/// that the view renders every phase in both appearances without a shell.
@MainActor
final class StatusPanelTests: XCTestCase {
    private static let recordingHUD = HUDViewState(
        phase: .recording(HUDRecordingState(inputLevel: 0.6, elapsed: .seconds(7), captureStarted: true))
    )
    private static let startingHUD = HUDViewState(
        phase: .recording(HUDRecordingState(inputLevel: 0.6, elapsed: .seconds(7), captureStarted: false))
    )

    /// A context like the shell fills in the idle, ready state.
    static func context(
        readinessTitle: String = "Ready",
        isBlocked: Bool = false,
        fixTitle: String = "Fix in Speech Models…",
        ai: StatusPanelContext.AI = StatusPanelContext.AI(
            isOn: true, canToggle: true, help: "Turns AI processing off.",
            defaultActionName: "Polish", defaultActionBadge: "⌘1", configurationName: "Local Ollama",
            defaultActions: StatusPanelChooser(choices: [
                StatusPanelChoice(id: "polish", title: "Polish", isSelected: true, command: .selectDefaultAction(UUID())),
            ]),
            configurations: StatusPanelChooser(choices: [
                StatusPanelChoice(id: "ollama", title: "Local Ollama", isSelected: true, command: .selectConfiguration(UUID())),
            ])
        ),
        canRecoverFailedInsertion: Bool = false,
        memoryPressure: StatusPanelContext.MemoryPressure? = nil,
        historyTitle: String = "History"
    ) -> StatusPanelContext {
        StatusPanelContext(
            readinessTitle: readinessTitle,
            isBlocked: isBlocked,
            fixTitle: fixTitle,
            modelName: "Whisper large-v3-turbo",
            modelChooser: StatusPanelChooser(
                choices: [StatusPanelChoice(id: "whisper", title: "Whisper large-v3-turbo — Standard", isSelected: true, isEnabled: false, command: .selectModel("whisper"))],
                footer: [StatusPanelChoice(id: "manage", title: "Manage Models…", command: .openModels)]
            ),
            languageName: "Auto-detect",
            languageChooser: StatusPanelChooser(choices: [StatusPanelChoice(id: "auto", title: "Auto-detect", isSelected: true, command: .selectLanguage(nil))]),
            microphoneName: "MacBook Pro Microphone",
            microphoneChooser: StatusPanelChooser(
                choices: [StatusPanelChoice(id: "default", title: "System Default (MacBook Pro Microphone)", isSelected: true, command: .selectMicrophone(uid: nil))],
                footer: [StatusPanelChoice(id: "settings", title: "Microphone Settings…", command: .openAudioInput)]
            ),
            ai: ai,
            canCopyLastTranscription: true,
            copyLastTranscriptionHelp: "Copies the final text of the newest history entry.",
            canRecoverFailedInsertion: canRecoverFailedInsertion,
            memoryPressure: memoryPressure,
            historyTitle: historyTitle
        )
    }

    static func state(
        _ headerContext: StatusMenuHeaderContext = StatusMenuHeaderContext(shortcutGlyphs: "⌃⇧Space"),
        hud: HUDViewState = .idle,
        context: StatusPanelContext = context()
    ) -> StatusPanelState {
        StatusPanelState(
            header: StatusMenuHeaderState(context: headerContext, hud: hud),
            headerContext: headerContext,
            context: context
        )
    }

    // MARK: Projection table

    func testIdleReadyShowsStartTheShortcutCapsAndCopyLast() {
        let state = Self.state()
        XCTAssertEqual(state.primaryTitle, "Start Recording")
        XCTAssertTrue(state.primaryIsEnabled)
        XCTAssertEqual(state.primaryGlyph, .start)
        XCTAssertEqual(state.readiness, "Ready · Whisper large-v3-turbo")
        XCTAssertFalse(state.readinessIsAttention)
        XCTAssertEqual(state.shortcutKeys, ["⌃", "⇧", "Space"])
        XCTAssertNil(state.shortcutNote)
        XCTAssertEqual(state.feed, .none)
        XCTAssertFalse(state.showsMeter)
        XCTAssertEqual(state.dictationRows.map(\.id), [.copyLastTranscription])
        XCTAssertEqual(state.dictationRows.first?.command, .copyLastTranscription)
        XCTAssertEqual(state.dictationRows.first?.help, "Copies the final text of the newest history entry.")
        XCTAssertEqual(state.primaryAccessibilityLabel, "Start Recording, Ready · Whisper large-v3-turbo, ⌃⇧Space")
    }

    func testIdleWithoutAShortcutShowsTheNoteInTheCapSlot() {
        let state = Self.state(StatusMenuHeaderContext(shortcutNote: "No Shortcut"))
        XCTAssertEqual(state.shortcutKeys, [])
        XCTAssertEqual(state.shortcutNote, "No Shortcut")
        XCTAssertEqual(state.primaryAccessibilityLabel, "Start Recording, Ready · Whisper large-v3-turbo, No Shortcut")
    }

    func testValueRowsCarryTheMenuTitlesValuesAndChoosers() {
        let state = Self.state()
        XCTAssertEqual(state.modelRow.title, "Model")
        XCTAssertEqual(state.modelRow.value, "Whisper large-v3-turbo")
        XCTAssertEqual(state.modelRow.symbol, "waveform")
        XCTAssertEqual(state.modelRow.chooser?.footer.first?.command, .openModels)
        XCTAssertEqual(state.modelRow.accessibilityLabel, "Model, Whisper large-v3-turbo")
        XCTAssertEqual(state.languageRow.value, "Auto-detect")
        XCTAssertEqual(state.languageRow.symbol, "globe")
        XCTAssertEqual(state.microphoneRow.value, "MacBook Pro Microphone")
        XCTAssertEqual(state.microphoneRow.symbol, "mic")
        XCTAssertEqual(state.microphoneRow.chooser?.footer.first?.command, .openAudioInput)
        XCTAssertTrue(state.modelRow.isEnabled)
        XCTAssertNil(state.modelRow.command, "a chooser row has no single command")
    }

    func testAISectionMirrorsTheMenusSwitchAndSubmenus() {
        let state = Self.state()
        XCTAssertEqual(state.aiSwitch.title, "Use AI Actions")
        XCTAssertTrue(state.aiIsOn)
        XCTAssertTrue(state.aiSwitch.isEnabled)
        XCTAssertEqual(state.aiSwitch.help, "Turns AI processing off.")
        XCTAssertEqual(state.aiSwitch.command, .toggleAI)
        XCTAssertEqual(state.defaultActionRow.value, "Polish")
        XCTAssertEqual(state.defaultActionRow.keyCap, "⌘1")
        XCTAssertEqual(state.defaultActionRow.accessibilityLabel, "Default Action, Polish, ⌘1")
        XCTAssertEqual(state.configurationRow.value, "Local Ollama")

        let off = Self.state(context: Self.context(ai: StatusPanelContext.AI(isOn: false, canToggle: false)))
        XCTAssertFalse(off.aiIsOn)
        XCTAssertFalse(off.aiSwitch.isEnabled)
        XCTAssertEqual(off.defaultActionRow.value, "None")
        XCTAssertNil(off.defaultActionRow.keyCap)
        XCTAssertEqual(off.configurationRow.value, "None")
    }

    func testFootRowsAreTheAppGroupInOrderWithTheirKeyCaps() {
        let state = Self.state()
        XCTAssertEqual(state.footRows.map(\.id), [.history, .settings, .setupGuide, .help, .about, .quit])
        XCTAssertEqual(state.footRows.map(\.title), ["History", "Settings…", "Setup Guide…", "Help", "About", "Quit KVoice"])
        XCTAssertEqual(state.footRows.map(\.keyCap), ["⌘H", "⌘,", nil, nil, nil, "⌘Q"])
        XCTAssertEqual(state.footRows.map(\.command), [.openHistory, .openSettings, .openSetup, .openHelp, .showAbout, .quit])
        XCTAssertTrue(state.footRows.allSatisfy(\.isEnabled))
        XCTAssertNil(state.footRows.first?.symbol, "the foot is text-only, like the App group")

        let degraded = Self.state(context: Self.context(historyTitle: "History (unavailable)"))
        XCTAssertEqual(degraded.footRows.first?.title, "History (unavailable)")
    }

    func testRecordingShowsStopTheMeterTheClockAndCancel() {
        let state = Self.state(StatusMenuHeaderContext(dictationKind: .recording, shortcutGlyphs: "⌃⇧Space"), hud: Self.recordingHUD)
        XCTAssertEqual(state.primaryTitle, "Stop Recording")
        XCTAssertEqual(state.primaryGlyph, .stop)
        XCTAssertEqual(state.readiness, "Recording · MacBook Pro Microphone")
        XCTAssertEqual(state.feed, .meter(level: 0.6, elapsed: .seconds(7)))
        XCTAssertTrue(state.showsMeter)
        XCTAssertEqual(state.shortcutKeys, [], "the shortcut caps belong to Start Recording")
        XCTAssertEqual(state.dictationRows.map(\.id), [.cancel])
        XCTAssertEqual(state.dictationRows.first?.title, "Cancel Current Dictation")
        XCTAssertEqual(state.dictationRows.first?.command, .cancelCurrentDictation)
        XCTAssertTrue(state.dictationRows.first!.isEnabled)
        XCTAssertEqual(state.primaryAccessibilityLabel, "Stop Recording, Recording · MacBook Pro Microphone, 0:07")
    }

    func testStartingMicShowsNoMeterEvenWithALevel() {
        let state = Self.state(StatusMenuHeaderContext(dictationKind: .recording), hud: Self.startingHUD)
        XCTAssertEqual(state.primaryTitle, "Starting mic…")
        XCTAssertEqual(state.primaryGlyph, .starting)
        XCTAssertEqual(state.readiness, "MacBook Pro Microphone")
        XCTAssertEqual(state.feed, .none, "capture not started: no meter, no clock — as on the recorder")
        XCTAssertFalse(state.showsMeter)
    }

    func testRecordingCarriesTheFinishingBadge() {
        let hud = HUDViewState(phase: .recording(HUDRecordingState(inputLevel: 0.2, elapsed: .seconds(3))), finishingCount: 1)
        let state = Self.state(StatusMenuHeaderContext(dictationKind: .recording), hud: hud)
        XCTAssertEqual(state.header.finishingBadge, "1 finishing")
        XCTAssertEqual(state.primaryAccessibilityLabel, "Stop Recording, 1 finishing, Recording · MacBook Pro Microphone, 0:03")
    }

    func testFinishingPhasesShowTheVerbAndTheCancelRowLikeTheMenu() {
        let cases: [(DictationStateKind, HUDViewState, String, String, Bool)] = [
            (.finalizing, HUDViewState(phase: .finalizing), "Preparing…", "Cancel Current Dictation", true),
            (.transcribing, HUDViewState(phase: .transcribing), "Transcribing…", "Cancel Current Dictation", true),
            (.processingAI, HUDViewState(phase: .processingAI(HUDProcessingAIState(mode: .polish))), "Polishing…", "Use Raw Transcript Now", true),
            (.inserting, HUDViewState(phase: .inserting), "Inserting…", "Cancel Current Dictation", false),
        ]
        for (kind, hud, readiness, cancelTitle, cancelEnabled) in cases {
            let state = Self.state(StatusMenuHeaderContext(dictationKind: kind), hud: hud)
            XCTAssertEqual(state.primaryTitle, "Finishing…", "\(kind)")
            XCTAssertFalse(state.primaryIsEnabled, "\(kind)")
            XCTAssertEqual(state.primaryGlyph, .working, "\(kind)")
            XCTAssertEqual(state.readiness, readiness, "\(kind)")
            XCTAssertEqual(state.feed, .none, "\(kind): no meter once the recording has ended")
            XCTAssertEqual(state.dictationRows.map(\.id), [.cancel], "\(kind)")
            XCTAssertEqual(state.dictationRows.first?.title, cancelTitle, "\(kind)")
            XCTAssertEqual(state.dictationRows.first?.isEnabled, cancelEnabled, "\(kind): the menu disables Cancel while an AX mutation may be in flight")
        }
    }

    func testOutcomesReadDismissWithTheHUDTitleAndNoCancel() {
        let inserted = Self.state(
            StatusMenuHeaderContext(dictationKind: .completed),
            hud: HUDViewState(phase: .completed(HUDCompletionState(kind: .success)))
        )
        XCTAssertEqual(inserted.primaryTitle, "Dismiss")
        XCTAssertEqual(inserted.primaryGlyph, .done)
        XCTAssertEqual(inserted.readiness, "Inserted")
        XCTAssertFalse(inserted.readinessIsAttention)
        XCTAssertEqual(inserted.dictationRows, [], "no Cancel, no Copy Last: the row is Dismiss")

        let failed = Self.state(
            StatusMenuHeaderContext(dictationKind: .failed),
            hud: HUDViewState(phase: .failed(HUDFailureState(code: "x", message: "Nothing.")))
        )
        XCTAssertEqual(failed.primaryGlyph, .attention)
        XCTAssertEqual(failed.readiness, "Nothing inserted")
    }

    func testRecoverableFailureAddsCopyAndInsertAgainRows() {
        let state = Self.state(
            StatusMenuHeaderContext(dictationKind: .failed),
            hud: HUDViewState(phase: .failed(HUDFailureState(code: "x", message: "Nothing."))),
            context: Self.context(canRecoverFailedInsertion: true)
        )
        XCTAssertEqual(state.dictationRows.map(\.id), [.copyTranscript, .insertTranscriptAgain])
        XCTAssertEqual(state.dictationRows.map(\.command), [.copyTranscript, .insertTranscriptAgain])
        XCTAssertEqual(state.dictationRows[1].help, "Inserts the kept transcript into the app that is in front now.")

        // ADR-022 item 7: kept behind a newer recording too, with Cancel first.
        let behindRecording = Self.state(
            StatusMenuHeaderContext(dictationKind: .recording),
            hud: Self.recordingHUD,
            context: Self.context(canRecoverFailedInsertion: true)
        )
        XCTAssertEqual(behindRecording.dictationRows.map(\.id), [.cancel, .copyTranscript, .insertTranscriptAgain])
    }

    func testBlockedShowsTheReasonAndTheFixRowInsteadOfCopyLast() {
        let state = Self.state(
            StatusMenuHeaderContext(modelReady: false, shortcutGlyphs: "⌃⇧Space", attention: "Model not ready"),
            context: Self.context(readinessTitle: "Model not ready", isBlocked: true, fixTitle: "Fix in Speech Models…")
        )
        XCTAssertEqual(state.primaryTitle, "Start Recording")
        XCTAssertFalse(state.primaryIsEnabled)
        XCTAssertEqual(state.primaryGlyph, .attention)
        XCTAssertEqual(state.readiness, "Model not ready")
        XCTAssertTrue(state.readinessIsAttention)
        XCTAssertEqual(state.shortcutKeys, ["⌃", "⇧", "Space"], "the shortcut is still shown; it just will not work yet")
        XCTAssertEqual(state.dictationRows.map(\.id), [.fix])
        XCTAssertEqual(state.dictationRows.first?.title, "Fix in Speech Models…")
        XCTAssertEqual(state.dictationRows.first?.command, .openStatusTarget)
        XCTAssertTrue(state.dictationRows.first!.isAttention)

        let permissions = Self.state(
            StatusMenuHeaderContext(shortcutGlyphs: "⌃⇧Space", attention: "Microphone denied"),
            context: Self.context(readinessTitle: "Microphone denied", isBlocked: true, fixTitle: "Fix in Permissions…")
        )
        XCTAssertTrue(permissions.primaryIsEnabled, "the model is ready; the menu's Start item is enabled too")
        XCTAssertEqual(permissions.dictationRows.first?.title, "Fix in Permissions…")
    }

    func testDownloadingShowsTheProgressRowAndKeepsCopyLast() {
        let install = StatusMenuHeaderContext.ModelInstall(modelName: "Nemotron", fraction: 0.42)
        let state = Self.state(StatusMenuHeaderContext(shortcutGlyphs: "⌃⇧Space", modelInstall: install))
        XCTAssertEqual(state.feed, .download(label: "Downloading Nemotron… 42%", fraction: 0.42))
        XCTAssertFalse(state.showsMeter, "a download is a progress bar, never a level")
        XCTAssertEqual(state.readiness, "Ready · Whisper large-v3-turbo", "the current model still works while another downloads")
        XCTAssertEqual(state.dictationRows.map(\.id), [.copyLastTranscription])
        XCTAssertEqual(state.primaryAccessibilityLabel, "Start Recording, Ready · Whisper large-v3-turbo, ⌃⇧Space, Downloading Nemotron… 42%")

        let unknownTotal = Self.state(StatusMenuHeaderContext(modelInstall: .init(modelName: "Nemotron", fraction: nil)))
        XCTAssertEqual(unknownTotal.feed, .download(label: "Downloading Nemotron…", fraction: nil))
    }

    func testMemoryPressureAddsUnloadModelNow() {
        let state = Self.state(context: Self.context(memoryPressure: .init(canUnloadNow: true, isUnloading: false)))
        XCTAssertEqual(state.dictationRows.map(\.id), [.copyLastTranscription, .unloadModel])
        XCTAssertEqual(state.dictationRows.last?.title, "Unload Model Now")
        XCTAssertEqual(state.dictationRows.last?.command, .unloadModel)

        let unloading = Self.state(context: Self.context(memoryPressure: .init(canUnloadNow: false, isUnloading: true)))
        XCTAssertEqual(unloading.dictationRows.last?.title, "Unloading Model…")
        XCTAssertFalse(unloading.dictationRows.last!.isEnabled)
    }

    func testTerminationDisablesEverythingButQuit() {
        var context = Self.context(ai: StatusPanelContext.AI(isOn: true, canToggle: false, canChoose: false), canRecoverFailedInsertion: true)
        context.canOpenChoosers = false
        let state = Self.state(
            StatusMenuHeaderContext(dictationKind: .terminating, isTerminating: true, shortcutGlyphs: "⌃⇧Space"),
            context: context
        )
        XCTAssertEqual(state.primaryTitle, "Stopping…")
        XCTAssertFalse(state.primaryIsEnabled)
        XCTAssertEqual(state.readiness, "")
        XCTAssertEqual(state.shortcutKeys, [])
        XCTAssertEqual(state.dictationRows.map(\.id), [.copyTranscript, .insertTranscriptAgain], "no Copy Last outside idle")
        for row in state.rowsInOrder where row.id != .quit {
            XCTAssertFalse(row.isEnabled, "\(row.id)")
        }
        XCTAssertTrue(state.footRows.last!.isEnabled, "Quit stays enabled, as in the menu")
    }

    func testKeyCapsSplitModifiersFromTheKey() {
        XCTAssertEqual(StatusPanelState.keyCaps("⌃⇧Space"), ["⌃", "⇧", "Space"])
        XCTAssertEqual(StatusPanelState.keyCaps("⌘⌥K"), ["⌘", "⌥", "K"])
        XCTAssertEqual(StatusPanelState.keyCaps("fnF5"), ["fn", "F5"])
        XCTAssertEqual(StatusPanelState.keyCaps("Right Option"), ["Right Option"], "a modifier-only shortcut is one cap")
        XCTAssertEqual(StatusPanelState.keyCaps(nil), [])
        XCTAssertEqual(StatusPanelState.keyCaps(""), [])
    }

    func testRowsInOrderIsTheMenusReadingOrder() {
        let state = Self.state(context: Self.context(memoryPressure: .init(canUnloadNow: true, isUnloading: false)))
        XCTAssertEqual(
            state.rowsInOrder.map(\.id),
            [.copyLastTranscription, .unloadModel, .model, .language, .microphone, .aiSwitch, .defaultAction, .configuration,
             .history, .settings, .setupGuide, .help, .about, .quit]
        )
    }

    // MARK: The product rule: no meter outside a recording

    /// The panel has no level source of its own: it reads the shared header
    /// model, whose only level is the one inside the HUD's rendered
    /// recording state, projected for `.recording` alone. Whatever the HUD
    /// state says, an idle panel draws no meter.
    func testPanelHasNoRecordingFeedInIdle() {
        let header = StatusMenuHeaderModel()
        let model = StatusPanelModel(header: header)
        XCTAssertNil(model.recordingFeed)
        XCTAssertFalse(model.state.showsMeter)

        header.apply(hud: Self.recordingHUD)
        XCTAssertNil(model.recordingFeed, "idle context: the HUD's level is not shown")
        XCTAssertFalse(model.state.showsMeter)
        XCTAssertEqual(model.state.primaryGlyph, .start)

        header.apply(context: StatusMenuHeaderContext(dictationKind: .recording))
        XCTAssertEqual(model.recordingFeed?.level, 0.6)
        XCTAssertTrue(model.state.showsMeter)

        for kind in [DictationStateKind.finalizing, .transcribing, .processingAI, .inserting, .completed, .failed, .idle] {
            header.apply(context: StatusMenuHeaderContext(dictationKind: kind))
            XCTAssertNil(model.recordingFeed, "\(kind)")
            XCTAssertFalse(model.state.showsMeter, "\(kind)")
        }
    }

    func testPanelFollowsTheSharedHeaderModelWithoutASecondFeed() {
        let header = StatusMenuHeaderModel()
        let model = StatusPanelModel(header: header)
        XCTAssertTrue(model.header === header, "one header model, shared with the menu row")
        header.apply(context: StatusMenuHeaderContext(dictationKind: .recording))
        header.apply(hud: Self.startingHUD)
        XCTAssertEqual(model.state.primaryTitle, "Starting mic…")
        header.apply(hud: Self.recordingHUD)
        XCTAssertEqual(model.state.primaryTitle, "Stop Recording")
        header.apply(hud: HUDViewState(phase: .recording(HUDRecordingState(inputLevel: 0.2, elapsed: .seconds(8)))))
        XCTAssertEqual(model.state.feed, .meter(level: 0.2, elapsed: .seconds(8)))
    }

    func testApplyContextSkipsUnchangedInput() {
        let model = StatusPanelModel(header: StatusMenuHeaderModel())
        let context = Self.context()
        model.apply(context: context)
        let first = model.state
        model.apply(context: context)
        XCTAssertEqual(model.state, first)
        model.apply(context: Self.context(historyTitle: "History (unavailable)"))
        XCTAssertNotEqual(model.state, first)
    }

    // MARK: Commands

    func testPerformHandsTheCommandToTheHandlerAndClosesFirstOnlyWhenRequired() {
        let model = StatusPanelModel(header: StatusMenuHeaderModel())
        var log: [String] = []
        model.handler = { log.append("perform \($0)") }
        model.requestClose = { log.append("close") }

        model.perform(.toggleDictation)
        XCTAssertEqual(log, ["perform toggleDictation"], "Start Recording keeps the panel open for the meter")

        log.removeAll()
        model.perform(.openHistory)
        XCTAssertEqual(log, ["close", "perform openHistory"], "a window closes the panel before it opens")

        log.removeAll()
        model.perform(.insertTranscriptAgain)
        XCTAssertEqual(log, ["close", "perform insertTranscriptAgain"], "the panel resigns key before any insertion")

        log.removeAll()
        model.perform(.selectLanguage("fr"))
        XCTAssertEqual(log, ["perform selectLanguage(Optional(\"fr\"))"], "a pick shows its result in place")
    }

    func testEveryCommandHasAClosePolicy() {
        let keepsOpen: [StatusPanelCommand] = [
            .toggleDictation, .cancelCurrentDictation, .copyTranscript, .copyLastTranscription, .unloadModel,
            .selectModel("m"), .selectLanguage(nil), .selectMicrophone(uid: nil), .toggleAI,
            .selectDefaultAction(UUID()), .selectConfiguration(UUID()),
        ]
        let closesFirst: [StatusPanelCommand] = [
            .openStatusTarget, .openModels, .openAudioInput, .openAIActions, .openHistory, .openSettings,
            .openSetup, .openHelp, .showAbout, .quit, .insertTranscriptAgain,
        ]
        for command in keepsOpen { XCTAssertFalse(command.closesPanelFirst, "\(command)") }
        for command in closesFirst { XCTAssertTrue(command.closesPanelFirst, "\(command)") }
    }

    // MARK: Keys

    func testKeyRoutingMatchesTheMenusKeyEquivalents() {
        typealias Keys = StatusPanelKeyEquivalents
        XCTAssertEqual(Keys.action(keyCode: 4, characters: "h", command: true), .command(.openHistory))
        XCTAssertEqual(Keys.action(keyCode: 4, characters: "H", command: true), .command(.openHistory), "⇧ is ignored")
        XCTAssertEqual(Keys.action(keyCode: 43, characters: ",", command: true), .command(.openSettings))
        XCTAssertEqual(Keys.action(keyCode: 12, characters: "q", command: true), .command(.quit))
        XCTAssertNil(Keys.action(keyCode: 0, characters: "a", command: true), "⌘A is not ours")
        XCTAssertEqual(Keys.action(keyCode: Keys.escapeKeyCode, characters: "\u{1B}", command: false), .close)
        XCTAssertEqual(Keys.action(keyCode: Keys.downArrowKeyCode, characters: nil, command: false), .focusNext)
        XCTAssertEqual(Keys.action(keyCode: Keys.upArrowKeyCode, characters: nil, command: false), .focusPrevious)
        XCTAssertEqual(Keys.action(keyCode: Keys.returnKeyCode, characters: "\r", command: false), .activateFocused)
        XCTAssertEqual(Keys.action(keyCode: Keys.keypadEnterKeyCode, characters: "\u{3}", command: false), .activateFocused)
        XCTAssertNil(Keys.action(keyCode: 4, characters: "h", command: false), "a plain letter is not ours (no type-select; the menu has it)")
        XCTAssertNil(Keys.action(keyCode: 48, characters: "\t", command: false), "Tab is the system's")
    }

    /// The click split: left-click → panel; right-click, ⌥-click or
    /// ⌃-click → the menu, unchanged.
    func testClickSplitSendsOnlyAPlainLeftClickToThePanel() {
        XCTAssertEqual(StatusItemClick.surface(isRightButton: false, option: false, control: false), .panel)
        XCTAssertEqual(StatusItemClick.surface(isRightButton: true, option: false, control: false), .menu)
        XCTAssertEqual(StatusItemClick.surface(isRightButton: false, option: true, control: false), .menu)
        XCTAssertEqual(StatusItemClick.surface(isRightButton: false, option: false, control: true), .menu)
    }

    // MARK: Focus

    func testFocusWalksTheEnabledRowsInOrderAndStopsAtTheEnds() {
        let header = StatusMenuHeaderModel()
        header.apply(context: StatusMenuHeaderContext(shortcutGlyphs: "⌃⇧Space"))
        let model = StatusPanelModel(header: header)
        model.apply(context: Self.context())
        XCTAssertNil(model.focus)

        model.moveFocus(forward: true)
        XCTAssertEqual(model.focus, .primary)
        model.moveFocus(forward: true)
        XCTAssertEqual(model.focus, .row(.copyLastTranscription))
        model.moveFocus(forward: false)
        XCTAssertEqual(model.focus, .primary)
        model.moveFocus(forward: false)
        XCTAssertEqual(model.focus, .primary, "no wrap at the top")

        model.focus = nil
        model.moveFocus(forward: false)
        XCTAssertEqual(model.focus, .row(.quit), "↑ from nothing lands on the last row")
        model.moveFocus(forward: true)
        XCTAssertEqual(model.focus, .row(.quit), "no wrap at the bottom")
    }

    func testFocusSkipsDisabledRowsAndTheDisabledPrimary() {
        let header = StatusMenuHeaderModel()
        header.apply(context: StatusMenuHeaderContext(modelReady: false, attention: "Model not ready"))
        let model = StatusPanelModel(header: header)
        model.apply(context: Self.context(isBlocked: true, ai: StatusPanelContext.AI(isOn: false, canToggle: false, canChoose: false)))
        XCTAssertEqual(
            model.focusOrder,
            [.row(.fix), .row(.model), .row(.language), .row(.microphone),
             .row(.history), .row(.settings), .row(.setupGuide), .row(.help), .row(.about), .row(.quit)]
        )
    }

    func testReturnActivatesTheFocusedCommandRowOnly() {
        let header = StatusMenuHeaderModel()
        header.apply(context: StatusMenuHeaderContext(shortcutGlyphs: "⌃⇧Space"))
        let model = StatusPanelModel(header: header)
        model.apply(context: Self.context())
        var performed: [StatusPanelCommand] = []
        model.handler = { performed.append($0) }

        XCTAssertFalse(model.activateFocusedRow(), "nothing focused")
        model.focus = .primary
        XCTAssertTrue(model.activateFocusedRow())
        model.focus = .row(.aiSwitch)
        XCTAssertTrue(model.activateFocusedRow())
        model.focus = .row(.model)
        XCTAssertFalse(model.activateFocusedRow(), "a chooser row opens with Space or the pointer; Return does nothing")
        model.focus = .row(.quit)
        XCTAssertTrue(model.activateFocusedRow())
        XCTAssertEqual(performed, [.toggleDictation, .toggleAI, .quit])
    }

    func testLayoutSignatureIgnoresTheLevelAndTheClock() {
        let a = Self.state(StatusMenuHeaderContext(dictationKind: .recording), hud: Self.recordingHUD)
        let b = Self.state(
            StatusMenuHeaderContext(dictationKind: .recording),
            hud: HUDViewState(phase: .recording(HUDRecordingState(inputLevel: 0.1, elapsed: .seconds(8))))
        )
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.layoutSignature, b.layoutSignature, "a 20 Hz tick must not retrigger the row animation")
        let idle = Self.state()
        XCTAssertNotEqual(a.layoutSignature, idle.layoutSignature, "a phase change does")
        XCTAssertNotEqual(idle.layoutSignature, Self.state(context: Self.context(canRecoverFailedInsertion: true)).layoutSignature, "so does a row appearing")
    }

    func testChooserSeparatorsAreCarriedPerChoice() {
        let auto = StatusPanelChoice(id: "auto", title: "Auto-detect", command: .selectLanguage(nil), separatorAfter: true)
        XCTAssertTrue(auto.separatorAfter)
        XCTAssertFalse(StatusPanelChoice(id: "fr", title: "French", command: .selectLanguage("fr")).separatorAfter)
    }

    // MARK: Rendering

    /// The real view renders with no shell behind it — the same seam the
    /// gallery uses — in both chromes and both appearances. Two renders,
    /// not the whole matrix: an offscreen render costs ~0.4 s and the
    /// suite is the pre-commit gate; the full phase set is the opt-in
    /// `DesignGalleryTests.testRenderStatusPanelGallery`.
    func testViewRendersWithoutAShell() {
        let smoke: [(Int, StatusPanelView.Chrome, NSAppearance.Name)] = [(0, .hosted, .aqua), (1, .standalone, .darkAqua)]
        for (index, chrome, appearance) in smoke {
            let (label, headerContext, hud, context) = Self.galleryPhases[index]
            let header = StatusMenuHeaderModel()
            header.apply(context: headerContext)
            header.apply(hud: hud)
            let model = StatusPanelModel(header: header)
            model.apply(context: context)
            let image = LayoutSnapshotTests.render(
                StatusPanelView(model: model, chrome: chrome).padding(20),
                size: NSSize(width: 360, height: 620),
                appearance: appearance
            )
            XCTAssertGreaterThan(image.size.width, 0, "\(label) \(chrome) \(appearance.rawValue)")
        }
    }

    /// Reduce Transparency and Increase Contrast are read-only environment
    /// values, so the view takes overrides; both variants render, in the
    /// standalone chrome where they change the background and the edge.
    func testViewRendersTheAccessibilityVariants() {
        let (_, headerContext, hud, context) = Self.galleryPhases[0]
        let header = StatusMenuHeaderModel()
        header.apply(context: headerContext)
        header.apply(hud: hud)
        let model = StatusPanelModel(header: header)
        model.apply(context: context)
        let variants: [(String, StatusPanelView.AccessibilityOverrides)] = [
            ("reduce-transparency", .init(reduceTransparency: true)),
            ("increase-contrast", .init(reduceMotion: true, increasedContrast: true)),
        ]
        for (label, overrides) in variants {
            let image = LayoutSnapshotTests.render(
                StatusPanelView(model: model, chrome: .standalone, overrides: overrides).padding(20),
                size: NSSize(width: 360, height: 620),
                appearance: .aqua
            )
            XCTAssertGreaterThan(image.size.width, 0, label)
        }
    }

    /// The four phases of the approved mock, plus the ones the mock did not
    /// draw, with the shell-shaped contexts; shared with `DesignGalleryTests`.
    static let galleryPhases: [(String, StatusMenuHeaderContext, HUDViewState, StatusPanelContext)] = [
        ("idle", StatusMenuHeaderContext(shortcutGlyphs: "⌃⇧Space"), .idle, context()),
        ("recording", StatusMenuHeaderContext(dictationKind: .recording, shortcutGlyphs: "⌃⇧Space"), recordingHUD, context()),
        ("downloading",
         StatusMenuHeaderContext(shortcutGlyphs: "⌃⇧Space", modelInstall: .init(modelName: "Nemotron", fraction: 0.42)),
         .idle, context()),
        ("blocked",
         StatusMenuHeaderContext(modelReady: false, shortcutGlyphs: "⌃⇧Space", attention: "Model not ready"),
         .idle, context(readinessTitle: "Model not ready", isBlocked: true)),
        ("finishing", StatusMenuHeaderContext(dictationKind: .transcribing), HUDViewState(phase: .transcribing, finishingCount: 1), context()),
        ("inserted", StatusMenuHeaderContext(dictationKind: .completed),
         HUDViewState(phase: .completed(HUDCompletionState(kind: .success))), context()),
        ("failed-recoverable", StatusMenuHeaderContext(dictationKind: .failed),
         HUDViewState(phase: .failed(HUDFailureState(code: "x", message: "Nothing."))), context(canRecoverFailedInsertion: true)),
    ]
}
