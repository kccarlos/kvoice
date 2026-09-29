import AppKit
import KvoiceDomain
import SwiftUI

/// SwiftUI-native first-run setup.  The view only invokes explicit view-model
/// intents; constructing or displaying it never requests an OS permission.
///
/// Every screen has the same shape: a header (title, one-line purpose,
/// progress), the screen's content in a scroll view, and a bottom action bar
/// with Back on the left and Skip + the primary action on the right. The
/// buttons never move between screens; only their titles and enablement
/// change, and those come from `OnboardingViewModel.actionBar`. Screen
/// content holds the step's own controls (Choose Existing…, Use Recommended,
/// the Try It indicator, the dictation test, the two optional links on
/// Ready) and no navigation.
///
/// Sizing belongs to `OnboardingWindowController`; this view sets no frame.
@MainActor
public struct OnboardingView: View {
    /// Injected by the app shell, so `@Bindable` rather than `@StateObject` —
    /// see the note in `GeneralSettingsView`.
    @Bindable private var viewModel: OnboardingViewModel
    /// Read for the Ready summary's AI line (Off / Polish / Translate to …)
    /// and privacy-boundary line only; the AI form itself lives on the AI
    /// Actions page, which Ready links to. Nil (tests, previews) reads as
    /// Off.
    private let aiSettingsViewModel: AISettingsViewModel?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        viewModel: OnboardingViewModel = .init(),
        aiSettingsViewModel: AISettingsViewModel? = nil
    ) {
        self.viewModel = viewModel
        self.aiSettingsViewModel = aiSettingsViewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            actionBar
        }
        .task {
            // This is a non-prompting status read.  User-facing request
            // buttons below are the only paths that can invoke TCC prompts.
            await viewModel.refreshPermissions()
        }
        .task(id: viewModel.stage) {
            // FR-PERM-005: poll trust every second while the accessibility
            // step is visible. Elsewhere a slower poll keeps both cards
            // fresh (D.9 downgrades a Granted older than 3 s to Unknown) and
            // picks up a change made in System Settings. The task is
            // cancelled as soon as the stage changes or the view goes away.
            let interval: Duration = viewModel.stage == .accessibility ? .seconds(1) : .seconds(2)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                await viewModel.pollPermissions()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Coming back from System Settings is the common case; read
            // immediately rather than waiting for the next poll tick.
            Task { @MainActor in
                await viewModel.appDidBecomeActive()
            }
        }
        .task(id: viewModel.hotkeyTestIsAvailable) {
            // Installs the onboarding-scoped shortcut hook only while the
            // shortcut page shows its Try It indicator, and always uninstalls
            // it: the task is cancelled as soon as the indicator goes (stage
            // change, registration lost, window closed), and `defer` runs
            // `endHotkeyTest()` on every exit path, including cancellation.
            // Never call `beginHotkeyTest()` anywhere else.
            guard viewModel.hotkeyTestIsAvailable else { return }
            viewModel.beginHotkeyTest()
            defer { viewModel.endHotkeyTest() }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                viewModel.tickHotkeyTest()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(viewModel.stage.title)
                    .font(.title2.weight(.semibold))
                Spacer()
                if viewModel.isFinished {
                    StatusLabel(String(localized: "Setup complete", bundle: .module), symbol: "checkmark.circle.fill", tone: .positive)
                        .labelStyle(.titleAndIcon)
                } else {
                    Text(viewModel.progressLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(viewModel.stage.purpose)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            progressIndicator
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(viewModel.progressLabel): \(viewModel.stage.title). \(viewModel.stage.purpose)")
    }

    /// One segment per screen; filled through the current one.
    private var progressIndicator: some View {
        HStack(spacing: 4) {
            ForEach(OnboardingStage.allCases) { stage in
                Capsule(style: .continuous)
                    .fill(stage.ordinal <= viewModel.stage.ordinal ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(height: 4)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.stage)
        .accessibilityHidden(true)
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            stageContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var stageContent: some View {
        switch viewModel.stage {
        case .welcome:
            welcomeStage
        case .speechModel:
            modelStage
        case .microphone:
            microphoneStage
        case .accessibility:
            accessibilityStage
        case .shortcut:
            shortcutStage
        case .ready:
            readyStage
        }
    }

    // MARK: Action bar

    private var actionBar: some View {
        let bar = viewModel.actionBar
        // The reason the primary button is disabled sits beside the buttons
        // when there is room and above them at the window's minimum width,
        // so a long reason never squeezes Skip or the primary button.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                backButton(bar)
                Spacer()
                primaryDisabledReason(bar)
                trailingActions(bar)
            }
            VStack(alignment: .leading, spacing: 8) {
                primaryDisabledReason(bar)
                HStack(spacing: 12) {
                    backButton(bar)
                    Spacer()
                    trailingActions(bar)
                }
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.bar)
    }

    @ViewBuilder
    private func backButton(_ bar: OnboardingActionBar) -> some View {
        if bar.canGoBack {
            Button {
                viewModel.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .accessibilityLabel("Back to the previous setup screen")
        }
    }

    @ViewBuilder
    private func primaryDisabledReason(_ bar: OnboardingActionBar) -> some View {
        if !bar.primaryIsEnabled, let reason = bar.primaryDisabledReason {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func trailingActions(_ bar: OnboardingActionBar) -> some View {
        if let skipTitle = bar.skipTitle {
            Button(skipTitle) {
                viewModel.performSkipAction()
            }
            .buttonStyle(.borderless)
            .disabled(!bar.skipIsEnabled)
            .accessibilityLabel("\(skipTitle) this step")
            // On the Shortcut page with a shortcut already registered, Skip
            // leaves only the Try It check undone; the shortcut is kept.
            .accessibilityHint(viewModel.hotkeyTestIsAvailable
                ? "Continue without trying the shortcut. The shortcut stays set up."
                : "Continue without finishing this step. It stays visible as Not Ready and can be finished later in Settings.")
        }

        Button {
            Task { @MainActor in
                await viewModel.performPrimaryAction()
            }
        } label: {
            HStack(spacing: 6) {
                if bar.primaryIsBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                Text(bar.primaryTitle)
            }
            .frame(minWidth: 96)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!bar.primaryIsEnabled)
        .accessibilityLabel(bar.primaryTitle)
        .accessibilityValue(bar.primaryIsBusy ? Text("In progress") : Text(verbatim: ""))
    }

    // MARK: Welcome

    private var welcomeStage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Private voice input", systemImage: "waveform")
                .font(.title3.weight(.semibold))

            Text("Hold your shortcut, speak, and let go. KVoice records while you dictate, transcribes the speech on this Mac, and places the finished text at your cursor.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    privacyRow("Audio and local speech-to-text stay on this Mac.", symbol: "lock.fill")
                    privacyRow("With AI off, dictation makes no network requests once the model is installed.", symbol: "network.slash")
                    privacyRow("AI is optional and sends transcript text only when you turn it on.", symbol: "text.bubble")
                    privacyRow("There is no account, analytics, or background recording.", symbol: "person.crop.circle.badge.xmark")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Model

    private var modelStage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Download the current model, or choose a folder that already holds a verified copy. A download keeps going while you finish the remaining screens.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        // 2026-09-16: the current model's catalog name, not
                        // a literal — the state below already followed it.
                        Label(viewModel.modelDisplayName, systemImage: "shippingbox")
                            .font(.headline)
                        Spacer()
                        readinessBadge(viewModel.readiness.model)
                    }
                    if let detail = viewModel.modelDetailLine {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Runtime and download size: \(detail)")
                    }
                    Text(viewModel.modelSourceNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let alternativeTitle = viewModel.alternativeModelTitle,
                       let alternativeNote = viewModel.alternativeModelNote {
                        // 2026-09-29: the other model, one click away, with
                        // what choosing it costs said up front.
                        VStack(alignment: .leading, spacing: 4) {
                            Text(alternativeNote)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(alternativeTitle) {
                                viewModel.useAlternativeModel()
                            }
                            .controlSize(.small)
                        }
                    }
                    Text("Choose a different model in Settings › Speech Models.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let estimate = viewModel.modelSpaceEstimateDescription {
                        statusLine("Download size", estimate)
                        if viewModel.modelSpaceEstimate?.isSufficient == false {
                            StatusLabel(String(localized: "Not enough free space for the download. Free some space, then retry.", bundle: .module), symbol: "exclamationmark.triangle.fill", tone: .attention)
                                .font(.caption)
                                .labelStyle(.titleAndIcon)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let activity = viewModel.modelActivityDescription {
                        if let progress = viewModel.modelProgress {
                            // Determinate: the bar, the byte or file counts,
                            // and a percentage so a slow stretch between
                            // byte updates still reads as moving.
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView(value: progress)
                                    .progressViewStyle(.linear)
                                HStack(alignment: .firstTextBaseline) {
                                    Text(activity)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    if let percent = viewModel.modelProgressPercentDescription {
                                        Text(percent)
                                            .font(.callout.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Model progress")
                            .accessibilityValue("\(Int(progress * 100)) percent. \(activity)")
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(activity)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(activity)
                        }
                    }

                    if let notice = viewModel.modelNotice {
                        StatusLabel(notice, symbol: "hourglass", tone: .neutral)
                            .font(.callout)
                            .labelStyle(.titleAndIcon)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let failure = viewModel.modelFailureMessage {
                        StatusLabel(failure, symbol: "exclamationmark.triangle.fill", tone: .attention)
                            .font(.callout)
                            .labelStyle(.titleAndIcon)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Model problem: \(failure)")
                    }

                    // FR-ONB-002: Download, Choose Existing, and Skip are all
                    // visible. The primary sits in the card, next to the
                    // progress it starts, as well as in the action bar.
                    // Three buttons on one line when there is room; they
                    // stack at the window's minimum width.
                    ViewThatFits(in: .horizontal) {
                        HStack { modelActionButtons }
                        VStack(alignment: .leading, spacing: 8) { modelActionButtons }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Microphone

    @ViewBuilder
    private var modelActionButtons: some View {
        if let action = viewModel.modelPrimaryAction,
           let title = viewModel.modelPrimaryActionTitle {
            // W3: bordered, not prominent — the action bar's primary is the
            // one prominent button per screen.
            Button(title) {
                viewModel.handleModelAction(action)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.modelIsBusy)
            .accessibilityHint(action == .download
                ? "Downloads the model from the repository named in the bundled manifest and verifies it. The download keeps going on later screens."
                : "Tries the download again from where it stopped.")
        }

        if viewModel.modelCanCancel {
            Button("Cancel Download") {
                viewModel.handleModelAction(.cancel)
            }
            .accessibilityHint("Stops the download. Downloaded bytes are kept so it can be resumed.")
        }

        Button("Choose Existing…") {
            viewModel.handleModelAction(.chooseExisting)
        }
        .disabled(viewModel.modelIsBusy)
        .accessibilityHint("Pick a folder that already contains a verified KVoice model package.")
    }

    private var microphoneStage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("The microphone is used only while you dictate. Audio is transcribed on this Mac, and the short level test below is not saved.")
                .fixedSize(horizontal: false, vertical: true)

            OnboardingPermissionCard(
                card: viewModel.microphonePermissionCard,
                deepLinkFailed: viewModel.systemSettingsOpenFailed == .microphone,
                note: microphoneNote
            )

            if microphoneIsDenied {
                Button("Check Again") {
                    Task { @MainActor in
                        await viewModel.refreshMicrophoneStatus()
                    }
                }
                .accessibilityHint("Reads the permission again after you change it in System Settings. It is also re-read automatically while this screen is open.")
            }

            if viewModel.microphoneAuthorization == .granted {
                GroupBox("Level test") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Press Run Level Test and speak for a moment to confirm the right input is selected.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let device = viewModel.microphoneTest.inputDeviceName {
                            statusLine("Input device", device)
                        }
                        ProgressView(value: viewModel.microphoneTest.meterValue)
                            .tint(.accentColor)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: viewModel.microphoneTest.meterValue)
                            .accessibilityLabel("Microphone level")
                            .accessibilityValue(viewModel.microphoneTest.meterAccessibilityValue)
                        HStack(spacing: 8) {
                            if viewModel.microphoneTest.isRunning {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityHidden(true)
                            } else if case .completed = viewModel.microphoneTestState {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityHidden(true)
                            } else if case .failed = viewModel.microphoneTestState {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .accessibilityHidden(true)
                            }
                            Text(viewModel.microphoneTest.statusDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var microphoneIsDenied: Bool {
        viewModel.microphoneAuthorization == .denied || viewModel.microphoneAuthorization == .restricted
    }

    private var microphoneNote: String? {
        if viewModel.isRequestingMicrophonePermission {
            return String(localized: "macOS is asking for permission. Choose Allow in the dialog.", bundle: .module)
        }
        return nil
    }

    // MARK: Accessibility

    private var accessibilityStage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Group {
                if viewModel.edition == .appStore {
                    Text("KVoice types the finished text into the app you are dictating into. macOS asks for this under Accessibility; this edition only sends keystrokes to that app and never reads its text.")
                } else {
                    Text("Accessibility is how KVoice writes the finished text at the cursor in another app. It is used only at that moment and does not read document content during setup.")
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            OnboardingPermissionCard(
                card: viewModel.accessibilityPermissionCard,
                deepLinkFailed: viewModel.systemSettingsOpenFailed == .accessibility,
                note: accessibilityNote,
                awaitingGrant: viewModel.isAwaitingAccessibilityGrant
            )

            if viewModel.accessibilityStatus != .granted {
                Button("Check Again") {
                    Task { @MainActor in
                        await viewModel.refreshAccessibilityStatus()
                    }
                }
                .accessibilityHint("Reads the trust state again. It is also re-read every second while this screen is open.")
            }
        }
    }

    private var accessibilityNote: String? {
        if viewModel.isRequestingAccessibilityPermission {
            return String(localized: "macOS is showing the Accessibility prompt.", bundle: .module)
        }
        if viewModel.isAwaitingAccessibilityGrant {
            return String(localized: "Waiting for you to enable KVoice in System Settings. This screen updates by itself once it is on.", bundle: .module)
        }
        return nil
    }

    // MARK: Shortcut

    private var shortcutStage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose how the shortcut controls recording, then record the keys you want. \(GeneralSettingsViewModel.displayName(for: GeneralSettingsViewModel.recommendedShortcut)) is recommended but is not claimed until you confirm it.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Recording mode") {
                Picker(
                    "Recording interaction",
                    selection: Binding(
                        get: { viewModel.recordingInteraction },
                        set: { viewModel.setRecordingInteraction($0) }
                    )
                ) {
                    Text("Push-to-Talk — hold to record, release to stop").tag(RecordingInteraction.pushToTalk)
                    Text("Toggle — press to start, press again to stop").tag(RecordingInteraction.toggle)
                    // P-W3: the same three modes as Settings › Shortcuts.
                    Text("Hybrid — tap to start and stop, or hold to talk").tag(RecordingInteraction.hybrid)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Recording interaction")
                .accessibilityHint("Push-to-talk is selected by default.")
            }

            GroupBox("Shortcut") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(shortcutDescription)
                            .font(.headline)
                        Spacer()
                        readinessBadge(viewModel.readiness.shortcut)
                    }
                    HStack {
                        Button("Record Shortcut…") {
                            viewModel.requestShortcutRecording()
                        }
                        .accessibilityHint("Open the recorder and press the key combination you want.")

                        // Recording used to be the only path, and it silently
                        // installed this value instead of recording.
                        Button("Use Recommended Shortcut") {
                            viewModel.useRecommendedShortcut()
                        }
                        .accessibilityHint(
                            "Use \(GeneralSettingsViewModel.displayName(for: GeneralSettingsViewModel.recommendedShortcut))."
                        )
                    }
                    if let shortcutError = viewModel.shortcutError {
                        StatusLabel(shortcutError, symbol: "exclamationmark.triangle.fill", tone: .attention)
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if viewModel.hotkeyTestIsAvailable {
                hotkeyTestSection
            }
        }
    }

    // MARK: Hotkey test (Try It)

    /// Later waves: onboarding hotkey test; its own step until the 2026-09-16
    /// six-step wizard (P-W1) folded it under the recorder. A live indicator
    /// lit by the real global shortcut — never a button in this window — so
    /// the check proves the shortcut works while kvoice is not focused, the
    /// same way it will every day. Shown only once a shortcut is registered
    /// (`hotkeyTestIsAvailable`); the hook task in `body` follows the same
    /// flag.
    private var hotkeyTestSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Try it") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Press your shortcut now, anywhere — this window does not need to be focused.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Circle()
                            .fill(viewModel.hotkeyTestSnapshot.isDown || viewModel.hotkeyTestSnapshot.isDone ? Color.green : Color.secondary.opacity(0.3))
                            .frame(width: 14, height: 14)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: viewModel.hotkeyTestSnapshot.isDown)
                        Text(viewModel.hotkeyTestStatusDescription)
                            .font(.headline)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Shortcut test")
                    .accessibilityValue(viewModel.hotkeyTestStatusDescription)

                    if viewModel.hotkeyTestSnapshot.isDone {
                        StatusLabel(String(localized: "Detected", bundle: .module), symbol: "checkmark.circle.fill", tone: .positive)
                            .labelStyle(.titleAndIcon)
                            .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            DisclosureGroup("Shortcut didn't register?") {
                VStack(alignment: .leading, spacing: 10) {
                    Group {
                        if viewModel.edition == .appStore {
                            Text("Some apps and system shortcuts can claim a key combination first. Try a different shortcut. The App Store edition needs a key combination; a lone modifier key cannot be detected.")
                        } else {
                            Text("Some apps and system shortcuts can claim a key combination first. Try a different shortcut, or make sure KVoice has Accessibility if you picked a lone modifier key.")
                        }
                    }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // ADR-026: the App Store edition's pointer to the full
                    // edition, where a lone modifier key works.
                    FullEditionLink(url: viewModel.fullEditionLink)
                        .font(.callout)
                    HStack {
                        Button("Choose Another Shortcut…") {
                            viewModel.requestShortcutRecording()
                        }
                        if viewModel.shortcut?.isModifierOnly == true, viewModel.edition == .developerID {
                            Button("Open Accessibility Settings") {
                                viewModel.openSystemSettings(for: .accessibility)
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }
            .accessibilityHint("A lone modifier key such as Right Option needs Accessibility permission to be detected.")
        }
    }

    // MARK: Ready

    /// Readiness list, the first dictation test, the two optional links,
    /// then what used to be the Complete page (summary, menu-bar pointer,
    /// what Finish does). Finish is the action bar's primary.
    private var readyStage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Everything the dictation test needs is listed here. Fix… opens the step for anything that is not ready.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(OnboardingReadinessItem.allCases) { item in
                        HStack {
                            Label {
                                Text(item.title)
                            } icon: {
                                Image(systemName: readinessSymbol(for: viewModel.readiness[item]))
                                    .foregroundStyle(readinessTone(for: viewModel.readiness[item]).symbolColor)
                            }
                            Spacer()
                            Text(viewModel.readiness[item].displayName)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("\(item.title) status")
                            if !viewModel.readiness[item].isReady {
                                Button("Fix…") {
                                    viewModel.goToStep(for: item)
                                }
                                .controlSize(.small)
                                .accessibilityLabel("Go to the \(item.title) step")
                            }
                        }
                    }
                    if let activity = viewModel.modelActivityDescription {
                        // C.2 step 8: model progress stays visible and cancellable.
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let progress = viewModel.modelProgress {
                                ProgressView(value: progress)
                                    .frame(maxWidth: 160)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(activity)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if case .downloading = viewModel.modelState {
                                Button("Cancel") {
                                    viewModel.handleModelAction(.cancel)
                                }
                                .controlSize(.small)
                                .accessibilityLabel("Cancel the model download")
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            dictationTestSection

            // The links before the summary: at the default window size the
            // summary is what scrolls below the fold, not the two offers.
            nextStepsSection

            summarySection

            Text("Finish closes this window. Setup will not open again on launch; reopen it any time from the menu or General. Anything you skipped stays visible as Not Ready in the menu and can be finished in Speech Models or Permissions.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var dictationTestSection: some View {
        GroupBox("First dictation test") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Uses the real recorder and transcription. The text appears below and is not inserted anywhere.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    if viewModel.dictationTestIsRecording {
                        // W3: bordered with a red tint — the bar's Continue
                        // is the only prominent button on this screen.
                        Button("Stop Recording") {
                            viewModel.stopDictationTest()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .accessibilityHint("Stop the test recording and transcribe it.")
                    } else {
                        Button(viewModel.dictationTestResult == nil ? "Run a Short Dictation Test" : "Try Again") {
                            viewModel.requestDictationTest()
                        }
                        .disabled(!viewModel.canRunDictationTest)
                        .accessibilityHint("Enabled when Model, Microphone, and Shortcut are Ready.")
                    }
                }

                if let blockedBy = viewModel.dictationTestBlockedBy, !viewModel.dictationTestIsRecording {
                    // The readiness list above already carries the Fix…
                    // link for this item; here we only say why the button
                    // is off.
                    Text("Waiting on \(blockedBy.title). Use Fix… above to set it up.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if viewModel.dictationTestIsRecording {
                    HStack(spacing: 8) {
                        if reduceMotion {
                            Image(systemName: "record.circle")
                                .foregroundStyle(.red)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Recording. Press Stop Recording, use your shortcut, or press Escape to cancel.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                } else if let result = viewModel.dictationTestResult {
                    switch result {
                    case .transcript(let text):
                        Text("Transcript")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollView {
                            Text(text.isEmpty ? String(localized: "(No speech was recognized.)", bundle: .module) : text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(minHeight: 60, maxHeight: 140)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
                        .accessibilityLabel("Dictation test transcript")
                        .accessibilityValue(text)
                    case .failed(let message, _):
                        VStack(alignment: .leading, spacing: 6) {
                            StatusLabel(message, symbol: "exclamationmark.triangle.fill", tone: .attention)
                                .labelStyle(.titleAndIcon)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("Dictation test failed: \(message)")
                            if let fix = viewModel.dictationTestFixStep {
                                Button("Go to \(fix.title)") {
                                    viewModel.goToStep(for: fix)
                                }
                                .controlSize(.small)
                                .accessibilityLabel("Go to the \(fix.title) step to fix this")
                            }
                        }
                    }
                } else if viewModel.dictationTestRequested {
                    Text("Starting the test…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Summary and links (the former Complete page, merged into Ready)

    /// Shortcut, mode, AI and the privacy boundary — the facts the Complete
    /// page used to summarise, in one box.
    /// Where transcript text goes with the current AI setup: nowhere while
    /// AI is off or the on-device model is active (ADR-024), to Apple's
    /// Private Cloud Compute for that engine (ADR-027), to the endpoint
    /// otherwise. Audio never leaves in any case.
    private var privacyBoundary: String {
        guard let ai = aiSettingsViewModel, ai.mode != .off else {
            return String(localized: "Everything stays on this Mac.", bundle: .module)
        }
        switch ai.provider {
        case .appleIntelligence:
            return String(localized: "Everything stays on this Mac.", bundle: .module)
        case .privateCloudCompute:
            return String(localized: "Transcript text goes to Apple's Private Cloud Compute; audio never does.", bundle: .module)
        case .openAICompatible:
            return String(localized: "Transcript text goes to your endpoint; audio never does.", bundle: .module)
        }
    }

    private var summarySection: some View {
        GroupBox("Your setup") {
            VStack(alignment: .leading, spacing: 10) {
                statusLine("Shortcut", shortcutDescription)
                statusLine("Recording mode", viewModel.recordingInteractionSummary)
                statusLine("AI", aiSummary)
                statusLine("Privacy boundary", privacyBoundary)
                privacyRow("KVoice lives in the menu bar. Click its icon for status, recording, modes, history, and Settings.", symbol: "menubar.arrow.up.rectangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The two optional follow-ups (P-W1): the Quick Tour and AI Actions
    /// were wizard stages until 2026-09-16 and are now links. Neither blocks
    /// Finish; both stay reachable later from Help › Quick Tour and Settings
    /// › AI Actions. Plain buttons, not `Link`s: they open windows, not
    /// URLs, and the bar's Finish stays the one prominent button (N19).
    private var nextStepsSection: some View {
        GroupBox("Optional") {
            VStack(alignment: .leading, spacing: 10) {
                nextStepRow(
                    "Take the Quick Tour",
                    detail: "Three short pages: where the text goes, the menu bar, and how to customize KVoice. Also in Help.",
                    symbol: "sparkles",
                    accessibilityHint: "Opens the quick tour in its own window. Setup stays open."
                ) {
                    viewModel.openQuickTour()
                }
                nextStepRow(
                    "Set up AI Actions",
                    detail: "Polish and translation are off and stay off unless you turn them on. Only transcript text is ever sent, and only to the endpoint you configure.",
                    symbol: "text.bubble",
                    accessibilityHint: "Opens the AI Actions page in the main window. Setup stays open and nothing is sent."
                ) {
                    viewModel.openAIActionsSetup()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func nextStepRow(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        symbol: String,
        accessibilityHint: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Button(title, action: action)
                    .buttonStyle(.link)
                    .accessibilityHint(accessibilityHint)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var aiSummary: String {
        guard let aiSettingsViewModel else { return String(localized: "Off", bundle: .module) }
        switch aiSettingsViewModel.mode {
        case .off: return String(localized: "Off", bundle: .module)
        case .polish: return String(localized: "Polish", bundle: .module)
        case .translate: return String(localized: "Translate to \(aiSettingsViewModel.translationLanguageName)", bundle: .module)
        }
    }

    // MARK: Helpers

    private var shortcutDescription: String {
        guard let shortcut = viewModel.shortcut else { return String(localized: "No shortcut recorded", bundle: .module) }
        return GeneralSettingsViewModel.displayName(for: shortcut)
    }

    @ViewBuilder
    private func privacyRow(_ text: String, symbol: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
    }

    @ViewBuilder
    private func statusLine(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private func readinessBadge(_ status: OnboardingReadinessStatus) -> some View {
        StatusLabel(status.displayName, symbol: readinessSymbol(for: status), tone: readinessTone(for: status))
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.medium))
            .accessibilityLabel("Status: \(status.displayName)")
    }

    private func readinessSymbol(for status: OnboardingReadinessStatus) -> String {
        switch status {
        case .ready: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        case .deferred, .notReady: return "circle.dashed"
        }
    }

    private func readinessTone(for status: OnboardingReadinessStatus) -> StatusTone {
        switch status {
        case .ready: return .positive
        case .blocked: return .attention
        case .deferred, .notReady: return .neutral
        }
    }
}

/// The D.9 permission card as onboarding shows it: state badge, why kvoice
/// needs it, the written System Settings path when the deep link is the
/// remedy, and when it was last read. It carries no button — the action bar
/// at the bottom of the screen is the one relevant action — which is why
/// this is not `PermissionCardView` from the Dictation settings tab.
@MainActor
private struct OnboardingPermissionCard: View {
    let card: PermissionCard
    var deepLinkFailed = false
    /// An in-flight or waiting message shown under the rationale.
    var note: String?
    /// Accessibility has no "deny" — the app is simply not in the list yet.
    /// Right after the prompt the trust read still says not granted, so the
    /// badge says "Not Enabled" rather than "Denied" until the poll sees it.
    var awaitingGrant = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presented: PermissionCardState {
        card.presentedState()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(card.kind.title, systemImage: card.kind.symbolName)
                        .font(.headline)
                    Spacer()
                    StatusLabel(badgeTitle, symbol: symbolName, tone: tone)
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.medium))
                        .accessibilityLabel("\(card.kind.title) status")
                        .accessibilityValue(badgeTitle)
                }

                Text(card.kind.rationale)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let note {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "clock")
                            .accessibilityHidden(true)
                        Text(note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }

                if card.showsSystemSettingsPath() || deepLinkFailed {
                    Text(deepLinkFailed
                        ? "System Settings could not be opened automatically. Go to \(card.kind.systemSettingsPath) and enable KVoice."
                        : "If the button does not open the right pane: \(card.kind.systemSettingsPath).")
                        .font(.caption)
                        .foregroundStyle(deepLinkFailed ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Written path: \(card.kind.systemSettingsPath)")
                }

                Text(lastCheckedDescription)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Last checked: \(lastCheckedDescription)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: presented)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(card.kind.title) permission, \(badgeTitle)")
    }

    private var isWaiting: Bool {
        awaitingGrant && presented == .denied
    }

    private var badgeTitle: String {
        isWaiting ? String(localized: "Not Enabled", bundle: .module) : presented.displayName
    }

    private var symbolName: String {
        if isWaiting { return "clock" }
        switch presented {
        case .granted: return "checkmark.circle.fill"
        case .denied, .restricted: return "xmark.octagon.fill"
        case .notRequested: return "circle.dashed"
        case .unknown: return "questionmark.circle"
        }
    }

    private var tone: StatusTone {
        if isWaiting { return .neutral }
        switch presented {
        case .granted: return .positive
        case .denied, .restricted: return .attention
        case .notRequested, .unknown: return .neutral
        }
    }

    private var lastCheckedDescription: String {
        guard let lastChecked = card.lastChecked else { return String(localized: "Not checked yet", bundle: .module) }
        return String(localized: "Checked \(lastChecked.formatted(date: .omitted, time: .standard))", bundle: .module)
    }
}
