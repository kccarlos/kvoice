import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceUI
import XCTest

/// 2026-09-29 (owner decision 1): the wizard's model card recommends Apple
/// Speech with its reason, keeps Whisper one click away with an honest note
/// about its download and one-time optimization, and shows nothing to press
/// while the shell decides.
@MainActor
final class OnboardingSetupModelTests: XCTestCase {
    private let whisper = SpeechModelCatalogEntry(
        id: "whisper", displayName: "Whisper v3 Turbo", variantName: "",
        family: "whisper", runtime: .whisperKitCoreML, hosting: .onDevice,
        supportsStreaming: true, supportsBatch: true, downloadBytes: 632_000_000,
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

    func testAppleSpeechIsPresentedAsTheRecommendationWithItsReason() {
        let model = OnboardingViewModel(stage: .speechModel)
        model.setModelEntry(apple)
        model.setModelState(.absent)

        XCTAssertEqual(model.modelDisplayName, "Apple Speech")
        XCTAssertEqual(model.modelDetailLine, "Apple Speech · Built into macOS", "no '0 bytes' download size")
        XCTAssertTrue(model.modelSourceNote.hasPrefix("Recommended for this Mac: ready in seconds, with nothing large to download."))
        XCTAssertEqual(model.modelPrimaryActionTitle, "Install Model")
        XCTAssertEqual(model.actionBar.primaryTitle, "Install Model")
    }

    func testWhisperIsOneClickAwayWithAnHonestNote() {
        var intents: [OnboardingIntent] = []
        let model = OnboardingViewModel(stage: .speechModel, onIntent: { intents.append($0) }, clock: ParkingClock())
        model.setModelEntry(apple)
        model.setModelState(.downloading(completed: 30, total: 100))
        model.setAlternativeModelEntry(whisper)

        XCTAssertEqual(model.alternativeModelTitle, "Use Whisper v3 Turbo Instead")
        let note = model.alternativeModelNote ?? ""
        XCTAssertTrue(note.contains("632 MB"), note)
        XCTAssertTrue(note.contains("the first time it loads it is optimized for your Mac"), note)

        model.useAlternativeModel()
        XCTAssertEqual(intents, [.useSpeechModel("whisper")])
        XCTAssertTrue(model.modelActionPending)
        XCTAssertNil(model.alternativeModelTitle, "no second click while the first is pending")
    }

    func testTheAlternativeIsWithheldWhileALoadCannotBeInterrupted() {
        let model = OnboardingViewModel(stage: .speechModel)
        model.setModelEntry(whisper)
        model.setAlternativeModelEntry(apple)
        for state in [ModelLifecycleState.optimizing, .loading, .verifying(completedFiles: 1, totalFiles: 2)] {
            model.setModelState(state)
            XCTAssertNil(model.alternativeModelTitle, "\(state)")
        }
        model.setModelState(.absent)
        XCTAssertEqual(model.alternativeModelTitle, "Use Apple Speech Instead")
        XCTAssertEqual(model.alternativeModelNote, "Apple Speech also runs on this Mac: ready in seconds, with nothing large to download.")
    }

    func testAWhisperCardWarnsAboutTheOneTimeOptimization() {
        let model = OnboardingViewModel(stage: .speechModel)
        model.setModelEntry(whisper)
        XCTAssertTrue(model.modelSourceNote.contains("The first time it loads, it is optimized for your Mac, which can take a few minutes."))
        XCTAssertEqual(model.modelPrimaryActionTitle, "Download Model")
    }

    func testNothingToPressWhileTheShellDecides() {
        var intents: [OnboardingIntent] = []
        let model = OnboardingViewModel(stage: .speechModel, onIntent: { intents.append($0) })
        model.setModelEntry(whisper)
        model.setAlternativeModelEntry(apple)
        model.setDeterminingModel(true)

        XCTAssertTrue(model.modelIsBusy)
        XCTAssertNil(model.modelPrimaryAction)
        XCTAssertNil(model.alternativeModelTitle)
        XCTAssertEqual(model.modelActivityDescription, "Checking which speech model suits this Mac…")
        XCTAssertEqual(model.actionBar.primaryTitle, "Continue")
        model.handleModelAction(.download)
        XCTAssertTrue(intents.isEmpty, "the old default's Download cannot be pressed mid-decision")

        model.setDeterminingModel(false)
        XCTAssertEqual(model.modelPrimaryAction, .download)
    }
}
