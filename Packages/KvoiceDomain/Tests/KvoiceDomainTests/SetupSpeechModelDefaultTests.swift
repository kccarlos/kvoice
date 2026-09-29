import KvoiceDomain
import XCTest

/// 2026-09-29 (owner decision 1): a fresh setup starts with Apple Speech
/// when this Mac can run it for the language; existing users never change.
final class SetupSpeechModelDefaultTests: XCTestCase {
    private let whisper = SpeechModelCatalogEntry(
        id: "whisper", displayName: "Whisper v3 Turbo", variantName: "",
        family: "whisper", runtime: .whisperKitCoreML, hosting: .onDevice,
        supportsStreaming: true, supportsBatch: true, downloadBytes: 632_000_000,
        languageSummary: "99 languages", summary: "", isRecommended: true,
        revision: "r", manifestResource: "whisper", manifestSHA256: "abc"
    )
    private let parakeet = SpeechModelCatalogEntry(
        id: "parakeet", displayName: "Parakeet", variantName: "",
        family: "parakeet", runtime: .fluidAudioParakeetTDT, hosting: .onDevice,
        supportsStreaming: false, supportsBatch: true, downloadBytes: 600_000_000,
        languageSummary: "25 languages", summary: "", isRecommended: false,
        revision: "r", manifestResource: "parakeet", manifestSHA256: "def"
    )
    private let apple = SpeechModelCatalogEntry(
        id: "apple-speech", displayName: "Apple Speech", variantName: "",
        family: "apple-speech", runtime: .appleSpeech, hosting: .onDevice,
        supportsStreaming: true, supportsBatch: true, downloadBytes: 0,
        languageCodes: ["en", "zh", "ja"], languageSummary: "3 languages on this Mac",
        summary: "", isRecommended: false, revision: "system",
        manifestResource: "", manifestSHA256: "", assetSource: .systemManaged
    )
    private var catalog: SpeechModelCatalog { SpeechModelCatalog(entries: [whisper, parakeet, apple]) }
    private let unavailable = ModelFailure(code: "x", message: "Requires macOS 26 or later.")
    private let installed = InstalledModelSummary(modelID: "whisper", revision: "r", ownership: .managedByKvoice)

    private func states(apple appleState: ModelLifecycleState, whisper whisperState: ModelLifecycleState = .absent) -> [ModelID: ModelLifecycleState] {
        ["whisper": whisperState, "parakeet": .absent, "apple-speech": appleState]
    }

    private func choice(
        completed: Int? = nil,
        savedDefault: ModelID? = nil,
        selected: ModelReference? = nil,
        states: [ModelID: ModelLifecycleState],
        language: String? = nil,
        mac: String? = "en"
    ) -> ModelID? {
        SetupSpeechModelDefault.choice(
            onboardingCompletedVersion: completed, savedDefaultModelID: savedDefault, selectedModel: selected,
            catalog: catalog, states: states, transcriptionLanguage: language, macLanguageCode: mac
        )
    }

    func testAFreshSetupOnAMacThatCanRunAppleSpeechStartsWithIt() {
        for appleState in [ModelLifecycleState.absent, .downloading(completed: 10, total: 100),
                           .ready(InstalledModelSummary(modelID: "apple-speech", revision: "system", ownership: .systemManaged))] {
            XCTAssertEqual(choice(states: states(apple: appleState)), "apple-speech", "\(appleState)")
        }
    }

    func testAMacThatCannotRunItKeepsTheRecommendedDefault() {
        XCTAssertNil(choice(states: states(apple: .unavailable(unavailable))), "macOS < 26, ineligible Mac, unsupported language")
        XCTAssertNil(choice(states: states(apple: .error(unavailable))), "a failed platform query is not 'can run it'")
        XCTAssertNil(choice(states: ["whisper": .absent, "parakeet": .absent]), "no system entry in this build")
    }

    func testTheLanguageMustBeCovered() {
        // Auto-detect means the Mac's language for a system runtime.
        XCTAssertNil(choice(states: states(apple: .absent), mac: "vi"), "the Mac's language is not in the observed list")
        XCTAssertNil(choice(states: states(apple: .absent), mac: nil))
        XCTAssertEqual(choice(states: states(apple: .absent), mac: "zh"), "apple-speech")
        // A chosen language wins over the Mac's.
        XCTAssertEqual(choice(states: states(apple: .absent), language: "ja", mac: "vi"), "apple-speech")
        XCTAssertNil(choice(states: states(apple: .absent), language: "vi", mac: "en"))
    }

    func testExistingUsersNeverChange() {
        let fine = states(apple: .absent)
        XCTAssertNil(choice(completed: 3, states: fine), "onboarding was completed")
        XCTAssertNil(choice(savedDefault: "whisper", states: fine), "a saved default")
        XCTAssertNil(choice(selected: .managed(modelID: "whisper", revision: "r"), states: fine), "a saved selection")
        // Whisper on disk without a saved selection (a download interrupted
        // before it was saved — the owner's TestFlight run) is not fresh.
        for whisperState in [ModelLifecycleState.ready(installed), .downloadPaused(resumableBytes: 5), .error(unavailable), .loading, .optimizing] {
            XCTAssertNil(choice(states: states(apple: .absent, whisper: whisperState)), "\(whisperState)")
        }
    }

    /// swift-reviewer 2026-09-29: a package download may be interrupted, so
    /// its choice is saved first; the seconds-long system install is saved
    /// after, inside the polled body.
    func testOnlyAPackageModelSavesItsChoiceBeforeTheInstall() {
        XCTAssertTrue(SetupSpeechModelDefault.savesChoiceBeforeInstall(whisper))
        XCTAssertTrue(SetupSpeechModelDefault.savesChoiceBeforeInstall(parakeet))
        XCTAssertFalse(SetupSpeechModelDefault.savesChoiceBeforeInstall(apple))
    }

    func testTheAlternativeIsTheOtherHalfOfThePair() {
        let fine = states(apple: .absent)
        XCTAssertEqual(
            SetupSpeechModelDefault.alternative(to: "apple-speech", catalog: catalog, states: fine, transcriptionLanguage: nil, macLanguageCode: "en"),
            "whisper"
        )
        XCTAssertEqual(
            SetupSpeechModelDefault.alternative(to: "whisper", catalog: catalog, states: fine, transcriptionLanguage: nil, macLanguageCode: "en"),
            "apple-speech"
        )
        XCTAssertNil(
            SetupSpeechModelDefault.alternative(to: "whisper", catalog: catalog, states: states(apple: .unavailable(unavailable)), transcriptionLanguage: nil, macLanguageCode: "en"),
            "never offer what this Mac cannot run"
        )
        XCTAssertNil(
            SetupSpeechModelDefault.alternative(to: "parakeet", catalog: catalog, states: fine, transcriptionLanguage: nil, macLanguageCode: "en"),
            "a user's own pick is left alone"
        )
    }
}
