import AppKit
import KvoiceAppCore
import KvoiceDomain
import KvoiceUI

/// P-D4 (product decision 2026-09-16): the status item's left-click opens the
/// Control-Center-style panel; a right-click or ⌥-click opens the `NSMenu`
/// exactly as before, as the keyboard / VoiceOver fallback. This file is
/// the glue: the click split, the `StatusPanelContext` the panel projects —
/// built at the end of `updateMenu(for:)` from the same facts the menu
/// items were just retitled with — the choosers that mirror the submenus,
/// and the command handler, which maps every `StatusPanelCommand` onto the
/// selector its menu row already calls. The panel adds no behaviour.
extension AppDelegate {
    /// Called once from `installStatusItem`, after the menu is built.
    func installStatusPanel(on item: NSStatusItem) {
        let controller = StatusPanelController(model: statusPanelModel)
        statusPanelController = controller
        statusPanelModel.handler = { [weak self] command in
            self?.performStatusPanelCommand(command)
        }
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// The status item's button action: the click split.
    @objc func statusItemClicked(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        let surface = StatusItemClick.surface(
            isRightButton: event?.type == .rightMouseUp || event?.type == .rightMouseDown,
            option: flags.contains(.option),
            control: flags.contains(.control)
        )
        switch surface {
        case .panel:
            statusPanelController?.toggle(relativeTo: button)
        case .menu:
            statusPanelController?.close()
            showStatusMenu()
        }
    }

    /// Pops the menu up from the button the way a set `menu` would — the
    /// button highlights and tracks it — then detaches it again so the
    /// next left-click is the panel's. `performClick` returns when the
    /// menu closes (menu tracking is modal).
    func showStatusMenu() {
        guard let statusItem, let statusMenu else { return }
        statusItem.menu = statusMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: Context

    /// Fills the panel's context from the facts `updateMenu(for:)` has just
    /// applied to the plain items, so the two surfaces can never disagree.
    func updateStatusPanel() {
        let status = statusSummary
        let idle = latestState.kind == .idle
        let terminating = terminationInProgress
        let ai = currentSettings.ai
        let aiOn = ai.isEnabled
        let configured = promptModeSettingsViewModel.canEnableProcessing
        let aiActive = ai.mode != .off

        statusPanelModel.apply(context: StatusPanelContext(
            readinessTitle: status.title,
            isBlocked: status.blocked,
            fixTitle: modelReady
                ? String(localized: "Fix in Permissions…", table: "Shell")
                : String(localized: "Fix in Speech Models…", table: "Shell"),
            modelName: statusPanelModelName ?? modelMenuTitle,
            modelChooser: statusPanelModelChooser() ?? StatusPanelChooser(
                choices: [StatusPanelChoice(id: "status", title: modelMenuTitle, isEnabled: false, command: nil)],
                footer: [StatusPanelChoice(id: "manage", title: String(localized: "Manage Models…", table: "Shell"), command: .openModels)]
            ),
            languageName: LanguageNames.transcriptionLanguageName(forCode: currentSettings.transcriptionLanguage),
            languageChooser: statusPanelLanguageChooser(),
            microphoneName: audioInputViewModel.currentDeviceName,
            microphoneChooser: statusPanelMicrophoneChooser(),
            canOpenChoosers: !terminating,
            ai: StatusPanelContext.AI(
                isOn: aiOn,
                canToggle: idle && !terminating,
                help: Self.aiToggleToolTip(on: aiOn, configured: configured),
                defaultActionName: aiActive ? ai.activePromptMode?.menuTitle : nil,
                defaultActionBadge: aiActive ? ai.activePromptModeID.flatMap { promptModeSettingsViewModel.shortcutBadge(for: $0) } : nil,
                configurationName: aiActive ? ai.activeConfiguration?.menuTitle : nil,
                canChoose: idle && !terminating,
                defaultActions: statusPanelDefaultActionChooser(),
                configurations: statusPanelConfigurationChooser()
            ),
            canCopyLastTranscription: !historyDegraded && !terminating,
            copyLastTranscriptionHelp: historyDegraded
                ? String(localized: "History is unavailable, so there is no saved transcription to copy.", table: "Shell")
                : String(localized: "Copies the final text of the newest history entry.", table: "Shell"),
            canRecoverFailedInsertion: latestSnapshot?.canRecoverFailedInsertion == true,
            memoryPressure: memoryPressureViewModel.isCritical
                ? StatusPanelContext.MemoryPressure(
                    canUnloadNow: memoryPressureViewModel.canUnloadNow,
                    isUnloading: memoryPressureViewModel.isUnloading
                )
                : nil,
            historyTitle: historyDegraded ? String(localized: "History (unavailable)", table: "Shell") : String(localized: "History", table: "Shell"),
            historyHelp: historyDegraded
                ? String(localized: "The history database could not be opened. Dictation continues without saving history.", table: "Shell")
                : nil
        ))
    }

    /// The Default Action chooser: the saved actions, as `updateModeMenu`
    /// lists them (no "Off" row — P-D1; the switch is the one door).
    private func statusPanelDefaultActionChooser() -> StatusPanelChooser {
        let idle = latestState.kind == .idle
        let ai = currentSettings.ai
        return StatusPanelChooser(choices: ai.promptModes.map { mode in
            StatusPanelChoice(
                id: mode.id.uuidString,
                title: mode.menuTitle,
                isSelected: mode.id == ai.activePromptModeID && ai.mode != .off,
                isEnabled: idle && mode.isUsable,
                command: .selectDefaultAction(mode.id)
            )
        })
    }

    /// The Configuration chooser, as `updateProviderMenu` lists it: the
    /// configurations with their model ids, or the one "add one" row that
    /// opens AI Actions.
    private func statusPanelConfigurationChooser() -> StatusPanelChooser {
        let idle = latestState.kind == .idle
        let ai = currentSettings.ai
        if ai.configurations.isEmpty {
            return StatusPanelChooser(choices: [StatusPanelChoice(
                id: "empty",
                title: String(localized: "No AI configurations — add one in AI Actions", table: "Shell"),
                command: .openAIActions
            )])
        }
        return StatusPanelChooser(choices: ai.configurations.map { configuration in
            StatusPanelChoice(
                id: configuration.id.uuidString,
                title: configuration.modelID.isEmpty
                    ? configuration.menuTitle
                    : "\(configuration.menuTitle) · \(configuration.modelID)",
                isSelected: configuration.id == ai.activeConfigurationID && ai.mode != .off,
                // ADR-024: the on-device row is listed like any other and
                // disabled, with the reason, while the model is unavailable.
                isEnabled: idle && configuration.isUsable && configurationUnavailableReason(configuration) == nil,
                help: configuration.isUsable
                    ? configurationUnavailableReason(configuration)
                    : String(localized: "Needs a base URL and model before it can be used.", table: "Shell"),
                command: .selectConfiguration(configuration.id)
            )
        })
    }

    // MARK: Commands

    /// One case per menu selector; each line names the `NSMenuItem` action
    /// it duplicates, so a behaviour change to a command is made in one
    /// place (the selector) and reaches both surfaces.
    private func performStatusPanelCommand(_ command: StatusPanelCommand) {
        switch command {
        case .toggleDictation:
            toggleDictation()
        case .cancelCurrentDictation:
            cancelCurrentDictation()
        case .copyTranscript:
            copyFailedTranscript()
        case .insertTranscriptAgain:
            insertFailedTranscriptAgain()
        case .copyLastTranscription:
            copyLastTranscription()
        case .openStatusTarget:
            openStatusTarget()
        case .unloadModel:
            unloadModelForMemoryPressure()
        case .selectModel(let id):
            // `selectSpeechModel(_:)`
            performSpeechModelAction(.use(id), origin: .statusMenu)
        case .openModels:
            openModels()
        case .selectLanguage(let code):
            // `selectTranscriptionLanguage(_:)`
            sendSettingsIntent(.setTranscriptionLanguage(code, origin: .statusMenu))
        case .selectMicrophone(let uid):
            // `selectSystemDefaultAudioInput` / `selectAudioInputDevice(_:)`
            guard !terminationInProgress else { return }
            audioInputViewModel.selectDevice(uid: uid, origin: .statusMenu)
        case .openAudioInput:
            openAudioInput()
        case .toggleAI:
            toggleAI()
        case .selectDefaultAction(let id):
            // `selectPromptMode(_:)`
            guard let mode = currentSettings.ai.promptModes.first(where: { $0.id == id }) else { return }
            selectPromptMode(mode: mode)
        case .selectConfiguration(let id):
            // `selectProviderConfiguration(_:)`
            guard let configuration = currentSettings.ai.configurations.first(where: { $0.id == id }) else { return }
            selectProviderConfiguration(configuration: configuration)
        case .openAIActions:
            openAIActions()
        case .openHistory:
            openHistory()
        case .openSettings:
            openSettings()
        case .openSetup:
            openSetup()
        case .openHelp:
            openHelp()
        case .showAbout:
            showAbout()
        case .quit:
            quit()
        }
    }
}
