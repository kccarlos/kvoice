import SwiftUI

/// One tutorial page's content: title, illustration, and body paragraph.
/// Pure renderer of `page` — no navigation, no view-model dependency — so the
/// wizard's embedded `.tutorial` stage and the standalone `TutorialView`
/// below can both use it without owning two copies of the copy or artwork.
@MainActor
public struct TutorialPageContentView: View {
    public let page: TutorialPage
    /// "Open kvoice" on the last page. Nil renders the pointer list as plain
    /// text (tests, previews).
    public var openMainWindow: (@MainActor (MainWindowSection) -> Void)?

    public init(page: TutorialPage, openMainWindow: (@MainActor (MainWindowSection) -> Void)? = nil) {
        self.page = page
        self.openMainWindow = openMainWindow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(page.title, systemImage: page.symbolName)
                .font(.title3.weight(.semibold))

            illustration
                .frame(maxWidth: .infinity)
                .frame(height: 120)

            Text(page.body)
                .fixedSize(horizontal: false, vertical: true)

            if page == .makeItYours {
                pointerList
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Illustration

    /// SF Symbols and shapes only — no image assets, per the tutorial's
    /// design constraint.
    @ViewBuilder
    private var illustration: some View {
        switch page {
        case .textDestination:
            textDestinationIllustration
        case .menuBar:
            menuBarIllustration
        case .makeItYours:
            makeItYoursIllustration
        }
    }

    /// A mock terminal window being typed into, with the clipboard fallback
    /// shown beside it.
    private var textDestinationIllustration: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().frame(width: 8, height: 8)
                    }
                    Spacer()
                    Image(systemName: "terminal")
                }
                .foregroundStyle(.secondary)
                HStack(spacing: 2) {
                    Text(verbatim: "KVoice")
                        .font(.callout.monospaced())
                    Rectangle()
                        .frame(width: 7, height: 15)
                        .opacity(0.7)
                }
            }
            .padding(10)
            .frame(width: 150, height: 90)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))

            VStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Fallback", bundle: .module)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityHidden(true)
    }

    /// A stylized menu-bar strip with the four things the status menu offers.
    private var menuBarIllustration: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "waveform")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 220)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))

            HStack(spacing: 18) {
                menuBarGlyph("record.circle", label: String(localized: "Start/Stop", bundle: .module))
                menuBarGlyph("xmark.circle", label: String(localized: "Cancel", bundle: .module))
                menuBarGlyph("sparkles", label: String(localized: "AI Actions", bundle: .module))
                menuBarGlyph("clock.arrow.circlepath", label: String(localized: "History", bundle: .module))
            }
        }
        .accessibilityHidden(true)
    }

    private func menuBarGlyph(_ symbol: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title3)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var makeItYoursIllustration: some View {
        HStack(spacing: 22) {
            ForEach(TutorialCustomizePointer.all) { pointer in
                Image(systemName: pointer.symbolName)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }

    private var pointerList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(TutorialCustomizePointer.all) { pointer in
                HStack {
                    Label(pointer.title, systemImage: pointer.symbolName)
                    Spacer()
                    if let openMainWindow {
                        Button {
                            openMainWindow(pointer.id)
                        } label: {
                            Text("Open KVoice", bundle: .module)
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Open KVoice \(pointer.title)")
                    }
                }
            }
        }
    }
}

/// The standalone tutorial window content (Help › Show Tutorial): the same
/// pages as the wizard's `.tutorial` stage, with their own header, paging,
/// and Back/Next/Skip Tutorial bar since there is no wizard chrome around
/// them here. `OnboardingWindowController`'s sibling, `TutorialWindowController`
/// (`Apps/KvoiceApp`), hosts this.
@MainActor
public struct TutorialView: View {
    @Bindable private var viewModel: TutorialViewModel

    public init(viewModel: TutorialViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                TutorialPageContentView(page: viewModel.page, openMainWindow: viewModel.openMainWindow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            actionBar
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Quick Tour", bundle: .module)
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(viewModel.progressLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(TutorialPage.allCases) { page in
                    Capsule(style: .continuous)
                        .fill(page.ordinal <= viewModel.page.ordinal ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: 4)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                backButton
                Spacer()
                skipButton
                nextButton
            }
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 12) {
                    backButton
                    Spacer()
                    skipButton
                    nextButton
                }
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.bar)
    }

    @ViewBuilder
    private var backButton: some View {
        if !viewModel.isFirstPage {
            Button {
                viewModel.back()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
        }
    }

    private var skipButton: some View {
        Button {
            viewModel.skip()
        } label: {
            Text("Skip Tutorial", bundle: .module)
        }
        .buttonStyle(.borderless)
    }

    private var nextButton: some View {
        Button {
            viewModel.next()
        } label: {
            Text(viewModel.isLastPage ? String(localized: "Done", bundle: .module) : String(localized: "Next", bundle: .module))
                .frame(minWidth: 64)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }
}
