import KvoiceDomain
@testable import KvoiceUI
import XCTest

/// fix/post-0.1.7: the one projection from a model's lifecycle state (and
/// the library's activity) to the phase the menu-bar surfaces show.
/// `SurfaceStateMatrixTests` checks that every surface uses it; this pins
/// the projection itself.
final class ModelReadinessPhaseTests: XCTestCase {
    private let summary = InstalledModelSummary(modelID: "whisper", revision: "r", ownership: .managedByKvoice)

    func testTheLifecycleStateDecidesThePhase() {
        XCTAssertEqual(ModelReadinessPhase(.downloading(completed: 1, total: 4)), .downloading(fraction: 0.25))
        XCTAssertEqual(ModelReadinessPhase(.downloading(completed: 5, total: 0)), .downloading(fraction: nil), "an unknown total is indeterminate")
        XCTAssertEqual(ModelReadinessPhase(.validatingExternal), .verifying)
        XCTAssertEqual(ModelReadinessPhase(.verifying(completedFiles: 1, totalFiles: 2)), .verifying)
        XCTAssertEqual(ModelReadinessPhase(.installing), .installing)
        XCTAssertEqual(ModelReadinessPhase(.loading), .loading)
        XCTAssertEqual(ModelReadinessPhase(.optimizing), .optimizing)
        XCTAssertNil(ModelReadinessPhase(.ready(summary)))
        XCTAssertNil(ModelReadinessPhase(.deleting(summary)))
        XCTAssertNil(ModelReadinessPhase(.absent))
    }

    /// The 0.1.7 bug: `.downloading(id)` is the whole transaction, so the
    /// first compile at its end must read as optimizing, not downloading.
    func testTheStateWinsOverTheActivity() {
        let optimizing = ModelReadinessPhase.inProgress(activity: .downloading("whisper"), state: .optimizing)
        XCTAssertEqual(optimizing?.phase, .optimizing)
        XCTAssertEqual(optimizing?.id, "whisper")
        XCTAssertEqual(ModelReadinessPhase.inProgress(activity: .installing("whisper"), state: .loading)?.phase, .loading)
        XCTAssertEqual(ModelReadinessPhase.inProgress(activity: .loading("whisper"), state: .optimizing)?.phase, .optimizing)
    }

    func testAStaleStateFallsBackToTheActivitysOwnPhase() {
        XCTAssertEqual(ModelReadinessPhase.inProgress(activity: .downloading("whisper"), state: .absent)?.phase, .downloading(fraction: nil))
        XCTAssertEqual(ModelReadinessPhase.inProgress(activity: .downloading("whisper"), state: .downloadPaused(resumableBytes: 3))?.phase, .downloading(fraction: nil), "a resume's first poll")
        XCTAssertEqual(ModelReadinessPhase.inProgress(activity: .loading("whisper"), state: .ready(summary))?.phase, .loading)
        XCTAssertNil(ModelReadinessPhase.inProgress(activity: .installing("whisper"), state: .ready(summary)), "a refresh of a ready model shows nothing")
    }

    func testOperationsThatBringNoModelCloserShowNoProgress() {
        XCTAssertNil(ModelReadinessPhase.inProgress(activity: .installing("whisper"), state: .deleting(summary)), "a delete is not a download")
        XCTAssertNil(ModelReadinessPhase.inProgress(activity: .downloading("whisper"), state: .deleting(summary)))
        for activity: ModelActivity in [.idle, .reloadingUnits, .testing, .transcribingFile, .unloading] {
            XCTAssertNil(ModelReadinessPhase.inProgress(activity: activity, state: .optimizing), "\(activity)")
        }
    }

    func testTheWordsNameThePhase() {
        XCTAssertEqual(ModelReadinessPhase.downloading(fraction: 0.4249).progressLabel(modelName: "Nemotron", withPercent: true), "Downloading Nemotron… 42%")
        XCTAssertEqual(ModelReadinessPhase.downloading(fraction: 0.4249).progressLabel(modelName: "Nemotron"), "Downloading Nemotron…")
        XCTAssertEqual(ModelReadinessPhase.loading.progressLabel(modelName: "Nemotron", withPercent: true), "Loading Nemotron…")
        XCTAssertEqual(ModelReadinessPhase.optimizing.progressLabel(modelName: "Whisper"), "Optimizing Whisper for this Mac (first time only)…")
        XCTAssertEqual(ModelReadinessPhase.readinessTitle(for: .downloading(completed: 1, total: 2)), "Downloading model…", "0.1.7 said \"Model loading…\" for a download")
        XCTAssertEqual(ModelReadinessPhase.readinessTitle(for: .optimizing), "Optimizing model for this Mac (first time only)…")
        XCTAssertEqual(ModelReadinessPhase.readinessTitle(for: .error(ModelFailure(code: "x", message: "y"))), "Model not ready")
    }
}
