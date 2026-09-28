import Foundation

/// ADR-022 item 1, the first of the four configuration sources: the
/// **developer defaults** — the tunables the developer chose, one field per
/// constant that used to be a scattered `static let`.
///
/// Three copies exist and must agree:
///
/// 1. `DeveloperDefaults.compiled` — the values in this file. The build
///    never depends on a JSON file: every field decodes
///    `decodeIfPresent ?? compiled`, so a missing key (an older override, a
///    hand-edited file) cannot break a launch.
/// 2. `Apps/KvoiceApp/Resources/kvoice.defaults.json` — the bundled copy,
///    every key present and equal to the compiled value.
///    `DeveloperDefaultsTests.testBundledJSONMatchesTheCompiledDefaults`
///    keeps the two from drifting.
/// 3. `~/Library/Application Support/kvoice/config.override.json` — an
///    optional, partial developer override read once at launch by
///    `DeveloperDefaultsLoader` (KvoicePersistence). Never hot-reloaded,
///    never shipped, never in Git (it lives outside the checkout).
///
/// **Contracts stay code.** Nothing here can change a dependency pin, a
/// manifest digest, the trust root, ADR-016's insertion tier order, the
/// pasteboard rule, the secure-field refusal, or the diagnostics rule: those
/// are not fields, so no JSON edit can weaken a P0.
/// `DeveloperDefaultsTests.testNoContractIsATunable` asserts the key list
/// against `forbiddenKeyWords`. A JSON value outside `validationBounds`
/// is refused as a whole file (`validationFailure`) rather than clamped, so a
/// typo cannot silently run the app at −1000 dBFS.
///
/// **Adding a tunable:** a field with its compiled value in the memberwise
/// `init`, a `CodingKeys` case, the `decodeIfPresent` line, the key in the
/// bundled JSON, a bound in `validationBounds` if the value has one, and —
/// when the user layer or the environment clamps it — a row in
/// `SettingsResolver`. `testEveryKeyDecodesWhenMissing` covers the decode
/// automatically because it iterates `CodingKeys.allCases`.
public struct DeveloperDefaults: Codable, Sendable, Equatable {
    // MARK: Speech gate (`SpeechGate.Thresholds`)

    /// Below this peak the recording is treated as silence (FR-AUD-008).
    public var silencePeakThresholdDBFS: Float
    /// Below this peak a transcript matching a known hallucination is dropped.
    public var quietPeakThresholdDBFS: Float
    /// A tap buffer at or below this carried no signal (the recorder's
    /// leading-silence drop; the controller's start cue and timing stamp).
    public var signalPeakThresholdDBFS: Float
    /// Silence kept after the last audible frame when the tail is trimmed.
    public var trailingSilenceKeepSeconds: Double

    // MARK: Dictionary (ADR-018)

    /// The share of the prompt-token cap held back from the budget.
    public var dictionaryReserveFraction: Double

    // MARK: Triggers

    /// Key-up within this window after key-down is a tap in Hybrid mode.
    public var hybridTapWindowMilliseconds: Int
    /// Two key-downs within this window arm auto-send.
    public var doublePressWindowMilliseconds: Int

    // MARK: HUD exit timings (D.4, `HUDDismissTimings`)

    public var hudSuccessDismissMilliseconds: Int
    public var hudDurationCapDismissMilliseconds: Int
    public var hudAIFallbackDismissMilliseconds: Int
    public var hudTextCopiedDismissMilliseconds: Int
    public var hudBlockedDismissMilliseconds: Int
    public var hudFailureDismissMilliseconds: Int

    // MARK: Accessibility insertion

    /// Polls after the Electron/Chromium handshake before giving up on a
    /// focused element (`AXTargetResolver`).
    public var axFocusRetryCount: Int
    public var axFocusRetryDelayMilliseconds: Int
    /// Pause between typed chunks in the ADR-016 third tier.
    public var typedChunkPacingMilliseconds: Int

    // MARK: Runtime card expectations (`RuntimeExpectations`)

    /// Real-time factor at or below which a run is judged to be on the
    /// expected device, per compute-unit choice.
    public var expectedRealTimeFactorNeuralEngine: Double
    public var expectedRealTimeFactorGPU: Double
    public var expectedRealTimeFactorCPU: Double

    // MARK: Settings backup

    /// How many automatic pre-import backups are kept.
    public var automaticBackupRetentionCount: Int

    // MARK: Overlapping jobs (ADR-022 item 7; slice 6 consumes the value)

    /// Ships off until verified on screen. Even when on, `SettingsResolver`
    /// turns it off under memory pressure, on CPU-only compute, or when the
    /// last measured real-time factor exceeds
    /// `overlappingJobsRealTimeFactorCeiling`.
    public var overlappingJobs: Bool
    public var overlappingJobsRealTimeFactorCeiling: Double

    /// The values compiled into the app. `kvoice.defaults.json` must equal
    /// this (tested).
    public static let compiled = DeveloperDefaults()

    public init(
        silencePeakThresholdDBFS: Float = -45,
        quietPeakThresholdDBFS: Float = -28,
        signalPeakThresholdDBFS: Float = -100,
        trailingSilenceKeepSeconds: Double = 0.4,
        dictionaryReserveFraction: Double = 0.10,
        hybridTapWindowMilliseconds: Int = 250,
        doublePressWindowMilliseconds: Int = 400,
        hudSuccessDismissMilliseconds: Int = 900,
        hudDurationCapDismissMilliseconds: Int = 3_500,
        hudAIFallbackDismissMilliseconds: Int = 2_500,
        hudTextCopiedDismissMilliseconds: Int = 3_500,
        hudBlockedDismissMilliseconds: Int = 3_500,
        hudFailureDismissMilliseconds: Int = 3_500,
        axFocusRetryCount: Int = 4,
        axFocusRetryDelayMilliseconds: Int = 60,
        typedChunkPacingMilliseconds: Int = 2,
        expectedRealTimeFactorNeuralEngine: Double = 0.35,
        expectedRealTimeFactorGPU: Double = 0.90,
        expectedRealTimeFactorCPU: Double = 15.0,
        automaticBackupRetentionCount: Int = 5,
        overlappingJobs: Bool = false,
        overlappingJobsRealTimeFactorCeiling: Double = 0.5
    ) {
        self.silencePeakThresholdDBFS = silencePeakThresholdDBFS
        self.quietPeakThresholdDBFS = quietPeakThresholdDBFS
        self.signalPeakThresholdDBFS = signalPeakThresholdDBFS
        self.trailingSilenceKeepSeconds = trailingSilenceKeepSeconds
        self.dictionaryReserveFraction = dictionaryReserveFraction
        self.hybridTapWindowMilliseconds = hybridTapWindowMilliseconds
        self.doublePressWindowMilliseconds = doublePressWindowMilliseconds
        self.hudSuccessDismissMilliseconds = hudSuccessDismissMilliseconds
        self.hudDurationCapDismissMilliseconds = hudDurationCapDismissMilliseconds
        self.hudAIFallbackDismissMilliseconds = hudAIFallbackDismissMilliseconds
        self.hudTextCopiedDismissMilliseconds = hudTextCopiedDismissMilliseconds
        self.hudBlockedDismissMilliseconds = hudBlockedDismissMilliseconds
        self.hudFailureDismissMilliseconds = hudFailureDismissMilliseconds
        self.axFocusRetryCount = axFocusRetryCount
        self.axFocusRetryDelayMilliseconds = axFocusRetryDelayMilliseconds
        self.typedChunkPacingMilliseconds = typedChunkPacingMilliseconds
        self.expectedRealTimeFactorNeuralEngine = expectedRealTimeFactorNeuralEngine
        self.expectedRealTimeFactorGPU = expectedRealTimeFactorGPU
        self.expectedRealTimeFactorCPU = expectedRealTimeFactorCPU
        self.automaticBackupRetentionCount = automaticBackupRetentionCount
        self.overlappingJobs = overlappingJobs
        self.overlappingJobsRealTimeFactorCeiling = overlappingJobsRealTimeFactorCeiling
    }

    // MARK: Coding

    /// `CaseIterable` so the tests and the loader can enumerate every key
    /// without a second hand-kept list.
    public enum CodingKeys: String, CodingKey, CaseIterable, Sendable {
        case silencePeakThresholdDBFS
        case quietPeakThresholdDBFS
        case signalPeakThresholdDBFS
        case trailingSilenceKeepSeconds
        case dictionaryReserveFraction
        case hybridTapWindowMilliseconds
        case doublePressWindowMilliseconds
        case hudSuccessDismissMilliseconds
        case hudDurationCapDismissMilliseconds
        case hudAIFallbackDismissMilliseconds
        case hudTextCopiedDismissMilliseconds
        case hudBlockedDismissMilliseconds
        case hudFailureDismissMilliseconds
        case axFocusRetryCount
        case axFocusRetryDelayMilliseconds
        case typedChunkPacingMilliseconds
        case expectedRealTimeFactorNeuralEngine
        case expectedRealTimeFactorGPU
        case expectedRealTimeFactorCPU
        case automaticBackupRetentionCount
        case overlappingJobs
        case overlappingJobsRealTimeFactorCeiling
    }

    /// Every JSON key, in declaration order.
    public static var keys: [String] { CodingKeys.allCases.map(\.rawValue) }

    /// Every key decodes `decodeIfPresent ?? compiled` (ADR-022 item 1):
    /// an older or partial file never fails a build or a launch.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let compiled = Self.compiled
        silencePeakThresholdDBFS = try values.decodeIfPresent(Float.self, forKey: .silencePeakThresholdDBFS) ?? compiled.silencePeakThresholdDBFS
        quietPeakThresholdDBFS = try values.decodeIfPresent(Float.self, forKey: .quietPeakThresholdDBFS) ?? compiled.quietPeakThresholdDBFS
        signalPeakThresholdDBFS = try values.decodeIfPresent(Float.self, forKey: .signalPeakThresholdDBFS) ?? compiled.signalPeakThresholdDBFS
        trailingSilenceKeepSeconds = try values.decodeIfPresent(Double.self, forKey: .trailingSilenceKeepSeconds) ?? compiled.trailingSilenceKeepSeconds
        dictionaryReserveFraction = try values.decodeIfPresent(Double.self, forKey: .dictionaryReserveFraction) ?? compiled.dictionaryReserveFraction
        hybridTapWindowMilliseconds = try values.decodeIfPresent(Int.self, forKey: .hybridTapWindowMilliseconds) ?? compiled.hybridTapWindowMilliseconds
        doublePressWindowMilliseconds = try values.decodeIfPresent(Int.self, forKey: .doublePressWindowMilliseconds) ?? compiled.doublePressWindowMilliseconds
        hudSuccessDismissMilliseconds = try values.decodeIfPresent(Int.self, forKey: .hudSuccessDismissMilliseconds) ?? compiled.hudSuccessDismissMilliseconds
        hudDurationCapDismissMilliseconds = try values.decodeIfPresent(Int.self, forKey: .hudDurationCapDismissMilliseconds) ?? compiled.hudDurationCapDismissMilliseconds
        hudAIFallbackDismissMilliseconds = try values.decodeIfPresent(Int.self, forKey: .hudAIFallbackDismissMilliseconds) ?? compiled.hudAIFallbackDismissMilliseconds
        hudTextCopiedDismissMilliseconds = try values.decodeIfPresent(Int.self, forKey: .hudTextCopiedDismissMilliseconds) ?? compiled.hudTextCopiedDismissMilliseconds
        hudBlockedDismissMilliseconds = try values.decodeIfPresent(Int.self, forKey: .hudBlockedDismissMilliseconds) ?? compiled.hudBlockedDismissMilliseconds
        hudFailureDismissMilliseconds = try values.decodeIfPresent(Int.self, forKey: .hudFailureDismissMilliseconds) ?? compiled.hudFailureDismissMilliseconds
        axFocusRetryCount = try values.decodeIfPresent(Int.self, forKey: .axFocusRetryCount) ?? compiled.axFocusRetryCount
        axFocusRetryDelayMilliseconds = try values.decodeIfPresent(Int.self, forKey: .axFocusRetryDelayMilliseconds) ?? compiled.axFocusRetryDelayMilliseconds
        typedChunkPacingMilliseconds = try values.decodeIfPresent(Int.self, forKey: .typedChunkPacingMilliseconds) ?? compiled.typedChunkPacingMilliseconds
        expectedRealTimeFactorNeuralEngine = try values.decodeIfPresent(Double.self, forKey: .expectedRealTimeFactorNeuralEngine) ?? compiled.expectedRealTimeFactorNeuralEngine
        expectedRealTimeFactorGPU = try values.decodeIfPresent(Double.self, forKey: .expectedRealTimeFactorGPU) ?? compiled.expectedRealTimeFactorGPU
        expectedRealTimeFactorCPU = try values.decodeIfPresent(Double.self, forKey: .expectedRealTimeFactorCPU) ?? compiled.expectedRealTimeFactorCPU
        automaticBackupRetentionCount = try values.decodeIfPresent(Int.self, forKey: .automaticBackupRetentionCount) ?? compiled.automaticBackupRetentionCount
        overlappingJobs = try values.decodeIfPresent(Bool.self, forKey: .overlappingJobs) ?? compiled.overlappingJobs
        overlappingJobsRealTimeFactorCeiling = try values.decodeIfPresent(Double.self, forKey: .overlappingJobsRealTimeFactorCeiling) ?? compiled.overlappingJobsRealTimeFactorCeiling
    }

    // MARK: Validation

    /// The range each numeric key must fall in. A file with a value outside
    /// its bound is refused whole (the loader logs `config.override.rejected`
    /// with `site` = the key) rather than clamped: a developer who typed
    /// `-1000` meant something and should find out, and a partially applied
    /// override is harder to reason about than none.
    public static let validationBounds: [CodingKeys: ClosedRange<Double>] = [
        .silencePeakThresholdDBFS: -160...0,
        .quietPeakThresholdDBFS: -160...0,
        .signalPeakThresholdDBFS: -160...0,
        .trailingSilenceKeepSeconds: 0...5,
        .dictionaryReserveFraction: 0...0.9,
        .hybridTapWindowMilliseconds: 0...2_000,
        .doublePressWindowMilliseconds: 0...2_000,
        .hudSuccessDismissMilliseconds: 100...30_000,
        .hudDurationCapDismissMilliseconds: 100...30_000,
        .hudAIFallbackDismissMilliseconds: 100...30_000,
        .hudTextCopiedDismissMilliseconds: 100...30_000,
        .hudBlockedDismissMilliseconds: 100...30_000,
        .hudFailureDismissMilliseconds: 100...30_000,
        .axFocusRetryCount: 0...50,
        .axFocusRetryDelayMilliseconds: 0...2_000,
        .typedChunkPacingMilliseconds: 0...500,
        .expectedRealTimeFactorNeuralEngine: 0.01...100,
        .expectedRealTimeFactorGPU: 0.01...100,
        .expectedRealTimeFactorCPU: 0.01...100,
        .automaticBackupRetentionCount: 1...100,
        .overlappingJobsRealTimeFactorCeiling: 0.01...100
    ]

    /// The first key whose value is outside `validationBounds`, or nil when
    /// every value is sane. `quietPeakThresholdDBFS` must also sit above
    /// `silencePeakThresholdDBFS`: the quiet gate is meant to catch what the
    /// silence gate let through.
    public var validationFailure: CodingKeys? {
        for key in CodingKeys.allCases {
            guard let bounds = Self.validationBounds[key], let value = numericValue(for: key) else { continue }
            guard value.isFinite, bounds.contains(value) else { return key }
        }
        if quietPeakThresholdDBFS < silencePeakThresholdDBFS { return .quietPeakThresholdDBFS }
        return nil
    }

    private func numericValue(for key: CodingKeys) -> Double? {
        switch key {
        case .silencePeakThresholdDBFS: return Double(silencePeakThresholdDBFS)
        case .quietPeakThresholdDBFS: return Double(quietPeakThresholdDBFS)
        case .signalPeakThresholdDBFS: return Double(signalPeakThresholdDBFS)
        case .trailingSilenceKeepSeconds: return trailingSilenceKeepSeconds
        case .dictionaryReserveFraction: return dictionaryReserveFraction
        case .hybridTapWindowMilliseconds: return Double(hybridTapWindowMilliseconds)
        case .doublePressWindowMilliseconds: return Double(doublePressWindowMilliseconds)
        case .hudSuccessDismissMilliseconds: return Double(hudSuccessDismissMilliseconds)
        case .hudDurationCapDismissMilliseconds: return Double(hudDurationCapDismissMilliseconds)
        case .hudAIFallbackDismissMilliseconds: return Double(hudAIFallbackDismissMilliseconds)
        case .hudTextCopiedDismissMilliseconds: return Double(hudTextCopiedDismissMilliseconds)
        case .hudBlockedDismissMilliseconds: return Double(hudBlockedDismissMilliseconds)
        case .hudFailureDismissMilliseconds: return Double(hudFailureDismissMilliseconds)
        case .axFocusRetryCount: return Double(axFocusRetryCount)
        case .axFocusRetryDelayMilliseconds: return Double(axFocusRetryDelayMilliseconds)
        case .typedChunkPacingMilliseconds: return Double(typedChunkPacingMilliseconds)
        case .expectedRealTimeFactorNeuralEngine: return expectedRealTimeFactorNeuralEngine
        case .expectedRealTimeFactorGPU: return expectedRealTimeFactorGPU
        case .expectedRealTimeFactorCPU: return expectedRealTimeFactorCPU
        case .automaticBackupRetentionCount: return Double(automaticBackupRetentionCount)
        case .overlappingJobs: return nil
        case .overlappingJobsRealTimeFactorCeiling: return overlappingJobsRealTimeFactorCeiling
        }
    }

    // MARK: Contracts stay code

    /// Words no key may contain (a key is split on its camelCase humps, so
    /// "overlappingJobs" does not match "pin"). The contracts these name —
    /// dependency pins, manifest digests, the trust root, ADR-016's tier
    /// order and pasteboard rule, the secure-field refusal, the diagnostics
    /// rule — are code and tests, never configuration.
    /// `DeveloperDefaultsTests.testNoContractIsATunable` checks `keys`.
    public static let forbiddenKeyWords: Set<String> = [
        "pin", "pins", "version", "digest", "digests", "sha", "sha256", "hash", "manifest",
        "trust", "trusted", "anchor", "tier", "tiers", "paste", "pasteboard", "clipboard",
        "secure", "diagnostic", "diagnostics", "log", "secret", "secrets", "key", "keys", "apikey",
        "token", "url", "host", "endpoint"
    ]

    /// The camelCase words of a key, lowercased ("axFocusRetryCount" →
    /// ["ax", "focus", "retry", "count"]; "DBFS" stays one word).
    public static func words(in key: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousWasUpper = false
        for character in key {
            let isUpper = character.isUppercase
            if isUpper, !current.isEmpty, !previousWasUpper {
                words.append(current.lowercased())
                current = ""
            }
            current.append(character)
            previousWasUpper = isUpper
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    // MARK: Derived views the consumers take

    public var speechGate: SpeechGate.Thresholds {
        SpeechGate.Thresholds(
            silencePeakDBFS: silencePeakThresholdDBFS,
            quietPeakDBFS: quietPeakThresholdDBFS,
            signalPeakDBFS: signalPeakThresholdDBFS,
            trailingSilenceKeepSeconds: trailingSilenceKeepSeconds
        )
    }

    public var hudDismissTimings: HUDDismissTimings {
        HUDDismissTimings(
            success: .milliseconds(hudSuccessDismissMilliseconds),
            durationCapReached: .milliseconds(hudDurationCapDismissMilliseconds),
            aiFallback: .milliseconds(hudAIFallbackDismissMilliseconds),
            clipboardFallback: .milliseconds(hudTextCopiedDismissMilliseconds),
            blocked: .milliseconds(hudBlockedDismissMilliseconds),
            failure: .milliseconds(hudFailureDismissMilliseconds)
        )
    }

    public var runtimeExpectations: RuntimeExpectations {
        RuntimeExpectations(
            neuralEngine: expectedRealTimeFactorNeuralEngine,
            gpu: expectedRealTimeFactorGPU,
            cpu: expectedRealTimeFactorCPU
        )
    }

    public var hybridTapWindow: Duration { .milliseconds(hybridTapWindowMilliseconds) }
    public var doublePressWindow: Duration { .milliseconds(doublePressWindowMilliseconds) }
    public var axFocusRetryDelay: Duration { .milliseconds(axFocusRetryDelayMilliseconds) }
    public var typedChunkPacing: Duration { .milliseconds(typedChunkPacingMilliseconds) }
}

/// D.4 exit timings for the HUD's non-modal terminal states (FR-HUD-005).
/// Lives in the domain so `DeveloperDefaults` can build it; `HUDViewState`
/// (KvoiceUI) reads it.
public struct HUDDismissTimings: Sendable, Equatable {
    public var success: Duration
    public var durationCapReached: Duration
    public var aiFallback: Duration
    public var clipboardFallback: Duration
    public var blocked: Duration
    public var failure: Duration

    public init(
        success: Duration,
        durationCapReached: Duration,
        aiFallback: Duration,
        clipboardFallback: Duration,
        blocked: Duration,
        failure: Duration
    ) {
        self.success = success
        self.durationCapReached = durationCapReached
        self.aiFallback = aiFallback
        self.clipboardFallback = clipboardFallback
        self.blocked = blocked
        self.failure = failure
    }

    public static let compiled = DeveloperDefaults.compiled.hudDismissTimings
}

/// The Runtime card's per-choice real-time-factor thresholds, measured on
/// the reference machine (`RuntimeExpectation` in KvoiceUI has the table).
public struct RuntimeExpectations: Sendable, Equatable {
    public var neuralEngine: Double
    public var gpu: Double
    public var cpu: Double

    public init(neuralEngine: Double, gpu: Double, cpu: Double) {
        self.neuralEngine = neuralEngine
        self.gpu = gpu
        self.cpu = cpu
    }

    public static let compiled = DeveloperDefaults.compiled.runtimeExpectations

    /// Real-time factor at or below which the run is judged to be on the
    /// expected device.
    public func expectedMaximumRealTimeFactor(for units: SpeechComputeUnits) -> Double {
        switch units {
        case .neuralEngineAndCPU, .all: return neuralEngine
        case .gpuAndCPU: return gpu
        case .cpuOnly: return cpu
        }
    }
}

/// The developer-defaults layer as loaded at launch (ADR-022 slice 5):
/// the merged values, which keys the override file changed, and what
/// happened to that file — so the shell can log it and a report can list
/// it, without any consumer re-reading a file.
public struct LoadedDeveloperDefaults: Sendable, Equatable {
    /// What happened to `config.override.json`.
    public enum OverrideOutcome: Sendable, Equatable {
        /// No file at the override path — the normal case.
        case absent
        /// Read and applied; the keys it named.
        case applied([DeveloperDefaults.CodingKeys])
        /// Present but ignored whole. The reason is a scalar token; the
        /// key is set for `outOfRange`.
        case rejected(reason: RejectionReason, key: DeveloperDefaults.CodingKeys?)
    }

    public enum RejectionReason: String, Sendable, Equatable {
        case unreadable
        case notAnObject
        case malformed
        case outOfRange
    }

    public var values: DeveloperDefaults
    public var overrideOutcome: OverrideOutcome

    public init(values: DeveloperDefaults, overrideOutcome: OverrideOutcome) {
        self.values = values
        self.overrideOutcome = overrideOutcome
    }

    /// Nothing overridden, nothing on disk.
    public static let compiled = LoadedDeveloperDefaults(values: .compiled, overrideOutcome: .absent)

    /// `.override` for a key the file changed, `.default` otherwise.
    public func provenance(of key: DeveloperDefaults.CodingKeys) -> Provenance {
        if case .applied(let keys) = overrideOutcome, keys.contains(key) { return .override }
        return .default
    }

    /// The keys the override changed, in the file's key order — empty
    /// unless the file was applied.
    public var overriddenKeys: [DeveloperDefaults.CodingKeys] {
        if case .applied(let keys) = overrideOutcome { return keys }
        return []
    }
}
