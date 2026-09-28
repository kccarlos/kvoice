import AppKit
import SwiftUI
import XCTest
import KvoiceDomain
@testable import KvoiceUI

/// The gallery for the 2026-09-16 design review
/// (`Docs/Design/Design-Review-2026-09-16.md`): every surface the review
/// covers, rendered offscreen through `LayoutSnapshotTests.render` in light
/// and dark, plus the proposed status-panel mock and the status menu's
/// header row. Opt-in like its sibling — set `KVOICE_LAYOUT_SNAPSHOTS=<dir>`
/// and the PNGs land in `<dir>/<gallery>/` and `<dir>/mock/`, where
/// `<gallery>` is `KVOICE_DESIGN_GALLERY` (default `after`); skipped
/// otherwise so the suite stays fast. Nothing is asserted about pixels.
///
/// Regenerate the committed gallery with
/// `KVOICE_LAYOUT_SNAPSHOTS=Docs/Design ./Scripts/test.sh --filter DesignGalleryTests`.
/// `Docs/Design/before/` is the frozen pre-review state and is never
/// regenerated. The `NSMenu` itself cannot be rendered offscreen; its plain
/// rows are described from `AppDelegate+Menu.swift`, and only the hosted
/// header row (P-D3) is rendered here, in a stand-in menu frame. What the
/// harness cannot show is listed in `Docs/Design/README.md`.
@MainActor
final class DesignGalleryTests: XCTestCase {
    private struct Output {
        /// `<dir>/<gallery>/`: `after` by default.
        let before: URL
        let mock: URL
    }

    private func output() throws -> Output {
        guard let directory = ProcessInfo.processInfo.environment["KVOICE_LAYOUT_SNAPSHOTS"] else {
            throw XCTSkip("Set KVOICE_LAYOUT_SNAPSHOTS=<dir> to render the design gallery")
        }
        let gallery = ProcessInfo.processInfo.environment["KVOICE_DESIGN_GALLERY"] ?? "after"
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let before = root.appendingPathComponent(gallery, isDirectory: true)
        let mock = root.appendingPathComponent("mock", isDirectory: true)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mock, withIntermediateDirectories: true)
        return Output(before: before, mock: mock)
    }

    private static let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    // MARK: Main window

    /// Every sidebar section at a realistic 900×620 in light; the five
    /// pages with the most controls again in dark and at a narrow 700×520
    /// (the offscreen sidebar's vibrancy makes every main-window PNG about
    /// 100 KB, so the set is kept to what the review cites):
    /// `main-<section>-<size>-<appearance>.png`.
    func testRenderMainWindowGallery() throws {
        let out = try output()
        let dense: Set<MainWindowSection> = [.shortcuts, .recording, .models, .aiActions, .general, .dataPrivacy]
        for section in MainWindowSection.allCases {
            var renders: [(String, NSSize, String, NSAppearance.Name)] = [("900x620", NSSize(width: 900, height: 620), "light", .aqua)]
            if dense.contains(section) {
                renders.append(("900x620", NSSize(width: 900, height: 620), "dark", .darkAqua))
                renders.append(("700x520", NSSize(width: 700, height: 520), "light", .aqua))
            }
            do {
                for (sizeLabel, size, appearanceLabel, appearance) in renders {
                    let model = MainWindowModel(selection: section)
                    let view = MainWindowView(model: model) { section in
                        section == .models ? Self.seededModelsSection() : LayoutSnapshotTests.content(for: section)
                    }
                    let image = LayoutSnapshotTests.render(view, size: size, appearance: appearance, hostInController: section != .history)
                    try LayoutSnapshotTests.write(
                        image,
                        to: out.before.appendingPathComponent("main-\(section.rawValue)-\(sizeLabel)-\(appearanceLabel).png")
                    )
                }
            }
        }
        // The sidebar on its own: inside the split view the offscreen
        // render fades its vibrant list after the first few rows, so the
        // groups and symbols are shown here as a plain sidebar-style list.
        for (appearanceLabel, appearance) in Self.appearances {
            let sidebar = List(selection: .constant(Optional(MainWindowSection.recording))) {
                ForEach(MainWindowSectionGroup.allCases) { group in
                    Section(group.title) {
                        ForEach(group.sections) { section in
                            Label(section.title, systemImage: section.symbolName).tag(section)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            try LayoutSnapshotTests.write(
                LayoutSnapshotTests.render(sidebar, size: NSSize(width: 220, height: 560), appearance: appearance),
                to: out.before.appendingPathComponent("main-sidebar-220x560-\(appearanceLabel).png")
            )
        }
        // The one-time tutorial banner over the default (History) section.
        let banner = MainWindowModel(selection: .history, showTutorialBanner: true)
        let bannerView = MainWindowView(model: banner) { LayoutSnapshotTests.content(for: $0) }
        try LayoutSnapshotTests.write(
            LayoutSnapshotTests.render(bannerView, size: NSSize(width: 900, height: 620), appearance: .aqua, hostInController: false),
            to: out.before.appendingPathComponent("main-history-tutorial-banner-900x620-light.png")
        )
    }

    /// Screenshot (2026-09-16): the Models group header's
    /// Recommended/All picker and the Manage Models gear overlapped at
    /// 700–900 pt wide. `main-models-*` above only reaches the page's top
    /// (Current Model, Runtime); this renders tall enough that the Models
    /// catalog header is on screen, at both widths the bug was reported at:
    /// `models-header-<width>x1400-light.png`.
    func testRenderModelsHeaderControlsDoNotOverlap() throws {
        let out = try output()
        for width in [700, 900] {
            let size = NSSize(width: CGFloat(width), height: 1_400)
            let model = MainWindowModel(selection: .models)
            let view = MainWindowView(model: model) { _ in Self.seededModelsSection() }
            let image = LayoutSnapshotTests.render(view, size: size, appearance: .aqua)
            try LayoutSnapshotTests.write(
                image,
                to: out.before.appendingPathComponent("models-header-\(width)x1400-light.png")
            )
        }
    }

    /// The Speech Models page as it looks with a catalog: the recommended
    /// Whisper model installed, resident and default; a Parakeet model not
    /// installed; the Runtime card with a placement; the managed package
    /// below. `LayoutSnapshotTests.content(for:)` renders the page with no
    /// catalog, which is what a bare view model gives.
    static func seededModelsSection() -> AnyView {
        let whisper = SpeechModelCatalogEntry(
            id: "whisper-large-v3-turbo-coreml-uncompressed", displayName: "Whisper large-v3-turbo", variantName: "Standard",
            family: "whisper-large-v3-turbo", runtime: .whisperKitCoreML, hosting: .onDevice,
            supportsStreaming: true, supportsBatch: true, downloadBytes: 1_640_000_000,
            languageSummary: "99 languages", summary: "The recommended model: accurate, multilingual, and fast enough on Apple silicon.", isRecommended: true,
            revision: "04e5c42d", manifestResource: "whisper", manifestSHA256: String(repeating: "a", count: 64)
        )
        let parakeet = SpeechModelCatalogEntry(
            id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT 0.6B v3", variantName: "Standard",
            family: "parakeet-tdt", runtime: .fluidAudioParakeetTDT, hosting: .onDevice,
            supportsStreaming: false, supportsBatch: true, downloadBytes: 650_000_000,
            languageSummary: "25 European languages", summary: "Faster on short clips; batch only.", isRecommended: false,
            revision: "v3", manifestResource: "parakeet", manifestSHA256: String(repeating: "b", count: 64)
        )
        let summary = InstalledModelSummary(modelID: whisper.id, revision: "04e5c42d80a522518023727e8c7e68d4bb391b28", ownership: .managedByKvoice)
        let modelsSnapshot = SpeechModelsSnapshot(
            catalog: SpeechModelCatalog(entries: [whisper, parakeet]),
            states: [whisper.id: .ready(summary), parakeet.id: .absent],
            defaultModelID: whisper.id,
            residentModelID: whisper.id,
            dictationIsActive: false,
            activity: .idle
        )
        // The providers return the seed, so the section's own poll (it runs
        // while the render settles) keeps it instead of clearing it.
        let speechModels = SpeechModelsViewModel(snapshot: modelsSnapshot, snapshotProvider: { modelsSnapshot })
        let runtimeSnapshot = RuntimeSnapshot(
            residentModelID: whisper.id,
            residentModelName: "Whisper large-v3-turbo",
            computeUnits: .neuralEngineAndCPU,
            placement: ModelPlacementReport(
                modelID: whisper.id,
                computeUnits: .neuralEngineAndCPU,
                encoder: ModelPlacement(operationCounts: [.neuralEngine: 970, .gpu: 0, .cpu: 30]),
                decoder: ModelPlacement(operationCounts: [.neuralEngine: 880, .gpu: 0, .cpu: 120])
            ),
            placementIsPending: false,
            statistics: .init(),
            isReloading: false,
            dictationIsActive: false,
            isExercisingRuntime: false,
            computeUnitsAvailability: .enabled
        )
        let runtime = RuntimeCardViewModel(snapshot: runtimeSnapshot, snapshotProvider: { runtimeSnapshot })
        let viewModel = ModelSettingsViewModel(
            state: .ready(summary),
            descriptor: ModelDescriptor(
                modelID: whisper.id,
                revision: "04e5c42d80a522518023727e8c7e68d4bb391b28",
                source: .managed(URL(fileURLWithPath: "/Users/me/Library/Application Support/kvoice/model")),
                installedBytes: 1_640_000_000,
                repository: "argmaxinc/whisperkit-coreml",
                manifestSchemaVersion: 1
            ),
            speechModels: speechModels,
            runtime: runtime
        )
        return AnyView(ModelSettingsView(viewModel: viewModel))
    }

    // MARK: AI action editor sheet

    /// Screenshot (2026-09-16): the editor's Icon+Title row wrapped
    /// "Icon" to "Ico n", squeezed the icon field to a sliver beside Title,
    /// and left Title's field out of line with Description's below it —
    /// packing both fields into one HStack made the Form compute one shared
    /// label column for the pair instead of a row each. Rendered at the
    /// sheet's own ideal size (640×680) and its minimum (560×520), so the
    /// label column is proven not to wrap at either: `ai-action-editor-<size>-light.png`.
    func testRenderAIActionEditorSheet() throws {
        let out = try output()
        let viewModel = PromptModeSettingsViewModel.previewSeeded()
        let draft = PromptModeDraft(
            name: "Meeting Notes",
            behavior: .polish,
            prompt: "Summarize the transcript into short action items, one per line.",
            summary: "Turns a rambling transcript into a short action list.",
            icon: "📝"
        )
        let view = AIActionEditorView(
            viewModel: viewModel,
            draft: .constant(draft),
            isBuiltIn: false,
            onSave: {},
            onCancel: {}
        )
        for (label, size) in [("640x680", NSSize(width: 640, height: 680)), ("560x520", NSSize(width: 560, height: 520))] {
            let image = LayoutSnapshotTests.render(view, size: size, appearance: .aqua, hostInController: false)
            try LayoutSnapshotTests.write(image, to: out.before.appendingPathComponent("ai-action-editor-\(label)-light.png"))
        }
    }

    // MARK: History

    /// Screenshot (2026-09-16): the History list (the left pane of its
    /// nested `NavigationSplitView`) disappeared — the detail pane filled
    /// the whole area — when the main window was resized horizontally. A
    /// single fixed-size render never reproduced it (every width above
    /// showed the list); only resizing an *already-laid-out* window does,
    /// so this drags one window wide → narrow → wide again, with a loaded
    /// (not "Loading History…") view model:
    /// `history-list-resize-<step>-<width>x620-light.png`.
    func testRenderHistoryListNeverCollapses() async throws {
        let out = try output()
        let viewModel = HistoryViewModel(repository: PreviewHistoryRepository())
        await viewModel.refresh()
        let model = MainWindowModel(selection: .history)
        let view = MainWindowView(model: model) { _ in AnyView(HistoryView(viewModel: viewModel)) }
        let widths = [900, 800, 720, 640, 900]
        let images = LayoutSnapshotTests.renderResizeSequence(
            view,
            sizes: widths.map { NSSize(width: CGFloat($0), height: 620) },
            appearance: .aqua
        )
        for (index, image) in images.enumerated() {
            let step = String(format: "%02d", index)
            try LayoutSnapshotTests.write(
                image,
                to: out.before.appendingPathComponent("history-list-resize-\(step)-\(widths[index])x620-light.png")
            )
        }
    }

    // MARK: Setup wizard

    /// Every one of the six stages (P-W1) at the wizard's default 640×640,
    /// the states that change a stage's layout (downloading, level test,
    /// Try It waiting / held, Hybrid, a test transcript, AI on), and the
    /// 560×520 minimum for the two stages whose buttons stack:
    /// `wizard-<stage>[-<state>]-<size>-<appearance>.png`.
    func testRenderWizardGallery() throws {
        let out = try output()
        let full = NSSize(width: 640, height: 640)
        let minimum = NSSize(width: 560, height: 520)
        let readyModel = ModelLifecycleState.ready(InstalledModelSummary(
            modelID: "whisper-large-v3-turbo-coreml-uncompressed",
            revision: "04e5c42d80a522518023727e8c7e68d4bb391b28",
            ownership: .managedByKvoice
        ))
        let shortcut = GeneralSettingsViewModel.recommendedShortcut

        var pages: [(String, OnboardingView, NSSize)] = []
        pages.append(("welcome", OnboardingView(viewModel: OnboardingViewModel()), full))
        pages.append(("model", OnboardingView(viewModel: OnboardingViewModel(stage: .speechModel)), full))
        // 2026-09-16: the card names the current model; a non-Whisper entry
        // is the case the literal used to get wrong.
        pages.append(("model-parakeet", OnboardingView(viewModel: OnboardingViewModel(
            stage: .speechModel,
            modelEntry: SpeechModelCatalogEntry(
                id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT 0.6B v3", variantName: "Standard",
                family: "parakeet-tdt", runtime: .fluidAudioParakeetTDT, hosting: .onDevice,
                supportsStreaming: false, supportsBatch: true, downloadBytes: 650_000_000,
                languageSummary: "25 European languages", summary: "Faster on short clips; batch only.", isRecommended: false,
                revision: "v3", manifestResource: "parakeet", manifestSHA256: String(repeating: "b", count: 64)
            )
        )), full))
        pages.append(("model-downloading", OnboardingView(viewModel: OnboardingViewModel(
            stage: .speechModel,
            modelState: .downloading(completed: 640_000_000, total: 1_600_000_000)
        )), full))
        pages.append(("model-downloading", OnboardingView(viewModel: OnboardingViewModel(
            stage: .speechModel,
            modelState: .downloading(completed: 640_000_000, total: 1_600_000_000)
        )), minimum))
        pages.append(("microphone", OnboardingView(viewModel: OnboardingViewModel(stage: .microphone, modelState: readyModel)), full))
        pages.append(("microphone-granted", OnboardingView(viewModel: OnboardingViewModel(
            stage: .microphone, modelState: readyModel, microphoneAuthorization: .granted
        )), full))
        pages.append(("accessibility", OnboardingView(viewModel: OnboardingViewModel(
            stage: .accessibility, modelState: readyModel, microphoneAuthorization: .granted
        )), full))
        pages.append(("shortcut", OnboardingView(viewModel: OnboardingViewModel(
            stage: .shortcut, modelState: readyModel, microphoneAuthorization: .granted, accessibilityStatus: .granted
        )), full))
        // P-W1: once a shortcut is registered the Try It indicator sits on
        // the same page, under the recorder; "held" is mid-press.
        pages.append(("shortcut-try-it", OnboardingView(viewModel: OnboardingViewModel(
            stage: .shortcut, modelState: readyModel, microphoneAuthorization: .granted, accessibilityStatus: .granted, shortcut: shortcut
        )), full))
        let held = OnboardingViewModel(
            stage: .shortcut, modelState: readyModel, microphoneAuthorization: .granted, accessibilityStatus: .granted, shortcut: shortcut
        )
        held.beginHotkeyTest()
        held.reportHotkeyTestKeyDown()
        held.tickHotkeyTest(now: Date().addingTimeInterval(0.8))
        pages.append(("shortcut-try-it-held", OnboardingView(viewModel: held), full))
        pages.append(("shortcut-try-it", OnboardingView(viewModel: OnboardingViewModel(
            stage: .shortcut, modelState: readyModel, microphoneAuthorization: .granted, accessibilityStatus: .granted, shortcut: shortcut
        )), minimum))
        // P-W3: Hybrid in the wizard's radio group.
        let hybrid = OnboardingViewModel(
            stage: .shortcut, modelState: readyModel, microphoneAuthorization: .granted, accessibilityStatus: .granted,
            recordingInteraction: .hybrid, shortcut: shortcut
        )
        pages.append(("shortcut-hybrid", OnboardingView(viewModel: hybrid), full))
        pages.append(("ready", OnboardingView(viewModel: OnboardingViewModel(
            stage: .ready, modelState: readyModel, microphoneAuthorization: .granted, accessibilityStatus: .granted, shortcut: shortcut
        )), full))
        let readyWithTranscript = OnboardingViewModel(
            stage: .ready, modelState: readyModel, microphoneAuthorization: .granted, accessibilityStatus: .granted, shortcut: shortcut
        )
        readyWithTranscript.setDictationTestResult(.transcript("This is what the recorder heard."))
        pages.append(("ready-transcript", OnboardingView(viewModel: readyWithTranscript), full))
        pages.append(("ready-deferred", OnboardingView(viewModel: OnboardingViewModel(stage: .ready)), full))
        // Ready with AI configured: the summary's AI and privacy lines.
        pages.append(("ready-ai-on", OnboardingView(
            viewModel: OnboardingViewModel(
                stage: .ready, modelState: readyModel, microphoneAuthorization: .granted, accessibilityStatus: .granted, shortcut: shortcut
            ),
            aiSettingsViewModel: .previewConfigured()
        ), full))

        // Every one of the six pages in dark, plus the two states most
        // likely to hide a contrast problem.
        let darkSubset: Set<String> = ["welcome", "model", "model-downloading", "microphone", "accessibility", "shortcut", "shortcut-try-it", "ready", "ready-transcript"]
        for (label, view, size) in pages {
            let sizeLabel = "\(Int(size.width))x\(Int(size.height))"
            let appearances = darkSubset.contains(label) && size == full ? Self.appearances : [("light", NSAppearance.Name.aqua)]
            for (appearanceLabel, appearance) in appearances {
                let image = LayoutSnapshotTests.render(view, size: size, appearance: appearance)
                try LayoutSnapshotTests.write(
                    image,
                    to: out.before.appendingPathComponent("wizard-\(label)-\(sizeLabel)-\(appearanceLabel).png")
                )
            }
        }

        // The standalone tutorial window (Help › Show Tutorial) on its last
        // page, with the Open kvoice pointers.
        let standalone = TutorialViewModel(page: .makeItYours, openMainWindowHandler: { _ in })
        try LayoutSnapshotTests.write(
            LayoutSnapshotTests.render(TutorialView(viewModel: standalone), size: full, appearance: .aqua),
            to: out.before.appendingPathComponent("tutorial-standalone-3-640x640-light.png")
        )
    }

    // MARK: Recorder HUD

    /// Both recorder styles through the states a dictation passes: starting
    /// mic, live recording, finishing (transcribing, polishing, inserting),
    /// completed (inserted, clipboard fallback), failed (recoverable,
    /// fatal), and blocked. Mini in light and dark (it is a material), Notch
    /// once (it is always black): `hud-<style>-<state>[-<appearance>].png`.
    func testRenderHUDGallery() throws {
        let out = try output()
        let ai = HUDAIIndicator(isEnabled: true, actionName: "Polish", shortcutBadge: "⌘1")
        let states: [(String, HUDViewState)] = [
            ("starting", HUDViewState(phase: .recording(HUDRecordingState(mode: .pushToTalk, ai: ai, captureStarted: false)))),
            ("recording", HUDViewState(phase: .recording(HUDRecordingState(inputLevel: 0.6, elapsed: .seconds(7), mode: .pushToTalk, ai: ai)))),
            ("recording-streaming", HUDViewState(
                phase: .recording(HUDRecordingState(inputLevel: 0.4, elapsed: .seconds(12), mode: .toggle, ai: HUDAIIndicator(isEnabled: false, actionName: "Translate", shortcutBadge: "⌘2"))),
                partialTranscript: "we should ship the menu bar work first and then look at the"
            )),
            ("recording-long", HUDViewState(phase: .recording(HUDRecordingState(inputLevel: 0.3, elapsed: .seconds(305), mode: .pushToTalk, ai: ai)))),
            ("transcribing", HUDViewState(phase: .transcribing)),
            ("polishing", HUDViewState(phase: .processingAI(HUDProcessingAIState(mode: .polish)))),
            ("inserting", HUDViewState(phase: .inserting)),
            ("inserted", HUDViewState(phase: .completed(HUDCompletionState(kind: .success)))),
            ("clipboard-fallback", HUDViewState(phase: .completed(HUDCompletionState(kind: .clipboardFallback, warningMessage: "Copied to the clipboard instead.")))),
            ("ai-fallback", HUDViewState(phase: .completed(HUDCompletionState(kind: .aiFallback, warningMessage: "The AI endpoint did not answer in time.")))),
            ("failed-recoverable", HUDViewState(
                phase: .failed(HUDFailureState(code: "insertion.failed", message: "Could not insert or copy the transcript.")),
                recoverableTranscript: "I think we should ship the menu bar work first, then look at the onboarding copy.",
                canRecoverFailedInsertion: true
            )),
            ("failed-fatal", HUDViewState(phase: .failed(HUDFailureState(
                code: "model.unavailable", message: "The speech model could not be loaded.", isFatal: true, settingsActionTitle: "Open Model Settings"
            )))),
            ("blocked", HUDViewState(phase: .blocked(HUDBlockedState(code: "microphone.denied", message: "Microphone access is off. Allow it in System Settings › Privacy & Security.")))),
        ]
        let canvas = NSSize(width: 560, height: 200)
        for (label, state) in states {
            for (appearanceLabel, appearance) in Self.appearances {
                let view = HUDGalleryFrame(dark: appearance == .darkAqua) {
                    HUDView(state: state, style: .mini)
                }
                let size = state.recoverableTranscript == nil ? canvas : NSSize(width: 560, height: 300)
                try LayoutSnapshotTests.write(
                    LayoutSnapshotTests.render(view, size: size, appearance: appearance),
                    to: out.before.appendingPathComponent("hud-mini-\(label)-\(appearanceLabel).png")
                )
            }
            let notch = HUDGalleryFrame(dark: false, menuBar: true) {
                HUDView(state: state, style: .notch, notchWidth: 420)
            }
            let size = state.recoverableTranscript == nil ? canvas : NSSize(width: 560, height: 300)
            try LayoutSnapshotTests.write(
                LayoutSnapshotTests.render(notch, size: size, appearance: .aqua),
                to: out.before.appendingPathComponent("hud-notch-\(label).png")
            )
        }
        // Reduce Motion and Increase Contrast cannot be injected here:
        // `accessibilityReduceMotion` and `colorSchemeContrast` are
        // read-only environment values, so the HUD's static-hourglass and
        // thick-material variants are described in the review from the
        // code (`HUDView.trailingSlot`, `HUDView.miniBackground`) rather
        // than rendered.
    }

    // MARK: Status menu header row (P-D3)

    /// The hosted header row through its states, light and dark, in a
    /// stand-in menu frame (the `NSMenu` cannot be rendered offscreen):
    /// `menu-header-<state>-<appearance>.png`. The real `NSMenuItem` host
    /// (`StatusMenuHeaderItemView`) is what is rendered, wrapped for the
    /// harness; the highlighted variant's selection material does not
    /// composite offscreen, so a flat accent stand-in is drawn behind it
    /// (see `Docs/Design/README.md`).
    func testRenderStatusMenuHeaderGallery() throws {
        let out = try output()
        let recording = HUDViewState(phase: .recording(HUDRecordingState(inputLevel: 0.6, elapsed: .seconds(7))))
        let states: [(String, StatusMenuHeaderContext, HUDViewState, Bool)] = [
            ("idle", StatusMenuHeaderContext(shortcutGlyphs: "⌃⇧Space"), .idle, false),
            ("idle-no-shortcut", StatusMenuHeaderContext(shortcutNote: "No Shortcut"), .idle, false),
            ("starting", StatusMenuHeaderContext(dictationKind: .recording, shortcutGlyphs: "⌃⇧Space"),
             HUDViewState(phase: .recording(HUDRecordingState(captureStarted: false))), false),
            ("recording", StatusMenuHeaderContext(dictationKind: .recording, shortcutGlyphs: "⌃⇧Space"), recording, false),
            ("recording-highlighted", StatusMenuHeaderContext(dictationKind: .recording, shortcutGlyphs: "⌃⇧Space"), recording, true),
            ("recording-finishing-badge", StatusMenuHeaderContext(dictationKind: .recording),
             HUDViewState(phase: .recording(HUDRecordingState(inputLevel: 0.4, elapsed: .seconds(12))), finishingCount: 1), false),
            ("finishing", StatusMenuHeaderContext(dictationKind: .transcribing), HUDViewState(phase: .transcribing), false),
            ("inserted", StatusMenuHeaderContext(dictationKind: .completed),
             HUDViewState(phase: .completed(HUDCompletionState(kind: .success))), false),
            ("blocked", StatusMenuHeaderContext(modelReady: false, shortcutGlyphs: "⌃⇧Space", attention: "Model not ready"), .idle, false),
            ("downloading", StatusMenuHeaderContext(
                modelReady: false, shortcutGlyphs: "⌃⇧Space", attention: "Model loading…",
                modelInstall: .init(modelName: "Whisper large-v3-turbo", fraction: 0.42)
            ), .idle, false),
        ]
        for (label, context, hud, highlighted) in states {
            for (appearanceLabel, appearance) in Self.appearances {
                let model = StatusMenuHeaderModel()
                model.apply(context: context)
                model.apply(hud: hud)
                model.isHighlighted = highlighted
                let view = MenuGalleryFrame(dark: appearance == .darkAqua) {
                    StatusMenuHeaderHostRepresentable(model: model)
                        .frame(height: StatusMenuHeaderView.rowHeight)
                        // The real highlight is a `.selection` material, which
                        // does not composite offscreen; a flat accent stand-in
                        // shows the inset and the white text instead.
                        .background {
                            if highlighted {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.accentColor)
                                    .padding(.horizontal, 5)
                            }
                        }
                }
                try LayoutSnapshotTests.write(
                    LayoutSnapshotTests.render(view, size: NSSize(width: 400, height: 150), appearance: appearance),
                    to: out.before.appendingPathComponent("menu-header-\(label)-\(appearanceLabel).png")
                )
            }
        }
    }

    // MARK: Status panel (P-D4)

    /// The real `StatusPanelView` over `StatusPanelModel` — the same seam
    /// the shell hosts — through the four phases of the approved mock and
    /// the three it did not draw, light and dark, in the mock's stand-in
    /// card over a stand-in desktop: `<gallery>/panel-<phase>-<appearance>.png`.
    /// In the app the panel sits in an `NSPopover`, whose own material,
    /// arrow and Liquid Glass cannot be rendered offscreen, and the view's
    /// standalone glass chrome flattens the colours inside it offscreen
    /// (see `Docs/Design/README.md`), so the render uses the hosted chrome
    /// inside `MockPanelCard`, as the mock drew itself.
    func testRenderStatusPanelGallery() throws {
        let out = try output()
        for (label, headerContext, hud, context) in StatusPanelTests.galleryPhases {
            for (appearanceLabel, appearance) in Self.appearances {
                let header = StatusMenuHeaderModel()
                header.apply(context: headerContext)
                header.apply(hud: hud)
                let model = StatusPanelModel(header: header)
                model.apply(context: context)
                model.isPresented = true
                let view = ZStack(alignment: .topTrailing) {
                    MockDesktopBackdrop()
                    MockPanelCard {
                        StatusPanelView(model: model, chrome: .hosted)
                    }
                    .padding(.top, 30)
                    .padding(.trailing, 28)
                }
                try LayoutSnapshotTests.write(
                    LayoutSnapshotTests.render(view, size: NSSize(width: 420, height: 680), appearance: appearance),
                    to: out.before.appendingPathComponent("panel-\(label)-\(appearanceLabel).png")
                )
            }
        }
    }

    // MARK: Proposed status panel (mock — superseded by P-D4)

    /// The Control-Center-style mock approved on 2026-09-16, kept
    /// as the spec the real panel above was built from: idle, recording,
    /// downloading and blocked, light and dark, over a stand-in desktop:
    /// `mock/panel-<phase>-<appearance>.png`.
    func testRenderStatusPanelMock() throws {
        let out = try output()
        let phases: [(StatusPanelMock.Phase, String)] = [(.idle, "idle"), (.recording, "recording"), (.downloading, "downloading"), (.blocked, "blocked")]
        for (phase, label) in phases {
            for (appearanceLabel, appearance) in Self.appearances {
                let view = ZStack(alignment: .topTrailing) {
                    MockDesktopBackdrop()
                    StatusPanelMock(phase: phase)
                        .padding(.top, 30)
                        .padding(.trailing, 28)
                }
                let size = NSSize(width: 420, height: 680)
                try LayoutSnapshotTests.write(
                    LayoutSnapshotTests.render(view, size: size, appearance: appearance),
                    to: out.mock.appendingPathComponent("panel-\(label)-\(appearanceLabel).png")
                )
            }
        }
    }
}

/// A stand-in for what sits behind the HUD: a document-like backdrop so the
/// Mini material has content to blur, and a menu-bar strip with a camera
/// housing for the Notch style, whose top edge sits on that line.
private struct HUDGalleryFrame<Content: View>: View {
    let dark: Bool
    var menuBar = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: menuBar ? .top : .center) {
            (dark ? Color(white: 0.16) : Color(white: 0.94))
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<9, id: \.self) { index in
                    Capsule()
                        .fill(dark ? Color.white.opacity(0.18) : Color.black.opacity(0.14))
                        .frame(width: CGFloat(200 + (index * 53) % 300), height: 9)
                }
            }
            .padding(.top, menuBar ? 56 : 24)
            .padding(.leading, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if menuBar {
                VStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        Rectangle().fill(Color.black.opacity(0.85)).frame(height: 24)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.black)
                            .frame(width: 150, height: 30)
                    }
                    content()
                }
            } else {
                content()
            }
        }
    }
}

/// The real `NSMenuItem` host of the header row, for the gallery.
private struct StatusMenuHeaderHostRepresentable: NSViewRepresentable {
    let model: StatusMenuHeaderModel

    func makeNSView(context: Context) -> StatusMenuHeaderItemView {
        let item = NSMenuItem(title: "Start Recording", action: nil, keyEquivalent: "")
        item.isEnabled = model.state.isEnabled
        let host = StatusMenuHeaderItemView.install(on: item, model: model)
        // Not in a menu: the highlight is driven from the model here.
        host.setHighlightedForGallery(model.isHighlighted)
        return host
    }

    func updateNSView(_ nsView: StatusMenuHeaderItemView, context: Context) {}
}

/// A stand-in for the menu around the header row: the menu's background,
/// the "Dictation" section header above it and two plain rows below, so the
/// row's alignment against a plain item can be judged. A drawing, not an
/// `NSMenu`.
private struct MenuGalleryFrame<Content: View>: View {
    let dark: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            (dark ? Color(white: 0.16) : Color(white: 0.94))
            VStack(alignment: .leading, spacing: 0) {
                Text("Dictation")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                content()
                plainRow("Cancel Current Dictation")
                plainRow("Copy Last Transcription")
            }
            .padding(.vertical, 5)
            // About the real menu's width, which its widest plain row sets
            // ("Model: Whisper large-v3-turbo — Standard").
            .frame(width: 360)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        }
    }

    private func plainRow(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13))
            .padding(.leading, 21)
            .frame(height: 22)
    }
}
