import AppKit
import SwiftUI
import XCTest
import KvoiceDomain
@testable import KvoiceUI

/// UI v2 wave 4, opt-in like `WizardSnapshotTests`: every main-window page
/// the design draws, light and dark at the window's default 960×640, light
/// again at its 820×540 minimum, and the App Store edition of the pages
/// that differ (ADR-026) — `window-v2/window-<page>[-<variant>]-<size>-<light|dark>.png`
/// and `window-v2-contact-sheet.png` beside the folder. Set
/// `KVOICE_LAYOUT_SNAPSHOTS=<dir>`. Nothing is asserted about pixels.
///
/// History keeps the plain hosting view (`LayoutSnapshotTests.render`,
/// `hostInController: false`): its nested split view cannot be hosted
/// through a controller offscreen.
@MainActor
final class WindowSnapshotTests: XCTestCase {
    private func outputDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["KVOICE_LAYOUT_SNAPSHOTS"] else {
            throw XCTSkip("Set KVOICE_LAYOUT_SNAPSHOTS=<dir> to render layout snapshots")
        }
        let out = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("window-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    private struct Render {
        let section: MainWindowSection
        var variant: String?
        var edition: DistributionEdition = .developerID
        var size = NSSize(width: 960, height: 640)
        var appearance: (String, NSAppearance.Name) = ("light", .aqua)
        var readiness: MainWindowReadiness? = .preview
    }

    private static let defaultSize = NSSize(width: 960, height: 640)
    private static let narrowSize = NSSize(width: 820, height: 540)

    private func renders() -> [Render] {
        var renders: [Render] = []
        for section in MainWindowSection.allCases {
            renders.append(Render(section: section))
            renders.append(Render(section: section, appearance: ("dark", .darkAqua)))
            renders.append(Render(section: section, size: Self.narrowSize))
        }
        // ADR-026: the pages whose rows the App Store edition disables or hides.
        for section in [MainWindowSection.shortcuts, .recording, .dictionary, .aiActions, .permissions] {
            renders.append(Render(section: section, variant: "appstore", edition: .appStore))
        }
        renders.append(Render(section: .permissions, variant: "attention", readiness: MainWindowReadiness(
            title: "Accessibility off — clipboard only", needsAttention: true, shortcutKeys: ["⌃", "⇧", "Space"]
        )))
        renders.append(Render(section: .permissions, variant: "attention", appearance: ("dark", .darkAqua), readiness: MainWindowReadiness(
            title: "Accessibility off — clipboard only", needsAttention: true, shortcutKeys: ["⌃", "⇧", "Space"]
        )))
        renders.append(Render(section: .history, variant: "empty"))
        renders.append(Render(section: .history, variant: "empty", appearance: ("dark", .darkAqua)))
        return renders
    }

    func testRenderEveryWindowPage() async throws {
        let out = try outputDirectory()
        var sheet: [(String, NSImage)] = []
        for render in renders() {
            let model = MainWindowModel(selection: render.section)
            model.readiness = render.readiness
            let content = await Self.content(for: render.section, variant: render.variant, edition: render.edition)
            let view = MainWindowView(model: model) { _ in content }
            let image = LayoutSnapshotTests.render(
                view, size: render.size, appearance: render.appearance.1,
                hostInController: render.section != .history, scale: 2
            )
            let variant = render.variant.map { "-\($0)" } ?? ""
            let size = "\(Int(render.size.width))x\(Int(render.size.height))"
            let file = "window-\(render.section.rawValue)\(variant)-\(size)-\(render.appearance.0).png"
            try LayoutSnapshotTests.write(image, to: out.appendingPathComponent(file))
            sheet.append(("\(render.section.rawValue)\(variant) · \(size) · \(render.appearance.0)", image))
        }
        // The sidebar alone: inside the split view its column does not
        // render offscreen.
        let attention = MainWindowReadiness(title: "Accessibility off — clipboard only", needsAttention: true, shortcutKeys: ["⌃", "⇧", "Space"])
        for (label, readiness) in [("ready", MainWindowReadiness.preview), ("attention", attention)] {
            for (appearanceLabel, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let model = MainWindowModel(selection: .models)
                model.readiness = readiness
                let image = LayoutSnapshotTests.render(
                    MainWindowSidebar(model: model).frame(width: 220, height: 640),
                    size: NSSize(width: 220, height: 640), appearance: appearance, scale: 2
                )
                try LayoutSnapshotTests.write(image, to: out.appendingPathComponent("window-sidebar-\(label)-220x640-\(appearanceLabel).png"))
                sheet.insert(("sidebar \(label) · \(appearanceLabel)", image), at: 0)
            }
        }
        let contact = PanelSnapshotTests.contactSheet(panels: sheet, icons: [], tile: NSSize(width: 480, height: 330), columns: 6)
        try LayoutSnapshotTests.write(contact, to: out.deletingLastPathComponent().appendingPathComponent("window-v2-contact-sheet.png"))
    }

    // MARK: UI v2 wave 5b — card pages at every breakpoint

    /// `cards-v2/…png` and `cards-v2-contact-sheet.png` beside it: every
    /// page at the four breakpoints of Docs/Design/Cards-Layout-Plan.md
    /// (820×540 minimum, 960×640 default, 1280×800, 1600×1000) in light,
    /// plus dark at 820×540 and 960×640. English only: the offscreen
    /// renderer does not switch the interface language.
    func testRenderCardPagesAtEveryBreakpoint() async throws {
        let out = try outputDirectory().deletingLastPathComponent().appendingPathComponent("cards-v2")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let sizes = [NSSize(width: 820, height: 540), NSSize(width: 960, height: 640), NSSize(width: 1280, height: 800), NSSize(width: 1600, height: 1000)]
        var sheet: [(String, NSImage)] = []
        for section in MainWindowSection.allCases {
            for size in sizes {
                for appearance in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] where appearance.0 == "light" || size.width <= 960 {
                    let model = MainWindowModel(selection: section)
                    model.readiness = .preview
                    let content = await Self.content(for: section, variant: nil, edition: .developerID)
                    let image = LayoutSnapshotTests.render(
                        MainWindowView(model: model) { _ in content },
                        size: size, appearance: appearance.1,
                        hostInController: section != .history, scale: 2
                    )
                    let label = "\(section.rawValue)-\(Int(size.width))x\(Int(size.height))-\(appearance.0)"
                    try LayoutSnapshotTests.write(image, to: out.appendingPathComponent("cards-\(label).png"))
                    sheet.append((label, image))
                }
            }
        }
        let contact = PanelSnapshotTests.contactSheet(panels: sheet, icons: [], tile: NSSize(width: 480, height: 330), columns: 6)
        try LayoutSnapshotTests.write(contact, to: out.deletingLastPathComponent().appendingPathComponent("cards-v2-contact-sheet.png"))
    }

    // MARK: UI v2 wave 5a — Home, sidebar regroup, History chips

    /// `home-v2/…png` and `home-v2-contact-sheet.png` beside it: Home
    /// populated, with an empty history, with history off, with AI off and
    /// in the App Store edition; the regrouped sidebar; History with its
    /// filter chips active and the Original/Enhanced toggle. Light and dark
    /// at 960×640, and 820×540.
    func testRenderHomeSidebarAndHistoryChips() async throws {
        guard let directory = ProcessInfo.processInfo.environment["KVOICE_LAYOUT_SNAPSHOTS"] else {
            throw XCTSkip("Set KVOICE_LAYOUT_SNAPSHOTS=<dir> to render layout snapshots")
        }
        let out = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("home-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var sheet: [(String, NSImage)] = []
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        let sizes = [Self.defaultSize, Self.narrowSize]
        let aiOff = HomeHeroState(
            readiness: .preview, interaction: .pushToTalk,
            modelName: "Whisper large-v3-turbo", microphoneName: "MacBook Pro Microphone", ai: .off
        )
        let attention = HomeHeroState(
            readiness: MainWindowReadiness(title: "Accessibility off — clipboard only", needsAttention: true, shortcutKeys: ["⌃", "⇧", "Space"]),
            interaction: .toggle, modelName: "Whisper large-v3-turbo", microphoneName: "MacBook Pro Microphone", ai: .off
        )
        let noShortcut = HomeHeroState(
            readiness: MainWindowReadiness(title: "Ready", needsAttention: false, shortcutKeys: []),
            interaction: .pushToTalk, modelName: "Parakeet TDT v3", microphoneName: "Studio Display Microphone", ai: .off
        )
        struct HomeVariant { let name: String; let hero: HomeHeroState; let entries: [HistoryEntry]; let historyOn: Bool; let edition: DistributionEdition }
        let variants = [
            HomeVariant(name: "populated", hero: .preview, entries: PreviewFixtures.historyEntries, historyOn: true, edition: .developerID),
            HomeVariant(name: "empty", hero: .preview, entries: [], historyOn: true, edition: .developerID),
            HomeVariant(name: "history-off", hero: .preview, entries: [], historyOn: false, edition: .developerID),
            HomeVariant(name: "ai-off", hero: aiOff, entries: PreviewFixtures.historyEntries, historyOn: true, edition: .developerID),
            HomeVariant(name: "appstore", hero: aiOff, entries: PreviewFixtures.historyEntries, historyOn: true, edition: .appStore),
            HomeVariant(name: "attention", hero: attention, entries: PreviewFixtures.historyEntries, historyOn: true, edition: .developerID),
            HomeVariant(name: "no-shortcut", hero: noShortcut, entries: [], historyOn: true, edition: .developerID)
        ]
        for variant in variants {
            for size in sizes {
                for appearance in appearances where size == Self.defaultSize || appearance.0 == "light" {
                    let model = MainWindowModel(selection: .home)
                    model.readiness = variant.hero.readiness
                    model.home = variant.hero
                    var settings = AppSettings()
                    settings.historyEnabled = variant.historyOn
                    let history = HistoryViewModel(
                        repository: PreviewHistoryRepository(entries: variant.entries),
                        host: .detached(settings: settings)
                    )
                    await history.refreshHome()
                    let page = AnyView(HomeView(model: model, history: history))
                    let image = LayoutSnapshotTests.render(
                        MainWindowView(model: model) { _ in page },
                        size: size, appearance: appearance.1, hostInController: true, scale: 2
                    )
                    let label = "home-\(variant.name)-\(Int(size.width))x\(Int(size.height))-\(appearance.0)"
                    try LayoutSnapshotTests.write(image, to: out.appendingPathComponent("\(label).png"))
                    sheet.append((label, image))
                }
            }
        }
        // The regrouped sidebar on its own (its column does not render
        // inside the split view offscreen).
        for selection in [MainWindowSection.home, .help] {
            for appearance in appearances {
                let model = MainWindowModel(selection: selection)
                model.readiness = .preview
                let image = LayoutSnapshotTests.render(
                    MainWindowSidebar(model: model).frame(width: 220, height: 640),
                    size: NSSize(width: 220, height: 640), appearance: appearance.1, scale: 2
                )
                let label = "sidebar-\(selection.rawValue)-220x640-\(appearance.0)"
                try LayoutSnapshotTests.write(image, to: out.appendingPathComponent("\(label).png"))
                sheet.insert((label, image), at: 0)
            }
        }
        // History with the chips narrowing the list and an AI entry open on
        // the Original/Enhanced toggle.
        for size in sizes {
            for appearance in appearances where size == Self.defaultSize || appearance.0 == "light" {
                let model = MainWindowModel(selection: .history)
                model.readiness = .preview
                let history = HistoryViewModel(repository: PreviewHistoryRepository())
                history.timeRange = .last7Days
                history.onlyWithAI = true
                await history.load()
                await history.refreshStatistics()
                history.selectedEntryID = history.entries.first(where: \.hasDistinctEnhancedText)?.id ?? history.entries.first?.id
                let page = AnyView(HistoryView(viewModel: history))
                let image = LayoutSnapshotTests.render(
                    MainWindowView(model: model) { _ in page },
                    size: size, appearance: appearance.1, hostInController: false, scale: 2
                )
                let label = "history-chips-\(Int(size.width))x\(Int(size.height))-\(appearance.0)"
                try LayoutSnapshotTests.write(image, to: out.appendingPathComponent("\(label).png"))
                sheet.append((label, image))
            }
        }
        let contact = PanelSnapshotTests.contactSheet(panels: sheet, icons: [], tile: NSSize(width: 480, height: 330), columns: 5)
        try LayoutSnapshotTests.write(contact, to: out.deletingLastPathComponent().appendingPathComponent("home-v2-contact-sheet.png"))
    }

    // MARK: Content

    static func availability(for edition: DistributionEdition) -> SettingsAvailabilityModel {
        let model = SettingsAvailabilityModel(edition: edition)
        model.update(SettingsAvailability.table(
            settings: AppSettings(), environment: EnvironmentProfile(edition: edition), gate: .idle
        ))
        return model
    }

    static func content(for section: MainWindowSection, variant: String?, edition: DistributionEdition) async -> AnyView {
        let availability = availability(for: edition)
        let general = GeneralSettingsView.previewModel(withShortcut: true)
        switch section {
        case .home:
            let model = MainWindowModel(selection: .home)
            model.home = .preview
            let history = HistoryViewModel(repository: PreviewHistoryRepository())
            await history.refreshHome()
            return AnyView(HomeView(model: model, history: history))
        case .history:
            let repository = PreviewHistoryRepository()
            if variant == "empty" {
                return AnyView(HistoryView(viewModel: HistoryViewModel(repository: PreviewHistoryRepository(entries: []))))
            }
            return AnyView(HistoryView(viewModel: HistoryViewModel(repository: repository)))
        case .aiActions:
            return AnyView(AIActionsSectionView(ai: .previewConfigured(), modes: .previewSeeded(), availability: availability))
        case .models:
            return DesignGalleryTests.seededModelsSection()
        case .permissions:
            // Microphone allowed; Accessibility (the PostEvent grant in the
            // App Store edition) not yet — the design's one card that needs
            // attention. Read before the render, as the page's poll would.
            let permissions = PermissionStatusViewModel(
                microphonePermission: SnapshotWindowMicrophone(),
                accessibilityPermission: SnapshotWindowAccessibility(trusted: variant != "attention"),
                edition: edition
            )
            await permissions.refresh()
            return AnyView(PermissionsSectionView(general: general, permissions: permissions, shortcutRegistration: { .registered(GeneralSettingsViewModel.recommendedShortcut) }))
        case .dictionary:
            return AnyView(DictionarySectionView(model: DictionaryViewModel(), availability: availability))
        case .audioInput:
            // UI v2 fidelity F3: the design's prioritized list and a
            // finished level test.
            let airpods = AudioInputDevice(uid: "airpods", name: "AirPods Pro")
            let builtIn = AudioInputDevice(uid: "builtin", name: "MacBook Pro Microphone")
            let input = AudioInputViewModel(deviceProvider: SnapshotDevices(available: [airpods, builtIn], systemDefault: builtIn))
            input.mode = .prioritized
            input.addToPriority(uid: "airpods")
            input.addToPriority(uid: "builtin")
            let test = MicrophoneTestViewModel(state: .completed(MicrophoneTestResult(duration: .seconds(3), peakLevelDBFS: -12, capturedSamples: 48_000)))
            return AnyView(AudioInputSectionView(microphoneTest: test, inputSelection: input))
        case .shortcuts:
            let triggers = TriggerSettingsViewModel()
            return AnyView(ShortcutsSectionView(general: general, triggers: triggers.triggerOptionBindings, availability: availability))
        case .recording:
            let triggers = TriggerSettingsViewModel()
            triggers.previewCue = { _ in }
            return AnyView(RecordingSectionView(general: general, options: triggers.recordingOptionBindings, availability: availability))
        case .dataPrivacy:
            return AnyView(DataPrivacySectionView(
                history: HistoryViewModel(repository: PreviewHistoryRepository()),
                dataPrivacy: DataPrivacyViewModel(),
                privacy: PrivacyAboutViewModel(appVersion: "0.1.0", buildNumber: "12", copyToPasteboard: { _ in })
            ))
        case .general:
            return AnyView(GeneralSectionView(viewModel: general))
        case .help:
            return AnyView(HelpSectionView(viewModel: HelpViewModel(openURL: { _ in true })))
        }
    }
}

// MARK: Snapshot doubles

private struct SnapshotDevices: AudioInputDeviceProviding {
    let available: [AudioInputDevice]
    let systemDefault: AudioInputDevice?
    func availableInputDevices() -> [AudioInputDevice] { available }
    func systemDefaultInputDevice() -> AudioInputDevice? { systemDefault }
}

private struct SnapshotWindowMicrophone: MicrophonePermissionProviding {
    func authorization() async -> PermissionAuthorization { .granted }
    func requestAccess() async -> PermissionAuthorization { .granted }
}

private struct SnapshotWindowAccessibility: AccessibilityPermissionProviding {
    let trusted: Bool
    func isTrusted(prompt: Bool) async -> Bool { trusted }
}
