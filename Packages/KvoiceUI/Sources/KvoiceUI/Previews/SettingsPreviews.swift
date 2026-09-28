#if DEBUG
import KvoiceDomain
import SwiftUI

// Previews for the settings surfaces, kept together so the whole Settings window
// can be reviewed in one place.
//
// Every view model here is constructed with its service-free defaults, so no
// preview reads settings from disk, calls an AI endpoint, or opens a microphone.
// The one exception is History, which needs a repository; it gets the in-memory
// `PreviewHistoryRepository`.

#Preview("General: no shortcut yet") {
    GeneralSettingsView(viewModel: GeneralSettingsView.previewModel(withShortcut: false))
        .frame(width: 620, height: 380)
}

#Preview("General: shortcut confirmed") {
    GeneralSettingsView(viewModel: GeneralSettingsView.previewModel(withShortcut: true))
        .frame(width: 620, height: 380)
}

#Preview("Permissions: nothing granted yet") {
    PermissionsSectionView(general: GeneralSettingsView.previewModel(withShortcut: true))
        .frame(width: 720, height: 720)
}

#Preview("Shortcuts") {
    ShortcutsSectionView(general: GeneralSettingsView.previewModel(withShortcut: true))
        .frame(width: 620, height: 520)
}

#Preview("Recording") {
    RecordingSectionView(general: GeneralSettingsView.previewModel(withShortcut: true))
        .frame(width: 620, height: 520)
}

#Preview("Data & Privacy") {
    DataPrivacySectionView(
        history: HistoryViewModel(repository: PreviewHistoryRepository()),
        privacy: PrivacyAboutViewModel(appVersion: "0.1.0", buildNumber: "12", copyToPasteboard: { _ in })
    )
    .frame(width: 720, height: 900)
}

#Preview("Help") {
    // P-M14: Help now hosts the About group too.
    HelpSectionView(
        viewModel: HelpViewModel(openURL: { _ in true }),
        privacy: PrivacyAboutViewModel(appVersion: "0.1.0", buildNumber: "12", copyToPasteboard: { _ in })
    )
    .frame(width: 720, height: 760)
}

#Preview("Main window") {
    MainWindowView(model: MainWindowModel(selection: .help)) { section in
        AnyView(Text(section.title).frame(maxWidth: .infinity, maxHeight: .infinity))
    }
    .frame(width: 900, height: 600)
}

#Preview("Main window: quick-tour banner") {
    MainWindowView(model: MainWindowModel(selection: .history, showTutorialBanner: true)) { section in
        AnyView(Text(section.title).frame(maxWidth: .infinity, maxHeight: .infinity))
    }
    .frame(width: 900, height: 600)
}

#Preview("Model: ready, managed") {
    ModelSettingsView(viewModel: ModelSettingsViewModel(
        state: .ready(InstalledModelSummary(
            modelID: "whisper-large-v3-turbo-coreml-uncompressed",
            revision: "04e5c42d80a522518023727e8c7e68d4bb391b28",
            ownership: .managedByKvoice
        )),
        descriptor: ModelDescriptor(
            modelID: "whisper-large-v3-turbo-coreml-uncompressed",
            revision: "04e5c42d80a522518023727e8c7e68d4bb391b28",
            source: .managed(URL(fileURLWithPath: "/Users/me/Library/Application Support/kvoice/model")),
            installedBytes: 1_640_000_000,
            repository: "argmaxinc/whisperkit-coreml",
            manifestSchemaVersion: 1
        )
    ))
    .frame(width: 720, height: 560)
}

#Preview("Model: downloading") {
    ModelSettingsView(viewModel: ModelSettingsViewModel(
        state: .downloading(completed: 640_000_000, total: 1_640_000_000),
        modelSpaceEstimate: { ModelSpaceEstimate(requiredBytes: 2_700_000_000, availableBytes: 120_000_000_000) }
    ))
    .frame(width: 720, height: 560)
}

#Preview("Privacy & About") {
    PrivacyAboutView(viewModel: PrivacyAboutViewModel(
        appVersion: "0.1.0",
        buildNumber: "12",
        dataFolderURL: URL(fileURLWithPath: "/Users/me/Library/Application Support/kvoice"),
        modelRepositoryHost: "huggingface.co (argmaxinc/whisperkit-coreml)",
        modelManifestDescription: "schema 1 · whisper-large-v3-turbo-coreml-uncompressed @ 04e5c42d80a5",
        licensesProvider: { "# Third-party notices\n\n(preview)" },
        historyMetrics: { HistoryMetrics(entryCount: 42, databaseBytes: 180_000) },
        copyToPasteboard: { _ in }
    ))
    .frame(width: 720, height: 720)
}

#Preview("AI: off, nothing configured") {
    AISettingsView(viewModel: AISettingsViewModel())
        .frame(width: 720, height: 620)
}

#Preview("AI: configured with saved endpoints") {
    AISettingsView(viewModel: .previewConfigured())
        .frame(width: 720, height: 620)
}

#Preview("Actions: built-ins seeded") {
    PromptModeSettingsView(viewModel: .previewSeeded())
        .frame(width: 720, height: 620)
}

#Preview("AI Actions: nothing configured") {
    AIActionsSectionView(ai: AISettingsViewModel(), modes: PromptModeSettingsViewModel())
        .frame(width: 760, height: 760)
}

#Preview("AI Actions: configured and enabled") {
    AIActionsSectionView(ai: .previewConfigured(), modes: .previewSeeded())
        .frame(width: 760, height: 900)
}

#Preview("History: with entries") {
    HistoryView(viewModel: HistoryViewModel(
        repository: PreviewHistoryRepository()
    ))
    .frame(width: 900, height: 560)
}

// The empty state is easy to break and hard to reach by hand once you have used
// the app, so it gets its own preview.
#Preview("History: empty") {
    HistoryView(viewModel: HistoryViewModel(
        repository: PreviewHistoryRepository(entries: []),
        host: .detached(settings: AppSettings(historyEnabled: false))
    ))
    .frame(width: 900, height: 560)
}

#Preview("Onboarding: welcome") {
    OnboardingView(viewModel: OnboardingViewModel())
}

#Preview("Onboarding: ready with a test transcript") {
    let model = OnboardingViewModel(
        stage: .ready,
        modelState: .ready(InstalledModelSummary(
            modelID: "whisper-large-v3-turbo-coreml-uncompressed",
            revision: "04e5c42d80a522518023727e8c7e68d4bb391b28",
            ownership: .managedByKvoice
        )),
        shortcut: GeneralSettingsViewModel.recommendedShortcut
    )
    model.setDictationTestResult(.transcript("This is what the recorder heard."))
    return OnboardingView(viewModel: model)
}

#Preview("Onboarding: model downloading") {
    OnboardingView(viewModel: OnboardingViewModel(
        stage: .speechModel,
        // Bytes, not files: the progress copy formats these with
        // ByteCountFormatter.
        modelState: .downloading(completed: 640_000_000, total: 1_600_000_000)
    ))
}

#Preview("Onboarding: shortcut with Try It, waiting") {
    OnboardingView(viewModel: OnboardingViewModel(
        stage: .shortcut,
        shortcut: GeneralSettingsViewModel.recommendedShortcut
    ))
}

#Preview("Onboarding: shortcut with Try It, held") {
    let model = OnboardingViewModel(
        stage: .shortcut,
        shortcut: GeneralSettingsViewModel.recommendedShortcut
    )
    model.beginHotkeyTest()
    model.reportHotkeyTestKeyDown()
    model.tickHotkeyTest(now: Date().addingTimeInterval(0.8))
    return OnboardingView(viewModel: model)
}

#Preview("Tutorial: standalone") {
    TutorialView(viewModel: TutorialViewModel())
        .frame(width: 640, height: 640)
}

extension AISettingsViewModel {
    /// A populated endpoint plus two saved configurations, which is what the
    /// section looks like in real use.
    static func previewConfigured() -> AISettingsViewModel {
        var settings = AppSettings()
        settings.ai = AIEndpointSettings(
            mode: .polish,
            baseURL: URL(string: "http://localhost:11434/v1"),
            modelID: "gemma4:latest"
        )
        settings.ai.configurations = [
            AIConfiguration(
                name: "Local Ollama",
                kind: .ollama,
                baseURL: URL(string: "http://localhost:11434/v1"),
                modelID: "gemma4:latest"
            ),
            AIConfiguration(
                name: "Work OpenAI",
                kind: .openAI,
                baseURL: URL(string: "https://api.openai.com/v1"),
                modelID: "gpt-4o-mini"
            )
        ]
        settings.ai.activeConfigurationID = settings.ai.configurations.first?.id
        return AISettingsViewModel(
            host: .detached(settings: settings),
            modelLister: { _, _ in ["gemma4:latest", "llama3:latest", "qwen2:7b"] }
        )
    }
}

extension PromptModeSettingsViewModel {
    /// Seeded with the shipped modes, and with one of them edited so the
    /// "edited" badge and its Restore action are both visible.
    static func previewSeeded() -> PromptModeSettingsViewModel {
        var settings = AIEndpointSettings(
            mode: .polish,
            baseURL: URL(string: "http://localhost:11434/v1"),
            modelID: "gemma4:latest"
        )
        settings.seedBuiltInPromptModesIfNeeded()
        if !settings.promptModes.isEmpty {
            settings.promptModes[0].prompt += "\n\nAlways keep British spelling."
        }
        settings.activePromptModeID = settings.promptModes.first?.id
        settings.userProfile = "Role: engineer\nTech stack: Swift"
        settings.actionTriggersEnabled = true
        settings.bindSelectionAction(settings.promptModes[1].id, slot: 0)
        var appSettings = AppSettings()
        appSettings.ai = settings
        return PromptModeSettingsViewModel(
            host: .detached(settings: appSettings),
            previewRunner: { _, sample in
                "Cleaned up: \(sample)"
            }
        )
    }
}
#endif
