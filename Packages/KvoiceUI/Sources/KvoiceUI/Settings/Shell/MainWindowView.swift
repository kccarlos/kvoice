import SwiftUI

/// The one main window: a sidebar of `MainWindowSection`s under their
/// `MainWindowSectionGroup` headings and a detail pane that shows the
/// selected section under a shared header.
///
/// The section contents are supplied by the app shell, which owns the view
/// models; this view knows only the section list. `AnyView` is deliberate:
/// ten fixed sections switched by an enum do not justify a generic view
/// per section, and nothing here is re-rendered on a per-keystroke path.
@MainActor
public struct MainWindowView: View {
    @Bindable private var model: MainWindowModel
    private let content: @MainActor (MainWindowSection) -> AnyView
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    public init(
        model: MainWindowModel,
        content: @escaping @MainActor (MainWindowSection) -> AnyView
    ) {
        self.model = model
        self.content = content
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: sidebarSelection) {
                ForEach(MainWindowSectionGroup.allCases) { group in
                    Section(group.title) {
                        ForEach(group.sections) { section in
                            Label(section.title, systemImage: section.symbolName)
                                .tag(section)
                                .accessibilityHint(section.purpose)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // Narrow enough that the detail pane keeps most of a small
            // window; the longest title ("Data & Privacy") still fits at
            // the minimum (2026-09-16: was "Shortcuts & Triggers" before
            // the design review shortened the Shortcuts and Microphone
            // titles — M4/N4).
            .navigationSplitViewColumnWidth(min: 176, ideal: 196, max: 240)
            .accessibilityLabel("Sections")
        } detail: {
            // The detail column hands a `VStack { header; Form }` the Form's
            // *ideal* height instead of the remaining space, so the stack
            // overflowed, was centred, and the header and the bottom rows
            // vanished as soon as the window was shorter than the content
            // (user report 2026-09-14; reproduced offscreen by
            // LayoutSnapshotTests). A GeometryReader is greedy, so pinning
            // the stack to its size gives the page exactly the space that is
            // left under the header, and the Form scrolls inside it.
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    if model.showTutorialBanner {
                        TutorialOfferBanner(
                            onShow: { model.showTutorial() },
                            onDismiss: { model.dismissTutorialBanner() }
                        )
                    }
                    SectionHeaderView(section: model.selection)
                    content(model.selection)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
            .navigationTitle(model.selection.title)
            // Keyed on the section so each section's `.task` modifiers start
            // fresh and the previous section's polls are cancelled.
            .id(model.selection)
        }
        // No fixed frame here: the window controller owns the size.
    }

    /// A sidebar list needs an optional selection; the model never has none.
    private var sidebarSelection: Binding<MainWindowSection?> {
        Binding(
            get: { model.selection },
            set: { newValue in
                if let newValue { model.select(newValue) }
            }
        )
    }
}

/// "New: a quick tour" (Later waves: tutorial pages), offered once to a user
/// who finished setup before the tutorial existed. Non-modal, dismissible,
/// and never reappears once acted on — see `MainWindowModel.showTutorial()` /
/// `dismissTutorialBanner()`.
@MainActor
private struct TutorialOfferBanner: View {
    let onShow: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text("New: a quick tour of where the text goes, the menu bar, and how to customize KVoice.", bundle: .module)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "sparkles")
            }
            Spacer()
            Button {
                onShow()
            } label: {
                Text("Show", bundle: .module)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                onDismiss()
            } label: {
                Text("Not now", bundle: .module)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Dismiss the quick tour offer")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
        .accessibilityElement(children: .contain)
    }
}
