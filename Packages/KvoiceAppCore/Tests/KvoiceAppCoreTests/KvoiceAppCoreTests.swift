import XCTest
import KvoiceDomain
import KvoiceTestSupport
@testable import KvoiceAppCore

final class KvoiceAppCoreTests: XCTestCase {
    private actor TestLogger: DiagnosticLogging {
        var events: [DiagnosticEvent] = []

        func log(_ event: DiagnosticEvent) async {
            events.append(event)
        }
    }

    func testControllerOwnsReducerState() async throws {
        let controller = DictationController()
        let jobID = DomainFixtures.jobID

        let started = try await controller.apply(.start(jobID: jobID, prerequisites: .passed))
        XCTAssertEqual(started, .recording(RecordingState(jobID: jobID)))
        let recordingState = await controller.state
        XCTAssertEqual(recordingState, .recording(RecordingState(jobID: jobID)))
        let escaped = try await controller.apply(.escape(jobID: jobID))
        XCTAssertEqual(escaped, .idle)
    }

    func testStaleEventDoesNotMutateController() async throws {
        let logger = TestLogger()
        let controller = DictationController(diagnosticLogger: logger)
        let expected = DomainFixtures.jobID
        let received = DomainFixtures.alternateJobID
        _ = try await controller.apply(.start(jobID: expected, prerequisites: .passed))

        let ignored = try await controller.apply(.stop(jobID: received))
        XCTAssertEqual(ignored, .recording(RecordingState(jobID: expected)))
        let recordingState = await controller.state
        XCTAssertEqual(recordingState, .recording(RecordingState(jobID: expected)))
        let events = await logger.events
        XCTAssertEqual(events.last?.result, .ignored)
        XCTAssertEqual(events.last?.errorCode, .appCancelled)
    }

    func testJobRetainsDurationAndAIFallbackMetadata() async throws {
        let controller = DictationController()
        let jobID = DomainFixtures.jobID
        let job = DictationJob(
            id: jobID,
            startedAt: Date(timeIntervalSince1970: 0),
            target: nil,
            modeSnapshot: .polish,
            translationTargetSnapshot: nil,
            modelIDSnapshot: "fixture"
        )

        _ = try await controller.apply(.start(jobID: jobID, prerequisites: .passed), job: job)
        _ = try await controller.apply(.hardDurationCap(jobID: jobID))
        var activeJob = await controller.activeJob
        XCTAssertEqual(activeJob?.durationCapReached, true)

        _ = try await controller.apply(.stop(jobID: jobID))
        _ = try await controller.apply(.validRecording(jobID: jobID))
        _ = try await controller.apply(.rawTranscript(jobID: jobID, mode: .polish))
        _ = try await controller.apply(.aiCancelled(jobID: jobID))
        activeJob = await controller.activeJob
        XCTAssertEqual(activeJob?.fallbackReason, .aiCancelled)
        XCTAssertEqual(activeJob?.aiCancelled, true)
        XCTAssertEqual(activeJob?.rawTranscript, activeJob?.finalText)
    }

    func testFailedEscapeIsNotSwallowedAndClearsJob() async throws {
        let controller = DictationController()
        let jobID = DomainFixtures.jobID
        _ = try await controller.apply(.start(jobID: jobID, prerequisites: .passed))
        _ = try await controller.apply(.captureFailure(jobID: jobID, code: .audioInputUnavailable))

        let recovered = try await controller.apply(.escape(jobID: jobID))
        XCTAssertEqual(recovered, .idle)
        let activeJob = await controller.activeJob
        XCTAssertNil(activeJob)
    }

    func testAIEscapeAtomicallySelectsRawTranscript() async throws {
        let controller = DictationController()
        let jobID = DomainFixtures.jobID
        let job = DictationJob(
            id: jobID,
            startedAt: Date(timeIntervalSince1970: 0),
            target: nil,
            modeSnapshot: .polish,
            translationTargetSnapshot: nil,
            modelIDSnapshot: "fixture"
        )

        _ = try await controller.apply(.start(jobID: jobID, prerequisites: .passed), job: job)
        _ = try await controller.apply(.stop(jobID: jobID))
        _ = try await controller.apply(.validRecording(jobID: jobID))
        _ = try await controller.apply(.rawTranscript(jobID: jobID, mode: .polish))
        await controller.recordRawTranscript("local transcript", for: jobID)

        let next = try await controller.apply(.escape(jobID: jobID))
        XCTAssertEqual(next, .inserting(jobID))
        await controller.recordFinalText("late provider result", for: jobID)
        let activeJob = await controller.activeJob
        XCTAssertEqual(activeJob?.finalText, "local transcript")
        XCTAssertEqual(activeJob?.fallbackReason, .aiCancelled)
    }

    func testRawTranscriptModeComesFromImmutableJobSnapshot() async throws {
        let logger = TestLogger()
        let controller = DictationController(diagnosticLogger: logger)
        let jobID = DomainFixtures.jobID
        let job = DictationJob(
            id: jobID,
            startedAt: Date(timeIntervalSince1970: 0),
            target: nil,
            modeSnapshot: .off,
            translationTargetSnapshot: nil,
            modelIDSnapshot: "fixture"
        )

        _ = try await controller.apply(.start(jobID: jobID, prerequisites: .passed), job: job)
        _ = try await controller.apply(.stop(jobID: jobID))
        _ = try await controller.apply(.validRecording(jobID: jobID))
        let next = try await controller.apply(.rawTranscript(jobID: jobID, mode: .polish))
        XCTAssertEqual(next, .inserting(jobID))
        let events = await logger.events
        XCTAssertEqual(events.last?.result, .warning)
    }

    func testInjectedJobIDMismatchIsRejected() async throws {
        let controller = DictationController()
        let injected = DictationJob(
            id: DomainFixtures.alternateJobID,
            startedAt: Date(timeIntervalSince1970: 0),
            target: nil,
            modeSnapshot: .off,
            translationTargetSnapshot: nil,
            modelIDSnapshot: "fixture"
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await controller.apply(
                .start(jobID: DomainFixtures.jobID, prerequisites: .passed),
                job: injected
            )
        }
        let state = await controller.state
        XCTAssertEqual(state, .idle)
    }

    func testCommandRouterPreservesIntent() {
        let jobID = DomainFixtures.jobID
        XCTAssertEqual(
            CommandRouter.event(for: .start(jobID: jobID, prerequisites: .passed)),
            .start(jobID: jobID, prerequisites: .passed)
        )
        XCTAssertEqual(CommandRouter.event(for: .quit), .quit)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
