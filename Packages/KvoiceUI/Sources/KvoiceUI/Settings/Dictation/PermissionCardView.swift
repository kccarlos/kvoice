import SwiftUI
import KvoiceDomain

/// One D.9 permission card: state badge, rationale, last-checked time, and a
/// single action. Shared by the Dictation tab and onboarding.
@MainActor
struct PermissionCardView: View {
    let card: PermissionCard
    /// When the deep link failed, the written path is promoted to the main
    /// instruction rather than a footnote.
    var deepLinkFailed = false
    /// Overrides the card's own action, for hosts that want to offer a
    /// different single action (onboarding offers Allow rather than Request).
    var actionTitle: String? = nil
    /// True while the action is running; the button is disabled and shows a
    /// spinner so a second press cannot queue a second prompt.
    var isActionInProgress = false
    let onAction: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presented: PermissionCardState {
        card.presentedState()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(card.kind.title, systemImage: card.kind.symbolName)
                        .font(.headline)
                    Spacer()
                    stateBadge
                }

                Text(card.rationale)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if card.showsSystemSettingsPath() || deepLinkFailed {
                    Text(deepLinkFailed
                        ? "System Settings could not be opened automatically. Go to \(card.kind.systemSettingsPath) and enable KVoice."
                        : "If the button does not open the right pane: \(card.kind.systemSettingsPath).")
                        .font(.caption)
                        .foregroundStyle(deepLinkFailed ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Written path: \(card.kind.systemSettingsPath)")
                }

                HStack(alignment: .firstTextBaseline) {
                    Button(actionTitle ?? card.action().title) {
                        onAction()
                    }
                    .disabled(isActionInProgress)
                    .accessibilityLabel("\(actionTitle ?? card.action().title) for \(card.kind.title)")
                    .accessibilityHint(actionHint)

                    if isActionInProgress {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Waiting for macOS")
                    }

                    // P-M9 (2026-09-16): the card's own refresh button was
                    // dropped — the page refreshes itself every second and
                    // offers one Refresh in its footer instead of one per
                    // card (M9: "a page that refreshes itself").
                    Spacer()

                    Text(lastCheckedDescription)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Last checked: \(lastCheckedDescription)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: presented)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isActionInProgress)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(card.kind.title) permission, \(presented.displayName)")
    }

    private var stateBadge: some View {
        StatusLabel(presented.displayName, symbol: symbolName, tone: tone)
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.medium))
            .accessibilityLabel("\(card.kind.title) status")
            .accessibilityValue(presented.displayName)
    }

    private var symbolName: String {
        switch presented {
        case .granted: return "checkmark.circle.fill"
        case .denied, .restricted: return "xmark.octagon.fill"
        case .notRequested: return "circle.dashed"
        case .unknown: return "questionmark.circle"
        }
    }

    private var tone: StatusTone {
        switch presented {
        case .granted: return .positive
        case .denied, .restricted: return .attention
        case .notRequested, .unknown: return .neutral
        }
    }

    private var actionHint: String {
        switch card.action() {
        case .request:
            return String(localized: "Shows the macOS permission prompt. Nothing is requested until you press this.", bundle: .module)
        case .openSystemSettings:
            return String(localized: "Opens \(card.kind.systemSettingsPath). A permission macOS has already refused cannot be prompted again.", bundle: .module)
        case .refresh:
            return "Reads the current permission state again without prompting."
        }
    }

    private var lastCheckedDescription: String {
        guard let lastChecked = card.lastChecked else { return String(localized: "Not checked yet", bundle: .module) }
        return String(localized: "Checked \(lastChecked.formatted(date: .omitted, time: .standard))", bundle: .module)
    }
}
