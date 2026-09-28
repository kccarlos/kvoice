import CoreML
import Foundation
import XCTest
@testable import KvoiceTranscription
import KvoiceDomain

/// The Runtime card's adapters: the bundled speech sample, the Mach/IOKit
/// telemetry provider, the Core ML placement reporter, and the compute-unit
/// mapping. Nothing here needs a model; `LiveRuntimeMeasurementTests` below
/// is the opt-in measurement that produced the RTF thresholds.
final class RuntimeAdapterTests: XCTestCase {
    // MARK: Performance sample

    func testBundledPerformanceSampleIsSixteenKilohertzMonoSpeechOfDictationLength() throws {
        let recording = try PerformanceSampleAudio.load()
        XCTAssertEqual(recording.sampleRate, 16_000)
        XCTAssertEqual(recording.channelCount, 1)
        XCTAssertTrue(recording.isEngineCompatible)
        XCTAssertGreaterThanOrEqual(recording.duration, PerformanceSampleAudio.minimumDuration)
        XCTAssertLessThan(recording.duration, .seconds(20), "keep the clip short; it ships in the app")
        // Speech, not silence or a tone: a synthesised voice peaks well above
        // the silence gate's −45 dBFS floor and never clips.
        XCTAssertGreaterThan(recording.peakLevelDBFS, -20)
        XCTAssertEqual(recording.clippedFrameCount, 0)
        let bytes = try Data(contentsOf: XCTUnwrap(PerformanceSampleAudio.resourceURL)).count
        XCTAssertLessThan(bytes, 400_000, "the sample must stay under 400 KB")
    }

    func testWaveReaderRefusesTheWrongFormatAndWalksPaddingChunks() throws {
        // 8 kHz stereo is refused with the offending figures.
        let stereo = makeWave(sampleRate: 8_000, channels: 2, frames: [0, 0])
        XCTAssertThrowsError(try PerformanceSampleAudio.decode(stereo)) { error in
            XCTAssertEqual(
                error as? PerformanceSampleAudio.LoadError,
                .unsupportedFormat(sampleRate: 8_000, channels: 2, bitsPerSample: 16)
            )
        }
        // A padding chunk before `data` (afconvert's FLLR) is skipped.
        let padded = makeWave(sampleRate: 16_000, channels: 1, frames: [16_384, -16_384, 0], padding: 7)
        let recording = try PerformanceSampleAudio.decode(padded)
        XCTAssertEqual(recording.samples.count, 3)
        XCTAssertEqual(recording.samples[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(recording.samples[1], -0.5, accuracy: 0.001)
        XCTAssertEqual(recording.peakLevelDBFS, -6.02, accuracy: 0.05)
        XCTAssertThrowsError(try PerformanceSampleAudio.decode(Data("not a wave".utf8)))
    }

    // MARK: Telemetry

    func testTelemetryProviderReadsThisProcess() {
        let provider = SystemRuntimeTelemetryProvider(processorCount: 4)
        let footprint = provider.memoryFootprintBytes()
        XCTAssertNotNil(footprint)
        XCTAssertGreaterThan(footprint ?? 0, 1_000_000, "a test process has more than a megabyte resident")

        XCTAssertNil(provider.cpuUtilisation(), "the first sample only primes the baseline")
        // Burn a little CPU so the second sample has something to measure.
        var accumulator = 0.0
        for index in 0..<200_000 { accumulator += sin(Double(index)) }
        XCTAssertNotEqual(accumulator, .infinity)
        let share = provider.cpuUtilisation()
        XCTAssertNotNil(share)
        XCTAssertGreaterThanOrEqual(share ?? -1, 0)
        XCTAssertLessThanOrEqual(share ?? 2, 1)

        // GPU may or may not be readable; when it is, it is a share.
        if let gpu = provider.gpuUtilisation() {
            XCTAssertGreaterThanOrEqual(gpu, 0)
            XCTAssertLessThanOrEqual(gpu, 1)
        }
    }

    // MARK: Placement

    func testPlacementReporterMapsEveryDeviceOnThisMachineAndUnitsToCoreML() {
        for device in MLComputeDevice.allComputeDevices {
            let kind = CoreMLModelPlacementReporter.kind(of: device)
            switch device {
            case .cpu: XCTAssertEqual(kind, .cpu)
            case .gpu: XCTAssertEqual(kind, .gpu)
            case .neuralEngine: XCTAssertEqual(kind, .neuralEngine)
            @unknown default: XCTFail("unmapped device \(device)")
            }
        }
        XCTAssertEqual(CoreMLModelPlacementReporter.mlComputeUnits(for: .neuralEngineAndCPU), .cpuAndNeuralEngine)
        XCTAssertEqual(CoreMLModelPlacementReporter.mlComputeUnits(for: .gpuAndCPU), .cpuAndGPU)
        XCTAssertEqual(CoreMLModelPlacementReporter.mlComputeUnits(for: .all), .all)
        XCTAssertEqual(CoreMLModelPlacementReporter.mlComputeUnits(for: .cpuOnly), .cpuOnly)
    }

    func testPlacementIsUnavailableWhenThePackageHasNoCompiledModels() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kvoice-placement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = InstalledModelPackage(
            manifest: Self.placeholderManifest,
            packageURL: root,
            modelFolderURL: root,
            tokenizerFolderURL: root,
            ownership: .managedByKvoice
        )

        let report = await CoreMLModelPlacementReporter().placement(for: package, computeUnits: .all)

        XCTAssertEqual(report.modelID, "placeholder")
        XCTAssertEqual(report.computeUnits, .all)
        XCTAssertNil(report.encoder)
        XCTAssertNil(report.decoder)
    }

    /// ADR-019: the graphs are found by manifest role, so a FluidAudio
    /// package's differently named bundles are planned too; a manifest
    /// without roles falls back to WhisperKit's names.
    func testPlacementFindsTheEncoderAndDecoderByManifestRole() {
        func descriptor(_ path: String, _ role: ModelArtifactRole) -> ModelFileDescriptor {
            ModelFileDescriptor(path: path, bytes: 1, sha256: String(repeating: "a", count: 64), role: role)
        }
        let parakeet = ModelManifest(
            schemaVersion: 1, modelID: "p", family: "parakeet-unified-en-0.6b", format: "fluidaudio-coreml", workingSpaceBytes: 1,
            source: ModelManifestSource(repository: "r", revision: "v", subdirectory: ""),
            runtimeCompatibility: ModelRuntimeCompatibility(swiftPackage: "f", exactVersion: "0"),
            tokenizer: ModelTokenizer(relativeRoot: "model"),
            files: [
                descriptor("model/vocab.json", .tokenizer),
                descriptor("model/parakeet_unified_encoder_int8.mlmodelc/weights/weight.bin", .audioEncoder),
                descriptor("model/parakeet_unified_encoder_streaming_70_13_13_int8.mlmodelc/weights/weight.bin", .otherRequired),
                descriptor("model/parakeet_unified_decoder.mlmodelc/weights/weight.bin", .textDecoder)
            ]
        )
        XCTAssertEqual(
            CoreMLModelPlacementReporter.compiledModelName(role: .audioEncoder, in: parakeet),
            "parakeet_unified_encoder_int8"
        )
        XCTAssertEqual(
            CoreMLModelPlacementReporter.compiledModelName(role: .textDecoder, in: parakeet),
            "parakeet_unified_decoder"
        )
        XCTAssertNil(CoreMLModelPlacementReporter.compiledModelName(role: .melSpectrogram, in: parakeet))
        XCTAssertNil(CoreMLModelPlacementReporter.compiledModelName(role: .audioEncoder, in: Self.placeholderManifest))
    }

    func testWhisperKitComputeOptionsFollowTheDomainChoice() {
        let neural = WhisperKitRuntimeFactory.computeOptions(for: .neuralEngineAndCPU)
        XCTAssertEqual(neural.audioEncoderCompute, .cpuAndNeuralEngine)
        XCTAssertEqual(neural.textDecoderCompute, .cpuAndNeuralEngine)
        XCTAssertEqual(neural.melCompute, .cpuAndGPU, "WhisperKit's default: the mel graph is not ANE-eligible")
        let gpu = WhisperKitRuntimeFactory.computeOptions(for: .gpuAndCPU)
        XCTAssertEqual(gpu.audioEncoderCompute, .cpuAndGPU)
        XCTAssertEqual(gpu.textDecoderCompute, .cpuAndGPU)
        let all = WhisperKitRuntimeFactory.computeOptions(for: .all)
        XCTAssertEqual(all.audioEncoderCompute, .all)
        let cpu = WhisperKitRuntimeFactory.computeOptions(for: .cpuOnly)
        XCTAssertEqual(cpu.melCompute, .cpuOnly)
        XCTAssertEqual(cpu.audioEncoderCompute, .cpuOnly)
        XCTAssertEqual(cpu.textDecoderCompute, .cpuOnly)
    }

    // MARK: Helpers

    static let placeholderManifest = ModelManifest(
        schemaVersion: 1,
        modelID: "placeholder",
        family: "whisper-large-v3-turbo",
        format: "whisperkit-coreml",
        workingSpaceBytes: 0,
        source: ModelManifestSource(repository: "none", revision: "none", subdirectory: "none"),
        runtimeCompatibility: ModelRuntimeCompatibility(
            swiftPackage: "argmaxinc/argmax-oss-swift/WhisperKit",
            exactVersion: "1.1.0"
        ),
        tokenizer: ModelTokenizer(relativeRoot: "tokenizer"),
        files: []
    )

    private func makeWave(sampleRate: UInt32, channels: UInt16, frames: [Int16], padding: Int = 0) -> Data {
        var body = Data()
        body.append(contentsOf: Array("WAVE".utf8))
        body.append(contentsOf: Array("fmt ".utf8))
        body.append(le(UInt32(16)))
        body.append(le(UInt16(1)))
        body.append(le(channels))
        body.append(le(sampleRate))
        body.append(le(sampleRate * UInt32(channels) * 2))
        body.append(le(UInt16(channels * 2)))
        body.append(le(UInt16(16)))
        if padding > 0 {
            body.append(contentsOf: Array("FLLR".utf8))
            body.append(le(UInt32(padding)))
            body.append(Data(repeating: 0, count: padding + padding % 2))
        }
        body.append(contentsOf: Array("data".utf8))
        body.append(le(UInt32(frames.count * 2)))
        for frame in frames { body.append(le(UInt16(bitPattern: frame))) }
        var data = Data("RIFF".utf8)
        data.append(le(UInt32(body.count)))
        data.append(body)
        return data
    }

    private func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

/// Opt-in measurement against the model installed on this Mac:
///
///     KVOICE_LIVE_RUNTIME_TESTS=1 ./Scripts/test.sh --filter LiveRuntimeMeasurementTests
///
/// Loads the default managed package under each compute-unit choice, reports
/// Core ML's placement, times the load, and transcribes the bundled sample
/// so the RTF thresholds in `RuntimeExpectation` (KvoiceUI) can be
/// re-measured on new hardware. Skips without the env var or the package.
/// It prints scalars only.
final class LiveRuntimeMeasurementTests: XCTestCase {
    func testMeasureEveryComputeUnitChoiceOnTheInstalledModel() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KVOICE_LIVE_RUNTIME_TESTS"] == "1",
            "opt-in: needs the installed model and a minute of wall time"
        )
        let modelsRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kvoice/Models", isDirectory: true)
        guard let package = Self.installedPackage(under: modelsRoot) else {
            throw XCTSkip("no installed package under \(modelsRoot.path)")
        }
        let manifestData = try Data(contentsOf: package.packageURL.appendingPathComponent("ModelManifest.json"))
        let anchor = try WhisperModelReleaseTrustAnchor(
            manifestData: manifestData,
            manifestSHA256: WhisperModelReleaseTrustAnchor.digest(for: package.manifest)
        )
        let engine = WhisperTranscriptionEngine(trustedReleases: [anchor])
        let sample = try PerformanceSampleAudio.load()
        let reporter = CoreMLModelPlacementReporter()
        let telemetry = SystemRuntimeTelemetryProvider()
        let units = ProcessInfo.processInfo.environment["KVOICE_LIVE_RUNTIME_UNITS"]
            .flatMap(SpeechComputeUnits.init(rawValue:))
            .map { [$0] } ?? SpeechComputeUnits.allCases

        print("[live-runtime] model \(package.manifest.modelID)")
        for choice in units {
            try await engine.setComputeUnits(choice)
            try await engine.load(package)
            let placement = await reporter.placement(for: package, computeUnits: choice)
            let load = await engine.runtimeStatistics.lastLoadDuration
            _ = telemetry.cpuUtilisation()
            // First pass warms Core ML; the second is the steady state a
            // user sees on the card.
            var factors: [Double] = []
            for _ in 0..<2 {
                let request = TranscriptionRequest(jobID: UUID(), audio: sample, languageHint: "en")
                let result = try await engine.transcribe(request, events: { _ in })
                let statistics = await engine.runtimeStatistics
                factors.append(statistics.lastRealTimeFactor ?? .nan)
                _ = result
            }
            let cpu = telemetry.cpuUtilisation().map { String(format: "%.0f %%", $0 * 100) } ?? "n/a"
            print(
                "[live-runtime] \(choice.rawValue): load \(load.map { "\($0)" } ?? "n/a"), "
                + "rtf first \(String(format: "%.3f", factors[0])) second \(String(format: "%.3f", factors[1])), "
                + "process cpu over the run \(cpu), "
                + "encoder \(placement.encoder?.summary ?? "unavailable"), "
                + "decoder \(placement.decoder?.summary ?? "unavailable"), "
                + "footprint \(telemetry.memoryFootprintBytes().map { "\($0 / 1_048_576) MiB" } ?? "n/a")"
            )
        }
        await engine.unload()
    }

    /// ADR-022 item 8: the first pass after a load versus the steady state,
    /// with and without the engine's warm-up. Same env var and package as
    /// the measurement above; Neural Engine + CPU only.
    ///
    ///     KVOICE_LIVE_RUNTIME_TESTS=1 ./Scripts/test.sh --filter testWarmUpRemovesTheFirstPassPenalty
    func testWarmUpRemovesTheFirstPassPenalty() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KVOICE_LIVE_RUNTIME_TESTS"] == "1",
            "opt-in: needs the installed model and a minute of wall time"
        )
        let modelsRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kvoice/Models", isDirectory: true)
        guard let package = Self.installedPackage(under: modelsRoot) else {
            throw XCTSkip("no installed package under \(modelsRoot.path)")
        }
        let manifestData = try Data(contentsOf: package.packageURL.appendingPathComponent("ModelManifest.json"))
        let anchor = try WhisperModelReleaseTrustAnchor(
            manifestData: manifestData,
            manifestSHA256: WhisperModelReleaseTrustAnchor.digest(for: package.manifest)
        )
        let sample = try PerformanceSampleAudio.load()
        let clock = ContinuousClock()
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let audioSeconds = seconds(sample.duration)

        // Without a warm-up: the raw runtime, first pass cold.
        let raw = try await WhisperKitRuntimeFactory().make(configuration: WhisperRuntimeConfiguration(
            modelFolderURL: package.modelFolderURL,
            tokenizerFolderURL: package.tokenizerFolderURL
        ))
        var cold: [Double] = []
        for _ in 0..<2 {
            let start = clock.now
            _ = try await raw.transcribe(samples: Array(sample.samples), languageHint: "en", promptTokens: nil)
            cold.append(seconds(clock.now - start) / audioSeconds)
        }
        await raw.unload()

        // With the engine's warm-up: first real pass after `load`.
        let engine = WhisperTranscriptionEngine(trustedReleases: [anchor])
        try await engine.load(package)
        let warmUp = await engine.runtimeStatistics.lastWarmUpDuration
        var warmed: [Double] = []
        for _ in 0..<2 {
            let request = TranscriptionRequest(jobID: UUID(), audio: sample, languageHint: "en")
            _ = try await engine.transcribe(request, events: { _ in })
            warmed.append(await engine.runtimeStatistics.lastRealTimeFactor ?? .nan)
        }
        await engine.unload()
        print(
            "[live-warmup] whisper \(package.manifest.modelID): without warm-up rtf first "
            + "\(String(format: "%.3f", cold[0])) second \(String(format: "%.3f", cold[1])); "
            + "warm-up \(warmUp.map { "\($0)" } ?? "n/a"), with warm-up rtf first "
            + "\(String(format: "%.3f", warmed[0])) second \(String(format: "%.3f", warmed[1]))"
        )
    }

    private static func installedPackage(under root: URL) -> InstalledModelPackage? {
        let fileManager = FileManager.default
        guard let models = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }
        for model in models.sorted(by: { $0.path < $1.path }) {
            guard let revisions = try? fileManager.contentsOfDirectory(at: model, includingPropertiesForKeys: nil) else {
                continue
            }
            for revision in revisions {
                let manifestURL = revision.appendingPathComponent("ModelManifest.json")
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data) else { continue }
                return InstalledModelPackage(
                    manifest: manifest,
                    packageURL: revision,
                    modelFolderURL: revision.appendingPathComponent("model", isDirectory: true),
                    tokenizerFolderURL: revision.appendingPathComponent("tokenizer", isDirectory: true),
                    ownership: .managedByKvoice
                )
            }
        }
        return nil
    }
}
