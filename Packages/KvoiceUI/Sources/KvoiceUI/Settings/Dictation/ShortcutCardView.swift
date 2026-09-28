import SwiftUI
import KvoiceDomain

/// The Keyboard Shortcut card, laid out like `PermissionCardView` so the
/// three prerequisites on the Permissions section read as one set.
@MainActor
struct ShortcutCardView: View {
    let card: ShortcutCard
    let onAction: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(ShortcutCard.title, systemImage: ShortcutCard.symbolName)
                        .font(.headline)
                    Spacer()
                    StatusLabel(card.status.displayName, symbol: symbolName, tone: tone)
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.medium))
                        .accessibilityLabel("\(ShortcutCard.title) status")
                        .accessibilityValue(card.status.displayName)
                }

                Text(ShortcutCard.rationale)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let readout = card.readout {
                    SettingsFactRow("Shortcut", readout)
                }

                if let failure = card.failureDescription {
                    StatusLabel(failure, symbol: "exclamationmark.triangle.fill", tone: .attention)
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Shortcut problem: \(failure)")
                }

                HStack(alignment: .firstTextBaseline) {
                    Button(card.action.title) {
                        onAction()
                    }
                    .accessibilityLabel("\(card.action.title) for \(ShortcutCard.title)")
                    .accessibilityHint(card.action == .confirmRecommended
                        ? "Confirms the recommended shortcut. It is not active until it is confirmed."
                        : "Opens the shortcut recorder to pick a different key.")

                    // P-M9 (2026-09-16): the card's own refresh button was
                    // dropped — the page refreshes itself every second and
                    // offers one Refresh in its footer (M9).
                    Spacer()

                    Text(lastCheckedDescription)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Last checked: \(lastCheckedDescription)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: card.status)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(ShortcutCard.title), \(card.status.displayName)")
    }

    private var symbolName: String {
        switch card.status {
        case .registered: return "checkmark.circle.fill"
        case .unavailable: return "xmark.octagon.fill"
        case .notConfigured: return "circle.dashed"
        case .notRegistered: return "questionmark.circle"
        }
    }

    private var tone: StatusTone {
        switch card.status {
        case .registered: return .positive
        case .unavailable: return .attention
        case .notConfigured, .notRegistered: return .neutral
        }
    }

    private var lastCheckedDescription: String {
        guard let lastChecked = card.lastChecked else { return String(localized: "Not checked yet", bundle: .module) }
        return String(localized: "Checked \(lastChecked.formatted(date: .omitted, time: .standard))", bundle: .module)
    }
}
