import SwiftUI
import KvoiceDomain

/// The header row of the status menu's Dictation group (P-D3): what the
/// plain "Start Recording  ⌃⇧Space" item drew, plus the recorder's own
/// vocabulary while a job runs — the recording ring, the five-bar meter and
/// the clock — and a thin progress bar while a model installs. Hosted in the
/// Start Recording item's `view` by `StatusMenuHeaderItemView`; this view
/// draws nothing but the row, so the item keeps its title, action and key
/// navigation.
///
/// Layout follows a plain item: the indicator sits in the checkmark column
/// (a plain item's state glyph), the title at the text column, the trailing
/// slot right-aligned where a key equivalent goes. 13 pt is the menu font.
public struct StatusMenuHeaderView: View {
    /// A plain item is 22 pt; the meter and the ring need a little more, and
    /// the extra reads as the "primary control" of a Control Center module
    /// without breaking the menu's rhythm.
    public static let rowHeight: CGFloat = 28
    /// The minimum width the item asks of the menu — enough for the
    /// recording row with its meter and clock; the other items make it
    /// wider in practice ("Model: Whisper large-v3-turbo — Standard ▸").
    public static let minimumWidth: CGFloat = 300

    private let model: StatusMenuHeaderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: StatusMenuHeaderModel) {
        self.model = model
    }

    public var body: some View {
        let state = model.state
        HStack(spacing: 0) {
            indicator(state)
                .frame(width: 16, height: 16)
                .padding(.leading, 5)
            Text(verbatim: state.title)
                .font(.system(size: 13))
                .foregroundStyle(titleColor(state))
                .lineLimit(1)
                .padding(.leading, 4)
            if let badge = state.finishingBadge {
                FinishingBadge(text: badge)
                    .padding(.leading, 6)
            }
            Spacer(minLength: 12)
            trailing(state)
                .padding(.trailing, 14)
        }
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // One element with the row's label: exposed only where the AppKit
        // host does not hide it (the gallery); in the menu, the item's own
        // title is what VoiceOver reads.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
    }

    // MARK: Slots

    @ViewBuilder
    private func indicator(_ state: StatusMenuHeaderState) -> some View {
        switch state.indicator {
        case .idle:
            // Hollow, secondary, static: no accent anywhere in an idle menu.
            RecordingDot(live: false, reduceMotion: reduceMotion, tint: secondaryColor(state), pulses: false)
        case .starting:
            RecordingDot(live: false, reduceMotion: reduceMotion, tint: accentColor, pulses: model.isMenuOpen)
        case .live:
            RecordingDot(live: true, reduceMotion: reduceMotion, tint: accentColor)
        case .working:
            if reduceMotion {
                Image(systemName: "hourglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(secondaryColor(state))
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
        case .attention:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(secondaryColor(state))
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(secondaryColor(state))
        }
    }

    @ViewBuilder
    private func trailing(_ state: StatusMenuHeaderState) -> some View {
        switch state.trailing {
        case .none:
            EmptyView()
        case .shortcut(let glyphs):
            Text(verbatim: glyphs)
                .font(.system(size: 13))
                .foregroundStyle(secondaryColor(state))
                .lineLimit(1)
        case .note(let note):
            Text(verbatim: note)
                .font(.system(size: 12))
                .foregroundStyle(secondaryColor(state))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 240, alignment: .trailing)
        case .meter(let level, let elapsed):
            HStack(spacing: 7) {
                Meter(
                    level: level, reduceMotion: reduceMotion, scale: 0.75,
                    tint: accentColor,
                    inactive: model.isHighlighted ? secondaryColor(state).opacity(0.4) : Color.secondary.opacity(0.25)
                )
                Text(verbatim: HUDViewState.formatElapsed(elapsed))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(secondaryColor(state))
                    .frame(minWidth: 32, alignment: .trailing)
            }
        case .download(let label, let fraction):
            // The bar sits under its label, the way Control Center stacks a
            // value over a slider, so the row needs no more width than the
            // label ("Downloading Whisper large-v3-turbo… 42%").
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: label)
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryColor(state))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .trailing)
                Group {
                    if let fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .frame(width: 120)
            }
        }
    }

    // MARK: Colours

    /// A highlighted menu row draws its text in `selectedMenuItemTextColor`
    /// (white on the accent selection); a disabled one in the disabled
    /// control colour; otherwise the label colour, like every plain item.
    private func titleColor(_ state: StatusMenuHeaderState) -> Color {
        if model.isHighlighted {
            return Color(nsColor: .selectedMenuItemTextColor)
        }
        return state.isEnabled ? Color(nsColor: .labelColor) : Color(nsColor: .disabledControlTextColor)
    }

    /// The accent reads as the recording colour everywhere but on the
    /// accent-coloured highlight, where the dot and the lit bars take the
    /// selected text colour instead.
    private var accentColor: Color {
        model.isHighlighted ? Color(nsColor: .selectedMenuItemTextColor) : .accentColor
    }

    private func secondaryColor(_ state: StatusMenuHeaderState) -> Color {
        if model.isHighlighted {
            return Color(nsColor: .selectedMenuItemTextColor).opacity(0.8)
        }
        return Color(nsColor: .secondaryLabelColor)
    }
}
