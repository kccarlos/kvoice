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
        PermissionRowCard(
            glyph: KVGlyphs.keys,
            tileFill: .grey,
            name: ShortcutCard.title,
            text: card.status == .registered && card.readout != nil
                ? String(localized: "\(card.readout ?? "") is registered with macOS.", bundle: .module)
                : ShortcutCard.rationale,
            hint: card.failureDescription,
            statusLabel: card.status.displayName,
            tone: card.status == .registered ? .ok : (card.status == .unavailable ? .warn : .neutral),
            action: .init(
                title: card.action.title,
                isPrimary: card.status != .registered,
                isInProgress: false,
                hint: card.action == .confirmRecommended
                    ? String(localized: "Confirms the recommended shortcut. It is not active until it is confirmed.", bundle: .module)
                    : String(localized: "Opens the shortcut recorder to pick a different key.", bundle: .module),
                perform: onAction
            ),
            checked: lastCheckedDescription
        )
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
