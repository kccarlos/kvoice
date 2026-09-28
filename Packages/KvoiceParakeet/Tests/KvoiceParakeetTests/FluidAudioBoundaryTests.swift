import Foundation
import KvoiceDomain
import KvoiceModelManagement
import KvoiceTranscription
import XCTest
@testable import KvoiceParakeet

/// ADR-019 rule 2 (allowed surface) and rule 3 (trust model), enforced by
/// scanning the source tree: FluidAudio is imported in exactly one file, that
/// file never spells a FluidAudio download entry point, and the version the
/// validator and the pinned-release table demand equals the `exact:` pin.
final class FluidAudioBoundaryTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KvoiceParakeetTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // KvoiceParakeet
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    private static func swiftFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    func testFluidAudioIsImportedInExactlyOneFile() throws {
        let importing = (Self.swiftFiles(under: Self.repositoryRoot.appendingPathComponent("Packages"))
            + Self.swiftFiles(under: Self.repositoryRoot.appendingPathComponent("Apps")))
            .filter { url in
                // The scan itself spells the import; tests are not adapters.
                guard !url.path.contains("/Tests/"),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return text.contains("import FluidAudio")
            }
            .map { $0.lastPathComponent }
        XCTAssertEqual(importing, ["FluidAudioParakeetRuntime.swift"])
    }

    func testTheAdapterNeverSpellsAFluidAudioDownloadEntryPoint() throws {
        let adapter = Self.repositoryRoot
            .appendingPathComponent("Packages/KvoiceParakeet/Sources/KvoiceParakeet/FluidAudioParakeetRuntime.swift")
        let text = try String(contentsOf: adapter, encoding: .utf8)
        // Strip comments: the doc comment names the forbidden helpers on purpose.
        let code = text.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        // The bare substring `download` covers every present and future
        // FluidAudio fetch helper at once (TDT's `downloadAndLoad`, the
        // Nemotron manager's `downloadVariant` / `downloadAndPreloadShared`,
        // `ModelHub.download`); the named spellings stay for a readable
        // failure message.
        // `SenseVoiceModels.load(from:` / `SenseVoiceManager.load(` are
        // forbidden for a different reason: the first pins the encoder's
        // compute units and would compile a stray `.mlpackage`, the second
        // goes through `downloadAndLoad`. The adapter builds the graphs
        // itself with `MLModel.load(contentsOf:)`. Paraformer's
        // `ParaformerModels.load(` pins the units and compiles a stray
        // `.mlpackage` the same way; `ParaformerManager` keeps `<unk>`,
        // truncates silently and hides the logits. Parakeet EOU's
        // `StreamingEouAsrManager` is driven through `loadModels(from:)`
        // only: its argument-less `loadModels()` and `loadModels(to:)` go
        // through `ModelHub.loadWithRecovery` (a download), and its
        // `injectSilence` is not used because kvoice pads the tail through
        // the same `appendAudio` path as the audio.
        for forbidden in [
            "AsrModels.load(", "downloadAndLoad", "loadFromCache", "loadWithAutoRecovery",
            ".download(", "ModelHub.loadModels", "ModelHub.download", "loadModels(to:", "loadWithRecovery",
            "downloadVariant", "downloadAndPreloadShared", "preloadShared", "download",
            "SenseVoiceModels.load(", "SenseVoiceManager.load(", "SenseVoiceManager(",
            "ParaformerModels.load(", "ParaformerManager.load(", "ParaformerManager(",
            ".loadModels()", "defaultCacheDirectory", "injectSilence"
        ] {
            XCTAssertFalse(code.contains(forbidden), "adapter must not use \(forbidden)")
        }
        XCTAssertTrue(code.contains("ModelHub.offlineMode = true"))
        XCTAssertTrue(code.contains("loadModels(from:") || code.contains("loadModels(from: folder)"))
    }

    func testTheRuntimeVersionEveryGateDemandsEqualsThePin() throws {
        let manifest = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let pin = "url: \"https://github.com/FluidInference/FluidAudio.git\", exact: \"\(ParakeetModelPackageValidator.runtimeVersion)\", traits: []"
        XCTAssertTrue(manifest.contains(pin), "Package.swift must pin FluidAudio exactly at \(ParakeetModelPackageValidator.runtimeVersion) with traits: []")
        XCTAssertEqual(KvoiceFluidAudioModels.runtimeVersion, ParakeetModelPackageValidator.runtimeVersion)
        XCTAssertEqual(KvoiceFluidAudioModels.runtimePackage, ParakeetModelPackageValidator.runtimePackage)
        XCTAssertEqual(KvoiceFluidAudioModels.format, ParakeetModelVariant.manifestFormat)
        for variant in ParakeetModelVariant.allCases {
            let release = PinnedModelReleases.all.first { $0.family == variant.rawValue }
            XCTAssertNotNil(release, "\(variant) needs a pinned release")
            XCTAssertEqual(release?.format, ParakeetModelVariant.manifestFormat)
            XCTAssertEqual(release?.tokenizerRelativeRoot, "model")
        }
    }

    func testThirdPartyNoticesNameParakeetAndFluidAudio() throws {
        let notices = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("THIRD_PARTY_NOTICES.md"),
            encoding: .utf8
        )
        XCTAssertTrue(notices.contains("FluidInference/FluidAudio"))
        XCTAssertTrue(notices.contains(ParakeetModelPackageValidator.runtimeVersion))
        XCTAssertTrue(notices.contains("Apache-2.0"))
        XCTAssertTrue(notices.contains("CC-BY-4.0"))
        XCTAssertTrue(notices.contains("Parakeet TDT"))
        XCTAssertTrue(notices.contains("Parakeet Unified"))
        XCTAssertTrue(notices.contains("NVIDIA"))
        // ADR-019 amendment (2026-09-16): the Nemotron weights are OpenMDW-1.1.
        XCTAssertTrue(notices.contains("Nemotron 3.5"))
        XCTAssertTrue(notices.contains("OpenMDW-1.1"))
        XCTAssertTrue(notices.contains("Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"))
        // ADR-019 amendment (2026-09-16, second model): SenseVoice's weights
        // are under Alibaba's FunASR model license, with the card as source.
        XCTAssertTrue(notices.contains("SenseVoice Small"))
        XCTAssertTrue(notices.contains("FunASR Model Open Source License 1.1"))
        XCTAssertTrue(notices.contains("FluidInference/sensevoice-small-coreml"))
        XCTAssertTrue(notices.contains("FunAudioLLM/SenseVoiceSmall"))
        // ADR-019 amendment (2026-09-16, third model): Paraformer-large's
        // upstream card names Apache-2.0; the FluidInference card is the
        // source of the "upstream license applies" claim.
        XCTAssertTrue(notices.contains("Paraformer-large"))
        XCTAssertTrue(notices.contains("FluidInference/paraformer-large-zh-coreml"))
        XCTAssertTrue(notices.contains("speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-pytorch"))
        // ADR-019 amendment (2026-09-16, fourth model): both cards name the
        // NVIDIA Open Model License; no SPDX id.
        XCTAssertTrue(notices.contains("Parakeet Realtime EOU"))
        XCTAssertTrue(notices.contains("NVIDIA Open Model License"))
        XCTAssertTrue(notices.contains("FluidInference/parakeet-realtime-eou-120m-coreml"))
        XCTAssertTrue(notices.contains("nvidia/parakeet_realtime_eou_120m-v1"))
    }
}
