import Foundation
import KvoiceDomain
import KvoiceModelManagement
import KvoiceTranscription
import KvoiceUI

/// The app owns the release trust material.  A package manifest read from a
/// user-selected folder is evidence only; it is never promoted to a trust
/// anchor by this loader.
public protocol AppTrustedModelReleaseLoading: Sendable {
    func load() throws -> WhisperModelReleaseTrustAnchor
}

public enum AppTrustedModelReleaseError: Error, Sendable, Equatable, LocalizedError {
    case manifestMissing
    case manifestUnreadable
    case digestMissing
    case digestInvalid
    case digestMismatch

    public var errorDescription: String? {
        switch self {
        case .manifestMissing:
            return "This app release does not contain a trusted model manifest."
        case .manifestUnreadable:
            return "The bundled trusted model manifest could not be decoded."
        case .digestMissing:
            return "This app release does not contain a trusted model manifest digest."
        case .digestInvalid:
            return "The bundled trusted model manifest digest is invalid."
        case .digestMismatch:
            return "The bundled trusted model manifest digest does not match its contents."
        }
    }
}

/// Loads the two app-owned trust artifacts without network access.  The
/// current lean checkout intentionally has no known-good production manifest,
/// so the default path fails closed and leaves model setup available for Skip
/// and recovery. Tests can inject deterministic manifest bytes and a digest.
public struct BundledTrustedModelReleaseLoader: AppTrustedModelReleaseLoading, @unchecked Sendable {
    private let bundle: Bundle?
    private let manifestData: Data?
    private let manifestSHA256: String?
    private let manifestResourceName: String
    private let digestResourceName: String

    public init(
        bundle: Bundle = .main,
        manifestResourceName: String = "ModelManifest",
        digestResourceName: String = "ModelManifest"
    ) {
        self.bundle = bundle
        self.manifestData = nil
        self.manifestSHA256 = nil
        self.manifestResourceName = manifestResourceName
        self.digestResourceName = digestResourceName
    }

    /// Deterministic injection seam for app-composition tests. The digest is
    /// still checked against canonical manifest bytes before it is accepted.
    public init(manifestData: Data, manifestSHA256: String) {
        self.bundle = nil
        self.manifestData = manifestData
        self.manifestSHA256 = manifestSHA256
        self.manifestResourceName = "ModelManifest"
        self.digestResourceName = "ModelManifest"
    }

    public func load() throws -> WhisperModelReleaseTrustAnchor {
        let data: Data
        let digest: String

        if let manifestData, let manifestSHA256 {
            data = manifestData
            digest = manifestSHA256
        } else {
            guard let bundle,
                  let manifestURL = bundle.url(
                      forResource: manifestResourceName,
                      withExtension: "json"
                  ) else {
                throw AppTrustedModelReleaseError.manifestMissing
            }
            do {
                data = try Data(contentsOf: manifestURL)
            } catch {
                throw AppTrustedModelReleaseError.manifestUnreadable
            }

            if let digestURL = bundle.url(
                forResource: digestResourceName,
                withExtension: "sha256"
            ) {
                do {
                    digest = try String(contentsOf: digestURL, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    throw AppTrustedModelReleaseError.digestMissing
                }
            } else if let infoDigest = bundle.object(
                forInfoDictionaryKey: "KvoiceTrustedModelManifestSHA256"
            ) as? String {
                digest = infoDigest.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                throw AppTrustedModelReleaseError.digestMissing
            }
        }

        guard digest.count == 64,
              digest.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57) ||
                      (scalar.value >= 97 && scalar.value <= 102)
              }) else {
            throw AppTrustedModelReleaseError.digestInvalid
        }

        let anchor: WhisperModelReleaseTrustAnchor
        do {
            anchor = try WhisperModelReleaseTrustAnchor(
                manifestData: data,
                manifestSHA256: digest
            )
        } catch {
            throw AppTrustedModelReleaseError.manifestUnreadable
        }

        guard try WhisperModelReleaseTrustAnchor.digest(for: anchor.manifest) == digest else {
            throw AppTrustedModelReleaseError.digestMismatch
        }
        return anchor
    }
}

/// Routes onboarding intents from the frozen KvoiceUI view model to the app
/// composition root. Keeping the callback in this tiny object avoids a
/// self-capture during AppComposition initialization and gives app tests a
/// deterministic intent observation point.
@MainActor
public final class AppOnboardingIntentRouter {
    public var handler: (@MainActor (OnboardingIntent) -> Void)?

    public init(handler: (@MainActor (OnboardingIntent) -> Void)? = nil) {
        self.handler = handler
    }

    public func send(_ intent: OnboardingIntent) {
        handler?(intent)
    }
}

/// Keeps the model library's inference reservation coupled to the exact
/// resident engine. Model mutation is therefore rejected while
/// transcription is active, even if a UI operation arrives concurrently.
/// ADR-017: the streaming path is forwarded to the engine; the reservation
/// covers only the batch pass, because the streaming session lives inside
/// the recording, during which the shell already refuses model mutation.
/// ADR-019: the engine underneath is the runtime-switching one, so the
/// same reservation covers Whisper and Parakeet alike.
public actor ResidentModelTranscriptionEngine: StreamingTranscriptionEngine, PromptTokenCounting {
    public let capabilities: TranscriptionCapabilities

    private let engine: RuntimeSwitchingTranscriptionEngine
    private let modelManager: SpeechModelLibrary?

    public init(
        engine: RuntimeSwitchingTranscriptionEngine,
        modelManager: SpeechModelLibrary?
    ) {
        self.engine = engine
        self.modelManager = modelManager
        self.capabilities = TranscriptionCapabilities(
            supportsBatch: true,
            supportsStreaming: true,
            supportsCancellation: true,
            supportedSampleRate: 16_000,
            supportedChannelCount: 1
        )
    }

    public var loadedModelID: ModelID? {
        get async { await engine.loadedModelID }
    }

    public func load(_ package: InstalledModelPackage) async throws {
        try await engine.load(package)
    }

    public func unload() async {
        await engine.unload()
    }

    // MARK: Runtime

    /// Forwarded rather than inherited from the protocol's no-op default, or
    /// the Runtime card's picker would silently do nothing.
    public func setComputeUnits(_ units: SpeechComputeUnits) async throws {
        try await engine.setComputeUnits(units)
    }

    public var runtimeStatistics: TranscriptionRuntimeStatistics {
        get async { await engine.runtimeStatistics }
    }

    // MARK: Dictionary (ADR-018)

    /// Forwarded, like the Runtime members, so the Dictionary counter sees
    /// the real tokenizer and cap instead of the protocol's "unsupported"
    /// default.
    public var promptTokenLimit: PromptTokenLimit? {
        get async { await engine.promptTokenLimit }
    }

    public func promptTokenCount(of text: String) async -> Int? {
        await engine.promptTokenCount(of: text)
    }

    /// `PromptTokenCounting` spelling of the engine property, for the
    /// Dictionary view model.
    public func promptTokenLimit() async -> PromptTokenLimit? {
        await engine.promptTokenLimit
    }

    public func beginStreaming(
        jobID: JobID,
        languageHint: String?,
        initialPrompt: String?,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws {
        try await engine.beginStreaming(
            jobID: jobID,
            languageHint: languageHint,
            initialPrompt: initialPrompt,
            events: events
        )
    }

    public func appendStreamingAudio(_ chunk: AudioSampleChunk, jobID: JobID) async {
        await engine.appendStreamingAudio(chunk, jobID: jobID)
    }

    public func endStreaming(jobID: JobID) async {
        await engine.endStreaming(jobID: jobID)
    }

    public func transcribe(
        _ request: TranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) async throws -> TranscriptionResult {
        if let modelManager {
            try await modelManager.beginInference(jobID: request.jobID)
        }

        do {
            let result = try await engine.transcribe(request, events: events)
            if let modelManager {
                await modelManager.endInference(jobID: request.jobID)
            }
            return result
        } catch {
            if let modelManager {
                await modelManager.endInference(jobID: request.jobID)
            }
            throw error
        }
    }
}
