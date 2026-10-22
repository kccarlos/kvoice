import AppKit
import KvoiceDomain
import SwiftUI

// The setup wizard's Ready screen: the checklist, the dictation test, the
// summary and the next-step links (split from `OnboardingView.swift`, Q2b).
extension OnboardingView {
    // MARK: Ready

    /// The checklist is the status: one row per prerequisite with what is
    /// set up or why it is open, Fix… on anything open (progress instead
    /// while the model is still coming), then the first dictation test, the
    /// two optional links, and the setup summary. Finish is the bar's one
    /// blue button.
    var readyStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            checklist

            dictationTestSection

            nextStepsSection

            // Wizard.dc draws the summary only while the test can run and
            // is not recording; the blocked state gets the finish note.
            if !viewModel.dictationTestIsRecording, viewModel.dictationTestWaitingText == nil {
                summarySection
            }

            if viewModel.readinessNeedsFinishNote {
                noteText(String(localized: "You can still finish. Anything open stays visible in the menu bar and in Permissions.", bundle: .module))
            }
        }
    }

    var checklist: some View {
        VStack(spacing: 0) {
            ForEach(Array(OnboardingReadinessItem.allCases.enumerated()), id: \.element) { index, item in
                if index > 0 {
                    Rectangle().fill(Color.kv.line2).frame(height: 1)
                }
                checklistRow(item, index: index)
            }
        }
        .background(Color.kv.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.kv.line, lineWidth: 1)
        }
    }

    func checklistRow(_ item: OnboardingReadinessItem, index: Int) -> some View {
        let status = viewModel.readiness[item]
        let busy = item == .model && viewModel.modelIsInProgress && status != .deferred
        let detail = viewModel.checklistDetail(for: item)
        return HStack(spacing: 12) {
            ChecklistIcon(status: status, busy: busy, index: index, shown: readyChecksShown, reduceMotion: reduceMotion)
            checklistText(item, status: status, busy: busy, detail: detail)
            Spacer(minLength: 8)
            checklistAction(item, busy: busy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    func checklistText(_ item: OnboardingReadinessItem, status: OnboardingReadinessStatus, busy: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.kv.text)
            Text(verbatim: detail)
                .font(.system(size: 12))
                .foregroundStyle(status == .blocked ? Color.kv.warnInk : Color.kv.text2)
                .fixedSize(horizontal: false, vertical: true)
            if busy, let progress = viewModel.modelProgress {
                Capsule().fill(Color.kv.fill)
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule().fill(Color.kv.cursor).frame(width: proxy.size.width * progress)
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: progress)
                        }
                    }
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title): \(status.displayName). \(detail)")
    }

    @ViewBuilder
    func checklistAction(_ item: OnboardingReadinessItem, busy: Bool) -> some View {
        if busy, case .downloading = viewModel.modelState {
            Button("Cancel") {
                viewModel.handleModelAction(.cancel)
            }
            .buttonStyle(WizardButtonStyle(size: .fix))
            .accessibilityLabel("Cancel the model download")
        } else if viewModel.checklistOffersFix(for: item) {
            Button("Fix…") {
                viewModel.goToStep(for: item)
            }
            .buttonStyle(WizardButtonStyle(size: .fix))
            .accessibilityLabel("Go to the \(item.title) step")
        }
    }

    @ViewBuilder
    var dictationTestSection: some View {
        let recording = viewModel.dictationTestIsRecording
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("First dictation test")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.kv.text)
                    Group {
                        if recording {
                            Text("Recording. Press Stop, use your shortcut, or Escape to cancel.")
                        } else if let waiting = viewModel.dictationTestWaitingText {
                            // The checklist above carries the Fix… for these
                            // items; here we only say why the button is off.
                            Text(verbatim: waiting)
                        } else if viewModel.dictationTestRequested, viewModel.dictationTestResult == nil {
                            Text("Starting the test…")
                        } else if case .transcript = viewModel.dictationTestResult {
                            Text(verbatim: viewModel.dictationTestResultCaption)
                        } else {
                            Text("Uses the real recorder. The text appears here and is not inserted anywhere.")
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kv.text2)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if recording {
                    // Outlined in err: the bar's Finish is the one blue
                    // button on this screen.
                    Button("Stop Recording") {
                        viewModel.stopDictationTest()
                    }
                    .buttonStyle(WizardButtonStyle(kind: .danger))
                    .accessibilityHint("Stop the test recording and transcribe it.")
                } else {
                    Button(viewModel.dictationTestResult == nil ? "Run a Short Dictation Test" : "Try Again") {
                        viewModel.requestDictationTest()
                    }
                    .buttonStyle(WizardButtonStyle(kind: viewModel.canRunDictationTest ? .standard : .muted))
                    .disabled(!viewModel.canRunDictationTest)
                    .accessibilityHint("Enabled when Model, Microphone, and Shortcut are Ready.")
                }
            }

            if recording {
                // Motion § 4·6: the recorder's own level, and the clock.
                HStack(spacing: 0) {
                    DictationTestMeter(level: viewModel.dictationTestLevel)
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(verbatim: viewModel.dictationTestElapsedDescription())
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.kv.voiceInk)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording")
            }

            if !recording, let result = viewModel.dictationTestResult {
                switch result {
                case .transcript(let text):
                    ScrollView {
                        Text(text.isEmpty ? String(localized: "(No speech was recognized.)", bundle: .module) : text)
                            .font(.system(size: 13))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                    .frame(minHeight: 40, maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color.kv.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("Dictation test transcript")
                    .accessibilityValue(text)
                case .failed(let message, _):
                    VStack(alignment: .leading, spacing: 8) {
                        CardAlert(text: message, tone: .warn)
                            .accessibilityLabel("Dictation test failed: \(message)")
                        if let fix = viewModel.dictationTestFixStep {
                            Button("Go to \(fix.title)") {
                                viewModel.goToStep(for: fix)
                            }
                            .buttonStyle(WizardButtonStyle(size: .fix))
                            .accessibilityLabel("Go to the \(fix.title) step to fix this")
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(recording ? Color.kv.voiceSoft : Color.kv.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.kv.voice, lineWidth: 1)
                .opacity(recording ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.2), value: recording)
    }

    // MARK: Summary and links (the former Complete page, merged into Ready)

    /// Where transcript text goes with the current AI setup: nowhere while
    /// AI is off or the on-device model is active (ADR-024), to Apple's
    /// Private Cloud Compute for that engine (ADR-027), to the endpoint
    /// otherwise. Audio never leaves in any case.
    var privacyBoundary: String {
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

    var staysOnThisMac: Bool {
        guard let ai = aiSettingsViewModel, ai.mode != .off else { return true }
        return ai.provider == .appleIntelligence
    }

    /// Wizard.dc's summary: "Shortcut ⌃⇧Space (hold)", "AI Clean Up" and
    /// the privacy boundary on one wrapping row, then where KVoice lives
    /// from now on (kept; the design leaves it out).
    var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            KVFlowLayout(spacing: 12) {
                summaryFact("Shortcut", shortcutSummary)
                summaryFact("AI", aiSummary)
                Text(verbatim: privacyBoundary)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(staysOnThisMac ? Color.kv.okInk : Color.kv.cursorInk)
                    .accessibilityLabel("Privacy boundary: \(privacyBoundary)")
            }
            Label {
                Text("KVoice lives in the menu bar. Click its icon for status, recording, modes, history, and Settings.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "menubar.arrow.up.rectangle")
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.kv.text2)
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    func summaryFact(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .fontWeight(.semibold)
                .foregroundStyle(Color.kv.text)
            Text(verbatim: value)
                .foregroundStyle(Color.kv.text2)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    /// The two optional follow-ups (P-W1): the Quick Tour and AI Actions
    /// were wizard stages until 2026-09-16 and are now links. Neither blocks
    /// Finish; both stay reachable later from Help › Quick Tour and Settings
    /// › AI Actions. Plain tiles, not `Link`s: they open windows, not URLs,
    /// and the bar's Finish stays the one prominent button (N19).
    var nextStepsSection: some View {
        HStack(spacing: 8) {
            linkTile(
                title: String(localized: "Take the Quick Tour", bundle: .module),
                detail: String(localized: "3 short pages", bundle: .module),
                glyph: WizardGlyph.book,
                fill: .ink,
                accessibilityHint: "Opens the quick tour in its own window. Setup stays open."
            ) {
                viewModel.openQuickTour()
            }
            linkTile(
                title: aiSummaryIsOn
                    ? String(localized: "AI Actions: \(aiSummary)", bundle: .module)
                    : String(localized: "Set up AI Actions", bundle: .module),
                detail: aiLinkDetail,
                glyph: WizardGlyph.sparkle,
                fill: .cursor,
                accessibilityHint: "Opens the AI Actions page in the main window. Setup stays open and nothing is sent."
            ) {
                viewModel.openAIActionsSetup()
            }
        }
    }

    /// "via Local Ollama · Edit" with AI on (the active configuration),
    /// "Off unless you turn it on" with it off.
    var aiLinkDetail: String {
        guard aiSummaryIsOn else { return String(localized: "Off unless you turn it on", bundle: .module) }
        if let name = aiSettingsViewModel?.activeConfigurationName {
            return String(localized: "via \(name) · Edit", bundle: .module)
        }
        return String(localized: "Edit in AI Actions", bundle: .module)
    }

    func linkTile(
        title: String,
        detail: String,
        glyph: String,
        fill: KVColorToken,
        accessibilityHint: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                WizardTile(glyph: glyph, fill: fill, side: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.kv.text)
                        .lineLimit(1)
                    Text(verbatim: detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kv.text2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.kv.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(accessibilityHint)
    }

    var aiSummaryIsOn: Bool {
        guard let aiSettingsViewModel else { return false }
        return aiSettingsViewModel.mode != .off
    }

    /// "Clean Up" (the active action) with AI on in Polish; "Translate to
    /// …" in Translate; "Off".
    var aiSummary: String {
        guard let aiSettingsViewModel else { return String(localized: "Off", bundle: .module) }
        switch aiSettingsViewModel.mode {
        case .off: return String(localized: "Off", bundle: .module)
        case .polish: return aiSettingsViewModel.activeActionName ?? String(localized: "Polish", bundle: .module)
        case .translate: return String(localized: "Translate to \(aiSettingsViewModel.translationLanguageName)", bundle: .module)
        }
    }
}
