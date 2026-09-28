import KvoiceDomain
import SwiftUI

/// The Default Action grid: one card per action with its icon, title, and
/// ⌘-badge. Click selects, double-click edits, right-click offers Edit / Set
/// as Default / Duplicate / Delete / Reset.
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

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)]

    var body: some View {
        if actions.isEmpty {
            Text("No actions yet. Add one, or reset the built-in actions.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(actions) { action in
                    AIActionCard(
                        action: action,
                        isDefault: action.id == defaultID,
                        badge: badge(action)
                    )
                    // The double-click gesture is declared first so a
                    // double-click does not also fire two single-click selects.
                    .onTapGesture(count: 2) { onEdit(action) }
                    .onTapGesture(count: 1) { onSelect(action) }
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
                    .accessibilityAction(named: "Set as Default") { onSelect(action) }
                    .accessibilityAction(named: "Edit") { onEdit(action) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func accessibilityLabel(for action: PromptMode) -> String {
        var parts = [action.menuTitle]
        if let badge = badge(action) { parts.append(badge) }
        if action.id == defaultID { parts.append(String(localized: "default action", bundle: .module)) }
        if action.isRevisedBuiltIn { parts.append(String(localized: "edited built-in", bundle: .module)) }
        return parts.joined(separator: ", ")
    }
}

@MainActor
struct AIActionCard: View {
    let action: PromptMode
    let isDefault: Bool
    let badge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                iconView
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .accessibilityHidden(true)
                }
            }
            Text(action.menuTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(action.summary.isEmpty ? " " : action.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
            HStack(spacing: 4) {
                if isDefault {
                    Label("Default", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
                if action.isRevisedBuiltIn {
                    Text("edited")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !action.isUsable {
                    StatusLabel(String(localized: "incomplete", bundle: .module), symbol: "exclamationmark.circle.fill", tone: .attention)
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                }
            }
            .frame(height: 14)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isDefault ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isDefault ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isDefault ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var iconView: some View {
        if action.icon.isEmpty {
            Image(systemName: action.behavior == .translate ? "globe" : "sparkles")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else {
            Text(action.icon)
                .font(.title2)
                .accessibilityHidden(true)
        }
    }
}
