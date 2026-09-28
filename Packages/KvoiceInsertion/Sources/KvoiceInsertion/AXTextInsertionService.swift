import Foundation
import KvoiceDomain

/// Accessibility-backed text insertion with target affinity and an exact
/// clipboard fallback.  The service retains providers only; no AX element is
/// stored between calls or jobs.
///
/// Three tiers, tried in order (spec G.8 and ADR-016):
/// 1. `AXSelectedText` assignment when that attribute is settable.
/// 2. `AXValue` + `AXSelectedTextRange` splice, TextEdit only.
/// 3. Typed Unicode keyboard events addressed to the target process, only when
///    tiers 1 and 2 were *unavailable* (attributes not settable), the focused
///    element has an allowlisted text role, and the feature is enabled.  A tier
///    that failed mid-mutation never falls through to typing.
public final class AXTextInsertionService: TextInsertionService, SelectionReading, @unchecked Sendable {
    private let workspace: any FrontmostApplicationProviding
    private let trust: any AccessibilityTrustProviding
    private let axClient: any AXElementClient
    private let executor: SerialAXExecutor
    private let clipboardFallback: ClipboardFallback
    private let keyPoster: any KeyboardEventPosting
    private let typedChunkPacing: Duration
    /// One resolver for the service's life, built with the Electron/Chromium
    /// handshake polling from the developer defaults (ADR-022 slice 5:
    /// `axFocusRetryCount` / `axFocusRetryDelayMilliseconds`). It holds only
    /// providers, never an element.
    private let resolver: AXTargetResolver

    /// Settings-controlled switch for tier 3.  Read once per insertion, under
    /// the lock, so a toggle mid-insertion applies to the next job only.
    private let typedInsertionLock = NSLock()
    private var typedInsertionEnabled: Bool

    /// Optional scalar diagnostics. Insertion previously emitted nothing, so a
    /// clipboard fallback was indistinguishable from a successful insertion
    /// without attaching a debugger. Only the bounded reason and method are
    /// reported — never the transcript.
    private let diagnostics: (any DiagnosticLogging)?

    public init(
        workspace: any FrontmostApplicationProviding = SystemFrontmostApplicationProvider(),
        axClient: (any AXElementClient)? = nil,
        trust: any AccessibilityTrustProviding = SystemAccessibilityTrustProvider(),
        clipboard: any ClipboardWriting = SystemClipboardWriter(),
        timeout: Duration = .seconds(1),
        executor: SerialAXExecutor? = nil,
        diagnostics: (any DiagnosticLogging)? = nil,
        keyPoster: any KeyboardEventPosting = TypedKeyboardEventPoster(),
        typedInsertionEnabled: Bool = true,
        typedChunkPacing: Duration = .milliseconds(2),
        focusRetryCount: Int = 4,
        focusRetryDelay: Duration = .milliseconds(60),
        clock: any KvoiceClock = SystemKvoiceClock()
    ) {
        self.workspace = workspace
        self.trust = trust
        let axClient = axClient ?? NativeAXElementClient(timeout: timeout)
        self.axClient = axClient
        self.resolver = AXTargetResolver(
            workspace: workspace, axClient: axClient,
            focusRetryCount: focusRetryCount, focusRetryDelay: focusRetryDelay
        )
        // `clock` times the executor's per-operation timeout; tests inject
        // a clock they advance so a timeout never depends on machine speed.
        self.executor = executor ?? SerialAXExecutor(timeout: timeout, clock: clock)
        clipboardFallback = ClipboardFallback(writer: clipboard)
        self.diagnostics = diagnostics
        self.keyPoster = keyPoster
        self.typedInsertionEnabled = typedInsertionEnabled
        self.typedChunkPacing = typedChunkPacing
    }

    /// Enables or disables the ADR-016 typed tier.  Mirrors
    /// `AppSettings.typedInsertionEnabled`; the app shell calls this when the
    /// setting changes.  Safe to call from any thread.
    public func setTypedInsertionEnabled(_ enabled: Bool) {
        typedInsertionLock.lock()
        typedInsertionEnabled = enabled
        typedInsertionLock.unlock()
    }

    public var isTypedInsertionEnabled: Bool {
        typedInsertionLock.lock()
        defer { typedInsertionLock.unlock() }
        return typedInsertionEnabled
    }

    /// Fire-and-forget so diagnostics cannot delay or fail an insertion.
    private func emit(_ event: DiagnosticEvent) {
        guard let diagnostics else { return }
        Task { await diagnostics.log(event) }
    }

    public func captureTargetApplication() async -> TargetApplicationSnapshot? {
        guard let current = workspace.frontmostApplication() else { return nil }
        return TargetApplicationSnapshot(
            processIdentifier: current.processIdentifier,
            bundleIdentifier: current.bundleIdentifier,
            localizedName: current.localizedName,
            capturedAt: Date()
        )
    }

    public func copyToClipboard(_ text: String, jobID _: JobID) async throws {
        // This path is intentionally independent of Accessibility. It is used
        // when no target was captured, so resolving a fresh target here could
        // violate target affinity or mutate an unrelated application.
        try Task.checkCancellation()
        do {
            _ = try clipboardFallback.copy(text, reason: .noFrontmostApplication)
        } catch let error as KVoiceError {
            // ADR-022 item 9: the one line for a direct copy that failed.
            emit(
                DiagnosticEvent(
                    name: .insertionFailed,
                    result: .failure,
                    errorCode: error.code,
                    attributes: DiagnosticAttributes(reason: "clipboardWriteFailed", site: "directClipboardCopy")
                )
            )
            throw error
        }
    }

    // MARK: AI actions

    /// Reads `AXSelectedText` from the focused element of the frontmost
    /// application, for the Selection Action.
    ///
    /// Read-only: no attribute is written, no pasteboard is touched, and no
    /// element handle outlives the call. Returns `nil` — never throws — when
    /// Accessibility is not trusted, nothing is focused, the element is a
    /// secure field or its role is unknown, the selection is empty, or the
    /// value is too large to send. Secure fields are refused even though
    /// their selection is usually unreadable anyway, so a password can never
    /// become an AI request.
    public func readFocusedSelection() async -> String? {
        guard trust.isTrusted(prompt: false) else { return nil }
        let axClient = self.axClient
        let selection = try? await executor.runWithCannotCompleteRetry {
            guard let element = try axClient.focusedElement() else { return String?.none }
            switch try axClient.secureMetadata(element) {
            case .notSecure:
                break
            case .secure, .unavailable:
                return nil
            }
            guard case .string(let text)? = try axClient.value(.selectedText, of: element),
                  AXInsertionLimits.isBounded(text)
            else {
                return nil
            }
            return text
        }
        guard let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return selection
    }

    public func insert(
        _ text: String,
        into target: TargetApplicationSnapshot,
        jobID _: JobID
    ) async throws -> InsertionOutcome {
        let gate = AXOperationGate()
        return try await withTaskCancellationHandler(operation: {
            do {
                return try await self.performInsertion(text: text, target: target, gate: gate)
            } catch let error as KVoiceError {
                // ADR-022 item 9: the one line for every error this service
                // throws to the controller. The site travels in the error's
                // scalar metadata from wherever the throw happened, so the
                // log can name the exact gate without a second emission.
                self.emit(
                    DiagnosticEvent(
                        name: error.code == .accessibilityVerifyFailed ? .insertionUncertain : .insertionFailed,
                        result: .failure,
                        errorCode: error.code,
                        attributes: DiagnosticAttributes(
                            reason: error.metadata.reason?.rawValue ?? "unclassified",
                            site: error.metadata.site?.rawValue ?? "insert"
                        )
                    )
                )
                throw error
            }
        }, onCancel: {
            gate.invalidateForCancellation()
        })
    }

    private func performInsertion(
        text: String,
        target: TargetApplicationSnapshot,
        gate: AXOperationGate
    ) async throws -> InsertionOutcome {
        try Task.checkCancellation()

        guard AXInsertionLimits.isBounded(text) else {
            return try copyFallback(text, reason: .unsupportedValueType, gate: gate)
        }

        guard trust.isTrusted(prompt: false) else {
            // The fallback reason below is `.noFocusedElement`, which does not
            // distinguish "untrusted" from "nothing focused". Emit the trust
            // state separately so the log is unambiguous.
            emit(
                DiagnosticEvent(
                    name: .permissionAccessibilityStatus,
                    result: .failure,
                    attributes: DiagnosticAttributes(reason: "notTrusted")
                )
            )
            return try copyFallback(text, reason: .noFocusedElement, gate: gate)
        }

        do {
            let workspace = self.workspace
            let axClient = self.axClient
            let typedEnabled = isTypedInsertionEnabled
            let resolver = self.resolver
            let attempt = try await executor.runWithCannotCompleteRetry(gate: gate) {
                try Self.performAttempt(
                    text: text,
                    target: target,
                    workspace: workspace,
                    axClient: axClient,
                    gate: gate,
                    typedInsertionEnabled: typedEnabled,
                    resolver: resolver
                )
            }
            let method: InsertionMethod
            switch attempt {
            case .inserted(let axMethod):
                method = axMethod
            case .typedEligible:
                method = try await performTypedInsertion(text: text, target: target, gate: gate)
            }
            emit(
                DiagnosticEvent(
                    name: .insertionCompleted,
                    result: .success,
                    attributes: DiagnosticAttributes(strategy: method)
                )
            )
            return .inserted(method: method)
        } catch is CancellationError {
            if gate.isMutationStarted {
                throw Self.uncertainMutationError(site: "cancelledAfterMutation")
            }
            throw CancellationError()
        } catch AXExecutionError.timeout {
            if gate.isMutationStarted {
                throw Self.uncertainMutationError(site: "executorTimeoutAfterMutation")
            }
            return try copyFallback(text, reason: .timeout, gate: gate, site: "executorTimeout")
        } catch AXClientError.timeout {
            if gate.isMutationStarted {
                throw Self.uncertainMutationError(site: "clientTimeoutAfterMutation")
            }
            return try copyFallback(text, reason: .timeout, gate: gate, site: "clientTimeout")
        } catch let failure as InsertionAttemptFailure {
            return try copyFallback(
                text,
                reason: failure.reason,
                gate: gate,
                site: failure.site
            )
        } catch let error as KVoiceError {
            // Already carries its site (`uncertainMutationError(site:)` or a
            // clipboard write); `insert` logs it once on the way out.
            throw error
        } catch AXClientError.cannotComplete {
            if gate.isMutationStarted {
                throw Self.uncertainMutationError(site: "cannotCompleteAfterMutation")
            }
            return try copyFallback(text, reason: .setFailed, gate: gate, site: "cannotComplete")
        } catch {
            if gate.isMutationStarted {
                throw Self.uncertainMutationError(site: "errorAfterMutation")
            }
            return try copyFallback(text, reason: .setFailed, gate: gate, site: "unclassifiedError")
        }
    }

    /// Tier 3 (ADR-016).  Runs outside the bounded AX operation because pacing
    /// a long transcript can legitimately exceed the AX messaging timeout, and
    /// a timeout must never invalidate the gate halfway through typing.
    ///
    /// Immediately before the first event the target is re-resolved and
    /// re-validated on the AX queue, so focus that moved to a secure or
    /// non-text element during the first pass is caught.  The first event
    /// marks the gate as mutation-started: from then on cancellation, a poster
    /// failure, or gate invalidation stops typing and reports an uncertain
    /// mutation (`accessibilityVerifyFailed`), never a clipboard fallback —
    /// partial text is reported, not hidden.
    ///
    /// The pasteboard is never read, written, or cleared on this path.
    private func performTypedInsertion(
        text: String,
        target: TargetApplicationSnapshot,
        gate: AXOperationGate
    ) async throws -> InsertionMethod {
        try Task.checkCancellation()

        let workspace = self.workspace
        let axClient = self.axClient
        let resolver = self.resolver
        let processIdentifier = try await executor.runWithCannotCompleteRetry(gate: gate) {
            let validated = try Self.validateTarget(
                target: target,
                workspace: workspace,
                axClient: axClient,
                resolver: resolver
            )
            guard validated.typedEligible else {
                throw InsertionAttemptFailure(reason: .notEditable, site: "typedRecheck")
            }
            return target.processIdentifier
        }

        let chunks = TypedTextChunker.chunks(of: TypedTextSanitizer.sanitize(text))
        for (index, chunk) in chunks.enumerated() {
            if index > 0, typedChunkPacing > .zero {
                try await Task.sleep(for: typedChunkPacing)
            }
            guard gate.beginMutation() else {
                throw AXOperationGateError.invalidated
            }
            do {
                try keyPoster.postUnicodeChunk(chunk, to: processIdentifier)
            } catch {
                // The first event has been posted (or attempted): partial
                // text may be in the target, so this is uncertain, named
                // after the tier rather than the generic after-mutation site.
                throw Self.uncertainMutationError(site: "typedPoster")
            }
        }
        return .typedKeyboardEvents
    }

    private func copyFallback(
        _ text: String,
        reason: ClipboardFallbackReason,
        gate: AXOperationGate,
        site: String? = nil
    ) throws -> InsertionOutcome {
        try Task.checkCancellation()
        emit(
            DiagnosticEvent(
                name: .insertionClipboardFallback,
                result: .warning,
                attributes: DiagnosticAttributes(
                    reason: reason.rawValue,
                    // Several gates share one reason; this names the exact one.
                    site: site
                )
            )
        )
        do {
            return try gate.performFallback {
                try Task.checkCancellation()
                return try clipboardFallback.copy(text, reason: reason)
            }
        } catch AXOperationGateError.invalidated {
            throw CancellationError()
        } catch let error as KVoiceError {
            // The pasteboard refused the copy: the transcript is now only in
            // the controller's retained text. Name the gate that fell back
            // so the log shows both why AX was skipped and where the copy
            // failed.
            throw KVoiceError(
                code: error.code,
                retryable: error.retryable,
                metadata: DiagnosticAttributes(reason: "clipboardWriteFailed", site: site ?? "clipboardFallback")
            )
        }
    }

    /// The result of one bounded AX pass: either a completed AX insertion or
    /// the finding that neither AX tier is available and the element may be
    /// typed into.  No element handle leaves the pass.
    private enum AttemptResult: Sendable {
        case inserted(InsertionMethod)
        case typedEligible
    }

    private struct ValidatedTarget {
        let element: AXElementHandle
        let typedEligible: Bool
        /// The element lives in Chromium web content (`AXDOMIdentifier` is
        /// present). Web editors (contenteditable frameworks) accept an
        /// `AXSelectedText` write at the AX layer and then discard it, so the
        /// AX tiers cannot be verified there; the typed tier is the one that
        /// reaches them (the Claude desktop app, 2026-09-14).
        let isWebContent: Bool
    }

    /// Spec L.8 checks 1–6 plus the ADR-016 role allowlist.  Shared by the AX
    /// pass and the pre-typing re-check so both apply identical gates.
    private static func validateTarget(
        target: TargetApplicationSnapshot,
        workspace: any FrontmostApplicationProviding,
        axClient: any AXElementClient,
        resolver: AXTargetResolver
    ) throws -> ValidatedTarget {
        let element: AXElementHandle
        do {
            element = try resolver.resolveFocusedElement(for: target)
        } catch AXTargetResolutionError.noFrontmostApplication {
            throw InsertionAttemptFailure(reason: .noFrontmostApplication, site: "resolveFocused")
        } catch AXTargetResolutionError.targetChanged,
                AXTargetResolutionError.identityUnavailable {
            throw InsertionAttemptFailure(reason: .targetApplicationChanged, site: "resolveFocused")
        } catch AXTargetResolutionError.noFocusedElement {
            throw InsertionAttemptFailure(reason: .noFocusedElement, site: "resolveFocused")
        }

        do {
            let secureMetadata: AXSecureMetadata
            do {
                secureMetadata = try axClient.secureMetadata(element)
            } catch AXClientError.noValue,
                    AXClientError.unsupportedAttribute,
                    AXClientError.unsupportedValue {
                throw InsertionAttemptFailure(reason: .unsupportedValueType, site: "secureMetadataRead")
            }
            switch secureMetadata {
            case .secure:
                throw InsertionAttemptFailure(reason: .secureTarget, site: "secureField")
            case .unavailable:
                throw InsertionAttemptFailure(reason: .unsupportedValueType, site: "roleUnavailable")
            case .notSecure:
                break
            }
            guard try axClient.isEnabled(element) else {
                throw InsertionAttemptFailure(reason: .notEditable, site: "elementDisabled")
            }
        } catch let failure as InsertionAttemptFailure {
            throw failure
        } catch AXClientError.noValue {
            throw InsertionAttemptFailure(reason: .notEditable, site: "metadataNoValue")
        }

        guard resolver.currentTargetMatches(target) else {
            throw InsertionAttemptFailure(reason: .targetApplicationChanged, site: "afterMetadata")
        }

        return ValidatedTarget(
            element: element,
            typedEligible: try typedEligibility(of: element, using: axClient),
            isWebContent: isWebContent(element, using: axClient)
        )
    }

    /// True when Chromium reports a DOM identifier for the element — the
    /// attribute exists (even empty) on every web node and on nothing native.
    static func isWebContent(_ element: AXElementHandle, using axClient: any AXElementClient) -> Bool {
        do {
            return try axClient.value(.domIdentifier, of: element) != nil
        } catch {
            return false
        }
    }

    /// Reads role/subrole for the ADR-016 allowlist.  Missing metadata is not
    /// eligible; it is never an error here because the secure-metadata gate
    /// has already failed closed on anything ambiguous.
    private static func typedEligibility(
        of element: AXElementHandle,
        using axClient: any AXElementClient
    ) throws -> Bool {
        do {
            guard case .string(let role)? = try axClient.value(.role, of: element) else {
                return false
            }
            var subrole: String?
            if case .string(let value)? = try axClient.value(.subrole, of: element) {
                subrole = value
            }
            return TypedInsertionEligibility.isEligible(role: role, subrole: subrole)
        } catch AXClientError.noValue,
                AXClientError.unsupportedAttribute,
                AXClientError.unsupportedValue {
            return false
        }
    }

    private static func performAttempt(
        text: String,
        target: TargetApplicationSnapshot,
        workspace: any FrontmostApplicationProviding,
        axClient: any AXElementClient,
        gate: AXOperationGate,
        typedInsertionEnabled: Bool,
        resolver: AXTargetResolver
    ) throws -> AttemptResult {
        guard AXInsertionLimits.isBounded(text) else {
            throw InsertionAttemptFailure(reason: .unsupportedValueType, site: "textTooLarge")
        }

        let validated = try validateTarget(target: target, workspace: workspace, axClient: axClient, resolver: resolver)
        let element = validated.element

        // Decided up front so an unavailable AX tier can hand over to typing.
        // A tier that *failed* after starting a mutation throws before any
        // code path consults this value.
        let typedFallback: AttemptResult? =
            (typedInsertionEnabled && validated.typedEligible) ? .typedEligible : nil

        // Web editors: type. Chromium says AXSelectedText is settable, takes
        // the write, and the JavaScript editor drops it, which used to end as
        // an unverifiable mutation and a hard failure. With typing disabled
        // the AX tiers still run, so the user keeps a (worse) path.
        if validated.isWebContent, let typedFallback {
            return typedFallback
        }

        let selectedTextSettable = try attributeSettable(
            .selectedText,
            on: element,
            using: axClient
        )

        if selectedTextSettable {
            let originalRange: AXTextRange?
            do {
                originalRange = try optionalRange(
                    attribute: .selectedTextRange,
                    on: element,
                    using: axClient
                )
            } catch AXClientError.unsupportedAttribute,
                    AXClientError.noValue,
                    AXClientError.unsupportedValue {
                throw InsertionAttemptFailure(reason: .unsupportedValueType, site: "selectedRangeRead")
            }
            guard resolver.currentTargetMatches(target) else {
                throw InsertionAttemptFailure(reason: .targetApplicationChanged, site: "beforeSetSelectedText")
            }

            do {
                try set(
                    .string(text),
                    for: .selectedText,
                    on: element,
                    using: axClient,
                    gate: gate
                )
                if let originalRange {
                    try verifyCaret(
                        originalRange: originalRange,
                        insertedText: text,
                        on: element,
                        using: axClient
                    )
                }
                return .inserted(.selectedTextAttribute)
            } catch AXOperationGateError.invalidated {
                throw AXOperationGateError.invalidated
            } catch let error as KVoiceError {
                throw error
            } catch {
                // Once selected-text assignment was attempted its result is
                // uncertain.  It is unsafe to try a second mutation path or
                // to copy to the clipboard, which could duplicate text.
                throw Self.uncertainMutationError(site: "selectedTextSet")
            }
        }

        guard isTextEdit(target) else {
            if let typedFallback { return typedFallback }
            throw InsertionAttemptFailure(
                reason: .unsupportedValueType,
                site: typedInsertionEnabled ? "selectedTextNotSettable" : "typedInsertionDisabled"
            )
        }

        let valueSettable = try attributeSettable(.value, on: element, using: axClient)
        let rangeSettable = try attributeSettable(
            .selectedTextRange,
            on: element,
            using: axClient
        )
        guard valueSettable, rangeSettable else {
            if let typedFallback { return typedFallback }
            throw InsertionAttemptFailure(reason: .notEditable, site: "valueOrRangeNotSettable")
        }

        guard case .string(let currentValue)? = try axClient.value(.value, of: element),
              AXInsertionLimits.isBounded(currentValue),
              case .range(let selectedRange)? = try axClient.value(
                  .selectedTextRange,
                  of: element
              ),
              AXInsertionLimits.isBounded(selectedRange)
        else {
            throw InsertionAttemptFailure(reason: .unsupportedValueType, site: "valueOrRangeRead")
        }

        let splice: TextEditValueSplice.Result
        do {
            splice = try TextEditValueSplice.replacing(
                value: currentValue,
                selectedRange: selectedRange,
                with: text
            )
        } catch TextEditValueSplice.SpliceError.invalidRange,
                TextEditValueSplice.SpliceError.valueTooLarge,
                TextEditValueSplice.SpliceError.insertionTooLarge,
                TextEditValueSplice.SpliceError.rangeTooLarge,
                TextEditValueSplice.SpliceError.resultTooLarge {
            throw InsertionAttemptFailure(reason: .unsupportedValueType, site: "splice")
        }

        guard resolver.currentTargetMatches(target) else {
            throw InsertionAttemptFailure(reason: .targetApplicationChanged, site: "beforeSetValue")
        }
        do {
            try set(
                .string(splice.replacementValue),
                for: .value,
                on: element,
                using: axClient,
                gate: gate
            )
            try set(
                .range(splice.caret),
                for: .selectedTextRange,
                on: element,
                using: axClient,
                gate: gate
            )
            try verifySplice(
                expectedValue: splice.replacementValue,
                expectedCaret: splice.caret,
                on: element,
                using: axClient
            )
        } catch AXOperationGateError.invalidated {
            throw AXOperationGateError.invalidated
        } catch let error as KVoiceError {
            throw error
        } catch {
            // A successful value write followed by a failed caret write (or
            // failed verification) is a partial mutation.  Clipboard
            // fallback would paste the same text a second time.
            throw Self.uncertainMutationError(site: "valueSplice")
        }
        return .inserted(.textEditValueSplice)
    }

    private static func set(
        _ value: AXAttributeValue,
        for attribute: AXAttribute,
        on element: AXElementHandle,
        using axClient: any AXElementClient,
        gate: AXOperationGate
    ) throws {
        guard gate.beginMutation() else {
            throw AXOperationGateError.invalidated
        }
        try axClient.set(value, for: attribute, on: element)
    }

    private static func attributeSettable(
        _ attribute: AXAttribute,
        on element: AXElementHandle,
        using axClient: any AXElementClient
    ) throws -> Bool {
        do {
            return try axClient.isAttributeSettable(attribute, on: element)
        } catch AXClientError.unsupportedAttribute,
                AXClientError.noValue,
                AXClientError.unsupportedValue {
            return false
        }
    }

    private static func optionalRange(
        attribute: AXAttribute,
        on element: AXElementHandle,
        using axClient: any AXElementClient
    ) throws -> AXTextRange? {
        guard let value = try axClient.value(attribute, of: element) else { return nil }
        guard case .range(let range) = value else { throw AXClientError.unsupportedValue }
        guard AXInsertionLimits.isBounded(range) else {
            throw AXClientError.unsupportedValue
        }
        return range
    }

    private static func verifyCaret(
        originalRange: AXTextRange,
        insertedText: String,
        on element: AXElementHandle,
        using axClient: any AXElementClient
    ) throws {
        guard let value = try axClient.value(.selectedTextRange, of: element),
              case .range(let range) = value
        else {
            throw Self.uncertainMutationError(site: "verifyCaretRead")
        }
        guard AXInsertionLimits.isBounded(range) else {
            throw Self.uncertainMutationError(site: "verifyCaretBounds")
        }
        let expectedLocation = originalRange.location + (insertedText as NSString).length
        guard range == AXTextRange(location: expectedLocation, length: 0) else {
            throw Self.uncertainMutationError(site: "verifyCaret")
        }
    }

    private static func verifySplice(
        expectedValue: String,
        expectedCaret: AXTextRange,
        on element: AXElementHandle,
        using axClient: any AXElementClient
    ) throws {
        guard case .string(let value)? = try axClient.value(.value, of: element),
              AXInsertionLimits.isBounded(value),
              case .range(let range)? = try axClient.value(.selectedTextRange, of: element),
              AXInsertionLimits.isBounded(range),
              value == expectedValue,
              range == expectedCaret
        else {
            throw Self.uncertainMutationError(site: "verifySplice")
        }
    }

    /// The "a mutation started and could not be verified" error. `site`
    /// names the check or catch that decided so (ADR-022 item 9); it rides
    /// in the error's scalar metadata and becomes the one
    /// `insertion.uncertain` line `insert` logs.
    private static func uncertainMutationError(site: String) -> KVoiceError {
        KVoiceError(
            code: .accessibilityVerifyFailed,
            retryable: false,
            metadata: DiagnosticAttributes(reason: "mutationUnverified", site: site)
        )
    }

    private static func isTextEdit(_ target: TargetApplicationSnapshot) -> Bool {
        if target.bundleIdentifier == "com.apple.TextEdit" {
            return true
        }
        return target.localizedName?.caseInsensitiveCompare("TextEdit") == .orderedSame
    }
}

/// A failed insertion attempt.
///
/// `reason` is the domain-level fallback reason, but several distinct gates map
/// onto the same one — `unsupportedValueType` is thrown from seven places and
/// `notEditable` from three — which made a fallback impossible to localise from
/// the log alone. `site` carries a short label naming the exact gate; it is
/// diagnostic only and never affects behaviour.
private struct InsertionAttemptFailure: Error, Sendable, Equatable {
    let reason: ClipboardFallbackReason
    let site: String

    init(reason: ClipboardFallbackReason, site: String = "unspecified") {
        self.reason = reason
        self.site = site
    }
}
