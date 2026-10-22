import AppKit
import KvoiceAppCore
import KvoiceDomain
import SwiftUI
@testable import KvoiceUI
import XCTest

/// Q2b (UI v2 regression audit): showing a page must never write a setting.
/// The drawn controls (`KVSwitch`, `KVSelect`, `KVSegmented`, chips, cards)
/// replaced the system ones in UI v2; a control that normalises its value
/// on appear, or a `.task` / `.onAppear` that "syncs" a view model, would
/// send an intent the user never made (and, during a job, a refusal note).
///
/// Every main-window page, Home, and every wizard step is laid out offscreen
/// over one `SettingsProjectionTestHarness`, and the run loop is turned once
/// so `onAppear` work runs (a `.task` that suspends before writing is not
/// covered); the harness must have recorded no intent at all.
@MainActor
final class NoSpuriousSettingsWritesTests: XCTestCase {
    private static func seededSettings() -> AppSettings {
        var settings = AppSettings()
        settings.shortcut = GeneralSettingsViewModel.recommendedShortcut
        settings.ai = AIEndpointSettings(
            mode: .polish,
            baseURL: URL(string: "http://localhost:11434/v1"),
            modelID: "gemma4:latest"
        )
        settings.ai.seedBuiltInPromptModesIfNeeded()
        settings.dictionary = DictionarySettings(terms: ["KVoice", "WhisperKit"])
        return settings
    }

    /// Lays the view out in a window (no bitmap: nothing is drawn or
    /// compared) and turns the run loop once so `onAppear` work runs.
    private func layOut<V: View>(_ view: V, size: NSSize = NSSize(width: 960, height: 640)) {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        // One pass of the run loop, without waiting on the clock: delivers
        // the onAppear work the layout scheduled.
        RunLoop.main.run(mode: .default, before: .distantPast)
        hosting.layoutSubtreeIfNeeded()
        window.contentView = nil
    }

    private func assertNoWrites(_ harness: SettingsProjectionTestHarness, _ page: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(harness.sent, [], "\(page) wrote settings on appear", file: file, line: line)
        XCTAssertEqual(harness.sentLocalState, [], "\(page) wrote local state on appear", file: file, line: line)
    }

    func testShowingEveryMainWindowPageWritesNothing() async {
        let harness = SettingsProjectionTestHarness(settings: Self.seededSettings())
        let host = harness.host
        // The probe: a view that does write on appear is caught, so a
        // silent pass below means the pages wrote nothing.
        let probe = GeneralSettingsViewModel(host: host)
        layOut(Color.clear.onAppear { probe.typedInsertionEnabled.toggle() })
        XCTAssertEqual(harness.sent.count, 1, "the layout pass runs onAppear")
        harness.clearRecords()

        for edition in DistributionEdition.allCases {
            let availability = WindowSnapshotTests.availability(for: edition)
            let general = GeneralSettingsViewModel(host: host)
            let triggers = TriggerSettingsViewModel(host: host)
            triggers.previewCue = { _ in }
            let history = HistoryViewModel(repository: PreviewHistoryRepository(), host: host)
            let pages: [(MainWindowSection, AnyView)] = [
                (.shortcuts, AnyView(ShortcutsSectionView(general: general, triggers: triggers.triggerOptionBindings, availability: availability))),
                (.recording, AnyView(RecordingSectionView(general: general, options: triggers.recordingOptionBindings, availability: availability))),
                (.audioInput, AnyView(AudioInputSectionView(
                    microphoneTest: MicrophoneTestViewModel(),
                    inputSelection: AudioInputViewModel(host: host)
                ))),
                (.dictionary, AnyView(DictionarySectionView(model: DictionaryViewModel(host: host), availability: availability))),
                (.aiActions, AnyView(AIActionsSectionView(
                    ai: AISettingsViewModel(host: host),
                    modes: PromptModeSettingsViewModel(host: host),
                    availability: availability
                ))),
                (.history, AnyView(HistoryView(viewModel: history))),
                (.dataPrivacy, AnyView(DataPrivacySectionView(
                    history: history,
                    dataPrivacy: DataPrivacyViewModel(host: host),
                    privacy: PrivacyAboutViewModel(appVersion: "0.1.0", buildNumber: "1", copyToPasteboard: { _ in })
                ))),
                (.general, AnyView(GeneralSectionView(viewModel: general, backup: BackupSettingsViewModel(host: host)))),
            ]
            // The App Store pass covers the pages that differ by edition.
            let differ: Set<MainWindowSection> = [.shortcuts, .recording, .aiActions, .dataPrivacy, .general]
            for (section, page) in pages where edition == .developerID || differ.contains(section) {
                let model = MainWindowModel(selection: section)
                layOut(MainWindowView(model: model) { _ in page })
                assertNoWrites(harness, "\(section.rawValue) (\(edition.rawValue))")
            }
            guard edition == .developerID else { continue }
            let homeModel = MainWindowModel(selection: .home)
            homeModel.home = .preview
            await history.refreshHome()
            layOut(MainWindowView(model: homeModel) { _ in AnyView(HomeView(model: homeModel, history: history)) })
            assertNoWrites(harness, "home (\(edition.rawValue))")
        }
    }

    func testShowingEveryWizardStepWritesNothing() {
        let harness = SettingsProjectionTestHarness(settings: Self.seededSettings())
        for edition in DistributionEdition.allCases {
            for stage in OnboardingStage.allCases {
                let model = OnboardingViewModel(stage: stage, settings: harness.host, edition: edition)
                layOut(
                    OnboardingView(
                        viewModel: model,
                        aiSettingsViewModel: AISettingsViewModel(host: harness.host),
                        audioInput: AudioInputViewModel(host: harness.host),
                        overrides: .init(reduceMotion: true)
                    ),
                    size: NSSize(width: 760, height: 620)
                )
                assertNoWrites(harness, "wizard \(stage) (\(edition.rawValue))")
            }
        }
    }
}
