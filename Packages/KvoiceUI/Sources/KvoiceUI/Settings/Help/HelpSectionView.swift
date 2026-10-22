import SwiftUI
import KvoiceDomain

/// The Help section: guides and links, Feedback › Compose, Acknowledgments,
/// and — since P-M14 (2026-09-16) — the About group (Version, Runtime,
/// Model manifest, Bundle, Open-Source Licenses…), moved here from Data &
/// Privacy because it is facts about the app rather than about privacy. The
/// reset and restart tools moved to General on 2026-09-13 (they change the
/// app; Help only explains it), and the footer says so. The status menu's
/// "About kvoice" item is unchanged: it still opens the standard About
/// panel, not this page.
@MainActor
public struct HelpSectionView: View {
    @Bindable private var viewModel: HelpViewModel
    private let privacy: PrivacyAboutViewModel

    @State private var isShowingLicenses = false

    public init(viewModel: HelpViewModel = .init(), privacy: PrivacyAboutViewModel = .init()) {
        self.viewModel = viewModel
        self.privacy = privacy
    }

    public var body: some View {
        KVCardPage {
            guidesSection
            feedbackSection
            acknowledgmentsSection
            AboutSections(viewModel: privacy) {
                isShowingLicenses = true
            }
        }
        .sheet(isPresented: $isShowingLicenses) {
            LicensesSheet(viewModel: privacy, isPresented: $isShowingLicenses)
        }
    }

    // MARK: Guides

    private var guidesSection: some View {
        KVCardSection {
            linkRow("User Guide", detail: "Setup, dictation, and every setting, in the project documentation.", symbol: "book") {
                viewModel.openUserGuide()
            }
            linkRow("Set up AI and an API key", detail: "How to point KVoice at an OpenAI-compatible endpoint and store its key.", symbol: "sparkles") {
                viewModel.openSetupAI()
            }
            linkRow("Official Website", detail: "The KVoice project page.", symbol: "globe") {
                viewModel.openWebsite()
            }
            LabeledContent {
                Button("Show") {
                    viewModel.showTutorial()
                }
                .fixedSize()
                .accessibilityHint("Reopens the three-page quick tour from setup, without redoing the rest of setup.")
            } label: {
                Text("Quick Tour")
            }
            if let failed = viewModel.lastOpenFailed {
                StatusLabel(
                    String(localized: "The link could not be opened. Copy it instead: \(failed.absoluteString)", bundle: .module),
                    symbol: "exclamationmark.triangle.fill",
                    tone: .attention
                )
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Guides")
        }
    }

    private func linkRow(_ title: String, detail: String, symbol: String, action: @escaping @MainActor () -> Void) -> some View {
        // LabeledContent: the description wraps in the label column and the
        // button keeps its size, so nothing clips in a narrow pane.
        LabeledContent {
            Button("Open") {
                action()
            }
            .fixedSize()
            .accessibilityLabel("Open \(title)")
            .accessibilityHint(Text(detail))
        } label: {
            Text(title)
        }
    }

    // MARK: Feedback

    private var feedbackSection: some View {
        KVCardSection {
            Toggle(isOn: $viewModel.includeDiagnosticsInFeedback) {
                Text("Include diagnostics")
                Text("Counts and timings only — never transcript text or audio")
            }
                .accessibilityHint("Appends the same redacted report as Copy Diagnostics: versions, permission and model status, and settings flags. Never a transcript, key, or endpoint path.")

            LabeledContent {
                Button("Compose…") {
                    viewModel.composeFeedback()
                }
                .fixedSize()
                .accessibilityLabel("Compose feedback email")
                .accessibilityHint("Opens your mail app with a new message addressed to the KVoice maintainers.")
            } label: {
                Text("Send feedback")
                Text(HelpLinks.feedbackAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Feedback")
        }
    }

    // MARK: Acknowledgments

    private var acknowledgmentsSection: some View {
        KVCardSection {
            // UI v2 fidelity F3 (Window.dc `help` › About): version, runtime
            // and the licences in one card.
            LabeledContent {
                Text(verbatim: "\(privacy.appVersion) (\(privacy.buildNumber))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.kv.text2)
                    .textSelection(.enabled)
            } label: {
                Text("Version")
            }
            LabeledContent {
                Text(verbatim: PrivacyAboutViewModel.runtimeDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kv.text2)
            } label: {
                Text("Runtime")
            }
            LabeledContent {
                Button("Acknowledgments…") {
                    isShowingLicenses = true
                }
                .accessibilityHint("Shows the open-source licenses.")
            } label: {
                Text("Licenses")
            }
        } header: {
            Text("About")
        }
    }
}
