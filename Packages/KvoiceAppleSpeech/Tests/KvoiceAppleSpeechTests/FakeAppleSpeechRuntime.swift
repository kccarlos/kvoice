import Foundation
import KvoiceDomain
@testable import KvoiceAppleSpeech

/// A scripted `AppleSpeechRuntime`: the platform's answers are set by the
/// test, every call is recorded, and a session replays the events the test
/// queued — volatile ones on `append`, finalized ones on `finish`.
actor FakeAppleSpeechRuntime: AppleSpeechRuntime {
    var availabilityAnswer: AppleSpeechAvailability = .available
    var supportedLocales: [String] = ["en_US", "en_GB", "zh_CN", "zh_TW", "zh_HK", "yue_CN", "ja_JP", "es_ES", "es_MX", "mul_IN"]
    var assetStatuses: [String: AppleSpeechAssetStatus] = ["en_US": .installed]
    var reserved: [String] = []
    var maximumReserved = 5
    var installError: AppleSpeechError?
    var installProgressSteps: [Double] = [0.1, 0.5, 1]
    var sessionError: AppleSpeechError?
    /// Events every session replays: `.volatile` on each `append`, then the
    /// `.finalized` ones on `finish`.
    var scriptedEvents: [AppleSpeechResultEvent] = []

    private(set) var sessionConfigurations: [AppleSpeechSessionConfiguration] = []
    private(set) var installedLocales: [String] = []
    private(set) var releasedLocales: [String] = []
    private(set) var retentionReleases = 0
    private(set) var sessions: [FakeAppleSpeechSession] = []

    func set(availability: AppleSpeechAvailability) { availabilityAnswer = availability }
    func set(supportedLocales: [String]) { self.supportedLocales = supportedLocales }
    func set(status: AppleSpeechAssetStatus, for locale: String) { assetStatuses[locale] = status }
    func set(installError: AppleSpeechError?) { self.installError = installError }
    func set(sessionError: AppleSpeechError?) { self.sessionError = sessionError }
    func set(scriptedEvents: [AppleSpeechResultEvent]) { self.scriptedEvents = scriptedEvents }

    func availability() async -> AppleSpeechAvailability { availabilityAnswer }

    func supportedLocaleIdentifiers() async -> [String] { supportedLocales.sorted() }

    func assetStatus(localeIdentifier: String) async -> AppleSpeechAssetStatus {
        guard supportedLocales.contains(localeIdentifier) else { return .unsupported }
        return assetStatuses[localeIdentifier] ?? .supported
    }

    var maximumReservedLocales: Int { maximumReserved }

    func reservedLocaleIdentifiers() async -> [String] { reserved.sorted() }

    func installAssets(localeIdentifier: String, progress: @escaping @Sendable (Double) async -> Void) async throws {
        if let installError { throw installError }
        if !reserved.contains(localeIdentifier), reserved.count >= maximumReserved {
            throw AppleSpeechError.tooManyReservedLocales(limit: maximumReserved)
        }
        for step in installProgressSteps { await progress(step) }
        if !reserved.contains(localeIdentifier) { reserved.append(localeIdentifier) }
        assetStatuses[localeIdentifier] = .installed
        installedLocales.append(localeIdentifier)
    }

    func releaseAssets(localeIdentifier: String) async -> Bool {
        releasedLocales.append(localeIdentifier)
        assetStatuses[localeIdentifier] = .supported
        guard let index = reserved.firstIndex(of: localeIdentifier) else { return false }
        reserved.remove(at: index)
        return true
    }

    func releaseRetainedModels() async { retentionReleases += 1 }

    func makeSession(
        configuration: AppleSpeechSessionConfiguration,
        results: @escaping @Sendable (AppleSpeechResultEvent) async -> Void
    ) async throws -> any AppleSpeechSession {
        if let sessionError { throw sessionError }
        sessionConfigurations.append(configuration)
        let session = FakeAppleSpeechSession(events: scriptedEvents, results: results)
        sessions.append(session)
        return session
    }
}

actor FakeAppleSpeechSession: AppleSpeechSession {
    private let volatileEvents: [AppleSpeechResultEvent]
    private let finalizedEvents: [AppleSpeechResultEvent]
    private let results: @Sendable (AppleSpeechResultEvent) async -> Void
    private(set) var appendedSampleCounts: [Int] = []
    private(set) var finished = false
    private(set) var cancelled = false
    private var nextVolatile = 0

    init(events: [AppleSpeechResultEvent], results: @escaping @Sendable (AppleSpeechResultEvent) async -> Void) {
        volatileEvents = events.filter { if case .volatile = $0 { return true } else { return false } }
        finalizedEvents = events.filter { if case .finalized = $0 { return true } else { return false } }
        self.results = results
    }

    /// Accepted after `finish` too: a streaming test uses `finish` as the
    /// lever that delivers the scripted finalized events mid-session.
    func append(samples: [Float]) async throws {
        guard !cancelled else { return }
        appendedSampleCounts.append(samples.count)
        if nextVolatile < volatileEvents.count {
            await results(volatileEvents[nextVolatile])
            nextVolatile += 1
        }
    }

    func finish() async throws {
        guard !cancelled, !finished else { return }
        finished = true
        for event in finalizedEvents {
            await results(event)
        }
    }

    func cancel() async {
        cancelled = true
    }
}
