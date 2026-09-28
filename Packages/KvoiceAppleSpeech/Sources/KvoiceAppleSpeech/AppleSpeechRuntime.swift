import Foundation
import KvoiceDomain

/// The narrow seam between `AppleSpeechTranscriptionEngine` /
/// `AppleSpeechModelAssets` and Apple's Speech framework (ADR-025).
/// `SpeechFrameworkRuntime` is the only implementation that touches the
/// framework — and the only file in kvoice that imports it
/// (`AppleSpeechBoundaryTests`) — so every other test runs the engine and
/// the assets adapter against `FakeAppleSpeechRuntime`. No framework type
/// appears here: locales travel as identifiers, results as text and
/// seconds, errors as `AppleSpeechError` cases.
public protocol AppleSpeechRuntime: Sendable {
    /// Whether the framework exists on this OS and reports the transcriber
    /// usable on this hardware. Cheap; read on every refresh.
    func availability() async -> AppleSpeechAvailability

    /// `SpeechTranscriber.supportedLocales` as identifiers (`en_US`,
    /// `zh_CN`, …), sorted. Locales the platform can transcribe into,
    /// installed or downloadable. Empty when unavailable.
    func supportedLocaleIdentifiers() async -> [String]

    /// `AssetInventory.status(forModules:)` for a transcriber in `locale`.
    func assetStatus(localeIdentifier: String) async -> AppleSpeechAssetStatus

    /// `AssetInventory.maximumReservedLocales` — how many locales this app
    /// may hold assets for (5 on a test Mac; varies with storage).
    var maximumReservedLocales: Int { get async }

    /// `AssetInventory.reservedLocales` as identifiers, sorted.
    func reservedLocaleIdentifiers() async -> [String]

    /// `AssetInventory.assetInstallationRequest(supporting:)` then
    /// `downloadAndInstall()`, reporting `Progress.fractionCompleted` (0…1)
    /// as it moves. Reserves the locale as a side effect (the framework
    /// does that itself). Returns when the platform's first attempt
    /// succeeded or failed; throws `AppleSpeechError` only.
    func installAssets(localeIdentifier: String, progress: @escaping @Sendable (Double) async -> Void) async throws

    /// `AssetInventory.release(reservedLocale:)`; `false` when the locale
    /// was not reserved (harmless).
    @discardableResult
    func releaseAssets(localeIdentifier: String) async -> Bool

    /// `SpeechModels.endRetention()`: releases the models the analyzers
    /// kept resident under `.processLifetime` retention. The engine's
    /// `unload` (memory pressure, a default-model switch) calls it so
    /// "Unload model now" frees memory for this runtime too.
    func releaseRetainedModels() async

    /// One `SpeechAnalyzer` + `SpeechTranscriber` pair in the locale, ready
    /// for audio. `progressive` selects volatile results (the streaming
    /// display); the batch pass uses finalized results only. Contextual
    /// strings are the dictionary terms (ADR-018 → `AnalysisContext`).
    /// Throws `AppleSpeechError` only.
    func makeSession(
        configuration: AppleSpeechSessionConfiguration,
        results: @escaping @Sendable (AppleSpeechResultEvent) async -> Void
    ) async throws -> any AppleSpeechSession
}

/// One analysis session: audio in, results out through the handler given
/// to `makeSession`. An actor because the real one owns an audio converter.
public protocol AppleSpeechSession: Actor {
    /// Appends 16 kHz mono Float32 samples; converts to the analyzer's
    /// format itself (the framework does not resample and takes only
    /// integer PCM on macOS 27.0 — see `SpeechFrameworkRuntime`).
    func append(samples: [Float]) async throws
    /// Ends the input, waits for the analyzer to finalize every result and
    /// for the handler to have seen them. Throws `AppleSpeechError`.
    func finish() async throws
    /// Drops the session without waiting; no result is delivered after
    /// this returns. Idempotent.
    func cancel() async
}

/// What the engine asks for when it opens a session.
public struct AppleSpeechSessionConfiguration: Sendable, Equatable {
    public let localeIdentifier: String
    /// Volatile results on (the streaming display) or off (the batch pass).
    public let progressive: Bool
    /// `AnalysisContext.contextualStrings[.general]`; already capped by the
    /// engine at `AppleSpeechTranscriptionEngine.contextualStringsLimit`.
    public let contextualStrings: [String]

    public init(localeIdentifier: String, progressive: Bool, contextualStrings: [String]) {
        self.localeIdentifier = localeIdentifier
        self.progressive = progressive
        self.contextualStrings = contextualStrings
    }
}

/// One `SpeechTranscriber.Result`, reduced to what the engine needs. A
/// volatile result for a range supersedes earlier volatile results for
/// that range; a finalized result closes the range and later results
/// start after it (observed on macOS 27.0, `AppleSpeechLiveTests`).
public enum AppleSpeechResultEvent: Sendable, Equatable {
    case volatile(text: String, start: Double, end: Double)
    case finalized(text: String, start: Double, end: Double)

    public var text: String {
        switch self {
        case .volatile(let text, _, _), .finalized(let text, _, _): return text
        }
    }
}

/// Whether the framework can transcribe on this Mac at all.
public enum AppleSpeechAvailability: Sendable, Equatable {
    case available
    /// The framework is absent: macOS older than 26.
    case requiresNewerMacOS
    /// `SpeechTranscriber.isAvailable == false`: the hardware cannot run it.
    case deviceNotEligible
}

/// `AssetInventory.Status`, as the domain reads it.
public enum AppleSpeechAssetStatus: Sendable, Equatable {
    /// The locale is not supported on this device.
    case unsupported
    /// Supported; the assets need downloading (or this app has not
    /// reserved the locale yet — the platform keys "installed" per app).
    case supported
    /// The platform is fetching the assets right now.
    case downloading
    /// Reserved by this app and on the device.
    case installed
}

/// What the framework can tell the engine, with every vendor detail already
/// removed (rule 3: nothing here can carry audio or a transcript).
public enum AppleSpeechError: Error, Equatable, Sendable {
    /// The framework cannot take a request on this Mac.
    case unavailable(AppleSpeechAvailability)
    /// The transcription language maps to no supported locale.
    case unsupportedLanguage(code: String?)
    /// The locale's assets are not installed for this app
    /// (`SFSpeechError.Code.noModel` / `.assetLocaleNotAllocated`, or a
    /// `bestAvailableAudioFormat` of nil).
    case assetsNotInstalled(localeIdentifier: String)
    /// `AssetInventory.maximumReservedLocales` would be exceeded
    /// (`.tooManyAssetLocalesAllocated`).
    case tooManyReservedLocales(limit: Int)
    /// The platform's download failed (it retries on its own later).
    case downloadFailed
    /// The audio could not be converted to the analyzer's format
    /// (`.unexpectedAudioFormat`, `.incompatibleAudioFormats`, or the
    /// converter refused).
    case audioFormatRejected
    /// The platform is out of analysis capacity (`.insufficientResources`).
    case insufficientResources
    /// Any other analysis failure (`.moduleOutputFailed`, an internal
    /// service error, …).
    case analysisFailed
}
