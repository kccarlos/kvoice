import SwiftUI
import XCTest
@testable import KvoiceDomain
@testable import KvoiceUI

/// The main window shell: section list, selection persistence, the shortcut
/// card, and the Help section's feedback mail.
@MainActor
final class MainWindowShellTests: XCTestCase {
    // MARK: Sections

    func testSidebarOrderMatchesTheProductDecision() {
        XCTAssertEqual(
            MainWindowSection.allCases,
            [
                .home, .history,
                .shortcuts, .recording, .models, .audioInput, .dictionary,
                .aiActions,
                .dataPrivacy, .permissions, .general, .help
            ]
        )
        for section in MainWindowSection.allCases {
            XCTAssertFalse(section.title.isEmpty)
            XCTAssertFalse(section.purpose.isEmpty)
            XCTAssertFalse(section.symbolName.isEmpty)
        }
        XCTAssertEqual(MainWindowSection.models.title, "Speech Models")
        XCTAssertEqual(MainWindowSection.shortcuts.title, "Shortcuts")
        XCTAssertEqual(MainWindowSection.audioInput.title, "Microphone")
        XCTAssertEqual(MainWindowSection.dictionary.title, "Dictionary")
        XCTAssertEqual(MainWindowSection(persisted: "dictionary"), .dictionary, "ADR-018: the section persists by raw value")
    }

    func testSidebarGroupsPartitionTheSectionsInOrder() {
        // Product decision #7 as regrouped by the owner on 2026-10-21 (UI
        // v2 wave 5a). Help is kept, last in App: the design drew no Help
        // row, and no page may be lost.
        XCTAssertEqual(MainWindowSectionGroup.allCases, [.top, .dictation, .ai, .app])
        XCTAssertEqual(MainWindowSectionGroup.top.sections, [.home, .history])
        XCTAssertEqual(MainWindowSectionGroup.dictation.sections, [.shortcuts, .recording, .models, .audioInput, .dictionary])
        XCTAssertEqual(MainWindowSectionGroup.ai.sections, [.aiActions])
        XCTAssertEqual(MainWindowSectionGroup.app.sections, [.dataPrivacy, .permissions, .general, .help])
        XCTAssertNil(MainWindowSectionGroup.top.title, "the top group is drawn without a heading")
        // Every section belongs to exactly one group, and the groups
        // concatenated are the sidebar order.
        XCTAssertEqual(MainWindowSectionGroup.allCases.flatMap(\.sections), MainWindowSection.allCases)
        for group in MainWindowSectionGroup.allCases where group != .top {
            XCTAssertFalse(group.title?.isEmpty ?? true, group.rawValue)
        }
    }

    func testPersistedSectionFallsBackToHomeForNilOrUnknownValues() {
        XCTAssertEqual(MainWindowSection(persisted: nil), .home)
        XCTAssertEqual(MainWindowSection(persisted: "not-a-section"), .home)
        XCTAssertEqual(MainWindowSection(persisted: "help"), .help)
        XCTAssertEqual(MainWindowSection(persisted: MainWindowSection.aiActions.rawValue), .aiActions)
    }

    /// Settings files written before the 2026-09-13 regroup stored "settings"
    /// for the one Settings page; it opens on the first of the pages that
    /// replaced it. Raw values that survived the regroup decode unchanged.
    func testRetiredPersistedSectionsMapToTheirReplacement() {
        XCTAssertEqual(MainWindowSection(persisted: "settings"), .shortcuts)
        XCTAssertEqual(MainWindowSection(persisted: "settings"), MainWindowSection.settingsEntry)
        for raw in ["history", "aiActions", "models", "permissions", "audioInput", "help"] {
            XCTAssertEqual(MainWindowSection(persisted: raw).rawValue, raw)
        }
        // A retired value must not also be a live case, or the map is dead.
        for retired in MainWindowSection.retiredRawValues.keys {
            XCTAssertNil(MainWindowSection(rawValue: retired), retired)
        }
    }

    /// Owner decision 2026-10-21: a new window opens on Home unless an entry
    /// point (a menu item, the panel, an App Intent) asked for a page.
    func testANewWindowOpensOnHomeUnlessAPageWasRequested() {
        XCTAssertEqual(MainWindowSection.opening(requested: nil), .home)
        XCTAssertEqual(MainWindowSection.opening(requested: .history), .history)
        XCTAssertEqual(MainWindowSection.opening(requested: .help), .help)
        XCTAssertEqual(MainWindowSection.home.tileFill, .ink)
        XCTAssertEqual(MainWindowSection.home.group, .top)
    }

    func testSelectionChangeIsReportedOnceAndOnlyWhenItChanges() {
        var reported: [MainWindowSection] = []
        let model = MainWindowModel(selection: .history) { reported.append($0) }

        model.select(.recording)
        model.select(.recording)
        model.selection = .help

        XCTAssertEqual(reported, [.recording, .help])
    }

    func testMainWindowSectionRoundTripsThroughLocalState() throws {
        // ADR-022 slice 5: the section is this Mac's state, not a setting.
        var state = LocalState()
        state.mainWindowSection = MainWindowSection.permissions.rawValue
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(LocalState.self, from: data)
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(MainWindowSection(persisted: decoded.mainWindowSection), .permissions)

        // A fresh local blob carries no section and opens on History.
        let fresh = try JSONDecoder().decode(LocalState.self, from: Data("{\"schemaVersion\":1}".utf8))
        XCTAssertNil(fresh.mainWindowSection)
    }

    // MARK: Shortcut card

    func testShortcutCardDerivesStatusAndActionFromConfirmationAndRegistration() {
        let shortcut = ShortcutDefinition(key: "space", modifiers: ["control", "shift"])

        let none = ShortcutCard(confirmed: nil, registration: .unregistered, lastChecked: nil)
        XCTAssertEqual(none.status, .notConfigured)
        XCTAssertEqual(none.action, .confirmRecommended)
        XCTAssertNil(none.readout)

        let registered = ShortcutCard(confirmed: shortcut, registration: .registered(shortcut), lastChecked: Date())
        XCTAssertEqual(registered.status, .registered)
        XCTAssertEqual(registered.action, .chooseAnother)
        XCTAssertEqual(registered.readout, "Control-Shift-Space")
        XCTAssertNil(registered.failureDescription)

        let pending = ShortcutCard(confirmed: shortcut, registration: .unregistered, lastChecked: nil)
        XCTAssertEqual(pending.status, .notRegistered)

        let failed = ShortcutCard(confirmed: shortcut, registration: .failed(.hotkeyRegistrationFailed), lastChecked: nil)
        XCTAssertEqual(failed.status, .unavailable)
        XCTAssertEqual(failed.action, .chooseAnother)
        XCTAssertEqual(failed.failureDescription?.contains("HOTKEY-REGISTRATION-FAILED"), true)
    }

    // MARK: Help

    private func snapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: "1.2.3",
            buildNumber: "456",
            macOSVersion: "15.6",
            activationPolicy: "accessory",
            modelState: .absent,
            shortcut: nil,
            shortcutRegistration: .unregistered,
            recordingInteraction: .pushToTalk,
            aiMode: .off,
            aiEndpoint: URL(string: "https://user:sk-CANARY@api.example.com/v1"),
            historyEnabled: true,
            escapeMonitorStatus: "inactive",
            typedInsertionEnabled: true,
            launchAtLoginStatus: .notRegistered
        )
    }

    func testFeedbackMailIsAMailtoWithSubjectAndOptionalRedactedDiagnostics() throws {
        var opened: [URL] = []
        let model = HelpViewModel(
            diagnosticsProvider: { self.snapshot() },
            appVersion: { "1.2.3" },
            openURL: { opened.append($0); return true }
        )

        let plain = try XCTUnwrap(model.composeFeedback())
        XCTAssertEqual(plain.scheme, "mailto")
        XCTAssertEqual(opened, [plain])
        let plainComponents = try XCTUnwrap(URLComponents(url: plain, resolvingAgainstBaseURL: false))
        XCTAssertEqual(plainComponents.path, HelpLinks.feedbackAddress)
        XCTAssertEqual(plainComponents.queryItems?.first { $0.name == "subject" }?.value, "KVoice 1.2.3 feedback")
        let plainBody = try XCTUnwrap(plainComponents.queryItems?.first { $0.name == "body" }?.value)
        XCTAssertFalse(plainBody.contains("KVoice diagnostics"))

        model.includeDiagnosticsInFeedback = true
        let withDiagnostics = try XCTUnwrap(model.feedbackMailURL(now: Date(timeIntervalSince1970: 0)))
        let components = try XCTUnwrap(URLComponents(url: withDiagnostics, resolvingAgainstBaseURL: false))
        let body = try XCTUnwrap(components.queryItems?.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.contains("KVoice diagnostics"), body)
        XCTAssertFalse(body.contains("sk-CANARY"), "the mail body must be redacted like Copy Diagnostics")
        XCTAssertNil(model.lastOpenFailed)
    }

    func testFailedLinkOpenIsRemembered() {
        let model = HelpViewModel(openURL: { _ in false })
        model.openUserGuide()
        XCTAssertEqual(model.lastOpenFailed, HelpLinks.userGuide)
    }

    func testHelpActionsRouteToTheShell() {
        var calls: [String] = []
        let model = HelpViewModel(actions: HelpActions(
            resetOnboarding: { calls.append("onboarding") },
            resetPreferences: { calls.append("preferences") },
            restartApp: { calls.append("restart") },
            showTutorial: { calls.append("tutorial") }
        ))
        model.resetOnboarding()
        model.resetPreferences()
        model.restartApp()
        model.showTutorial()
        XCTAssertEqual(calls, ["onboarding", "preferences", "restart", "tutorial"])
    }

    // MARK: Tutorial banner (Later waves: tutorial pages)

    /// The existing-user "New: a quick tour" offer must show at most once:
    /// both "Show" and "Not now" dismiss it for good, and dismissing twice
    /// must not double-report.
    func testTutorialBannerShowsOnceAndDismissesEitherWay() {
        var shown = 0
        var dismissedCount = 0
        let notNowModel = MainWindowModel(
            showTutorialBanner: true,
            onShowTutorial: { shown += 1 },
            onTutorialBannerDismissed: { dismissedCount += 1 }
        )
        XCTAssertTrue(notNowModel.showTutorialBanner)
        notNowModel.dismissTutorialBanner()
        XCTAssertFalse(notNowModel.showTutorialBanner)
        XCTAssertEqual(dismissedCount, 1)
        XCTAssertEqual(shown, 0, "Not now must not open the tour")
        // A second dismissal (e.g. a stray double click) must not re-report.
        notNowModel.dismissTutorialBanner()
        XCTAssertEqual(dismissedCount, 1)

        var showCalls = 0
        var showDismissedCount = 0
        let showModel = MainWindowModel(
            showTutorialBanner: true,
            onShowTutorial: { showCalls += 1 },
            onTutorialBannerDismissed: { showDismissedCount += 1 }
        )
        showModel.showTutorial()
        XCTAssertFalse(showModel.showTutorialBanner, "Show also dismisses the banner")
        XCTAssertEqual(showCalls, 1)
        XCTAssertEqual(showDismissedCount, 1)

        // A user who has already seen it opens with no banner at all.
        let alreadySeen = MainWindowModel(showTutorialBanner: false)
        XCTAssertFalse(alreadySeen.showTutorialBanner)
    }

    func testSectionViewsConstructWithoutAShell() {
        XCTAssertNotNil(HelpSectionView())
        XCTAssertNotNil(AudioInputSectionView())
        XCTAssertNotNil(ShortcutsSectionView())
        XCTAssertNotNil(RecordingSectionView())
        XCTAssertNotNil(DictionarySectionView())
        XCTAssertNotNil(GeneralSectionView())
        XCTAssertNotNil(DataPrivacySectionView(history: HistoryViewModel(repository: TestHistoryRepository())))
        XCTAssertNotNil(MainWindowView(model: MainWindowModel()) { _ in AnyView(EmptyView()) })
    }
}

/// UI v2 wave 4: the sidebar's icon tiles and readiness pill.
@MainActor
final class MainWindowUIv2Tests: XCTestCase {
    func testEverySectionTileCarriesTheDesignsMeaning() {
        let expected: [MainWindowSection: KVColorToken] = [
            .home: .ink, .history: .ink,
            .recording: .voice, .models: .voice, .audioInput: .voice,
            .dictionary: .cursor, .aiActions: .cursor,
            .dataPrivacy: .ok, .permissions: .ok,
            .shortcuts: .grey, .general: .grey, .help: .grey
        ]
        XCTAssertEqual(Set(expected.keys), Set(MainWindowSection.allCases), "every section has a tile")
        for section in MainWindowSection.allCases {
            XCTAssertEqual(section.tileFill, expected[section], section.rawValue)
        }
    }

    func testGreyTokenIsTheDesignsTileGrey() {
        XCTAssertEqual(KVColorToken.grey.hex.light, 0x8A8A93)
        XCTAssertEqual(KVColorToken.grey.hex.dark, 0x6E6E78)
    }

    func testReadinessProjectsTheShellSummaryAndShortcut() {
        let ready = MainWindowReadiness(statusTitle: "Ready", isBlocked: false, shortcutGlyphs: "⌃⇧Space")
        XCTAssertEqual(ready.title, "Ready")
        XCTAssertFalse(ready.needsAttention)
        XCTAssertEqual(ready.tone, .ok)
        XCTAssertEqual(ready.shortcutKeys, ["⌃", "⇧", "Space"])
        XCTAssertEqual(ready.accessibilityLabel, "Ready. Shortcut ⌃⇧Space")

        let blocked = MainWindowReadiness(statusTitle: "Microphone denied", isBlocked: true, shortcutGlyphs: nil)
        XCTAssertTrue(blocked.needsAttention)
        XCTAssertEqual(blocked.tone, .warn)
        XCTAssertEqual(blocked.shortcutKeys, [])
        XCTAssertEqual(blocked.accessibilityLabel, "Microphone denied", "no shortcut, no trailing words")
    }

    func testReadinessStartsEmptyAndIsSetByTheShell() {
        let model = MainWindowModel()
        XCTAssertNil(model.readiness, "no pill until the shell's first update")
        model.readiness = .preview
        XCTAssertEqual(model.readiness, .preview)
    }

    func testStatusToneMapsOntoTheDesignTones() {
        XCTAssertEqual(StatusTone.positive.kvTone, .ok)
        XCTAssertEqual(StatusTone.attention.kvTone, .warn)
        XCTAssertEqual(StatusTone.neutral.kvTone, .neutral)
    }
}
