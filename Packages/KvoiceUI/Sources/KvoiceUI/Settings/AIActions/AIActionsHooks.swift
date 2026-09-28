import SwiftUI

/// Seams the app shell fills in for the AI Actions section.
///
/// The section lives in `KvoiceUI`, which does not depend on the hotkey
/// adapter, so the KeyboardShortcuts recorder for the Selection Action slots
/// is supplied by the shell (`SelectionActionShortcuts` in `KvoiceHotkeys`
/// provides a ready-made view). Every hook has a default so previews and tests
/// render without the shell.
@MainActor
public enum AIActionsHooks {
    /// Returns the recorder control for a Selection Action slot (0-based).
    /// The default is a placeholder that explains the shortcut is set by the app.
    public static var selectionActionShortcutRecorder: (Int) -> AnyView = { _ in
        AnyView(
            Text("Shortcut recorder unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
        )
    }

    /// A one-line description of the shortcut bound to a slot ("⌥⇧1"), or
    /// `nil` when none is recorded. Used for the row's accessibility value.
    public static var selectionActionShortcutDescription: (Int) -> String? = { _ in nil }

    /// ADR-027: presents the system's "raise your Private Cloud Compute
    /// limit" UI (`limitIncreaseSuggestion.show()` behind the adapter).
    /// Wired by the shell in `AppDelegate+AIActions.swift`
    /// (`installAIActions()`) to `privateCloudComputeClient
    /// .showQuotaIncreaseOptions()` followed by a fact refresh. The default
    /// does nothing.
    public static var showPrivateCloudComputeQuotaOptions: () -> Void = {}
}
