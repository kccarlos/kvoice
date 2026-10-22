import AppKit
import KvoiceDomain
import SwiftUI

/// SwiftUI-native first-run setup.  The view only invokes explicit view-model
/// intents; constructing or displaying it never requests an OS permission.
///
/// UI v2 wave 3 / fidelity F4 (Wizard.dc.html, Motion.dc.html): every screen
/// is built the same way — a labelled step bar that shows what was skipped
/// (`OnboardingViewModel.stepState(for:)`), one title and purpose line, one
/// hero card for the thing the step sets up, and a footer with Back on the
/// left and Skip plus exactly one blue button on the right. The buttons
/// never move between screens; only their titles and enablement change, and
/// those come from `OnboardingViewModel.actionBar`. Screen content holds the
/// step's own secondary controls and no navigation.
///
/// Motion (F4): pages slide 24 pt in from the side you go (§ 9); the step
/// bar's line fills with a spring; a permission granted while its step is
/// open turns its chip green, draws the check and glows the card once
/// (§ 10); the shortcut check sinks the keycaps and fills the orb (§ 11);
/// arriving on Ready ticks the checks in (§ 12). Reduce Motion keeps the
/// colour changes and drops movement and scale. The drawn pieces live in
/// `OnboardingPieces.swift`.
///
/// Sizing belongs to `OnboardingWindowController`; this view sets no frame.
@MainActor
public struct OnboardingView: View {
    /// Forces an accessibility setting for offscreen renders (the wizard
    /// snapshots), as `StatusPanelView` does; nil reads the environment.
    public struct AccessibilityOverrides: Equatable, Sendable {
        public var reduceMotion: Bool?

        public init(reduceMotion: Bool? = nil) {
            self.reduceMotion = reduceMotion
        }
    }

    /// Injected by the app shell, so `@Bindable` rather than `@StateObject` —
    /// see the note in `GeneralSettingsView`.
    @Bindable var viewModel: OnboardingViewModel
    /// Read for the Ready summary's AI line and privacy-boundary line only;
    /// the AI form itself lives on the AI Actions page, which Ready links
    /// to. Nil (tests, previews) reads as Off.
    let aiSettingsViewModel: AISettingsViewModel?
    /// The level test's input picker (F4). Nil shows the input's name
    /// without a menu.
    let audioInput: AudioInputViewModel?
    let overrides: AccessibilityOverrides

    @Environment(\.accessibilityReduceMotion) var environmentReduceMotion
    var reduceMotion: Bool { overrides.reduceMotion ?? environmentReduceMotion }

    /// Motion § 10: bumped when a permission is granted while its step is
    /// open; the card glows once per bump.
    @State var microphoneGlow = 0
    @State var accessibilityGlow = 0
    /// Motion § 12: false on arrival at Ready, true a moment later, so the
    /// ready checks tick in once per arrival.
    @State var readyChecksShown = true

    public init(
        viewModel: OnboardingViewModel = .init(),
        aiSettingsViewModel: AISettingsViewModel? = nil,
        audioInput: AudioInputViewModel? = nil,
        overrides: AccessibilityOverrides = AccessibilityOverrides()
    ) {
        self.viewModel = viewModel
        self.aiSettingsViewModel = aiSettingsViewModel
        self.audioInput = audioInput
        self.overrides = overrides
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepBar
            ZStack(alignment: .top) {
                page
                    .id(viewModel.stage)
                    .transition(WizardMotion.pageTransition(forward: viewModel.navigatesForward, reduceMotion: reduceMotion))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .animation(WizardMotion.page(reduceMotion: reduceMotion), value: viewModel.stage)
            actionBar
        }
        .background(Color.kv.bg)
        .tint(Color.kv.cursor)
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
        // Motion § 10: the moment of the grant, never the first read (the
        // value only changes after the view is up) and never a chip's
        // presentation flip (Checking… after 3 s).
        .onChange(of: viewModel.microphoneAuthorization) { old, new in
            if new == .granted, old != .granted, viewModel.stage == .microphone, !reduceMotion {
                microphoneGlow += 1
            }
        }
        .onChange(of: viewModel.accessibilityStatus) { old, new in
            if new == .granted, old != .granted, viewModel.stage == .accessibility, !reduceMotion {
                accessibilityGlow += 1
            }
        }
        .onChange(of: viewModel.stage) { _, stage in
            guard stage == .ready, !reduceMotion else { return }
            readyChecksShown = false
            Task { @MainActor in readyChecksShown = true }
        }
    }

    // MARK: Step bar and title

    /// Six labelled dots joined by a line: blue check for done, ink with its
    /// number for the current step, amber dashed for skipped, grey for not
    /// reached (Wizard.dc: 18 pt from the top, 20 pt dots, labels 6 pt
    /// below). The line between two dots is drawn behind them.
    var stepBar: some View {
        let stages = OnboardingStage.allCases
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.element) { index, stage in
                VStack(spacing: 6) {
                    StepDot(state: viewModel.stepState(for: stage), number: index + 1)
                    Text(verbatim: stage.stepBarTitle)
                        .font(.system(size: 11, weight: labelWeight(for: stage)))
                        .foregroundStyle(labelColor(for: stage))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: viewModel.stepAccessibilityLabel(for: stage)))
            }
        }
        .background(alignment: .topLeading) {
            GeometryReader { proxy in
                let column = proxy.size.width / CGFloat(stages.count)
                ForEach(1..<stages.count, id: \.self) { index in
                    StepConnector(lit: isConnectorLit(into: index), reduceMotion: reduceMotion)
                        .frame(width: column)
                        .offset(x: column * (CGFloat(index) - 0.5), y: 9)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .animation(.easeInOut(duration: 0.2), value: viewModel.stepStates)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: viewModel.progressLabel))
    }

    func isConnectorLit(into index: Int) -> Bool {
        let stage = OnboardingStage.allCases[index]
        return stage.ordinal <= viewModel.stage.ordinal && viewModel.stepState(for: stage) != .todo
    }

    func labelWeight(for stage: OnboardingStage) -> Font.Weight {
        switch viewModel.stepState(for: stage) {
        case .current: return .bold
        case .skipped: return .semibold
        case .done, .todo: return .regular
        }
    }

    func labelColor(for stage: OnboardingStage) -> Color {
        switch viewModel.stepState(for: stage) {
        case .current: return Color.kv.text
        case .skipped: return Color.kv.warnInk
        case .done, .todo: return Color.kv.text2
        }
    }

    /// One page: the title block and the step's content, moved together by
    /// the page transition.
    var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.stage != .welcome {
                titleBlock
            }
            content
        }
    }

    var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(viewModel.stage.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.kv.text)
                Spacer()
                if viewModel.isFinished {
                    StatusPill(text: String(localized: "Setup complete", bundle: .module), tone: .ok, filled: true)
                }
            }
            Text(viewModel.stage.purpose)
                .font(.system(size: 13))
                .foregroundStyle(Color.kv.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(viewModel.progressLabel): \(viewModel.stage.title). \(viewModel.stage.purpose)")
        // Every step's title is its heading (VoiceOver's heading rotor; the
        // Shortcut and Ready steps had none, Q2).
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Content

    var content: some View {
        ScrollView {
            stageContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    var stageContent: some View {
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

    var actionBar: some View {
        let bar = viewModel.actionBar
        // The reason the primary button is disabled sits beside the buttons
        // when there is room and above them at the window's minimum width,
        // so a long reason never squeezes Skip or the primary button.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                leadingActions(bar)
                Spacer(minLength: 8)
                primaryDisabledReason(bar)
                trailingActions(bar)
            }
            VStack(alignment: .trailing, spacing: 8) {
                primaryDisabledReason(bar)
                HStack(spacing: 10) {
                    leadingActions(bar)
                    Spacer()
                    trailingActions(bar)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(Color.kv.sidebar)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.kv.line).frame(height: 1)
        }
    }

    @ViewBuilder
    func leadingActions(_ bar: OnboardingActionBar) -> some View {
        if bar.canGoBack {
            Button {
                viewModel.goBack()
            } label: {
                Text("‹ Back")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.kv.text)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, -12)
            .accessibilityLabel("Back to the previous setup screen")
        }
        if viewModel.stage == .welcome {
            // Welcome's one secondary: where KVoice's data stays, in full.
            Button("Privacy details") {
                viewModel.openPrivacyDetails()
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Color.kv.cursorInk)
            .accessibilityHint("Opens Data & Privacy in the main window. Setup stays open.")
        }
    }

    @ViewBuilder
    func primaryDisabledReason(_ bar: OnboardingActionBar) -> some View {
        if !bar.primaryIsEnabled, let reason = bar.primaryDisabledReason {
            Text(reason)
                .font(.system(size: 12))
                .foregroundStyle(Color.kv.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    func trailingActions(_ bar: OnboardingActionBar) -> some View {
        if let skipTitle = bar.skipTitle {
            Button {
                viewModel.performSkipAction()
            } label: {
                Text(skipTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.kv.text2)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!bar.skipIsEnabled)
            .opacity(bar.skipIsEnabled ? 1 : 0.4)
            .accessibilityLabel(Text(verbatim: bar.skipAccessibilityLabel ?? skipTitle))
            // On the Shortcut page with a shortcut already registered, Skip
            // leaves only the Try It check undone; the shortcut is kept.
            .accessibilityHint(viewModel.hotkeyTestIsAvailable
                ? "Continue without trying the shortcut. The shortcut stays set up."
                : "Continue without finishing this step. It stays visible as Not Ready and can be finished later in Settings.")
        }

        // The one blue button on every screen.
        Button {
            Task { @MainActor in
                await viewModel.performPrimaryAction()
            }
        } label: {
            HStack(spacing: 7) {
                if bar.primaryIsBusy {
                    WizardSpinner(color: .white, side: 13, reduceMotion: reduceMotion)
                }
                Text(bar.primaryTitle)
            }
            .frame(minWidth: 60)
        }
        .buttonStyle(KVPrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
        // Busy stays blue with its spinner (Wizard.dc); the press is a no-op
        // then (`performPrimaryAction` checks `primaryIsEnabled`).
        .disabled(!bar.primaryIsEnabled && !bar.primaryIsBusy)
        .accessibilityLabel(bar.primaryTitle)
        .accessibilityValue(bar.primaryIsBusy ? Text("In progress") : Text(verbatim: ""))
        // The Finish paragraph the design leaves out: what Finish does.
        .help(viewModel.stage == .ready
            ? String(localized: "Finish closes this window. Setup will not open again on launch; reopen it any time from the menu or General. Anything you skipped stays visible as Not Ready in the menu and can be finished in Speech Models or Permissions.", bundle: .module)
            : String())
    }

    // MARK: Helpers

    /// "⌃⇧Space (hold)": the keys and how the mode uses them.
    var shortcutSummary: String {
        guard let shortcut = viewModel.shortcut else { return String(localized: "No shortcut recorded", bundle: .module) }
        return "\(GeneralSettingsViewModel.glyphs(for: shortcut)) (\(viewModel.recordingInteractionVerb))"
    }

    func cardLine(_ text: String, emphasized: Bool = false) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .foregroundStyle(emphasized ? Color.kv.text : Color.kv.text2)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A card's ruled-off section (Wizard.dc's alt and foot rows: a line-2
    /// rule, then 10 pt).
    func cardSection<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CardDivider()
            content()
        }
    }

    func noteText(_ text: String, size: CGFloat = 13) -> some View {
        Text(verbatim: text)
            .font(.system(size: size))
            .foregroundStyle(Color.kv.text2)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The written System Settings path beside the deep link, because the
    /// `x-apple.systempreferences:` URL is undocumented (FR-PERM-004).
    func writtenPath(_ kind: PermissionKind, failed: Bool) -> some View {
        Text(failed
            ? "System Settings could not be opened automatically. Go to \(kind.systemSettingsPath) and enable KVoice."
            : "If the button does not open the right pane: \(kind.systemSettingsPath).")
            .font(.system(size: 12))
            .foregroundStyle(failed ? Color.kv.text : Color.kv.text2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Written path: \(kind.systemSettingsPath)")
    }

    /// D.9: when the permission was last read.
    func lastChecked(_ card: PermissionCard) -> some View {
        let description = card.lastChecked.map {
            String(localized: "Checked \($0.formatted(date: .omitted, time: .standard))", bundle: .module)
        } ?? String(localized: "Not checked yet", bundle: .module)
        return Text(verbatim: description)
            .font(.system(size: 11))
            .foregroundStyle(Color.kv.text2.opacity(0.8))
            .accessibilityLabel("Last checked: \(description)")
    }
}
