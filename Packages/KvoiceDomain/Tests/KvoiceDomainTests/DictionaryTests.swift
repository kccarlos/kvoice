import Foundation
import XCTest
@testable import KvoiceDomain

/// ADR-018: the user dictionary as a Whisper initial prompt.
final class DictionaryTests: XCTestCase {
    // MARK: Settings

    func testTermsAreTrimmedDeduplicatedCaseInsensitivelyAndNeverEmpty() {
        let settings = DictionarySettings(terms: ["  kvoice ", "KVOICE", "", "   ", "Whisper\tKit", "whisper  kit", "Cosima"])

        XCTAssertEqual(settings.terms, ["kvoice", "Whisper Kit", "Cosima"])
        XCTAssertTrue(settings.containsTerm("cosima"))
        XCTAssertFalse(settings.containsTerm("Carla"))
        XCTAssertNil(DictionarySettings.normalizedTerm(" \n "))
        XCTAssertEqual(DictionarySettings.normalizedTerm("  a  b "), "a b")
    }

    func testDecodingSanitizesAndAMissingKeyIsTheDefault() throws {
        let decoded = try JSONDecoder().decode(
            DictionarySettings.self,
            from: Data(#"{"terms":["  Alpha ","alpha","","Beta"]}"#.utf8)
        )
        XCTAssertEqual(decoded.terms, ["Alpha", "Beta"])

        let app = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"schemaVersion":1}"#.utf8))
        XCTAssertEqual(app.dictionary, DictionarySettings())
        XCTAssertTrue(app.dictionary.terms.isEmpty)
    }

    func testAppSettingsRoundTripsTheDictionary() throws {
        let input = AppSettings(dictionary: DictionarySettings(terms: ["kvoice", "WhisperKit", "Cosima"]))
        let data = try JSONEncoder().encode(input)
        let output = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(output.dictionary.terms, ["kvoice", "WhisperKit", "Cosima"])
        XCTAssertEqual(output, input)
    }

    func testImportExportFileFormatIsOneTermPerLine() {
        let terms = DictionarySettings.parse(fileContents: "kvoice\n\n  WhisperKit  \r\nCosima\nkvoice\n")
        XCTAssertEqual(terms, ["kvoice", "WhisperKit", "Cosima"])

        let settings = DictionarySettings(terms: terms)
        XCTAssertEqual(settings.fileContents, "kvoice\nWhisperKit\nCosima\n")
        XCTAssertEqual(DictionarySettings.parse(fileContents: settings.fileContents), terms)
        XCTAssertEqual(DictionarySettings().fileContents, "")
    }

    // MARK: Prompt

    func testPromptIsAGlossarySentenceAndNilWhenEmpty() {
        XCTAssertEqual(
            DictionaryPrompt.render(terms: ["kvoice", "WhisperKit", "Cosima"]),
            "Glossary: kvoice, WhisperKit, Cosima."
        )
        XCTAssertEqual(DictionaryPrompt.render(terms: [" kvoice "]), "Glossary: kvoice.")
        XCTAssertNil(DictionaryPrompt.render(terms: []))
        XCTAssertNil(DictionaryPrompt.render(terms: ["", "  "]), "whitespace-only terms send no prompt")
        XCTAssertNil(DictionaryPrompt.render(DictionarySettings()))
    }

    func testEstimateIsOneTokenPerFourLatinCharactersAndOnePointFivePerCJKCharacter() {
        XCTAssertEqual(DictionaryPrompt.estimatedTokenCount(of: ""), 0)
        XCTAssertEqual(DictionaryPrompt.estimatedTokenCount(of: "abcd"), 1)
        XCTAssertEqual(DictionaryPrompt.estimatedTokenCount(of: "abcde"), 2, "rounds up")
        XCTAssertEqual(DictionaryPrompt.estimatedTokenCount(of: "北京"), 3)
        XCTAssertEqual(DictionaryPrompt.estimatedTokenCount(of: "東京"), 3)
        XCTAssertEqual(DictionaryPrompt.estimatedTokenCount(of: "서울"), 3, "Hangul counts as CJK")
        // Mixed: 8 Latin (2) + 2 CJK (3).
        XCTAssertEqual(DictionaryPrompt.estimatedTokenCount(of: "Glossary北京"), 5)
    }

    // MARK: Budget

    func testBudgetIsTheLimitMinusATenPercentReserveRoundedUp() {
        let whisper = DictionaryTokenBudget(promptTokenLimit: 224, isFromResidentModel: false)
        XCTAssertEqual(whisper.reserve, 23)
        XCTAssertEqual(whisper.budget, 201)

        let whisperKit = DictionaryTokenBudget(promptTokenLimit: 111, isFromResidentModel: true)
        XCTAssertEqual(whisperKit.reserve, 12)
        XCTAssertEqual(whisperKit.budget, 99)

        XCTAssertEqual(DictionaryTokenBudget(promptTokenLimit: 0, isFromResidentModel: true).budget, 0)
    }

    func testBudgetResolutionPrefersTheResidentRuntimeAndCapsByTheCatalog() {
        // Nothing loaded: the catalog stands in, labelled as such.
        XCTAssertEqual(
            DictionaryTokenBudget.resolve(catalogLimit: 224, residentLimit: nil),
            DictionaryTokenBudget(promptTokenLimit: 224, isFromResidentModel: false)
        )
        // Loaded: the runtime's cap wins when it is the smaller.
        XCTAssertEqual(
            DictionaryTokenBudget.resolve(catalogLimit: 224, residentLimit: .tokens(111)),
            DictionaryTokenBudget(promptTokenLimit: 111, isFromResidentModel: true)
        )
        // A model whose own context is below the runtime cap is not shown the cap.
        XCTAssertEqual(
            DictionaryTokenBudget.resolve(catalogLimit: 64, residentLimit: .tokens(111)),
            DictionaryTokenBudget(promptTokenLimit: 64, isFromResidentModel: true)
        )
        // No catalog value: the runtime alone.
        XCTAssertEqual(
            DictionaryTokenBudget.resolve(catalogLimit: nil, residentLimit: .tokens(111)),
            DictionaryTokenBudget(promptTokenLimit: 111, isFromResidentModel: true)
        )
    }

    func testBudgetResolutionReportsUnsupportedAsNil() {
        XCTAssertNil(DictionaryTokenBudget.resolve(catalogLimit: 224, residentLimit: .unsupported),
                     "a resident model without a prompt wins over the catalog")
        XCTAssertNil(DictionaryTokenBudget.resolve(catalogLimit: nil, residentLimit: nil),
                     "nothing loaded and a catalog entry without a limit means no prompt")
        XCTAssertNil(PromptTokenLimit.unsupported.tokens)
        XCTAssertEqual(PromptTokenLimit.tokens(111).tokens, 111)
    }

    func testCatalogEntryPromptTokenLimitIsOptionalAndDecodes() throws {
        let json = """
        {"id":"m","displayName":"M","variantName":"","family":"f","runtime":"whisperkit-coreml",
         "hosting":"on-device","supportsStreaming":true,"supportsBatch":true,"downloadBytes":1,
         "languageCodes":null,"languageSummary":"","summary":"","isRecommended":true,"revision":"r",
         "manifestResource":"m","manifestSHA256":"0"}
        """
        let without = try JSONDecoder().decode(SpeechModelCatalogEntry.self, from: Data(json.utf8))
        XCTAssertNil(without.promptTokenLimit, "absent means the model takes no prompt")

        let with = try JSONDecoder().decode(
            SpeechModelCatalogEntry.self,
            from: Data(json.replacingOccurrences(of: #""manifestSHA256":"0""#, with: #""manifestSHA256":"0","promptTokenLimit":224"#).utf8)
        )
        XCTAssertEqual(with.promptTokenLimit, 224)
    }

    func testTranscriptionRequestCarriesAnOptionalPrompt() {
        let audio = AudioRecording(samples: [0, 0], duration: .zero, peakLevelDBFS: -60, clippedFrameCount: 0)
        XCTAssertNil(TranscriptionRequest(jobID: UUID(), audio: audio).initialPrompt)
        XCTAssertEqual(
            TranscriptionRequest(jobID: UUID(), audio: audio, initialPrompt: "Glossary: kvoice.").initialPrompt,
            "Glossary: kvoice."
        )
    }
}
