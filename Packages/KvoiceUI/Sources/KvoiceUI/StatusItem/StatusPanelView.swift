import SwiftUI
import KvoiceDomain

/// The Control-Center-style status panel (P-D4, 2026-09-16): the
/// approved mock (`StatusPanelMock` in the test target, superseded by this
/// view) made real over `StatusPanelModel`. The shape is Control Center's
/// *Sound* module — one primary control on top with a read-only level bar
/// under it, icon-led value rows with a chevron, a switch section, and the
/// app commands at the foot. Every row the `NSMenu` shows is here; the
/// menu itself stays as the right-click / ⌥-click fallback.
///
/// UI v2 (wave 2) and fidelity F1 (2026-10-21, `Panel.dc.html`): the
/// primary control, its subtitle, the feed, the outcome's words and the
/// state's buttons sit on one top card whose ground says the state
/// (`StatusPanelState.cardTone`); the idle card carries the last
/// transcription. Model, Language and Microphone lead with the design's
/// stroke tiles; the AI block is one chip row — Off or an action — under
/// "AI Action" with the configuration as a link; the foot rows are text
/// only. The marks are the design's paths (`StatusPanelGlyphs.swift`), the
/// panel-scoped colours `PanelColor`, the rest `Color.kv` tokens. Motion
/// follows `Motion.dc.html`: the level follows the voice (§ 4·6), the
/// clock and the percent roll (§ 7), the check draws itself (§ 10·12),
/// state changes cross-fade; Reduce Motion turns movement into fades.
///
/// Sections are accessibility containers with the menu's group names, each
/// row is a button with its label and value, the Off chip and the action
/// chips carry the selected trait, and the primary control reads "Start
/// Recording, Ready · Whisper large-v3-turbo, ⌃⇧Space". Keyboard: ↓ / ↑ /
/// Return / Escape / ⌘H ⌘, ⌘Q come through `StatusPanelKeyEquivalents`
/// (the presenter's local monitor) into `model.focus` and `perform`; Tab
/// is the system's.
public struct StatusPanelView: View {
    /// Who draws the panel's ground. `.standalone` draws the design's own
    /// (`Panel.dc.html`): the solid panel colour, a 22 pt continuous
    /// corner and the .5 pt edge — the app's borderless status panel
    /// (`StatusPanelController`) and the renders use it. `.hosted` draws
    /// none, for a host that brings its own (the design gallery's frame).
    public enum Chrome: Sendable {
        case hosted
        case standalone
    }

    public static let panelWidth: CGFloat = 320
    static let cornerRadius: CGFloat = 22
    static let rowFont = Font.system(size: 13)

    /// The three accessibility settings the view answers. Read from the
    /// environment in the app; the environment's values are read-only, so
    /// tests and the gallery pass them in to render the variants.
    public struct AccessibilityOverrides: Equatable, Sendable {
        public var reduceMotion: Bool?
        public var reduceTransparency: Bool?
        public var increasedContrast: Bool?

        public init(reduceMotion: Bool? = nil, reduceTransparency: Bool? = nil, increasedContrast: Bool? = nil) {
            self.reduceMotion = reduceMotion
            self.reduceTransparency = reduceTransparency
            self.increasedContrast = increasedContrast
        }
    }

    private let model: StatusPanelModel
    private let chrome: Chrome
    private let overrides: AccessibilityOverrides
    @Environment(\.accessibilityReduceMotion) private var environmentReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var environmentReduceTransparency
    @Environment(\.colorSchemeContrast) private var environmentContrast
    @FocusState private var focus: StatusPanelModel.FocusTarget?
    /// Motion § 4·6: the level the meter and the stop disc's halo show —
    /// fast attack, slow release — stepped on every feed tick.
    @State private var follower = KVLevelFollower()

    private var reduceMotion: Bool { overrides.reduceMotion ?? environmentReduceMotion }
    private var reduceTransparency: Bool { overrides.reduceTransparency ?? environmentReduceTransparency }
    private var increasedContrast: Bool { overrides.increasedContrast ?? (environmentContrast == .increased) }

    public init(model: StatusPanelModel, chrome: Chrome = .hosted, overrides: AccessibilityOverrides = AccessibilityOverrides()) {
        self.model = model
        self.chrome = chrome
        self.overrides = overrides
    }

    public var body: some View {
        let state = model.state
        VStack(alignment: .leading, spacing: 10) {
            topCard(state)
            dictationSection(state)
            aiSection(state)
            footBlock(state)
        }
        .padding(12)
        .frame(width: Self.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(PanelChrome(chrome: chrome, increasedContrast: increasedContrast))
        // Keyed on the layout signature, not the whole state: the level
        // and clock tick at 20 Hz and must not retrigger the row animation.
        // Motion: state changes cross-fade (200–260 ms); under Reduce
        // Motion a plain 150 ms fade.
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.22), value: state.layoutSignature)
        .onAppear { follower = KVLevelFollower(level: Self.level(of: state.feed)) }
        .onChange(of: Self.level(of: state.feed)) { _, raw in stepLevel(raw) }
        // Focus flows both ways: ↓/↑ set `model.focus` through the key
        // router; a click or Tab that moves the system focus updates the
        // model so Return acts on what is highlighted.
        .onChange(of: model.focus) { _, next in
            if focus != next { focus = next }
        }
        .onChange(of: focus) { _, next in
            if model.focus != next { model.focus = next }
        }
        // No default focus: like a menu, nothing is highlighted until ↓ / ↑
        // or Tab moves the focus, so opening the panel draws no ring.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("KVoice", bundle: .module))
    }

    private static func level(of feed: StatusPanelState.Feed) -> Double {
        if case .meter(let level, _) = feed { return level }
        return 0
    }

    private func stepLevel(_ raw: Double) {
        follower.follow(raw: raw, at: Date())
    }

    // MARK: Top card — what is happening and what to do about it

    /// The primary control, its subtitle, the trailing caps / link /
    /// clock, the feed, the outcome's words, the state's buttons and (idle)
    /// the last transcription, on one card whose ground says the state:
    /// voice while recording, warn while blocked, an err edge when a job
    /// ended without inserting (`Panel.dc.html`, "Top card · every state").
    private func topCard(_ state: StatusPanelState) -> some View {
        let buttons = state.dictationRows.filter { $0.id != .copyLastTranscription }
            .sorted { Self.emphasisRank($0.emphasis) < Self.emphasisRank($1.emphasis) }
        let copyLast = state.dictationRows.first { $0.id == .copyLastTranscription }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    model.perform(.toggleDictation)
                } label: {
                    HStack(spacing: 12) {
                        PrimaryGlyphView(
                            glyph: state.primaryGlyph,
                            outcome: state.outcomeGlyph,
                            downloading: Self.isDownloading(state.feed),
                            enabled: state.primaryIsEnabled,
                            level: follower.level,
                            animates: model.isPresented && !reduceMotion,
                            reduceMotion: reduceMotion
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(verbatim: state.primaryTitle)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.kv.text)
                                    .opacity(Self.dimsTitle(state) ? 0.5 : 1)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if let badge = state.header.finishingBadge {
                                    FinishingBadge(text: badge)
                                }
                            }
                            subtitle(state)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                // Not dimmed as a whole: a finishing job's disc and words stay
                // legible; only an idle Start without a model dims its title.
                .buttonStyle(PanelRowButtonStyle(inset: -6, horizontalPadding: 0, verticalPadding: 0, dimsWhenDisabled: false))
                .disabled(!state.primaryIsEnabled)
                .focused($focus, equals: .primary)
                .panelHelp(state.shortcutNote)
                .accessibilityLabel(Text(verbatim: state.primaryAccessibilityLabel))

                trailing(state)
            }

            feedRow(state.feed)

            if let text = state.resultText {
                Text(verbatim: text)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kv.text)
                    .lineSpacing(3)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 9)
                    .background(Color.kv.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.leading, 52)
                    .accessibilityLabel(Text(verbatim: text))
            }

            if !buttons.isEmpty {
                KVFlowLayout(spacing: 6) {
                    ForEach(buttons) { row in
                        cardButton(row)
                    }
                }
                .padding(.leading, 52)
            }

            if let copyLast {
                lastTranscriptionSection(state.lastTranscription, copy: copyLast)
            }
        }
        .padding(12)
        .background(cardFill(state.cardTone), in: cardShape)
        .overlay { cardShape.strokeBorder(cardEdge(state.cardTone), lineWidth: state.cardTone == .voice || state.cardTone == .err ? 1 : 0.5) }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: state.cardTone)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Dictation", bundle: .module))
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    private func cardFill(_ tone: StatusPanelState.CardTone) -> Color {
        switch tone {
        case .voice: return Color.kv.voiceSoft
        case .warn: return Color.kv.warnSoft
        case .plain, .err: return PanelColor.surface
        }
    }

    private func cardEdge(_ tone: StatusPanelState.CardTone) -> Color {
        switch tone {
        case .voice: return Color.kv.voice
        case .err: return Color.kv.err
        case .plain, .warn: return increasedContrast ? Color.primary.opacity(0.45) : PanelColor.cardLine
        }
    }

    /// The design dims the title (50 %) while the card cannot start a
    /// recording yet: downloading, optimizing, blocked.
    private static func dimsTitle(_ state: StatusPanelState) -> Bool {
        !state.primaryIsEnabled && (state.primaryGlyph == .start || state.primaryGlyph == .attention)
            || state.cardTone == .warn
    }

    /// Primary first, then the fix, then the plain buttons.
    private static func emphasisRank(_ emphasis: StatusPanelState.Row.Emphasis) -> Int {
        switch emphasis {
        case .primary: return 0
        case .warn: return 1
        case .plain: return 2
        }
    }

    private static func isDownloading(_ feed: StatusPanelState.Feed) -> Bool {
        if case .download = feed { return true }
        return false
    }

    /// The line under the title. Ready: a 7 pt ok dot and quiet words. A
    /// line that asks something of the user (warn, err): the tone's ink,
    /// semibold, no dot. Everything else: quiet words.
    @ViewBuilder
    private func subtitle(_ state: StatusPanelState) -> some View {
        if !state.readiness.isEmpty {
            // The design's subtitle is not clipped to a line: beside the key
            // caps "Ready · Whisper large-v3-turbo" wraps to a second line
            // (the memory-pressure line to a third).
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if state.readinessTone == .ok {
                    Circle().fill(Color.kv.ok).frame(width: 7, height: 7)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 }
                }
                Text(verbatim: state.readiness)
                    .font(.system(size: 11, weight: Self.isLoud(state.readinessTone) ? .semibold : .regular))
                    .foregroundStyle(Self.subtitleColor(state.readinessTone))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func isLoud(_ tone: KVTone?) -> Bool {
        tone == .warn || tone == .err
    }

    private static func subtitleColor(_ tone: KVTone?) -> Color {
        switch tone {
        case .warn?: return Color.kv.warnInk
        case .err?: return Color.kv.errInk
        default: return Color.kv.text2
        }
    }

    /// The card's trailing slot, centred on the 40 pt disc: the shortcut's
    /// caps (idle), "Set Shortcut…" when there is no working shortcut, or
    /// the clock (recording), whose digits roll (Motion § 7).
    @ViewBuilder
    private func trailing(_ state: StatusPanelState) -> some View {
        if case .meter(_, let elapsed) = state.feed {
            Text(verbatim: HUDViewState.formatElapsed(elapsed))
                .font(KVFont.metric(size: 14))
                .foregroundStyle(Color.kv.text)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8), value: HUDViewState.formatElapsed(elapsed))
                .fixedSize()
                .accessibilityHidden(true)
        } else if !state.shortcutKeys.isEmpty {
            Keycaps(state.shortcutKeys, size: .medium)
        } else if let link = state.shortcutLink {
            Button {
                if let command = link.command {
                    model.perform(command)
                }
            } label: {
                Text(verbatim: link.title)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kv.cursorInk)
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(LinkButtonStyle())
            .disabled(!link.isEnabled)
            .focused($focus, equals: .row(link.id))
            .panelHelp(link.help)
            .accessibilityLabel(Text(verbatim: link.title))
            .accessibilityHint(Text(verbatim: link.help ?? ""))
        }
    }

    /// The meter exists only while a job is recording — the microphone is
    /// never open otherwise (product rule 2026-09-16); `StatusPanelState.feed`
    /// carries `.meter` for a live recording and nothing else. While a
    /// model downloads, its progress takes the row instead.
    @ViewBuilder
    private func feedRow(_ feed: StatusPanelState.Feed) -> some View {
        switch feed {
        case .none:
            EmptyView()
        case .meter(_, let elapsed):
            LevelBars(level: follower.level)
                .padding(.leading, 52)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Recording", bundle: .module))
                .accessibilityValue(Text(verbatim: HUDViewState.formatElapsed(elapsed)))
        case .download(let label, let fraction):
            VStack(alignment: .leading, spacing: 5) {
                ProgressTrack(fraction: fraction, reduceMotion: reduceMotion)
                HStack {
                    Text(verbatim: label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    if let percent = StatusPanelState.percentText(fraction) {
                        Text(verbatim: percent)
                            .font(KVFont.metric(size: 11, weight: .regular))
                            .contentTransition(.numericText())
                            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8), value: percent)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.kv.text2)
            }
            .padding(.leading, 52)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityValue(Text(verbatim: StatusPanelState.percentText(fraction) ?? ""))
        }
    }

    /// UI v2: the newest saved transcription under the idle controls — a
    /// two-line preview, how long ago, and Copy. Without a preview (no
    /// history yet, history off or unavailable) the row is a plain button,
    /// disabled with the menu's tooltip when it cannot copy.
    @ViewBuilder
    private func lastTranscriptionSection(_ last: StatusPanelState.LastTranscription?, copy: StatusPanelState.Row) -> some View {
        if let last {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Last transcription", bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(verbatim: StatusPanelState.relativeTime(last.createdAt, now: model.now()))
                        .font(.system(size: 11))
                }
                .foregroundStyle(Color.kv.text2)
                Text(verbatim: last.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kv.text)
                    .lineLimit(2)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                cardButton(copy, compact: true)
            }
            .padding(.top, 9)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.kv.line2).frame(height: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Last transcription", bundle: .module))
        } else {
            cardButton(StatusPanelState.Row(
                id: copy.id, symbol: copy.symbol, title: copy.title, isEnabled: copy.isEnabled,
                help: copy.help, command: copy.command
            ))
            .padding(.leading, 52)
        }
    }

    /// A state row as a card button: primary (cursor fill), warn (the fix),
    /// or plain (outlined). Focus and VoiceOver keep the row's full title.
    private func cardButton(_ row: StatusPanelState.Row, compact: Bool = false) -> some View {
        Button {
            if let command = row.command {
                model.perform(command)
            }
        } label: {
            Text(verbatim: row.buttonTitle)
                .lineLimit(1)
        }
        .buttonStyle(CardButtonStyle(emphasis: row.emphasis, compact: compact, increasedContrast: increasedContrast))
        .disabled(!row.isEnabled)
        .focused($focus, equals: .row(row.id))
        .panelHelp(row.help)
        .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
    }

    // MARK: Dictation rows — the "Output" device rows

    private func dictationSection(_ state: StatusPanelState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle(Text("Dictation", bundle: .module))
                .padding(.horizontal, 6)
                .padding(.top, 2)
                .padding(.bottom, 4)
            chooserRow(state.modelRow, mark: .bars, tile: .voice)
            chooserRow(state.languageRow, mark: .globe, tile: .cursor)
            chooserRow(state.microphoneRow, mark: .mic, tile: .voice)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Transcription", bundle: .module))
    }

    // MARK: AI — one chip row: Off or an action

    /// UI v2 fidelity F1 (`Panel.dc.html`): "Use AI Actions", Default
    /// Action and Configuration collapse into one row — "AI Action" with
    /// the configuration as a link, then the chips, **Off** first. Off is
    /// the old switch (`toggleAI`, the same gate and tooltip); an action
    /// picked while AI is off turns it on with that action
    /// (`useAIAction`). The lit chip is what the next dictation will do.
    private func aiSection(_ state: StatusPanelState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionTitle(Text("AI Action", bundle: .module))
                Spacer(minLength: 4)
                configurationLink(state.configurationRow)
            }
            actionChips(state)
        }
        .padding(.top, 10)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .overlay(alignment: .top) { sectionDivider }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("AI", bundle: .module))
    }

    private func actionChips(_ state: StatusPanelState) -> some View {
        let chips = state.aiChips
        // The row's focus target lands on the current action, else the
        // first, whatever the switch says, so ↓ never lands on nothing.
        let focusID = chips.first(where: \.isSelected)?.id ?? chips.first?.id
        let off = state.aiSwitch
        return KVFlowLayout(spacing: 5) {
            Button {
                if state.aiIsOn {
                    model.perform(.toggleAI)
                }
            } label: {
                Text(verbatim: off.buttonTitle).lineLimit(1)
            }
            .buttonStyle(ChipButtonStyle(kind: state.aiIsOn ? .off : .lit, increasedContrast: increasedContrast))
            .disabled(!off.isEnabled)
            .focused($focus, equals: .row(.aiSwitch))
            .panelHelp(off.help)
            .accessibilityLabel(Text(verbatim: AIActionsCopy.aiOff))
            .accessibilityAddTraits(state.aiIsOn ? [] : .isSelected)
            .accessibilityValue(Text(verbatim: KVAccessibility.selectionValue(!state.aiIsOn)))

            ForEach(chips) { choice in
                Button {
                    if let command = Self.chipCommand(choice.command, aiIsOn: state.aiIsOn) {
                        model.perform(command)
                    }
                } label: {
                    Text(verbatim: choice.title).lineLimit(1)
                }
                .buttonStyle(ChipButtonStyle(kind: choice.isSelected && state.aiIsOn ? .lit : .plain, increasedContrast: increasedContrast))
                .disabled(!choice.isEnabled || !state.defaultActionRow.isEnabled)
                .modifier(FocusIf(active: choice.id == focusID, focus: $focus, target: .row(.defaultAction)))
                .panelHelp(choice.help)
                .accessibilityLabel(Text(verbatim: choice.title))
                .accessibilityAddTraits(choice.isSelected && state.aiIsOn ? .isSelected : [])
                .accessibilityValue(Text(verbatim: KVAccessibility.selectionValue(choice.isSelected && state.aiIsOn)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: state.defaultActionRow.title))
    }

    /// While AI is off, picking an action is picking "on, with this".
    static func chipCommand(_ command: StatusPanelCommand?, aiIsOn: Bool) -> StatusPanelCommand? {
        guard !aiIsOn, case .selectDefaultAction(let id)? = command else { return command }
        return .useAIAction(id)
    }

    /// "Local Ollama ›": the Configuration chooser as a link.
    private func configurationLink(_ row: StatusPanelState.Row) -> some View {
        Menu {
            chooserItems(row.chooser)
        } label: {
            Text(verbatim: "\(row.value ?? "") ›")
                .font(.system(size: 11))
                .foregroundStyle(Color.kv.cursorInk)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160, alignment: .trailing)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!row.isEnabled)
        .focused($focus, equals: .row(row.id))
        .panelHelp(row.help)
        .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
    }

    // MARK: Foot — "Sound Settings…"

    private func footBlock(_ state: StatusPanelState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Request: every App-group command visible, no submenu.
            ForEach(state.footRows) { row in
                commandRow(row)
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, 4)
        .overlay(alignment: .top) { sectionDivider }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("App", bundle: .module))
    }

    // MARK: Rows

    /// A foot row: 26 pt, title and key-cap text, nothing else.
    private func commandRow(_ row: StatusPanelState.Row) -> some View {
        Button {
            if let command = row.command {
                model.perform(command)
            }
        } label: {
            HStack(spacing: 0) {
                Text(verbatim: row.title)
                    .font(Self.rowFont)
                    .foregroundStyle(Color.kv.text)
                Spacer()
                if let keyCap = row.keyCap {
                    Text(verbatim: keyCap)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.kv.text2)
                }
            }
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowButtonStyle(verticalPadding: 0, radius: 6))
        .disabled(!row.isEnabled)
        .focused($focus, equals: .row(row.id))
        .panelHelp(row.help)
        .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
    }

    /// A value row whose click opens its chooser: a native `Menu`, so
    /// arrow keys, type-select, Return, Escape and VoiceOver's "menu"
    /// semantics inside it are the system's, and no second panel is
    /// stacked on the first (`popovers.md`: never a cascade of popovers).
    /// 30 pt: the design's tile, label, value (140 pt, tail-cut) and "›".
    private func chooserRow(_ row: StatusPanelState.Row, mark: PanelGlyphShape.Mark, tile: KVTone) -> some View {
        Menu {
            chooserItems(row.chooser)
        } label: {
            HStack(spacing: 10) {
                PanelIconTile(mark: mark, tone: tile, isEnabled: row.isEnabled)
                Text(verbatim: row.title)
                    .font(Self.rowFont)
                    .foregroundStyle(Color.kv.text)
                Spacer(minLength: 8)
                if let value = row.value {
                    Text(verbatim: value)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.kv.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 140, alignment: .trailing)
                }
                if let keyCap = row.keyCap {
                    Keycaps([keyCap], size: .compact)
                }
                Text(verbatim: "›")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.kv.text2)
                    .accessibilityHidden(true)
            }
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PanelRowButtonStyle(verticalPadding: 0))
        .disabled(!row.isEnabled)
        .focused($focus, equals: .row(row.id))
        .panelHelp(row.help)
        .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
    }

    @ViewBuilder
    private func chooserItems(_ chooser: StatusPanelChooser?) -> some View {
        if let chooser {
            ForEach(chooser.choices) { choice in
                chooserItem(choice)
                if choice.separatorAfter {
                    Divider()
                }
            }
            if !chooser.footer.isEmpty {
                Divider()
                ForEach(chooser.footer) { choice in
                    chooserItem(choice)
                }
            }
        }
    }

    /// A pickable choice draws as a checked menu item (a `Toggle` inside a
    /// `Menu` is the system's checkmark row); a note row is plain text,
    /// which a `Menu` shows disabled, as the submenu does.
    @ViewBuilder
    private func chooserItem(_ choice: StatusPanelChoice) -> some View {
        if let command = choice.command {
            if Self.isPick(command) {
                Toggle(isOn: Binding(get: { choice.isSelected }, set: { _ in model.perform(command) })) {
                    Text(verbatim: choice.title)
                }
                .disabled(!choice.isEnabled)
            } else {
                Button {
                    model.perform(command)
                } label: {
                    Text(verbatim: choice.title)
                }
                .disabled(!choice.isEnabled)
            }
        } else {
            Text(verbatim: choice.title)
        }
    }

    /// Commands that pick a value (drawn with the checkmark column) versus
    /// the footer commands that open a window (plain rows).
    private static func isPick(_ command: StatusPanelCommand) -> Bool {
        switch command {
        case .selectModel, .selectLanguage, .selectMicrophone, .selectDefaultAction, .selectConfiguration, .useAIAction:
            return true
        default:
            return false
        }
    }

    // MARK: Pieces

    private var sectionDivider: some View {
        Rectangle()
            .fill(increasedContrast ? Color.primary.opacity(0.35) : Color.kv.line2)
            .frame(height: 1)
    }

    private func sectionTitle(_ title: Text) -> some View {
        title
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.kv.text2)
            .accessibilityAddTraits(.isHeader)
    }
}
