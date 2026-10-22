import AppKit
import SwiftUI
import XCTest
import KvoiceDomain
@testable import KvoiceUI

/// Q3 (2026-10-22), opt-in like the other snapshot suites: the restructured
/// AI Actions page in the window shell — light and dark at 820×540,
/// 960×640 and 1280×800 (what the window shows), a tall render of the whole
/// page, the App Store edition, no configurations, several configurations,
/// AI off, a passed test — and the action detail sheet on its own (a sheet
/// does not render offscreen inside the window): the default Clean Up, a
/// Translate action, a user action and a new one, at the sheet's ideal and
/// minimum sizes. `q3-ai-actions/<name>.png` plus
/// `q3-ai-actions-contact-sheet.png` beside the folder. Set
/// `KVOICE_LAYOUT_SNAPSHOTS=<dir>`. Nothing is asserted about pixels.
@MainActor
final class AIActionsIASnapshotTests: XCTestCase {
    enum Variant: String, CaseIterable {
        case configured, noConfigurations = "no-configurations", severalConfigurations = "several-configurations"
        case aiOff = "ai-off", tested, appStore = "appstore"
    }

    static func settings(_ variant: Variant) -> AppSettings {
        var ai = AIEndpointSettings(mode: .polish)
        ai.seedBuiltInPromptModesIfNeeded()
        ai.promptModes[0].prompt += "\n\nAlways keep British spelling."
        ai.promptModes[0].triggerWords = ["clean up"]
        ai.promptModes[0].options.formalWriting = true
        if let translate = ai.promptModes.firstIndex(where: { $0.behavior == .translate }) {
            ai.promptModes[translate].options.secondTranslationLanguage = TranslationLanguage(bcp47: "ja", displayName: "Japanese")
        }
        ai.actionTriggersEnabled = true
        ai.userProfile = "Role: engineer\nTech stack: Swift"
        ai.bindSelectionAction(ai.promptModes[1].id, slot: 0)
        if variant != .noConfigurations {
            var configurations = [
                AIConfiguration(name: "Local Ollama", kind: .ollama, baseURL: URL(string: "http://localhost:11434/v1"), modelID: "gemma4:latest"),
                AIConfiguration(name: "Work OpenAI", kind: .openAI, baseURL: URL(string: "https://api.openai.com/v1"), modelID: "gpt-4o-mini"),
            ]
            if variant == .severalConfigurations {
                configurations += [
                    AIConfiguration(name: "Gemini Flash", kind: .gemini, baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai"), modelID: "gemini-2.5-flash"),
                    AIConfiguration(name: "Apple Intelligence", kind: .appleIntelligence),
                ]
            }
            ai.configurations = configurations
            ai.activeConfigurationID = configurations[0].id
            ai.baseURL = configurations[0].baseURL
            ai.modelID = configurations[0].modelID
        }
        ai.apply(promptMode: ai.promptModes[0])
        ai.isEnabled = variant != .aiOff
        var settings = AppSettings()
        settings.ai = ai
        return settings
    }

    /// Both halves of the page over one host, as the app wires them.
    static func page(_ variant: Variant) async -> (AnyView, AISettingsViewModel, PromptModeSettingsViewModel) {
        let host = SettingsProjectionHost.detached(settings: settings(variant))
        let configurations = AISettingsViewModel(host: host)
        let actions = PromptModeSettingsViewModel(host: host)
        if variant == .tested { await configurations.testConfiguration() }
        // The projection over this variant's settings, so the rows it
        // gates (trigger words, Selection Action) read as they would.
        let edition: DistributionEdition = variant == .appStore ? .appStore : .developerID
        let availability = SettingsAvailabilityModel(edition: edition)
        availability.update(SettingsAvailability.table(
            settings: host.settings, environment: EnvironmentProfile(edition: edition), gate: .idle
        ))
        return (AnyView(AIActionsSectionView(ai: configurations, modes: actions, availability: availability)), configurations, actions)
    }

    func testRenderAIActionsPage() async throws {
        guard let directory = ProcessInfo.processInfo.environment["KVOICE_LAYOUT_SNAPSHOTS"] else {
            throw XCTSkip("Set KVOICE_LAYOUT_SNAPSHOTS=<dir> to render layout snapshots")
        }
        let out = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("q3-ai-actions", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var sheet: [(String, NSImage)] = []
        let light = ("light", NSAppearance.Name.aqua)
        let dark = ("dark", NSAppearance.Name.darkAqua)

        func shoot(_ variant: Variant, size: NSSize, _ appearance: (String, NSAppearance.Name), tall: Bool = false) async throws {
            let (page, _, _) = await Self.page(variant)
            let model = MainWindowModel(selection: .aiActions)
            model.readiness = .preview
            let image = LayoutSnapshotTests.render(
                MainWindowView(model: model) { _ in page },
                size: size, appearance: appearance.1, hostInController: true, scale: tall ? 1 : 2
            )
            let name = "page-\(variant.rawValue)-\(tall ? "full" : "\(Int(size.width))x\(Int(size.height))")-\(appearance.0)"
            try LayoutSnapshotTests.write(image, to: out.appendingPathComponent("\(name).png"))
            sheet.append((name, image))
        }

        for appearance in [light, dark] {
            for size in [NSSize(width: 820, height: 540), NSSize(width: 960, height: 640), NSSize(width: 1_280, height: 800)] {
                try await shoot(.configured, size: size, appearance)
            }
            try await shoot(.configured, size: NSSize(width: 960, height: 2_000), appearance, tall: true)
        }
        for variant in [Variant.noConfigurations, .severalConfigurations, .aiOff, .tested, .appStore] {
            try await shoot(variant, size: NSSize(width: 960, height: 640), light)
            try await shoot(variant, size: NSSize(width: 960, height: 2_000), variant == .aiOff ? dark : light, tall: true)
        }

        // The action detail, on its own.
        let (_, _, actions) = await Self.page(.configured)
        let modes = actions.modes
        let user = PromptMode(name: "Standup", behavior: .polish, prompt: "Turn the transcript into a three-line standup update.", summary: "Yesterday, today, blockers.", icon: "🧍")
        let details: [(String, PromptModeDraft, AIActionDetailContext)] = [
            ("clean-up-default", PromptModeDraft(mode: modes[0]), AIActionDetailContext(
                saved: modes[0], isDefault: true, shortcutBadge: "⌘1",
                selectionSlots: []
            )),
            ("translate", PromptModeDraft(mode: modes.first { $0.behavior == .translate }!), AIActionDetailContext(
                saved: modes.first { $0.behavior == .translate }, shortcutBadge: actions.shortcutBadge(for: modes.first { $0.behavior == .translate }!.id),
                selectionSlots: []
            )),
            ("message-on-slot", PromptModeDraft(mode: modes[1]), AIActionDetailContext(
                saved: modes[1], shortcutBadge: "⌘2",
                selectionSlots: [.init(slot: 0, shortcut: "⌥⇧1")]
            )),
            ("user-action", PromptModeDraft(mode: user), AIActionDetailContext(saved: user, shortcutBadge: nil)),
            ("new", PromptModeDraft(), AIActionDetailContext()),
        ]
        for (name, draft, context) in details {
            for (size, appearance) in [(NSSize(width: 640, height: 680), light), (NSSize(width: 640, height: 680), dark),
                                       (NSSize(width: 560, height: 520), light), (NSSize(width: 640, height: 1_700), light)] {
                guard name == "clean-up-default" || size.height != 520 || appearance.0 == "light" else { continue }
                let view = AIActionEditorView(
                    viewModel: actions, draft: .constant(draft), isBuiltIn: context.saved?.isBuiltIn ?? false,
                    context: context, onSave: {}, onCancel: {}
                )
                .frame(width: size.width, height: size.height)
                let image = LayoutSnapshotTests.render(view, size: size, appearance: appearance.1, scale: size.height > 1_000 ? 1 : 2)
                let label = "detail-\(name)-\(size.height > 1_000 ? "full" : "\(Int(size.width))x\(Int(size.height))")-\(appearance.0)"
                try LayoutSnapshotTests.write(image, to: out.appendingPathComponent("\(label).png"))
                sheet.append((label, image))
            }
        }

        // ≤ 8000 px on the longest side (at 2×): 8 columns of 420 pt tiles.
        let contact = PanelSnapshotTests.contactSheet(panels: sheet, icons: [], tile: NSSize(width: 420, height: 300), columns: 8)
        try LayoutSnapshotTests.write(contact, to: out.deletingLastPathComponent().appendingPathComponent("q3-ai-actions-contact-sheet.png"))
    }
}
