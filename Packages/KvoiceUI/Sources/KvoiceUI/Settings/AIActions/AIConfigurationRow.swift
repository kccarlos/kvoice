import KvoiceDomain
import SwiftUI

/// One "Where AI runs" row (Window.dc `configs`, UI v2 fidelity F3b):
/// padding 9/14, a 16 pt radio — the active one a `cursor` disc with a
/// 6 pt white dot, the others a 1.5 pt `line` ring — the 13 pt semibold
/// name over the 11 pt sub-line, the This Mac (ok) / Cloud (warn) chip,
/// and Edit. Clicking the row, or Space / Return while it has keyboard
/// focus, makes it active; Delete (or the context menu, or VoiceOver's
/// Delete action) asks to delete it. A row whose Apple model is
/// unavailable cannot be chosen and says why in its sub-line.
@MainActor
struct AIConfigurationRow: View {
    let configuration: AIConfiguration
    let isActive: Bool
    let subtitle: String
    let subtitleNeedsAttention: Bool
    let unavailableReason: String?
    let showsQuotaOptions: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var canSelect: Bool { !isActive && unavailableReason == nil }

    var body: some View {
        HStack(spacing: 12) {
            identity
            if showsQuotaOptions {
                // ADR-027: Apple's own "raise your limit" UI, only when offered.
                Button("Show Options…") { AIActionsHooks.showPrivateCloudComputeQuotaOptions() }
                    .help("Apple's options for a higher Private Cloud Compute limit.")
            }
            Button("Edit") { onEdit() }
                .accessibilityLabel("Edit \(configuration.menuTitle)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            if focused {
                Rectangle().fill(Color.kv.select)
            }
        }
        .contextMenu {
            Button("Set as Active") { onSelect() }
                .disabled(!canSelect)
            Button("Edit…") { onEdit() }
            Divider()
            Button("Delete…", role: .destructive) { onDelete() }
        }
    }

    private var identity: some View {
        HStack(spacing: 12) {
            radio
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: configuration.menuTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.kv.text)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(subtitleNeedsAttention ? Color.kv.warnInk : Color.kv.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            placementChip
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onTapGesture {
            focused = true
            if canSelect { onSelect() }
        }
        .onKeyPress(keys: [.space, .return]) { _ in
            if canSelect { onSelect() }
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            onDelete()
            return .handled
        }
        .help(Text(verbatim: unavailableReason ?? String()))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: configuration.menuTitle))
        .accessibilityValue(Text(verbatim: [isActive ? String(localized: "active", bundle: .module) : nil, subtitle, placementTitle].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(Text("Makes this the configuration every action uses.", bundle: .module))
        .accessibilityAction { if canSelect { onSelect() } }
        .accessibilityAction(named: Text("Set \(configuration.menuTitle) as active", bundle: .module)) { if canSelect { onSelect() } }
        .accessibilityAction(named: Text("Delete \(configuration.menuTitle)", bundle: .module)) { onDelete() }
    }

    private var radio: some View {
        ZStack {
            if isActive {
                Circle().fill(Color.kv.cursor)
                Circle().fill(.white).frame(width: 6, height: 6)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Circle().strokeBorder(contrast == .increased ? Color.kv.text2 : Color.kv.line, lineWidth: 1.5)
            }
        }
        .frame(width: 16, height: 16)
        .opacity(unavailableReason != nil && !isActive ? 0.45 : 1)
        .overlay {
            if focused {
                Circle().strokeBorder(Color.kv.cursor.opacity(0.6), lineWidth: 2).padding(-3)
            }
        }
        .animation(KVControlMotion.stateChange(reduceMotion: reduceMotion), value: isActive)
        .accessibilityHidden(true)
    }

    private var placementTitle: String {
        configuration.runsOnThisMac
            ? String(localized: "This Mac", bundle: .module)
            : String(localized: "Cloud", bundle: .module)
    }

    /// This Mac (ok) when the request stays here; Cloud (warn) when it
    /// leaves — including Apple's Private Cloud Compute.
    private var placementChip: some View {
        KVChip(placementTitle, tone: configuration.runsOnThisMac ? .ok : .warn, dot: false)
            .help(configuration.runsOnThisMac
                ? Text("Requests stay on this Mac.", bundle: .module)
                : Text("Requests leave this Mac: the transcript is sent over the network.", bundle: .module))
    }
}
