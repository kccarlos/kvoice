import XCTest
@testable import KvoiceDomain

/// ADR-025: the domain seams a system-managed speech model (Apple Speech)
/// needs — the catalog's asset source, the language overlay, the
/// `.unavailable` lifecycle state, the phrase-list prompt limit, the
/// inverse of the dictionary rendering, and the copy inventory.
final class AppleSpeechDomainTests: XCTestCase {
    private static func appleSpeechEntry(assetSource: SpeechModelAssetSource? = .systemManaged) -> SpeechModelCatalogEntry {
        SpeechModelCatalogEntry(
            id: "apple-speech", displayName: "Apple Speech", variantName: "on-device",
            family: "apple-speech", runtime: .appleSpeech, hosting: .onDevice,
            supportsStreaming: true, supportsBatch: true, downloadBytes: 0,
            languageCodes: TranscriptionLanguage.appleSpeechShippedLanguageCodes,
            languageSummary: "21 languages", summary: "Apple's model.", isRecommended: false,
            revision: "system", manifestResource: "", manifestSHA256: "",
            punctuation: true, assetSource: assetSource
        )
    }

    // MARK: Runtime

    func testAppleSpeechIsARuntimeThisBuildShipsAndOnlyQwenStaysReserved() {
        XCTAssertTrue(SpeechModelRuntime.appleSpeech.isAvailableInThisBuild)
        XCTAssertEqual(SpeechModelRuntime.allCases.filter { !$0.isAvailableInThisBuild }, [.mlxQwen3ASR])
        XCTAssertEqual(SpeechModelRuntime.appleSpeech.rawValue, "apple-speech", "the reserved spelling from ADR-017")
        XCTAssertEqual(SpeechModelRuntime.appleSpeech.displayName, "Apple Speech")
    }

    func testOnlyAppleSpeechLacksAComputeUnitChoiceAndTakesNoPrompt() {
        XCTAssertFalse(SpeechModelRuntime.appleSpeech.hasComputeUnitChoice)
        XCTAssertFalse(SpeechModelRuntime.appleSpeech.acceptsInitialPrompt, "the dictionary is a phrase list, not a prompt")
        for runtime in SpeechModelRuntime.allCases where runtime != .appleSpeech {
            XCTAssertTrue(runtime.hasComputeUnitChoice, "\(runtime) keeps the picker")
        }
    }

    // MARK: Catalog entry

    func testAssetSourceDecodesIfPresentAndAbsentMeansKvoiceManifest() throws {
        let entry = Self.appleSpeechEntry()
        XCTAssertTrue(entry.isSystemManaged)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(SpeechModelCatalogEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.assetSource, .systemManaged)

        // An entry written before ADR-025 has no key at all.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "assetSource")
        let legacy = try JSONDecoder().decode(
            SpeechModelCatalogEntry.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(legacy.assetSource)
        XCTAssertFalse(legacy.isSystemManaged)
        XCTAssertEqual(SpeechModelAssetSource.systemManaged.rawValue, "system-managed")
        XCTAssertEqual(SpeechModelAssetSource.kvoiceManifest.rawValue, "kvoice-manifest")
    }

    func testObservingLanguagesReplacesOnlyTheCoverageAndTheCatalogReplacesOneEntry() {
        let shipped = Self.appleSpeechEntry()
        let whisper = SpeechModelCatalogEntry(
            id: "whisper", displayName: "Whisper", variantName: "", family: "whisper", runtime: .whisperKitCoreML,
            hosting: .onDevice, supportsStreaming: true, supportsBatch: true, downloadBytes: 1,
            languageSummary: "99", summary: "", isRecommended: true, revision: "r", manifestResource: "m", manifestSHA256: "d"
        )
        let observed = shipped.observingLanguages(codes: ["en", "zh", "ja"], summary: "3 languages on this Mac")
        XCTAssertEqual(observed.languageCodes, ["en", "zh", "ja"])
        XCTAssertEqual(observed.languageSummary, "3 languages on this Mac")
        XCTAssertTrue(observed.supportsLanguage("ja"))
        XCTAssertFalse(observed.supportsLanguage("fr"))
        // Everything else is byte-for-byte the shipped entry.
        XCTAssertEqual(observed.observingLanguages(codes: shipped.languageCodes ?? [], summary: shipped.languageSummary), shipped)

        let catalog = SpeechModelCatalog(entries: [whisper, shipped])
        let overlaid = catalog.replacing(observed)
        XCTAssertEqual(overlaid.entries.map(\.id), ["whisper", "apple-speech"], "order is kept")
        XCTAssertEqual(overlaid.entry(id: "apple-speech")?.languageCodes, ["en", "zh", "ja"])
        XCTAssertEqual(overlaid.entry(id: "whisper"), whisper)
        XCTAssertEqual(catalog.replacing(whisper), catalog)
        XCTAssertEqual(catalog.runnableEntries.map(\.id), ["whisper", "apple-speech"], "Apple Speech is runnable in this build")
    }

    func testTheShippedAppleSpeechCodesAreWhisperCodesSortedAndCoverEnglishAndChinese() {
        let codes = TranscriptionLanguage.appleSpeechShippedLanguageCodes
        XCTAssertEqual(codes, codes.sorted())
        XCTAssertEqual(Set(codes).count, codes.count)
        for code in codes {
            XCTAssertTrue(TranscriptionLanguage.whisperLanguages.contains { $0.code == code }, "\(code) is not a Whisper code")
        }
        XCTAssertTrue(codes.contains("en"))
        XCTAssertTrue(codes.contains("zh"))
        XCTAssertTrue(codes.contains("yue"))
        XCTAssertEqual(codes.count, 21)
    }

    // MARK: Lifecycle state and ownership

    func testUnavailableIsItsOwnLifecycleStateAndSystemManagedOwnershipRoundTrips() throws {
        let failure = SystemManagedUnavailableReason.requiresNewerMacOS.modelFailure
        XCTAssertEqual(ModelLifecycleState.unavailable(failure), .unavailable(failure))
        XCTAssertNotEqual(ModelLifecycleState.unavailable(failure), .error(failure))
        XCTAssertEqual(failure.message, "Requires macOS 26 or later.")
        XCTAssertEqual(failure.code, "MODEL-REQUIRES-NEWER-MACOS")

        let sentinel = InstalledModelSentinel(
            modelID: "apple-speech", repository: "system", revision: "system", manifestVersion: 0,
            manifestSHA256: "", installedBytes: 0, installedAt: Date(timeIntervalSince1970: 0),
            appVersion: "test", ownership: .systemManaged
        )
        let data = try JSONEncoder().encode(sentinel)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"ownership\":\"system\""))
        XCTAssertEqual(try JSONDecoder().decode(InstalledModelSentinel.self, from: data), sentinel)
    }

    // MARK: Prompt limit and the dictionary

    func testPhrasesIsAPromptLimitWithoutATokenBudgetThatStillCountsAsAcceptingTheDictionary() {
        let limit = PromptTokenLimit.phrases(100)
        XCTAssertEqual(limit.phrases, 100)
        XCTAssertNil(limit.tokens)
        XCTAssertNil(PromptTokenLimit.tokens(111).phrases)
        XCTAssertNil(DictionaryTokenBudget.resolve(catalogLimit: 224, residentLimit: limit), "a phrase list has no token budget")
        let profile = EnvironmentProfile(enginePromptTokenLimit: limit)
        XCTAssertEqual(profile.residentModelAcceptsPrompt, true, "the Dictionary editor stays enabled")
        XCTAssertNil(profile.enginePromptTokenCap)
    }

    func testTermsFromRenderedPromptInvertTheRenderingAndTolerateOtherText() {
        let terms = ["kvoice", "WhisperKit", "Cosima"]
        let rendered = DictionaryPrompt.render(terms: terms)
        XCTAssertEqual(rendered, "Glossary: kvoice, WhisperKit, Cosima.")
        XCTAssertEqual(DictionaryPrompt.terms(fromRendered: rendered), terms)
        XCTAssertEqual(DictionaryPrompt.terms(fromRendered: nil), [])
        XCTAssertEqual(DictionaryPrompt.terms(fromRendered: "   "), [])
        XCTAssertEqual(DictionaryPrompt.terms(fromRendered: DictionaryPrompt.render(terms: ["one"])), ["one"])
        // Documented lossiness: a comma-bearing term splits; a term ending in "." keeps it (the render adds its own).
        XCTAssertEqual(DictionaryPrompt.terms(fromRendered: DictionaryPrompt.render(terms: ["Hello, world", "Inc."])), ["Hello", "world", "Inc."])
        // Not a rendered prompt: one phrase, never dropped.
        XCTAssertEqual(DictionaryPrompt.terms(fromRendered: "just some text"), ["just some text"])
    }

    // MARK: Copy inventory

    func testSystemManagedCopyIsInTheDomainInventory() {
        let messages = DomainUserFacingCopy.messages
        for reason in SystemManagedUnavailableReason.allCases {
            XCTAssertTrue(messages.contains(reason.message), reason.message)
        }
        for message in SystemManagedAssetError.messageInventory {
            XCTAssertTrue(messages.contains(message), message)
        }
        XCTAssertTrue(messages.contains(SettingAvailabilityReason.runtimeHasNoComputeUnitChoice.message))
        XCTAssertEqual(SystemManagedAssetError.messageInventory.count, 3)
        XCTAssertEqual(SystemManagedAssetError.unavailable(.languageUnsupported).message, SystemManagedUnavailableReason.languageUnsupported.message)
        XCTAssertEqual(SystemManagedAssetError.tooManyReservedLocales.modelFailure.code, "MODEL-ASSET-RESERVATION-LIMIT")
        // Product name spelling in user-facing copy.
        for message in SystemManagedAssetError.messageInventory where message.contains("kvoice") {
            XCTFail("user-facing copy spells the product KVoice: \(message)")
        }
    }

    // MARK: Blocked HUD copy (ADR-025 amendment, 2026-09-16)

    func testTheSystemManagedBlockReasonsKeepTheModelNotInstalledCodeAndAreInTheInventory() {
        let missing = BlockReason.systemManagedAssetsMissing
        XCTAssertEqual(missing.code, KVoiceErrorCode.modelNotInstalled.rawValue, "the HUD's error mapping is unchanged")
        XCTAssertEqual(missing.message, "Apple Speech has no assets for the selected language on this Mac yet. Install them in Settings › Speech Models.")
        XCTAssertNotEqual(missing.message, BlockReason.modelUnavailable.message)

        let failure = SystemManagedUnavailableReason.languageUnsupported.modelFailure
        let unavailable = BlockReason.systemManagedUnavailable(failure)
        XCTAssertEqual(unavailable.code, KVoiceErrorCode.modelNotInstalled.rawValue)
        XCTAssertEqual(
            unavailable.message,
            "Apple Speech doesn't support the selected transcription language on this Mac. Choose another speech model in Settings › Speech Models.",
            "the card's reason, then the pointer — two known sentences joined by one space"
        )
        XCTAssertEqual(BlockReason.systemManagedUnavailable(ModelFailure(code: "x", message: "Requires macOS 26 or later.")).message,
                       "Requires macOS 26 or later. " + BlockReason.systemManagedUnavailableHint)

        // Every piece is a DomainCopy key: the fixed sentence, the hint,
        // and (already) each reason the composed message can start with.
        let messages = DomainUserFacingCopy.messages
        XCTAssertTrue(messages.contains(missing.message))
        XCTAssertTrue(messages.contains(BlockReason.systemManagedUnavailableHint))
        XCTAssertTrue(BlockReason.builtIn.contains(missing))
        for reason in SystemManagedUnavailableReason.allCases {
            XCTAssertTrue(messages.contains(reason.message), reason.message)
        }
        for message in [missing.message, BlockReason.systemManagedUnavailableHint] where message.contains("kvoice") {
            XCTFail("user-facing copy spells the product KVoice: \(message)")
        }
    }
}
