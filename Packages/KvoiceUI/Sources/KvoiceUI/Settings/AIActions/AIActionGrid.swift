import KvoiceDomain
import SwiftUI

/// The Default action grid, drawn to Window.dc (UI v2 fidelity F3b): four
/// equal columns 8 pt apart, one tile per action. Click selects, double-click
/// edits, right-click offers Edit / Set as Default / Duplicate / Delete /
/// Reset. Each tile takes keyboard focus: Space sets it as the default,
/// Return edits it.
@MainActor
struct AIActionGrid: View {
    let actions: [PromptMode]
    let defaultID: UUID?
    let badge: (PromptMode) -> String?
    let onSelect: (PromptMode) -> Void
    let onEdit: (PromptMode) -> Void
    let onDuplicate: (PromptMode) -> Void
    let onDelete: (PromptMode) -> Void
    let onReset: (PromptMode) -> Void

    /// Window.dc: `grid-template-columns: repeat(4, minmax(0, 1fr))`.
    static let columns = 4
    @FocusState private var focused: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if actions.isEmpty {
            Text("No actions yet. Add one, or reset the built-in actions.")
                .font(.system(size: 12))
                .foregroundStyle(Color.kv.text2)
        } else {
            KVAutoFitGrid(minimumColumnWidth: 0, spacing: 8, fixedColumns: Self.columns) {
                ForEach(actions) { action in
                    tile(action)
                }
            }
            .animation(KVControlMotion.stateChange(reduceMotion: reduceMotion), value: defaultID)
        }
    }

    private func tile(_ action: PromptMode) -> some View {
        AIActionCard(
            action: action,
            isDefault: action.id == defaultID,
            badge: badge(action),
            isFocused: focused == action.id
        )
        .focusable()
        .focused($focused, equals: action.id)
        .focusEffectDisabled()
        // The double-click gesture is declared first so a double-click
        // does not also fire two single-click selects.
        .onTapGesture(count: 2) { onEdit(action) }
        .onTapGesture(count: 1) {
            focused = action.id
            if action.isUsable { onSelect(action) }
        }
        .onKeyPress(.space) {
            if action.isUsable { onSelect(action) }
            return .handled
        }
        .onKeyPress(.return) {
            onEdit(action)
            return .handled
        }
        .contextMenu {
            Button("Edit…") { onEdit(action) }
            Button("Set as Default") { onSelect(action) }
                .disabled(action.id == defaultID || !action.isUsable)
            Button("Duplicate") { onDuplicate(action) }
            if action.isBuiltIn {
                Button("Reset to Shipped Text") { onReset(action) }
                    .disabled(!action.isRevisedBuiltIn)
            } else {
                Divider()
                Button("Delete…", role: .destructive) { onDelete(action) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: action))
        .accessibilityHint("Double-tap to set as default. Actions menu offers Edit, Duplicate, and more.")
        .accessibilityAddTraits(action.id == defaultID ? [.isSelected, .isButton] : .isButton)
        .accessibilityValue(Text(verbatim: KVAccessibility.selectionValue(action.id == defaultID)))
        .accessibilityAction { if action.isUsable { onSelect(action) } }
        .accessibilityAction(named: "Set as Default") { onSelect(action) }
        .accessibilityAction(named: "Edit") { onEdit(action) }
        .accessibilityAction(named: "Duplicate") { onDuplicate(action) }
    }

    private func accessibilityLabel(for action: PromptMode) -> String {
        var parts = [action.displayTitle]
        if !action.displaySummary.isEmpty { parts.append(action.displaySummary) }
        if let badge = badge(action) { parts.append(badge) }
        if action.id == defaultID { parts.append(String(localized: "default action", bundle: .module)) }
        if action.isRevisedBuiltIn { parts.append(String(localized: "edited built-in", bundle: .module)) }
        if !action.isUsable { parts.append(String(localized: "incomplete", bundle: .module)) }
        return parts.joined(separator: ", ")
    }
}

/// One action tile (Window.dc `actions`): padding 10, radius 10; the
/// default on `cursor-soft` with a 2 pt `cursor` border, the others on
/// `surface` with a 1 pt `line` border (1 pt margin, so both are the same
/// size). A 22 pt radius-6 tile — `cursor` for the default, `grey`
/// otherwise — holds the action's own emoji (user data; the design draws
/// line glyphs), the ⌘ number in 10 pt mono at the right, then the 13 pt
/// title and the 11 pt description.
@MainActor
struct AIActionCard: View {
    let action: PromptMode
    let isDefault: Bool
    let badge: String?
    var isFocused = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                iconTile
                Spacer(minLength: 4)
                if let badge {
                    Text(verbatim: badge)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.kv.text2)
                        .accessibilityHidden(true)
                }
            }
            Text(verbatim: action.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.kv.text)
                .lineLimit(1)
            Text(verbatim: action.displaySummary)
                .font(.system(size: 11))
                .foregroundStyle(Color.kv.text2)
                .lineSpacing(1.5)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if action.isRevisedBuiltIn || !action.isUsable {
                HStack(spacing: 4) {
                    if action.isRevisedBuiltIn {
                        Text("edited")
                            .foregroundStyle(Color.kv.text2)
                    }
                    if !action.isUsable {
                        StatusLabel(String(localized: "incomplete", bundle: .module), symbol: "exclamationmark.circle.fill", tone: .attention)
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.system(size: 10))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDefault ? Color.kv.cursorSoft : Color.kv.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(border, lineWidth: isDefault || isFocused ? 2 : (contrast == .increased ? 1.5 : 1))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var border: Color {
        if isDefault { return Color.kv.cursor }
        if isFocused { return Color.kv.cursor.opacity(0.6) }
        return contrast == .increased ? Color.kv.text2 : Color.kv.line
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isDefault ? Color.kv.cursor : Color.kv.grey)
            .frame(width: 22, height: 22)
            .overlay {
                if action.icon.isEmpty {
                    Image(systemName: action.behavior == .translate ? "globe" : "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text(verbatim: action.icon)
                        .font(.system(size: 12))
                }
            }
            .accessibilityHidden(true)
    }
}
