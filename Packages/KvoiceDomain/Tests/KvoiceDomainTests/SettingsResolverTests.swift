import XCTest
@testable import KvoiceDomain

/// ADR-022 item 2: `effective = user ?? developer`, clamped by the
/// environment, every value with a provenance. One row per rule.
final class SettingsResolverTests: XCTestCase {
    private func resolve(
        user: AppSettings = AppSettings(),
        defaults: DeveloperDefaults = .compiled,
        environment: EnvironmentProfile = .unknown,
        overridden: Set<DeveloperDefaults.CodingKeys> = []
    ) -> EffectiveSettings {
        SettingsResolver.resolve(user: user, defaults: defaults, environment: environment, overriddenKeys: overridden)
    }

    // MARK: User layer

    func testCompiledDefaultsAreAllDefaultProvenance() {
        let effective = resolve()
        XCTAssertEqual(effective.maxRecordingSeconds, Resolved(600, .default))
        XCTAssertEqual(effective.recordingFeedback.provenance, .default)
        XCTAssertEqual(effective.recorderStyle, Resolved(.mini, .default))
        XCTAssertEqual(effective.addSpaceAfterInsertion.provenance, .default)
        XCTAssertEqual(effective.automaticTextFormatting.provenance, .default)
        XCTAssertEqual(effective.typedInsertionEnabled, Resolved(true, .default))
        XCTAssertEqual(effective.triggers.provenance, .default)
        XCTAssertEqual(effective.voiceActivityDetectionEnabled.provenance, .default)
        XCTAssertEqual(effective.speechComputeUnits.provenance, .default)
        XCTAssertEqual(effective.freeModelMemoryUnderCriticalPressure.provenance, .default)
        XCTAssertEqual(effective.interfaceLanguage.provenance, .default)
        XCTAssertEqual(effective.overlappingJobs, Resolved(false, .default))
        XCTAssertEqual(effective.speechGate, Resolved(.compiled, .default))
        XCTAssertEqual(effective.hudDismissTimings, Resolved(.compiled, .default))
        XCTAssertEqual(effective.runtimeExpectations, Resolved(.compiled, .default))
        XCTAssertEqual(effective.hybridTapWindow, Resolved(.milliseconds(250), .default))
        XCTAssertEqual(effective.doublePressWindow, Resolved(.milliseconds(400), .default))
        XCTAssertEqual(effective.dictionaryReserveFraction, Resolved(0.10, .default))
        XCTAssertEqual(effective.axFocusRetryCount, Resolved(4, .default))
        XCTAssertEqual(effective.axFocusRetryDelay, Resolved(.milliseconds(60), .default))
        XCTAssertEqual(effective.typedChunkPacing, Resolved(.milliseconds(2), .default))
        XCTAssertEqual(effective.automaticBackupRetentionCount, Resolved(5, .default))
        // No catalog, nothing resident: no budget, and nothing limited it.
        XCTAssertEqual(effective.dictionaryTokenBudget, Resolved(nil, .default))
    }

    func testAUserValueIsLabelledUserAndFlaggedChangedFromDefault() {
        var user = AppSettings()
        user.maxRecordingSeconds = 1_800
        user.recorderStyle = .notch
        user.recordingFeedback.soundFeedbackEnabled = false
        user.triggers.autoSendEnabled = true
        user.speechComputeUnits = .gpuAndCPU
        let effective = resolve(user: user)
        XCTAssertEqual(effective.maxRecordingSeconds, Resolved(1_800, .user))
        XCTAssertTrue(effective.maxRecordingSeconds.isChangedFromDefault)
        XCTAssertEqual(effective.recorderStyle, Resolved(.notch, .user))
        XCTAssertEqual(effective.recordingFeedback.provenance, .user)
        XCTAssertEqual(effective.triggers.provenance, .user)
        XCTAssertEqual(effective.speechComputeUnits, Resolved(.gpuAndCPU, .user))
        // Untouched rows stay default.
        XCTAssertEqual(effective.typedInsertionEnabled.provenance, .default)
        XCTAssertFalse(effective.typedInsertionEnabled.isChangedFromDefault)
    }

    func testResettableSettingsAgreeWithTheResolver() {
        var user = AppSettings()
        user.maxRecordingSeconds = 60
        user.automaticTextFormatting = true
        for row in ResettableSetting.allCases {
            let expected: Bool
            switch row {
            case .maxRecordingSeconds, .automaticTextFormatting: expected = true
            default: expected = false
            }
            XCTAssertEqual(row.isChangedFromDefault(in: user), expected, "\(row)")
            var reset = user
            row.reset(in: &reset)
            XCTAssertFalse(row.isChangedFromDefault(in: reset), "\(row) after reset")
        }
        // Resetting every row lands on the compiled defaults for those rows
        // and touches nothing else (the shortcut, AI, history stay).
        user.shortcut = ShortcutDefinition(key: "space", modifiers: ["control"])
        user.historyEnabled = false
        var all = user
        for row in ResettableSetting.allCases { row.reset(in: &all) }
        XCTAssertEqual(all.maxRecordingSeconds, 600)
        XCTAssertFalse(all.automaticTextFormatting)
        XCTAssertEqual(all.shortcut, user.shortcut)
        XCTAssertFalse(all.historyEnabled)
    }

    func testEveryResettableRowIsAUserLayerRowOfTheResolver() {
        // Every resettable row names a field of EffectiveSettings, and the
        // per-row answer equals the field's own provenance.
        let labels = Set(Mirror(reflecting: resolve()).children.compactMap(\.label))
        for row in ResettableSetting.allCases {
            XCTAssertTrue(labels.contains(row.rawValue), row.rawValue)
        }
        var user = AppSettings()
        user.recorderStyle = .notch
        user.freeModelMemoryUnderCriticalPressure = true
        let effective = resolve(user: user)
        XCTAssertEqual(effective.changedFromDefault, [.recorderStyle, .freeModelMemoryUnderCriticalPressure])
        XCTAssertTrue(effective.isChangedFromDefault(.recorderStyle))
        XCTAssertFalse(effective.isChangedFromDefault(.triggers))
        XCTAssertEqual(resolve().changedFromDefault, [])
    }

    func testRecordingLengthAboveTheTechnicalCeilingIsClamped() {
        var user = AppSettings()
        user.maxRecordingSeconds = RecordingDurationLimit.technicalCeilingSeconds + 1
        let effective = resolve(user: user)
        XCTAssertEqual(effective.maxRecordingSeconds.value, RecordingDurationLimit.technicalCeilingSeconds)
        XCTAssertEqual(effective.maxRecordingSeconds.provenance, .limitedBy(SettingsResolver.technicalCeilingFact))
        XCTAssertEqual(effective.maxRecordingSeconds.limitingFact, "technical ceiling")
        XCTAssertFalse(effective.maxRecordingSeconds.isChangedFromDefault)
    }

    // MARK: Dictionary budget

    func testDictionaryBudgetIsLimitedByTheEngineCap() {
        // Whisper: catalog 224, runtime 111 → the runtime's number, and the
        // page says "using the engine's 111-token cap".
        let whisper = EnvironmentProfile(enginePromptTokenLimit: .tokens(111), catalogPromptTokenLimit: 224, residentModelID: "whisper")
        let effective = resolve(environment: whisper)
        XCTAssertEqual(effective.dictionaryTokenBudget.value?.promptTokenLimit, 111)
        XCTAssertEqual(effective.dictionaryTokenBudget.value?.budget, 99)
        XCTAssertEqual(effective.dictionaryTokenBudget.provenance, .limitedBy(SettingsResolver.enginePromptCapFact))

        // Nothing resident: the catalog's number, no limit noted.
        let unloaded = EnvironmentProfile(catalogPromptTokenLimit: 224)
        let estimate = resolve(environment: unloaded)
        XCTAssertEqual(estimate.dictionaryTokenBudget.value?.promptTokenLimit, 224)
        XCTAssertEqual(estimate.dictionaryTokenBudget.value?.isFromResidentModel, false)
        XCTAssertEqual(estimate.dictionaryTokenBudget.provenance, .default)

        // A resident cap equal to the catalog's is not a limit.
        let equal = EnvironmentProfile(enginePromptTokenLimit: .tokens(224), catalogPromptTokenLimit: 224, residentModelID: "x")
        XCTAssertEqual(resolve(environment: equal).dictionaryTokenBudget.provenance, .default)

        // Parakeet: no prompt at all.
        let parakeet = EnvironmentProfile(enginePromptTokenLimit: .unsupported, catalogPromptTokenLimit: nil, residentModelID: "parakeet")
        XCTAssertNil(resolve(environment: parakeet).dictionaryTokenBudget.value)
    }

    func testDictionaryReserveOverrideReachesTheBudgetWithOverrideProvenance() {
        var defaults = DeveloperDefaults.compiled
        defaults.dictionaryReserveFraction = 0.5
        let unloaded = EnvironmentProfile(catalogPromptTokenLimit: 200)
        let effective = resolve(defaults: defaults, environment: unloaded, overridden: [.dictionaryReserveFraction])
        XCTAssertEqual(effective.dictionaryTokenBudget.value?.budget, 100)
        XCTAssertEqual(effective.dictionaryTokenBudget.provenance, .override)
        XCTAssertEqual(effective.dictionaryReserveFraction, Resolved(0.5, .override))
    }

    // MARK: Overlapping jobs (ADR-022 item 7)

    func testOverlappingJobsOnIsForcedOffByTheEnvironment() {
        var defaults = DeveloperDefaults.compiled
        defaults.overlappingJobs = true

        let fine = EnvironmentProfile(memoryPressureLevel: .normal, lastRealTimeFactor: 0.2, computeUnits: .neuralEngineAndCPU)
        XCTAssertEqual(resolve(defaults: defaults, environment: fine, overridden: [.overlappingJobs]).overlappingJobs, Resolved(true, .override))
        XCTAssertEqual(resolve(defaults: defaults, environment: fine).overlappingJobs, Resolved(true, .default))

        let pressure = EnvironmentProfile(memoryPressureLevel: .warning)
        XCTAssertEqual(resolve(defaults: defaults, environment: pressure).overlappingJobs, Resolved(false, .limitedBy(SettingsResolver.memoryPressureFact)))
        let critical = EnvironmentProfile(memoryPressureLevel: .critical)
        XCTAssertEqual(resolve(defaults: defaults, environment: critical).overlappingJobs.value, false)

        let cpu = EnvironmentProfile(computeUnits: .cpuOnly)
        XCTAssertEqual(resolve(defaults: defaults, environment: cpu).overlappingJobs, Resolved(false, .limitedBy(SettingsResolver.cpuOnlyComputeFact)))

        let slow = EnvironmentProfile(lastRealTimeFactor: 0.51)
        XCTAssertEqual(resolve(defaults: defaults, environment: slow).overlappingJobs, Resolved(false, .limitedBy(SettingsResolver.realTimeFactorFact)))
        let atCeiling = EnvironmentProfile(lastRealTimeFactor: 0.5)
        XCTAssertEqual(resolve(defaults: defaults, environment: atCeiling).overlappingJobs.value, true, "the ceiling itself is allowed")

        // A raised ceiling from the override file moves the line.
        defaults.overlappingJobsRealTimeFactorCeiling = 1.0
        XCTAssertEqual(resolve(defaults: defaults, environment: slow).overlappingJobs.value, true)
    }

    func testOverlappingJobsOffIsNeverLabelledLimited() {
        // Nothing to limit: the shipped default stays `.default` whatever
        // the environment says.
        let pressure = EnvironmentProfile(memoryPressureLevel: .critical, lastRealTimeFactor: 3, computeUnits: .cpuOnly)
        XCTAssertEqual(resolve(environment: pressure).overlappingJobs, Resolved(false, .default))
    }

    func testTheUserLayerCannotTurnOverlappingJobsOn() {
        // By construction: no AppSettings field reaches the flag. Every
        // user value resolves to the developer's answer.
        var user = AppSettings()
        user.maxRecordingSeconds = 30
        user.typedInsertionEnabled = false
        XCTAssertEqual(resolve(user: user).overlappingJobs, Resolved(false, .default))
    }

    // MARK: Developer layer provenance

    func testOverriddenKeysLabelTheirRows() {
        var defaults = DeveloperDefaults.compiled
        defaults.hybridTapWindowMilliseconds = 300
        defaults.quietPeakThresholdDBFS = -20
        let effective = resolve(defaults: defaults, overridden: [.hybridTapWindowMilliseconds, .quietPeakThresholdDBFS])
        XCTAssertEqual(effective.hybridTapWindow, Resolved(.milliseconds(300), .override))
        XCTAssertEqual(effective.speechGate.provenance, .override)
        XCTAssertEqual(effective.speechGate.value.quietPeakDBFS, -20)
        XCTAssertEqual(effective.doublePressWindow.provenance, .default)
        XCTAssertEqual(effective.hudDismissTimings.provenance, .default)
    }

    // MARK: Safety boundary

    func testUserLayerCannotReachDeveloperOnlyRows() {
        // Two wildly different user layers resolve the developer-only rows
        // identically: there is no path from AppSettings to them.
        var loud = AppSettings()
        loud.maxRecordingSeconds = 10
        loud.recorderStyle = .notch
        loud.typedInsertionEnabled = false
        loud.triggers.autoSendEnabled = true
        loud.speechComputeUnits = .cpuOnly
        let a = resolve()
        let b = resolve(user: loud)
        XCTAssertEqual(a.speechGate, b.speechGate)
        XCTAssertEqual(a.hudDismissTimings, b.hudDismissTimings)
        XCTAssertEqual(a.runtimeExpectations, b.runtimeExpectations)
        XCTAssertEqual(a.hybridTapWindow, b.hybridTapWindow)
        XCTAssertEqual(a.doublePressWindow, b.doublePressWindow)
        XCTAssertEqual(a.dictionaryReserveFraction, b.dictionaryReserveFraction)
        XCTAssertEqual(a.axFocusRetryCount, b.axFocusRetryCount)
        XCTAssertEqual(a.axFocusRetryDelay, b.axFocusRetryDelay)
        XCTAssertEqual(a.typedChunkPacing, b.typedChunkPacing)
        XCTAssertEqual(a.automaticBackupRetentionCount, b.automaticBackupRetentionCount)
        XCTAssertEqual(a.overlappingJobs, b.overlappingJobs)
    }

    func testNoSafetyRuleIsAUserSetting() {
        // The secure-field refusal, the pasteboard rule, the trust checks,
        // the insertion tier order and the diagnostics rule have no field
        // in AppSettings or EffectiveSettings (word-level, like the
        // developer-defaults guard). `preserveTranscriptInClipboard` is an
        // opt-in *after* a successful insertion, nested under
        // recordingFeedback, and is not a rule about the fallback.
        let forbidden = SettingsResolver.safetyRuleWords
        XCTAssertEqual(forbidden.subtracting(DeveloperDefaults.forbiddenKeyWords), [], "the JSON guard covers every safety word")
        for label in Mirror(reflecting: AppSettings()).children.compactMap(\.label) {
            XCTAssertTrue(Set(DeveloperDefaults.words(in: label)).isDisjoint(with: forbidden), "AppSettings.\(label)")
        }
        for label in Mirror(reflecting: resolve()).children.compactMap(\.label) {
            XCTAssertTrue(Set(DeveloperDefaults.words(in: label)).isDisjoint(with: forbidden), "EffectiveSettings.\(label)")
        }
    }

    func testProvenanceNamesAreScalars() {
        XCTAssertEqual(Provenance.user.name, "user")
        XCTAssertEqual(Provenance.default.name, "default")
        XCTAssertEqual(Provenance.override.name, "override")
        XCTAssertEqual(Provenance.limitedBy("engine prompt cap").name, "limitedBy")
    }
}
