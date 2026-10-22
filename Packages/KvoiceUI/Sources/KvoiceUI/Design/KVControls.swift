import SwiftUI

/// UI v2 fidelity F3: the drawn row controls of Window.dc's `row()` helper —
/// switch, select, segmented control, chip and the four button kinds. Each
/// keeps the native control underneath for keyboard and VoiceOver
/// (`accessibilityRepresentation`), so only the drawing changes.
public enum KVControlMotion {
    /// A state change (switch knob, segment) — Motion's 200–260 ms band.
    /// Reduce Motion keeps colour changes and drops the movement to a
    /// 150 ms crossfade.
    public static func stateChange(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.24, dampingFraction: 0.8)
    }
}

// MARK: Switch

/// Window.dc's switch: 32×19 track, 15 pt white knob, `cursor` when on and
/// `fill-2` when off. Dims to 45 % when disabled.
public struct KVSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(isOn: Binding<Bool>) { _isOn = isOn }

    public var body: some View {
        Capsule(style: .continuous)
            .fill(isOn ? Color.kv.cursor : Color.kv.fill2)
            .frame(width: 32, height: 19)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 15, height: 15)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .padding(2)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
            .onTapGesture {
                guard isEnabled else { return }
                withAnimation(KVControlMotion.stateChange(reduceMotion: reduceMotion)) { isOn.toggle() }
            }
            .animation(KVControlMotion.stateChange(reduceMotion: reduceMotion), value: isOn)
            // Keyboard navigation: Tab reaches it, Space toggles.
            .focusable(isEnabled)
            .onKeyPress(.space) {
                guard isEnabled else { return .ignored }
                withAnimation(KVControlMotion.stateChange(reduceMotion: reduceMotion)) { isOn.toggle() }
                return .handled
            }
    }
}

// MARK: Select

/// Window.dc's select: 24 pt high, `fill` ground, radius 6, 12 pt text and
/// the ▲▼ mark. A `Menu` holding an inline `Picker`, so the choices, the
/// check mark and keyboard use are the system's.
public struct KVSelect<Value: Hashable, Options: View>: View {
    private let title: Text
    @Binding private var selection: Value
    private let current: String
    private let options: Options

    public init(_ title: LocalizedStringKey, selection: Binding<Value>, current: String, @ViewBuilder options: () -> Options) {
        self.title = Text(title, bundle: .module)
        _selection = selection
        self.current = current
        self.options = options()
    }

    public init(verbatim title: String, selection: Binding<Value>, current: String, @ViewBuilder options: () -> Options) {
        self.title = Text(verbatim: title)
        _selection = selection
        self.current = current
        self.options = options()
    }

    public var body: some View {
        Menu {
            Picker(selection: $selection) { options } label: { title }
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            KVSelectLabel(text: current)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(Text(verbatim: current))
    }
}

struct KVSelectLabel: View {
    let text: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: text)
                .font(.system(size: 12))
                .foregroundStyle(Color.kv.text)
                .lineLimit(1)
            Text(verbatim: "▲▼")
                .font(.system(size: 7))
                .foregroundStyle(Color.kv.text2)
                .accessibilityHidden(true)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 24)
        .background(Color.kv.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: Segmented

/// Window.dc's segmented control: a `fill` track with a 2 pt inset, radius 7;
/// segments 3/10 padding, radius 5, 11 pt; the chosen one on `surface` with a
/// small shadow and semibold. VoiceOver and the keyboard get a native
/// segmented `Picker`.
public struct KVSegmented<Value: Hashable>: View {
    private let title: Text
    @Binding private var selection: Value
    private let options: [(Value, String)]
    private let size: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    public init(_ title: LocalizedStringKey, selection: Binding<Value>, options: [(Value, String)], size: CGFloat = 11) {
        self.title = Text(title, bundle: .module)
        _selection = selection
        self.options = options
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let chosen = option.0 == selection
                Text(verbatim: option.1)
                    .font(.system(size: size, weight: chosen ? .semibold : .regular))
                    .foregroundStyle(Color.kv.text)
                    .lineLimit(1)
                    .padding(.vertical, size > 11 ? 5 : 3)
                    .padding(.horizontal, size > 11 ? 12 : 10)
                    .background {
                        if chosen {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.kv.surface)
                                .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                                .matchedGeometryEffect(id: "segment", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard isEnabled else { return }
                        withAnimation(KVControlMotion.stateChange(reduceMotion: reduceMotion)) { selection = option.0 }
                    }
            }
        }
        .padding(2)
        .background(Color.kv.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .opacity(isEnabled ? 1 : 0.45)
        .fixedSize()
        // Keyboard navigation: Tab reaches it, ← / → step the choice.
        .focusable(isEnabled)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard isEnabled, let index = options.firstIndex(where: { $0.0 == selection }) else { return .ignored }
            let next = min(options.count - 1, max(0, index + (press.key == .leftArrow ? -1 : 1)))
            guard next != index else { return .handled }
            withAnimation(KVControlMotion.stateChange(reduceMotion: reduceMotion)) { selection = options[next].0 }
            return .handled
        }
        .accessibilityRepresentation {
            Picker(selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(verbatim: option.1).tag(option.0)
                }
            } label: { title }
                .pickerStyle(.segmented)
        }
    }
}

// MARK: Chip

/// Window.dc's `chipS`: 22 pt capsule, 11 pt semibold, the tone's soft
/// ground and ink, an optional 6 pt dot.
public struct KVChip: View {
    let text: String
    var tone: KVTone
    var dot: Bool

    public init(_ text: String, tone: KVTone, dot: Bool = true) {
        self.text = text
        self.tone = tone
        self.dot = dot
    }

    public var body: some View {
        HStack(spacing: 6) {
            if dot {
                Circle().fill(tone.solid.color).frame(width: 6, height: 6)
            }
            Text(verbatim: text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tone.ink.color)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(tone == .neutral ? Color.kv.fill : tone.soft.color, in: Capsule(style: .continuous))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
    }
}

// MARK: Buttons

/// Window.dc's `btn()`: 24 pt high, radius 6, 12 pt. `.standard` has a
/// `line` border on `surface`; `.primary` is `cursor` with white semibold;
/// `.danger` (also any `.destructive` role) is borderless `err-ink`;
/// `.link` is borderless `cursor-ink`. `height` 28 is the page-header and
/// card-footer size.
public struct KVButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case standard, primary, danger, link }
    var kind: Kind
    var height: CGFloat
    var fontSize: CGFloat
    var horizontalPadding: CGFloat?
    @Environment(\.isEnabled) private var isEnabled

    public init(_ kind: Kind = .standard, height: CGFloat = 24, fontSize: CGFloat = 12, horizontalPadding: CGFloat? = nil) {
        self.kind = kind
        self.height = height
        self.fontSize = fontSize
        self.horizontalPadding = horizontalPadding
    }

    public func makeBody(configuration: Configuration) -> some View {
        let kind = configuration.role == .destructive && self.kind == .standard ? Kind.danger : self.kind
        let shape = RoundedRectangle(cornerRadius: height > 24 ? 7 : 6, style: .continuous)
        configuration.label
            .font(.system(size: fontSize, weight: kind == .primary ? .semibold : .regular))
            .lineLimit(1)
            .foregroundStyle(Self.foreground(kind))
            .padding(.horizontal, horizontalPadding ?? (kind == .link ? 2 : (height > 24 ? 12 : 10)))
            .frame(height: height)
            .background {
                switch kind {
                case .standard: shape.fill(Color.kv.surface)
                case .primary: shape.fill(Color.kv.cursor)
                case .danger, .link: Color.clear
                }
            }
            .overlay {
                if kind == .standard { shape.strokeBorder(Color.kv.line, lineWidth: 1) }
            }
            .contentShape(shape)
            .opacity((isEnabled ? 1 : 0.45) * (configuration.isPressed ? 0.75 : 1))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .fixedSize()
    }

    static func foreground(_ kind: Kind) -> Color {
        switch kind {
        case .standard: Color.kv.text
        case .primary: .white
        case .danger: Color.kv.errInk
        case .link: Color.kv.cursorInk
        }
    }
}

extension ButtonStyle where Self == KVButtonStyle {
    /// Window.dc's row button.
    public static var kv: KVButtonStyle { KVButtonStyle() }
    public static var kvPrimary: KVButtonStyle { KVButtonStyle(.primary) }
    public static var kvLink: KVButtonStyle { KVButtonStyle(.link) }
}
