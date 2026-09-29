import XCTest
import KvoiceDomain
@testable import KvoiceAppCore

/// The model half of the start prerequisite check as a pure function
/// (`AppComposition`'s `prerequisiteChecker` feeds it): which lifecycle
/// state passes, which blocks as loading, which blocks as unavailable — and,
/// ADR-025 amendment, the system-managed default's own sentences.
final class ModelStartPrerequisiteTests: XCTestCase {
    private let summary = InstalledModelSummary(modelID: "m", revision: "r", ownership: .managedByKvoice)
    private let failure = ModelFailure(code: "MODEL-LANGUAGE-UNSUPPORTED", message: SystemManagedUnavailableReason.languageUnsupported.message)

    func testAResidentVerifiedModelPassesAndANonResidentOneBlocksAsLoading() {
        for state in [ModelLifecycleState.ready(summary), .inference(summary, jobID: UUID())] {
            XCTAssertEqual(ModelStartPrerequisite.check(state, isResident: true, isSystemManaged: false), .passed)
            XCTAssertEqual(ModelStartPrerequisite.check(state, isResident: true, isSystemManaged: true), .passed)
            XCTAssertEqual(ModelStartPrerequisite.check(state, isResident: false, isSystemManaged: false), .blocked(.modelLoading))
            XCTAssertTrue(ModelStartPrerequisite.wantsReload(state, isResident: false))
            XCTAssertFalse(ModelStartPrerequisite.wantsReload(state, isResident: true))
        }
    }

    func testTransientStatesBlockAsLoadingWithoutAReload() {
        let transient: [ModelLifecycleState] = [
            .downloading(completed: 1, total: 2), .downloadPaused(resumableBytes: nil),
            .verifying(completedFiles: 0, totalFiles: 1), .installing, .loading, .validatingExternal
        ]
        for state in transient {
            for systemManaged in [false, true] {
                XCTAssertEqual(ModelStartPrerequisite.check(state, isResident: false, isSystemManaged: systemManaged), .blocked(.modelLoading), "\(state)")
            }
            XCTAssertFalse(ModelStartPrerequisite.wantsReload(state, isResident: false))
        }
    }

    /// 2026-09-29: the hotkey pressed during the first Core ML build gets
    /// the "optimized for this Mac, first time only" sentence, not "a moment".
    func testTheFirstCompileBlocksWithItsOwnSentenceAndNoReload() {
        for systemManaged in [false, true] {
            XCTAssertEqual(
                ModelStartPrerequisite.check(.optimizing, isResident: false, isSystemManaged: systemManaged),
                .blocked(.modelOptimizing)
            )
        }
        XCTAssertFalse(ModelStartPrerequisite.wantsReload(.optimizing, isResident: false))
        XCTAssertEqual(BlockReason.modelOptimizing.code, BlockReason.modelLoading.code, "the HUD's error mapping is unchanged")
        XCTAssertTrue(BlockReason.builtIn.contains(.modelOptimizing), "the sentence is in the copy inventory")
    }

    func testAPackageModelBlocksWithTheGenericSentenceInEveryOtherState() {
        let states: [ModelLifecycleState] = [
            .absent, .corrupt(failure), .incompatible(failure), .deleting(summary), .error(failure), .unavailable(failure)
        ]
        for state in states {
            XCTAssertEqual(ModelStartPrerequisite.check(state, isResident: false, isSystemManaged: false), .blocked(.modelUnavailable), "\(state)")
        }
    }

    func testASystemManagedDefaultSaysWhatIsMissing() {
        // ADR-025 amendment: `.absent` is "no assets for this language",
        // `.unavailable` is the card's own reason; both keep the
        // `modelNotInstalled` code.
        let absent = ModelStartPrerequisite.check(.absent, isResident: false, isSystemManaged: true)
        XCTAssertEqual(absent, .blocked(.systemManagedAssetsMissing))
        let unavailable = ModelStartPrerequisite.check(.unavailable(failure), isResident: false, isSystemManaged: true)
        XCTAssertEqual(unavailable, .blocked(.systemManagedUnavailable(failure)))
        guard case .blocked(let reason) = unavailable else { return XCTFail() }
        XCTAssertEqual(reason.code, KVoiceErrorCode.modelNotInstalled.rawValue)
        XCTAssertTrue(reason.message.hasPrefix(failure.message))

        // `.error` (a failed install, the reservation cap) and the rest keep
        // the generic sentence: the card shows the error with Retry / Delete.
        for state in [ModelLifecycleState.error(failure), .corrupt(failure), .incompatible(failure), .deleting(summary)] {
            XCTAssertEqual(ModelStartPrerequisite.check(state, isResident: false, isSystemManaged: true), .blocked(.modelUnavailable), "\(state)")
        }
    }
}
