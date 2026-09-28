import Foundation
import KvoiceDomain
@testable import KvoiceAppleIntelligence

/// A scripted runtime so the client's rules are tested without a model —
/// on-device (ADR-024) or Private Cloud Compute (ADR-027), by `transport`.
final class FakeAppleIntelligenceRuntime: AppleIntelligenceRuntime, @unchecked Sendable {
    struct Call: Equatable {
        let instructions: String
        let prompt: String
        let maximumResponseTokens: Int?
    }

    let transport: AIProviderTransport

    private let lock = NSLock()
    private var _availability: AIProviderAvailability
    private var _contextSize: Int?
    private var _tokenCount: Int?
    private var _tokenCountError: (any Error)?
    private var _reply: Result<String, AppleIntelligenceRuntimeError>
    private var _delay: Duration?
    private var _calls: [Call] = []
    private var _quota: AIProviderQuota?
    private var _frameworkReads = 0
    private var _quotaOptionsShown = 0

    init(
        transport: AIProviderTransport = .appleIntelligence,
        availability: AIProviderAvailability = .available,
        contextSize: Int? = 4096,
        tokenCount: Int? = nil,
        reply: Result<String, AppleIntelligenceRuntimeError> = .success("ok")
    ) {
        self.transport = transport
        _availability = availability
        _contextSize = contextSize
        _tokenCount = tokenCount
        _reply = reply
    }

    var calls: [Call] { lock.withLock { _calls } }
    /// Every read of availability, window, languages or quota, and every
    /// request — the "asked the framework anything" count that ADR-027's
    /// static refusal must keep at zero.
    var frameworkReads: Int { lock.withLock { _frameworkReads + _calls.count } }
    var quotaOptionsShown: Int { lock.withLock { _quotaOptionsShown } }
    func set(availability: AIProviderAvailability) { lock.withLock { _availability = availability } }
    func set(reply: Result<String, AppleIntelligenceRuntimeError>) { lock.withLock { _reply = reply } }
    func set(delay: Duration?) { lock.withLock { _delay = delay } }
    func set(tokenCountError: any Error) { lock.withLock { _tokenCountError = tokenCountError } }
    func set(quota: AIProviderQuota?) { lock.withLock { _quota = quota } }

    func availability() -> AIProviderAvailability {
        lock.withLock {
            _frameworkReads += 1
            return _availability
        }
    }

    func contextSize() async -> Int? {
        lock.withLock {
            _frameworkReads += 1
            return _contextSize
        }
    }

    func supportedLanguageIdentifiers() async -> [String] {
        lock.withLock { _frameworkReads += 1 }
        return ["en", "zh-Hans"]
    }

    func quota() -> AIProviderQuota? {
        lock.withLock {
            _frameworkReads += 1
            return _quota
        }
    }

    @MainActor
    func showQuotaIncreaseOptions() {
        lock.withLock { _quotaOptionsShown += 1 }
    }

    func tokenCount(instructions: String, prompt: String) async throws -> Int? {
        let (count, error) = lock.withLock { (_tokenCount, _tokenCountError) }
        if let error { throw error }
        return count
    }

    func respond(instructions: String, prompt: String, maximumResponseTokens: Int?) async throws -> String {
        let (reply, delay) = lock.withLock {
            _calls.append(Call(instructions: instructions, prompt: prompt, maximumResponseTokens: maximumResponseTokens))
            return (_reply, _delay)
        }
        if let delay { try await Task.sleep(for: delay) }
        return try reply.get()
    }
}
