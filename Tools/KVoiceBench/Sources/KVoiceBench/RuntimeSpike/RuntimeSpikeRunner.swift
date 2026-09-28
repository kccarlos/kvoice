@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import KvoiceDomain
import KvoiceTranscription

public enum RuntimeSpikePhase: String, Codable, Sendable, Equatable {
    case warm
    case stability
}

public enum RuntimeSpikeQualityEvidence: String, Codable, Sendable, Equatable {
    case normalizedReferenceComparison
}

public struct RuntimeSpikeEnvironmentMetadata: Codable, Sendable, Equatable {
    public let osVersion: String
    public let hardwareModel: String
    public let physicalMemoryBytes: UInt64
    public let processArchitecture: String
    public let appCommit: String

    public init(
        osVersion: String,
        hardwareModel: String,
        physicalMemoryBytes: UInt64,
        processArchitecture: String,
        appCommit: String
    ) {
        self.osVersion = osVersion
        self.hardwareModel = hardwareModel
        self.physicalMemoryBytes = physicalMemoryBytes
        self.processArchitecture = processArchitecture
        self.appCommit = appCommit
    }

    public static func current(processInfo: ProcessInfo = .processInfo) -> Self {
        Self(
            osVersion: processInfo.operatingSystemVersionString,
            hardwareModel: sysctlString("hw.model") ?? "unknown",
            physicalMemoryBytes: processInfo.physicalMemory,
            processArchitecture: sysctlString("hw.machine") ?? "unknown",
            appCommit: processInfo.environment["KVOICE_APP_COMMIT"] ?? "unknown"
        )
    }
}

public struct RuntimeSpikeModelMetadata: Codable, Sendable, Equatable {
    public let modelID: String
    public let revision: String
    public let sourceSubdirectory: String
    public let manifestSHA256: String
    public let runtimeVersion: String

    public init(
        modelID: String,
        revision: String,
        sourceSubdirectory: String,
        manifestSHA256: String,
        runtimeVersion: String
    ) {
        self.modelID = modelID
        self.revision = revision
        self.sourceSubdirectory = sourceSubdirectory
        self.manifestSHA256 = manifestSHA256
        self.runtimeVersion = runtimeVersion
    }
}

public struct RuntimeSpikeComparisonMetadata: Codable, Sendable, Equatable {
    public let comparisonKey: String
    public let corpusID: String
    public let task: String
    public let languageHint: String?
    public let downloadDisabled: Bool
    public let prewarmDisabled: Bool
    public let stabilityJobCount: Int

    public init(
        comparisonKey: String,
        corpusID: String,
        task: String,
        languageHint: String?,
        downloadDisabled: Bool,
        prewarmDisabled: Bool,
        stabilityJobCount: Int
    ) {
        self.comparisonKey = comparisonKey
        self.corpusID = corpusID
        self.task = task
        self.languageHint = languageHint
        self.downloadDisabled = downloadDisabled
        self.prewarmDisabled = prewarmDisabled
        self.stabilityJobCount = stabilityJobCount
    }
}

public struct RuntimeSpikeLoadMeasurement: Codable, Sendable, Equatable {
    public let modelLoadMilliseconds: Double
    public let firstInferenceMilliseconds: Double?
    public let firstRequestToResultMilliseconds: Double?

    public init(
        modelLoadMilliseconds: Double,
        firstInferenceMilliseconds: Double?,
        firstRequestToResultMilliseconds: Double?
    ) {
        self.modelLoadMilliseconds = modelLoadMilliseconds
        self.firstInferenceMilliseconds = firstInferenceMilliseconds
        self.firstRequestToResultMilliseconds = firstRequestToResultMilliseconds
    }
}

public struct RuntimeSpikeMeasurement: Codable, Sendable, Equatable {
    public let runID: String
    public let iteration: Int
    public let phase: RuntimeSpikePhase
    public let isFirstInference: Bool
    public let clipID: String
    public let modelID: String
    public let audioDurationMilliseconds: Double
    public let requestToResultMilliseconds: Double
    public let inferenceMilliseconds: Double
    public let runtimeRealTimeFactor: Double?
    public let detectedLanguage: String?
    public let outputSHA256: String
    public let qualityEvidence: RuntimeSpikeQualityEvidence
    public let normalizedReferenceMatch: Bool
    public let protectedSpanCount: Int
    public let protectedSpanSmokePassed: Bool

    public init(
        runID: String,
        iteration: Int,
        phase: RuntimeSpikePhase,
        isFirstInference: Bool,
        clipID: String,
        modelID: String,
        audioDurationMilliseconds: Double,
        requestToResultMilliseconds: Double,
        inferenceMilliseconds: Double,
        runtimeRealTimeFactor: Double?,
        detectedLanguage: String?,
        outputSHA256: String,
        qualityEvidence: RuntimeSpikeQualityEvidence,
        normalizedReferenceMatch: Bool,
        protectedSpanCount: Int,
        protectedSpanSmokePassed: Bool
    ) {
        self.runID = runID
        self.iteration = iteration
        self.phase = phase
        self.isFirstInference = isFirstInference
        self.clipID = clipID
        self.modelID = modelID
        self.audioDurationMilliseconds = audioDurationMilliseconds
        self.requestToResultMilliseconds = requestToResultMilliseconds
        self.inferenceMilliseconds = inferenceMilliseconds
        self.runtimeRealTimeFactor = runtimeRealTimeFactor
        self.detectedLanguage = detectedLanguage
        self.outputSHA256 = outputSHA256
        self.qualityEvidence = qualityEvidence
        self.normalizedReferenceMatch = normalizedReferenceMatch
        self.protectedSpanCount = protectedSpanCount
        self.protectedSpanSmokePassed = protectedSpanSmokePassed
    }
}

public struct RuntimeSpikeRun: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let runID: String
    public let corpusID: String
    public let modelID: String
    public let model: RuntimeSpikeModelMetadata
    public let environment: RuntimeSpikeEnvironmentMetadata
    public let comparison: RuntimeSpikeComparisonMetadata
    public let load: RuntimeSpikeLoadMeasurement
    public let hashVerification: [RuntimeSpikeHashVerification]
    public let measurements: [RuntimeSpikeMeasurement]

    public init(
        schemaVersion: Int = 2,
        runID: String,
        corpusID: String,
        modelID: String,
        model: RuntimeSpikeModelMetadata,
        environment: RuntimeSpikeEnvironmentMetadata,
        comparison: RuntimeSpikeComparisonMetadata,
        load: RuntimeSpikeLoadMeasurement,
        hashVerification: [RuntimeSpikeHashVerification],
        measurements: [RuntimeSpikeMeasurement]
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.corpusID = corpusID
        self.modelID = modelID
        self.model = model
        self.environment = environment
        self.comparison = comparison
        self.load = load
        self.hashVerification = hashVerification
        self.measurements = measurements
    }
}

public struct RuntimeSpikeRunner: Sendable {
    public let manifest: UserRecordingCorpusManifest
    public let audioDirectory: URL

    public init(manifestURL: URL, audioDirectory: URL) throws {
        self.manifest = try UserRecordingCorpusManifest.load(from: manifestURL)
        self.audioDirectory = audioDirectory.standardizedFileURL
    }

    public func verifyCorpus() throws -> [RuntimeSpikeHashVerification] {
        try RuntimeSpikeCorpusVerifier(manifest: manifest, audioDirectory: audioDirectory).verifyHashes()
    }

    /// Runs the external corpus through the same production transcription actor
    /// used by the app. Audio files are read in place and never copied into the
    /// repository or benchmark output. The result stores only output hashes.
    public func run(
        engine: WhisperTranscriptionEngine,
        package: InstalledModelPackage,
        iterations: Int = 1,
        stabilityJobs: Int = 50,
        runID: String = UUID().uuidString.lowercased()
    ) async throws -> RuntimeSpikeRun {
        guard iterations > 0 else { throw RuntimeSpikeError.unsupportedIterationCount }
        guard stabilityJobs >= 0 else { throw RuntimeSpikeError.unsupportedStabilityJobCount }
        let verification = try verifyCorpus()
        let loadClock = ContinuousClock()
        let loadStart = loadClock.now
        try await engine.load(package)
        let modelLoadMilliseconds = loadStart.duration(to: loadClock.now).milliseconds
        let modelManifestSHA256 = try Self.manifestSHA256(package.manifest)
        let modelMetadata = RuntimeSpikeModelMetadata(
            modelID: package.manifest.modelID,
            revision: package.manifest.source.revision,
            sourceSubdirectory: package.manifest.source.subdirectory,
            manifestSHA256: modelManifestSHA256,
            runtimeVersion: "WhisperKit 1.1.0"
        )
        let environment = RuntimeSpikeEnvironmentMetadata.current()
        let comparison = RuntimeSpikeComparisonMetadata(
            comparisonKey: [
                manifest.corpusId,
                package.manifest.modelID,
                package.manifest.source.revision,
                modelManifestSHA256,
                "WhisperKit 1.1.0",
                "transcribe:nil"
            ].joined(separator: "|"),
            corpusID: manifest.corpusId,
            task: "transcribe",
            languageHint: nil,
            downloadDisabled: true,
            prewarmDisabled: true,
            stabilityJobCount: stabilityJobs
        )

        var measurements: [RuntimeSpikeMeasurement] = []
        measurements.reserveCapacity(manifest.clips.count * iterations + stabilityJobs)
        for iteration in 1...iterations {
            for clip in manifest.clips {
                measurements.append(
                    try await measure(
                        clip: clip,
                        engine: engine,
                        package: package,
                        runID: runID,
                        iteration: iteration,
                        phase: .warm,
                        isFirstInference: measurements.isEmpty
                    )
                )
            }
        }
        if stabilityJobs > 0 {
            for index in 0..<stabilityJobs {
                let clip = manifest.clips[index % manifest.clips.count]
                measurements.append(
                    try await measure(
                        clip: clip,
                        engine: engine,
                        package: package,
                        runID: runID,
                        iteration: index + 1,
                        phase: .stability,
                        isFirstInference: false
                    )
                )
            }
        }
        let firstMeasurement = measurements.first
        return RuntimeSpikeRun(
            runID: runID,
            corpusID: manifest.corpusId,
            modelID: package.manifest.modelID,
            model: modelMetadata,
            environment: environment,
            comparison: comparison,
            load: RuntimeSpikeLoadMeasurement(
                modelLoadMilliseconds: modelLoadMilliseconds,
                firstInferenceMilliseconds: firstMeasurement?.inferenceMilliseconds,
                firstRequestToResultMilliseconds: firstMeasurement?.requestToResultMilliseconds
            ),
            hashVerification: verification,
            measurements: measurements
        )
    }

    private func measure(
        clip: UserRecordingClip,
        engine: WhisperTranscriptionEngine,
        package: InstalledModelPackage,
        runID: String,
        iteration: Int,
        phase: RuntimeSpikePhase,
        isFirstInference: Bool
    ) async throws -> RuntimeSpikeMeasurement {
        let audio = try Self.loadAudio(from: audioDirectory.appendingPathComponent(clip.filename))
        let request = TranscriptionRequest(
            jobID: UUID(),
            audio: audio,
            languageHint: nil,
            task: .transcribe
        )
        let clock = ContinuousClock()
        let requestStart = clock.now
        let result = try await engine.transcribe(request) { _ in }
        let resultEnd = clock.now
        let requestDuration = requestStart.duration(to: resultEnd)
        let inferenceDuration = result.timings.inferenceStart.duration(to: result.timings.inferenceEnd)
        let outputHash = SHA256.hash(data: Data(result.text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let normalizedOutput = Self.normalizeForComparison(result.text)
        let normalizedReference = Self.normalizeForComparison(clip.reference.text)
        let protectedSpanSmokePassed = clip.protectedSpans.allSatisfy { span in
            normalizedOutput.contains(Self.normalizeForComparison(span))
        }
        return RuntimeSpikeMeasurement(
            runID: runID,
            iteration: iteration,
            phase: phase,
            isFirstInference: isFirstInference,
            clipID: clip.id,
            modelID: package.manifest.modelID,
            audioDurationMilliseconds: audio.duration.milliseconds,
            requestToResultMilliseconds: requestDuration.milliseconds,
            inferenceMilliseconds: inferenceDuration.milliseconds,
            runtimeRealTimeFactor: result.timings.runtimeReportedRealTimeFactor,
            detectedLanguage: result.detectedLanguage,
            outputSHA256: outputHash,
            qualityEvidence: .normalizedReferenceComparison,
            normalizedReferenceMatch: normalizedOutput == normalizedReference,
            protectedSpanCount: clip.protectedSpans.count,
            protectedSpanSmokePassed: protectedSpanSmokePassed
        )
    }

    private static func normalizeForComparison(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func manifestSHA256(_ manifest: ModelManifest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadAudio(from url: URL) throws -> AudioRecording {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw RuntimeSpikeError.invalidManifest("could not construct 16 kHz Float32 target format")
        }
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw RuntimeSpikeError.invalidManifest("could not allocate source audio buffer")
        }
        try file.read(into: sourceBuffer)

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: targetFormat,
                  frameCapacity: AVAudioFrameCount(
                      ceil(Double(sourceBuffer.frameLength) * 16_000 / sourceFormat.sampleRate) + 1024
                  )
              ) else {
            throw RuntimeSpikeError.invalidManifest("could not construct audio converter")
        }

        let inputState = AudioInputState(buffer: sourceBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            inputState.provide(inputStatus)
        }
        guard status != .error, conversionError == nil,
              let channel = outputBuffer.floatChannelData?[0] else {
            throw RuntimeSpikeError.invalidManifest(
                "audio conversion failed: \(conversionError?.localizedDescription ?? "unknown error")"
            )
        }

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
        let peak = samples.map { abs($0) }.max() ?? 0
        let peakDBFS = peak > 0 ? Float(20 * log10(Double(peak))) : -.infinity
        return AudioRecording(
            samples: ContiguousArray(samples),
            sampleRate: 16_000,
            channelCount: 1,
            duration: .seconds(Double(samples.count) / 16_000),
            peakLevelDBFS: peakDBFS,
            clippedFrameCount: samples.reduce(into: 0) { count, sample in
                if abs(sample) >= 1 { count += 1 }
            }
        )
    }
}

private final class AudioInputState: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var didSupplyBuffer = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func provide(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !didSupplyBuffer else {
            status.pointee = .endOfStream
            return nil
        }
        didSupplyBuffer = true
        status.pointee = .haveData
        return buffer
    }
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
        return nil
    }
    var value = [CChar](repeating: 0, count: size)
    let result = value.withUnsafeMutableBytes { buffer in
        sysctlbyname(name, buffer.baseAddress, &size, nil, 0)
    }
    guard result == 0 else { return nil }
    let bytes = value.map { UInt8(bitPattern: $0) }
    let decoded = String(decoding: bytes, as: UTF8.self)
    return decoded.split(separator: "\0", maxSplits: 1).first.map(String.init)
}

private extension Duration {
    var milliseconds: Double {
        let components = self.components
        return (Double(components.seconds) * 1_000) + (Double(components.attoseconds) / 1_000_000_000_000_000)
    }
}
