import Foundation
import KvoiceDomain

/// What the app shell holds as "the insertion service": either edition's
/// implementation (ADR-026). `setTypedInsertionEnabled` mirrors
/// `AppSettings.typedInsertionEnabled`.
public protocol EditionTextInsertionService: TextInsertionService, SelectionReading {
    func setTypedInsertionEnabled(_ enabled: Bool)
}

extension AXTextInsertionService: EditionTextInsertionService {}

/// The App Store edition's insertion (ADR-026): the ADR-016 typed tier as the
/// only tier, with no Accessibility element anywhere.
///
/// A sandboxed app cannot resolve or write another app's focused element
/// (ADR-009), so the L.8 checks that read it — the focused element belongs
/// to the target, its role is a text role, it is not a secure field, it is
/// enabled — cannot run. What remains, in order:
///
/// 1. the text is within `AXInsertionLimits`;
/// 2. the PostEvent privilege is granted (`EventPostingAccessProviding`);
/// 3. the recording-start application is still frontmost, by PID *and*
///    bundle identifier (`NSWorkspace`, which the sandbox allows);
/// 4. Secure Event Input is off (`SecureEventInputProviding`) — the coarse
///    stand-in for the secure-field refusal.
///
/// Any of these failing before the first event is the documented clipboard
/// fallback, exactly as an unavailable AX tier is. Then the text is
/// sanitized and chunked as in ADR-016 (line breaks and tabs become one
/// space) and posted to the target PID, re-checking the frontmost
/// application before every chunk. The first event marks the gate as
/// mutation-started: from then on a changed target, a poster failure or
/// cancellation stops typing and reports `accessibilityVerifyFailed` — never
/// a clipboard copy, so partial text is never hidden (FR-AX-009 holds: the
/// pasteboard is untouched on success).
///
/// `readFocusedSelection` always returns nil: reading another app's
/// selection is Accessibility. The typed-insertion switch is ignored — here
/// typing *is* insertion, and the settings page holds the switch on.
public final class TypedTextInsertionService: EditionTextInsertionService, Sendable {
    private let workspace: any FrontmostApplicationProviding
    private let access: any EventPostingAccessProviding
    private let secureInput: any SecureEventInputProviding
    private let keyPoster: any KeyboardEventPosting
    private let clipboardFallback: ClipboardFallback
    private let typedChunkPacing: Duration
    private let diagnostics: (any DiagnosticLogging)?

    public init(
        workspace: any FrontmostApplicationProviding = SystemFrontmostApplicationProvider(),
        access: any EventPostingAccessProviding = SystemEventPostingAccess(),
        secureInput: any SecureEventInputProviding = SystemSecureEventInputProbe(),
        keyPoster: any KeyboardEventPosting = TypedKeyboardEventPoster(),
        clipboard: any ClipboardWriting = SystemClipboardWriter(),
        typedChunkPacing: Duration = .milliseconds(2),
        diagnostics: (any DiagnosticLogging)? = nil
    ) {
        self.workspace = workspace
        self.access = access
        self.secureInput = secureInput
        self.keyPoster = keyPoster
        clipboardFallback = ClipboardFallback(writer: clipboard)
        self.typedChunkPacing = typedChunkPacing
        self.diagnostics = diagnostics
    }

    /// Ignored in this edition (see the type's documentation).
    public func setTypedInsertionEnabled(_: Bool) {}

    public func readFocusedSelection() async -> String? {
        nil
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
        try Task.checkCancellation()
        do {
            _ = try clipboardFallback.copy(text, reason: .noFrontmostApplication)
        } catch let error as KVoiceError {
            emit(DiagnosticEvent(
                name: .insertionFailed,
                result: .failure,
                errorCode: error.code,
                attributes: DiagnosticAttributes(reason: "clipboardWriteFailed", site: "directClipboardCopy")
            ))
            throw error
        }
    }

    public func insert(
        _ text: String,
        into target: TargetApplicationSnapshot,
        jobID _: JobID
    ) async throws -> InsertionOutcome {
        let gate = AXOperationGate()
        return try await withTaskCancellationHandler(operation: {
            do {
                return try await self.performInsertion(text, into: target, gate: gate)
            } catch let error as KVoiceError {
                // ADR-022 item 9: the one line for every error this service
                // throws, including a clipboard write that failed inside the
                // fallback.
                self.emit(DiagnosticEvent(
                    name: error.code == .accessibilityVerifyFailed ? .insertionUncertain : .insertionFailed,
                    result: .failure,
                    errorCode: error.code,
                    attributes: DiagnosticAttributes(
                        reason: error.metadata.reason?.rawValue ?? "unclassified",
                        site: error.metadata.site?.rawValue ?? "typedInsert"
                    )
                ))
                throw error
            }
        }, onCancel: {
            gate.invalidateForCancellation()
        })
    }

    // MARK: Typing

    private func performInsertion(
        _ text: String,
        into target: TargetApplicationSnapshot,
        gate: AXOperationGate
    ) async throws -> InsertionOutcome {
        do {
            let method = try await type(text, into: target, gate: gate)
            emit(DiagnosticEvent(
                name: .insertionCompleted,
                result: .success,
                attributes: DiagnosticAttributes(strategy: method)
            ))
            return .inserted(method: method)
        } catch let fallback as Fallback {
            return try copyFallback(text, reason: fallback.reason, gate: gate, site: fallback.site)
        }
    }

    /// A reason to copy instead, found before any event was posted.
    private struct Fallback: Error {
        let reason: ClipboardFallbackReason
        let site: String
    }

    private func type(
        _ text: String,
        into target: TargetApplicationSnapshot,
        gate: AXOperationGate
    ) async throws -> InsertionMethod {
        try Task.checkCancellation()
        guard AXInsertionLimits.isBounded(text) else {
            throw Fallback(reason: .textTooLarge, site: "textTooLarge")
        }
        guard access.isGranted() else {
            // Its own reason (the "Accessibility permission is missing"
            // copy — macOS lists the grant there); the separate line says
            // which permission.
            emit(DiagnosticEvent(
                name: .permissionAccessibilityStatus,
                result: .failure,
                attributes: DiagnosticAttributes(reason: "postEventNotGranted")
            ))
            throw Fallback(reason: .permissionNotGranted, site: "postEventNotGranted")
        }
        try requireTargetFrontmost(target, mutationStarted: false)
        guard !secureInput.isSecureEventInputEnabled else {
            throw Fallback(reason: .secureTarget, site: "secureEventInput")
        }

        let chunks = TypedTextChunker.chunks(of: TypedTextSanitizer.sanitize(text))
        for (index, chunk) in chunks.enumerated() {
            if index > 0, typedChunkPacing > .zero {
                do {
                    try await Task.sleep(for: typedChunkPacing)
                } catch {
                    throw Self.uncertainMutationError(site: "cancelledAfterMutation")
                }
            }
            if index > 0 {
                try requireTargetFrontmost(target, mutationStarted: true)
                // Focus may have moved to a password field mid-typing.
                if secureInput.isSecureEventInputEnabled {
                    throw Self.uncertainMutationError(site: "secureEventInput")
                }
            }
            guard gate.beginMutation() else {
                if gate.isMutationStarted {
                    throw Self.uncertainMutationError(site: "cancelledAfterMutation")
                }
                throw CancellationError()
            }
            do {
                try keyPoster.postUnicodeChunk(chunk, to: target.processIdentifier)
            } catch {
                throw Self.uncertainMutationError(site: "typedPoster")
            }
        }
        return .typedKeyboardEvents
    }

    /// Target affinity without Accessibility: the frontmost application is
    /// the one captured at recording start, by PID and bundle identifier.
    /// Before the first event a mismatch is a clipboard fallback; after it,
    /// typing stops and the partial insertion is reported.
    private func requireTargetFrontmost(_ target: TargetApplicationSnapshot, mutationStarted: Bool) throws {
        guard let current = workspace.frontmostApplication() else {
            if mutationStarted { throw Self.uncertainMutationError(site: "typedTargetChanged") }
            throw Fallback(reason: .noFrontmostApplication, site: "noFrontmostApplication")
        }
        guard current.processIdentifier == target.processIdentifier,
              let expected = Self.nonEmpty(target.bundleIdentifier),
              let actual = Self.nonEmpty(current.bundleIdentifier),
              expected == actual
        else {
            if mutationStarted { throw Self.uncertainMutationError(site: "typedTargetChanged") }
            throw Fallback(reason: .targetApplicationChanged, site: "frontmostCheck")
        }
    }

    private func copyFallback(
        _ text: String,
        reason: ClipboardFallbackReason,
        gate: AXOperationGate,
        site: String
    ) throws -> InsertionOutcome {
        try Task.checkCancellation()
        emit(DiagnosticEvent(
            name: .insertionClipboardFallback,
            result: .warning,
            attributes: DiagnosticAttributes(reason: reason.rawValue, site: site)
        ))
        do {
            return try gate.performFallback {
                try Task.checkCancellation()
                return try clipboardFallback.copy(text, reason: reason)
            }
        } catch AXOperationGateError.invalidated {
            throw CancellationError()
        } catch let error as KVoiceError {
            throw KVoiceError(
                code: error.code,
                retryable: error.retryable,
                metadata: DiagnosticAttributes(reason: "clipboardWriteFailed", site: site)
            )
        }
    }

    private static func uncertainMutationError(site: String) -> KVoiceError {
        KVoiceError(
            code: .accessibilityVerifyFailed,
            retryable: false,
            metadata: DiagnosticAttributes(reason: "mutationUnverified", site: site)
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func emit(_ event: DiagnosticEvent) {
        guard let diagnostics else { return }
        Task { await diagnostics.log(event) }
    }
}
