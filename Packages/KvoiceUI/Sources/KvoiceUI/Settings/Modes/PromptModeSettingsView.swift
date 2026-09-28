import KvoiceDomain
import SwiftUI

/// The actions half of the AI Actions section on its own: the default-action
/// grid, Add / Reset, and the editor sheet.
///
/// Settings hosts `AIActionsSectionView`, which shows this together with the
/// configurations. This view remains for hosts that only need the grid (and
/// for callers written against the old Modes tab).
@MainActor
public struct PromptModeSettingsView: View {
    /// Injected by the app shell, so `@Bindable` rather than `@StateObject` —
    /// see the note in `GeneralSettingsView`.
    @Bindable private var viewModel: PromptModeSettingsViewModel

    @State private var editing: EditorTarget?
    @State private var draft = PromptModeDraft()
    /// The user-made action awaiting delete confirmation. Its prompt is gone
    /// for good, so the dialog says what is kept.
    @State private var modePendingDeletion: PromptMode?
    @State private var isConfirmingResetAll = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum EditorTarget: Identifiable {
        case new
        case existing(UUID)

        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let id): return id.uuidString
            }
        }
    }

    /// ADR-026: handed to the action editor so the selected-text switch
    /// follows the edition; the default (everything enabled) is what
    /// previews see.
    private let availability: SettingsAvailabilityModel

    public init(viewModel: PromptModeSettingsViewModel = .init(), availability: SettingsAvailabilityModel = .init()) {
        self.availability = availability
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            Section {
                AIActionGrid(
                    actions: viewModel.modes,
                    defaultID: viewModel.activeModeID,
                    badge: { viewModel.shortcutBadge(for: $0.id) },
                    onSelect: { viewModel.selectMode(id: $0.id) },
                    onEdit: { mode in
                        draft = PromptModeDraft(mode: mode)
                        viewModel.clearPreview()
                        editing = .existing(mode.id)
                    },
                    onDuplicate: { viewModel.duplicateMode(id: $0.id) },
                    onDelete: { modePendingDeletion = $0 },
                    onReset: { viewModel.resetBuiltIn(id: $0.id) }
                )

                HStack {
                    Button("Add Action…") {
                        draft = PromptModeDraft()
                        editing = .new
                    }
                    Spacer()
                    Button("Reset Built-in Actions…") { isConfirmingResetAll = true }
                        .accessibilityHint("Restores every shipped action's text and trigger words and adds back any that is missing.")
                }
            } header: {
                Text("Default Action")
            } footer: {
                Text(viewModel.isEnabled
                    ? "The default action runs after each transcription. Click to set the default; double-click to edit; right-click for more."
                    : "AI Actions is off; the default action is remembered for when it is turned on in the AI Actions section.")
            }
        }
        .formStyle(.grouped)
        .animation(reduceMotion ? nil : .default, value: viewModel.modes)
        // Sizing belongs to the host window, not the tab content.
        .navigationTitle("Actions")
        .sheet(item: $editing) { target in
            AIActionEditorView(
                viewModel: viewModel,
                draft: $draft,
                isBuiltIn: isBuiltIn(target),
                availability: availability,
                onSave: { save(target) },
                onCancel: {
                    viewModel.clearPreview()
                    editing = nil
                }
            )
        }
        .confirmationDialog(
            "Delete “\(modePendingDeletion?.menuTitle ?? "")”?",
            isPresented: Binding(
                get: { modePendingDeletion != nil },
                set: { if !$0 { modePendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: modePendingDeletion
        ) { mode in
            Button("Delete Action", role: .destructive) {
                viewModel.deleteMode(id: mode.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its instructions are removed and cannot be restored. Built-in actions, your other actions, and the AI endpoint are kept.")
        }
        .confirmationDialog(
            "Reset all built-in actions?",
            isPresented: $isConfirmingResetAll,
            titleVisibility: .visible
        ) {
            Button("Reset Built-in Actions", role: .destructive) {
                viewModel.resetAllBuiltIns()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every built-in action goes back to its shipped title, instructions, and trigger words, and any that was missing is added. Your own actions and mode settings are kept.")
        }
    }

    private func isBuiltIn(_ target: EditorTarget) -> Bool {
        switch target {
        case .new:
            return false
        case .existing(let id):
            return viewModel.modes.first { $0.id == id }?.isBuiltIn ?? false
        }
    }

    private func save(_ target: EditorTarget) {
        switch target {
        case .new:
            _ = viewModel.addMode(draft)
        case .existing(let id):
            viewModel.updateMode(id: id, from: draft)
        }
        viewModel.clearPreview()
        editing = nil
    }
}
