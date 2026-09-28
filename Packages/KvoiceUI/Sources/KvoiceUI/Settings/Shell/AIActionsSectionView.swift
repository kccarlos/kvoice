import SwiftUI

/// The AI Actions section (product decision #6): the master switch, the saved
/// AI configurations, the default-action grid, the selected action's mode
/// settings, the Selection Action slots, the user profile, action triggers,
/// and the ⌘1–⌘0 explanation, in one grouped form.
///
/// The app shell depends only on this initializer; the body lives in
/// `AIActionsForm` (`Settings/AIActions/`), which the AI Actions workstream
/// owns.
@MainActor
public struct AIActionsSectionView: View {
    private let ai: AISettingsViewModel
    private let modes: PromptModeSettingsViewModel
    private let availability: SettingsAvailabilityModel

    public init(
        ai: AISettingsViewModel,
        modes: PromptModeSettingsViewModel,
        availability: SettingsAvailabilityModel = .init()
    ) {
        self.ai = ai
        self.modes = modes
        self.availability = availability
    }

    public var body: some View {
        AIActionsForm(configurations: ai, actions: modes, availability: availability)
    }
}
