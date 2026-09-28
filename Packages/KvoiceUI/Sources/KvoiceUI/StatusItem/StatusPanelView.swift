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
/// Sections are accessibility containers with the menu's group names, each
/// row is a button with its label and value, the switch announces its own
/// state, and the primary control reads "Start Recording, Ready · Whisper
/// large-v3-turbo, ⌃⇧Space". Keyboard: ↓ / ↑ / Return / Escape / ⌘H ⌘, ⌘Q
/// come through `StatusPanelKeyEquivalents` (the presenter's local
/// monitor) into `model.focus` and `perform`; Tab is the system's.
///
/// `chrome` says who draws the panel's background: `.hosted` draws none —
/// an `NSPopover` supplies its own material (Liquid Glass on macOS 26),
/// arrow, edge and shadow, and answers Reduce Transparency itself, so glass
/// inside it would be glass on glass; `.standalone` draws the mock's card
/// (glass on macOS 26, the regular material below, an opaque window colour
/// under Reduce Transparency, a strong edge under Increase Contrast) for
/// the gallery and any future host without chrome of its own.
public struct StatusPanelView: View {
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
        VStack(alignment: .leading, spacing: 0) {
            primaryBlock(state)
            sectionDivider
            dictationSection(state)
            sectionDivider
            aiSection(state)
            sectionDivider
            footBlock(state)
        }
        .frame(width: Self.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(PanelChrome(chrome: chrome, reduceTransparency: reduceTransparency, increasedContrast: increasedContrast))
        // Keyed on the layout signature, not the whole state: the level
        // and clock tick at 20 Hz and must not retrigger the row animation.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: state.layoutSignature)
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

    // MARK: Primary block — the "slider" of the Sound module

    private func primaryBlock(_ state: StatusPanelState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.perform(.toggleDictation)
            } label: {
                HStack(spacing: 10) {
                    PrimaryGlyphView(glyph: state.primaryGlyph, enabled: state.primaryIsEnabled, pulses: model.isPresented, reduceMotion: reduceMotion)
                    // The key-caps share the title's line so the readiness
                    // line under it has the full width for a long model
                    // name ("Ready · Whisper large-v3-turbo").
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(verbatim: state.primaryTitle)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(state.primaryIsEnabled ? .primary : .secondary)
                            if let badge = state.header.finishingBadge {
                                FinishingBadge(text: badge)
                            }
                            Spacer(minLength: 8)
                            if !state.shortcutKeys.isEmpty {
                                KeyCaps(state.shortcutKeys)
                            } else if let note = state.shortcutNote {
                                Text(verbatim: note)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        if !state.readiness.isEmpty {
                            Text(verbatim: state.readiness)
                                .font(.system(size: 11))
                                .foregroundStyle(state.readinessIsAttention ? Color.orange : Color.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PanelRowButtonStyle(inset: -6))
            .disabled(!state.primaryIsEnabled)
            .focused($focus, equals: .primary)
            .panelHelp(state.shortcutNote)
            .accessibilityLabel(Text(verbatim: state.primaryAccessibilityLabel))

            feedRow(state.feed)

            ForEach(state.dictationRows) { row in
                commandRow(row)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Dictation", bundle: .module))
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
        case .meter(let level, let elapsed):
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                LevelBar(level: level, reduceMotion: reduceMotion)
                Text(verbatim: HUDViewState.formatElapsed(elapsed))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 30, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Recording", bundle: .module))
            .accessibilityValue(Text(verbatim: HUDViewState.formatElapsed(elapsed)))
        case .download(let label, let fraction):
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Group {
                    if let fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .controlSize(.small)
                // The label wins the width; the bar takes what is left
                // ("Downloading Whisper large-v3-turbo… 42%" is the
                // longest, and a bar of any length reads).
                Text(verbatim: label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                    .frame(maxWidth: 200, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
        }
    }

    // MARK: Dictation rows — the "Output" device rows

    private func dictationSection(_ state: StatusPanelState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle(Text("Dictation", bundle: .module))
            chooserRow(state.modelRow)
            chooserRow(state.languageRow)
            chooserRow(state.microphoneRow)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Transcription", bundle: .module))
    }

    // MARK: AI rows — the switch

    private func aiSection(_ state: StatusPanelState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle(Text("AI", bundle: .module))
            HStack(spacing: 10) {
                rowIcon("sparkles", tint: state.aiSwitch.isEnabled ? .accentColor : .secondary)
                Text(verbatim: state.aiSwitch.title)
                    .font(Self.rowFont)
                    .foregroundStyle(state.aiSwitch.isEnabled ? .primary : .secondary)
                Spacer()
                // The switch's binding sends `toggleAI` whichever way it is
                // flipped; the position follows the committed settings, not
                // the flip, so a refused intent leaves it where it was.
                Toggle(isOn: Binding(get: { state.aiIsOn }, set: { _ in model.perform(.toggleAI) })) {
                    Text(verbatim: state.aiSwitch.title)
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!state.aiSwitch.isEnabled)
                .focused($focus, equals: .row(.aiSwitch))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .panelHelp(state.aiSwitch.help)
            chooserRow(state.defaultActionRow)
            chooserRow(state.configurationRow)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("AI", bundle: .module))
    }

    // MARK: Foot — "Sound Settings…"

    private func footBlock(_ state: StatusPanelState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Request: every App-group command visible, no submenu.
            ForEach(state.footRows) { row in
                commandRow(row)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("App", bundle: .module))
    }

    // MARK: Rows

    /// A row that sends one command: icon (when it has one), title, key-cap.
    private func commandRow(_ row: StatusPanelState.Row) -> some View {
        Button {
            if let command = row.command {
                model.perform(command)
            }
        } label: {
            HStack(spacing: row.symbol == nil ? 0 : 8) {
                if let symbol = row.symbol {
                    rowIcon(symbol, tint: row.isAttention ? .orange : .secondary)
                }
                Text(verbatim: row.title)
                    .font(Self.rowFont)
                    .foregroundStyle(row.isEnabled ? .primary : .secondary)
                Spacer()
                if let keyCap = row.keyCap {
                    Text(verbatim: keyCap)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                } else if row.isAttention {
                    chevron
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowButtonStyle())
        .disabled(!row.isEnabled)
        .focused($focus, equals: .row(row.id))
        .panelHelp(row.help)
        .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
    }

    /// A value row whose click opens its chooser: a native `Menu`, so
    /// arrow keys, type-select, Return, Escape and VoiceOver's "menu"
    /// semantics inside it are the system's, and no second panel is
    /// stacked on the first (`popovers.md`: never a cascade of popovers).
    private func chooserRow(_ row: StatusPanelState.Row) -> some View {
        Menu {
            if let chooser = row.chooser {
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
        } label: {
            HStack(spacing: 10) {
                rowIcon(row.symbol ?? "circle", tint: row.isEnabled ? .primary : .secondary)
                Text(verbatim: row.title)
                    .font(Self.rowFont)
                    .foregroundStyle(row.isEnabled ? .primary : .secondary)
                Spacer(minLength: 8)
                if let value = row.value {
                    Text(verbatim: value)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let keyCap = row.keyCap {
                    KeyCaps([keyCap])
                }
                chevron
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PanelRowButtonStyle())
        .disabled(!row.isEnabled)
        .focused($focus, equals: .row(row.id))
        .panelHelp(row.help)
        .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
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
        case .selectModel, .selectLanguage, .selectMicrophone, .selectDefaultAction, .selectConfiguration:
            return true
        default:
            return false
        }
    }

    // MARK: Pieces

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(increasedContrast ? 0.35 : 0.08))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    private func sectionTitle(_ title: Text) -> some View {
        title
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func rowIcon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
            .background(tint.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

private extension View {
    /// `help(_:)` only when there is a tooltip — the menu's `toolTip`.
    @ViewBuilder
    func panelHelp(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            self.help(Text(verbatim: text))
        } else {
            self
        }
    }
}

// MARK: - Chrome

/// The panel's background per host; see `StatusPanelView.Chrome`. Glass
/// answers Reduce Transparency and Increase Contrast itself
/// (`liquid-glass.md › Which variant`); the material path and the edge
/// are ours, as in `HUDView.miniPillBackground`.
private struct PanelChrome: ViewModifier {
    let chrome: StatusPanelView.Chrome
    let reduceTransparency: Bool
    let increasedContrast: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: StatusPanelView.cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        switch chrome {
        case .hosted:
            content
        case .standalone:
            standalone(content)
        }
    }

    @ViewBuilder
    private func standalone(_ content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay { shape.strokeBorder(Color.primary.opacity(increasedContrast ? 0.6 : 0.2), lineWidth: 1) }
                .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        } else if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(increasedContrast ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.regularMaterial), in: shape)
                .overlay { shape.strokeBorder(Color.primary.opacity(increasedContrast ? 0.6 : 0.08), lineWidth: 1) }
                .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        }
    }
}

// MARK: - Row style

/// A Control Center row: flat, with a rounded highlight under the pointer
/// and a stronger one while pressed or focused. Opaque under Reduce
/// Transparency, a visible edge under Increase Contrast.
private struct PanelRowButtonStyle: ButtonStyle {
    /// Negative to let the highlight bleed past the row's own padding (the
    /// primary control sits in a wider block).
    var inset: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        PanelRowBody(configuration: configuration, inset: inset)
    }

    private struct PanelRowBody: View {
        let configuration: Configuration
        let inset: CGFloat
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            configuration.label
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fill)
                        .padding(inset)
                }
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 2)
                            .padding(inset)
                    }
                }
                .opacity(isEnabled ? 1 : 0.55)
                .onHover { hovered = $0 && isEnabled }
        }

        private var fill: Color {
            let base = contrast == .increased ? 0.22 : 0.1
            if configuration.isPressed { return Color.primary.opacity(base + 0.08) }
            if hovered { return Color.primary.opacity(base) }
            return .clear
        }
    }
}

// MARK: - Pieces

/// The primary control's disc: the recording colour while recording, the
/// accent otherwise, secondary when disabled; the symbol says what a
/// click does. Pulses only while the input route is coming up, only
/// while the panel is shown, and never under Reduce Motion.
private struct PrimaryGlyphView: View {
    let glyph: StatusPanelState.PrimaryGlyph
    let enabled: Bool
    let pulses: Bool
    let reduceMotion: Bool
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(tint)
                .frame(width: 30, height: 30)
                .opacity(pulsing ? 0.55 : 1)
            switch glyph {
            case .working where !reduceMotion:
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            default:
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .onAppear { updatePulse() }
        .onChange(of: glyph) { _, _ in updatePulse() }
        .onChange(of: pulses) { _, _ in updatePulse() }
        .accessibilityHidden(true)
    }

    private var tint: Color {
        switch glyph {
        case .stop: return .red
        case .start, .starting: return enabled ? .accentColor : .secondary
        case .working, .done, .attention: return .secondary
        }
    }

    private var symbol: String {
        switch glyph {
        case .start, .starting: return "mic.fill"
        case .stop: return "stop.fill"
        case .working: return "hourglass"
        case .done: return "checkmark"
        case .attention: return "exclamationmark"
        }
    }

    private func updatePulse() {
        guard glyph == .starting, pulses, !reduceMotion else {
            pulsing = false
            return
        }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}

/// Key-cap glyphs for a shortcut, the way Control Center and menus show
/// key equivalents: tertiary, small, never a control.
private struct KeyCaps: View {
    let keys: [String]
    init(_ keys: [String]) { self.keys = keys }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(verbatim: key)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: keys.joined()))
    }
}

/// A slim horizontal level bar — the module's slider, read-only. Driven by
/// the HUD's smoothed level; a level change is a repaint of the fill.
private struct LevelBar: View {
    let level: Double
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Color.accentColor).frame(width: proxy.size.width * min(max(level, 0), 1))
            }
        }
        .frame(height: 6)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}
