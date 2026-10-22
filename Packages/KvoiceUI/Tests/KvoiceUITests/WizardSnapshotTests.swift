import AppKit
import SwiftUI
import KvoiceTestSupport
import XCTest
@testable import KvoiceDomain
@testable import KvoiceUI

/// UI v2 wave 3 / fidelity F4, opt-in like `PanelSnapshotTests`: every
/// setup-wizard step and state the design draws, light and dark, both
/// editions where they differ (the Accessibility step and Ready's
/// checklist), and three screens at the window's 560×520 minimum —
/// `fidelity-wizard/wizard-<state>-<light|dark>.png` and
/// `fidelity-wizard-contact-sheet.png` beside the folder. Set
/// `KVOICE_LAYOUT_SNAPSHOTS=<dir>`. Nothing is asserted about pixels.
///
/// The permission states come from stub providers read before the render
/// (the view re-reads them on appear, and a Granted older than 3 s presents
/// as Unknown), so what is drawn is what the app would show.
@MainActor
final class WizardSnapshotTests: XCTestCase {
    private func outputDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["KVOICE_LAYOUT_SNAPSHOTS"] else {
            throw XCTSkip("Set KVOICE_LAYOUT_SNAPSHOTS=<dir> to render layout snapshots")
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let out = root.appendingPathComponent("fidelity-wizard", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    struct Shot {
        let name: String
        let model: OnboardingViewModel
        var ai: AISettingsViewModel?
        var audio: AudioInputViewModel?
        var size = NSSize(width: 640, height: 640)
        var appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        /// Read the stubs again just before the render; off for a shot
        /// whose permission request is held open.
        var refresh = true
    }

    func testRenderEveryWizardState() async throws {
        let out = try outputDirectory()
        var sheet: [(String, NSImage)] = []
        for shot in try await shots() {
            for (label, appearance) in shot.appearances {
                // Fresh readings just before the render, as the 1–2 s poll
                // keeps them in the app.
                if shot.refresh {
                    await shot.model.refreshPermissions()
                }
                let view = OnboardingView(viewModel: shot.model, aiSettingsViewModel: shot.ai, audioInput: shot.audio, overrides: .init(reduceMotion: true))
                let image = LayoutSnapshotTests.render(view, size: shot.size, appearance: appearance, scale: 2)
                let sizeLabel = shot.size.width == 640 ? "" : "-\(Int(shot.size.width))x\(Int(shot.size.height))"
                let file = "wizard-\(shot.name)\(sizeLabel)-\(label).png"
                try LayoutSnapshotTests.write(image, to: out.appendingPathComponent(file))
                sheet.append(("\(shot.name)\(sizeLabel) · \(label)", image))
            }
        }
        let contact = PanelSnapshotTests.contactSheet(panels: sheet, icons: [], tile: NSSize(width: 400, height: 400), columns: 8)
        try LayoutSnapshotTests.write(contact, to: out.deletingLastPathComponent().appendingPathComponent("fidelity-wizard-contact-sheet.png"))
    }

    // MARK: States

    private let whisper = SpeechModelCatalogEntry(
        id: "whisper-large-v3-turbo", displayName: "Whisper v3 Turbo", variantName: "Standard",
        family: "whisper", runtime: .whisperKitCoreML, hosting: .onDevice,
        supportsStreaming: true, supportsBatch: true, downloadBytes: 650_000_000,
        languageSummary: "99 languages", summary: "", isRecommended: true,
        revision: "r", manifestResource: "whisper", manifestSHA256: "abc"
    )
    private let apple = SpeechModelCatalogEntry(
        id: "apple-speech", displayName: "Apple Speech", variantName: "",
        family: "apple-speech", runtime: .appleSpeech, hosting: .onDevice,
        supportsStreaming: true, supportsBatch: true, downloadBytes: 0,
        languageCodes: ["en"], languageSummary: "1 language on this Mac",
        summary: "", isRecommended: false, revision: "system",
        manifestResource: "", manifestSHA256: "", assetSource: .systemManaged
    )
    private let readyModel = ModelLifecycleState.ready(InstalledModelSummary(
        modelID: "whisper-large-v3-turbo", revision: "r", ownership: .managedByKvoice
    ))
    private let shortcut = GeneralSettingsViewModel.recommendedShortcut
    private let passed = MicrophoneTestState.completed(MicrophoneTestResult(duration: .seconds(3), peakLevelDBFS: -12, capturedSamples: 48_000))

    private func make(
        _ stage: OnboardingStage,
        model: ModelLifecycleState = .absent,
        entry: SpeechModelCatalogEntry? = nil,
        microphone: PermissionAuthorization = .notDetermined,
        microphoneTest: MicrophoneTestState = .notStarted,
        trusted: Bool = false,
        interaction: RecordingInteraction = .pushToTalk,
        shortcut: ShortcutDefinition? = nil,
        edition: DistributionEdition = .developerID,
        clock: any KvoiceClock = SystemKvoiceClock()
    ) -> OnboardingViewModel {
        let vm = OnboardingViewModel(
            stage: stage,
            modelState: model,
            modelEntry: entry ?? whisper,
            microphoneAuthorization: microphone,
            accessibilityStatus: trusted ? .granted : .notDetermined,
            microphoneTestState: microphoneTest,
            recordingInteraction: interaction,
            shortcut: shortcut,
            microphonePermission: SnapshotMicrophone(value: microphone),
            accessibilityPermission: SnapshotAccessibility(trusted: trusted),
            edition: edition,
            clock: clock
        )
        vm.inputDeviceNameProvider = { "MacBook Pro Microphone" }
        return vm
    }

    private func shots() async throws -> [Shot] {
        var shots: [Shot] = []
        let dark: [(String, NSAppearance.Name)] = [("dark", .darkAqua)]
        let light: [(String, NSAppearance.Name)] = [("light", .aqua)]

        // 1 Welcome
        shots.append(Shot(name: "1-welcome", model: make(.welcome)))

        // 2 Model
        let notInstalled = make(.speechModel)
        notInstalled.setAlternativeModelEntry(apple)
        notInstalled.setModelSpaceEstimate(requiredBytes: 650_000_000, availableBytes: 120_000_000_000)
        shots.append(Shot(name: "2-model-not-installed", model: notInstalled))
        let builtIn = make(.speechModel, entry: apple)
        builtIn.setAlternativeModelEntry(whisper)
        shots.append(Shot(name: "2-model-built-in", model: builtIn, appearances: light))
        let downloading = make(.speechModel, model: .downloading(completed: 273_000_000, total: 650_000_000))
        shots.append(Shot(name: "2-model-downloading", model: downloading))
        shots.append(Shot(name: "2-model-verifying", model: make(.speechModel, model: .verifying(completedFiles: 7, totalFiles: 9)), appearances: light))
        shots.append(Shot(name: "2-model-optimizing", model: make(.speechModel, model: .optimizing), appearances: light))
        let modelReady = make(.speechModel, model: readyModel)
        modelReady.setModelSpaceEstimate(requiredBytes: 650_000_000, availableBytes: 120_000_000_000)
        shots.append(Shot(name: "2-model-ready", model: modelReady))
        shots.append(Shot(name: "2-model-paused", model: make(.speechModel, model: .downloadPaused(resumableBytes: 273_000_000)), appearances: light))
        shots.append(Shot(name: "2-model-failed", model: make(.speechModel, model: .corrupt(ModelFailure(code: "modelCorrupt", message: "One file did not match the manifest.")))))
        let noSpace = make(.speechModel)
        noSpace.setAlternativeModelEntry(apple)
        noSpace.setModelSpaceEstimate(requiredBytes: 650_000_000, availableBytes: 410_000_000)
        shots.append(Shot(name: "2-model-no-space", model: noSpace, appearances: dark))

        // 3 Microphone
        shots.append(Shot(name: "3-mic-not-requested", model: make(.microphone, model: readyModel), appearances: light))
        let prompting = make(.microphone, model: readyModel)
        Task { @MainActor in await prompting.requestMicrophonePermission() }
        while !prompting.isRequestingMicrophonePermission {
            await Task.yield()
        }
        shots.append(Shot(name: "3-mic-prompt-open", model: prompting, appearances: light, refresh: false))
        let devices = AudioInputViewModel(deviceProvider: SnapshotDevices())
        shots.append(Shot(name: "3-mic-allowed-untested", model: make(.microphone, model: readyModel, microphone: .granted), audio: devices, appearances: light))
        let listening = make(.microphone, model: readyModel, microphone: .granted, microphoneTest: .running)
        listening.updateMicrophoneLevel(rmsDBFS: -22, peakDBFS: -18)
        shots.append(Shot(name: "3-mic-listening", model: listening, appearances: light))
        let micPassed = make(.microphone, model: readyModel, microphone: .granted, microphoneTest: passed)
        micPassed.updateMicrophoneLevel(rmsDBFS: -20, peakDBFS: -12)
        shots.append(Shot(name: "3-mic-passed", model: micPassed))
        shots.append(Shot(name: "3-mic-denied", model: make(.microphone, model: readyModel, microphone: .denied), appearances: light))

        // 4 Accessibility, both editions
        for edition in [DistributionEdition.developerID, .appStore] {
            let tag = edition == .appStore ? "-appstore" : ""
            shots.append(Shot(name: "4-ax-not-requested\(tag)", model: make(.accessibility, model: readyModel, microphone: .granted, microphoneTest: passed, edition: edition), appearances: light))
            let waiting = make(.accessibility, model: readyModel, microphone: .granted, microphoneTest: passed, edition: edition)
            await waiting.requestAccessibilityPermission()
            shots.append(Shot(name: "4-ax-waiting\(tag)", model: waiting))
            shots.append(Shot(name: "4-ax-allowed\(tag)", model: make(.accessibility, model: readyModel, microphone: .granted, microphoneTest: passed, trusted: true, edition: edition), appearances: edition == .appStore ? light : [("light", .aqua), ("dark", .darkAqua)]))
        }

        // 5 Shortcut
        let base = (model: readyModel, microphone: PermissionAuthorization.granted, test: passed)
        shots.append(Shot(name: "5-shortcut-none", model: make(.shortcut, model: base.model, microphone: base.microphone, microphoneTest: base.test, trusted: true), appearances: light))
        let recordingKeys = make(.shortcut, model: base.model, microphone: base.microphone, microphoneTest: base.test, trusted: true)
        recordingKeys.setShortcutRecorderOpen(true)
        shots.append(Shot(name: "5-shortcut-recording-keys", model: recordingKeys, appearances: light))
        let conflict = make(.shortcut, model: base.model, microphone: base.microphone, microphoneTest: base.test, trusted: true,
                            shortcut: ShortcutDefinition(key: "space", modifiers: ["command"]))
        conflict.setShortcutRegistrationState(.failed(.hotkeyRegistrationFailed), problem: .takenBySystem)
        shots.append(Shot(name: "5-shortcut-conflict", model: conflict, appearances: light))
        let tryIt = make(.shortcut, model: base.model, microphone: base.microphone, microphoneTest: base.test, trusted: true, shortcut: shortcut)
        shots.append(Shot(name: "5-shortcut-try-it", model: tryIt, appearances: light))
        let holding = make(.shortcut, model: base.model, microphone: base.microphone, microphoneTest: base.test, trusted: true, shortcut: shortcut)
        holding.beginHotkeyTest()
        holding.reportHotkeyTestKeyDown(at: Date().addingTimeInterval(-1.2))
        holding.tickHotkeyTest()
        shots.append(Shot(name: "5-shortcut-holding", model: holding))
        let detected = make(.shortcut, model: base.model, microphone: base.microphone, microphoneTest: base.test, trusted: true, shortcut: shortcut)
        detected.beginHotkeyTest()
        detected.reportHotkeyTestKeyDown(at: Date().addingTimeInterval(-1))
        detected.reportHotkeyTestKeyUp()
        shots.append(Shot(name: "5-shortcut-detected", model: detected))
        let tooShort = make(.shortcut, model: base.model, microphone: base.microphone, microphoneTest: base.test, trusted: true, shortcut: shortcut)
        tooShort.beginHotkeyTest()
        tooShort.reportHotkeyTestKeyDown(at: Date().addingTimeInterval(-0.3))
        tooShort.reportHotkeyTestKeyUp()
        shots.append(Shot(name: "5-shortcut-too-short", model: tooShort, appearances: light))
        let toggle = make(.shortcut, model: base.model, microphone: base.microphone, microphoneTest: base.test, trusted: true, interaction: .toggle, shortcut: shortcut)
        toggle.beginHotkeyTest()
        toggle.reportHotkeyTestKeyDown()
        toggle.reportHotkeyTestKeyUp()
        shots.append(Shot(name: "5-shortcut-toggle-started", model: toggle, appearances: light))

        // 6 Ready
        func allReady(_ edition: DistributionEdition = .developerID, clock: any KvoiceClock = SystemKvoiceClock()) -> OnboardingViewModel {
            make(.ready, model: readyModel, microphone: .granted, microphoneTest: passed, trusted: true, shortcut: shortcut, edition: edition, clock: clock)
        }
        shots.append(Shot(name: "6-ready-all", model: allReady()))
        shots.append(Shot(name: "6-ready-all-appstore", model: allReady(.appStore), appearances: light))
        let recordingClock = ManualClock()
        let recording = allReady(clock: recordingClock)
        recording.requestDictationTest()
        recordingClock.advance(by: .seconds(4))
        recording.dictationTestLevel.apply(raw: 0.7, elapsed: 1)
        shots.append(Shot(name: "6-ready-recording", model: recording))
        let resultClock = ManualClock()
        let result = allReady(clock: resultClock)
        result.requestDictationTest()
        result.setDictationTestRecording(false)
        resultClock.advance(by: .milliseconds(400))
        result.setDictationTestResult(.transcript("Testing one two three — this is my first dictation with KVoice."))
        shots.append(Shot(name: "6-ready-result", model: result, appearances: light))
        let skipped = make(.accessibility, model: .downloading(completed: 416_000_000, total: 650_000_000), microphone: .granted, microphoneTest: passed, shortcut: shortcut)
        skipped.skipAccessibility()
        skipped.advance()
        shots.append(Shot(name: "6-ready-some-skipped", model: skipped))
        let blocked = make(.accessibility, model: readyModel, microphone: .denied)
        blocked.skipAccessibility()
        blocked.skipShortcut()
        shots.append(Shot(name: "6-ready-blocked", model: blocked, appearances: light))
        shots.append(Shot(name: "6-ready-ai-on", model: allReady(), ai: .previewConfigured(), appearances: light))

        // The window's minimum size, where the bar's reason stacks.
        shots.append(Shot(name: "2-model-downloading", model: downloading, size: NSSize(width: 560, height: 520), appearances: light))
        shots.append(Shot(name: "5-shortcut-try-it", model: tryIt, size: NSSize(width: 560, height: 520), appearances: light))
        shots.append(Shot(name: "6-ready-all", model: allReady(), size: NSSize(width: 560, height: 520), appearances: light))
        shots.append(Shot(name: "6-ready-all", model: allReady(), size: NSSize(width: 560, height: 520), appearances: dark))
        return shots
    }
}

// MARK: Snapshot doubles

private struct SnapshotMicrophone: MicrophonePermissionProviding {
    let value: PermissionAuthorization
    func authorization() async -> PermissionAuthorization { value }
    func requestAccess() async -> PermissionAuthorization {
        // The "prompt open" state: the request never returns during the run.
        try? await Task.sleep(for: .seconds(600))
        return value
    }
}

private struct SnapshotDevices: AudioInputDeviceProviding {
    func availableInputDevices() -> [AudioInputDevice] {
        [AudioInputDevice(uid: "builtin", name: "MacBook Pro Microphone"), AudioInputDevice(uid: "usb", name: "USB Microphone")]
    }

    func systemDefaultInputDevice() -> AudioInputDevice? {
        AudioInputDevice(uid: "builtin", name: "MacBook Pro Microphone")
    }
}

private struct SnapshotAccessibility: AccessibilityPermissionProviding {
    let trusted: Bool
    func isTrusted(prompt: Bool) async -> Bool { trusted }
}
