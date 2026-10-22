import SwiftUI

/// UI v2 **Keycap**: one key of a shortcut, the same component everywhere a
/// shortcut is shown. `.regular` is the design's 24 pt cap; `.compact` fits
/// a menu-panel row.
struct Keycap: View {
    enum Size {
        case regular
        /// The status panel's 22 pt cap, in the panel's own key colours
        /// (`PanelColor`, Panel.dc.html).
        case medium
        case compact
        /// The setup wizard's shortcut box: a 36 pt cap with a 2 pt base.
        /// `held` sinks it onto its base in the voice tint (Motion § 11).
        case large
        /// A cap drawn on the ink hero (Welcome): ink-2 with white type.
        case onInk
    }

    let key: String
    var size: Size = .regular
    /// The wizard's Try It check: the key is being held (`.large` only).
    var held = false
    var reduceMotion = true

    var body: some View {
        Text(verbatim: key)
            .font(.system(size: metrics.font, weight: size == .compact ? .medium : .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, metrics.padding)
            .frame(minWidth: metrics.side, minHeight: metrics.side, maxHeight: size == .medium ? metrics.side : nil)
            .background(fill, in: shape)
            .overlay {
                if size != .onInk {
                    shape.strokeBorder(line, lineWidth: 1)
                }
            }
            .background {
                // The design's raised base: a 2 pt shadow line under the cap.
                if size == .large || size == .onInk {
                    shape.fill(size == .onInk ? Color.black.opacity(0.45) : Color.kv.keyLine).offset(y: 2).opacity(isHeld ? 0 : 1)
                }
            }
            .offset(y: isHeld && !reduceMotion ? 2 : 0)
            .fixedSize()
    }

    private var isHeld: Bool { held && size == .large }

    private var fill: Color {
        switch size {
        case .onInk: return Color.kv.ink2
        case .medium: return PanelColor.key
        case .regular, .compact, .large: return isHeld ? Color.kv.voiceSoft : Color.kv.key
        }
    }

    private var line: Color {
        if size == .medium { return PanelColor.keyLine }
        return isHeld ? Color.kv.voice : Color.kv.keyLine
    }

    private var foreground: Color {
        switch size {
        case .compact: return Color.kv.text2
        case .onInk: return .white
        case .regular, .medium, .large: return Color.kv.text
        }
    }

    private var metrics: (font: CGFloat, padding: CGFloat, side: CGFloat, radius: CGFloat) {
        switch size {
        case .regular: return (12, 6, 24, KVRadius.control)
        // A word key ("Space") sets a size smaller, as in the design.
        case .medium: return (key.count > 2 ? 10 : 11, key.count > 2 ? 7 : 5, 22, 5)
        case .compact: return (10, 4, 16, 4)
        case .large: return (15, 10, 36, 8)
        case .onInk: return (key.count > 2 ? 12 : 13, key.count > 2 ? 10 : 7, 28, 7)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.radius, style: .continuous)
    }
}

/// A row of `Keycap`s read by VoiceOver as one shortcut ("⌃⇧Space"). The
/// status panel (`.medium`), the Shortcuts page, the panel's rows
/// (`.compact`) and the wizard's shortcut box (`.large`, `held`) all draw
/// their keys through it.
struct Keycaps: View {
    let keys: [String]
    var size: Keycap.Size = .regular
    var held = false
    var reduceMotion = true

    init(_ keys: [String], size: Keycap.Size = .regular, held: Bool = false, reduceMotion: Bool = true) {
        self.keys = keys
        self.size = size
        self.held = held
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        HStack(spacing: size == .compact ? 2 : size == .medium ? 3 : size == .large ? 6 : 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Keycap(key: key, size: size, held: held, reduceMotion: reduceMotion)
            }
        }
        .padding(.bottom, size == .large ? 2 : 0)
        .animation(
            size == .large ? (reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.15, dampingFraction: 0.7)) : nil,
            value: held
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: keys.joined()))
    }
}

/// UI v2 **Mode chip**: an AI action (or "AI off") the same way in the
/// panel, the HUD and settings — a capsule, cursor-soft with cursor-ink text
/// when the action will run, neutral fill when it will not. Also the HUD's
/// "1 finishing" badge, which is the same capsule without a symbol. A
/// label, never a control.
struct ModeChip: View {
    let text: String
    var symbolName: String?
    var isActive = true
    var shortcut: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(verbatim: text)
                .lineLimit(1)
                .truncationMode(.tail)
            if let shortcut {
                Text(verbatim: shortcut)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(isActive ? Color.kv.cursorInk : Color.kv.text2)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(isActive ? Color.kv.cursorSoft : Color.kv.fill, in: Capsule(style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
    }
}

/// UI v2 **Status pill**: a status is always a dot *and* words, never colour
/// alone. The dot carries the tone's solid colour; the words stay secondary
/// for a good state (ready, granted) and take the tone's ink, semibold, for
/// one that asks something of the user. A label, never a control.
struct StatusPill: View {
    let text: String
    var tone: KVTone = .ok
    var size: CGFloat = 11
    /// The chip form (UI v2 wave 3, the setup wizard's cards): a 24 pt
    /// capsule in the tone's soft shade, the words in its ink, semibold, for
    /// every tone — the capsule already sets it apart from body text.
    var filled = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Self.dotToken(for: tone).color)
                .frame(width: 7, height: 7)
            Text(verbatim: text)
                .font(.system(size: filled ? 12 : size, weight: filled || Self.isEmphasized(tone) ? .semibold : .regular))
                .foregroundStyle(Self.textToken(for: tone, filled: filled).color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, filled ? 10 : 0)
        .frame(height: filled ? 24 : nil)
        .background {
            if filled {
                Capsule(style: .continuous).fill(tone.soft.color)
            }
        }
        .fixedSize(horizontal: filled, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
    }

    static func dotToken(for tone: KVTone) -> KVColorToken { tone.solid }

    static func textToken(for tone: KVTone, filled: Bool = false) -> KVColorToken {
        filled || isEmphasized(tone) ? tone.ink : .text2
    }

    /// Ready and neutral read quietly; voice, cursor, warn and err speak up.
    static func isEmphasized(_ tone: KVTone) -> Bool {
        tone != .ok && tone != .neutral
    }
}

/// UI v2 **Primary button**: the one blue button of a screen (the setup
/// wizard's footer). Cursor ground with white semibold type; disabled, it
/// drops to the neutral fill with secondary type, so a disabled primary
/// never reads as blue. Drawn rather than `.borderedProminent`, which turns
/// grey whenever its window is not key — the design's footer always shows
/// which button Return presses.
struct KVPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.white : Color.kv.text2)
            .padding(.horizontal, 18)
            .frame(height: 32)
            .background(
                Self.ground(isEnabled: isEnabled).color.opacity(configuration.isPressed ? 0.8 : 1),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    static func ground(isEnabled: Bool) -> KVColorToken {
        isEnabled ? .cursor : .fill
    }
}
