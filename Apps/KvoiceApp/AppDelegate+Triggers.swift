import AppKit
import KvoiceAppCore
import KvoiceAudio
import KvoiceDomain
import KvoiceHotkeys
import KvoiceUI

/// Shell wiring for the triggers/audio workstream (product decisions #5 and
/// #10): the Cancel shortcut, the middle mouse trigger, the
/// watchdog's hold ceiling, the Settings › Shortcuts / Recording bindings,
/// and the `Microphone ▸` status submenu.
///
/// Glue only. `KvoiceHotkeys` owns every event monitor and the recorder
/// window, `KvoiceAppCore` decides what an edge means (Hybrid, double-press,
/// middle mouse), `KvoiceUI` renders the controls, and `KvoiceAudio` reads the
/// devices. `TriggerSettingsViewModel` and `AudioInputViewModel` are
/// projections over the settings coordinator (ADR-022 slice 7) and send
/// their own `.setTriggers` / `.setAudioInput` intents; the submenu below
/// sends with origin `.statusMenu` so a refusal line names its door.
extension AppDelegate {
    /// Called once from `applicationDidFinishLaunching`.
    func installTriggers() {
        let adapter = composition.shortcutAdapter
        adapter.onAuxiliaryShortcutRecorded = { [weak self] role, shortcut in
            guard let self, !self.terminationInProgress else { return }
            switch role {
            case .cancel: self.triggerSettingsViewModel.setCancelShortcut(shortcut)
            }
        }
        triggerSettingsViewModel.recordCancelShortcut = { [weak self] in
            self?.composition.shortcutAdapter.presentAuxiliaryRecorder(for: .cancel)
        }
        // Recording › Sound › Preview: the start cue of the set the picker
        // shows, through the same player the controller uses, so what the
        // user hears is what a dictation will play.
        triggerSettingsViewModel.previewCue = { [weak self] set in
            guard let player = self?.composition.feedbackPlayer else { return }
            Task { await player.play(.start, using: set) }
        }
        SettingsSurface.recordingOptionBindings = { [weak self] in
            self?.triggerSettingsViewModel.recordingOptionBindings ?? RecordingOptionBindings()
        }
        SettingsSurface.triggerOptionBindings = { [weak self] in
            self?.triggerSettingsViewModel.triggerOptionBindings ?? TriggerOptionBindings()
        }
        audioInputSubmenuProvider = { [weak self] submenu in
            self?.fillAudioInputSubmenu(submenu) ?? false
        }
    }

    /// Applies `settings.triggers` and the hold ceiling to the hotkey adapter.
    /// Called after every settings load and every trigger change; failures
    /// are shown beside the control rather than thrown away.
    func applyTriggerSettings(_ settings: AppSettings) {
        let adapter = composition.shortcutAdapter
        let triggers = settings.triggers

        // FR-HOTKEY-007: the watchdog synthesizes a key-up after this long
        // without one; it follows the recording limit so a 30-minute
        // push-to-talk hold is not cut at ten minutes (the audio cap is the
        // hard bound either way).
        adapter.maximumHoldDuration = .seconds(settings.maxRecordingSeconds)

        // Cancel: the Escape-equivalent on key-down, for whichever job is live.
        if let cancel = triggers.cancelShortcut {
            do {
                try adapter.registerAuxiliaryShortcut(.cancel, cancel) { [weak self] event in
                    guard event == .keyDown, let self, !self.terminationInProgress,
                          let jobID = self.latestState.jobID else { return }
                    Task { [weak self] in
                        _ = await self?.composition.dictationController.handle(.escape(jobID: jobID))
                    }
                }
                triggerSettingsViewModel.cancelShortcutError = nil
            } catch {
                adapter.unregisterAuxiliaryShortcut(.cancel)
                triggerSettingsViewModel.cancelShortcutError = error.localizedDescription
            }
        } else {
            adapter.unregisterAuxiliaryShortcut(.cancel)
            triggerSettingsViewModel.cancelShortcutError = nil
        }

        // Middle mouse: toggle semantics whatever the keyboard mode.
        do {
            try adapter.setMiddleMouseTrigger(
                enabled: triggers.middleMouseToggleEnabled,
                activationDelay: triggers.middleMouseActivationDelay
            ) { [weak self] event in
                self?.receiveShortcut(event, trigger: .middleMouse)
            }
            triggerSettingsViewModel.middleMouseError = nil
        } catch {
            triggerSettingsViewModel.middleMouseError = error.localizedDescription
        }
    }

    // MARK: Audio Input submenu

    /// `Microphone ▸`: every connected device with the one in use checked,
    /// System Default, and the section. Choosing a device is the Custom
    /// Device mode with that device; System Default returns to following
    /// System Settings. The row's own title carries the current device
    /// (D2/N4), same as `Model:` and `Language:`.
    private func fillAudioInputSubmenu(_ submenu: NSMenu) -> Bool {
        let model = audioInputViewModel
        model.refresh()
        let selection = model.selection

        audioInputItem?.title = String(localized: "Microphone: \(model.currentDeviceName)", table: "Shell")

        let systemDefault = NSMenuItem(
            title: model.systemDefault.map { String(localized: "System Default (\($0.name))", table: "Shell") }
                ?? String(localized: "System Default", table: "Shell"),
            action: #selector(selectSystemDefaultAudioInput),
            keyEquivalent: ""
        )
        systemDefault.target = self
        systemDefault.state = selection.usesSystemDefault && model.mode == .systemDefault ? .on : .off
        systemDefault.isEnabled = !terminationInProgress
        submenu.addItem(systemDefault)

        if !model.devices.isEmpty {
            submenu.addItem(.separator())
        }
        for device in model.devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectAudioInputDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = selection.pinsDevice && selection.device?.uid == device.uid ? .on : .off
            item.isEnabled = !terminationInProgress
            submenu.addItem(item)
        }
        if model.mode == .prioritized {
            let note = NSMenuItem(title: String(localized: "Prioritized List in Use", table: "Shell"), action: nil, keyEquivalent: "")
            note.isEnabled = false
            submenu.addItem(note)
        }

        submenu.addItem(.separator())
        let open = NSMenuItem(title: String(localized: "Microphone Settings…", table: "Shell"), action: #selector(openAudioInput), keyEquivalent: "")
        open.target = self
        submenu.addItem(open)
        return true
    }

    /// The panel's Microphone chooser (P-D4): System Default, the devices,
    /// the prioritized-list note, and Microphone Settings… after the
    /// separator — the same rows as `fillAudioInputSubmenu`, from the view
    /// model that filler has just refreshed (it runs first, inside
    /// `updateMenu(for:)`).
    func statusPanelMicrophoneChooser() -> StatusPanelChooser {
        let model = audioInputViewModel
        let selection = model.selection
        let enabled = !terminationInProgress
        var choices = [StatusPanelChoice(
            id: "systemDefault",
            title: model.systemDefault.map { String(localized: "System Default (\($0.name))", table: "Shell") }
                ?? String(localized: "System Default", table: "Shell"),
            isSelected: selection.usesSystemDefault && model.mode == .systemDefault,
            isEnabled: enabled,
            command: .selectMicrophone(uid: nil),
            separatorAfter: !model.devices.isEmpty
        )]
        for device in model.devices {
            choices.append(StatusPanelChoice(
                id: device.uid,
                title: device.name,
                isSelected: selection.pinsDevice && selection.device?.uid == device.uid,
                isEnabled: enabled,
                command: .selectMicrophone(uid: device.uid)
            ))
        }
        if model.mode == .prioritized {
            choices.append(StatusPanelChoice(id: "prioritized", title: String(localized: "Prioritized List in Use", table: "Shell"), isEnabled: false, command: nil))
        }
        return StatusPanelChooser(
            choices: choices,
            footer: [StatusPanelChoice(id: "settings", title: String(localized: "Microphone Settings…", table: "Shell"), command: .openAudioInput)]
        )
    }

    @objc func selectSystemDefaultAudioInput() {
        guard !terminationInProgress else { return }
        audioInputViewModel.selectDevice(uid: nil, origin: .statusMenu)
    }

    @objc func selectAudioInputDevice(_ sender: NSMenuItem) {
        guard !terminationInProgress, let uid = sender.representedObject as? String else { return }
        audioInputViewModel.selectDevice(uid: uid, origin: .statusMenu)
    }

    @objc func openAudioInput() {
        openMainWindow(section: .audioInput)
    }
}
