import XCTest
@testable import KvoiceDomain

/// ADR-017: the `Speech models` block of `AppSettings`, the catalog value
/// types, and the transcription-language table.
final class SpeechModelSettingsTests: XCTestCase {
    func testSpeechModelBlockRoundTripsAndDefaultsWhenAbsent() throws {
        var settings = AppSettings()
        XCTAssertNil(settings.defaultSpeechModelID)
        XCTAssertNil(settings.transcriptionLanguage)
        XCTAssertEqual(settings.speechModelModes, [:])
        XCTAssertFalse(settings.addSpaceAfterInsertion)
        XCTAssertFalse(settings.automaticTextFormatting)
        XCTAssertTrue(settings.voiceActivityDetectionEnabled)

        settings.defaultSpeechModelID = "whisper-large-v3-turbo-coreml-632mb"
        settings.transcriptionLanguage = "zh"
        settings.speechModelModes = ["whisper-large-v3-turbo-coreml-632mb": .streaming]
        settings.addSpaceAfterInsertion = true
        settings.automaticTextFormatting = true
        settings.voiceActivityDetectionEnabled = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, settings)

        // A settings file written before ADR-017 has none of the keys.
        let legacy = Data("{\"schemaVersion\":1}".utf8)
        let older = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(older, AppSettings())
    }

    func testCatalogResolvesDefaultAndFallsBackToRecommended() throws {
        let standard = SpeechModelCatalogEntry(
            id: "standard", displayName: "Whisper v3 Turbo", variantName: "Standard",
            family: "whisper-large-v3-turbo", runtime: .whisperKitCoreML, hosting: .onDevice,
            supportsStreaming: true, supportsBatch: true, downloadBytes: 646_000_000,
            languageSummary: "99 languages", summary: "Default.", isRecommended: true,
            revision: "rev", manifestResource: "standard.json", manifestSHA256: String(repeating: "a", count: 64)
        )
        let reserved = SpeechModelCatalogEntry(
            id: "qwen", displayName: "Qwen3-ASR", variantName: "Standard",
            family: "qwen3-asr", runtime: .mlxQwen3ASR, hosting: .onDevice,
            supportsStreaming: true, supportsBatch: true, downloadBytes: 1,
            languageCodes: ["zh", "en"], languageSummary: "zh/en", summary: "Reserved.", isRecommended: false,
            revision: "rev", manifestResource: "qwen.json", manifestSHA256: String(repeating: "b", count: 64)
        )
        let catalog = SpeechModelCatalog(entries: [reserved, standard])

        XCTAssertEqual(catalog.recommended?.id, "standard")
        XCTAssertEqual(catalog.defaultEntry(preferring: nil)?.id, "standard")
        XCTAssertEqual(catalog.defaultEntry(preferring: "qwen")?.id, "qwen")
        XCTAssertEqual(catalog.defaultEntry(preferring: "missing")?.id, "standard")
        XCTAssertEqual(catalog.runnableEntries.map(\.id), ["standard"])
        XCTAssertEqual(standard.fullDisplayName, "Whisper v3 Turbo — Standard")
        XCTAssertEqual(standard.availableModes, [.batch, .streaming])
        XCTAssertTrue(standard.supportsLanguage("yue"))
        XCTAssertFalse(reserved.supportsLanguage("yue"))
        XCTAssertTrue(reserved.supportsLanguage("zh"))

        let data = try JSONEncoder().encode(catalog)
        XCTAssertEqual(try JSONDecoder().decode(SpeechModelCatalog.self, from: data), catalog)
    }

    func testWhisperLanguageTableIsUniqueSortedAndCoversTheCoreLanguages() {
        let languages = TranscriptionLanguage.whisperLanguages
        XCTAssertEqual(languages.count, 100, "Whisper's 99 languages plus Cantonese")
        XCTAssertEqual(Set(languages.map(\.code)).count, languages.count, "codes are unique")
        XCTAssertEqual(languages.map(\.displayName), languages.map(\.displayName).sorted())
        for code in ["zh", "en", "yue", "ja", "de"] {
            XCTAssertTrue(languages.contains { $0.code == code }, code)
        }
        XCTAssertEqual(TranscriptionLanguage.displayName(forCode: nil), "Auto-detect")
        XCTAssertEqual(TranscriptionLanguage.displayName(forCode: "zh"), "Chinese")
        XCTAssertEqual(TranscriptionLanguage.displayName(forCode: "xx"), "xx")
    }

    func testAudioSampleChunkIsEngineCompatibleOnlyAtTheTranscriptionFormat() {
        XCTAssertTrue(AudioSampleChunk(samples: [0, 0]).isEngineCompatible)
        XCTAssertFalse(AudioSampleChunk(samples: [0], sampleRate: 48_000).isEngineCompatible)
        XCTAssertFalse(AudioSampleChunk(samples: [0], channelCount: 2).isEngineCompatible)
    }
}
