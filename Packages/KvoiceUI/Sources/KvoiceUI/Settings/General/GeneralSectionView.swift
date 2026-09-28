import SwiftUI
import KvoiceAppCore
import KvoiceDomain

/// The General section: how kvoice appears on this Mac (Dock, Launch at
/// Login), the interface language, the setup guide, and the reset tools
/// (Reset Preferences, Restart) that used to live under Help. One grouped
/// form, destructive actions last.
///
/// `help` carries the shell routes for Reset Preferences and Restart
/// (`HelpActions`); the default is a no-op model so previews and tests
/// render the rows without a shell.
///
/// No modifier sits on a `Section` itself: `Form` applies a modifier on a
/// section to every row, so the `.task`, `.onReceive`, and the confirmation
/// dialogs are attached to single rows instead.
@MainActor
public struct GeneralSectionView: View {
    @Bindable private var viewModel: GeneralSettingsViewModel
    @Bindable private var backup: BackupSettingsViewModel
    private let help: HelpViewModel

    @State private var isConfirmingResetOnboarding = false
    @State private var isConfirmingResetPreferences = false
    @State private var isConfirmingRestart = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        viewModel: GeneralSettingsViewModel = .init(),
        backup: BackupSettingsViewModel = .init(),
        help: HelpViewModel = .init()
    ) {
        self.viewModel = viewModel
        self.backup = backup
        self.help = help
    }

    public var body: some View {
        Form {
            appearanceSection
            languageSection
            memorySection
            backupSection
            setupSection
            troubleshootingSection
        }
        .formStyle(.grouped)
    }

    // MARK: Appearance and startup

    private var appearanceSection: some View {
        Section {
            Toggle("Show KVoice in Dock", isOn: $viewModel.showDockIcon)
                .accessibilityLabel("Show KVoice in Dock")
                .accessibilityHint("When enabled, KVoice appears in the Dock as well as the menu bar. The menu-bar item is always shown.")

            Toggle("Launch at Login", isOn: $viewModel.launchAtLogin)
                .accessibilityLabel("Launch at Login")
                .accessibilityHint("Registers KVoice as a login item through macOS. The status below is what macOS reports.")
                .task {
                    // The user can approve or remove the login item in System
                    // Settings at any time, so the section reads the real
                    // status when it appears.
                    viewModel.refreshLaunchAtLoginStatus()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    viewModel.refreshLaunchAtLoginStatus()
                }

            LabeledContent("Login item status") {
                if viewModel.launchAtLoginNeedsApproval {
                    StatusLabel(viewModel.launchAtLoginStatus.displayName, symbol: "exclamationmark.triangle.fill", tone: .attention)
                        .labelStyle(.titleAndIcon)
                } else {
                    Text(viewModel.launchAtLoginStatus.displayName)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Login item status")
            .accessibilityValue(viewModel.launchAtLoginStatus.displayName)
            .animation(reduceMotion ? nil : .default, value: viewModel.launchAtLoginStatus)

            if viewModel.launchAtLoginNeedsApproval {
                Button("Open Login Items Settings") {
                    viewModel.openLoginItemsSettings()
                }
                .accessibilityHint("Opens System Settings, General, Login Items, where the registration must be approved once.")
            }

            if let error = viewModel.launchAtLoginError {
                StatusLabel(error, symbol: "exclamationmark.triangle.fill", tone: .attention)
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Launch at Login error: \(error)")
            }
        } header: {
            Text("Appearance and Startup")
        } footer: {
            SettingsFooter(note: viewModel.refusalNote) {
                Text("KVoice always lives in the menu bar; macOS may ask you to approve the login item once.")
            }
        }
    }

    // MARK: Language

    /// Language names are shown in their own language (`Text(verbatim:)`), as
    /// macOS does, so a user who cannot read the current one can still find
    /// theirs. The change takes effect on relaunch — the alert says why.
    private var languageSection: some View {
        Section {
            Picker("Interface language", selection: $viewModel.interfaceLanguage) {
                Text("Follow System").tag(InterfaceLanguage.system)
                Text(verbatim: "English").tag(InterfaceLanguage.english)
                Text(verbatim: "简体中文").tag(InterfaceLanguage.simplifiedChinese)
            }
            .accessibilityLabel("Interface language")
            .accessibilityHint("Changes the language of KVoice's windows and menus after a relaunch.")
            .alert(
                "Relaunch KVoice to change the language?",
                isPresented: $viewModel.isRelaunchForLanguagePending
            ) {
                Button("Relaunch Now") { viewModel.relaunchForLanguage() }
                Button("Later", role: .cancel) { viewModel.deferRelaunchForLanguage() }
            } message: {
                Text("Menus and windows switch language when KVoice starts. The setting is saved either way; a dictation in progress is cancelled by a relaunch.")
            }
        } header: {
            Text("Language")
        } footer: {
            SettingsFooter(note: viewModel.refusalNote) {
                Text("The language of KVoice's own windows and menus. Speech recognition and translation languages are set in Speech Models and AI Actions.")
            }
        }
    }

    // MARK: Memory

    /// Later waves: memory-pressure warnings. "Unload model now" (the status
    /// menu and the Runtime card's banner) is always offered under critical
    /// pressure; this toggle is the only way it happens without being asked.
    private var memorySection: some View {
        Section {
            Toggle("Free model memory under critical pressure automatically", isOn: $viewModel.freeModelMemoryUnderCriticalPressure)
                .accessibilityHint("When enabled, KVoice unloads the speech model on its own if the Mac reaches critical memory pressure and no dictation is running. The next dictation reloads it.")
            SettingsResetRow(.freeModelMemoryUnderCriticalPressure, host: viewModel.host, origin: .page(.general))
        } header: {
            Text("Memory")
        } footer: {
            SettingsFooter(note: viewModel.refusalNote) {
                Text("Only under critical system memory pressure and only while idle; the next dictation reloads the model.")
            }
        }
    }

    // MARK: Backup

    /// Export/Import round-trip the whole `AppSettings` blob as one JSON
    /// file; Restore Previous Settings reuses the same confirm dialog
    /// against the automatic snapshot an apply takes first. Neither ever
    /// touches `SecretSettings` — the footer says so.
    private var backupSection: some View {
        Section {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { backupButtons }
                VStack(alignment: .leading, spacing: 8) { backupButtons }
            }

            if backup.backups.isEmpty {
                Text("No automatic backups yet. One is made the first time you import or restore settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Menu("Restore Previous Settings…") {
                    ForEach(backup.backups) { listing in
                        Button(listing.exportedAt.formatted(date: .abbreviated, time: .shortened)) {
                            backup.selectBackupForRestore(listing)
                        }
                    }
                }
                .accessibilityHint("Lists automatic snapshots taken before an import, newest first.")
            }

            if let message = backup.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Backup note")
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("API keys and the Auto Daily Export folder grant are never exported; re-choose the folder after importing.")
        }
        .task { backup.refreshBackups() }
        .confirmationDialog(
            pendingChangeTitle,
            isPresented: pendingChangeIsPresented,
            titleVisibility: .visible
        ) {
            Button(pendingChangeConfirmLabel) { backup.confirmPendingChange() }
            Button("Cancel", role: .cancel) { backup.cancelPendingChange() }
        } message: {
            Text(backup.pendingChange.map { BackupSettingsViewModel.summary(for: $0.diff) } ?? "")
        }
    }

    @ViewBuilder
    private var backupButtons: some View {
        Button("Export Settings…") { backup.exportToPanel() }
            .accessibilityHint("Saves your settings, without API keys, as a JSON file.")
        Button("Import Settings…") { backup.importFromPanel() }
            .accessibilityHint("Choose a settings file. You will see what will change before anything is applied.")
    }

    private var pendingChangeIsPresented: Binding<Bool> {
        Binding(
            get: { backup.pendingChange != nil },
            set: { isPresented in if !isPresented { backup.cancelPendingChange() } }
        )
    }

    private var pendingChangeTitle: LocalizedStringKey {
        switch backup.pendingChange?.source {
        case .automaticBackup: "Restore These Settings?"
        case .importedFile, .none: "Import These Settings?"
        }
    }

    private var pendingChangeConfirmLabel: LocalizedStringKey {
        switch backup.pendingChange?.source {
        case .automaticBackup: "Restore"
        case .importedFile, .none: "Import"
        }
    }

    // MARK: Setup guide

    private var setupSection: some View {
        Section {
            actionRow(
                "Reset Onboarding…",
                detail: "Replays the setup guide from the first screen. Model, history, shortcut, and settings are kept."
            ) {
                isConfirmingResetOnboarding = true
            }
            .confirmationDialog("Reset Onboarding?", isPresented: $isConfirmingResetOnboarding, titleVisibility: .visible) {
                Button("Reset Onboarding") { viewModel.resetOnboarding() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The setup guide will open again from the first screen. Your model, history, shortcut, and other settings are kept.")
            }
        } header: {
            Text("Setup Guide")
        } footer: {
            Text("The first-run guide, for walking through the model, permissions, and shortcut again. It deletes nothing.")
        }
    }

    // MARK: Troubleshooting

    private var troubleshootingSection: some View {
        Section {
            actionRow(
                "Restart KVoice…",
                detail: "Quits and relaunches the app. A dictation in progress is cancelled."
            ) {
                isConfirmingRestart = true
            }
            .confirmationDialog("Restart KVoice?", isPresented: $isConfirmingRestart, titleVisibility: .visible) {
                Button("Restart") { help.restartApp() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("KVoice quits and opens again. Nothing is deleted; a dictation in progress is cancelled.")
            }

            actionRow(
                "Reset Preferences…",
                detail: "Returns appearance and recording behavior to their defaults. AI configurations, API keys, shortcuts, history, and the model are kept.",
                role: .destructive
            ) {
                isConfirmingResetPreferences = true
            }
            .confirmationDialog("Reset preferences to defaults?", isPresented: $isConfirmingResetPreferences, titleVisibility: .visible) {
                Button("Reset Preferences", role: .destructive) { help.resetPreferences() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Dock icon, Launch at Login, typed insertion, history saving, the recording options, automatic memory unloading, and the window layout go back to their defaults. Your AI configurations, API keys, shortcut, history entries, and model are kept.")
            }
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text("For when something is stuck. Restart keeps everything; Reset Preferences keeps your data and shortcut and asks first.")
        }
    }

    /// A one-line explanation with its button: the macOS Settings shape for
    /// an action row. `LabeledContent` lets the explanation wrap in the label
    /// column while the button keeps its size, so nothing clips in a narrow
    /// pane.
    private func actionRow(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        role: ButtonRole? = nil,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        LabeledContent {
            Button(title, role: role) { action() }
                .fixedSize()
                .accessibilityHint(detail)
        } label: {
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
