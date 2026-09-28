import AppKit
import KvoiceAppCore
import KvoiceDomain
import KvoiceHotkeys
import KvoiceUI

/// Shell wiring for the AI Actions workstream (product decisions #2, #4, #6):
/// the context provider dictation uses for actions that opted into clipboard
/// or selected text, the three Selection Action shortcut slots, and the HUD
/// feedback for a Selection Action run.
///
/// Everything here is glue between packages that must not know each other:
/// `KvoiceUI` supplies the section and its hooks, `KvoiceHotkeys` the
/// recorder and the key handler, `KvoiceAppCore` the runner, and
/// `KvoiceInsertion` the Accessibility reads. Nothing in this file inspects
/// text; it only moves it between those seams.
extension AppDelegate {
    /// ADR-027: after every Private Cloud Compute request or connection
    /// test (a job, a Selection Action, the prompt preview, Verify & Save),
    /// re-read the quota it may have spent.
    func installPrivateCloudComputeObserver() {
        let router = composition.aiProcessingClient
        let observer: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refreshPrivateCloudComputeFacts(trigger: .afterRequest)
            }
        }
        Task { await router.setPrivateCloudComputeObserver(observer) }
    }

    /// Called once from `applicationDidFinishLaunching`.
    func installAIActions() {
        let contextProvider = ShellAIContextProvider(selectionReader: composition.insertionService)
        selectionActionRunner = SelectionActionRunner(
            settingsRepository: composition.settingsStore,
            secretsRepository: composition.secretsStore,
            aiClient: composition.aiProcessingClient,
            insertionService: composition.insertionService,
            selectionReader: composition.insertionService,
            contextProvider: contextProvider,
            diagnostics: composition.diagnostics
        )
        Task { [weak self] in
            await self?.composition.dictationController.setAIContextProvider(contextProvider)
        }

        AIActionsHooks.selectionActionShortcutRecorder = { slot in
            SelectionActionShortcuts.recorder(slot: slot)
        }
        AIActionsHooks.selectionActionShortcutDescription = { slot in
            SelectionActionShortcuts.shortcutDescription(slot: slot)
        }
        // ADR-027: Apple's own "raise your limit" sheet, then a fresh read
        // of the quota it may have changed.
        AIActionsHooks.showPrivateCloudComputeQuotaOptions = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.composition.privateCloudComputeClient.showQuotaIncreaseOptions()
                await self.refreshPrivateCloudComputeFacts(trigger: .afterRequest)
            }
        }
        installPrivateCloudComputeObserver()
        // ADR-026: the App Store edition cannot read another app's
        // selection, so its slots are never registered (the AI Actions page
        // shows why); a shortcut stored by the other edition stays stored.
        guard composition.edition.canReadSelectionInOtherApps else { return }
        SelectionActionShortcuts.install { [weak self] slot in
            self?.runSelectionAction(slot: slot)
        }
        syncSelectionActionShortcuts(for: latestState)
    }

    /// A dictation job and a Selection Action both write into the focused
    /// element, so the slots are silenced — and a run in flight is cancelled
    /// before it can splice its result under the new job — while a job is
    /// anywhere between start and terminal HUD. Called once at install and
    /// then only on a lifecycle change, not per level tick: the library
    /// decodes every slot's stored shortcut on each enable/disable.
    func syncSelectionActionShortcuts(for state: DictationState) {
        let idle = state.kind == .idle && !terminationInProgress
        // ADR-026: never enabled in the App Store edition, where a slot's
        // stored shortcut would otherwise be registered with no handler.
        SelectionActionShortcuts.setEnabled(idle && composition.edition.canReadSelectionInOtherApps)
        if !idle {
            selectionActionRunTask?.cancel()
            selectionActionRunTask = nil
            selectionActionDismissTask?.cancel()
            selectionActionDismissTask = nil
        }
    }

    private func runSelectionAction(slot: Int) {
        guard !terminationInProgress, latestState.kind == .idle, let runner = selectionActionRunner else { return }
        // One run at a time, like the runner itself: a repeat press while the
        // processing HUD is up is ignored rather than cancelling the request.
        guard selectionActionRunTask == nil else { return }
        selectionActionDismissTask?.cancel()
        selectionActionDismissTask = nil

        // The HUD is otherwise driven only by controller snapshots. While the
        // controller is idle nothing else renders, so this borrows the same
        // phases; a dictation started meanwhile wins because its snapshot
        // render replaces whatever is on screen and cancels this run.
        let action = currentSettings.ai.selectionAction(slot: slot)
        showSelectionActionHUD(HUDViewState(phase: .processingAI(HUDProcessingAIState(
            mode: action?.behavior ?? .polish,
            targetLanguageDisplayName: action?.behavior == .translate ? action?.translationLanguage?.displayName : nil
        ))))
        selectionActionRunTask = Task { [weak self] in
            let outcome = await runner.run(slot: slot)
            guard let self, !Task.isCancelled else { return }
            self.selectionActionRunTask = nil
            guard self.latestState.kind == .idle else { return }
            let hud: HUDViewState
            if outcome.isSuccess {
                let kind: HUDCompletionKind = outcome.userFacingMessage == nil ? .success : .clipboardFallback
                hud = HUDViewState(phase: .completed(HUDCompletionState(kind: kind, warningMessage: outcome.userFacingMessage.map { DomainCopy.localized($0) })))
            } else {
                hud = HUDViewState(phase: .failed(HUDFailureState(
                    code: "selectionAction",
                    message: outcome.userFacingMessage.map { DomainCopy.localized($0) }
                        ?? String(localized: "The Selection Action did not run.", table: "Shell")
                )))
            }
            self.showSelectionActionHUD(hud)
            self.selectionActionDismissTask = Task { [weak self] in
                try? await Task.sleep(for: hud.autoDismissAfter(timings: self?.composition.hudController.dismissTimings ?? .compiled) ?? .seconds(2))
                guard let self, !Task.isCancelled, self.latestState.kind == .idle else { return }
                self.composition.hudController.dismiss()
                self.lastRenderedHUDState = nil
                self.selectionActionDismissTask = nil
            }
        }
    }

    private func showSelectionActionHUD(_ state: HUDViewState) {
        // No job snapshot here (a Selection Action is not a dictation), so
        // the toast takes the stored recorder style (ADR-021).
        composition.hudController.show(state, style: currentSettings.recorderStyle)
        // Forget the dictation projection so the next controller snapshot is
        // rendered even if it equals the one shown before this run.
        lastRenderedHUDState = nil
    }
}

/// `AIContextProviding` over the pasteboard and the Accessibility selection
/// reader. Only consulted for actions that opted in (product decision #2:
/// clipboard and selected text, never a screen capture), and only at request
/// time, so neither source is read for an action that does not use it.
struct ShellAIContextProvider: AIContextProviding {
    let selectionReader: any SelectionReading

    func clipboardText() async -> String? {
        await MainActor.run {
            NSPasteboard.general.string(forType: .string)
        }
    }

    func selectedText() async -> String? {
        await selectionReader.readFocusedSelection()
    }
}
