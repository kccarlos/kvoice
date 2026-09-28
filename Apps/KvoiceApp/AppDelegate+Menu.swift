import AppKit
import KvoiceAppCore
import KvoiceDomain
import KvoiceUI

/// The status item and everything reachable from it, plus the two projections
/// that follow dictation state: escape monitoring and terminal HUD dismissal.
///
/// Every submenu is rebuilt from current settings rather than mutated in place,
/// and switching is refused while a job is active: a running job holds a
/// settings snapshot, so swapping the mode or endpoint underneath it would make
/// its behavior nondeterministic.
extension AppDelegate {
    func installStatusItem() {
        // variableLength, not squareLength: the logo is wider than it is tall,
        // and a square slot would clip it.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = String(localized: "KVoice voice input", table: "Shell")
        if let button = item.button {
            statusIcon = StatusItemIconController(button: button)
        }

        // Layout (D.1, regrouped 2026-09-13 with `NSMenuItem.sectionHeader`
        // headers so a glance shows what each block does; refined by the
        // 2026-09-16 design review's D1-D7/N4-N10):
        //
        //   Dictation      Start/Stop Recording (shortcut glyphs folded into
        //                  the title, N10; drawn by the P-D3 header row —
        //                  `StatusMenuHeaderItemView` on the same item, so
        //                  the ring, meter, clock and install progress live
        //                  there), Cancel / Use Raw Transcript Now
        //                  while a job runs, Copy Transcript / Insert
        //                  Transcript Again while a failure keeps the
        //                  transcript (ADR-022 item 6), Copy Last
        //                  Transcription, Status, Fix in… while blocked (N7)
        //   Transcription  Model ▸, Language ▸, Microphone ▸ (N4; the one
        //                  group with SF Symbols — `menus.md › Icons`: all
        //                  items in a group get icons, or none)
        //   AI             Use AI Actions (N5), Default Action ▸,
        //                  Configuration ▸
        //   App            History, Settings…, Setup Guide…, kvoice Help
        //                  (flattened from Help & Setup ▸, N6), About, Quit
        //
        // Launch at Login and Show Dock Icon left the menu the same day; they
        // live only in Settings › General now. "Open kvoice" left on
        // 2026-09-16: it and Settings… opened the same window, so it became
        // one item (KNOWN_ISSUES "Accepted deviations"). Every item
        // is rebuilt from state in updateMenu(for:) rather than mutated ad hoc.
        // Every item carries a `StatusMenuItemID` so the inventory can be
        // checked (`verifyStatusMenuInventory`): the shell has no test
        // target, and the product rule is that no row leaves unasked.
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(.sectionHeader(title: String(localized: "Dictation", table: "Shell")).tagged(.dictationHeader))

        // The global shortcut readout is folded into this title ("Start
        // Recording (Control-Shift-Space)") rather than a separate disabled
        // line; see `dictationActionTitle`.
        let action = NSMenuItem(title: String(localized: "Start Recording", table: "Shell"), action: #selector(toggleDictation), keyEquivalent: "")
        action.target = self
        // P-D3: the row is drawn by a hosted SwiftUI view on this same item.
        // The item keeps its title (type-select, VoiceOver), target/action
        // (Return, and the view's click), key navigation and `isEnabled`;
        // `updateMenu(for:)` feeds the view's model beside the title. The
        // model holds nothing of the delegate; the click goes through the
        // item's own selector.
        StatusMenuHeaderItemView.install(on: action, model: statusMenuHeaderModel)
        menu.addItem(action.tagged(.startRecording))
        actionItem = action

        // FR-LIFE-011: the state-equivalent Escape command. It is the required
        // fallback when global Escape monitoring is unavailable (Accessibility
        // denied), so it is always present while a job is active.
        let cancel = NSMenuItem(title: String(localized: "Cancel Current Dictation", table: "Shell"), action: #selector(cancelCurrentDictation), keyEquivalent: "")
        cancel.target = self
        cancel.isHidden = true
        menu.addItem(cancel.tagged(.cancelCurrentDictation))
        cancelItem = cancel

        // ADR-022 item 6: the failure HUD's Copy / Insert Again, reachable
        // from the menu too — the HUD can be behind a full-screen app, and
        // a VoiceOver user may prefer the menu. Same controller commands.
        let copyTranscript = NSMenuItem(title: String(localized: "Copy Transcript", table: "Shell"), action: #selector(copyFailedTranscript), keyEquivalent: "")
        copyTranscript.target = self
        copyTranscript.isHidden = true
        copyTranscript.toolTip = String(localized: "Copies the transcript the last dictation kept after it could not be inserted.", table: "Shell")
        menu.addItem(copyTranscript.tagged(.copyTranscript))
        copyTranscriptItem = copyTranscript
        let insertAgain = NSMenuItem(title: String(localized: "Insert Transcript Again", table: "Shell"), action: #selector(insertFailedTranscriptAgain), keyEquivalent: "")
        insertAgain.target = self
        insertAgain.isHidden = true
        insertAgain.toolTip = String(localized: "Inserts the kept transcript into the app that is in front now.", table: "Shell")
        menu.addItem(insertAgain.tagged(.insertTranscriptAgain))
        insertTranscriptAgainItem = insertAgain
        installHUDRecoveryActions()
        installStatusMenuHeaderFeed()

        let copyLast = NSMenuItem(title: String(localized: "Copy Last Transcription", table: "Shell"), action: #selector(copyLastTranscription), keyEquivalent: "")
        copyLast.target = self
        menu.addItem(copyLast.tagged(.copyLastTranscription))
        copyLastTranscriptionItem = copyLast

        let readiness = NSMenuItem(title: String(localized: "Status: Ready", table: "Shell"), action: #selector(openStatusTarget), keyEquivalent: "")
        readiness.target = self
        menu.addItem(readiness.tagged(.status))
        readinessItem = readiness

        // D4/N7: the explicit fix, next to the status line it explains.
        // Hidden unless `statusSummary.blocked`; see `updateMenu(for:)`.
        let fix = NSMenuItem(title: "", action: #selector(openStatusTarget), keyEquivalent: "")
        fix.target = self
        fix.isHidden = true
        menu.addItem(fix.tagged(.fix))
        fixItem = fix

        // Later waves: memory-pressure warnings. Hidden outside critical
        // pressure; `updateMenu(for:)` toggles it.
        let unloadModel = NSMenuItem(title: String(localized: "Unload Model Now", table: "Shell"), action: #selector(unloadModelForMemoryPressure), keyEquivalent: "")
        unloadModel.target = self
        unloadModel.isHidden = true
        menu.addItem(unloadModel.tagged(.unloadModel))
        unloadModelMenuItem = unloadModel

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "Transcription", table: "Shell")).tagged(.transcriptionHeader))

        // P-D3: SF Symbols on the three rows of this group and nowhere else
        // (`menus.md › Icons`: icons for every item in a group or none; the
        // AI and App groups are text-only groups). Template images at the
        // menu's 13 pt, so they take the menu's text colour and highlight.
        let model = NSMenuItem(title: String(localized: "Model: Missing", table: "Shell"), action: nil, keyEquivalent: "")
        model.submenu = NSMenu()
        model.image = Self.menuSymbol("waveform")
        menu.addItem(model.tagged(.model))
        modelMenuItem = model

        let language = NSMenuItem(title: String(localized: "Language", table: "Shell"), action: nil, keyEquivalent: "")
        language.submenu = NSMenu()
        language.image = Self.menuSymbol("globe")
        menu.addItem(language.tagged(.language))
        languageItem = language

        let audioInput = NSMenuItem(title: String(localized: "Microphone", table: "Shell"), action: nil, keyEquivalent: "")
        audioInput.submenu = NSMenu()
        audioInput.image = Self.menuSymbol("mic")
        menu.addItem(audioInput.tagged(.microphone))
        audioInputItem = audioInput

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "AI", table: "Shell")).tagged(.aiHeader))

        let aiToggle = NSMenuItem(title: String(localized: "Use AI Actions", table: "Shell"), action: #selector(toggleAI), keyEquivalent: "")
        aiToggle.target = self
        menu.addItem(aiToggle.tagged(.useAIActions))
        aiToggleItem = aiToggle

        // "Default Action" (was "Mode"): the action a dictation runs when AI
        // is on, the same choice as the badge in AI Actions.
        let modeMenu = NSMenuItem(title: String(localized: "Default Action", table: "Shell"), action: nil, keyEquivalent: "")
        modeMenu.submenu = NSMenu()
        menu.addItem(modeMenu.tagged(.defaultAction))
        modeItem = modeMenu

        // "Configuration" (was "AI Configuration"): the endpoint that runs it.
        let provider = NSMenuItem(title: String(localized: "Configuration", table: "Shell"), action: nil, keyEquivalent: "")
        provider.submenu = NSMenu()
        menu.addItem(provider.tagged(.configuration))
        providerItem = provider

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "App", table: "Shell")).tagged(.appHeader))

        let history = NSMenuItem(title: String(localized: "History", table: "Shell"), action: #selector(openHistory), keyEquivalent: "h")
        history.target = self
        menu.addItem(history.tagged(.history))
        historyMenuItem = history

        let settings = NSMenuItem(title: String(localized: "Settings…", table: "Shell"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        // macOS 26 attaches a stock "action image" (a gear) to any item it
        // recognises as Settings, which makes this the only row in the menu
        // with an icon. Assigning an image and then nil is the documented
        // opt-out for one item; nil alone leaves the stock image in place.
        settings.image = NSImage()
        settings.image = nil
        menu.addItem(settings.tagged(.settings))

        // D3/N6: flattened from "Help & Setup ▸" (a two-item submenu does
        // not earn a level) into the App group, same selectors, same order.
        let setup = NSMenuItem(title: String(localized: "Setup Guide…", table: "Shell"), action: #selector(openSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup.tagged(.setupGuide))
        setupItem = setup
        let help = NSMenuItem(title: String(localized: "KVoice Help", table: "Shell"), action: #selector(openHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help.tagged(.help))
        helpItem = help

        let about = NSMenuItem(title: String(localized: "About KVoice", table: "Shell"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about.tagged(.about))

        let quit = NSMenuItem(title: String(localized: "Quit KVoice", table: "Shell"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit.tagged(.quit))

        verifyStatusMenuInventory(menu)
        // P-D4: the menu is not the item's `menu` (that would make every
        // left-click open it); the button's action routes a left-click to
        // the panel and a right-click / ⌥-click to this menu, unchanged.
        statusMenu = menu
        statusItem = item
        installStatusPanel(on: item)
        updateMenu(for: .idle)
    }

    /// Debug-only: every `StatusMenuItemID` is in the menu, once, in order.
    /// The shell has no unit tests; this is the check that a row cannot
    /// leave the menu unnoticed (see `StatusMenuItemID`).
    private func verifyStatusMenuInventory(_ menu: NSMenu) {
        let missing = StatusMenuItemID.missing(from: menu)
        assert(missing.isEmpty, "Status menu is missing \(missing.map(\.rawValue))")
        assert(StatusMenuItemID.isComplete(menu), "Status menu items are out of inventory order or duplicated")
    }

    /// A template SF Symbol at the menu's text size, for the Transcription
    /// rows (P-D3).
    private static func menuSymbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        image?.isTemplate = true
        return image
    }

    /// P-D3: the header row follows the HUD's *rendered* state — the same
    /// filtered feed the recorder draws — so its meter and clock are the
    /// HUD's, at the HUD's 20 Hz, and exist only while the HUD renders a
    /// recording. Nothing else feeds a level to the menu.
    private func installStatusMenuHeaderFeed() {
        composition.hudController.renderedStateObserver = { [weak self] rendered in
            self?.statusMenuHeaderModel.apply(hud: rendered)
        }
    }

    func updateMenu(for state: DictationState) {
        // Before the guard: the icon must follow state even if the menu items
        // are not built yet, and it de-duplicates internally.
        // D.1: the warning badge stays up while idle with a missing
        // prerequisite, not only during a blocked/failed job.
        statusIcon?.apply(StatusItemAppearance(dictationState: state, needsAttention: statusSummary.blocked))

        guard let readinessItem, let actionItem else { return }
        updateModelMenu()
        updateAIToggle()
        updateModeMenu()
        updateProviderMenu()
        updateLanguageMenu()
        updateAudioInputMenu()

        let status = statusSummary
        readinessItem.title = String(localized: "Status: \(status.title)", table: "Shell")
        readinessItem.isEnabled = !terminationInProgress
        readinessItem.image = status.blocked
            ? NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Attention needed")
            : nil
        // D4/N7: the same target `openStatusTarget` already picks (Speech
        // Models while the model is not ready, else Permissions), spelled
        // out as its own row so a blocked status is not a hidden button.
        fixItem?.isHidden = !status.blocked
        fixItem?.isEnabled = !terminationInProgress
        fixItem?.title = modelReady
            ? String(localized: "Fix in Permissions…", table: "Shell")
            : String(localized: "Fix in Speech Models…", table: "Shell")
        setupItem?.isEnabled = !terminationInProgress
        helpItem?.isEnabled = !terminationInProgress
        historyMenuItem?.title = historyDegraded ? String(localized: "History (unavailable)", table: "Shell") : String(localized: "History", table: "Shell")
        historyMenuItem?.toolTip = historyDegraded
            ? String(localized: "The history database could not be opened. Dictation continues without saving history.", table: "Shell")
            : nil
        // Later waves: memory-pressure warnings. Visible only under
        // critical pressure; disabled/relabeled while an unload is already
        // in flight or the engine is busy, mirroring the banner button.
        unloadModelMenuItem?.isHidden = !memoryPressureViewModel.isCritical
        unloadModelMenuItem?.isEnabled = !terminationInProgress && memoryPressureViewModel.canUnloadNow
        unloadModelMenuItem?.title = memoryPressureViewModel.isUnloading
            ? String(localized: "Unloading Model…", table: "Shell")
            : String(localized: "Unload Model Now", table: "Shell")
        copyLastTranscriptionItem?.isEnabled = !historyDegraded && !terminationInProgress
        copyLastTranscriptionItem?.toolTip = historyDegraded
            ? String(localized: "History is unavailable, so there is no saved transcription to copy.", table: "Shell")
            : String(localized: "Copies the final text of the newest history entry.", table: "Shell")

        // The Escape-equivalent command follows C.7 exactly: discard during
        // Recording/Finalizing/Transcribing, skip AI during Polish/Translate,
        // and stay disabled while an AX mutation may be in flight.
        actionItem.toolTip = nil
        switch state {
        case .idle:
            let readout = shortcutReadout
            actionItem.title = modelReady
                ? dictationActionTitle("Start Recording", readout: readout)
                : String(localized: "Start Recording (Model Not Ready)", table: "Shell")
            actionItem.toolTip = readout.toolTip
            actionItem.isEnabled = modelReady && !terminationInProgress
            cancelItem?.isHidden = true
        case .recording:
            actionItem.title = dictationActionTitle("Stop Recording", readout: shortcutReadout)
            actionItem.isEnabled = true
            cancelItem?.isHidden = false
            cancelItem?.title = String(localized: "Cancel Current Dictation", table: "Shell")
            cancelItem?.isEnabled = true
        case .finalizing, .transcribing:
            actionItem.title = String(localized: "Dictation In Progress…", table: "Shell")
            actionItem.isEnabled = false
            cancelItem?.isHidden = false
            cancelItem?.title = String(localized: "Cancel Current Dictation", table: "Shell")
            cancelItem?.isEnabled = true
        case .processingAI:
            actionItem.title = String(localized: "Dictation In Progress…", table: "Shell")
            actionItem.isEnabled = false
            cancelItem?.isHidden = false
            cancelItem?.title = String(localized: "Use Raw Transcript Now", table: "Shell")
            cancelItem?.isEnabled = true
        case .inserting:
            actionItem.title = String(localized: "Inserting…", table: "Shell")
            actionItem.isEnabled = false
            cancelItem?.isHidden = false
            cancelItem?.title = String(localized: "Cancel Current Dictation", table: "Shell")
            cancelItem?.isEnabled = false
        case .failed:
            actionItem.title = String(localized: "Dismiss", table: "Shell")
            actionItem.isEnabled = true
            cancelItem?.isHidden = true
        case .completed, .blocked:
            actionItem.title = String(localized: "Dismiss", table: "Shell")
            actionItem.isEnabled = true
            cancelItem?.isHidden = true
        case .terminating:
            actionItem.title = String(localized: "Stopping…", table: "Shell")
            actionItem.isEnabled = false
            cancelItem?.isHidden = true
        }
        // The controller's one scalar for "Copy / Insert Again will be
        // accepted" — the same value that puts the buttons on the HUD. Not
        // tied to `.failed`: with overlapping jobs (ADR-022 item 7) a failed
        // job is kept behind a newer recording and the menu is the only way
        // to reach it until the recorder goes away.
        let recoverable = latestSnapshot?.canRecoverFailedInsertion == true
        copyTranscriptItem?.isHidden = !recoverable
        insertTranscriptAgainItem?.isHidden = !recoverable
        copyTranscriptItem?.isEnabled = recoverable && !terminationInProgress
        insertTranscriptAgainItem?.isEnabled = recoverable && !terminationInProgress

        // P-D3: the header row's context, from the same facts the titles
        // above were just set from. The recorder feed arrives separately
        // (`installStatusMenuHeaderFeed`).
        let readout = shortcutReadout
        statusMenuHeaderModel.apply(context: StatusMenuHeaderContext(
            dictationKind: state.kind,
            modelReady: modelReady,
            isTerminating: terminationInProgress,
            shortcutGlyphs: readout.isGlyph ? readout.title : nil,
            shortcutNote: readout.isGlyph ? nil : readout.title,
            attention: status.blocked ? status.title : nil,
            modelInstall: statusMenuModelInstall
        ))
        // P-D4: the panel's context, from the same facts again, after every
        // submenu above has been rebuilt (the microphone name is refreshed
        // by `fillAudioInputSubmenu`).
        updateStatusPanel()
    }

    /// The library's install in progress, for the header row's progress
    /// bar: only while `ModelActivity` is `.downloading` / `.installing`,
    /// with the fraction from that model's lifecycle state (refreshed on the
    /// 250 ms poll of `withModelStatePolling`) when the byte total is known.
    private var statusMenuModelInstall: StatusMenuHeaderContext.ModelInstall? {
        let modelID: ModelID
        switch modelActivity {
        case .downloading(let id), .installing(let id):
            modelID = id
        default:
            return nil
        }
        let name = composition.modelManager?.catalog.entry(id: modelID)?.displayName
            ?? Self.displayName(forModelID: modelID)
        var fraction: Double?
        if case .downloading(let completed, let total)? = speechModelState(for: modelID), total > 0 {
            fraction = Double(completed) / Double(total)
        }
        return StatusMenuHeaderContext.ModelInstall(modelName: name, fraction: fraction)
    }

    // MARK: Failure recovery (ADR-022 item 6)

    /// Wires the HUD's Copy / Insert Again buttons to the controller. One
    /// instance for the life of the app; the HUD renders the buttons
    /// disabled until this has run.
    private func installHUDRecoveryActions() {
        composition.hudController.recoveryActions = HUDRecoveryActions { [weak self] action in
            switch action {
            case .copy: self?.copyFailedTranscript()
            case .insertAgain: self?.insertFailedTranscriptAgain()
            }
        }
    }

    @objc func copyFailedTranscript() {
        guard !terminationInProgress else { return }
        Task { [weak self] in
            guard let self else { return }
            if await self.composition.dictationController.copyRetainedTranscript() != nil {
                NSSound.beep()
            }
        }
    }

    @objc func insertFailedTranscriptAgain() {
        guard !terminationInProgress else { return }
        Task { [weak self] in
            guard let self else { return }
            if case .failure = await self.composition.dictationController.retryInsertion() {
                NSSound.beep()
            }
        }
    }

    /// The global recording shortcut as it appears inside the Start/Stop
    /// Recording title, with a tooltip explaining the two not-working
    /// cases. D7a/N10: a confirmed shortcut is glyphs, right-aligned the
    /// way every menu on the Mac draws a key equivalent — "Start
    /// Recording  ⌃⇧Space" (`dictationActionTitle(_:readout:)`) — but it
    /// is still a title suffix, not a real `keyEquivalent`: the shortcut
    /// is a global hotkey (KeyboardShortcuts), and a real key equivalent
    /// would let the menu fire it while open, a second trigger path
    /// (parked as P-D2). The two not-working cases stay spelled out in
    /// parentheses, as they always were.
    private var shortcutReadout: (title: String, isGlyph: Bool, toolTip: String?) {
        if let shortcut = currentSettings.shortcut {
            return (GeneralSettingsViewModel.glyphs(for: shortcut), true, nil)
        }
        if let shortcutError {
            return (String(localized: "Shortcut Unavailable", table: "Shell"), false, String(localized: "The recording shortcut could not be registered: \(shortcutError). Choose another in Shortcuts.", table: "Shell"))
        }
        return (String(localized: "No Shortcut", table: "Shell"), false, String(localized: "No recording shortcut is confirmed yet. Confirm one in Shortcuts.", table: "Shell"))
    }

    /// "Start Recording  ⌃⇧Space" when the readout is glyphs, else the
    /// original "Start Recording (No Shortcut)" / "(Shortcut Unavailable)".
    private func dictationActionTitle(_ verb: String, readout: (title: String, isGlyph: Bool, toolTip: String?)) -> String {
        if readout.isGlyph {
            return String(localized: "\(verb)  \(readout.title)", table: "Shell")
        }
        return String(localized: "\(verb) (\(readout.title))", table: "Shell")
    }

    // MARK: Status

    /// The single reason the next dictation would be blocked or degraded, in
    /// the order the user would fix it: model, microphone, then Accessibility
    /// (which only degrades to the clipboard).
    var statusSummary: (title: String, blocked: Bool) {
        if !modelReady {
            switch latestModelState {
            case .downloading, .downloadPaused, .verifying, .installing, .loading, .validatingExternal:
                return (String(localized: "Model loading…", table: "Shell"), true)
            default:
                return (String(localized: "Model not ready", table: "Shell"), true)
            }
        }
        switch permissionSnapshot.microphone {
        case .granted:
            break
        case .notDetermined:
            return (String(localized: "Microphone not granted", table: "Shell"), true)
        case .denied, .restricted:
            return (String(localized: "Microphone denied", table: "Shell"), true)
        }
        if !permissionSnapshot.accessibilityTrusted {
            return (String(localized: "Accessibility off — clipboard only", table: "Shell"), true)
        }
        // Later waves: memory-pressure warnings. Advisory, not blocking —
        // dictation still starts — so it sits last, below every prerequisite
        // that actually prevents it.
        if memoryPressureViewModel.level != .normal {
            return (String(localized: "Memory pressure — dictation may be slower", table: "Shell"), true)
        }
        // ADR-022 item 7: the one note for a press that could not overlap
        // because the environment turned the developer flag off. Advisory.
        if let reason = latestSnapshot?.overlapPausedReason {
            return (HUDViewState.overlapPausedNote(reason), false)
        }
        return (String(localized: "Ready", table: "Shell"), false)
    }

    // MARK: Model submenu

    /// `Model: <name> ▸`. The submenu is filled by `modelSubmenuProvider`
    /// (the models workstream) when installed; until then it carries the
    /// lifecycle state and a link to the Models section.
    private func updateModelMenu() {
        guard let modelMenuItem, let submenu = modelMenuItem.submenu else { return }
        modelMenuItem.title = String(localized: "Model: \(modelMenuTitle)", table: "Shell")
        modelMenuItem.isEnabled = !terminationInProgress
        submenu.removeAllItems()
        if let modelSubmenuProvider, modelSubmenuProvider(submenu) {
            return
        }
        let status = NSMenuItem(title: modelStatusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        submenu.addItem(status)
        submenu.addItem(.separator())
        let manage = NSMenuItem(title: String(localized: "Manage Models…", table: "Shell"), action: #selector(openModels), keyEquivalent: "")
        manage.target = self
        submenu.addItem(manage)
    }

    /// The installed model's name when one is resident, else its status.
    var modelMenuTitle: String {
        switch latestModelState {
        case .ready(let summary), .inference(let summary, _):
            return modelReady ? Self.displayName(forModelID: summary.modelID) : String(localized: "Loading…", table: "Shell")
        default:
            return modelStatusTitle
        }
    }

    /// "whisper-large-v3-turbo-coreml-uncompressed" → "Whisper large-v3-turbo".
    static func displayName(forModelID modelID: String) -> String {
        var name = modelID
        for suffix in ["-coreml-uncompressed", "-coreml", "-uncompressed"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        if name.lowercased().hasPrefix("whisper-") {
            name = "Whisper " + name.dropFirst("whisper-".count)
        }
        return name.isEmpty ? modelID : name
    }

    private var modelStatusTitle: String {
        switch latestModelState {
        case .ready, .inference:
            return modelReady ? String(localized: "Ready", table: "Shell") : String(localized: "Loading…", table: "Shell")
        case .downloading(let completed, let total) where total > 0:
            return String(localized: "Downloading \(Int(Double(completed) / Double(total) * 100))%", table: "Shell")
        case .downloading:
            return String(localized: "Downloading…", table: "Shell")
        case .downloadPaused:
            return String(localized: "Download paused", table: "Shell")
        case .verifying:
            return String(localized: "Verifying…", table: "Shell")
        case .installing:
            return String(localized: "Installing…", table: "Shell")
        case .loading, .validatingExternal:
            return String(localized: "Loading…", table: "Shell")
        case .deleting:
            return String(localized: "Deleting…", table: "Shell")
        case .absent:
            return String(localized: "Missing", table: "Shell")
        case .corrupt, .incompatible, .error:
            return String(localized: "Needs attention", table: "Shell")
        case .unavailable:
            // ADR-025: a system-managed model this Mac cannot run.
            return String(localized: "Unavailable", table: "Shell")
        }
    }

    // MARK: AI toggle

    /// `Use AI Actions` (was `AI Actions: On/Off`, was `AI: On/Off`) is the
    /// master switch (`AIEndpointSettings.isEnabled`, product decision #6):
    /// it is independent of which action is the default, so turning it off
    /// and on again restores the same action. D1/N5: the checkmark is the
    /// only state carrier — a changeable label doubled the word "On" and
    /// the checkmark, and "Off" with no checkmark read as a status line
    /// rather than the command that turns it on. The tooltip says when the
    /// switch is on but no request can be made because no endpoint is
    /// configured.
    private func updateAIToggle() {
        guard let aiToggleItem else { return }
        let idle = latestState.kind == .idle
        let on = currentSettings.ai.isEnabled
        let configured = promptModeSettingsViewModel.canEnableProcessing
        aiToggleItem.title = String(localized: "Use AI Actions", table: "Shell")
        aiToggleItem.state = on ? .on : .off
        aiToggleItem.isEnabled = idle && !terminationInProgress
        aiToggleItem.toolTip = Self.aiToggleToolTip(on: on, configured: configured)
    }

    /// The Use AI Actions tooltip, shared with the panel's switch (P-D4).
    static func aiToggleToolTip(on: Bool, configured: Bool) -> String {
        switch (on, configured) {
        case (true, true):
            return String(localized: "Turns AI processing off. Dictation inserts the raw transcript.", table: "Shell")
        case (true, false):
            return String(localized: "AI is on but no configuration is set, so dictation inserts the raw transcript. Add one in AI Actions.", table: "Shell")
        case (false, true):
            return String(localized: "Turns AI processing on with the default action.", table: "Shell")
        case (false, false):
            return String(localized: "Add an AI configuration in AI Actions before turning this on.", table: "Shell")
        }
    }

    /// ADR-022 slice 3: the menu no longer reaches into the AI view models.
    /// It builds the next `AIEndpointSettings` from the committed state with
    /// the same domain helpers the view models use and sends one intent;
    /// both AI view models are projections (slice 7 part B) and read the
    /// committed state live, so nothing re-applies anything to them.
    @objc func toggleAI() {
        // Idle-gating is the reducer's `.setAI` row for the status-menu
        // origin; the item itself is disabled while a job runs.
        var ai = currentSettings.ai
        if ai.isEnabled {
            ai.isEnabled = false
            sendSettingsIntent(.setAI(ai, origin: .statusMenu))
            return
        }
        guard ai.canEnableProcessing else {
            openMainWindow(section: .aiActions)
            return
        }
        // A default action is needed for the switch to mean anything; fall
        // back to the first usable one rather than enabling a no-op.
        if ai.activePromptMode?.isUsable != true {
            guard let candidate = ai.promptModes.first(where: \.isUsable) else {
                openMainWindow(section: .aiActions)
                return
            }
            ai.apply(promptMode: candidate)
        }
        ai.isEnabled = true
        sendSettingsIntent(.setAI(ai, origin: .statusMenu))
    }

    /// ⌘1–⌘0 while the main window is key: make the n-th saved action the
    /// default (the tenth is ⌘0). Returns true when the key was consumed.
    /// The action applies from the next dictation. While a job is running
    /// the event is left alone: during `.recording` the recording-scoped
    /// monitor (ADR-021, `AppDelegate+RecorderControls.swift`) switches the
    /// *current* job's action instead, and in every other phase a ⌘digit
    /// means nothing.
    func handleDefaultActionShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.numericPad) == .command,
              let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let number = Int(characters)
        else { return false }
        // Not a settings gate but the key router's: during `.recording` the
        // recording-scoped monitor owns ⌘n, and elsewhere in a job the key
        // means nothing. The write itself goes through the modes view
        // model, which sends `.setAI` (origin `.page(.aiActions)`) itself —
        // a projection, same as every other settings page.
        guard latestState.kind == .idle, !terminationInProgress else { return false }
        guard promptModeSettingsViewModel.selectDefaultAction(shortcutNumber: number) != nil else {
            return false
        }
        updateMenu(for: latestState)
        return true
    }

    // MARK: Language and Audio Input submenus

    /// `Language ▸`. Filled by `languageSubmenuProvider` (the models
    /// workstream); until then a checked "Auto-detect", which is what the
    /// transcription does.
    private func updateLanguageMenu() {
        guard let languageItem, let submenu = languageItem.submenu else { return }
        submenu.removeAllItems()
        languageItem.title = String(localized: "Language: Auto-detect", table: "Shell")
        languageItem.isEnabled = !terminationInProgress
        if let languageSubmenuProvider, languageSubmenuProvider(submenu) {
            return
        }
        let auto = NSMenuItem(title: String(localized: "Auto-detect", table: "Shell"), action: nil, keyEquivalent: "")
        auto.state = .on
        auto.isEnabled = false
        submenu.addItem(auto)
    }

    /// `Microphone ▸`. Filled by `audioInputSubmenuProvider` (the audio
    /// workstream), which also sets the row's title to the current device
    /// (D2/N4); until then the system default input, checked, and the
    /// title falls back to the bare section name.
    private func updateAudioInputMenu() {
        guard let audioInputItem, let submenu = audioInputItem.submenu else { return }
        submenu.removeAllItems()
        audioInputItem.title = String(localized: "Microphone", table: "Shell")
        audioInputItem.isEnabled = !terminationInProgress
        if let audioInputSubmenuProvider, audioInputSubmenuProvider(submenu) {
            return
        }
        let device = SettingsSurface.defaultInputDeviceName() ?? String(localized: "No input device", table: "Shell")
        audioInputItem.title = String(localized: "Microphone: \(device)", table: "Shell")
        let current = NSMenuItem(title: String(localized: "\(device) (System Default)", table: "Shell"), action: nil, keyEquivalent: "")
        current.state = .on
        current.isEnabled = false
        submenu.addItem(current)
    }

    // MARK: Default Action submenu

    /// Rebuilds the Default Action submenu (titled "Mode" before 2026-09-13)
    /// from current settings.
    ///
    /// Refused while a job is active for the same reason endpoint and shortcut
    /// changes are: the running job holds a settings snapshot.
    ///
    /// P-D1 (2026-09-16): the "Off" row that duplicated "Use AI Actions" was
    /// dropped here — the checkmark on that one row is now the only door
    /// that turns AI off. Picking an action still never flips the switch
    /// (product decision #6, unchanged): a chosen default action is
    /// remembered for whenever AI is next turned on.
    private func updateModeMenu() {
        guard let submenu = modeItem?.submenu else { return }
        submenu.removeAllItems()

        let idle = latestState.kind == .idle
        modeItem?.isEnabled = idle && !terminationInProgress

        let modes = currentSettings.ai.promptModes
        guard !modes.isEmpty else { return }

        for (index, mode) in modes.enumerated() {
            let item = NSMenuItem(
                title: mode.menuTitle,
                action: #selector(selectPromptMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            item.state = mode.id == currentSettings.ai.activePromptModeID
                && currentSettings.ai.mode != .off ? .on : .off
            item.isEnabled = idle && mode.isUsable
            submenu.addItem(item)
        }
    }

    @objc private func selectPromptMode(_ sender: NSMenuItem) {
        let modes = currentSettings.ai.promptModes
        guard modes.indices.contains(sender.tag) else { return }
        selectPromptMode(mode: modes[sender.tag])
    }

    /// The pick itself, shared by the submenu item and the panel's chooser
    /// (P-D4, `selectDefaultAction`). Named apart from the selector so the
    /// `#selector` reference stays unambiguous.
    func selectPromptMode(mode: PromptMode) {
        guard mode.isUsable else { return }

        // The same copy-into-the-request-fields the section's pick does;
        // choosing an action never flips the switch (product decision #6).
        var ai = currentSettings.ai
        ai.apply(promptMode: mode)
        sendSettingsIntent(.setAI(ai, origin: .statusMenu))
    }

    // MARK: Configuration submenu

    /// Rebuilds the Configuration submenu (titled "AI Configuration" before
    /// 2026-09-13) from current settings.
    ///
    /// Switching is refused while a job is active for the same reason shortcut
    /// changes are: the running job holds a settings snapshot, and swapping the
    /// endpoint underneath it would make its behaviour nondeterministic.
    ///
    /// P-D1 (2026-09-16): the "Off" row that duplicated "Use AI Actions" was
    /// dropped here too, for the same reason as the Default Action submenu.
    /// Picking a configuration while AI is off still turns it on
    /// (`selectProviderConfiguration`, unchanged): a usable endpoint is the
    /// one condition that makes the switch mean anything.
    private func updateProviderMenu() {
        guard let submenu = providerItem?.submenu else { return }
        submenu.removeAllItems()

        let idle = latestState.kind == .idle
        providerItem?.isEnabled = idle && !terminationInProgress

        let configurations = currentSettings.ai.configurations
        if configurations.isEmpty {
            let empty = NSMenuItem(
                title: String(localized: "No AI configurations — add one in AI Actions", table: "Shell"),
                action: #selector(openAIActions),
                keyEquivalent: ""
            )
            empty.target = self
            submenu.addItem(empty)
            return
        }

        for (index, configuration) in configurations.enumerated() {
            let title = configuration.modelID.isEmpty
                ? configuration.menuTitle
                : "\(configuration.menuTitle) · \(configuration.modelID)"
            let item = NSMenuItem(
                title: title,
                action: #selector(selectProviderConfiguration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            item.state = configuration.id == currentSettings.ai.activeConfigurationID
                && currentSettings.ai.mode != .off ? .on : .off
            // An incomplete configuration cannot service a request; neither
            // can the on-device one while the environment says the model is
            // unavailable (ADR-024). It stays listed, with the reason.
            item.isEnabled = idle && configuration.isUsable && configurationUnavailableReason(configuration) == nil
            if !configuration.isUsable {
                item.toolTip = String(localized: "Needs a base URL and model before it can be used.", table: "Shell")
            } else if let reason = configurationUnavailableReason(configuration) {
                item.toolTip = reason
            }
            submenu.addItem(item)
        }
    }

    /// ADR-024: the localized reason an on-device configuration cannot take
    /// a request right now, or nil for every other configuration and while
    /// the fact has not been observed yet.
    func configurationUnavailableReason(_ configuration: AIConfiguration) -> String? {
        let availability: AIProviderAvailability?
        switch configuration.kind.transport {
        case .appleIntelligence: availability = environmentProfile.appleIntelligenceAvailability
        case .privateCloudCompute: availability = environmentProfile.privateCloudComputeAvailability
        case .openAICompatible: availability = nil
        }
        guard let reason = availability?.unavailableMessage else { return nil }
        return DomainCopy.localized(reason)
    }

    @objc private func selectProviderConfiguration(_ sender: NSMenuItem) {
        let configurations = currentSettings.ai.configurations
        guard configurations.indices.contains(sender.tag) else { return }
        selectProviderConfiguration(configuration: configurations[sender.tag])
    }

    /// The pick itself, shared by the submenu item and the panel's chooser
    /// (P-D4, `selectConfiguration`). Named apart from the selector so the
    /// `#selector` reference stays unambiguous.
    func selectProviderConfiguration(configuration: AIConfiguration) {
        guard configuration.isUsable else { return }

        // Copy the configuration into the live request fields, exactly as
        // the section's pick does, and make its saved key the live key.
        var ai = currentSettings.ai
        ai.apply(configuration: configuration)
        if ai.mode == .off {
            // Switching provider from Off implies wanting it on; polish is the
            // documented default mode.
            ai.mode = .polish
        }
        guard sendSettingsIntent(.setAI(ai, origin: .statusMenu)) == nil else { return }
        var secrets = aiSettingsViewModel.secretSettings
        secrets.apiKey = secrets.configurationAPIKeys[configuration.id.uuidString]
        sendSettingsIntent(.setSecrets(secrets, origin: .statusMenu))
    }

    // MARK: Escape monitoring and HUD dismissal

    /// A Blocked HUD has no job, but D.4 says Escape dismisses it, so it is
    /// monitored under a fixed sentinel identity.
    private static let blockedMonitorID = UUID(uuidString: "00000000-0000-0000-0000-00000000B10C")!

    func syncEscapeMonitoring(for state: DictationState) {
        let monitorID: JobID?
        switch state {
        case .recording, .finalizing, .transcribing, .processingAI, .inserting, .completed, .failed:
            monitorID = state.jobID
        case .blocked:
            monitorID = Self.blockedMonitorID
        default:
            monitorID = nil
        }

        guard let jobID = monitorID else {
            if monitoredJobID != nil {
                composition.shortcutAdapter.endActiveJobEscapeMonitoring()
                monitoredJobID = nil
            }
            return
        }
        guard monitoredJobID != jobID else { return }

        composition.shortcutAdapter.endActiveJobEscapeMonitoring()
        monitoredJobID = jobID
        _ = composition.shortcutAdapter.beginActiveJobEscapeMonitoring { [weak self] in
            // P-D4: this monitor has a local half too, and local monitors
            // run in install order — a panel opened during a job would let
            // this one see Escape first and discard the recording. While
            // the panel is up, Escape belongs to the panel (its own monitor
            // closes it); the next Escape, with the panel gone, lands here.
            guard self?.statusPanelController?.isShown != true else { return }
            self?.dismissOrCancelActiveJob()
        }
    }

    private func dismissOrCancelActiveJob() {
        guard !terminationInProgress else { return }
        Task { [weak self] in
            guard let self else { return }
            let state = await self.composition.dictationController.state
            switch state {
            case .completed, .failed, .blocked:
                _ = await self.composition.dictationController.handle(.dismiss)
            default:
                _ = await self.composition.dictationController.cancel()
            }
        }
    }

    /// Auto-dismisses terminal HUD states on the D.4 timings. Blocked and
    /// recoverable failures dismiss too (FR-HUD-005); fatal model errors and a
    /// failed clipboard copy wait for the user.
    func scheduleTerminalDismissal(for state: DictationState, hudState: HUDViewState) {
        switch state {
        case .completed, .failed, .blocked:
            break
        default:
            terminalDismissTask?.cancel()
            terminalDismissTask = nil
            return
        }
        guard terminalDismissTask == nil else { return }
        guard let duration = hudState.autoDismissAfter(timings: composition.hudController.dismissTimings) else { return }
        terminalDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                self?.terminalDismissTask = nil
                return
            }
            guard let self, !Task.isCancelled else { return }
            _ = await self.composition.dictationController.handle(AppCommand.dismiss)
            terminalDismissTask = nil
        }
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(currentSettings.showDockIcon ? .regular : .accessory)
    }

    // MARK: Menu actions

    @objc func toggleDictation() {
        guard !terminationInProgress else { return }

        switch latestState {
        case .idle where modelReady:
            Task { [weak self] in
                guard let self else { return }
                _ = await self.composition.dictationController.startRecording()
            }
        case .recording:
            Task { [weak self] in
                guard let self else { return }
                _ = await self.composition.dictationController.stopRecording()
            }
        case .completed, .failed, .blocked:
            Task { [weak self] in
                guard let self else { return }
                _ = await self.composition.dictationController.handle(AppCommand.dismiss)
            }
        default:
            break
        }
    }

    @objc func cancelCurrentDictation() {
        guard !terminationInProgress else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await self.composition.dictationController.cancel()
        }
    }

    /// D.1: selecting Status opens the surface that fixes the blocking item:
    /// Models when the model is not ready, otherwise Permissions.
    @objc func openStatusTarget() {
        guard !terminationInProgress else { return }
        openMainWindow(section: modelReady ? .permissions : .models)
    }

    // MARK: Main window

    /// Every window entry point lands here. Presented from an owned AppKit
    /// window: the `showSettingsWindow:` selector silently did nothing for
    /// this accessory app; see MainWindowController.
    func openMainWindow(section: MainWindowSection?) {
        guard !terminationInProgress else { return }
        // P-D4: whoever opens the window — a panel row, `toggleAI` falling
        // through to AI Actions, a HUD button, an App Intent — the panel
        // must not stay up under an activating window.
        statusPanelController?.closeImmediately()
        if mainWindow == nil {
            mainWindow = MainWindowController(appDelegate: self)
        }
        mainWindow?.open(section: section)
    }

    /// The window on whichever section it last showed: the Dock-icon
    /// reopen path and the tutorial's "Open kvoice" buttons. The status
    /// menu's own "Open kvoice" item was removed on 2026-09-16 — Settings…
    /// opens the same window.
    @objc func openMainWindow() {
        openMainWindow(section: nil)
    }

    /// `Settings…` (⌘,): there is no page named Settings since the 2026-09-13
    /// regroup; the item opens the first settings page in the sidebar.
    @objc func openSettings() {
        openMainWindow(section: .settingsEntry)
    }

    @objc func openHistory() {
        openMainWindow(section: .history)
    }

    @objc func openModels() {
        openMainWindow(section: .models)
    }

    @objc func openAIActions() {
        openMainWindow(section: .aiActions)
    }

    /// `kvoice Help`.
    @objc func openHelp() {
        openMainWindow(section: .help)
    }

    /// Dock icon click (when the icon is shown) reopens the main window, like
    /// any document-less app; it never re-shows the setup guide.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // `launchCompleted`: a reopen during the instance handoff would open
        // the main window before the settings load (`AppDelegate.swift`).
        guard !terminationInProgress, launchCompleted else { return false }
        if !hasVisibleWindows {
            openMainWindow(section: nil)
        }
        return true
    }

    /// Copies the final text of the newest history row. Nothing else is
    /// read; the pasteboard is the only side effect.
    @objc func copyLastTranscription() {
        guard !terminationInProgress, !historyDegraded else { return }
        Task { [weak self] in
            guard let self else { return }
            let newest = try? await self.composition.historyStore.fetchPage(before: nil, limit: 1).first
            guard let newest else {
                NSSound.beep()
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(newest.finalText, forType: .string)
        }
    }

    /// Later waves: memory-pressure warnings. Shares `unloadNow()` with the
    /// Runtime card's banner button — one in-flight state, one error.
    @objc func unloadModelForMemoryPressure() {
        memoryPressureViewModel.unloadNow()
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
