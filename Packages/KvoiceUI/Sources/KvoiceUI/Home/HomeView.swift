import SwiftUI
import KvoiceDomain

/// UI v2 wave 5a: the Home page, where the main window opens — the ink hero
/// (readiness, the real shortcut, model / microphone / AI chips), this
/// week's four figures and the newest dictations with Copy.
///
/// Every figure comes from the history store through
/// `HistoryViewModel.refreshHome()`; nothing here is invented. Recent rows
/// show no app name because history does not store one.
@MainActor
public struct HomeView: View {
    @Bindable private var model: MainWindowModel
    @Bindable private var history: HistoryViewModel
    private let testDictation: HomeTestDictationModel?
    @State private var copiedID: HistoryEntryID?
    /// Motion §7: figures roll only when they change on screen, never as a
    /// count-up from zero when the page first loads.
    @State private var rollFigures = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    public init(model: MainWindowModel, history: HistoryViewModel, testDictation: HomeTestDictationModel? = nil) {
        self.model = model
        self.history = history
        self.testDictation = testDictation
    }

    public var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HomeHero(state: model.home, select: { model.select($0) }, onTestDictation: testDictation.map { test in { test.present() } })
                    if history.historyEnabled {
                        stats
                        recent
                    } else {
                        historyOff
                    }
                }
                .frame(maxWidth: HomeLayout.maxContentWidth)
                .padding(.horizontal, HomeLayout.sidePadding(windowWidth: proxy.size.width + MainWindowSidebar.width + 1))
                .padding(.top, HomeLayout.topPadding)
                .padding(.bottom, HomeLayout.bottomPadding)
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            if history.home != nil { rollFigures = true }
            await history.refreshHome()
            // Let the first figures land without a transaction first.
            try? await Task.sleep(for: .milliseconds(150))
            rollFigures = true
        }
        .task(id: copiedID) {
            guard copiedID != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copiedID = nil }
        }
        .sheet(isPresented: Binding(
            get: { testDictation?.isPresented ?? false },
            set: { if !$0 { testDictation?.dismiss() } }
        )) {
            if let testDictation {
                HomeTestDictationSheet(model: testDictation)
            }
        }
    }

    // MARK: This week

    private var stats: some View {
        let tiles = (history.home ?? HomeSummary(today: .empty, week: .empty, recent: [])).tiles
        // Home.dc: `repeat(auto-fit, minmax(min(180px, 100%), 1fr))`, gap 12.
        return KVAutoFitGrid(minimumColumnWidth: 180, spacing: 12) {
            ForEach(tiles) { tile in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: tile.label)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.kv.text2)
                    Text(verbatim: tile.value)
                        .font(.system(size: 26, weight: HomeLayout.figureWeight, design: .monospaced))
                        .monospacedDigit()
                        .tracking(-0.52)
                        .foregroundStyle(Color.kv.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                        .animation(rollFigures ? HomeLayout.figureAnimation(reduceMotion: reduceMotion) : nil, value: tile.value)
                    Text(verbatim: tile.hint)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.kv.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay { tileShape.strokeBorder(contrast == .increased ? Color.kv.text2 : Color.kv.line, lineWidth: 1) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(tile.label): \(tile.value) \(tile.hint)"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("This week", bundle: .module))
    }

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent", bundle: .module)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.kv.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    model.select(.history)
                } label: {
                    Text("Open History ›", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.kv.cursorInk)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isLink)
            }
            let rows = history.home?.recent ?? []
            if rows.isEmpty {
                Text("Nothing dictated yet. Your newest dictations appear here.", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.kv.text2)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay { tileShape.strokeBorder(Color.kv.line, lineWidth: 1) }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Rectangle().fill(Color.kv.line2).frame(height: 1)
                        }
                        recentRow(entry)
                    }
                }
                .clipShape(tileShape)
                .overlay { tileShape.strokeBorder(contrast == .increased ? Color.kv.text2 : Color.kv.line, lineWidth: 1) }
            }
        }
    }

    private func recentRow(_ entry: HistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Home.dc's tile holds the app's initial; history stores no app
            // (J.5), so the tile says where the text went instead.
            Image(systemName: HomeLayout.outcomeSymbol(entry))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.kv.text2)
                .frame(width: 32, height: 32)
                .background(Color.kv.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: entry.finalText.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 13))
                    .lineSpacing(HomeLayout.recentLineSpacing)
                    .foregroundStyle(Color.kv.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text(verbatim: StatusPanelState.relativeTime(entry.createdAt, now: history.currentDate))
                    if entry.aiStatus == .succeeded {
                        Text(verbatim: "·").accessibilityHidden(true)
                        Text(verbatim: entry.mode.displayName)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.kv.cursorInk)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .background(Color.kv.cursorSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.kv.text2)
                .lineLimit(1)
            }
            Button {
                history.copyFinal(entry)
                copiedID = entry.id
            } label: {
                ZStack {
                    // Both words laid out so the button never changes width.
                    Text("Copied", bundle: .module).hidden()
                    if copiedID == entry.id {
                        Text("Copied", bundle: .module).transition(.opacity)
                    } else {
                        Text("Copy", bundle: .module).transition(.opacity)
                    }
                }
            }
            .buttonStyle(KVSmallButtonStyle())
            .accessibilityHint(Text("Copies this dictation's final text.", bundle: .module))
            .animation(.easeOut(duration: 0.2), value: copiedID)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }

    // MARK: History off

    private var historyOff: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History is off", bundle: .module)
                .font(.system(size: 17, weight: .semibold))
            Text("KVoice is not saving dictations, so there are no figures or recent dictations to show. Turn on Save dictation history in Data & Privacy.", bundle: .module)
                .font(.system(size: 13))
                .foregroundStyle(Color.kv.text2)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.select(.dataPrivacy)
            } label: {
                Text("Open Data & Privacy", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.kv.cursorInk)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isLink)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { tileShape.strokeBorder(Color.kv.line, lineWidth: 1) }
    }
}

/// Home.dc's numbers, in one place so they can be tested.
enum HomeLayout {
    static let maxContentWidth: CGFloat = 920
    static let topPadding: CGFloat = 32
    static let bottomPadding: CGFloat = 48
    /// CSS 650: SwiftUI has no numeric weights; semibold is the nearest.
    static let figureWeight = Font.Weight.semibold
    /// CSS line-height 1.45 on 13 pt is about 3 pt more than SF's own.
    static let recentLineSpacing: CGFloat = 3

    /// `padding: 32px clamp(16px, 4vw, 48px)`: 4 % of the window's width,
    /// never under 16 or over 48.
    static func sidePadding(windowWidth: CGFloat) -> CGFloat {
        min(48, max(16, (windowWidth * 0.04).rounded()))
    }

    /// Motion §7: the digit roll, 320 ms on cubic-bezier(.34, 1.4, .64, 1);
    /// Reduce Motion → a 150 ms crossfade.
    static func figureAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.34, 1.4, 0.64, 1, duration: 0.32)
    }

    /// The recent row's tile: where the text went (inserted at the cursor,
    /// left on the clipboard, a transcribed file, or kept in KVoice).
    static func outcomeSymbol(_ entry: HistoryEntry) -> String {
        if entry.isFileTranscription { return "doc" }
        switch entry.insertionOutcome {
        case .inserted: return "text.cursor"
        case .copiedToClipboard: return "doc.on.clipboard"
        case .deliveredInApp: return "text.bubble"
        default: return "minus"
        }
    }
}

/// Home.dc's small outline button (Copy): 28 pt, radius 7, 1 pt key-line
/// border on the surface, 12 pt medium.
struct KVSmallButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isEnabled ? Color.kv.text : Color.kv.text2)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(configuration.isPressed ? Color.kv.fill : Color.kv.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.kv.keyLine, lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The ink card at the top of Home (Home.dc hero). Its colours are the
/// design's literals for this card, light and dark (several are not
/// tokens; FIDELITY.md › F2 design problems).
@MainActor
struct HomeHero: View {
    let state: HomeHeroState?
    let select: (MainWindowSection) -> Void
    var onTestDictation: (() -> Void)?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                column.frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
                testButton
            }
            VStack(alignment: .leading, spacing: 24) {
                column.frame(maxWidth: .infinity, alignment: .leading)
                testButton
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HomeHeroPalette.ground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.kv.inkLine, lineWidth: 1)
            }
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let state {
                HStack(spacing: 8) {
                    Circle()
                        .fill(state.readiness.needsAttention ? HomeHeroPalette.attentionDot : HomeHeroPalette.readyDot)
                        .frame(width: 8, height: 8)
                    Text(verbatim: state.readiness.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.readiness.needsAttention ? HomeHeroPalette.attentionText : HomeHeroPalette.readyText)
                }
                .accessibilityElement(children: .combine)
                headline(state)
                chips(state)
            } else {
                headlineText(String(localized: "Hold your shortcut and speak.", bundle: .module))
            }
        }
    }

    @ViewBuilder
    private var testButton: some View {
        if let onTestDictation {
            Button(action: onTestDictation) {
                Text("Try a Test Dictation", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HomeHeroPalette.buttonText)
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .frame(height: 36)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .fixedSize()
            }
            .buttonStyle(KVPressScaleStyle())
            .accessibilityHint(Text("Records a short dictation and shows the text here, without typing it into any app.", bundle: .module))
        }
    }

    @ViewBuilder
    private func headline(_ state: HomeHeroState) -> some View {
        if state.hasShortcut {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    headlineText(state.verb)
                    caps(state.readiness.shortcutKeys)
                    headlineText(state.trailer)
                }
                VStack(alignment: .leading, spacing: 8) {
                    headlineText(state.verb)
                    caps(state.readiness.shortcutKeys)
                    headlineText(state.trailer)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(state.verb) \(state.readiness.shortcutKeys.joined()) \(state.trailer)"))
            .accessibilityAddTraits(.isHeader)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                headlineText(String(localized: "Set a recording shortcut to start dictating.", bundle: .module))
                Button {
                    select(.shortcuts)
                } label: {
                    Text("Open Shortcuts", bundle: .module)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Home.dc keycap on ink: 28 pt, radius 7, #2A3556 with a 1 pt #3D4970
    /// border and a 2 pt #0B0F1C base; 14 pt (a word key 13 pt) semibold.
    private func caps(_ keys: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
                Text(verbatim: key)
                    .font(.system(size: key.count > 2 ? 13 : 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, key.count > 2 ? 10 : 7)
                    .frame(minWidth: 28, minHeight: 28)
                    .background(HomeHeroPalette.cap, in: shape)
                    .overlay { shape.strokeBorder(HomeHeroPalette.capBorder, lineWidth: 1) }
                    .background { shape.fill(HomeHeroPalette.capBase).offset(y: 2) }
                    .fixedSize()
            }
        }
        .padding(.bottom, 2)
    }

    private func headlineText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 28, weight: .bold))
            .tracking(-0.28)
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chips(_ state: HomeHeroState) -> some View {
        KVFlowLayout(spacing: 8) {
            chip(state.modelName, dot: Color.kv.voice, hint: String(localized: "Opens Speech Models.", bundle: .module)) { select(.models) }
            chip(state.microphoneName, dot: Color.kv.voice, hint: String(localized: "Opens Microphone.", bundle: .module)) { select(.audioInput) }
            chip(state.aiChipTitle, dot: state.aiIsOn ? HomeHeroPalette.aiDot : Color.kv.grey, hint: String(localized: "Opens AI Actions.", bundle: .module)) { select(.aiActions) }
        }
    }

    private func chip(_ title: String, dot: Color, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(verbatim: title)
                    .font(.system(size: 12))
                    .foregroundStyle(HomeHeroPalette.chipText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(HomeHeroPalette.chip, in: Capsule())
            .overlay {
                if contrast == .increased { Capsule().strokeBorder(Color.kv.inkLine, lineWidth: 1) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(KVPressScaleStyle())
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(Text(verbatim: hint))
    }
}

/// Home.dc's hero literals (light) and Window.dc's dark values for the same
/// roles. Not tokens: see FIDELITY.md › F2 design problems.
enum HomeHeroPalette {
    static let ground = KVColorToken.ink.color
    static let chip = dynamic(light: 0x232C49, dark: 0x26304F)
    static let chipText = KVColorToken.inkText.color
    static let cap = KVColorToken.ink2.color
    static let capBorder = dynamic(light: 0x3D4970, dark: 0x3D4970)
    static let capBase = dynamic(light: 0x0B0F1C, dark: 0x0B0F1C)
    static let readyText = dynamic(light: 0xA9E2BF, dark: 0xA9E2BF)
    static let readyDot = dynamic(light: 0x3DCB7A, dark: 0x3DCB7A)
    static let attentionText = dynamic(light: 0xFFC966, dark: 0xFFC966)
    static let attentionDot = dynamic(light: 0xFFB940, dark: 0xFFB940)
    static let aiDot = dynamic(light: 0x5B8EF5, dark: 0x5B8EF5)
    static let buttonText = KVColorToken.ink.color

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return KVColorToken.srgb(isDark ? dark : light)
        })
    }
}

/// The press feedback every drawn control shares (Motion: presses 120 ms):
/// a 0.97 scale while held.
struct KVPressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
