import Foundation

/// Where an effective value came from (ADR-022 item 2). Every value
/// `SettingsResolver` returns carries one, so a page can say "changed from
/// default" (`.user`), "using the engine's 111-token cap"
/// (`.limitedBy("engine prompt cap")`), or nothing at all (`.default`).
/// `DeveloperDefaultsLoader` uses the same type for the developer layer's
/// two possibilities (`.default` from the bundled JSON / compiled value,
/// `.override` from the developer's override file).
public enum Provenance: Sendable, Equatable, Hashable {
    /// The user set it (`AppSettings` differs from the developer default).
    case user
    /// The compiled / bundled developer default.
    case `default`
    /// The developer override file changed it.
    case override
    /// The environment clamped it; the string names the observed fact and
    /// is a scalar token, never a value or a path.
    case limitedBy(String)

    /// Scalar name for diagnostics and tests.
    public var name: String {
        switch self {
        case .user: return "user"
        case .default: return "default"
        case .override: return "override"
        case .limitedBy: return "limitedBy"
        }
    }
}

/// One effective value with where it came from.
public struct Resolved<Value: Sendable & Equatable>: Sendable, Equatable {
    public let value: Value
    public let provenance: Provenance

    public init(_ value: Value, _ provenance: Provenance) {
        self.value = value
        self.provenance = provenance
    }

    /// The page's "changed from default" affordance: the user set it.
    public var isChangedFromDefault: Bool { provenance == .user }

    /// The page's "using the engine's N-token cap" footnote: the fact name.
    public var limitingFact: String? {
        if case .limitedBy(let fact) = provenance { return fact }
        return nil
    }
}

/// What the app actually runs with, per tunable, each with its provenance
/// (ADR-022 item 2). Two kinds of row:
///
/// - **User-layer** rows (`maxRecordingSeconds` … `interfaceLanguage`): the
///   preference the user set, `.user` when it differs from the compiled
///   default of `AppSettings`, `.default` otherwise. These are the rows the
///   pages decorate with "changed from default" and Reset.
/// - **Developer-only** rows (`speechGate` … `overlappingJobs`): no field
///   in `AppSettings` can reach them — that is how "the user layer cannot
///   override safety behaviour" is enforced, by construction rather than by
///   a check (`SettingsResolverTests.testUserLayerCannotReachDeveloperOnlyRows`).
///   Their provenance is `.default` or `.override` (the developer's file),
///   or `.limitedBy(fact)` when the environment clamped them.
public struct EffectiveSettings: Sendable, Equatable {
    // MARK: User layer (pages show "changed from default" / Reset)

    public var maxRecordingSeconds: Resolved<Int>
    public var recordingFeedback: Resolved<RecordingFeedbackSettings>
    public var recorderStyle: Resolved<HUDStyle>
    public var addSpaceAfterInsertion: Resolved<Bool>
    public var automaticTextFormatting: Resolved<Bool>
    public var typedInsertionEnabled: Resolved<Bool>
    public var triggers: Resolved<TriggerSettings>
    public var voiceActivityDetectionEnabled: Resolved<Bool>
    public var speechComputeUnits: Resolved<SpeechComputeUnits>
    public var freeModelMemoryUnderCriticalPressure: Resolved<Bool>
    public var interfaceLanguage: Resolved<InterfaceLanguage>

    // MARK: Environment-clamped

    /// The Dictionary budget: `nil` when the resident model takes no prompt
    /// (or nothing is known); `.limitedBy("engine prompt cap")` when the
    /// resident runtime enforces less than the catalog's number.
    public var dictionaryTokenBudget: Resolved<DictionaryTokenBudget?>
    /// ADR-022 item 7: the developer flag, forced off — `.limitedBy` naming
    /// the fact — under memory pressure, on CPU-only compute, or above the
    /// real-time-factor ceiling. Slice 6 reads the value; nothing else.
    public var overlappingJobs: Resolved<Bool>

    // MARK: Developer only (pass-through with provenance)

    public var speechGate: Resolved<SpeechGate.Thresholds>
    public var hudDismissTimings: Resolved<HUDDismissTimings>
    public var runtimeExpectations: Resolved<RuntimeExpectations>
    public var hybridTapWindow: Resolved<Duration>
    public var doublePressWindow: Resolved<Duration>
    public var dictionaryReserveFraction: Resolved<Double>
    public var axFocusRetryCount: Resolved<Int>
    public var axFocusRetryDelay: Resolved<Duration>
    public var typedChunkPacing: Resolved<Duration>
    public var automaticBackupRetentionCount: Resolved<Int>

    /// Whether the user-layer row a page can reset differs from its
    /// compiled default — the resolver's `.user` answer by row.
    public func isChangedFromDefault(_ row: ResettableSetting) -> Bool {
        switch row {
        case .maxRecordingSeconds: return maxRecordingSeconds.isChangedFromDefault
        case .recordingFeedback: return recordingFeedback.isChangedFromDefault
        case .recorderStyle: return recorderStyle.isChangedFromDefault
        case .addSpaceAfterInsertion: return addSpaceAfterInsertion.isChangedFromDefault
        case .automaticTextFormatting: return automaticTextFormatting.isChangedFromDefault
        case .typedInsertionEnabled: return typedInsertionEnabled.isChangedFromDefault
        case .triggers: return triggers.isChangedFromDefault
        case .freeModelMemoryUnderCriticalPressure: return freeModelMemoryUnderCriticalPressure.isChangedFromDefault
        }
    }

    /// The rows currently changed from default, for the pages.
    public var changedFromDefault: Set<ResettableSetting> {
        Set(ResettableSetting.allCases.filter(isChangedFromDefault))
    }

    /// The resident engine's prompt cap when it limits the Dictionary budget
    /// below the catalog's number (`dictionaryTokenBudget.limitingFact ==
    /// .enginePromptCapFact`); `nil` otherwise, including when there is no
    /// prompt budget at all. `DictionarySectionView`'s footer says so.
    public var dictionaryBudgetEngineCap: Int? {
        guard dictionaryTokenBudget.limitingFact == SettingsResolver.enginePromptCapFact else { return nil }
        return dictionaryTokenBudget.value?.promptTokenLimit
    }
}

/// The user-layer settings a page offers "Reset to default" for (ADR-022
/// slice 5). One case per `EffectiveSettings` user-layer row that a page
/// renders with the affordance; `SettingsIntent.resetToDefault` carries
/// one, and the reducer writes the compiled `AppSettings` default for it.
/// Not here on purpose: `speechComputeUnits` (a reset reloads the model —
/// the Runtime card's picker is the one door), `voiceActivityDetectionEnabled`
/// (the Manage Models gear has no row chrome), and `interfaceLanguage`
/// (its reset is the picker's "System" entry with the relaunch consent).
public enum ResettableSetting: String, CaseIterable, Sendable, Equatable {
    case maxRecordingSeconds
    case recordingFeedback
    case recorderStyle
    case addSpaceAfterInsertion
    case automaticTextFormatting
    case typedInsertionEnabled
    case triggers
    case freeModelMemoryUnderCriticalPressure

    /// Writes the compiled default for this row into `settings`.
    public func reset(in settings: inout AppSettings) {
        let defaults = AppSettings()
        switch self {
        case .maxRecordingSeconds: settings.maxRecordingSeconds = defaults.maxRecordingSeconds
        case .recordingFeedback: settings.recordingFeedback = defaults.recordingFeedback
        case .recorderStyle: settings.recorderStyle = defaults.recorderStyle
        case .addSpaceAfterInsertion: settings.addSpaceAfterInsertion = defaults.addSpaceAfterInsertion
        case .automaticTextFormatting: settings.automaticTextFormatting = defaults.automaticTextFormatting
        case .typedInsertionEnabled: settings.typedInsertionEnabled = defaults.typedInsertionEnabled
        case .triggers: settings.triggers = defaults.triggers
        case .freeModelMemoryUnderCriticalPressure:
            settings.freeModelMemoryUnderCriticalPressure = defaults.freeModelMemoryUnderCriticalPressure
        }
    }

    /// Whether `settings` differs from the compiled default in this row —
    /// the same answer `SettingsResolver` gives as `.user`.
    public func isChangedFromDefault(in settings: AppSettings) -> Bool {
        var reset = settings
        self.reset(in: &reset)
        return reset != settings
    }

    /// The rows that travel in `TriggerSettingsSnapshot` (the Shortcuts &
    /// Triggers and Recording pages' block): a reset of one of these is the
    /// `setTriggers` row's effects, and `typedInsertionEnabled` /
    /// `freeModelMemoryUnderCriticalPressure` are the General model's.
    public var isTriggerSnapshotRow: Bool {
        switch self {
        case .maxRecordingSeconds, .recordingFeedback, .recorderStyle, .addSpaceAfterInsertion,
             .automaticTextFormatting, .triggers:
            return true
        case .typedInsertionEnabled, .freeModelMemoryUnderCriticalPressure:
            return false
        }
    }
}

/// ADR-022 item 2: `effective = user ?? developer`, clamped and validated
/// against the environment, every value with its provenance. Pure and
/// table-tested (`SettingsResolverTests`); the shell recomputes it after
/// every intent and on the slow poll, the pages read the rows they show.
///
/// The user layer has no optional fields, so `user ?? developer` reduces to
/// "the user's value, labelled `.user` when it differs from the compiled
/// `AppSettings` default". The developer layer's provenance comes from
/// `overriddenKeys` (what the override file changed, per
/// `LoadedDeveloperDefaults`). The rows the environment clamps:
///
/// | Row | Fact | Provenance |
/// | --- | --- | --- |
/// | `maxRecordingSeconds` | above the four-hour technical ceiling | `.limitedBy("technical ceiling")` |
/// | `dictionaryTokenBudget` | resident engine cap below the catalog's | `.limitedBy("engine prompt cap")` |
/// | `overlappingJobs` | memory pressure ≥ warning | `.limitedBy("memory pressure")` |
/// | `overlappingJobs` | compute units CPU only | `.limitedBy("cpu-only compute")` |
/// | `overlappingJobs` | last RTF > ceiling | `.limitedBy("real-time factor")` |
///
/// Adding a row: a field on `EffectiveSettings`, a line in `resolve`, and a
/// row in `SettingsResolverTests`; a user-layer row also gets a
/// `ResettableSetting` case (which makes it resettable from a page).
public enum SettingsResolver {
    /// Words that name a safety rule (ADR-016's tiers and pasteboard rule,
    /// the secure-field refusal, the trust root, the diagnostics rule, the
    /// pins and digests). No `AppSettings` or `EffectiveSettings` field may
    /// be named with one — `SettingsResolverTests.testNoSafetyRuleIsAUserSetting`
    /// — which is how "the user layer cannot override safety behaviour" is
    /// kept structural. Narrower than `DeveloperDefaults.forbiddenKeyWords`
    /// because a user setting may legitimately mention a token budget or a
    /// schema version.
    public static let safetyRuleWords: Set<String> = [
        "secure", "paste", "pasteboard", "trust", "trusted", "tier", "tiers",
        "diagnostic", "diagnostics", "pin", "pins", "digest", "digests", "manifest",
        "anchor", "secret", "secrets", "apikey"
    ]

    public static let technicalCeilingFact = "technical ceiling"
    public static let enginePromptCapFact = "engine prompt cap"
    public static let memoryPressureFact = "memory pressure"
    public static let cpuOnlyComputeFact = "cpu-only compute"
    public static let realTimeFactorFact = "real-time factor"

    public static func resolve(
        user: AppSettings,
        defaults: DeveloperDefaults,
        environment: EnvironmentProfile,
        overriddenKeys: Set<DeveloperDefaults.CodingKeys> = []
    ) -> EffectiveSettings {
        let compiled = AppSettings()

        func userRow<Value: Sendable & Equatable>(_ value: Value, _ standard: Value) -> Resolved<Value> {
            Resolved(value, value == standard ? .default : .user)
        }
        func developerRow<Value: Sendable & Equatable>(_ value: Value, _ keys: DeveloperDefaults.CodingKeys...) -> Resolved<Value> {
            Resolved(value, keys.contains(where: overriddenKeys.contains) ? .override : .default)
        }

        // MARK: User layer

        let ceiling = RecordingDurationLimit.technicalCeilingSeconds
        let maxRecordingSeconds: Resolved<Int>
        if user.maxRecordingSeconds > ceiling {
            maxRecordingSeconds = Resolved(ceiling, .limitedBy(technicalCeilingFact))
        } else {
            maxRecordingSeconds = userRow(max(1, user.maxRecordingSeconds), compiled.maxRecordingSeconds)
        }

        // MARK: Dictionary budget (ADR-018 through the resolver)

        let budget = DictionaryTokenBudget.resolve(
            catalogLimit: environment.catalogPromptTokenLimit,
            residentLimit: environment.enginePromptTokenLimit,
            reserveFraction: defaults.dictionaryReserveFraction
        )
        let budgetProvenance: Provenance
        if let cap = environment.enginePromptTokenCap,
           let catalog = environment.catalogPromptTokenLimit, cap < catalog {
            budgetProvenance = .limitedBy(enginePromptCapFact)
        } else {
            budgetProvenance = overriddenKeys.contains(.dictionaryReserveFraction) ? .override : .default
        }

        // MARK: Overlapping jobs (ADR-022 item 7 — the value only)

        var overlapping = developerRow(defaults.overlappingJobs, .overlappingJobs)
        if overlapping.value {
            if environment.memoryPressureLevel >= .warning {
                overlapping = Resolved(false, .limitedBy(memoryPressureFact))
            } else if environment.computeUnits == .cpuOnly {
                overlapping = Resolved(false, .limitedBy(cpuOnlyComputeFact))
            } else if let rtf = environment.lastRealTimeFactor, rtf > defaults.overlappingJobsRealTimeFactorCeiling {
                overlapping = Resolved(false, .limitedBy(realTimeFactorFact))
            }
        }

        return EffectiveSettings(
            maxRecordingSeconds: maxRecordingSeconds,
            recordingFeedback: userRow(user.recordingFeedback, compiled.recordingFeedback),
            recorderStyle: userRow(user.recorderStyle, compiled.recorderStyle),
            addSpaceAfterInsertion: userRow(user.addSpaceAfterInsertion, compiled.addSpaceAfterInsertion),
            automaticTextFormatting: userRow(user.automaticTextFormatting, compiled.automaticTextFormatting),
            typedInsertionEnabled: userRow(user.typedInsertionEnabled, compiled.typedInsertionEnabled),
            triggers: userRow(user.triggers, compiled.triggers),
            voiceActivityDetectionEnabled: userRow(user.voiceActivityDetectionEnabled, compiled.voiceActivityDetectionEnabled),
            speechComputeUnits: userRow(user.speechComputeUnits, compiled.speechComputeUnits),
            freeModelMemoryUnderCriticalPressure: userRow(
                user.freeModelMemoryUnderCriticalPressure, compiled.freeModelMemoryUnderCriticalPressure
            ),
            interfaceLanguage: userRow(user.interfaceLanguage, compiled.interfaceLanguage),
            dictionaryTokenBudget: Resolved(budget, budgetProvenance),
            overlappingJobs: overlapping,
            speechGate: developerRow(
                defaults.speechGate,
                .silencePeakThresholdDBFS, .quietPeakThresholdDBFS, .signalPeakThresholdDBFS, .trailingSilenceKeepSeconds
            ),
            hudDismissTimings: developerRow(
                defaults.hudDismissTimings,
                .hudSuccessDismissMilliseconds, .hudDurationCapDismissMilliseconds, .hudAIFallbackDismissMilliseconds,
                .hudTextCopiedDismissMilliseconds, .hudBlockedDismissMilliseconds, .hudFailureDismissMilliseconds
            ),
            runtimeExpectations: developerRow(
                defaults.runtimeExpectations,
                .expectedRealTimeFactorNeuralEngine, .expectedRealTimeFactorGPU, .expectedRealTimeFactorCPU
            ),
            hybridTapWindow: developerRow(defaults.hybridTapWindow, .hybridTapWindowMilliseconds),
            doublePressWindow: developerRow(defaults.doublePressWindow, .doublePressWindowMilliseconds),
            dictionaryReserveFraction: developerRow(defaults.dictionaryReserveFraction, .dictionaryReserveFraction),
            axFocusRetryCount: developerRow(defaults.axFocusRetryCount, .axFocusRetryCount),
            axFocusRetryDelay: developerRow(defaults.axFocusRetryDelay, .axFocusRetryDelayMilliseconds),
            typedChunkPacing: developerRow(defaults.typedChunkPacing, .typedChunkPacingMilliseconds),
            automaticBackupRetentionCount: developerRow(defaults.automaticBackupRetentionCount, .automaticBackupRetentionCount)
        )
    }
}

/// ADR-022 item 7: why the environment profile turned `overlappingJobs` off
/// while the developer flag is on — the three facts `SettingsResolver`
/// names, as one scalar the HUD note, the status menu and the
/// `dictation.overlap.refused` line share (`reason: limitedBy:<case>`).
public enum OverlapPauseReason: String, Sendable, Equatable, Hashable, CaseIterable {
    case memoryPressure
    case cpuOnlyCompute
    case slowTranscription

    /// The resolver's `.limitedBy(fact)` string for this reason.
    public var limitingFact: String {
        switch self {
        case .memoryPressure: return SettingsResolver.memoryPressureFact
        case .cpuOnlyCompute: return SettingsResolver.cpuOnlyComputeFact
        case .slowTranscription: return SettingsResolver.realTimeFactorFact
        }
    }

    public init?(limitingFact: String) {
        guard let match = Self.allCases.first(where: { $0.limitingFact == limitingFact }) else { return nil }
        self = match
    }
}
