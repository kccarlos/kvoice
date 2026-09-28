import XCTest
import KvoiceDomain
@testable import KvoiceAppCore

/// ADR-022 slice 5: one row per `LocalStateIntent` × gate that matters. The
/// rows moved here from `SettingsReducerTests` with the fields; their
/// semantics (loaded-gated, never idle-gated, no-op when unchanged) did not.
final class LocalStateReducerTests: XCTestCase {
    private static let jobActive = SettingsGate(dictation: .jobActive)
    private static let notLoaded = SettingsGate(settingsLoaded: false)
    private static let terminating = SettingsGate(terminationInProgress: true)
    private static let grant = ExportFolderGrant(bookmark: Data([1, 2, 3]), displayPath: "/Users/x/Transcripts")

    private static var base: LocalState {
        var state = LocalState()
        state.mainWindowSection = "general"
        state.exportFolder = grant
        return state
    }

    private struct Row: Sendable {
        let name: String
        let intent: LocalStateIntent
        let gate: SettingsGate
        let expectedState: @Sendable (LocalState) -> LocalState
        let effects: [SettingsEffect]
        let refusal: SettingsRefusal.Reason?

        init(
            _ name: String, _ intent: LocalStateIntent, gate: SettingsGate = .idle,
            state: @escaping @Sendable (LocalState) -> LocalState = { $0 },
            effects: [SettingsEffect] = [], refusal: SettingsRefusal.Reason? = nil
        ) {
            self.name = name
            self.intent = intent
            self.gate = gate
            self.expectedState = state
            self.effects = effects
            self.refusal = refusal
        }
    }

    private static let rows: [Row] = [
        Row("window section", .setMainWindowSection("history", origin: .shell),
            state: { var s = $0; s.mainWindowSection = "history"; return s }, effects: [.persistLocalState]),
        Row("window section unchanged is a no-op", .setMainWindowSection("general", origin: .shell)),
        Row("window section during a job applies", .setMainWindowSection("history", origin: .shell), gate: jobActive,
            state: { var s = $0; s.mainWindowSection = "history"; return s }, effects: [.persistLocalState]),
        Row("window section before load", .setMainWindowSection("history", origin: .shell), gate: notLoaded, refusal: .notLoaded),
        Row("window section while terminating", .setMainWindowSection("history", origin: .shell), gate: terminating, refusal: .terminating),
        Row("tutorial seen", .markTutorialSeen(origin: .shell),
            state: { var s = $0; s.tutorialSeen = true; return s }, effects: [.persistLocalState]),
        Row("tutorial seen twice is a no-op", .markTutorialSeen(origin: .shell), gate: .idle,
            state: { var s = $0; s.tutorialSeen = true; return s }, effects: [.persistLocalState]),
        Row("complete onboarding", .completeOnboarding(version: 3, origin: .wizard),
            state: { var s = $0; s.onboardingVersionCompleted = 3; s.tutorialSeen = true; return s }, effects: [.persistLocalState]),
        Row("complete onboarding during a job applies", .completeOnboarding(version: 3, origin: .wizard), gate: jobActive,
            state: { var s = $0; s.onboardingVersionCompleted = 3; s.tutorialSeen = true; return s }, effects: [.persistLocalState]),
        Row("reset onboarding", .resetOnboarding(origin: .page(.general)),
            state: { var s = $0; s.onboardingVersionCompleted = nil; return s }, effects: [.persistLocalState]),
        Row("reset onboarding before load", .resetOnboarding(origin: .page(.general)), gate: notLoaded, refusal: .notLoaded),
        Row("export folder", .setExportFolder(ExportFolderGrant(bookmark: Data([9]), displayPath: "/y"), origin: .page(.dataPrivacy)),
            state: { var s = $0; s.exportFolder = ExportFolderGrant(bookmark: Data([9]), displayPath: "/y"); return s },
            effects: [.persistLocalState]),
        Row("export folder unchanged is a no-op", .setExportFolder(grant, origin: .page(.dataPrivacy))),
        Row("export folder cleared", .setExportFolder(nil, origin: .page(.dataPrivacy)),
            state: { var s = $0; s.exportFolder = nil; return s }, effects: [.persistLocalState]),
        Row("export folder during a job applies", .setExportFolder(nil, origin: .page(.dataPrivacy)), gate: jobActive,
            state: { var s = $0; s.exportFolder = nil; return s }, effects: [.persistLocalState])
    ]

    func testEveryRow() {
        for row in Self.rows {
            let base = Self.base
            let result = LocalStateReducer.reduce(state: base, intent: row.intent, gate: row.gate)
            if let refusal = row.refusal {
                XCTAssertEqual(result.refusal?.reason, refusal, row.name)
                XCTAssertEqual(result.refusal?.intent, row.intent.name, row.name)
                XCTAssertEqual(result.state, base, "\(row.name): a refusal must leave the state untouched")
                XCTAssertEqual(result.effects, [], "\(row.name): a refusal runs no effect")
            } else {
                XCTAssertNil(result.refusal, row.name)
                XCTAssertEqual(result.state, row.expectedState(base), row.name)
                XCTAssertEqual(result.effects, row.effects, row.name)
            }
        }
    }

    func testMarkingTheTutorialSeenTwiceIsANoOp() {
        var seen = Self.base
        seen.tutorialSeen = true
        let result = LocalStateReducer.reduce(state: seen, intent: .markTutorialSeen(origin: .shell), gate: .idle)
        XCTAssertEqual(result.state, seen)
        XCTAssertEqual(result.effects, [])
    }

    func testEveryIntentNamesItsOriginAndNamesAreDistinct() {
        let intents: [LocalStateIntent] = [
            .setMainWindowSection("x", origin: .shell), .markTutorialSeen(origin: .wizard),
            .completeOnboarding(version: 1, origin: .wizard), .resetOnboarding(origin: .page(.general)),
            .setExportFolder(nil, origin: .page(.dataPrivacy))
        ]
        XCTAssertEqual(Set(intents.map(\.name)).count, intents.count)
        XCTAssertEqual(intents.map(\.origin), [.shell, .wizard, .wizard, .page(.general), .page(.dataPrivacy)])
        // No name collides with a settings intent: one diagnostics site
        // namespace.
        let settingsNames: Set<String> = [
            SettingsIntent.setShortcut(nil, origin: .shell).name, SettingsIntent.replaceAll(AppSettings(), origin: .shell).name,
            SettingsIntent.resetPreferences(origin: .shell).name, SettingsIntent.setDataPrivacy(historyRetention: .init(), audioStorage: .init(), export: .init(), origin: .shell).name
        ]
        XCTAssertTrue(settingsNames.isDisjoint(with: intents.map(\.name)))
    }
}
