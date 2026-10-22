import KvoiceDomain
@testable import KvoiceUI
import XCTest

/// Q2b (UI v2 regression audit): every dictation state the controller can
/// publish, projected into every UI v2 surface that shows it — the
/// recorder (`HUDViewState` and its glyph), the status panel
/// (`StatusMenuHeaderState` + `StatusPanelState`) and the menu-bar icon
/// (`StatusItemAppearance`) — must mean the same thing on all of them.
///
/// The expected meaning comes from one exhaustive `switch` over
/// `DictationState` (`expectedMeaning`), so a new controller state fails to
/// compile here instead of being skipped. The walk then applies every
/// reducer event to every fixture and checks that each legal transition
/// lands on a surface state that is defined and consistent: no spinner
/// outside the processing phases, no outcome (or "Inserted") left over on
/// idle, a Cancel row exactly while a job runs. The surfaces take no
/// edition: what differs for them reaches these projections only as
/// `canRecoverFailedInsertion` (the controller's `recoveryRunner != nil`,
/// with no edition gate), so the walk runs with recovery on and off. Home
/// and the panel make no Accessibility-insertion claim to vary by edition;
/// the wizard's edition copy is checked below.
@MainActor
final class SurfaceStateMatrixTests: XCTestCase {
    /// What a surface says about the dictation, independent of its pixels.
    enum Meaning: String {
        case idle, starting, live, working, success, warning, failure, stopping
    }

    private static let job = JobID()

    /// One exhaustive projection of the domain state to its meaning.
    static func expectedMeaning(_ state: DictationState, captureStarted: Bool) -> Meaning {
        switch state {
        case .idle: return .idle
        case .blocked: return .warning
        case .recording: return captureStarted ? .live : .starting
        case .finalizing, .transcribing, .processingAI, .inserting: return .working
        case .completed(_, let summary):
            switch summary.insertion {
            case .copiedToClipboard: return .warning
            case .inserted, .deliveredInApp, .abortedAtTermination:
                return summary.aiFallback == nil ? .success : .warning
            }
        case .failed: return .failure
        case .terminating: return .stopping
        }
    }

    /// Every state shape the controller publishes, with the payloads that
    /// change a surface (insertion outcome, AI fallback, the duration cap,
    /// fatal vs recoverable failure, polish vs translate).
    static var fixtures: [DictationState] {
        let job = Self.job
        return [
            .idle,
            .blocked(.microphonePermission),
            .blocked(.modelUnavailable),
            .blocked(.modelLoading),
            .recording(RecordingState(jobID: job, elapsed: .seconds(3))),
            .finalizing(job),
            .transcribing(job),
            .processingAI(job, .polish),
            .processingAI(job, .translate),
            .inserting(job),
            .completed(job, CompletionSummary(insertion: .inserted(method: .selectedTextAttribute))),
            .completed(job, CompletionSummary(insertion: .inserted(method: .typedKeyboardEvents))),
            .completed(job, CompletionSummary(insertion: .inserted(method: .selectedTextAttribute))
                .attaching(aiFallback: .aiUnreachable, durationCapReached: false)),
            .completed(job, CompletionSummary(insertion: .inserted(method: .selectedTextAttribute))
                .attaching(aiFallback: nil, durationCapReached: true)),
            .completed(job, CompletionSummary(insertion: .copiedToClipboard(reason: .notEditable), warningMessage: "Copied")),
            .completed(job, CompletionSummary(insertion: .deliveredInApp)),
            .failed(job, UserFacingFailure(code: .clipboardWriteFailed)),
            .failed(job, UserFacingFailure(code: .sttEmpty)),
            .failed(job, UserFacingFailure(code: .modelLoadFailed)),
            .failed(nil, UserFacingFailure(code: .audioEngineStartFailed)),
            .terminating(job),
            .terminating(nil),
        ]
    }

    /// Every reducer event, aimed at the fixtures' job.
    static var events: [DictationEvent] {
        let job = Self.job
        return [
            .start(jobID: job, prerequisites: .passed),
            .start(jobID: job, prerequisites: .blocked(.microphonePermission)),
            .stop(jobID: job),
            .escape(jobID: job),
            .hardDurationCap(jobID: job),
            .captureFailure(jobID: job, code: .audioInputUnavailable),
            .validRecording(jobID: job),
            .invalidAudio(jobID: job, code: .audioTooShort),
            .rawTranscript(jobID: job, mode: .off),
            .rawTranscript(jobID: job, mode: .polish),
            .rawTranscript(jobID: job, mode: .translate),
            .transcriptionFailure(jobID: job, code: .sttFailed),
            .aiSuccess(jobID: job),
            .aiFailure(jobID: job, code: .aiTimeout),
            .aiCancelled(jobID: job),
            .insertionSucceeded(jobID: job, outcome: .inserted(method: .textEditValueSplice)),
            .insertionFallback(jobID: job, outcome: .copiedToClipboard(reason: .secureTarget)),
            .clipboardFailure(jobID: job, code: .clipboardWriteFailed),
            .retryInsertion(jobID: job),
            .reset,
            .dismiss,
            .quit,
        ]
    }

    // MARK: The surfaces

    struct Surfaces {
        let hud: HUDViewState
        let header: StatusMenuHeaderState
        let panel: StatusPanelState
        let icon: StatusItemAppearance
    }

    static func project(
        _ state: DictationState,
        captureStarted: Bool = true,
        canRecover: Bool = false,
        hud overriddenHUD: HUDViewState? = nil
    ) -> Surfaces {
        let hud = overriddenHUD ?? HUDViewState(
            dictationState: state,
            inputLevel: 0.4,
            recoverableTranscript: canRecover ? "kept text" : nil,
            canRecoverFailedInsertion: canRecover,
            captureStarted: captureStarted,
            facts: HUDJobFacts(modelName: "Whisper", aiActionName: "Clean Up", targetAppName: "Notes", wordCount: 2)
        )
        let headerContext = StatusMenuHeaderContext(
            dictationKind: state.kind,
            isTerminating: state.kind == .terminating,
            shortcutGlyphs: "⌃⇧Space"
        )
        var context = StatusPanelTests.context(canRecoverFailedInsertion: canRecover)
        if case .completed = state {
            context.jobResult = StatusPanelContext.JobResult(text: "two words", appName: "Notes")
        }
        let header = StatusMenuHeaderState(context: headerContext, hud: hud)
        return Surfaces(
            hud: hud,
            header: header,
            panel: StatusPanelState(header: header, headerContext: headerContext, context: context, hud: hud),
            icon: StatusItemAppearance(dictationState: state)
        )
    }

    static func hudMeaning(_ hud: HUDViewState) -> Meaning {
        let glyph = hud.glyph
        switch (glyph.tone, glyph.fill, glyph.mark) {
        case (.neutral, _, _): return .idle
        case (.voice, .ring, _): return .starting
        case (.voice, _, _): return .live
        case (.cursor, _, .spinner): return .working
        case (.cursor, _, _): return .success
        case (.warn, _, _): return .warning
        case (.err, _, _): return .failure
        case (.ok, _, _): return .success
        }
    }

    /// The panel names warning and failure alike (`attention`); the card's
    /// err ground tells them apart.
    static func panelMeaning(_ panel: StatusPanelState, terminating: Bool) -> Meaning {
        switch panel.primaryGlyph {
        case .start: return terminating ? .stopping : .idle
        case .starting: return .starting
        case .stop: return .live
        case .working: return .working
        case .done: return .success
        case .attention: return panel.cardTone == .err ? .failure : .warning
        }
    }

    // MARK: The checks

    /// Asserts every surface of `state` agrees with the expected meaning.
    func assertConsistent(
        _ state: DictationState,
        captureStarted: Bool = true,
        canRecover: Bool,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = Self.expectedMeaning(state, captureStarted: captureStarted)
        let s = Self.project(state, captureStarted: captureStarted, canRecover: canRecover)
        let tag = "\(label) [\(state.kind.rawValue), recover=\(canRecover)]"

        // Recorder.
        let hudExpected: Meaning = expected == .stopping ? .idle : expected
        XCTAssertEqual(Self.hudMeaning(s.hud), hudExpected, "HUD glyph: \(tag)", file: file, line: line)
        XCTAssertEqual(s.hud.showsActivityIndicator, expected == .working, "HUD spinner: \(tag)", file: file, line: line)

        // Panel header and card.
        let panel = Self.panelMeaning(s.panel, terminating: state.kind == .terminating)
        XCTAssertEqual(panel, expected, "panel: \(tag)", file: file, line: line)
        XCTAssertEqual(s.header.indicator == .working, expected == .working, "header working: \(tag)", file: file, line: line)
        XCTAssertEqual(s.panel.cardTone == .err, expected == .failure, "err card: \(tag)", file: file, line: line)
        XCTAssertEqual(s.panel.cardTone == .voice, expected == .live, "voice card: \(tag)", file: file, line: line)
        switch expected {
        case .success, .warning, .failure:
            XCTAssertEqual(s.panel.outcomeGlyph, s.hud.glyph, "the panel's outcome is the recorder's glyph: \(tag)", file: file, line: line)
        case .idle, .starting, .live, .working, .stopping:
            XCTAssertNil(s.panel.outcomeGlyph, "no outcome outside a finished job: \(tag)", file: file, line: line)
            XCTAssertNil(s.panel.resultText, "no result words outside a finished job: \(tag)", file: file, line: line)
        }
        let runs = [.recording, .finalizing, .transcribing, .processingAI, .inserting].contains(state.kind)
        XCTAssertEqual(s.panel.dictationRows.contains { $0.id == .cancel }, runs, "Cancel row while a job runs: \(tag)", file: file, line: line)
        XCTAssertEqual(s.panel.dictationRows.contains { $0.id == .insertTranscriptAgain }, canRecover, "Insert Again follows the shell: \(tag)", file: file, line: line)
        if state.kind == .idle {
            XCTAssertTrue(s.panel.primaryIsEnabled, "Start is available: \(tag)", file: file, line: line)
            XCTAssertEqual(s.panel.primaryTitle, "Start Recording", tag, file: file, line: line)
        }
        if !Self.inserted(state) {
            XCTAssertFalse(s.panel.readiness.contains("Inserted"), "no Inserted for text that was not inserted: \(tag) → \(s.panel.readiness)", file: file, line: line)
        }

        // Menu-bar icon.
        switch expected {
        case .starting, .live:
            XCTAssertEqual(s.icon.phase, .recording, "icon: \(tag)", file: file, line: line)
        case .working:
            XCTAssertEqual(s.icon.phase, .processing, "icon: \(tag)", file: file, line: line)
        case .idle, .success, .warning, .failure, .stopping:
            XCTAssertEqual(s.icon.phase, .idle, "icon: \(tag)", file: file, line: line)
            XCTAssertNil(s.icon.glow, "no glow once a job is over: \(tag)", file: file, line: line)
        }
        let iconBadges = state.kind == .blocked || state.kind == .failed
        XCTAssertEqual(s.icon.badge == .warning, iconBadges, "icon badge: \(tag)", file: file, line: line)
    }

    private static func inserted(_ state: DictationState) -> Bool {
        if case .completed(_, let summary) = state, case .inserted = summary.insertion { return true }
        return false
    }

    // MARK: Tests

    func testEveryControllerStateMeansTheSameOnEverySurface() {
        for canRecover in [false, true] {
            for state in Self.fixtures {
                assertConsistent(state, canRecover: canRecover, "fixture")
                if case .recording = state {
                    assertConsistent(state, captureStarted: false, canRecover: canRecover, "fixture, mic coming up")
                }
            }
        }
    }

    /// Every transition the reducer allows from every fixture lands on a
    /// defined, consistent surface state — including the returns to idle
    /// after Escape, Dismiss and Reset (no spinner, outcome or Cancel left).
    func testEveryLegalTransitionLandsOnAConsistentSurfaceState() throws {
        var legal = 0
        for canRecover in [false, true] {
            for state in Self.fixtures {
                for event in Self.events where DictationReducer.isLegal(state, event: event) {
                    let next = try DictationReducer.reduce(state, event: event)
                    legal += 1
                    assertConsistent(next, canRecover: canRecover, "\(state.kind.rawValue) + \(event.kind)")
                }
            }
        }
        XCTAssertGreaterThan(legal, 40, "the walk covers the reducer, not a handful of edges")
    }

    /// The in-app tests (wizard, Home) end `completed(.deliveredInApp)`, and
    /// the shell dismisses the recorder instead of rendering it: the
    /// rendered state the panel reads is idle. The card must not claim the
    /// text was inserted anywhere.
    func testAnInAppTestNeverReadsInsertedOnThePanel() {
        let state = DictationState.completed(Self.job, CompletionSummary(insertion: .deliveredInApp))
        let s = Self.project(state, hud: .idle)
        XCTAssertNil(s.panel.outcomeGlyph)
        XCTAssertNil(s.panel.resultText)
        XCTAssertFalse(s.panel.readiness.contains("Inserted"), s.panel.readiness)
        XCTAssertFalse(s.panel.primaryTitle.contains("Inserted"), s.panel.primaryTitle)
        XCTAssertEqual(s.icon.phase, .idle)
        XCTAssertNil(s.icon.badge)
    }

    /// The finishing badge ("1 finishing") is shown by the recorder and the
    /// panel together, and only while a newer job records or processes.
    func testTheOverlapBadgeAgreesBetweenTheRecorderAndThePanel() {
        for state in Self.fixtures {
            let hud = HUDViewState(dictationState: state, finishingCount: 1)
            let s = Self.project(state, hud: hud)
            XCTAssertEqual(s.panel.header.finishingBadge, hud.finishingBadge, "\(state.kind)")
            let shows = [.recording, .finalizing, .transcribing, .processingAI, .inserting].contains(state.kind)
            XCTAssertEqual(hud.finishingBadge != nil, shows, "\(state.kind)")
        }
    }

    /// A standing readiness problem (model missing, permission denied) is
    /// the same verdict on the icon, the panel, the window's sidebar pill
    /// and Home's hero; a download in flight is the fix happening.
    func testTheReadinessVerdictAgreesOnIconPanelSidebarAndHome() {
        for blocked in [false, true] {
            let icon = StatusItemAppearance(dictationState: .idle, needsAttention: blocked)
            let context = StatusPanelTests.context(readinessTitle: blocked ? "Model not ready" : "Ready", isBlocked: blocked)
            let headerContext = StatusMenuHeaderContext(attention: blocked ? "Model not ready" : nil)
            let panel = StatusPanelState(
                header: StatusMenuHeaderState(context: headerContext, hud: .idle),
                headerContext: headerContext, context: context
            )
            let readiness = MainWindowReadiness(statusTitle: context.readinessTitle, isBlocked: blocked, shortcutGlyphs: "⌃⇧Space")
            let home = HomeHeroState(readiness: readiness, interaction: .pushToTalk, modelName: "Whisper", microphoneName: "Mic", ai: .off)

            XCTAssertEqual(icon.badge == .warning, blocked)
            XCTAssertEqual(panel.readinessTone == .warn, blocked)
            XCTAssertEqual(panel.readinessIsAttention, blocked)
            XCTAssertEqual(readiness.tone, blocked ? .warn : .ok)
            XCTAssertEqual(home.readiness.tone, readiness.tone)
            XCTAssertEqual(home.readiness.title, panel.readiness.components(separatedBy: " · ").first)
            XCTAssertEqual(panel.dictationRows.contains { $0.id == .fix }, blocked)
        }
    }

    /// The edition matrix for the surfaces that read the edition directly:
    /// the wizard's Accessibility card and checklist line exist for every
    /// grant state in both editions, and only the App Store edition says it
    /// types the text (ADR-026).
    func testTheWizardsAccessibilityCopyIsDefinedForBothEditions() {
        let statuses: [AccessibilityPermissionStatus] = [.notDetermined, .granted, .denied, .unknown]
        for edition in DistributionEdition.allCases {
            for status in statuses {
                let model = OnboardingViewModel(stage: .ready, accessibilityStatus: status, edition: edition)
                let line = model.accessibilityCardLine
                let detail = model.checklistDetail(for: .accessibility)
                XCTAssertFalse(line.isEmpty, "\(edition) \(status)")
                XCTAssertFalse(detail.isEmpty, "\(edition) \(status)")
                XCTAssertEqual(model.edition, edition)
                if edition == .appStore {
                    XCTAssertFalse(line.contains("cursor"), "the App Store edition never claims AX insertion: \(line)")
                }
            }
        }
    }

    /// The wizard's model chip and the Ready checklist agree for every
    /// model lifecycle state: work in progress is never offered as a Fix,
    /// a failure always is, and a ready model is never open.
    func testTheWizardsModelChipAndChecklistAgreeForEveryModelState() {
        let summary = InstalledModelSummary(modelID: "whisper", revision: "r", ownership: .managedByKvoice)
        let failure = ModelFailure(code: KVoiceErrorCode.modelLoadFailed.rawValue, message: "Failed")
        let states: [ModelLifecycleState] = [
            .absent, .validatingExternal, .downloading(completed: 1, total: 4), .downloadPaused(resumableBytes: 1),
            .verifying(completedFiles: 1, totalFiles: 2), .installing, .loading, .optimizing, .ready(summary),
            .inference(summary, jobID: Self.job), .corrupt(failure), .incompatible(failure), .deleting(summary),
            .error(failure), .unavailable(failure),
        ]
        for edition in DistributionEdition.allCases {
            for state in states {
                let model = OnboardingViewModel(stage: .ready, modelState: state, edition: edition)
                let chip = model.modelChip
                XCTAssertFalse(chip.title.isEmpty, "\(state)")
                XCTAssertFalse(model.checklistDetail(for: .model).isEmpty, "\(state)")
                switch chip.tone {
                case .ok:
                    XCTAssertFalse(model.checklistOffersFix(for: .model), "ready is not open: \(state)")
                case .cursor where model.modelIsInProgress:
                    XCTAssertFalse(model.checklistOffersFix(for: .model), "progress, not Fix…: \(state)")
                case .err:
                    XCTAssertTrue(model.modelCardIsFailed, "\(state)")
                    XCTAssertTrue(model.checklistOffersFix(for: .model), "a failure is fixable: \(state)")
                case .cursor, .warn, .neutral, .voice:
                    XCTAssertFalse(model.modelCardIsFailed, "\(state)")
                }
            }
        }
    }

    // MARK: Model readiness phases (fix/post-0.1.7)

    private static let whisperEntry = SpeechModelCatalogEntry(
        id: "whisper", displayName: "Whisper", variantName: "Standard",
        family: "whisper-large-v3-turbo", runtime: .whisperKitCoreML, hosting: .onDevice,
        supportsStreaming: true, supportsBatch: true, downloadBytes: 650_000_000,
        languageSummary: "99 languages", summary: "Default.", isRecommended: true,
        revision: "rev", manifestResource: "whisper", manifestSHA256: String(repeating: "a", count: 64)
    )

    /// The words every surface must use for a phase. Verifying also covers
    /// the external-folder check, which the cards call "Checking".
    private static func phaseWords(_ phase: ModelReadinessPhase) -> [String] {
        switch phase {
        case .downloading: return ["Download"]
        case .downloadPaused: return ["paused", "Paused"]
        case .verifying: return ["Verif", "Check"]
        case .installing: return ["Install"]
        case .loading: return ["Load"]
        case .optimizing: return ["Optimiz"]
        }
    }

    /// Every other phase's words: a surface that shows one of them for this
    /// phase has drifted (the 0.1.7 panel said "Downloading" while Speech
    /// Models said the model was being optimized).
    private static func otherPhaseWords(_ phase: ModelReadinessPhase) -> [String] {
        let all: [ModelReadinessPhase] = [.downloading(fraction: nil), .downloadPaused, .verifying, .installing, .loading, .optimizing]
        // A paused download is still about the download.
        let mine = Set(phaseWords(phase) + (phase == .downloadPaused ? ["Download"] : []))
        return all.filter { !Self.samePhase($0, phase) }.flatMap(phaseWords).filter { !mine.contains($0) }
    }

    private static func samePhase(_ a: ModelReadinessPhase, _ b: ModelReadinessPhase) -> Bool {
        switch (a, b) {
        case (.downloading, .downloading): return true
        default: return a == b
        }
    }

    private func assertSays(_ text: String, _ phase: ModelReadinessPhase, _ surface: String, _ tag: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(Self.phaseWords(phase).contains { text.contains($0) }, "\(surface) does not name \(phase): \(tag) → \(text)", file: file, line: line)
        for word in Self.otherPhaseWords(phase) {
            XCTAssertFalse(text.contains(word), "\(surface) says \(word) during \(phase): \(tag) → \(text)", file: file, line: line)
        }
    }

    /// While the default model is on its way to ready, the menu-bar icon,
    /// the menu header, the status panel (progress row and readiness line),
    /// the sidebar pill, Home's hero, the wizard (chip and progress label)
    /// and Speech Models all name the same phase — under each activity the
    /// library runs it in, because `.downloading` spans the load and the
    /// first compile and `.installing` is the launch re-verification that
    /// loads the default.
    func testEveryModelLifecycleStateNamesTheSamePhaseOnEverySurface() {
        let summary = InstalledModelSummary(modelID: "whisper", revision: "r", ownership: .managedByKvoice)
        let failure = ModelFailure(code: KVoiceErrorCode.modelLoadFailed.rawValue, message: "Failed")
        let states: [ModelLifecycleState] = [
            .absent, .validatingExternal, .downloading(completed: 1, total: 4), .downloading(completed: 0, total: 0),
            .downloadPaused(resumableBytes: 1), .verifying(completedFiles: 1, totalFiles: 2), .installing, .loading,
            .optimizing, .ready(summary), .inference(summary, jobID: Self.job), .corrupt(failure),
            .incompatible(failure), .deleting(summary), .error(failure), .unavailable(failure),
        ]
        let activities: [ModelActivity] = [.downloading("whisper"), .installing("whisper"), .loading("whisper")]
        for state in states {
            let phase = ModelReadinessPhase(state)
            let tag = "\(state)"

            // Readiness line: status row, panel, sidebar pill, Home hero.
            let readinessTitle = ModelReadinessPhase.readinessTitle(for: state)
            let sidebar = MainWindowReadiness(statusTitle: readinessTitle, isBlocked: true, shortcutGlyphs: "⌃⇧Space")
            let home = HomeHeroState(readiness: sidebar, interaction: .pushToTalk, modelName: "Whisper", microphoneName: "Mic", ai: .off)
            if let phase {
                assertSays(readinessTitle, phase, "readiness", tag)
                assertSays(home.readiness.title, phase, "Home", tag)
            } else {
                XCTAssertEqual(readinessTitle, "Model not ready", tag)
            }
            XCTAssertEqual(sidebar.tone, .warn, tag)
            XCTAssertEqual(home.readiness.tone, sidebar.tone, tag)

            // Speech Models' "In use" card (what the page renders, resident
            // or not), its package status line, and the wizard.
            let card = ModelSettingsViewModel.statusDescription(for: state)
            let wizard = OnboardingViewModel(stage: .ready, modelState: state)
            if let phase {
                assertSays(card, phase, "Speech Models status", tag)
                for resident in [false, true] {
                    let models = SpeechModelsViewModel(snapshot: SpeechModelsSnapshot(
                        catalog: SpeechModelCatalog(entries: [Self.whisperEntry]),
                        states: ["whisper": state],
                        defaultModelID: "whisper",
                        residentModelID: resident ? "whisper" : nil,
                        activity: .downloading("whisper")
                    ))
                    assertSays(models.defaultCard?.statusDescription ?? "", phase, "Speech Models card", "\(tag) resident \(resident)")
                }
                assertSays(wizard.modelChip.title, phase, "wizard chip", tag)
                if phase != .downloadPaused {
                    assertSays(wizard.modelActivityDescription ?? "", phase, "wizard progress", tag)
                }
            }

            // The menu-bar surfaces, under every activity that can carry it.
            for activity in activities {
                let atag = "\(tag) under \(activity)"
                let progress = ModelReadinessPhase.inProgress(activity: activity, state: state)
                let install = progress.map { StatusMenuHeaderContext.ModelInstall(modelName: "Whisper", phase: $0.phase) }
                let headerContext = StatusMenuHeaderContext(
                    modelReady: false, shortcutGlyphs: "⌃⇧Space", attention: readinessTitle, modelInstall: install
                )
                let header = StatusMenuHeaderState(context: headerContext, hud: .idle)
                let panel = StatusPanelState(
                    header: header,
                    headerContext: headerContext,
                    context: StatusPanelTests.context(readinessTitle: readinessTitle, isBlocked: true)
                )
                let icon = StatusItemAppearance(dictationState: .idle, needsAttention: true, downloadFraction: install?.fraction)

                if let shown = progress?.phase {
                    if let phase, phase != .downloadPaused {
                        XCTAssertTrue(Self.samePhase(shown, phase), "the row's phase is the state's: \(atag) → \(shown)")
                    }
                    guard case .modelProgress(let label, let feedPhase) = panel.feed else {
                        return XCTFail("no progress row: \(atag)")
                    }
                    assertSays(label, shown, "panel row", atag)
                    XCTAssertEqual(feedPhase, shown, atag)
                    if case .modelProgress(let headerLabel, _) = header.trailing {
                        assertSays(headerLabel, shown, "menu header", atag)
                    } else {
                        XCTFail("no header progress: \(atag)")
                    }
                    XCTAssertEqual(panel.cardTone, .plain, "the fix happening: \(atag)")
                    XCTAssertEqual(
                        panel.dictationRows.contains { $0.id == .pauseDownload }, false,
                        "the context offers no pausable download here: \(atag)"
                    )
                    // The bar: determinate only for a download with a total;
                    // every other phase slides (still under Reduce Motion).
                    let motion = KVProgressMotion.style(fraction: panel.feed.fraction, reduceMotion: false)
                    if case .downloading(let fraction?) = shown {
                        XCTAssertEqual(motion, .determinate(fraction), atag)
                        XCTAssertNotNil(icon.progress, "the icon rings a download with a total: \(atag)")
                        XCTAssertNil(icon.badge, atag)
                    } else {
                        XCTAssertEqual(motion, .sliding, "an indeterminate phase animates: \(atag)")
                        XCTAssertEqual(KVProgressMotion.style(fraction: panel.feed.fraction, reduceMotion: true), .still, atag)
                        XCTAssertNil(icon.progress, "no ring without a fraction: \(atag)")
                        XCTAssertEqual(icon.badge, .warning, "the standing verdict: \(atag)")
                    }
                } else {
                    XCTAssertEqual(panel.feed, .none, "no progress row without a phase: \(atag)")
                    XCTAssertNil(icon.progress, atag)
                    XCTAssertFalse(panel.primaryAccessibilityLabel.contains("Downloading"), atag)
                }
                // The panel's readiness line is the status row's.
                XCTAssertEqual(panel.readiness, readinessTitle, atag)
            }
        }
    }
}
