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
                .shortcuts, .recording, .models, .dictionary, .audioInput,
                .aiActions,
                .history, .dataPrivacy,
                .general, .permissions, .help
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
        XCTAssertEqual(MainWindowSectionGroup.allCases, [.dictation, .ai, .data, .app])
        XCTAssertEqual(MainWindowSectionGroup.dictation.sections, [.shortcuts, .recording, .models, .dictionary, .audioInput])
        XCTAssertEqual(MainWindowSectionGroup.ai.sections, [.aiActions])
        XCTAssertEqual(MainWindowSectionGroup.data.sections, [.history, .dataPrivacy])
        XCTAssertEqual(MainWindowSectionGroup.app.sections, [.general, .permissions, .help])
        // Every section belongs to exactly one group, and the groups
        // concatenated are the sidebar order.
        XCTAssertEqual(MainWindowSectionGroup.allCases.flatMap(\.sections), MainWindowSection.allCases)
        for group in MainWindowSectionGroup.allCases {
            XCTAssertFalse(group.title.isEmpty)
        }
    }

    func testPersistedSectionFallsBackToHistoryForNilOrUnknownValues() {
        XCTAssertEqual(MainWindowSection(persisted: nil), .history)
        XCTAssertEqual(MainWindowSection(persisted: "not-a-section"), .history)
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
