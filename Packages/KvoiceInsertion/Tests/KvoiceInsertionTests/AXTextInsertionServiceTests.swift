import Foundation
import XCTest
@testable import KvoiceInsertion
import KvoiceDomain

final class AXTextInsertionServiceTests: XCTestCase {
    func testCommittedTextEditFixturesUseDirectMutationOrExactFallback() async throws {
        let fixtureURL = Self.fixtureURL
        let fixtureDataBefore = try Data(contentsOf: fixtureURL)
        let fixtures = try JSONDecoder().decode(FixtureSet.self, from: fixtureDataBefore)

        for fixture in fixtures.cases {
            let target = TargetApplicationSnapshot(
                processIdentifier: fixture.target.processIdentifierAtCapture,
                bundleIdentifier: "com.apple.TextEdit",
                localizedName: "TextEdit",
                capturedAt: Date(timeIntervalSince1970: 1)
            )
            let workspace = FakeWorkspace(
                sequence: [
                    FrontmostApplicationSnapshot(
                        processIdentifier: fixture.target.processIdentifierAtCompletion,
                        bundleIdentifier: "com.apple.TextEdit",
                        localizedName: "TextEdit"
                    )
                ]
            )
            let ax = FakeAXClient(
                processIdentifier: fixture.target.processIdentifierAtCompletion,
                value: fixture.before.value,
                selectedRange: AXTextRange(
                    location: fixture.before.selectedRangeUTF16.location,
                    length: fixture.before.selectedRangeUTF16.length
                ),
                secure: fixture.target.secure ?? false
            )
            let clipboard = FakeClipboard(
                value: fixture.clipboard?.before,
                changeCount: fixture.clipboard?.beforeChangeCount ?? 7
            )
            let service = AXTextInsertionService(
                workspace: workspace,
                axClient: ax,
                trust: FakeTrust(isTrusted: true),
                clipboard: clipboard
            )

            let outcome = try await service.insert(
                fixture.insertText,
                into: target,
                jobID: UUID()
            )

            if fixture.expected.outcome == "inserted" {
                XCTAssertEqual(
                    outcome,
                    .inserted(method: .selectedTextAttribute),
                    fixture.id
                )
                XCTAssertEqual(ax.valueText, fixture.expected.value, fixture.id)
                XCTAssertEqual(
                    ax.selectedRange,
                    AXTextRange(
                        location: fixture.expected.selectedRangeUTF16?.location ?? 0,
                        length: fixture.expected.selectedRangeUTF16?.length ?? 0
                    ),
                    fixture.id
                )
                XCTAssertEqual(clipboard.writeCount, 0, fixture.id)
            } else {
                XCTAssertEqual(
                    outcome,
                    .copiedToClipboard(reason: try XCTUnwrap(fixture.expected.fallbackReason)),
                    fixture.id
                )
                XCTAssertEqual(clipboard.value, fixture.expected.clipboardValue, fixture.id)
                XCTAssertEqual(clipboard.writeCount, 1, fixture.id)
                XCTAssertTrue(ax.setOperations.isEmpty, fixture.id)
            }
        }

        let fixtureDataAfter = try Data(contentsOf: fixtureURL)
        XCTAssertEqual(fixtureDataBefore, fixtureDataAfter, "fixture must remain read-only")
    }

    func testTextEditValueSpliceUsesUTF16ForUnicodeAndMultilineRanges() throws {
        let cases: [(String, AXTextRange, String, String, AXTextRange)] = [
            (
                "Hi 👋!",
                AXTextRange(location: 3, length: 2),
                "hello",
                "Hi hello!",
                AXTextRange(location: 8, length: 0)
            ),
            (
                "你好，世界",
                AXTextRange(location: 3, length: 2),
                "kvoice",
                "你好，kvoice",
                AXTextRange(location: 9, length: 0)
            ),
            (
                "first\nsecond\nthird",
                AXTextRange(location: 6, length: 6),
                "middle line",
                "first\nmiddle line\nthird",
                AXTextRange(location: 17, length: 0)
            ),
            (
                "Café noir",
                AXTextRange(location: 0, length: 5),
                "Café",
                "Café noir",
                AXTextRange(location: 4, length: 0)
            )
        ]

        for (value, range, insertion, expectedValue, expectedCaret) in cases {
            let result = try TextEditValueSplice.replacing(
                value: value,
                selectedRange: range,
                with: insertion
            )
            XCTAssertEqual(result.replacementValue, expectedValue)
            XCTAssertEqual(result.caret, expectedCaret)
        }
    }

    func testTextEditValueSpliceRejectsInvalidUTF16Ranges() {
        let invalidRanges = [
            AXTextRange(location: -1, length: 0),
            AXTextRange(location: 0, length: -1),
            AXTextRange(location: 99, length: 0),
            AXTextRange(location: 2, length: 99)
        ]

        for range in invalidRanges {
            XCTAssertThrowsError(
                try TextEditValueSplice.replacing(value: "hello", selectedRange: range, with: "x")
            )
        }
    }

    func testValueSpliceIsTextEditOnlyAndRestoresCollapsedCaret() async throws {
        let ax = FakeAXClient(
            processIdentifier: 901,
            value: "hello world",
            selectedRange: AXTextRange(location: 6, length: 5),
            selectedTextSettable: false
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 101)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 901, bundle: "com.apple.TextEdit")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard
        )
        let target = target(pid: 901, bundle: "com.apple.TextEdit", name: "TextEdit")

        let outcome = try await service.insert("kvoice", into: target, jobID: UUID())

        XCTAssertEqual(outcome, .inserted(method: .textEditValueSplice))
        XCTAssertEqual(ax.valueText, "hello kvoice")
        XCTAssertEqual(ax.selectedRange, AXTextRange(location: 12, length: 0))
        XCTAssertEqual(ax.setOperations, [.value, .selectedTextRange])
        XCTAssertEqual(clipboard.value, "sentinel")
        XCTAssertEqual(clipboard.changeCount, 101)
        XCTAssertEqual(clipboard.writeCount, 0)
    }

    func testDirectClipboardCopyWritesExactTextWithoutAXResolution() async throws {
        let ax = FakeAXClient(
            processIdentifier: 901,
            value: "untouched",
            selectedRange: AXTextRange(location: 0, length: 0)
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 7)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace(sequence: []),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard
        )

        try await service.copyToClipboard("exact fallback", jobID: UUID())

        XCTAssertEqual(clipboard.value, "exact fallback")
        XCTAssertEqual(clipboard.writeCount, 1)
        XCTAssertEqual(ax.focusedCallCount, 0)
        XCTAssertTrue(ax.setOperations.isEmpty)
        XCTAssertEqual(ax.valueText, "untouched")
    }

    func testTargetSwitchRefusesMutationAndUsesClipboardExactlyOnce() async throws {
        let ax = FakeAXClient(
            processIdentifier: 100,
            value: "original",
            selectedRange: AXTextRange(location: 0, length: 8)
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 43)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace(sequence: [frontmost(pid: 200, bundle: "com.apple.TextEdit")]),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard
        )
        let outcome = try await service.insert(
            "new text",
            into: target(pid: 100, bundle: "com.apple.TextEdit", name: "TextEdit"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .copiedToClipboard(reason: .targetApplicationChanged))
        XCTAssertEqual(ax.valueText, "original")
        XCTAssertTrue(ax.setOperations.isEmpty)
        XCTAssertEqual(clipboard.value, "new text")
        XCTAssertEqual(clipboard.changeCount, 44)
        XCTAssertEqual(clipboard.writeCount, 1)
    }

    func testCompletionTimeTargetSwitchAfterResolutionStillRefusesMutation() async throws {
        let ax = FakeAXClient(
            processIdentifier: 110,
            value: "original",
            selectedRange: AXTextRange(location: 0, length: 8)
        )
        let original = frontmost(pid: 110, bundle: "com.apple.TextEdit")
        let switched = frontmost(pid: 210, bundle: "com.apple.TextEdit")
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 51)
        let service = AXTextInsertionService(
            // The first two calls are made while resolving the current
            // focused element; the third is the completion-time guard.
            workspace: FakeWorkspace(sequence: [original, original, switched]),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard
        )

        let outcome = try await service.insert(
            "new text",
            into: target(pid: 110, bundle: "com.apple.TextEdit", name: "TextEdit"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .copiedToClipboard(reason: .targetApplicationChanged))
        XCTAssertEqual(ax.valueText, "original")
        XCTAssertTrue(ax.setOperations.isEmpty)
        XCTAssertEqual(clipboard.writeCount, 1)
    }

    func testMissingCapturedBundleIdentityFailsClosed() async throws {
        let ax = FakeAXClient(
            processIdentifier: 211,
            value: "original",
            selectedRange: AXTextRange(location: 0, length: 8)
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 52)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 211, bundle: "com.apple.TextEdit")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard
        )
        let target = TargetApplicationSnapshot(
            processIdentifier: 211,
            bundleIdentifier: nil,
            localizedName: "TextEdit",
            capturedAt: Date(timeIntervalSince1970: 1)
        )

        let outcome = try await service.insert("new text", into: target, jobID: UUID())

        XCTAssertEqual(outcome, .copiedToClipboard(reason: .targetApplicationChanged))
        XCTAssertTrue(ax.setOperations.isEmpty)
        XCTAssertEqual(clipboard.writeCount, 1)
    }

    func testMissingCurrentBundleIdentityFailsClosed() async throws {
        let ax = FakeAXClient(
            processIdentifier: 212,
            value: "original",
            selectedRange: AXTextRange(location: 0, length: 8)
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 53)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(
                FrontmostApplicationSnapshot(
                    processIdentifier: 212,
                    bundleIdentifier: nil,
                    localizedName: "TextEdit"
                )
            ),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard
        )

        let outcome = try await service.insert(
            "new text",
            into: target(pid: 212, bundle: "com.apple.TextEdit", name: "TextEdit"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .copiedToClipboard(reason: .targetApplicationChanged))
        XCTAssertTrue(ax.setOperations.isEmpty)
        XCTAssertEqual(clipboard.writeCount, 1)
    }

    func testSecureTargetNeverMutatesAndCopiesWithoutReadingClipboard() async throws {
        let ax = FakeAXClient(
            processIdentifier: 108,
            value: "••••",
            selectedRange: AXTextRange(location: 0, length: 4),
            secure: true
        )
        let clipboard = FakeClipboard(value: "sentinel-secure", changeCount: 44)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 108, bundle: "com.apple.TextEdit")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard
        )
        let outcome = try await service.insert(
            "secret",
            into: target(pid: 108, bundle: "com.apple.TextEdit", name: "TextEdit"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .copiedToClipboard(reason: .secureTarget))
        XCTAssertEqual(ax.valueText, "••••")
        XCTAssertTrue(ax.setOperations.isEmpty)
        XCTAssertEqual(clipboard.value, "secret")
        XCTAssertEqual(clipboard.readCount, 0)
        XCTAssertEqual(clipboard.writeCount, 1)
    }

    func testUnavailableSecureMetadataFailsClosedWithoutMutation() async throws {
        let ax = FakeAXClient(
            processIdentifier: 109,
            value: "unchanged",
            selectedRange: AXTextRange(location: 0, length: 0),
            secureMetadataOverride: .unavailable
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 45)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 109, bundle: "com.apple.TextEdit")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard
        )

        let outcome = try await service.insert(
            "copy me",
            into: target(pid: 109, bundle: "com.apple.TextEdit", name: "TextEdit"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .copiedToClipboard(reason: .unsupportedValueType))
        XCTAssertTrue(ax.setOperations.isEmpty)
        XCTAssertEqual(clipboard.writeCount, 1)
    }

    func testCancellationBeforeDirectFallbackCheckDoesNotWriteClipboard() async throws {
        let trustEntered = DispatchSemaphore(value: 0)
        let releaseTrust = DispatchSemaphore(value: 0)
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 46)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 110, bundle: "com.apple.TextEdit")),
            axClient: FakeAXClient(
                processIdentifier: 110,
                value: "unchanged",
                selectedRange: AXTextRange(location: 0, length: 0)
            ),
            trust: BlockingTrust(
                result: false,
                entered: trustEntered,
                release: releaseTrust
            ),
            clipboard: clipboard
        )
        let capturedTarget = Self.target(pid: 110, bundle: "com.apple.TextEdit", name: "TextEdit")
        let task = Task {
            try await service.insert(
                "copy me",
                into: capturedTarget,
                jobID: UUID()
            )
        }

        XCTAssertEqual(trustEntered.wait(timeout: .now() + 1), .success)
        task.cancel()
        releaseTrust.signal()

        do {
            _ = try await task.value
            XCTFail("cancellation must not be converted into clipboard fallback")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(clipboard.writeCount, 0)
    }

    func testUntrustedAndUnsupportedTargetsUseClipboardWithoutAXMutation() async throws {
        let untrustedAX = FakeAXClient(
            processIdentifier: 301,
            value: "unchanged",
            selectedRange: AXTextRange(location: 0, length: 0)
        )
        let untrustedClipboard = FakeClipboard(value: "sentinel", changeCount: 1)
        let untrustedService = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 301, bundle: "com.apple.TextEdit")),
            axClient: untrustedAX,
            trust: FakeTrust(isTrusted: false),
            clipboard: untrustedClipboard
        )
        let untrustedOutcome = try await untrustedService.insert(
            "copy me",
            into: target(pid: 301, bundle: "com.apple.TextEdit", name: "TextEdit"),
            jobID: UUID()
        )
        XCTAssertEqual(untrustedOutcome, .copiedToClipboard(reason: .noFocusedElement))
        XCTAssertEqual(untrustedAX.focusedCallCount, 0)
        XCTAssertEqual(untrustedClipboard.writeCount, 1)

        let unsupportedAX = FakeAXClient(
            processIdentifier: 302,
            value: "unchanged",
            selectedRange: AXTextRange(location: 0, length: 0),
            selectedTextSettable: false,
            valueSettable: false,
            rangeSettable: false
        )
        let unsupportedClipboard = FakeClipboard(value: "sentinel", changeCount: 2)
        // With the ADR-016 typed tier switched off, a read-only text area is
        // still an unsupported target and goes to the clipboard.
        let unsupportedPoster = FakeKeyPoster()
        let unsupportedService = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 302, bundle: "com.example.Other")),
            axClient: unsupportedAX,
            trust: FakeTrust(isTrusted: true),
            clipboard: unsupportedClipboard,
            keyPoster: unsupportedPoster,
            typedInsertionEnabled: false
        )
        let unsupportedOutcome = try await unsupportedService.insert(
            "copy me",
            into: target(pid: 302, bundle: "com.example.Other", name: "Other"),
            jobID: UUID()
        )
        XCTAssertEqual(unsupportedOutcome, .copiedToClipboard(reason: .unsupportedValueType))
        XCTAssertTrue(unsupportedAX.setOperations.isEmpty)
        XCTAssertTrue(unsupportedPoster.posted.isEmpty)
        XCTAssertEqual(unsupportedClipboard.writeCount, 1)
    }

    func testDisabledEditableRoleIsRejectedBeforeAnyMutation() async throws {
        let ax = FakeAXClient(
            processIdentifier: 303,
            value: "unchanged",
            selectedRange: AXTextRange(location: 0, length: 0),
            enabled: false
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 3)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 303, bundle: "com.apple.TextEdit")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard
        )

        let outcome = try await service.insert(
            "copy me",
            into: target(pid: 303, bundle: "com.apple.TextEdit", name: "TextEdit"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .copiedToClipboard(reason: .notEditable))
        XCTAssertEqual(ax.valueText, "unchanged")
        XCTAssertTrue(ax.setOperations.isEmpty)
        XCTAssertEqual(clipboard.writeCount, 1)
    }

    func testMissingFrontmostApplicationUsesClipboardWithoutResolvingAX() async throws {
        let ax = FakeAXClient(
            processIdentifier: 304,
            value: "unchanged",
            selectedRange: AXTextRange(location: 0, length: 0)
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 4)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace(sequence: [nil]),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard
        )

        let outcome = try await service.insert(
            "copy me",
            into: target(pid: 304, bundle: "com.apple.TextEdit", name: "TextEdit"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .copiedToClipboard(reason: .noFrontmostApplication))
        XCTAssertEqual(ax.focusedCallCount, 0)
        XCTAssertEqual(clipboard.writeCount, 1)
    }

    func testInvalidRangeDoesNotMutateTextEdit() async throws {
        let ax = FakeAXClient(
            processIdentifier: 401,
            value: "short",
            selectedRange: AXTextRange(location: 4, length: 99),
            selectedTextSettable: false
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 9)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 401, bundle: "com.apple.TextEdit")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard
        )

        let outcome = try await service.insert(
            "replacement",
            into: target(pid: 401, bundle: "com.apple.TextEdit", name: "TextEdit"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .copiedToClipboard(reason: .unsupportedValueType))
        XCTAssertEqual(ax.valueText, "short")
        XCTAssertTrue(ax.setOperations.isEmpty)
        XCTAssertEqual(clipboard.writeCount, 1)
    }

    func testOversizedInsertionUsesClipboardWithoutAXMutation() async throws {
        let ax = FakeAXClient(
            processIdentifier: 402,
            value: "unchanged",
            selectedRange: AXTextRange(location: 0, length: 0)
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 90)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 402, bundle: "com.apple.TextEdit")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard
        )
        let oversized = String(repeating: "x", count: AXInsertionLimits.maxUTF8Bytes + 1)

        let outcome = try await service.insert(
            oversized,
            into: target(pid: 402, bundle: "com.apple.TextEdit", name: "TextEdit"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .copiedToClipboard(reason: .unsupportedValueType))
        XCTAssertEqual(clipboard.value, oversized)
        XCTAssertTrue(ax.setOperations.isEmpty)
        XCTAssertEqual(clipboard.writeCount, 1)
    }

    func testOversizedValueAndRangeAreRejectedBeforeTextEditMutation() async throws {
        let oversizedValueAX = FakeAXClient(
            processIdentifier: 403,
            value: String(repeating: "v", count: AXInsertionLimits.maxUTF8Bytes + 1),
            selectedRange: AXTextRange(location: 0, length: 0),
            selectedTextSettable: false
        )
        let oversizedValueClipboard = FakeClipboard(value: "sentinel", changeCount: 91)
        let oversizedValueService = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 403, bundle: "com.apple.TextEdit")),
            axClient: oversizedValueAX,
            trust: FakeTrust(isTrusted: true),
            clipboard: oversizedValueClipboard
        )

        let oversizedValueOutcome = try await oversizedValueService.insert(
            "x",
            into: target(pid: 403, bundle: "com.apple.TextEdit", name: "TextEdit"),
            jobID: UUID()
        )

        XCTAssertEqual(oversizedValueOutcome, .copiedToClipboard(reason: .unsupportedValueType))
        XCTAssertTrue(oversizedValueAX.setOperations.isEmpty)

        let oversizedRangeAX = FakeAXClient(
            processIdentifier: 404,
            value: "value",
            selectedRange: AXTextRange(location: AXInsertionLimits.maxUTF16Units + 1, length: 0),
            selectedTextSettable: false
        )
        let oversizedRangeClipboard = FakeClipboard(value: "sentinel", changeCount: 92)
        let oversizedRangeService = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 404, bundle: "com.apple.TextEdit")),
            axClient: oversizedRangeAX,
            trust: FakeTrust(isTrusted: true),
            clipboard: oversizedRangeClipboard
        )

        let oversizedRangeOutcome = try await oversizedRangeService.insert(
            "x",
            into: target(pid: 404, bundle: "com.apple.TextEdit", name: "TextEdit"),
            jobID: UUID()
        )

        XCTAssertEqual(oversizedRangeOutcome, .copiedToClipboard(reason: .unsupportedValueType))
        XCTAssertTrue(oversizedRangeAX.setOperations.isEmpty)
    }

    func testSelectedTextSetFailureIsUncertainAndDoesNotFallbackOrSplice() async throws {
        let ax = FakeAXClient(
            processIdentifier: 405,
            value: "before",
            selectedRange: AXTextRange(location: 6, length: 0),
            delayedSetDuration: .milliseconds(180)
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 93)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 405, bundle: "com.apple.TextEdit")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard,
            timeout: .milliseconds(20)
        )

        do {
            _ = try await service.insert(
                "!",
                into: target(pid: 405, bundle: "com.apple.TextEdit", name: "TextEdit"),
                jobID: UUID()
            )
            XCTFail("a timed-out in-flight mutation must be reported as uncertain")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .accessibilityVerifyFailed)
            XCTAssertFalse(error.retryable)
        }

        XCTAssertEqual(clipboard.writeCount, 0)
        XCTAssertEqual(ax.setOperations, [.selectedText])
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(ax.valueText, "before!")
    }

    func testLateSetAfterTimeoutIsSuppressedByOperationGate() async throws {
        let ax = FakeAXClient(
            processIdentifier: 406,
            value: "before",
            selectedRange: AXTextRange(location: 6, length: 0),
            blockedValueDuration: .milliseconds(180)
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 94)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 406, bundle: "com.apple.TextEdit")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard,
            timeout: .milliseconds(20)
        )

        let outcome = try await service.insert(
            "!",
            into: target(pid: 406, bundle: "com.apple.TextEdit", name: "TextEdit"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .copiedToClipboard(reason: .timeout))
        XCTAssertEqual(clipboard.writeCount, 1)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(ax.setOperations.isEmpty)
        XCTAssertEqual(ax.valueText, "before")
    }

    func testCancellationDuringBlockedAXOperationDoesNotWriteClipboard() async throws {
        let focusStarted = DispatchSemaphore(value: 0)
        let ax = FakeAXClient(
            processIdentifier: 408,
            value: "before",
            selectedRange: AXTextRange(location: 6, length: 0),
            blockedFocusDuration: .milliseconds(180),
            focusStarted: focusStarted
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 96)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 408, bundle: "com.apple.TextEdit")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard,
            timeout: .seconds(1)
        )
        let capturedTarget = Self.target(pid: 408, bundle: "com.apple.TextEdit", name: "TextEdit")
        let task = Task {
            try await service.insert(
                "!",
                into: capturedTarget,
                jobID: UUID()
            )
        }

        XCTAssertEqual(focusStarted.wait(timeout: .now() + 1), .success)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancellation must not use clipboard fallback")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(clipboard.writeCount, 0)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(ax.setOperations.isEmpty)
    }

    func testCannotCompleteRetryDoesNotLoseGateNearFirstTimeout() async throws {
        let executor = SerialAXExecutor(timeout: .milliseconds(100))
        let gate = AXOperationGate()
        let firstAttemptStarted = DispatchSemaphore(value: 0)
        let attempts = AttemptCounter()

        let result = try await executor.runWithCannotCompleteRetry(gate: gate) {
            let attempt = attempts.next()

            if attempt == 1 {
                firstAttemptStarted.signal()
                Thread.sleep(forTimeInterval: 0.05)
                throw AXClientError.cannotComplete
            }

            // This overlaps the first invocation's original deadline. A
            // stale first timer would invalidate the shared gate here.
            Thread.sleep(forTimeInterval: 0.07)
            guard gate.beginMutation() else {
                throw AXOperationGateError.invalidated
            }
            return "retried"
        }

        XCTAssertEqual(firstAttemptStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result, "retried")
        XCTAssertEqual(attempts.value, 2)
        XCTAssertTrue(gate.isMutationStarted)
    }

    func testTextEditCaretFailureAfterValueWriteNeverCopiesToClipboard() async throws {
        let ax = FakeAXClient(
            processIdentifier: 407,
            value: "hello",
            selectedRange: AXTextRange(location: 5, length: 0),
            selectedTextSettable: false,
            rangeSetFailure: .unsupportedAttribute
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 95)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 407, bundle: "com.apple.TextEdit")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard
        )

        do {
            _ = try await service.insert(
                "!",
                into: target(pid: 407, bundle: "com.apple.TextEdit", name: "TextEdit"),
                jobID: UUID()
            )
            XCTFail("a failed caret mutation must be reported as uncertain")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .accessibilityVerifyFailed)
            XCTAssertFalse(error.retryable)
        }

        XCTAssertEqual(ax.valueText, "hello!")
        XCTAssertEqual(ax.setOperations, [.value, .selectedTextRange])
        XCTAssertEqual(clipboard.writeCount, 0)
    }

    func testCannotCompleteRetriesExactlyOnceOnTheSerialExecutor() async throws {
        let ax = FakeAXClient(
            processIdentifier: 501,
            value: "before",
            selectedRange: AXTextRange(location: 6, length: 0),
            focusFailures: [.cannotComplete]
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 10)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 501, bundle: "com.apple.TextEdit")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard,
            timeout: .milliseconds(100)
        )

        let outcome = try await service.insert(
            "!",
            into: target(pid: 501, bundle: "com.apple.TextEdit", name: "TextEdit"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .inserted(method: .selectedTextAttribute))
        XCTAssertEqual(ax.focusedCallCount, 2)
        XCTAssertEqual(ax.valueText, "before!")
        XCTAssertEqual(clipboard.writeCount, 0)
    }

    func testCannotCompleteGetsOnlyOneRetryThenCopiesSetFailure() async throws {
        let ax = FakeAXClient(
            processIdentifier: 502,
            value: "before",
            selectedRange: AXTextRange(location: 0, length: 0),
            focusFailures: [.cannotComplete, .cannotComplete, .cannotComplete]
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 11)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 502, bundle: "com.apple.TextEdit")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard,
            timeout: .milliseconds(100)
        )

        let outcome = try await service.insert(
            "!",
            into: target(pid: 502, bundle: "com.apple.TextEdit", name: "TextEdit"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .copiedToClipboard(reason: .setFailed))
        XCTAssertEqual(ax.focusedCallCount, 2)
        XCTAssertTrue(ax.setOperations.isEmpty)
        XCTAssertEqual(clipboard.writeCount, 1)
    }

    func testTimeoutIsBoundedAndCopiesWithoutWaitingForBlockedAXCall() async throws {
        let ax = FakeAXClient(
            processIdentifier: 503,
            value: "before",
            selectedRange: AXTextRange(location: 0, length: 0),
            blockedFocusDuration: .milliseconds(180)
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 12)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 503, bundle: "com.apple.TextEdit")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard,
            timeout: .milliseconds(20)
        )
        let started = ContinuousClock().now

        let outcome = try await service.insert(
            "!",
            into: target(pid: 503, bundle: "com.apple.TextEdit", name: "TextEdit"),
            jobID: UUID()
        )
        let elapsed = started.duration(to: ContinuousClock().now)

        XCTAssertEqual(outcome, .copiedToClipboard(reason: .timeout))
        XCTAssertLessThan(elapsed, .milliseconds(120))
        XCTAssertTrue(ax.setOperations.isEmpty)
        XCTAssertEqual(clipboard.writeCount, 1)
    }

    func testSuccessfulAXInsertionLeavesClipboardSentinelUntouched() async throws {
        let ax = FakeAXClient(
            processIdentifier: 601,
            value: "hello",
            selectedRange: AXTextRange(location: 5, length: 0)
        )
        let clipboard = FakeClipboard(value: "sentinel-ascii", changeCount: 41)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 601, bundle: "com.apple.TextEdit")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard
        )

        let outcome = try await service.insert(
            " world",
            into: target(pid: 601, bundle: "com.apple.TextEdit", name: "TextEdit"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .inserted(method: .selectedTextAttribute))
        XCTAssertEqual(clipboard.value, "sentinel-ascii")
        XCTAssertEqual(clipboard.changeCount, 41)
        XCTAssertEqual(clipboard.writeCount, 0)
        XCTAssertEqual(clipboard.readCount, 0)
    }

    /// FR-AX-001 as amended by ADR-016: typing is permitted, but only from one
    /// dedicated poster file, and no file anywhere in the module may build a
    /// synthetic paste.  The intent is unchanged — a pasteboard-backed success
    /// path must be impossible to write without this test failing.
    func testSourceDoesNotContainSyntheticPasteMechanisms() throws {
        let typedPosterFileName = "TypedKeyboardEventPoster.swift"
        let sourceFiles = try FileManager.default.contentsOfDirectory(
            at: Self.sourceDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        XCTAssertTrue(
            sourceFiles.contains { $0.lastPathComponent == typedPosterFileName },
            "the typed poster must live in its dedicated file"
        )

        let pasteTokens = [
            "Command-V",
            "kVK_ANSI_V",
            ".maskCommand",
            "CGEventTap",
            "post(tap",
            "tapCreate",
            "virtualKey: 9",
            "virtualKey: 0x09"
        ]
        let eventTokens = ["CGEvent", "keyDown", "postToPid", "keyboardSetUnicodeString"]

        for file in sourceFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            let name = file.lastPathComponent

            for token in pasteTokens {
                XCTAssertFalse(source.contains(token), "\(name) contains \(token)")
            }

            if name == typedPosterFileName {
                XCTAssertTrue(source.contains("CGEvent"), "poster must be the CGEvent adapter")
                XCTAssertTrue(source.contains("postToPid"), "poster must address the target PID only")
                XCTAssertFalse(source.contains("NSPasteboard"), "poster must not touch the pasteboard")
                XCTAssertFalse(source.contains("import AppKit"), "poster must not import AppKit")
                XCTAssertFalse(source.contains("post(tap"), "poster must not post to a system tap")
            } else {
                for token in eventTokens {
                    XCTAssertFalse(source.contains(token), "\(name) contains \(token)")
                }
            }
        }
    }

    // MARK: - ADR-016 typed keyboard-event tier

    func testTerminalLikeReadOnlyTextAreaUsesTypedKeyboardEvents() async throws {
        let ax = FakeAXClient(
            processIdentifier: 700,
            value: "$ ",
            selectedRange: AXTextRange(location: 2, length: 0),
            selectedTextSettable: false,
            valueSettable: false,
            rangeSettable: false,
            role: "AXTextArea",
            subrole: nil
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 11)
        let poster = FakeKeyPoster()
        let diagnostics = RecordingDiagnostics()
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 700, bundle: "com.apple.Terminal")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard,
            diagnostics: diagnostics,
            keyPoster: poster,
            typedChunkPacing: .zero
        )

        let text = "echo hello from kvoice — 你好 👋 done"
        let outcome = try await service.insert(
            text,
            into: target(pid: 700, bundle: "com.apple.Terminal", name: "Terminal"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .inserted(method: .typedKeyboardEvents))
        XCTAssertEqual(poster.posted.map(\.pid), Array(repeating: 700, count: poster.posted.count))
        XCTAssertEqual(poster.posted.map(\.chunk), TypedTextChunker.chunks(of: text))
        XCTAssertEqual(poster.posted.map(\.chunk).joined(), text)
        XCTAssertTrue(poster.posted.allSatisfy { $0.chunk.utf16.count <= 20 && !$0.chunk.isEmpty })
        XCTAssertTrue(ax.setOperations.isEmpty, "typed tier must not perform an AX mutation")
        XCTAssertEqual(ax.valueText, "$ ")
        XCTAssertEqual(clipboard.value, "sentinel")
        XCTAssertEqual(clipboard.changeCount, 11)
        XCTAssertEqual(clipboard.writeCount, 0)

        let completed = await diagnostics.events(named: .insertionCompleted)
        XCTAssertEqual(completed.map(\.attributes.strategy), [.typedKeyboardEvents])
    }

    /// The Claude desktop app (2026-09-14): Chromium reports the message
    /// box's AXSelectedText as settable and accepts the write, but the web
    /// editor drops it, so the AX tier ended as an unverifiable mutation.
    /// Web content (AXDOMIdentifier present) goes straight to typing.
    func testChromiumWebEditorIsTypedInsteadOfAXWritten() async throws {
        let ax = FakeAXClient(
            processIdentifier: 800,
            value: "",
            selectedRange: AXTextRange(location: 0, length: 0),
            selectedTextSettable: true,
            valueSettable: true,
            rangeSettable: true,
            role: "AXTextArea",
            subrole: nil,
            domIdentifier: ""
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 3)
        let poster = FakeKeyPoster()
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 800, bundle: "com.anthropic.claudefordesktop")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard,
            keyPoster: poster,
            typedChunkPacing: .zero
        )

        let outcome = try await service.insert(
            "Does it work?",
            into: target(pid: 800, bundle: "com.anthropic.claudefordesktop", name: "Claude"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .inserted(method: .typedKeyboardEvents))
        XCTAssertEqual(poster.posted.map(\.chunk).joined(), "Does it work?")
        XCTAssertTrue(ax.setOperations.isEmpty, "no AX mutation may be attempted in web content")
        XCTAssertEqual(clipboard.writeCount, 0)
    }

    /// With typing switched off the AX tiers still run for web content, so
    /// the setting keeps its meaning (a worse path, never no path).
    func testChromiumWebEditorFallsBackToAXTiersWhenTypingIsDisabled() async throws {
        let ax = FakeAXClient(
            processIdentifier: 800,
            value: "",
            selectedRange: AXTextRange(location: 0, length: 0),
            selectedTextSettable: true,
            role: "AXTextArea",
            subrole: nil,
            domIdentifier: "composer"
        )
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 800, bundle: "com.anthropic.claudefordesktop")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: FakeClipboard(value: "", changeCount: 0),
            keyPoster: FakeKeyPoster(),
            typedChunkPacing: .zero
        )
        await service.setTypedInsertionEnabled(false)

        _ = try await service.insert(
            "hello",
            into: target(pid: 800, bundle: "com.anthropic.claudefordesktop", name: "Claude"),
            jobID: UUID()
        )

        XCTAssertEqual(ax.setOperations, [.selectedText])
    }

    func testTypedTierCollapsesNewlinesAndTabsToOneSpace() async throws {
        let ax = FakeAXClient(
            processIdentifier: 701,
            value: "",
            selectedRange: AXTextRange(location: 0, length: 0),
            selectedTextSettable: false,
            valueSettable: false,
            rangeSettable: false,
            role: "AXTextArea",
            subrole: nil
        )
        let poster = FakeKeyPoster()
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 701, bundle: "com.googlecode.iterm2")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: FakeClipboard(value: nil, changeCount: 0),
            keyPoster: poster,
            typedChunkPacing: .zero
        )

        let outcome = try await service.insert(
            "ls -la\r\n\r\nrm -rf /\n\tsudo\r reboot\n",
            into: target(pid: 701, bundle: "com.googlecode.iterm2", name: "iTerm2"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .inserted(method: .typedKeyboardEvents))
        let typed = poster.posted.map(\.chunk).joined()
        // Each break/tab run becomes exactly one space; an adjacent literal
        // space is preserved ("\r " -> two spaces), which is harmless to type.
        XCTAssertEqual(typed, "ls -la rm -rf / sudo  reboot ")
        XCTAssertFalse(typed.contains("\n") || typed.contains("\r") || typed.contains("\t"))
    }

    func testTypedTierIsRefusedForSecureFieldAndFallsBackToClipboard() async throws {
        let ax = FakeAXClient(
            processIdentifier: 702,
            value: "",
            selectedRange: AXTextRange(location: 0, length: 0),
            secure: true,
            selectedTextSettable: false,
            valueSettable: false,
            rangeSettable: false,
            role: "AXSecureTextField",
            subrole: "AXSecureTextField"
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 3)
        let poster = FakeKeyPoster()
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 702, bundle: "com.apple.Terminal")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard,
            keyPoster: poster,
            typedChunkPacing: .zero
        )

        let outcome = try await service.insert(
            "hunter2",
            into: target(pid: 702, bundle: "com.apple.Terminal", name: "Terminal"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .copiedToClipboard(reason: .secureTarget))
        XCTAssertTrue(poster.posted.isEmpty)
        XCTAssertEqual(clipboard.value, "hunter2")
        XCTAssertEqual(clipboard.writeCount, 1)
    }

    func testTypedTierIsRefusedWhenAnotherApplicationIsFrontmost() async throws {
        let ax = FakeAXClient(
            processIdentifier: 703,
            value: "",
            selectedRange: AXTextRange(location: 0, length: 0),
            selectedTextSettable: false,
            valueSettable: false,
            rangeSettable: false,
            role: "AXTextArea",
            subrole: nil
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 3)
        let poster = FakeKeyPoster()
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 999, bundle: "com.apple.Safari")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard,
            keyPoster: poster,
            typedChunkPacing: .zero
        )

        let outcome = try await service.insert(
            "not for safari",
            into: target(pid: 703, bundle: "com.apple.Terminal", name: "Terminal"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .copiedToClipboard(reason: .targetApplicationChanged))
        XCTAssertTrue(poster.posted.isEmpty)
        XCTAssertEqual(ax.focusedCallCount, 0)
        XCTAssertEqual(clipboard.writeCount, 1)
    }

    func testTypedTierRechecksTargetImmediatelyBeforeTyping() async throws {
        // First pass sees the terminal frontmost; the re-check before the
        // first keyboard event sees another app.  Nothing may be typed.
        let terminal = frontmost(pid: 704, bundle: "com.apple.Terminal")
        let other = frontmost(pid: 998, bundle: "com.apple.Safari")
        let ax = FakeAXClient(
            processIdentifier: 704,
            value: "",
            selectedRange: AXTextRange(location: 0, length: 0),
            selectedTextSettable: false,
            valueSettable: false,
            rangeSettable: false,
            role: "AXTextArea",
            subrole: nil
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 3)
        let poster = FakeKeyPoster()
        let service = AXTextInsertionService(
            // The first pass reads the frontmost app three times (resolve,
            // resolver affinity, after-metadata); the re-check then sees the
            // other application on its first read.
            workspace: FakeWorkspace(sequence: [terminal, terminal, terminal, other]),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard,
            keyPoster: poster,
            typedChunkPacing: .zero
        )

        let outcome = try await service.insert(
            "late",
            into: target(pid: 704, bundle: "com.apple.Terminal", name: "Terminal"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .copiedToClipboard(reason: .targetApplicationChanged))
        XCTAssertTrue(poster.posted.isEmpty)
        XCTAssertEqual(clipboard.writeCount, 1)
    }

    func testTypedTierIsSkippedWhenDisabled() async throws {
        let ax = FakeAXClient(
            processIdentifier: 705,
            value: "",
            selectedRange: AXTextRange(location: 0, length: 0),
            selectedTextSettable: false,
            valueSettable: false,
            rangeSettable: false,
            role: "AXTextArea",
            subrole: nil
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 3)
        let poster = FakeKeyPoster()
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 705, bundle: "com.apple.Terminal")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard,
            keyPoster: poster,
            typedChunkPacing: .zero
        )
        XCTAssertTrue(service.isTypedInsertionEnabled, "default is on")
        service.setTypedInsertionEnabled(false)
        XCTAssertFalse(service.isTypedInsertionEnabled)

        let target = target(pid: 705, bundle: "com.apple.Terminal", name: "Terminal")
        let disabled = try await service.insert("off", into: target, jobID: UUID())
        XCTAssertEqual(disabled, .copiedToClipboard(reason: .unsupportedValueType))
        XCTAssertTrue(poster.posted.isEmpty)
        XCTAssertEqual(clipboard.value, "off")

        service.setTypedInsertionEnabled(true)
        let enabled = try await service.insert("on", into: target, jobID: UUID())
        XCTAssertEqual(enabled, .inserted(method: .typedKeyboardEvents))
        XCTAssertEqual(poster.posted.map(\.chunk), ["on"])
        XCTAssertEqual(clipboard.value, "off", "typed success must not write the clipboard")
    }

    func testTypedTierIsNotUsedWhenSelectedTextIsSettable() async throws {
        let ax = FakeAXClient(
            processIdentifier: 706,
            value: "hello",
            selectedRange: AXTextRange(location: 5, length: 0),
            role: "AXTextArea",
            subrole: nil
        )
        let poster = FakeKeyPoster()
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 706, bundle: "com.apple.Notes")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: FakeClipboard(value: nil, changeCount: 0),
            keyPoster: poster,
            typedChunkPacing: .zero
        )

        let outcome = try await service.insert(
            " world",
            into: target(pid: 706, bundle: "com.apple.Notes", name: "Notes"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .inserted(method: .selectedTextAttribute))
        XCTAssertEqual(ax.valueText, "hello world")
        XCTAssertTrue(poster.posted.isEmpty)
    }

    func testTypedTierIsNotUsedForUnknownOrContainerRoles() async throws {
        for (role, subrole) in [("AXScrollArea", nil), ("AXGroup", nil), ("AXTextArea", "AXMysterySubrole")] {
            let ax = FakeAXClient(
                processIdentifier: 707,
                value: "",
                selectedRange: AXTextRange(location: 0, length: 0),
                selectedTextSettable: false,
                valueSettable: false,
                rangeSettable: false,
                role: role,
                subrole: subrole
            )
            let clipboard = FakeClipboard(value: "sentinel", changeCount: 3)
            let poster = FakeKeyPoster()
            let service = AXTextInsertionService(
                workspace: FakeWorkspace.repeating(frontmost(pid: 707, bundle: "com.example.term")),
                axClient: ax,
                trust: FakeTrust(isTrusted: true),
                clipboard: clipboard,
                keyPoster: poster,
                typedChunkPacing: .zero
            )

            let outcome = try await service.insert(
                "x",
                into: target(pid: 707, bundle: "com.example.term", name: "Term"),
                jobID: UUID()
            )

            XCTAssertEqual(outcome, .copiedToClipboard(reason: .unsupportedValueType), role)
            XCTAssertTrue(poster.posted.isEmpty, role)
            XCTAssertEqual(clipboard.writeCount, 1, role)
        }
    }

    func testTypedTierDoesNotFollowAFailedAXMutation() async throws {
        // Tier 1 was *available* and failed after starting: the outcome is an
        // uncertain mutation, never typing on top of it and never the clipboard.
        let ax = FakeAXClient(
            processIdentifier: 708,
            value: "abc",
            selectedRange: AXTextRange(location: 3, length: 0),
            selectedTextSetFailure: .failed(code: -25200),
            role: "AXTextArea",
            subrole: nil
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 3)
        let poster = FakeKeyPoster()
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 708, bundle: "com.apple.Terminal")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard,
            keyPoster: poster,
            typedChunkPacing: .zero
        )

        do {
            _ = try await service.insert(
                "x",
                into: target(pid: 708, bundle: "com.apple.Terminal", name: "Terminal"),
                jobID: UUID()
            )
            XCTFail("expected an uncertain-mutation error")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .accessibilityVerifyFailed)
        }
        XCTAssertTrue(poster.posted.isEmpty)
        XCTAssertEqual(clipboard.writeCount, 0)
    }

    func testTypedTierPosterFailureMidwayReportsUncertainMutationWithoutClipboard() async throws {
        let ax = FakeAXClient(
            processIdentifier: 709,
            value: "",
            selectedRange: AXTextRange(location: 0, length: 0),
            selectedTextSettable: false,
            valueSettable: false,
            rangeSettable: false,
            role: "AXTextArea",
            subrole: nil
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 3)
        let poster = FakeKeyPoster(failAtChunkIndex: 1)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 709, bundle: "com.apple.Terminal")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard,
            keyPoster: poster,
            typedChunkPacing: .zero
        )

        do {
            _ = try await service.insert(
                String(repeating: "a", count: 45),
                into: target(pid: 709, bundle: "com.apple.Terminal", name: "Terminal"),
                jobID: UUID()
            )
            XCTFail("expected an uncertain-mutation error")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .accessibilityVerifyFailed)
        }
        XCTAssertEqual(poster.posted.count, 1, "typing stops at the first failure")
        XCTAssertEqual(clipboard.value, "sentinel")
        XCTAssertEqual(clipboard.writeCount, 0)
    }

    /// ADR-022 item 9: every error `insert` throws to the controller leaves
    /// exactly one scalar line — `insertion.uncertain` for an unverifiable
    /// mutation, `insertion.failed` for anything else — whose `site` names
    /// the gate that decided and whose `reason` classifies it. Never text.
    func testEveryErrorLeavingInsertLogsExactlyOneLineNamingTheGate() async throws {
        // 1. Typed tier: the poster fails after the first chunk.
        do {
            let ax = FakeAXClient(
                processIdentifier: 709, value: "", selectedRange: AXTextRange(location: 0, length: 0),
                selectedTextSettable: false, valueSettable: false, rangeSettable: false,
                role: "AXTextArea", subrole: nil
            )
            let diagnostics = RecordingDiagnostics()
            let service = AXTextInsertionService(
                workspace: FakeWorkspace.repeating(frontmost(pid: 709, bundle: "com.apple.Terminal")),
                axClient: ax, trust: FakeTrust(isTrusted: true),
                clipboard: FakeClipboard(value: "sentinel", changeCount: 3),
                diagnostics: diagnostics,
                keyPoster: FakeKeyPoster(failAtChunkIndex: 1), typedChunkPacing: .zero
            )
            do {
                _ = try await service.insert(String(repeating: "a", count: 45), into: target(pid: 709, bundle: "com.apple.Terminal", name: "Terminal"), jobID: UUID())
                XCTFail("expected an uncertain-mutation error")
            } catch let error as KVoiceError {
                XCTAssertEqual(error.metadata.site?.rawValue, "typedPoster", "the site rides in the error's scalar metadata")
            }
            let uncertain = await diagnostics.events(named: .insertionUncertain)
            XCTAssertEqual(uncertain.count, 1)
            XCTAssertEqual(uncertain.first?.errorCode, .accessibilityVerifyFailed)
            XCTAssertEqual(uncertain.first?.attributes.site?.rawValue, "typedPoster")
            XCTAssertEqual(uncertain.first?.attributes.reason?.rawValue, "mutationUnverified")
            let failed = await diagnostics.events(named: .insertionFailed)
            XCTAssertTrue(failed.isEmpty, "one line, not two")
        }
        // 2. TextEdit splice: the value write lands, the caret write fails.
        do {
            let ax = FakeAXClient(
                processIdentifier: 405, value: "before", selectedRange: AXTextRange(location: 6, length: 0),
                selectedTextSettable: false, rangeSetFailure: .cannotComplete
            )
            let diagnostics = RecordingDiagnostics()
            let service = AXTextInsertionService(
                workspace: FakeWorkspace.repeating(frontmost(pid: 405, bundle: "com.apple.TextEdit")),
                axClient: ax, trust: FakeTrust(isTrusted: true),
                clipboard: FakeClipboard(value: "sentinel", changeCount: 3),
                diagnostics: diagnostics
            )
            do {
                _ = try await service.insert("!", into: target(pid: 405, bundle: "com.apple.TextEdit", name: "TextEdit"), jobID: UUID())
                XCTFail("expected an uncertain-mutation error")
            } catch is KVoiceError {}
            let uncertain = await diagnostics.events(named: .insertionUncertain)
            XCTAssertEqual(uncertain.count, 1)
            XCTAssertEqual(uncertain.first?.attributes.site?.rawValue, "valueSplice")
        }
        // 3. A mutation still in flight at the timeout.
        do {
            let ax = FakeAXClient(
                processIdentifier: 405, value: "before", selectedRange: AXTextRange(location: 6, length: 0),
                delayedSetDuration: .milliseconds(180)
            )
            let diagnostics = RecordingDiagnostics()
            let service = AXTextInsertionService(
                workspace: FakeWorkspace.repeating(frontmost(pid: 405, bundle: "com.apple.TextEdit")),
                axClient: ax, trust: FakeTrust(isTrusted: true),
                clipboard: FakeClipboard(value: "sentinel", changeCount: 3),
                timeout: .milliseconds(20), diagnostics: diagnostics
            )
            do {
                _ = try await service.insert("!", into: target(pid: 405, bundle: "com.apple.TextEdit", name: "TextEdit"), jobID: UUID())
                XCTFail("expected an uncertain-mutation error")
            } catch is KVoiceError {}
            let uncertain = await diagnostics.events(named: .insertionUncertain)
            XCTAssertEqual(uncertain.count, 1)
            XCTAssertEqual(uncertain.first?.attributes.site?.rawValue, "executorTimeoutAfterMutation")
            try await Task.sleep(for: .milliseconds(220)) // let the late set unwind
        }
        // 4. The clipboard fallback itself cannot write: `insertion.failed`
        //    names the gate that fell back, so both facts are in one line.
        do {
            let ax = FakeAXClient(processIdentifier: 304, value: "unchanged", selectedRange: AXTextRange(location: 0, length: 0))
            let diagnostics = RecordingDiagnostics()
            let service = AXTextInsertionService(
                workspace: FakeWorkspace(sequence: [nil]),
                axClient: ax, trust: FakeTrust(isTrusted: true),
                clipboard: FakeClipboard(value: "sentinel", changeCount: 4, writeFailure: KVoiceError(code: .clipboardWriteFailed)),
                diagnostics: diagnostics
            )
            do {
                _ = try await service.insert("copy me", into: target(pid: 304, bundle: "com.apple.TextEdit", name: "TextEdit"), jobID: UUID())
                XCTFail("expected the clipboard failure to propagate")
            } catch let error as KVoiceError {
                XCTAssertEqual(error.code, .clipboardWriteFailed)
            }
            let failed = await diagnostics.events(named: .insertionFailed)
            XCTAssertEqual(failed.count, 1)
            XCTAssertEqual(failed.first?.errorCode, .clipboardWriteFailed)
            XCTAssertEqual(failed.first?.attributes.site?.rawValue, "resolveFocused")
            XCTAssertEqual(failed.first?.attributes.reason?.rawValue, "clipboardWriteFailed")
            let fallback = await diagnostics.events(named: .insertionClipboardFallback)
            XCTAssertEqual(fallback.first?.attributes.site?.rawValue, "resolveFocused", "the fallback decision names the same gate")
            let encoded = try JSONEncoder().encode(failed.first)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("copy me"))

            // 5. The direct copy (no target captured, the recovery Copy) too.
            do {
                try await service.copyToClipboard("copy me", jobID: UUID())
                XCTFail("expected the clipboard failure to propagate")
            } catch is KVoiceError {}
            var direct = await diagnostics.events(named: .insertionFailed)
            // Fire-and-forget emission: wait for the second line to land.
            for _ in 0..<40 where direct.count < 2 {
                try await Task.sleep(for: .milliseconds(5))
                direct = await diagnostics.events(named: .insertionFailed)
            }
            XCTAssertEqual(direct.count, 2)
            XCTAssertEqual(direct.last?.attributes.site?.rawValue, "directClipboardCopy")
        }
    }

    func testTypedTierCancellationAfterFirstChunkReportsUncertainMutation() async throws {
        let ax = FakeAXClient(
            processIdentifier: 710,
            value: "",
            selectedRange: AXTextRange(location: 0, length: 0),
            selectedTextSettable: false,
            valueSettable: false,
            rangeSettable: false,
            role: "AXTextArea",
            subrole: nil
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 3)
        let firstChunkPosted = DispatchSemaphore(value: 0)
        let poster = FakeKeyPoster(signalAfterFirstChunk: firstChunkPosted)
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 710, bundle: "com.apple.Terminal")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard,
            keyPoster: poster,
            typedChunkPacing: .milliseconds(50)
        )
        let target = target(pid: 710, bundle: "com.apple.Terminal", name: "Terminal")

        let task = Task {
            try await service.insert(String(repeating: "b", count: 200), into: target, jobID: UUID())
        }
        XCTAssertEqual(firstChunkPosted.wait(timeout: .now() + 2), .success)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected an uncertain-mutation error")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .accessibilityVerifyFailed)
        }
        XCTAssertLessThan(poster.posted.count, 10, "typing must stop once cancelled")
        XCTAssertEqual(clipboard.writeCount, 0)
    }

    func testTypedTierRespectsBoundedLength() async throws {
        let ax = FakeAXClient(
            processIdentifier: 711,
            value: "",
            selectedRange: AXTextRange(location: 0, length: 0),
            selectedTextSettable: false,
            valueSettable: false,
            rangeSettable: false,
            role: "AXTextArea",
            subrole: nil
        )
        let clipboard = FakeClipboard(value: "sentinel", changeCount: 3)
        let poster = FakeKeyPoster()
        let service = AXTextInsertionService(
            workspace: FakeWorkspace.repeating(frontmost(pid: 711, bundle: "com.apple.Terminal")),
            axClient: ax,
            trust: FakeTrust(isTrusted: true),
            clipboard: clipboard,
            keyPoster: poster,
            typedChunkPacing: .zero
        )

        let outcome = try await service.insert(
            String(repeating: "z", count: AXInsertionLimits.maxUTF8Bytes + 1),
            into: target(pid: 711, bundle: "com.apple.Terminal", name: "Terminal"),
            jobID: UUID()
        )

        XCTAssertEqual(outcome, .copiedToClipboard(reason: .unsupportedValueType))
        XCTAssertTrue(poster.posted.isEmpty)
    }

    func testTypedTextSanitizerRules() {
        XCTAssertEqual(TypedTextSanitizer.sanitize("a\nb"), "a b")
        XCTAssertEqual(TypedTextSanitizer.sanitize("a\r\nb"), "a b")
        XCTAssertEqual(TypedTextSanitizer.sanitize("a\rb"), "a b")
        XCTAssertEqual(TypedTextSanitizer.sanitize("a\n\n\r\n\nb"), "a b")
        XCTAssertEqual(TypedTextSanitizer.sanitize("a\tb"), "a b")
        XCTAssertEqual(TypedTextSanitizer.sanitize("a\t\n\tb"), "a b")
        XCTAssertEqual(TypedTextSanitizer.sanitize("a\u{2028}b\u{2029}c\u{85}d"), "a b c d")
        XCTAssertEqual(TypedTextSanitizer.sanitize("a\u{1B}[31mb\u{03}c"), "a[31mbc")
        XCTAssertEqual(TypedTextSanitizer.sanitize("plain text, 你好 👋 café"), "plain text, 你好 👋 café")
        XCTAssertEqual(TypedTextSanitizer.sanitize(""), "")
        XCTAssertEqual(TypedTextSanitizer.sanitize("\n"), " ")
    }

    func testTypedTextChunkerRespectsLimitAndClusters() {
        let ascii = String(repeating: "x", count: 45)
        XCTAssertEqual(TypedTextChunker.chunks(of: ascii).map(\.count), [20, 20, 5])
        XCTAssertEqual(TypedTextChunker.chunks(of: ascii).joined(), ascii)

        // 19 ASCII units then an emoji (2 units) must not split the surrogate pair.
        let nearBoundary = String(repeating: "x", count: 19) + "👋" + "y"
        let chunks = TypedTextChunker.chunks(of: nearBoundary)
        XCTAssertEqual(chunks.joined(), nearBoundary)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 20 })
        XCTAssertEqual(chunks, [String(repeating: "x", count: 19), "👋y"])

        // A family emoji is one cluster; it travels in one event.
        let family = "👨‍👩‍👧‍👦"
        let mixed = String(repeating: "a", count: 15) + family
        let familyChunks = TypedTextChunker.chunks(of: mixed)
        XCTAssertEqual(familyChunks, [String(repeating: "a", count: 15), family])

        // An oversized single cluster is cut without splitting a surrogate pair.
        let oversized = "a" + String(repeating: "\u{0301}", count: 30) + "😀"
        let oversizedChunks = TypedTextChunker.chunks(of: oversized)
        XCTAssertEqual(oversizedChunks.joined(), oversized)
        XCTAssertTrue(oversizedChunks.allSatisfy { $0.utf16.count <= 20 && !$0.isEmpty })
        for chunk in oversizedChunks {
            XCTAssertFalse(UTF16.isLeadSurrogate(chunk.utf16.last!), "chunk ends on a high surrogate")
        }

        XCTAssertEqual(TypedTextChunker.chunks(of: ""), [])
    }

    func testTypedInsertionEligibilityAllowlist() {
        XCTAssertTrue(TypedInsertionEligibility.isEligible(role: "AXTextArea", subrole: nil))
        XCTAssertTrue(TypedInsertionEligibility.isEligible(role: "AXTextArea", subrole: "AXStandardTextArea"))
        XCTAssertTrue(TypedInsertionEligibility.isEligible(role: "AXTextField", subrole: nil))
        XCTAssertTrue(TypedInsertionEligibility.isEligible(role: "AXWebArea", subrole: nil))
        XCTAssertFalse(TypedInsertionEligibility.isEligible(role: "AXSecureTextField", subrole: nil))
        XCTAssertFalse(TypedInsertionEligibility.isEligible(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertFalse(TypedInsertionEligibility.isEligible(role: "AXScrollArea", subrole: nil))
        XCTAssertFalse(TypedInsertionEligibility.isEligible(role: "AXGroup", subrole: nil))
        XCTAssertFalse(TypedInsertionEligibility.isEligible(role: "AXTextArea", subrole: "AXUnknownSubrole"))
        XCTAssertFalse(TypedInsertionEligibility.isEligible(role: nil, subrole: nil))
        XCTAssertFalse(TypedInsertionEligibility.isEligible(role: "", subrole: nil))
    }

    func testInsertionMethodTypedCaseRoundTripsThroughCodable() throws {
        let outcome = InsertionOutcome.inserted(method: .typedKeyboardEvents)
        let data = try JSONEncoder().encode(outcome)
        XCTAssertEqual(try JSONDecoder().decode(InsertionOutcome.self, from: data), outcome)
        XCTAssertEqual(InsertionMethod.typedKeyboardEvents.rawValue, "typedKeyboardEvents")
        XCTAssertEqual(InsertionMethod(rawValue: "typedKeyboardEvents"), .typedKeyboardEvents)
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KvoiceInsertionTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // KvoiceInsertion
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository
            .appendingPathComponent("Tests/Fixtures/Insertion/textedit-insertion-cases.json")
    }

    private static var sourceDirectory: URL {
        fixtureURL
            .deletingLastPathComponent() // Insertion
            .deletingLastPathComponent() // Fixtures
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository
            .appendingPathComponent("Packages/KvoiceInsertion/Sources/KvoiceInsertion")
    }

    private func target(pid: pid_t, bundle: String, name: String) -> TargetApplicationSnapshot {
        Self.target(pid: pid, bundle: bundle, name: name)
    }

    private static func target(pid: pid_t, bundle: String, name: String) -> TargetApplicationSnapshot {
        TargetApplicationSnapshot(
            processIdentifier: pid,
            bundleIdentifier: bundle,
            localizedName: name,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func frontmost(pid: pid_t, bundle: String) -> FrontmostApplicationSnapshot {
        Self.frontmost(pid: pid, bundle: bundle)
    }

    private static func frontmost(pid: pid_t, bundle: String) -> FrontmostApplicationSnapshot {
        FrontmostApplicationSnapshot(
            processIdentifier: pid,
            bundleIdentifier: bundle,
            localizedName: bundle == "com.apple.TextEdit" ? "TextEdit" : "Other"
        )
    }
}

private struct FixtureSet: Decodable {
    let cases: [FixtureCase]
}

private struct FixtureCase: Decodable {
    let id: String
    let target: FixtureTarget
    let before: FixtureBefore
    let insertText: String
    let expected: FixtureExpected
    let clipboard: FixtureClipboard?
}

private struct FixtureTarget: Decodable {
    let processIdentifierAtCapture: pid_t
    let processIdentifierAtCompletion: pid_t
    let secure: Bool?
}

private struct FixtureBefore: Decodable {
    let value: String
    let selectedRangeUTF16: FixtureRange
}

private struct FixtureExpected: Decodable {
    let outcome: String
    let reason: String?
    let value: String?
    let selectedRangeUTF16: FixtureRange?
    let clipboardValue: String?

    var fallbackReason: ClipboardFallbackReason? {
        switch reason {
        case "targetChanged": return .targetApplicationChanged
        case "secureTarget": return .secureTarget
        default: return reason.flatMap(ClipboardFallbackReason.init(rawValue:))
        }
    }
}

private struct FixtureClipboard: Decodable {
    let before: String
    let beforeChangeCount: Int
}

private struct FixtureRange: Decodable {
    let location: Int
    let length: Int
}

private final class FakeTrust: AccessibilityTrustProviding, @unchecked Sendable {
    private let value: Bool

    init(isTrusted: Bool) {
        value = isTrusted
    }

    func isTrusted(prompt _: Bool) -> Bool {
        value
    }
}

private final class BlockingTrust: AccessibilityTrustProviding, @unchecked Sendable {
    private let result: Bool
    private let entered: DispatchSemaphore
    private let release: DispatchSemaphore

    init(result: Bool, entered: DispatchSemaphore, release: DispatchSemaphore) {
        self.result = result
        self.entered = entered
        self.release = release
    }

    func isTrusted(prompt _: Bool) -> Bool {
        entered.signal()
        release.wait()
        return result
    }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

private final class FakeWorkspace: FrontmostApplicationProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [FrontmostApplicationSnapshot?]

    init(sequence: [FrontmostApplicationSnapshot?]) {
        snapshots = sequence
    }

    func frontmostApplication() -> FrontmostApplicationSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard !snapshots.isEmpty else { return nil }
        if snapshots.count == 1 {
            return snapshots[0]
        }
        return snapshots.removeFirst()
    }

    static func repeating(_ snapshot: FrontmostApplicationSnapshot) -> FakeWorkspace {
        FakeWorkspace(sequence: [snapshot])
    }
}

private final class FakeClipboard: ClipboardWriting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value: String?
    private(set) var changeCount: Int
    private(set) var writeCount = 0
    private(set) var readCount = 0
    /// Thrown by every `write` when set (a pasteboard that refuses).
    private let writeFailure: Error?

    init(value: String?, changeCount: Int, writeFailure: Error? = nil) {
        self.value = value
        self.changeCount = changeCount
        self.writeFailure = writeFailure
    }

    func write(_ text: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let writeFailure { throw writeFailure }
        value = text
        changeCount += 1
        writeCount += 1
    }
}

private final class FakeAXClient: AXElementClient, @unchecked Sendable {
    private let lock = NSLock()
    private let handle = AXElementHandle(identifier: "fake-focused")
    private let processIdentifier: pid_t
    private let enabled: Bool
    private let secure: Bool
    private let selectedTextSettable: Bool
    private let valueSettable: Bool
    private let rangeSettable: Bool
    private var focusFailures: [AXClientError]
    private let blockedFocusDuration: Duration?
    private let focusStarted: DispatchSemaphore?
    private let blockedValueDuration: Duration?
    private let delayedSetDuration: Duration?
    private let rangeSetFailure: AXClientError?
    private let selectedTextSetFailure: AXClientError?
    private let secureMetadataOverride: AXSecureMetadata?
    /// When `role` is provided, both role and subrole come from the overrides
    /// (a nil subrole means the attribute is absent, as Terminal.app reports).
    private let roleOverride: String?
    private let subroleOverride: String?
    /// Non-nil models Chromium web content (the attribute exists, even empty).
    private let domIdentifier: String?
    private(set) var valueText: String
    private(set) var selectedRange: AXTextRange
    private(set) var setOperations: [AXAttribute] = []
    private(set) var focusedCallCount = 0

    init(
        processIdentifier: pid_t,
        value: String,
        selectedRange: AXTextRange,
        enabled: Bool = true,
        secure: Bool = false,
        selectedTextSettable: Bool = true,
        valueSettable: Bool = true,
        rangeSettable: Bool = true,
        focusFailures: [AXClientError] = [],
        blockedFocusDuration: Duration? = nil,
        focusStarted: DispatchSemaphore? = nil,
        blockedValueDuration: Duration? = nil,
        delayedSetDuration: Duration? = nil,
        rangeSetFailure: AXClientError? = nil,
        selectedTextSetFailure: AXClientError? = nil,
        secureMetadataOverride: AXSecureMetadata? = nil,
        role: String? = nil,
        subrole: String? = nil,
        domIdentifier: String? = nil
    ) {
        self.domIdentifier = domIdentifier
        self.processIdentifier = processIdentifier
        self.enabled = enabled
        self.secure = secure
        self.selectedTextSettable = selectedTextSettable
        self.valueSettable = valueSettable
        self.rangeSettable = rangeSettable
        self.focusFailures = focusFailures
        self.blockedFocusDuration = blockedFocusDuration
        self.focusStarted = focusStarted
        self.blockedValueDuration = blockedValueDuration
        self.delayedSetDuration = delayedSetDuration
        self.rangeSetFailure = rangeSetFailure
        self.selectedTextSetFailure = selectedTextSetFailure
        self.secureMetadataOverride = secureMetadataOverride
        roleOverride = role
        subroleOverride = subrole
        valueText = value
        self.selectedRange = selectedRange
    }

    func focusedElement() throws -> AXElementHandle? {
        focusStarted?.signal()
        if let blockedFocusDuration {
            Thread.sleep(forTimeInterval: blockedFocusDuration.timeInterval)
        }
        lock.lock()
        defer { lock.unlock() }
        focusedCallCount += 1
        if !focusFailures.isEmpty {
            throw focusFailures.removeFirst()
        }
        return handle
    }

    func processIdentifier(of _: AXElementHandle) throws -> pid_t {
        processIdentifier
    }

    func isEnabled(_: AXElementHandle) throws -> Bool {
        enabled
    }

    func isSecure(_: AXElementHandle) throws -> Bool {
        secure
    }

    func secureMetadata(_: AXElementHandle) throws -> AXSecureMetadata {
        secureMetadataOverride ?? (secure ? .secure : .notSecure)
    }

    func isAttributeSettable(
        _ attribute: AXAttribute,
        on _: AXElementHandle
    ) throws -> Bool {
        switch attribute {
        case .selectedText: return selectedTextSettable
        case .value: return valueSettable
        case .selectedTextRange: return rangeSettable
        default: return false
        }
    }

    func value(
        _ attribute: AXAttribute,
        of _: AXElementHandle
    ) throws -> AXAttributeValue? {
        if attribute == .selectedTextRange, let blockedValueDuration {
            Thread.sleep(forTimeInterval: blockedValueDuration.timeInterval)
        }
        lock.lock()
        defer { lock.unlock() }
        switch attribute {
        case .value: return .string(valueText)
        case .selectedTextRange: return .range(selectedRange)
        case .enabled: return .boolean(enabled)
        case .role:
            if let roleOverride { return .string(roleOverride) }
            return .string(secure ? "AXTextField" : "AXTextArea")
        case .subrole:
            if roleOverride != nil { return subroleOverride.map { .string($0) } }
            return .string(secure ? "AXSecureTextField" : "AXStandardTextField")
        case .selectedText: return nil
        case .domIdentifier: return domIdentifier.map { .string($0) }
        }
    }

    func set(
        _ value: AXAttributeValue,
        for attribute: AXAttribute,
        on _: AXElementHandle
    ) throws {
        lock.lock()
        setOperations.append(attribute)
        lock.unlock()

        if let delayedSetDuration {
            Thread.sleep(forTimeInterval: delayedSetDuration.timeInterval)
        }

        lock.lock()
        defer { lock.unlock() }
        if attribute == .selectedTextRange, let rangeSetFailure {
            throw rangeSetFailure
        }
        if attribute == .selectedText, let selectedTextSetFailure {
            throw selectedTextSetFailure
        }
        switch attribute {
        case .selectedText:
            guard case .string(let insertion) = value else { throw AXClientError.unsupportedValue }
            let result = try TextEditValueSplice.replacing(
                value: valueText,
                selectedRange: selectedRange,
                with: insertion
            )
            valueText = result.replacementValue
            selectedRange = result.caret
        case .value:
            guard case .string(let replacement) = value else { throw AXClientError.unsupportedValue }
            valueText = replacement
        case .selectedTextRange:
            guard case .range(let range) = value else { throw AXClientError.unsupportedValue }
            selectedRange = range
        default:
            throw AXClientError.unsupportedAttribute
        }
    }
}

/// Records every chunk the service asks to type, without touching the system.
private final class FakeKeyPoster: KeyboardEventPosting, @unchecked Sendable {
    struct Posted: Equatable {
        let chunk: String
        let pid: pid_t
    }

    private let lock = NSLock()
    private let failAtChunkIndex: Int?
    private let signalAfterFirstChunk: DispatchSemaphore?
    private var storage: [Posted] = []

    init(failAtChunkIndex: Int? = nil, signalAfterFirstChunk: DispatchSemaphore? = nil) {
        self.failAtChunkIndex = failAtChunkIndex
        self.signalAfterFirstChunk = signalAfterFirstChunk
    }

    var posted: [Posted] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func postUnicodeChunk(_ chunk: String, to processIdentifier: pid_t) throws {
        lock.lock()
        let index = storage.count
        if index == failAtChunkIndex {
            lock.unlock()
            throw TypedKeyboardEventError.eventCreationFailed
        }
        storage.append(Posted(chunk: chunk, pid: processIdentifier))
        lock.unlock()
        if index == 0 { signalAfterFirstChunk?.signal() }
    }
}

private actor RecordingDiagnostics: DiagnosticLogging {
    private var events: [DiagnosticEvent] = []

    func log(_ event: DiagnosticEvent) async {
        events.append(event)
    }

    func events(named name: DiagnosticEventName) async -> [DiagnosticEvent] {
        // Emission is fire-and-forget; yield so the logging task lands first.
        for _ in 0..<20 where !events.contains(where: { $0.name == name }) {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return events.filter { $0.name == name }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
