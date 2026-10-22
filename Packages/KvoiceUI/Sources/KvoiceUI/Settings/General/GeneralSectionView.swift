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
        KVCardPage {
            appearanceSection
            languageSection
            memorySection
            backupSection
            setupSection
        }
    }

    // MARK: Appearance and startup

    private var appearanceSection: some View {
        KVCardSection {
            Toggle("Show KVoice in Dock", isOn: $viewModel.showDockIcon)
                .accessibilityLabel("Show KVoice in Dock")
                .accessibilityHint("When enabled, KVoice appears in the Dock as well as the menu bar. The menu-bar item is always shown.")

            HStack(spacing: 12) {
                Toggle("Launch at Login", isOn: $viewModel.launchAtLogin)
                    .accessibilityLabel("Launch at Login")
                    .accessibilityHint("Registers KVoice as a login item through macOS. The status below is what macOS reports.")
                if let chip = Self.loginChip(viewModel.launchAtLoginStatus) {
                    KVChip(chip.0, tone: chip.1)
                        .accessibilityLabel(Text("Login item status", bundle: .module))
                        .accessibilityValue(Text(viewModel.launchAtLoginStatus.displayName))
                        .help(viewModel.launchAtLoginStatus.displayName)
                }
            }
            .animation(reduceMotion ? nil : .default, value: viewModel.launchAtLoginStatus)
                .task {
                    // The user can approve or remove the login item in System
                    // Settings at any time, so the section reads the real
                    // status when it appears.
                    viewModel.refreshLaunchAtLoginStatus()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    viewModel.refreshLaunchAtLoginStatus()
                }

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
                Text("KVoice always lives in the menu bar.")
            }
        }
    }

    // MARK: Language

    /// Language names are shown in their own language (`Text(verbatim:)`), as
    /// macOS does, so a user who cannot read the current one can still find
    /// theirs. The change takes effect on relaunch — the alert says why.
    private var languageSection: some View {
        KVCardSection {
            LabeledContent {
                KVSelect("Interface language", selection: $viewModel.interfaceLanguage, current: Self.languageTitle(viewModel.interfaceLanguage)) {
                    Text("Follow System").tag(InterfaceLanguage.system)
                    Text(verbatim: "English").tag(InterfaceLanguage.english)
                    Text(verbatim: "简体中文").tag(InterfaceLanguage.simplifiedChinese)
                }
            } label: {
                Text("Interface language")
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
            SettingsFooter(note: viewModel.refusalNote) { EmptyView() }
        }
    }

    // MARK: Memory

    /// Later waves: memory-pressure warnings. "Unload model now" (the status
    /// menu and the Runtime card's banner) is always offered under critical
    /// pressure; this toggle is the only way it happens without being asked.
    private var memorySection: some View {
        KVCardSection {
            Toggle(isOn: $viewModel.freeModelMemoryUnderCriticalPressure) {
                Text("Free model memory under critical pressure")
                Text("Only while idle; the next dictation reloads the model")
            }
                .accessibilityHint("When enabled, KVoice unloads the speech model on its own if the Mac reaches critical memory pressure and no dictation is running. The next dictation reloads it.")
        } header: {
            KVHeaderRow("Memory") {
                SettingsResetRow(.freeModelMemoryUnderCriticalPressure, host: viewModel.host, origin: .page(.general))
            }
        } footer: {
            SettingsFooter(note: viewModel.refusalNote) { EmptyView() }
        }
    }

    // MARK: Backup

    /// Export/Import round-trip the whole `AppSettings` blob as one JSON
    /// file; Restore Previous Settings reuses the same confirm dialog
    /// against the automatic snapshot an apply takes first. Neither ever
    /// touches `SecretSettings` — the footer says so.
    private var backupSection: some View {
        KVCardSection {
            LabeledContent {
                HStack(spacing: 6) {
                    backupButtons
                    Menu {
                        ForEach(backup.backups) { listing in
                            Button(listing.exportedAt.formatted(date: .abbreviated, time: .shortened)) {
                                backup.selectBackupForRestore(listing)
                            }
                        }
                    } label: {
                        Text("Restore…")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(backup.backups.isEmpty)
                    .help(backup.backups.isEmpty
                        ? Text("No automatic backups yet. One is made the first time you import or restore settings.")
                        : Text("Lists automatic snapshots taken before an import, newest first."))
                    .accessibilityHint(backup.backups.isEmpty
                        ? Text("No automatic backups yet. One is made the first time you import or restore settings.")
                        : Text("Lists automatic snapshots taken before an import, newest first."))
                }
            } label: {
                Text("Settings")
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
        Button("Export…") { backup.exportToPanel() }
            .accessibilityHint("Saves your settings, without API keys, as a JSON file.")
        Button("Import…") { backup.importFromPanel() }
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
        // UI v2 fidelity F3 (Window.dc `general`): the setup guide and the
        // restart / reset tools in one "Setup and Troubleshooting" card.
        KVCardSection {
            LabeledContent {
                Button("Open Setup Guide…") { isConfirmingResetOnboarding = true }
                    .accessibilityHint("Replays the setup guide from the first screen. Model, history, shortcut, and settings are kept.")
            } label: {
                Text("Setup Guide")
            }
            .confirmationDialog("Reset Onboarding?", isPresented: $isConfirmingResetOnboarding, titleVisibility: .visible) {
                Button("Reset Onboarding") { viewModel.resetOnboarding() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The setup guide will open again from the first screen. Your model, history, shortcut, and other settings are kept.")
            }
            LabeledContent {
                HStack(spacing: 6) {
                    Button("Restart KVoice…") { isConfirmingRestart = true }
                        .accessibilityHint("Quits and relaunches the app. A dictation in progress is cancelled.")
                    Button("Reset Preferences…", role: .destructive) { isConfirmingResetPreferences = true }
                        .accessibilityHint("Returns appearance and recording behavior to their defaults. AI configurations, API keys, shortcuts, history, and the model are kept.")
                }
            } label: {
                Text("Restart or reset")
            }
            .confirmationDialog("Restart KVoice?", isPresented: $isConfirmingRestart, titleVisibility: .visible) {
                Button("Restart") { help.restartApp() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("KVoice quits and opens again. Nothing is deleted; a dictation in progress is cancelled.")
            }
            .confirmationDialog("Reset preferences to defaults?", isPresented: $isConfirmingResetPreferences, titleVisibility: .visible) {
                Button("Reset Preferences", role: .destructive) { help.resetPreferences() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Dock icon, Launch at Login, typed insertion, history saving, the recording options, automatic memory unloading, and the window layout go back to their defaults. Your AI configurations, API keys, shortcut, history entries, and model are kept.")
            }
        } header: {
            Text("Setup and Troubleshooting")
        }
    }

    static func loginChip(_ status: LaunchAtLoginStatus) -> (String, KVTone)? {
        switch status {
        case .enabled: (String(localized: "Approved", bundle: .module), .ok)
        case .requiresApproval: (String(localized: "Needs approval", bundle: .module), .warn)
        case .notFound: (String(localized: "Unavailable", bundle: .module), .warn)
        case .notRegistered, .unknown: nil
        }
    }

    static func languageTitle(_ language: InterfaceLanguage) -> String {
        switch language {
        case .system: String(localized: "Follow System", bundle: .module)
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }


}
