import Foundation
import KvoiceDomain

/// Fits a request into the on-device model's context window (ADR-024).
///
/// Apple's model shares one window between instructions, prompt, and reply
/// (4,096 tokens on macOS 26; `SystemLanguageModel.contextSize` on 27). The
/// client asks the framework for the exact input count where the system can
/// count (macOS 26.4+) and otherwise uses `estimateTokens`, then requires
/// room for a reply about the size of the transcript before it sends
/// anything; a request that does not fit fails as `.aiInputTooLong` and the
/// raw transcript is inserted — the ordinary AI fallback. Pure, so the rule
/// is tested without a model.
public enum AppleIntelligenceContextBudget: Sendable {
    /// The window assumed when the framework cannot say (pre-macOS 27).
    public static let defaultContextSize = 4096

    /// ADR-027: Private Cloud Compute's window as Apple documents it ("a
    /// larger 32K-token context size"; the WWDC26 session shows 32768),
    /// assumed when the asynchronous `contextSize` cannot be read.
    public static let privateCloudComputeContextSize = 32_768

    /// The assumed window for a transport's model.
    public static func defaultContextSize(for transport: AIProviderTransport) -> Int {
        transport == .privateCloudCompute ? privateCloudComputeContextSize : defaultContextSize
    }

    /// Tokens kept free below the window: the framework's own framing of the
    /// instructions and prompt, and the estimate's error.
    public static let safetyMarginTokens = 256

    /// The reply floor, so a one-word transcript still gets a sentence back.
    public static let minimumResponseTokens = 64

    /// A rough count when the framework cannot count: one token per four
    /// characters of Latin-script text (the usual tokenizer rule of thumb),
    /// one token per CJK character, which these tokenizers rarely merge.
    /// Documented as an estimate; the framework's own `contextSizeExceeded`
    /// is still mapped, so an underestimate fails the same way, just later.
    public static func estimateTokens(in text: String) -> Int {
        var latin = 0
        var cjk = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
                cjk += 1
            default:
                latin += 1
            }
        }
        return (latin + 3) / 4 + cjk
    }

    /// The reply budget a transcript of `transcriptTokens` needs: a polish
    /// returns about the same length, a translation may grow by half.
    public static func expectedResponseTokens(forTranscriptTokens transcriptTokens: Int) -> Int {
        max(minimumResponseTokens, transcriptTokens + transcriptTokens / 2)
    }

    /// The plan for one request, or nil when it cannot fit.
    public struct Plan: Equatable, Sendable {
        /// What the reply may use: everything left below the window.
        public let maximumResponseTokens: Int
        /// The input count the plan was made from (exact or estimated).
        public let inputTokens: Int
    }

    public static func plan(
        inputTokens: Int,
        transcriptTokens: Int,
        contextSize: Int?,
        defaultContextSize: Int = AppleIntelligenceContextBudget.defaultContextSize
    ) -> Plan? {
        let window = contextSize ?? defaultContextSize
        let available = window - safetyMarginTokens - inputTokens
        guard available >= expectedResponseTokens(forTranscriptTokens: transcriptTokens) else { return nil }
        return Plan(maximumResponseTokens: available, inputTokens: inputTokens)
    }
}
