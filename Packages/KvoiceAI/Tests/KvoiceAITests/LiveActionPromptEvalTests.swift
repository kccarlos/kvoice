import Foundation
import XCTest
@testable import KvoiceAI
import KvoiceDomain

/// A small opt-in eval of the shipped AI Action prompts against Gemini, the
/// provider the 0.1.5 demo used. Two messy dictations — one English, one
/// Chinese, each with fillers and a self-correction ("two, no, wait,
/// three") — run through Clean Up, TODO List, Translate (both directions)
/// and Prompt, and each reply is printed on a `prompt-eval` line so a person
/// can compare prompt revisions. The inputs are synthetic; the key is read
/// from the app's secrets file at run time and never printed.
///
///     KVOICE_LIVE_AI_TESTS=1 ./Scripts/test.sh --filter LiveActionPromptEvalTests
///
/// `KVOICE_PROMPT_EVAL_REPEATS=3` samples each case three times (a live
/// model varies between runs), and `KVOICE_PROMPT_EVAL_PREVIOUS=1` runs the
/// text each built-in shipped with before the current one
/// (`BuiltInPromptModes.previousPrompts`), for a before/after comparison.
///
/// Model output is not asserted on beyond "not empty": a live model is not
/// deterministic, and the suite must not flake on wording.
final class LiveActionPromptEvalTests: XCTestCase {
    private static let geminiURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!
    private static let geminiModel = "models/gemini-3.5-flash-lite"

    static let english = "Um, so tomorrow's meeting, let's do two. No, wait, three. Oh, and, uh, send Lisa the report and book Friday's flights."
    static let chinese = "那个明天的会改到两点不对三点吧对了把报告发给丽莎再订周五的机票"
    /// A control with plain negations and no self-correction: the
    /// self-correction rule must not drop a "no" or a "不是" that is meant.
    static let control = "No, I don't think we should ship Friday. 这不是我的问题，是服务器的。"

    private static let simplifiedChinese = TranslationLanguage(bcp47: "zh-Hans", displayName: "Chinese, Simplified")
    private static let englishLanguage = TranslationLanguage(bcp47: "en", displayName: "English")

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KVOICE_LIVE_AI_TESTS"] == "1",
            "live endpoint tests are opt-in (KVOICE_LIVE_AI_TESTS=1)"
        )
    }

    func testShippedActionsOnTheDemoDictations() async throws {
        let credentials = try Self.storedGeminiKey()
        let client = OpenAICompatibleAIProcessingClient()
        let environment = ProcessInfo.processInfo.environment
        let repeats = max(1, Int(environment["KVOICE_PROMPT_EVAL_REPEATS"] ?? "") ?? 1)
        let previous = environment["KVOICE_PROMPT_EVAL_PREVIOUS"] == "1"
        let profile = AIRequestContext(userProfile: "Role: software engineer. Writes in English at work.")
        let runs: [(key: String, label: String, input: String, target: TranslationLanguage?, context: AIRequestContext)] = [
            (BuiltInPromptModes.Key.clean, "clean/en", Self.english, nil, .init()),
            (BuiltInPromptModes.Key.clean, "clean/zh", Self.chinese, nil, .init()),
            (BuiltInPromptModes.Key.todo, "todo/en", Self.english, nil, .init()),
            (BuiltInPromptModes.Key.todo, "todo/zh", Self.chinese, nil, .init()),
            (BuiltInPromptModes.Key.translate, "translate/en->zh", Self.english, Self.simplifiedChinese, .init()),
            (BuiltInPromptModes.Key.translate, "translate/zh->en", Self.chinese, Self.englishLanguage, .init()),
            (BuiltInPromptModes.Key.translate2, "translate2/en->zh", Self.english, Self.simplifiedChinese, .init()),
            (BuiltInPromptModes.Key.translate2, "translate2/zh->en", Self.chinese, Self.englishLanguage, .init()),
            (BuiltInPromptModes.Key.promptRewrite, "prompt/en", Self.english, nil, .init()),
            (BuiltInPromptModes.Key.promptRewrite, "prompt/zh", Self.chinese, nil, .init()),
            (BuiltInPromptModes.Key.promptRewrite, "prompt/zh+en-profile", Self.chinese, nil, profile),
            (BuiltInPromptModes.Key.clean, "clean/control", Self.control, nil, .init()),
            (BuiltInPromptModes.Key.translate, "translate/control->zh", Self.control, Self.simplifiedChinese, .init()),
            (BuiltInPromptModes.Key.translate, "translate/control->en", Self.control, Self.englishLanguage, .init()),
            (BuiltInPromptModes.Key.translate2, "translate2/control->en", Self.control, Self.englishLanguage, .init())
        ]
        for run in runs {
            for sample in 1...repeats {
                var settings = AIEndpointSettings(baseURL: Self.geminiURL, modelID: Self.geminiModel, isEnabled: true)
                settings.seedBuiltInPromptModesIfNeeded()
                var action = try XCTUnwrap(settings.promptModes.first { $0.builtInKey == run.key })
                if let target = run.target { action.translationLanguage = target }
                if previous { action.prompt = try XCTUnwrap(BuiltInPromptModes.previousPrompts(forKey: run.key).last) }
                settings.apply(promptMode: action)
                let request = AIProcessRequest(
                    jobID: UUID(),
                    mode: settings.mode,
                    rawTranscript: run.input,
                    modelID: settings.modelID,
                    targetLanguage: settings.translationLanguage,
                    polishPrompt: settings.promptConfiguration.polishPrompt,
                    context: run.context
                )
                let text = try await processPaced(client, request, settings, credentials)
                let version = previous ? "previous" : "current"
                // Unbuffered: `print` to a pipe can be lost when the runner exits.
                let line = "prompt-eval \(version) \(run.label) #\(sample) => \(text.replacingOccurrences(of: "\n", with: " ⏎ "))\n"
                FileHandle.standardError.write(Data(line.utf8))
                XCTAssertFalse(text.isEmpty, run.label)
            }
        }
    }

    private func processPaced(
        _ client: OpenAICompatibleAIProcessingClient,
        _ request: AIProcessRequest,
        _ settings: AIEndpointSettings,
        _ credentials: AICredentialSnapshot
    ) async throws -> String {
        // Gemini's free tier allows about 15 requests a minute: pace every
        // request, and back off on a 429 or a transient 503.
        try await Task.sleep(nanoseconds: 4_500_000_000)
        var attempt = 0
        while true {
            do {
                return try await client.process(request, settings: settings, credentials: credentials).text
            } catch let error as KVoiceError where error.retryable && attempt < 3 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 20_000_000_000)
            }
        }
    }

    private static func storedGeminiKey() throws -> AICredentialSnapshot {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kvoice/secrets.json")
        guard let data = try? Data(contentsOf: url),
              let secrets = try? JSONDecoder().decode(SecretSettings.self, from: data),
              let key = secrets.apiKey, !key.isEmpty
        else {
            throw XCTSkip("no stored key in the app's secrets file")
        }
        return AICredentialSnapshot(apiKey: key)
    }
}
