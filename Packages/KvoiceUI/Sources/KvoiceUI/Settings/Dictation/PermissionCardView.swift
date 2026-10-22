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
        let action = card.action()
        let needsAction = action != .refresh || deepLinkFailed
        PermissionRowCard(
            glyph: card.kind == .microphone ? KVGlyphs.mic : KVGlyphs.access,
            tileFill: card.kind == .microphone ? .voice : .ok,
            name: card.kind.title,
            text: card.rationale,
            hint: card.kind == .accessibility && presented != .granted
                ? String(localized: "Until it’s on, text is copied to the clipboard instead.", bundle: .module)
                : nil,
            note: card.showsSystemSettingsPath() || deepLinkFailed
                ? (deepLinkFailed
                    ? String(localized: "System Settings could not be opened automatically. Go to \(card.kind.systemSettingsPath) and enable KVoice.", bundle: .module)
                    : String(localized: "If the button does not open the right pane: \(card.kind.systemSettingsPath).", bundle: .module))
                : nil,
            statusLabel: presented.displayName,
            tone: presented == .granted ? .ok : (presented == .notRequested || presented == .unknown ? .neutral : .warn),
            action: needsAction ? .init(
                title: actionTitle ?? action.title,
                isPrimary: action != .refresh,
                isInProgress: isActionInProgress,
                hint: actionHint,
                perform: onAction
            ) : nil,
            checked: lastCheckedDescription
        )
    }

    private var stateBadge: some View {
        StatusPill(text: presented.displayName, tone: tone.kvTone, filled: true)
            .accessibilityLabel("\(card.kind.title) status")
            .accessibilityValue(presented.displayName)
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
