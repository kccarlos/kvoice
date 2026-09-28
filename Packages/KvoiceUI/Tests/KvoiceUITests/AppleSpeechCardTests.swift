import XCTest
import KvoiceAppCore
@testable import KvoiceDomain
@testable import KvoiceUI

/// ADR-025: what the Models section, the Dictionary section and the
/// Runtime card show for a system-managed model (Apple Speech).
@MainActor
final class AppleSpeechCardTests: XCTestCase {
    private let whisper = SpeechModelCatalogEntry(
        id: "standard", displayName: "Whisper v3 Turbo", variantName: "Standard",
        family: "whisper-large-v3-turbo", runtime: .whisperKitCoreML, hosting: .onDevice,
        supportsStreaming: true, supportsBatch: true, downloadBytes: 650_000_000,
        languageSummary: "99 languages", summary: "Default.", isRecommended: true,
        revision: "rev", manifestResource: "standard", manifestSHA256: String(repeating: "a", count: 64),
        promptTokenLimit: 224, punctuation: true
    )
    private let appleSpeech = SpeechModelCatalogEntry(
        id: "apple-speech", displayName: "Apple Speech", variantName: "on-device",
        family: "apple-speech", runtime: .appleSpeech, hosting: .onDevice,
        supportsStreaming: true, supportsBatch: true, downloadBytes: 0,
        languageCodes: ["en", "zh"], languageSummary: "2 languages on this Mac", summary: "Apple's model.",
        isRecommended: false, revision: "system", manifestResource: "", manifestSHA256: "",
        punctuation: true, assetSource: .systemManaged
    )
    private let systemSummary = InstalledModelSummary(modelID: "apple-speech", revision: "system", ownership: .systemManaged)

    private func snapshot(_ state: ModelLifecycleState?, defaultID: ModelID = "standard", resident: ModelID? = nil) -> SpeechModelsSnapshot {
        var states: [ModelID: ModelLifecycleState] = ["standard": .ready(InstalledModelSummary(modelID: "standard", revision: "rev", ownership: .managedByKvoice))]
        states["apple-speech"] = state
        return SpeechModelsSnapshot(
            catalog: SpeechModelCatalog(entries: [whisper, appleSpeech]),
            states: states,
            defaultModelID: defaultID,
            residentModelID: resident
        )
    }

    // MARK: Models section

    func testTheCardShowsTheFourAxesWithASystemManagedSizeAndAnInstallButton() throws {
        let model = SpeechModelsViewModel(snapshot: snapshot(.absent))
        let card = try XCTUnwrap(model.cards.first { $0.id == "apple-speech" })
        XCTAssertEqual(card.badges, ["On-Device", "Streaming or Batch", "Punctuation and capitalization", "System-managed"])
        XCTAssertEqual(card.entry.languageSummary, "2 languages on this Mac")
        XCTAssertEqual(card.statusDescription, "Not installed")
        XCTAssertEqual(card.actions, [.download])
        XCTAssertEqual(card.title(for: .download), "Install", "the OS installs; KVoice downloads nothing")
        XCTAssertEqual(card.title(for: .delete), "Delete")
        XCTAssertTrue(model.isEnabled(.download, for: card))
        // The Whisper card is unchanged.
        let whisperCard = try XCTUnwrap(model.cards.first { $0.id == "standard" })
        XCTAssertEqual(whisperCard.title(for: .download), "Download")
        XCTAssertEqual(whisperCard.badges.last, ModelSettingsViewModel.formatBytes(650_000_000))
    }

    func testDownloadingShowsAPercentNotBytesAndInstalledOffersUseAndDelete() throws {
        var model = SpeechModelsViewModel(snapshot: snapshot(.downloading(completed: 51, total: 100)))
        var card = try XCTUnwrap(model.cards.first { $0.id == "apple-speech" })
        XCTAssertEqual(card.statusDescription, "Downloading — 51 %")
        XCTAssertEqual(card.progress, 0.51)
        XCTAssertEqual(card.actions, [.cancel])

        model = SpeechModelsViewModel(snapshot: snapshot(.ready(systemSummary)))
        card = try XCTUnwrap(model.cards.first { $0.id == "apple-speech" })
        XCTAssertEqual(card.statusDescription, "Installed")
        XCTAssertEqual(card.actions, [.use, .delete])
        XCTAssertTrue(card.isInstalled)

        model = SpeechModelsViewModel(snapshot: snapshot(.ready(systemSummary), defaultID: "apple-speech", resident: "apple-speech"))
        card = try XCTUnwrap(model.cards.first { $0.id == "apple-speech" })
        XCTAssertEqual(card.statusDescription, "Default · Ready")
        XCTAssertEqual(card.actions, [.delete])
        XCTAssertEqual(model.languageOptions.map(\.code), ["zh", "en"], "the picker lists the observed coverage, in Whisper name order (Chinese, English)")
        model.host.send(.setTranscriptionLanguage("fr", origin: .page(.models)))
        XCTAssertEqual(model.languageOptions.map(\.code), ["zh", "en", "fr"], "the selected code stays listed while the warning explains")
        XCTAssertEqual(
            model.languageCoverageWarning,
            "Apple Speech — on-device does not support French (2 languages on this Mac). Choose Auto-detect or a covered language, or use a Whisper model for French."
        )
    }

    func testAnUnavailableModelShowsTheReasonWithInstallDisabled() throws {
        let failure = SystemManagedUnavailableReason.requiresNewerMacOS.modelFailure
        let model = SpeechModelsViewModel(snapshot: snapshot(.unavailable(failure)))
        let card = try XCTUnwrap(model.cards.first { $0.id == "apple-speech" })
        XCTAssertTrue(card.isAvailableInThisBuild, "offered, not hidden")
        XCTAssertEqual(card.statusDescription, "Requires macOS 26 or later.")
        XCTAssertEqual(card.actions, [.download])
        XCTAssertFalse(model.isEnabled(.download, for: card))
        XCTAssertEqual(model.mutationDisabledReason(for: card), "Requires macOS 26 or later.")
        XCTAssertFalse(card.isBusy)
        XCTAssertNil(card.progress)
        XCTAssertEqual(SpeechModelsViewModel.actions(for: .unavailable(failure), isDefault: false), [.download])
        XCTAssertEqual(ModelSettingsViewModel.statusDescription(for: .unavailable(failure)), "Requires macOS 26 or later.")
        XCTAssertNil(ModelSettingsViewModel.progress(for: .unavailable(failure)))
    }

    func testAnErrorOnTheSystemCardReadsAsTheDomainSentence() throws {
        let error = SystemManagedAssetError.tooManyReservedLocales.modelFailure
        let model = SpeechModelsViewModel(snapshot: snapshot(.error(error)))
        let card = try XCTUnwrap(model.cards.first { $0.id == "apple-speech" })
        XCTAssertEqual(card.statusDescription, "Error — \(SystemManagedAssetError.tooManyReservedLocales.message)")
        XCTAssertEqual(card.actions, [.retry, .delete])
    }

    // MARK: Dictionary section

    func testTheDictionaryShowsAPhraseCountForAPhraseListRuntime() async {
        let counter = FixedCounter(limit: .phrases(100))
        let host = SettingsProjectionHost.detached(settings: AppSettings(dictionary: DictionarySettings(terms: ["KVoice", "WhisperKit"])))
        let model = DictionaryViewModel(host: host, counter: counter, catalogPromptTokenLimit: nil)
        await model.refresh()
        XCTAssertEqual(model.phraseLimit, 100)
        XCTAssertEqual(model.phraseUsage?.sent, 2)
        XCTAssertEqual(model.phraseUsage?.limit, 100)
        XCTAssertNil(model.usage, "no token budget")
        XCTAssertFalse(model.promptUnsupported, "the list is used — as hints")
        // Adding is never refused on count: the engine sends the first 100.
        let added = await model.add("Cosima")
        XCTAssertTrue(added)
        XCTAssertEqual(model.phraseUsage?.sent, 3)

        // A token-budget runtime clears it again.
        model.counter = FixedCounter(limit: .tokens(111))
        await model.refresh()
        XCTAssertNil(model.phraseLimit)
        XCTAssertNil(model.phraseUsage)
        XCTAssertNotNil(model.usage)
    }

    // MARK: Runtime card

    func testTheRuntimeCardSaysThePlatformPlacesAppleSpeech() {
        let snapshot = RuntimeSnapshot(
            residentModelID: "apple-speech",
            residentModelName: "Apple Speech — on-device",
            runtime: .appleSpeech,
            computeUnitsAvailability: .disabled(reason: SettingAvailabilityReason.runtimeHasNoComputeUnitChoice.message)
        )
        let model = RuntimeCardViewModel(snapshot: snapshot, telemetry: NoRuntimeTelemetry())
        let lines = model.placementLines
        XCTAssertEqual(lines.map(\.label), ["Model"])
        XCTAssertEqual(lines.first?.value, "Placed by macOS")
        XCTAssertEqual(lines.first?.isAvailable, false)
        XCTAssertFalse(model.canChangeComputeUnits, "no compute-unit choice for this runtime")
        XCTAssertEqual(model.controlsDisabledReason, SettingAvailabilityReason.runtimeHasNoComputeUnitChoice.message)
        XCTAssertTrue(model.canRunPerformanceTest, "the test still measures the runtime")

        // A Core ML runtime keeps its two planned rows.
        let whisper = RuntimeCardViewModel(
            snapshot: RuntimeSnapshot(residentModelID: "standard", runtime: .whisperKitCoreML, placementIsPending: true),
            telemetry: NoRuntimeTelemetry()
        )
        XCTAssertEqual(whisper.placementLines.map(\.label), ["Encoder", "Decoder"])
    }

    func testThePerformanceTestOnAppleSpeechReportsTheFigureWithoutGradingADevice() async {
        let snapshot = RuntimeSnapshot(
            residentModelID: "apple-speech",
            runtime: .appleSpeech,
            computeUnitsAvailability: .disabled(reason: SettingAvailabilityReason.runtimeHasNoComputeUnitChoice.message)
        )
        let model = RuntimeCardViewModel(
            snapshot: snapshot,
            telemetry: NoRuntimeTelemetry(),
            snapshotProvider: { snapshot },
            transcribePerformanceSample: {
                PerformanceSampleRun(realTimeFactor: 0.02, audioDuration: .seconds(11.6), inferenceDuration: .seconds(0.23))
            }
        )
        model.runPerformanceTest()
        for _ in 0..<5_000 where model.isRunningPerformanceTest { await Task.yield() }
        XCTAssertEqual(model.performanceTestResult?.verdict, .asExpected("Placed by macOS (RTF 0.02×)"))
    }
}

private struct FixedCounter: PromptTokenCounting {
    let limit: PromptTokenLimit

    func promptTokenLimit() async -> PromptTokenLimit? { limit }
    func promptTokenCount(of text: String) async -> Int? { limit.tokens == nil ? nil : text.count / 4 }
}
