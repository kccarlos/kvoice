import SwiftUI

/// The trailing Cancel / confirm pair a macOS sheet is expected to have.
///
/// Sheets in this app previously put these in a `.toolbar`, which has no window
/// toolbar to land in, and — more importantly — carried no keyboard shortcuts.
/// A macOS modal is expected to confirm on Return and dismiss on Escape;
/// `.defaultAction` and `.cancelAction` are what provide that, and they also
/// give the confirm button its accent styling for free.
struct SheetButtonBar: View {
    let confirmTitle: String
    let isConfirmEnabled: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    /// Shown when the confirm button is disabled, so the sheet says *why* it
    /// cannot be completed instead of leaving a dead button.
    var disabledReason: String?

    init(
        confirmTitle: String,
        isConfirmEnabled: Bool,
        disabledReason: String? = nil,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.confirmTitle = confirmTitle
        self.isConfirmEnabled = isConfirmEnabled
        self.disabledReason = disabledReason
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    var body: some View {
        HStack(spacing: 12) {
            if let disabledReason, !isConfirmEnabled {
                Text(disabledReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Cannot continue. \(disabledReason)")
            }

            Spacer(minLength: 0)

            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)

            Button(confirmTitle, action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .disabled(!isConfirmEnabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        // Keeps the bar legible when the form scrolls underneath it.
        .background(.bar)
    }
}
