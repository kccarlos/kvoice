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
    @State private var sidebarVisible = true
    /// UI v2 fidelity F3b: the button the shown page publishes for its
    /// header (`mainWindowHeaderAction(_:)`).
    @State private var publishedHeaderAction: MainWindowHeaderAction?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        model: MainWindowModel,
        content: @escaping @MainActor (MainWindowSection) -> AnyView
    ) {
        self.model = model
        self.content = content
    }

    /// UI v2 fidelity F2: the design's height of the empty strip over the
    /// detail column (Window.dc: 38 pt), which also clears the window's
    /// transparent title bar.
    static let titlebarStripHeight: CGFloat = 38

    public var body: some View {
        // UI v2 fidelity F2: a drawn shell instead of NavigationSplitView.
        // The design's sidebar is flush, opaque (kv.sidebar) and full height
        // with the traffic lights inside it; the split view's system column
        // is inset glass on macOS 26+ and never rendered offscreen.
        HStack(spacing: 0) {
            if sidebarVisible {
                MainWindowSidebar(model: model)
                    .frame(width: MainWindowSidebar.width)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                Rectangle()
                    .fill(Color.kv.line)
                    .frame(width: 1)
                    .accessibilityHidden(true)
            }
            detail
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Color.kv.bg)
        // No toolbar and a hidden title (the window controller): the window
        // title still names the page for VoiceOver and the Window list.
        .background(WindowTitleBridge(title: model.selection.title))
        // No fixed frame here: the window controller owns the size.
    }

    private var detail: some View {
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
                titlebarStrip
                if model.showTutorialBanner {
                    TutorialOfferBanner(
                        onShow: { model.showTutorial() },
                        onDismiss: { model.dismissTutorialBanner() }
                    )
                }
                if model.selection.showsPageHeader {
                    SectionHeaderView(section: model.selection, action: model.selection.headerAction(from: publishedHeaderAction))
                }
                content(model.selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onPreferenceChange(MainWindowHeaderActionKey.self) { action in
                        publishedHeaderAction = action
                    }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        // UI v2: every page's grouped Form sits on the window ground
        // (kv.bg) with its cards on kv.surface; hiding the scroll
        // background here reaches every page's Form and List at once.
        .scrollContentBackground(.hidden)
        .background(Color.kv.bg)
        // Keyed on the section so each section's `.task` modifiers start
        // fresh and the previous section's polls are cancelled.
        .id(model.selection)
    }

    /// The design's empty 38 pt strip. It keeps the window's one control the
    /// design does not draw — hide / show the sidebar (the split view's
    /// toolbar button until F2) — at its leading edge, clear of the traffic
    /// lights when the sidebar is hidden.
    private var titlebarStrip: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.8)) {
                    sidebarVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.kv.text2)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(sidebarVisible ? Text("Hide Sidebar", bundle: .module) : Text("Show Sidebar", bundle: .module))
            .accessibilityLabel(sidebarVisible ? Text("Hide Sidebar", bundle: .module) : Text("Show Sidebar", bundle: .module))
            .padding(.leading, sidebarVisible ? 8 : 78)
            .padding(.top, 7)
            Spacer(minLength: 0)
        }
        .frame(height: Self.titlebarStripHeight, alignment: .top)
    }
}

/// Keeps the hosting window's title on the selected page while the title
/// bar hides it (AppKit title, read by VoiceOver and Mission Control).
private struct WindowTitleBridge: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let title = title
        DispatchQueue.main.async { [weak view] in
            view?.window?.title = title
        }
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
                    .foregroundStyle(Color.kv.cursorInk)
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
        .background(Color.kv.cursorSoft)
        .accessibilityElement(children: .contain)
    }
}

/// UI v2: the sidebar's live readiness pill — a dot and the shell's one-line
/// status, then the recording shortcut. Warn-soft with warn-ink words when
/// something needs attention; a quiet surface card when ready. Status is
/// never colour alone: the words always say it.
@MainActor
struct SidebarReadinessPill: View {
    let readiness: MainWindowReadiness
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(readiness.tone.solid.color)
                .frame(width: 7, height: 7)
            Text(verbatim: readiness.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(readiness.needsAttention ? Color.kv.warnInk : Color.kv.text)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !readiness.shortcutKeys.isEmpty {
                Text(verbatim: readiness.shortcutKeys.joined())
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kv.text2)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .background(
            (readiness.needsAttention ? Color.kv.warnSoft : Color.kv.surface),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            // Window.dc: the ring is kv.line in both states; the warn-soft
            // ground and warn-ink words carry the attention.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(contrast == .increased ? Color.kv.text2 : Color.kv.line, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: readiness.accessibilityLabel))
    }
}

/// The main window's sidebar, drawn to the design (Window.dc): the
/// traffic-light row, untitled top group then titled groups of 28 pt rows
/// with colour tiles, the selected row on kv.select, and the readiness pill
/// at the bottom. Replaces the system `List` (UI v2 fidelity F2), so the
/// list behaviours it gave are rebuilt here: the column takes keyboard
/// focus (click or Tab), ↑/↓ move the selection, typing selects by title,
/// and VoiceOver reads a "Sections" group of buttons with the selected one
/// marked.
@MainActor
struct MainWindowSidebar: View {
    @Bindable var model: MainWindowModel
    @FocusState private var focused: Bool
    @State private var typed = ""
    @State private var typedAt = Date.distantPast
    @Environment(\.colorSchemeContrast) private var contrast

    /// Home.dc: `flex: 1 1 220px; max-width: 260px` beside a `flex: 999`
    /// main — the sidebar grows by a thousandth of the free space, so 220
    /// at every window size the app allows.
    static let width: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Window.dc: 14 pt top padding, then the 22 pt traffic-light row
            // (the window's own buttons sit over it).
            Color.clear.frame(height: 14 + 22)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(MainWindowSectionGroup.allCases) { group in
                        VStack(alignment: .leading, spacing: 1) {
                            if let title = group.title {
                                Text(verbatim: title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.kv.text2)
                                    .padding(.horizontal, 8)
                                    .padding(.bottom, 3)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(group.sections) { section in
                                row(section)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            // Below the rows rather than one of them, so the arrow keys
            // never land on it.
            if let readiness = model.readiness {
                SidebarReadinessPill(readiness: readiness)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.kv.sidebar)
        .focusable()
        .focused($focused)
        // The system List was the window's first key view, so ↑/↓ worked
        // as soon as the window opened; keep that.
        .defaultFocus($focused, true)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.home) { jump(to: MainWindowSectionGroup.allCases.first?.sections.first) }
        .onKeyPress(.end) { jump(to: MainWindowSectionGroup.allCases.last?.sections.last) }
        .onKeyPress(phases: .down) { press in typeSelect(press.characters) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Sections", bundle: .module))
    }

    private func row(_ section: MainWindowSection) -> some View {
        let selected = model.selection == section
        return HStack(spacing: 9) {
            KVGlyphTile(glyph: section.designGlyph, fill: section.tileFill, side: 20)
            Text(verbatim: section.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(Color.kv.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.kv.select : Color.clear)
        }
        .overlay {
            // Keyboard focus is visible on the selected row: the cursor
            // ring macOS draws around a focused list (or the high-contrast
            // outline on any selected row).
            if selected, focused || contrast == .increased {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(focused ? Color.kv.cursor : Color.kv.text2, lineWidth: focused ? 2 : 1)
            }
        }
        .animation(.easeOut(duration: 0.2), value: selected)
        .contentShape(Rectangle())
        .onTapGesture {
            focused = true
            model.select(section)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: section.title))
        .accessibilityHint(Text(verbatim: section.purpose))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(Text(verbatim: KVAccessibility.selectionValue(selected)))
        .accessibilityAction { model.select(section) }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        model.select(MainWindowSection.sidebarNeighbour(of: model.selection, step: step))
        return .handled
    }

    private func jump(to section: MainWindowSection?) -> KeyPress.Result {
        guard let section else { return .ignored }
        model.select(section)
        return .handled
    }

    /// Type-to-select, as `List` did: letters typed within a second build
    /// a prefix; a single repeated letter cycles through its matches.
    private func typeSelect(_ characters: String) -> KeyPress.Result {
        guard let character = characters.first, character.isLetter || character.isNumber else { return .ignored }
        let now = Date()
        let continuing = now.timeIntervalSince(typedAt) < 1
        typedAt = now
        let candidate = continuing && typed != String(character) ? typed + characters : characters
        typed = candidate
        guard let match = MainWindowSection.typeSelect(candidate, from: model.selection) else { return .ignored }
        model.select(match)
        return .handled
    }
}
