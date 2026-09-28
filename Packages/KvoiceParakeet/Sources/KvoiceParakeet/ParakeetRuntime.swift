import Foundation
import KvoiceDomain

/// What the engine asks the runtime to build (ADR-019). The folder is the
/// verified package's `model/` — the flat folder FluidAudio expects, holding
/// the Core ML bundles and the vocabulary — and the runtime must read only
/// from it. There is deliberately no "download" or "cache" field: the runtime
/// is never allowed to fetch anything.
public struct ParakeetRuntimeConfiguration: Sendable, Equatable {
    public let variant: ParakeetModelVariant
    public let modelFolderURL: URL
    /// Domain compute-unit choice; the FluidAudio file maps it to Core ML's
    /// `MLComputeUnits` so that type never leaves the adapter (rule 1).
    public let computeUnits: SpeechComputeUnits

    public init(variant: ParakeetModelVariant, modelFolderURL: URL, computeUnits: SpeechComputeUnits) {
        self.variant = variant
        self.modelFolderURL = modelFolderURL.standardizedFileURL
        self.computeUnits = computeUnits
    }
}

/// One decoded token span, in seconds from the start of the audio. Runtime
/// types stop at this boundary.
public struct ParakeetTokenSpan: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// The output of one batch pass before it is normalised to the domain
/// `TranscriptionResult`.
public struct ParakeetTranscript: Sendable, Equatable {
    public let text: String
    /// Token spans when the runtime reports them (TDT and Unified both do);
    /// empty otherwise.
    public let tokens: [ParakeetTokenSpan]
    /// The runtime's own inference-time / audio-duration figure, when it
    /// reports one (TDT does).
    public let runtimeReportedRealTimeFactor: Double?
    /// The language the runtime itself reported, as a Whisper code, when
    /// the model emits one (Nemotron's leading language tag); nil otherwise
    /// and the engine falls back to `ParakeetModelVariant.reportedLanguage`.
    public let detectedLanguage: String?

    public init(
        text: String,
        tokens: [ParakeetTokenSpan] = [],
        runtimeReportedRealTimeFactor: Double? = nil,
        detectedLanguage: String? = nil
    ) {
        self.text = text
        self.tokens = tokens
        self.runtimeReportedRealTimeFactor = runtimeReportedRealTimeFactor
        self.detectedLanguage = detectedLanguage
    }
}

/// A loaded batch pipeline. Actor-isolated in production (FluidAudio's
/// managers are actors); the protocol only promises `Sendable` so a test fake
/// can be a plain final class with a lock.
public protocol ParakeetBatchDecoder: Sendable {
    /// `languageHint` is already filtered to a code the variant accepts, or
    /// nil for auto-detect.
    func transcribe(samples: [Float], languageHint: String?) async throws -> ParakeetTranscript
    func unload() async
    /// A streaming session over *this decoder's* resident graphs, for a
    /// model whose one pipeline serves both modes (Nemotron), or nil when
    /// streaming needs its own graph set from the runtime (Unified) or is
    /// not offered (TDT). The engine asks here first, then the runtime.
    /// `languageHint` is the variant's runtime hint, or nil for auto.
    func makeStreamingSession(languageHint: String?) async throws -> (any ParakeetStreamingSession)?
}

extension ParakeetBatchDecoder {
    public func makeStreamingSession(languageHint _: String?) async throws -> (any ParakeetStreamingSession)? { nil }
}

/// A live streaming session over the Unified streaming export or the
/// resident pipeline of Nemotron and Parakeet EOU. Audio is appended as it
/// is captured; `append` returns the text so far; `finish` flushes the
/// tail. The session is single-use.
public protocol ParakeetStreamingSession: Sendable {
    /// Appends 16 kHz mono samples and decodes every complete window they
    /// enable. Returns the transcript so far (committed text — the RNNT
    /// decoder does not revise it).
    func append(samples: [Float]) async throws -> String
    func finish() async throws -> String
    func unload() async
    /// Whether the model has signalled the end of an utterance since the
    /// session opened — Parakeet EOU's `<EOU>` token, debounced by the
    /// library over 1.28 s of silence. **The seam for the planned ADR-023
    /// opt-in and nothing else**: the engine forwards it as a scalar event
    /// and no caller acts on it, because FR-AUD-007 forbids ending a
    /// recording on silence. Every other model answers `false`.
    func endOfUtteranceDetected() async -> Bool
}

extension ParakeetStreamingSession {
    public func endOfUtteranceDetected() async -> Bool { false }
}

/// The FluidAudio-facing seam. Everything above it is unit-tested against a
/// fake; only `FluidAudioParakeetRuntime` implements it for real.
public protocol ParakeetRuntime: Sendable {
    /// Builds the batch pipeline from the verified folder. Must never touch
    /// the network or any other directory.
    func makeBatchDecoder(configuration: ParakeetRuntimeConfiguration) async throws -> any ParakeetBatchDecoder
    /// Opens a streaming session from the verified folder. Only variants
    /// with `supportsStreaming` whose batch decoder offered no session of
    /// its own are asked.
    func makeStreamingSession(configuration: ParakeetRuntimeConfiguration) async throws -> any ParakeetStreamingSession
}
