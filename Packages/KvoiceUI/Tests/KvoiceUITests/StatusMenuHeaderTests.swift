import AppKit
import XCTest
@testable import KvoiceDomain
@testable import KvoiceUI

/// P-D3: the status menu's header row — the projection per state, the
/// no-meter-outside-a-recording rule, the Reduce Motion rule, the
/// VoiceOver labels, and the `NSMenuItem` host's seam (title, action and
/// enabled state untouched; a click performs the item's own action).
@MainActor
final class StatusMenuHeaderTests: XCTestCase {
    private static let recordingHUD = HUDViewState(
        phase: .recording(HUDRecordingState(inputLevel: 0.6, elapsed: .seconds(7), captureStarted: true))
    )
    private static let startingHUD = HUDViewState(
        phase: .recording(HUDRecordingState(inputLevel: 0.6, elapsed: .seconds(7), captureStarted: false))
    )

    // MARK: Projection

    func testIdleShowsTheCommandTheShortcutAndNoMeter() {
        let state = StatusMenuHeaderState(
            context: StatusMenuHeaderContext(shortcutGlyphs: "⌃⇧Space"),
            hud: .idle
        )
        XCTAssertEqual(state.indicator, .idle)
        XCTAssertEqual(state.title, "Start Recording")
        XCTAssertTrue(state.isEnabled)
        XCTAssertNil(state.finishingBadge)
        XCTAssertEqual(state.trailing, .shortcut("⌃⇧Space"))
        XCTAssertEqual(state.accessibilityLabel, "Start Recording, ⌃⇧Space")
    }

    func testIdleWithoutAConfirmedShortcutShowsTheNote() {
        let state = StatusMenuHeaderState(context: StatusMenuHeaderContext(shortcutNote: "No Shortcut"), hud: .idle)
        XCTAssertEqual(state.trailing, .note("No Shortcut"))
        XCTAssertEqual(state.accessibilityLabel, "Start Recording, No Shortcut")
    }

    func testIdleModelNotReadyIsDisabled() {
        let state = StatusMenuHeaderState(context: StatusMenuHeaderContext(modelReady: false, shortcutGlyphs: "⌃⇧Space"), hud: .idle)
        XCTAssertFalse(state.isEnabled)
        XCTAssertEqual(state.title, "Start Recording")
    }

    func testStartingMicShowsThePulsingRingAndNoMeterEvenWithALevel() {
        let state = StatusMenuHeaderState(
            context: StatusMenuHeaderContext(dictationKind: .recording, shortcutGlyphs: "⌃⇧Space"),
            hud: Self.startingHUD
        )
        XCTAssertEqual(state.indicator, .starting)
        XCTAssertEqual(state.title, "Starting mic…")
        XCTAssertTrue(state.isEnabled)
        // The HUD state carries a level, but capture has not started: no
        // meter, no clock — same as the recorder, which holds both at zero.
        XCTAssertEqual(state.trailing, .none)
        XCTAssertTrue(state.indicatorPulses(reduceMotion: false))
        XCTAssertFalse(state.indicatorPulses(reduceMotion: true), "Reduce Motion: the ring is static")
    }

    func testRecordingBeforeTheHUDRenderedItReadsAsStarting() {
        let state = StatusMenuHeaderState(context: StatusMenuHeaderContext(dictationKind: .recording), hud: .idle)
        XCTAssertEqual(state.indicator, .starting)
        XCTAssertEqual(state.title, "Starting mic…")
        XCTAssertEqual(state.trailing, .none)
    }

    func testRecordingShowsStopTheMeterAndTheClock() {
        let state = StatusMenuHeaderState(
            context: StatusMenuHeaderContext(dictationKind: .recording, shortcutGlyphs: "⌃⇧Space"),
            hud: Self.recordingHUD
        )
        XCTAssertEqual(state.indicator, .live)
        XCTAssertEqual(state.title, "Stop Recording")
        XCTAssertTrue(state.isEnabled)
        XCTAssertEqual(state.trailing, .meter(level: 0.6, elapsed: .seconds(7)))
        XCTAssertFalse(state.indicatorPulses(reduceMotion: false), "only the starting ring pulses")
        XCTAssertEqual(state.accessibilityLabel, "Stop Recording, 0:07")
    }

    func testRecordingCarriesTheFinishingBadgeLikeTheHUD() {
        let hud = HUDViewState(
            phase: .recording(HUDRecordingState(inputLevel: 0.2, elapsed: .seconds(3))),
            finishingCount: 1
        )
        let state = StatusMenuHeaderState(context: StatusMenuHeaderContext(dictationKind: .recording), hud: hud)
        XCTAssertEqual(state.finishingBadge, "1 finishing")
        XCTAssertEqual(state.accessibilityLabel, "Stop Recording, 1 finishing, 0:03")
    }

    func testFinishingPhasesShowTheVerbAndAreDisabled() {
        let cases: [(DictationStateKind, HUDViewState, String)] = [
            (.finalizing, HUDViewState(phase: .finalizing), "Preparing"),
            (.transcribing, HUDViewState(phase: .transcribing), "Transcribing"),
            (.processingAI, HUDViewState(phase: .processingAI(HUDProcessingAIState(mode: .polish))), "Polishing"),
            (.processingAI, HUDViewState(phase: .processingAI(HUDProcessingAIState(mode: .translate, targetLanguageDisplayName: "French"))), "Translating"),
            (.inserting, HUDViewState(phase: .inserting), "Inserting")
        ]
        for (kind, hud, word) in cases {
            let state = StatusMenuHeaderState(context: StatusMenuHeaderContext(dictationKind: kind), hud: hud)
            XCTAssertEqual(state.indicator, .working, "\(kind)")
            XCTAssertEqual(state.title, "Finishing…", "\(kind)")
            XCTAssertFalse(state.isEnabled, "\(kind)")
            XCTAssertEqual(state.trailing, .note(word), "\(kind)")
            XCTAssertNil(state.finishingBadge, "\(kind)")
        }
        let overlapping = StatusMenuHeaderState(
            context: StatusMenuHeaderContext(dictationKind: .transcribing),
            hud: HUDViewState(phase: .transcribing, finishingCount: 2)
        )
        XCTAssertEqual(overlapping.finishingBadge, "2 finishing")
    }

    func testOutcomesReadDismissWithTheHUDTitle() {
        let inserted = StatusMenuHeaderState(
            context: StatusMenuHeaderContext(dictationKind: .completed),
            hud: HUDViewState(phase: .completed(HUDCompletionState(kind: .success)))
        )
        XCTAssertEqual(inserted.indicator, .done)
        XCTAssertEqual(inserted.title, "Dismiss")
        XCTAssertEqual(inserted.trailing, .note("Inserted"))
        XCTAssertTrue(inserted.isEnabled)

        let clipboard = StatusMenuHeaderState(
            context: StatusMenuHeaderContext(dictationKind: .completed),
            hud: HUDViewState(phase: .completed(HUDCompletionState(kind: .clipboardFallback)))
        )
        XCTAssertEqual(clipboard.indicator, .attention)
        XCTAssertEqual(clipboard.trailing, .note("Copied to clipboard"))

        let failed = StatusMenuHeaderState(
            context: StatusMenuHeaderContext(dictationKind: .failed),
            hud: HUDViewState(phase: .failed(HUDFailureState(code: "x", message: "Nothing.")))
        )
        XCTAssertEqual(failed.indicator, .attention)
        XCTAssertEqual(failed.title, "Dismiss")
        XCTAssertEqual(failed.trailing, .note("Nothing inserted"))

        let blockedJob = StatusMenuHeaderState(
            context: StatusMenuHeaderContext(dictationKind: .blocked),
            hud: HUDViewState(phase: .blocked(HUDBlockedState(code: "mic", message: "Microphone access is off.")))
        )
        XCTAssertEqual(blockedJob.indicator, .attention)
        XCTAssertEqual(blockedJob.trailing, .note("KVoice needs attention"))
    }

    func testBlockedPrerequisiteSummarisesTheStatusRow() {
        let state = StatusMenuHeaderState(
            context: StatusMenuHeaderContext(modelReady: false, shortcutGlyphs: "⌃⇧Space", attention: "Model not ready"),
            hud: .idle
        )
        XCTAssertEqual(state.indicator, .attention)
        XCTAssertEqual(state.title, "Start Recording")
        XCTAssertFalse(state.isEnabled)
        XCTAssertEqual(state.trailing, .note("Model not ready"), "the reason replaces the shortcut, as the plain title did")
        XCTAssertEqual(state.accessibilityLabel, "Start Recording, Model not ready")

        let degraded = StatusMenuHeaderState(
            context: StatusMenuHeaderContext(shortcutGlyphs: "⌃⇧Space", attention: "Accessibility off — clipboard only"),
            hud: .idle
        )
        XCTAssertTrue(degraded.isEnabled, "degraded, not blocked: the model is ready")
        XCTAssertEqual(degraded.trailing, .note("Accessibility off — clipboard only"))
    }

    func testModelInstallShowsProgressAndWinsOverTheBlockedReason() {
        let context = StatusMenuHeaderContext(
            modelReady: false,
            shortcutGlyphs: "⌃⇧Space",
            attention: "Model loading…",
            modelInstall: .init(modelName: "Nemotron", fraction: 0.4249)
        )
        let state = StatusMenuHeaderState(context: context, hud: .idle)
        XCTAssertEqual(state.trailing, .download(label: "Downloading Nemotron… 42%", fraction: 0.4249))
        XCTAssertEqual(state.indicator, .attention)
        XCTAssertFalse(state.isEnabled)
        XCTAssertEqual(state.accessibilityLabel, "Start Recording, Downloading Nemotron… 42%")

        let unknownTotal = StatusMenuHeaderState(
            context: StatusMenuHeaderContext(modelInstall: .init(modelName: "Nemotron", fraction: nil)),
            hud: .idle
        )
        XCTAssertEqual(unknownTotal.trailing, .download(label: "Downloading Nemotron…", fraction: nil))

        let clamped = StatusMenuHeaderContext.ModelInstall(modelName: "x", fraction: 1.7)
        XCTAssertEqual(clamped.fraction, 1)
    }

    func testModelInstallDoesNotReplaceTheMeterWhileRecording() {
        let state = StatusMenuHeaderState(
            context: StatusMenuHeaderContext(dictationKind: .recording, modelInstall: .init(modelName: "Nemotron", fraction: 0.5)),
            hud: Self.recordingHUD
        )
        XCTAssertEqual(state.trailing, .meter(level: 0.6, elapsed: .seconds(7)))
    }

    func testTerminatingIsDisabledAndQuiet() {
        let state = StatusMenuHeaderState(
            context: StatusMenuHeaderContext(dictationKind: .terminating, isTerminating: true, shortcutGlyphs: "⌃⇧Space"),
            hud: .idle
        )
        XCTAssertEqual(state.title, "Stopping…")
        XCTAssertFalse(state.isEnabled)
        XCTAssertEqual(state.trailing, .none)
        XCTAssertEqual(state.indicator, .idle)
    }

    func testTerminationDisablesEveryClickableState() {
        for kind in [DictationStateKind.idle, .recording, .completed, .failed, .blocked] {
            let state = StatusMenuHeaderState(
                context: StatusMenuHeaderContext(dictationKind: kind, isTerminating: true),
                hud: kind == .recording ? Self.recordingHUD : .idle
            )
            XCTAssertFalse(state.isEnabled, "\(kind)")
        }
    }

    // MARK: The product rule: no meter outside a recording

    /// The model has no level source of its own; the only level it can show
    /// is the one inside the HUD's rendered recording state, and that is
    /// projected only while the dictation is `.recording`. Whatever the HUD
    /// state says, an idle context draws no meter.
    func testModelHasNoRecordingFeedInIdle() {
        let model = StatusMenuHeaderModel()
        XCTAssertNil(model.recordingFeed)
        XCTAssertEqual(model.state, .idle)

        // A stale or stray recording render with an idle context: ignored.
        model.apply(hud: Self.recordingHUD)
        XCTAssertNil(model.recordingFeed, "idle context: the HUD's level is not shown")
        XCTAssertEqual(model.state.indicator, .idle)
        XCTAssertEqual(model.state.trailing, .none)

        // A recording context with the HUD's live render: the feed exists…
        model.apply(context: StatusMenuHeaderContext(dictationKind: .recording))
        XCTAssertEqual(model.recordingFeed?.level, 0.6)
        XCTAssertEqual(model.recordingFeed?.elapsed, .seconds(7))

        // …and goes away with the job, in every later phase.
        for kind in [DictationStateKind.finalizing, .transcribing, .processingAI, .inserting, .completed, .failed, .idle] {
            model.apply(context: StatusMenuHeaderContext(dictationKind: kind))
            XCTAssertNil(model.recordingFeed, "\(kind)")
        }
        model.apply(hud: .idle)
        XCTAssertNil(model.recordingFeed)
    }

    func testModelSkipsUnchangedInputs() {
        let model = StatusMenuHeaderModel()
        let context = StatusMenuHeaderContext(shortcutGlyphs: "⌃⇧Space")
        model.apply(context: context)
        let first = model.state
        model.apply(context: context)
        XCTAssertEqual(model.state, first)
        model.apply(hud: .idle)
        XCTAssertEqual(model.state, first)
    }

    func testModelFollowsTheHUDRenderedFeedWhileRecording() {
        let model = StatusMenuHeaderModel()
        model.apply(context: StatusMenuHeaderContext(dictationKind: .recording))
        model.apply(hud: Self.startingHUD)
        XCTAssertEqual(model.state.title, "Starting mic…")
        XCTAssertNil(model.recordingFeed)
        model.apply(hud: Self.recordingHUD)
        XCTAssertEqual(model.state.title, "Stop Recording")
        XCTAssertEqual(model.recordingFeed?.level, 0.6)
        model.apply(hud: HUDViewState(phase: .recording(HUDRecordingState(inputLevel: 0.2, elapsed: .seconds(8)))))
        XCTAssertEqual(model.recordingFeed?.level, 0.2)
        XCTAssertEqual(model.recordingFeed?.elapsed, .seconds(8))
    }

    /// `HUDController` hands the header the state it rendered — after the
    /// feedback filter — and `.idle` on dismissal, so the two surfaces show
    /// the same level and the header is cleared with the HUD.
    func testHUDControllerFeedsTheRenderedStateAndIdleOnDismiss() {
        let controller = HUDController(announce: { _ in })
        var received: [HUDViewState] = []
        controller.renderedStateObserver = { received.append($0) }
        controller.show(Self.recordingHUD)
        XCTAssertEqual(received.count, 1)
        guard case .recording(let rendered)? = received.first?.phase else {
            return XCTFail("expected the rendered recording state")
        }
        // The filtered level (attack 0.6 from silence), not the raw 0.6:
        // the header draws what the recorder draws.
        XCTAssertEqual(rendered.inputLevel, 0.36, accuracy: 0.001)
        XCTAssertEqual(rendered.elapsed, .seconds(7))
        controller.dismiss()
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.last, .idle)
        controller.panel?.orderOut(nil)
    }

    // MARK: The NSMenuItem host

    func testInstallLeavesTheItemsTitleActionAndEnabledStateAlone() {
        let target = ClickTarget()
        let item = NSMenuItem(title: "Start Recording  ⌃⇧Space", action: #selector(ClickTarget.fire), keyEquivalent: "")
        item.target = target
        item.isEnabled = true
        let model = StatusMenuHeaderModel()
        let host = StatusMenuHeaderItemView.install(on: item, model: model)
        XCTAssertTrue(item.view === host)
        XCTAssertEqual(item.title, "Start Recording  ⌃⇧Space", "type-select and VoiceOver keep reading the title")
        XCTAssertEqual(item.action, #selector(ClickTarget.fire))
        XCTAssertTrue(item.target === target)
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(host.frame.height, StatusMenuHeaderView.rowHeight)
        XCTAssertGreaterThanOrEqual(host.frame.width, StatusMenuHeaderView.minimumWidth)
        XCTAssertTrue(host.autoresizingMask.contains(.width), "the menu stretches the row to its width")
        XCTAssertFalse(host.isAccessibilityElement(), "the menu item, not the view, is what VoiceOver reads")
    }

    func testClickPerformsTheItemsOwnActionAndNothingWhenDisabled() {
        let target = ClickTarget()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Start Recording", action: #selector(ClickTarget.fire), keyEquivalent: "")
        item.target = target
        menu.addItem(item)
        let host = StatusMenuHeaderItemView.install(on: item, model: StatusMenuHeaderModel())

        host.performItemAction()
        XCTAssertEqual(target.fired, 1, "the click goes through performActionForItem(at:) to the item's own selector")

        item.isEnabled = false
        host.performItemAction()
        XCTAssertEqual(target.fired, 1, "a disabled item ignores the click, like a plain one")
    }

    func testHostClearsTheHighlightWhenTheMenuCloses() {
        let model = StatusMenuHeaderModel()
        let item = NSMenuItem(title: "Start Recording", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.addItem(item)
        let host = StatusMenuHeaderItemView.install(on: item, model: model)
        host.setHighlightedForGallery(true)
        model.isMenuOpen = true
        XCTAssertTrue(host.isHighlightVisible)
        // Not in a window (the menu closed): the highlight is dropped and
        // the pulse stops.
        host.viewDidMoveToWindow()
        XCTAssertFalse(model.isHighlighted)
        XCTAssertFalse(model.isMenuOpen)
        XCTAssertFalse(host.isHighlightVisible)
    }

    // MARK: The inventory

    /// The list the shell must build (`AppDelegate.installStatusItem`), in
    /// order. Removing a row from the shell without removing it here trips
    /// the shell's launch assertion; removing it here as well is the
    /// visible act the product rule ("nothing removed unasked") asks for.
    func testInventoryIsTheFullMenuInOrder() {
        XCTAssertEqual(StatusMenuItemID.allCases.map(\.rawValue), [
            "dictationHeader", "startRecording", "cancelCurrentDictation", "copyTranscript", "insertTranscriptAgain",
            "copyLastTranscription", "status", "fix", "unloadModel",
            "transcriptionHeader", "model", "language", "microphone",
            "aiHeader", "useAIActions", "defaultAction", "configuration",
            "appHeader", "history", "settings", "setupGuide", "help", "about", "quit"
        ])
        XCTAssertEqual(StatusMenuItemID.allCases.count, 24)
    }

    func testInventoryCheckFindsMissingAndMisorderedItems() {
        let menu = NSMenu()
        for id in StatusMenuItemID.allCases {
            menu.addItem(NSMenuItem(title: id.rawValue, action: nil, keyEquivalent: "").tagged(id))
            if id == .unloadModel || id == .microphone || id == .configuration {
                menu.addItem(.separator())
            }
        }
        XCTAssertTrue(StatusMenuItemID.isComplete(menu))
        XCTAssertEqual(StatusMenuItemID.missing(from: menu), [])

        menu.removeItem(at: menu.indexOfItem(withTitle: "language"))
        XCTAssertEqual(StatusMenuItemID.missing(from: menu), [.language])
        XCTAssertFalse(StatusMenuItemID.isComplete(menu))

        menu.insertItem(NSMenuItem(title: "language", action: nil, keyEquivalent: "").tagged(.language), at: 0)
        XCTAssertEqual(StatusMenuItemID.missing(from: menu), [], "present, but…")
        XCTAssertFalse(StatusMenuItemID.isComplete(menu), "…out of order")
    }
}

@MainActor
private final class ClickTarget: NSObject {
    var fired = 0
    @objc func fire() { fired += 1 }
}
