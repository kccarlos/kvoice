import SwiftUI
import KvoiceDomain

/// The General page on its own (spec D.6 § 1), for previews and tests. The
/// main window shows the same `GeneralSectionView` as its General section.
@MainActor
public struct GeneralSettingsView: View {
    /// `@Bindable`, not `@StateObject`: the app shell owns this model and hands
    /// it in. `StateObject(wrappedValue:)` captures whatever instance it sees
    /// first and silently ignores every later one, so an injected model stored
    /// that way stops reflecting the shell's state.
    @Bindable private var viewModel: GeneralSettingsViewModel
    private let backup: BackupSettingsViewModel

    public init(viewModel: GeneralSettingsViewModel = .init(), backup: BackupSettingsViewModel = .init()) {
        self.viewModel = viewModel
        self.backup = backup
    }

    public var body: some View {
        GeneralSectionView(viewModel: viewModel, backup: backup)
            // No fixed frame: the host window sizes itself.
            .navigationTitle("General")
    }

    #if DEBUG
    /// Both states matter: the button changes meaning once a shortcut exists.
    static func previewModel(withShortcut: Bool) -> GeneralSettingsViewModel {
        let model = GeneralSettingsViewModel()
        if withShortcut {
            model.confirmRecommendedShortcut()
        }
        return model
    }
    #endif
}
