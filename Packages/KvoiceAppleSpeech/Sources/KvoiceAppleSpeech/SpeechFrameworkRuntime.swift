import AVFoundation
import Foundation
import KvoiceDomain
import Speech

/// The one place in kvoice that speaks to Apple's Speech framework
/// (ADR-025). Everything the framework returns is reduced to a domain value,
/// an `AppleSpeechResultEvent` or an `AppleSpeechError` before it leaves this
/// file, so no `Speech` type crosses a `KvoiceDomain` protocol (rule 1).
///
/// `SpeechAnalyzer` and `SpeechTranscriber` exist from macOS 26; kvoice's
/// deployment target is macOS 15, so every use sits behind
/// `#available(macOS 26, *)` and an older system reports
/// `.requiresNewerMacOS`. The framework is linked weakly for the same reason
/// (see `Package.swift`); its older `SFSpeechRecognizer` API is deliberately
/// not used (short-form, server-capable, needs a speech-recognition grant),
/// and neither is Siri (not an API).
///
/// SDK facts this file relies on (read from the macOS 27.0 SDK's
/// `Speech.swiftinterface` and `.swiftdoc`, and observed on an
/// Apple silicon Mac running macOS 27.0, 2026-09-16):
/// - `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:
///   attributeOptions:)`; `ReportingOption.volatileResults` and
///   `.fastResults` are what the `.progressiveTranscription` preset sets,
///   `.transcription` sets none. `SpeechTranscriber.isAvailable`,
///   `supportedLocales` (45 on 27.0), `installedLocales`,
///   `supportedLocale(equivalentTo:)` (not used — see
///   `AppleSpeechLocaleMapping`). Punctuation and capitalisation come from
///   the model with no option (observed on the bundled sample).
/// - `SpeechAnalyzer(modules:options:)`, `Options(priority:modelRetention:)`
///   with `.processLifetime` ("keeps the models in memory until this process
///   exits"), `prepareToAnalyze(in:)`, `start(inputSequence:)` (autonomous),
///   `finalizeAndFinishThroughEndOfInput()` (waits for the input sequence to
///   terminate, then finalizes and finishes; throws `CancellationError` if
///   finished early), `cancelAndFinishNow()`, `setContext(_:)`.
/// - `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` returns nil
///   when the modules need assets that are not installed; with assets it
///   returned **16 kHz mono Int16** for `en_US` and `zh_CN`. The analyzer
///   never resamples or converts ("to keep CMTime values sample-accurate").
/// - **`AnalyzerInput(buffer:)` traps (`EXC_BREAKPOINT` in
///   `AnalyzerInput.data(from:)`) on a Float32 `AVAudioPCMBuffer`,
///   interleaved or not; Int16 buffers are accepted.** kvoice's samples are
///   Float32, so every buffer is converted to the analyzer's format first —
///   `AnalyzerInputConverter` (macOS 27) or `AVAudioConverter` (macOS 26).
/// - `SpeechTranscriber.Result`: `text: AttributedString`, `range:
///   CMTimeRange`, `isFinal`. Volatile results for a range are re-sent as
///   the interpretation improves; a finalized result closes the range and
///   later results start at its end (52 volatile + 3 final over the 11.6 s
///   bundled sample paced in real time).
/// - `AnalysisContext.contextualStrings: [ContextualStringsTag: [String]]`
///   with the predefined `.general` tag; Apple's doc: keep phrases to one
///   or two words and **no more than 100 phrases across all tags** (the doc
///   names `DictationTranscriber`; `SpeechTranscriber` accepted the context
///   without error — whether it biases recognition is a human row).
/// - `AssetInventory`: `Status { unsupported, downloading, supported,
///   installed }` (`.supported` = "will need to be downloaded"; observed
///   `.supported` for `en_US` with the assets on the device but not yet
///   reserved by the app — "installed" is per app), `status(forModules:)`,
///   `assetInstallationRequest(supporting:)` (nil when installed; reserves
///   the locale itself; throws when that would exceed
///   `maximumReservedLocales`, 5 on a test Mac), `AssetInstallationRequest
///   .progress.fractionCompleted` (coarse steps: 0, 0.1, 0.51, 0.93, 1) and
///   `downloadAndInstall()` (returned in 7.5 s for `zh_CN`; instantly for
///   `en_US`), `reservedLocales`, `release(reservedLocale:)` ("the system
///   will remove the assets at a later time"). Assets persist across
///   launches and are shared between apps.
/// - `SFSpeechError.Code` (macOS 26 additions): `noModel`,
///   `assetLocaleNotAllocated`, `tooManyAssetLocalesAllocated`,
///   `cannotAllocateUnsupportedLocale`, `insufficientResources`,
///   `unexpectedAudioFormat`, `incompatibleAudioFormats`, `audioDisordered`,
///   `moduleOutputFailed`.
/// - No speech-recognition authorization is requested: `SpeechAnalyzer` ran
///   with `SFSpeechRecognizer.authorizationStatus() == .notDetermined`, and
///   `Info.plist` carries no `NSSpeechRecognitionUsageDescription`. The
///   microphone grant kvoice already holds is the only permission involved.
public struct SpeechFrameworkRuntime: AppleSpeechRuntime {
    public init() {}

    public func availability() async -> AppleSpeechAvailability {
        guard #available(macOS 26, *) else { return .requiresNewerMacOS }
        return SpeechTranscriber.isAvailable ? .available : .deviceNotEligible
    }

    public func supportedLocaleIdentifiers() async -> [String] {
        guard #available(macOS 26, *) else { return [] }
        return await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
    }

    public func assetStatus(localeIdentifier: String) async -> AppleSpeechAssetStatus {
        guard #available(macOS 26, *) else { return .unsupported }
        let transcriber = Self.makeTranscriber(localeIdentifier: localeIdentifier, progressive: false)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .unsupported: return .unsupported
        case .supported: return .supported
        case .downloading: return .downloading
        case .installed: return .installed
        @unknown default: return .unsupported
        }
    }

    public var maximumReservedLocales: Int {
        get async {
            guard #available(macOS 26, *) else { return 0 }
            return AssetInventory.maximumReservedLocales
        }
    }

    public func reservedLocaleIdentifiers() async -> [String] {
        guard #available(macOS 26, *) else { return [] }
        return await AssetInventory.reservedLocales.map(\.identifier).sorted()
    }

    public func installAssets(localeIdentifier: String, progress: @escaping @Sendable (Double) async -> Void) async throws {
        guard #available(macOS 26, *) else { throw AppleSpeechError.unavailable(.requiresNewerMacOS) }
        let transcriber = Self.makeTranscriber(localeIdentifier: localeIdentifier, progressive: false)
        let locale = Locale(identifier: localeIdentifier)
        // The request reserves the locale *before* it downloads, and a
        // reservation the download never filled would hold one of the
        // app's few slots with no card to release it from. Remember what
        // was reserved before, and give the slot back on any failure —
        // including a cancel — when it was ours to take.
        let reservedBefore = await AssetInventory.reservedLocales.map(\.identifier)
        let wasReserved = Self.isReserved(locale, in: reservedBefore)
        let limit = AssetInventory.maximumReservedLocales
        if !wasReserved, reservedBefore.count >= limit {
            // The typed refusal before the framework's own
            // `tooManyAssetLocalesAllocated` (mapped below as a second line).
            throw AppleSpeechError.tooManyReservedLocales(limit: limit)
        }
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                await progress(1)
                return
            }
            // `Progress` is KVO-observable, but a poll is enough for a card
            // and keeps this free of observer plumbing. The steps the
            // platform reports are coarse anyway.
            let monitor = Task {
                while !Task.isCancelled {
                    await progress(min(max(request.progress.fractionCompleted, 0), 1))
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { monitor.cancel() }
            try await request.downloadAndInstall()
            await progress(1)
        } catch {
            if !wasReserved {
                await AssetInventory.release(reservedLocale: locale)
            }
            throw Self.mapped(error, localeIdentifier: localeIdentifier, limit: limit)
        }
    }

    /// Whether `locale` is among the app's reservations. The platform
    /// "may return variants of the locales provided to `reserve`", so the
    /// comparison is by language and region, not by the exact identifier.
    static func isReserved(_ locale: Locale, in reservedIdentifiers: [String]) -> Bool {
        reservedIdentifiers.contains { identifier in
            let reserved = Locale(identifier: identifier)
            return reserved.language.languageCode == locale.language.languageCode
                && reserved.region == locale.region
        }
    }

    /// The analyzer formats this adapter hands audio to. Observed on macOS
    /// 27.0: `AnalyzerInput(buffer:)` traps on a Float32 buffer, so a
    /// platform answer that is not integer PCM is refused as
    /// `audioFormatRejected` rather than converted into a crash.
    static func isAcceptedAnalyzerFormat(_ format: AVAudioFormat) -> Bool {
        switch format.commonFormat {
        case .pcmFormatInt16, .pcmFormatInt32: return true
        default: return false
        }
    }

    @discardableResult
    public func releaseAssets(localeIdentifier: String) async -> Bool {
        guard #available(macOS 26, *) else { return false }
        return await AssetInventory.release(reservedLocale: Locale(identifier: localeIdentifier))
    }

    public func releaseRetainedModels() async {
        guard #available(macOS 26, *) else { return }
        await SpeechModels.endRetention()
    }

    public func makeSession(
        configuration: AppleSpeechSessionConfiguration,
        results: @escaping @Sendable (AppleSpeechResultEvent) async -> Void
    ) async throws -> any AppleSpeechSession {
        guard #available(macOS 26, *) else { throw AppleSpeechError.unavailable(.requiresNewerMacOS) }
        return try await SpeechFrameworkSession(configuration: configuration, results: results)
    }

    // MARK: Framework helpers

    @available(macOS 26, *)
    static func makeTranscriber(localeIdentifier: String, progressive: Bool) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: Locale(identifier: localeIdentifier),
            transcriptionOptions: [],
            // The `.progressiveTranscription` preset's options; the batch
            // pass wants finalized results only (the `.transcription` preset).
            reportingOptions: progressive ? [.volatileResults, .fastResults] : [],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Every framework error, reduced to a case. The `SFSpeechError` codes
    /// that name a cause map to it; anything else is "analysis failed". A
    /// `CancellationError` is never mapped — callers rethrow it as such.
    @available(macOS 26, *)
    static func mapped(_ error: any Error, localeIdentifier: String, limit: Int) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? AppleSpeechError { return error }
        guard let error = error as? SFSpeechError else { return AppleSpeechError.analysisFailed }
        return Self.mapped(code: error.code, localeIdentifier: localeIdentifier, limit: limit)
    }

    @available(macOS 26, *)
    static func mapped(code: SFSpeechError.Code, localeIdentifier: String, limit: Int) -> AppleSpeechError {
        switch code {
        case .noModel, .assetLocaleNotAllocated:
            return .assetsNotInstalled(localeIdentifier: localeIdentifier)
        case .tooManyAssetLocalesAllocated:
            return .tooManyReservedLocales(limit: limit)
        case .cannotAllocateUnsupportedLocale:
            return .unsupportedLanguage(code: nil)
        case .unexpectedAudioFormat, .incompatibleAudioFormats, .audioDisordered:
            return .audioFormatRejected
        case .insufficientResources:
            return .insufficientResources
        default:
            return .analysisFailed
        }
    }
}

// MARK: - Session

/// One analyzer over one transcriber, fed through an `AsyncStream` of
/// converted buffers. Results are reduced on the way out; the handler runs
/// on the results task, in order.
@available(macOS 26, *)
private actor SpeechFrameworkSession: AppleSpeechSession {
    private let localeIdentifier: String
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let converter: any AnalyzerInputConversion
    private let resultsTask: Task<Void, any Error>
    private var inputEnded = false
    private var finished = false

    init(
        configuration: AppleSpeechSessionConfiguration,
        results: @escaping @Sendable (AppleSpeechResultEvent) async -> Void
    ) async throws {
        localeIdentifier = configuration.localeIdentifier
        let transcriber = SpeechFrameworkRuntime.makeTranscriber(
            localeIdentifier: configuration.localeIdentifier,
            progressive: configuration.progressive
        )
        // Nil means the assets are not installed for this app — the engine
        // reports it as such rather than letting the analyzer fail later.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppleSpeechError.assetsNotInstalled(localeIdentifier: configuration.localeIdentifier)
        }
        guard SpeechFrameworkRuntime.isAcceptedAnalyzerFormat(analyzerFormat) else {
            throw AppleSpeechError.audioFormatRejected
        }
        converter = try Self.makeConverter(analyzerFormat: analyzerFormat)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        self.analyzer = analyzer
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = continuation
        // The results task must be running before any audio is analyzed;
        // it ends when the analyzer finishes (finalize or cancel).
        resultsTask = Task {
            for try await result in transcriber.results {
                await results(Self.reduce(result))
            }
        }
        do {
            if !configuration.contextualStrings.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings = [.general: configuration.contextualStrings]
                try await analyzer.setContext(context)
            }
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            try await analyzer.start(inputSequence: stream)
        } catch {
            continuation.finish()
            resultsTask.cancel()
            throw SpeechFrameworkRuntime.mapped(error, localeIdentifier: configuration.localeIdentifier, limit: AssetInventory.maximumReservedLocales)
        }
    }

    func append(samples: [Float]) async throws {
        guard !inputEnded, !samples.isEmpty else { return }
        for input in try converter.convert(samples) {
            self.input.yield(input)
        }
    }

    func finish() async throws {
        guard !finished else { return }
        finished = true
        do {
            if !inputEnded {
                inputEnded = true
                for input in try converter.flush() {
                    self.input.yield(input)
                }
                input.finish()
            }
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            // Every finalized result has been handed to the handler once the
            // results sequence ends.
            try await resultsTask.value
        } catch {
            // A finalize that failed leaves the results stream open; end it
            // so no handler call outlives this session.
            resultsTask.cancel()
            _ = try? await resultsTask.value
            throw SpeechFrameworkRuntime.mapped(error, localeIdentifier: localeIdentifier, limit: AssetInventory.maximumReservedLocales)
        }
    }

    func cancel() async {
        guard !finished else { return }
        finished = true
        inputEnded = true
        input.finish()
        resultsTask.cancel()
        await analyzer.cancelAndFinishNow()
        // Drain: the protocol promises no result reaches the handler after
        // this returns, and the results task may still be mid-delivery.
        _ = try? await resultsTask.value
    }

    private static func makeConverter(analyzerFormat: AVAudioFormat) throws -> any AnalyzerInputConversion {
        if #available(macOS 27, *) {
            return FrameworkInputConversion(analyzerFormat: analyzerFormat)
        }
        return try AVAudioConverterInputConversion(analyzerFormat: analyzerFormat)
    }

    private static func reduce(_ result: SpeechTranscriber.Result) -> AppleSpeechResultEvent {
        let text = String(result.text.characters)
        let start = CMTimeGetSeconds(result.range.start)
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
        return result.isFinal
            ? .finalized(text: text, start: start, end: end)
            : .volatile(text: text, start: start, end: end)
    }
}

// MARK: - Audio conversion

/// kvoice's samples (16 kHz mono Float32) → `AnalyzerInput`s in the format
/// the analyzer asked for. Two implementations because
/// `AnalyzerInputConverter` is macOS 27 only and the framework floor is 26.
@available(macOS 26, *)
private protocol AnalyzerInputConversion {
    func convert(_ samples: [Float]) throws -> [AnalyzerInput]
    func flush() throws -> [AnalyzerInput]
}

@available(macOS 26, *)
private enum SourceAudio {
    /// The format of every buffer kvoice hands the engine
    /// (`AudioSampleChunk` / `AudioRecording`: mono 16 kHz Float32).
    static let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)

    static func buffer(from samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else {
            throw AppleSpeechError.audioFormatRejected
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel[0].update(from: base, count: samples.count)
        }
        return buffer
    }
}

/// macOS 27: the framework's own converter, which also stamps no start
/// time (buffers are contiguous, as kvoice's are).
@available(macOS 27, *)
private final class FrameworkInputConversion: AnalyzerInputConversion {
    private let converter: AnalyzerInputConverter

    init(analyzerFormat: AVAudioFormat) {
        converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)
    }

    func convert(_ samples: [Float]) throws -> [AnalyzerInput] {
        try converter.convert(try SourceAudio.buffer(from: samples), at: nil)
    }

    func flush() throws -> [AnalyzerInput] {
        try converter.flush()
    }
}

/// macOS 26: `AVAudioConverter` from the source format to the analyzer's,
/// one buffer at a time. The sample rate matched on every observed format
/// (16 kHz both sides), so this is a sample-format change; the output
/// capacity still allows for a rate change so a different platform answer
/// does not truncate audio.
@available(macOS 26, *)
private final class AVAudioConverterInputConversion: AnalyzerInputConversion {
    private let converter: AVAudioConverter
    private let analyzerFormat: AVAudioFormat

    init(analyzerFormat: AVAudioFormat) throws {
        guard let source = SourceAudio.format,
              let converter = AVAudioConverter(from: source, to: analyzerFormat) else {
            throw AppleSpeechError.audioFormatRejected
        }
        self.converter = converter
        self.analyzerFormat = analyzerFormat
    }

    func convert(_ samples: [Float]) throws -> [AnalyzerInput] {
        let source = try SourceAudio.buffer(from: samples)
        let ratio = analyzerFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount((Double(source.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
            throw AppleSpeechError.audioFormatRejected
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return source
        }
        guard status != .error, conversionError == nil else {
            throw AppleSpeechError.audioFormatRejected
        }
        guard output.frameLength > 0 else { return [] }
        return [AnalyzerInput(buffer: output)]
    }

    func flush() throws -> [AnalyzerInput] {
        // No resampler state to drain when the rates match; a rate change
        // would leave at most a few primed frames, which the analyzer's
        // finalization tolerates.
        []
    }
}
