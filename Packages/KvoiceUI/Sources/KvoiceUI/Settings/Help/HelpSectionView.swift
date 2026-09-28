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
        Form {
            guidesSection
            feedbackSection
            acknowledgmentsSection
            AboutSections(viewModel: privacy) {
                isShowingLicenses = true
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingLicenses) {
            LicensesSheet(viewModel: privacy, isPresented: $isShowingLicenses)
        }
    }

    // MARK: Guides

    private var guidesSection: some View {
        Section {
            linkRow("User Guide", detail: "Setup, dictation, and every setting, in the project documentation.", symbol: "book") {
                viewModel.openUserGuide()
            }
            linkRow("Setup AI & API Key", detail: "How to point KVoice at an OpenAI-compatible endpoint and store its key.", symbol: "sparkles") {
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
                Label("Quick Tour", systemImage: "sparkles")
                Text("Where the text goes, the menu bar, and how to customize KVoice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        } footer: {
            Text("Reading material, opened in your browser. The setup guide itself, Reset Preferences, and Restart are in General.")
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
            .accessibilityHint("Opens in your browser.")
        } label: {
            Label(title, systemImage: symbol)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Feedback

    private var feedbackSection: some View {
        Section {
            Toggle("Include diagnostics", isOn: $viewModel.includeDiagnosticsInFeedback)
                .controlSize(.mini)
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
        } footer: {
            Text("A new message in your mail app, with diagnostics attached only if you tick the box. You can read and edit everything before sending.")
        }
    }

    // MARK: Acknowledgments

    private var acknowledgmentsSection: some View {
        Section {
            LabeledContent {
                Button("Acknowledgments…") {
                    isShowingLicenses = true
                }
                .fixedSize()
                .accessibilityHint("Shows the open-source licenses.")
            } label: {
                Text("Third-party notices for the libraries and the speech model linked into KVoice.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Acknowledgments")
        }
    }
}
