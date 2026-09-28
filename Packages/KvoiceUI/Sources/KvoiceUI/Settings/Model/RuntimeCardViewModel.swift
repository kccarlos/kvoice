import Foundation
import KvoiceDomain
import Observation

// MARK: - Shell → view model

/// What the Runtime card knows about the resident model, pushed by the app
/// shell on every poll tick. The view model never touches the engine, the
/// library, or the settings store.
public struct RuntimeSnapshot: Sendable, Equatable {
    /// The model the engine holds, if any.
    public var residentModelID: ModelID?
    public var residentModelName: String?
    /// ADR-025: the resident model's runtime. A runtime with no compute-unit
    /// choice (Apple Speech) has no Core ML placement to plan: the card says
    /// the OS places the model instead of "Not planned yet".
    public var runtime: SpeechModelRuntime?
    public var computeUnits: SpeechComputeUnits
    /// Core ML's plan for the resident model under `computeUnits`. Nil while
    /// nothing is resident or the shell has not finished planning yet
    /// (`placementIsPending`).
    public var placement: ModelPlacementReport?
    public var placementIsPending: Bool
    public var statistics: TranscriptionRuntimeStatistics
    /// The engine is between runtimes (a compute-unit change in flight).
    public var isReloading: Bool
    /// A dictation job, a file transcription, or a model operation holds
    /// the engine; the picker and the test are disabled.
    public var dictationIsActive: Bool
    /// Something is exercising the runtime right now (recording, a file
    /// transcription) — the sparklines sample while this is true.
    public var isExercisingRuntime: Bool
    /// ADR-022 item 3: the projection's `.speechComputeUnits` row, computed
    /// by the shell from its gate and environment (a job, a file
    /// transcription, a model operation, the test, nothing resident). The
    /// card shows its reason; `isReloading` and the card's own optimistic
    /// pending state stay local because the projection cannot see them.
    public var computeUnitsAvailability: SettingAvailability

    public init(
        residentModelID: ModelID? = nil,
        residentModelName: String? = nil,
        runtime: SpeechModelRuntime? = nil,
        computeUnits: SpeechComputeUnits = .default,
        placement: ModelPlacementReport? = nil,
        placementIsPending: Bool = false,
        statistics: TranscriptionRuntimeStatistics = .init(),
        isReloading: Bool = false,
        dictationIsActive: Bool = false,
        isExercisingRuntime: Bool = false,
        computeUnitsAvailability: SettingAvailability = .enabled
    ) {
        self.residentModelID = residentModelID
        self.residentModelName = residentModelName
        self.runtime = runtime
        self.computeUnits = computeUnits
        self.placement = placement
        self.placementIsPending = placementIsPending
        self.statistics = statistics
        self.isReloading = isReloading
        self.dictationIsActive = dictationIsActive
        self.isExercisingRuntime = isExercisingRuntime
        self.computeUnitsAvailability = computeUnitsAvailability
    }
}

/// One transcription of the bundled sample, as the shell reports it back.
/// Scalars only.
public struct PerformanceSampleRun: Sendable, Equatable {
    public let realTimeFactor: Double
    public let audioDuration: Duration
    public let inferenceDuration: Duration

    public init(realTimeFactor: Double, audioDuration: Duration, inferenceDuration: Duration) {
        self.realTimeFactor = realTimeFactor
        self.audioDuration = audioDuration
        self.inferenceDuration = inferenceDuration
    }
}

/// The closures the shell installs at launch (the `SpeechModelsHooks`
/// pattern). Defaults render the card with "not connected" copy.
@MainActor
public enum RuntimeCardHooks {
    public static var snapshot: @MainActor () async -> RuntimeSnapshot? = { nil }
    /// Persist and apply a compute-unit choice; throws when the engine is
    /// busy or the reload failed.
    public static var setComputeUnits: @MainActor (SpeechComputeUnits) async throws -> Void = { _ in }
    /// Transcribe the bundled speech sample on the resident engine. Throws
    /// `KVoiceError(code: .appBusy)` while a dictation owns the engine.
    public static var transcribePerformanceSample: @MainActor () async throws -> PerformanceSampleRun = {
        throw KVoiceError(code: .appCancelled)
    }
}

// MARK: - Expectations

/// What "fast enough" means per compute-unit choice, and the verdict copy.
///
/// The thresholds sit above the *first* pass after a load of Whisper
/// large-v3-turbo (632 MB) on the bundled 11.6 s sample, because that is what
/// the button most often measures, with headroom for a warm machine under
/// light load. Measured on 2026-09-13 on an Apple M4 (10 cores, 16 GB),
/// WhisperKit 1.1.0, with `LiveRuntimeMeasurementTests` (KvoiceTranscription,
/// `KVOICE_LIVE_RUNTIME_TESTS=1`), which prints the same figures again on
/// new hardware:
///
/// | Choice               | RTF first pass | RTF second pass | Placement (enc / dec)      | Threshold |
/// | -------------------- | -------------- | --------------- | -------------------------- | --------- |
/// | Neural Engine + CPU  | 0.155          | 0.082           | 100 % NE / 99 % NE         | 0.35      |
/// | All (Core ML picks)  | 0.101          | 0.081           | 100 % NE / 99 % NE         | 0.35      |
/// | GPU + CPU            | 0.749          | 0.337           | 100 % GPU / 100 % GPU      | 0.90      |
/// | CPU only             | 11.4           | 0.601           | 100 % CPU / 100 % CPU      | 15.0      |
///
/// Two things the numbers say: a model that silently landed on the CPU reads
/// about 0.6× warm — well over the 0.35 Neural Engine threshold, which is the
/// case the amber verdict exists for — and the CPU's own first pass is
/// twenty times its warm one, so the CPU threshold is generous on purpose
/// (CPU only is the user's explicit choice; the verdict there confirms it
/// ran, it does not grade it). A slower Mac lands above the Neural Engine
/// threshold by design: the amber copy says "slower than expected", not
/// "broken".
public enum RuntimeExpectation {
    /// Real-time factor at or below which the run is judged to be on the
    /// expected device. The thresholds are `DeveloperDefaults`
    /// (`expectedRealTimeFactor*`, ADR-022 slice 5); `.compiled` is the
    /// table above.
    public static func expectedMaximumRealTimeFactor(
        for units: SpeechComputeUnits,
        expectations: RuntimeExpectations = .compiled
    ) -> Double {
        expectations.expectedMaximumRealTimeFactor(for: units)
    }

    public static func verdict(
        realTimeFactor: Double,
        units: SpeechComputeUnits,
        expectations: RuntimeExpectations = .compiled
    ) -> PerformanceVerdict {
        let device = DomainCopy.localized(units.expectedDeviceDisplayName)
        let figure = formatRealTimeFactor(realTimeFactor)
        if realTimeFactor <= expectedMaximumRealTimeFactor(for: units, expectations: expectations) {
            return .asExpected(String(localized: "Running on \(device) (RTF \(figure))", bundle: .module))
        }
        return .slowerThanExpected(
            String(localized: "Slower than expected for \(device) (RTF \(figure)) — check the compute-unit setting", bundle: .module)
        )
    }

    /// "0.18×" — two decimals below 10, none above.
    public static func formatRealTimeFactor(_ factor: Double) -> String {
        guard factor.isFinite else { return "—" }
        return factor < 10
            ? String(format: "%.2f×", factor)
            : String(format: "%.0f×", factor)
    }
}

public enum PerformanceVerdict: Sendable, Equatable {
    case asExpected(String)
    case slowerThanExpected(String)

    public var message: String {
        switch self {
        case let .asExpected(message), let .slowerThanExpected(message): return message
        }
    }

    public var isAsExpected: Bool {
        if case .asExpected = self { return true }
        return false
    }
}

/// The finished performance test as the card shows it.
public struct PerformanceTestResult: Sendable, Equatable {
    public let run: PerformanceSampleRun
    public let computeUnits: SpeechComputeUnits
    /// Highest process CPU share (0…1) sampled during the run.
    public let peakCPU: Double
    /// Highest GPU share sampled, nil when the counter is unreadable.
    public let peakGPU: Double?
    public let verdict: PerformanceVerdict

    public init(
        run: PerformanceSampleRun,
        computeUnits: SpeechComputeUnits,
        peakCPU: Double,
        peakGPU: Double?,
        verdict: PerformanceVerdict
    ) {
        self.run = run
        self.computeUnits = computeUnits
        self.peakCPU = peakCPU
        self.peakGPU = peakGPU
        self.verdict = verdict
    }
}

/// A `RuntimeTelemetryProviding` that reads nothing. The default for a view
/// model built without the shell (previews, a section rendered before the
/// hooks exist); every line that needs a counter hides itself.
public struct NoRuntimeTelemetry: RuntimeTelemetryProviding {
    public init() {}
    public func memoryFootprintBytes() -> UInt64? { nil }
    public func cpuUtilisation() -> Double? { nil }
    public func gpuUtilisation() -> Double? { nil }
}

// MARK: - View model

/// State for the Runtime card in Speech Models: Placement, the compute-unit
/// picker, the memory footprint, load time and last RTF, the performance
/// test, and the live CPU / GPU sparklines.
///
/// Sampling is one loop (`pollWhileVisible`) ticking every `tickInterval`
/// from the section's `.task`; each `tick()` refreshes the snapshot, reads
/// memory every `memoryTicks` ticks (about 2 s), and reads CPU / GPU only
/// while the runtime is being exercised. `tick()` is public so tests drive
/// the cadence without a clock.
@Observable
@MainActor
public final class RuntimeCardViewModel {
    public static let tickInterval: Duration = .milliseconds(250)
    /// Memory refreshes every this many ticks (2 s at the default interval).
    public static let memoryTicks = 8
    /// Points kept per sparkline (15 s at four samples a second).
    public static let sparklineLength = 60

    public private(set) var snapshot: RuntimeSnapshot?
    public private(set) var memoryFootprintBytes: UInt64?
    public private(set) var cpuSeries: [Double] = []
    /// Nil once the GPU counter proved unreadable; the view hides the line.
    public private(set) var gpuSeries: [Double]? = []
    public private(set) var isRunningPerformanceTest = false
    public private(set) var performanceTestResult: PerformanceTestResult?
    public private(set) var performanceTestError: String?
    /// The choice the user just made, until the shell's snapshot agrees or
    /// the change fails.
    public private(set) var pendingComputeUnits: SpeechComputeUnits?
    public private(set) var computeUnitsError: String?

    private let telemetry: any RuntimeTelemetryProviding
    private let clock: any KvoiceClock
    private let snapshotProvider: @MainActor () async -> RuntimeSnapshot?
    private let computeUnitsSetter: @MainActor (SpeechComputeUnits) async throws -> Void
    private let sampleTranscriber: @MainActor () async throws -> PerformanceSampleRun
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var peakCPUDuringTest: Double = 0
    @ObservationIgnored private var peakGPUDuringTest: Double?
    /// ADR-022 slice 5: the per-choice RTF thresholds the verdict reads,
    /// from the developer defaults the shell loaded.
    @ObservationIgnored private let expectations: RuntimeExpectations

    public init(
        snapshot: RuntimeSnapshot? = nil,
        telemetry: any RuntimeTelemetryProviding = NoRuntimeTelemetry(),
        clock: any KvoiceClock = SystemKvoiceClock(),
        snapshotProvider: @escaping @MainActor () async -> RuntimeSnapshot? = { await RuntimeCardHooks.snapshot() },
        setComputeUnits: @escaping @MainActor (SpeechComputeUnits) async throws -> Void = {
            try await RuntimeCardHooks.setComputeUnits($0)
        },
        transcribePerformanceSample: @escaping @MainActor () async throws -> PerformanceSampleRun = {
            try await RuntimeCardHooks.transcribePerformanceSample()
        },
        expectations: RuntimeExpectations = .compiled
    ) {
        self.snapshot = snapshot
        self.telemetry = telemetry
        self.clock = clock
        self.snapshotProvider = snapshotProvider
        self.computeUnitsSetter = setComputeUnits
        self.sampleTranscriber = transcribePerformanceSample
        self.expectations = expectations
    }

    // MARK: Inputs

    /// Equality-guarded: the shell polls four times a second.
    public func apply(_ snapshot: RuntimeSnapshot?) {
        if let pending = pendingComputeUnits, snapshot?.computeUnits == pending, snapshot?.isReloading == false {
            pendingComputeUnits = nil
        }
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
    }

    /// One sampling step. Runs from `pollWhileVisible`; tests call it directly.
    public func tick() async {
        apply(await snapshotProvider())
        if tickCount % Self.memoryTicks == 0 {
            let footprint = telemetry.memoryFootprintBytes()
            if footprint != memoryFootprintBytes { memoryFootprintBytes = footprint }
        }
        tickCount &+= 1
        if isSampling {
            sampleUtilisation()
        } else {
            // Keep the CPU baseline fresh so the first active sample is a
            // real delta rather than the whole idle period.
            _ = telemetry.cpuUtilisation()
        }
    }

    /// Runs from the section's `.task` and stops when the section is hidden.
    public func pollWhileVisible() async {
        while !Task.isCancelled {
            await tick()
            do {
                try await clock.sleep(for: Self.tickInterval)
            } catch {
                return
            }
        }
    }

    // MARK: Derived state

    public var isAvailable: Bool { snapshot != nil }

    public var residentModelName: String? {
        snapshot?.residentModelName ?? snapshot?.residentModelID
    }

    public var computeUnits: SpeechComputeUnits {
        pendingComputeUnits ?? snapshot?.computeUnits ?? .default
    }

    /// The sparklines sample while a recording, a file transcription, or
    /// the performance test is running.
    public var isSampling: Bool {
        isRunningPerformanceTest || (snapshot?.isExercisingRuntime ?? false)
    }

    public var gpuCounterIsReadable: Bool { gpuSeries != nil }

    /// Why the picker and the test button are disabled, or nil.
    public var controlsDisabledReason: String? {
        guard let snapshot else { return String(localized: "The speech runtime is not connected in this build.", bundle: .module) }
        if isRunningPerformanceTest { return String(localized: "Performance test running…", bundle: .module) }
        if pendingComputeUnits != nil || snapshot.isReloading { return String(localized: "Reloading the model with the new compute units…", bundle: .module) }
        // The rest — a job, a file transcription, a model operation, nothing
        // loaded — is the availability projection's row (ADR-022 item 3).
        return snapshot.computeUnitsAvailability.disabledReason.map { DomainCopy.localized($0) }
    }

    public var canChangeComputeUnits: Bool { controlsDisabledReason == nil }

    /// The test runs whenever the picker could be used — and also when the
    /// picker is refused only because the resident runtime places its own
    /// model (ADR-025, Apple Speech): that refusal says nothing about the
    /// engine being busy, and the test is how its speed is measured.
    public var canRunPerformanceTest: Bool {
        guard let snapshot else { return false }
        if controlsDisabledReason == nil { return true }
        guard !isRunningPerformanceTest, pendingComputeUnits == nil, !snapshot.isReloading else { return false }
        return snapshot.computeUnitsAvailability.disabledReason == SettingAvailabilityReason.runtimeHasNoComputeUnitChoice.message
    }

    /// "Encoder: 97 % Neural Engine · 3 % CPU", one line per graph, or the
    /// honest fallback per graph.
    public var placementLines: [(label: String, value: String, isAvailable: Bool)] {
        guard let snapshot, snapshot.residentModelID != nil else { return [] }
        if let runtime = snapshot.runtime, !runtime.hasComputeUnitChoice {
            // ADR-025: nothing to plan — the platform places its own model
            // and exposes no compute-unit choice or per-graph plan.
            return [(String(localized: "Model", bundle: .module), String(localized: "Placed by macOS", bundle: .module), false)]
        }
        guard let placement = snapshot.placement, placement.modelID == snapshot.residentModelID,
              placement.computeUnits == snapshot.computeUnits else {
            let text = snapshot.placementIsPending ? String(localized: "Planning…", bundle: .module) : String(localized: "Not planned yet", bundle: .module)
            return [(String(localized: "Encoder", bundle: .module), text, false), (String(localized: "Decoder", bundle: .module), text, false)]
        }
        return [
            (String(localized: "Encoder", bundle: .module), placement.encoder?.summary ?? String(localized: "Unavailable for this model", bundle: .module), placement.encoder != nil),
            (String(localized: "Decoder", bundle: .module), placement.decoder?.summary ?? String(localized: "Unavailable for this model", bundle: .module), placement.decoder != nil)
        ]
    }

    public var memoryFootprintDescription: String {
        memoryFootprintBytes.map { Self.formatBytes($0) } ?? "—"
    }

    public var loadTimeDescription: String {
        snapshot?.statistics.lastLoadDuration.map(Self.formatSeconds) ?? "—"
    }

    /// ADR-022 item 8: the silent warm-up pass after the last load, or "—"
    /// before a load and when the warm-up failed (the model still loaded).
    public var warmUpTimeDescription: String {
        snapshot?.statistics.lastWarmUpDuration.map(Self.formatSeconds) ?? "—"
    }

    public var lastRealTimeFactorDescription: String {
        snapshot?.statistics.lastRealTimeFactor.map(RuntimeExpectation.formatRealTimeFactor) ?? "—"
    }

    /// Current (last sampled) CPU share, for the sparkline caption.
    public var currentCPUDescription: String {
        cpuSeries.last.map(Self.formatPercent) ?? "—"
    }

    public var currentGPUDescription: String {
        gpuSeries?.last.map(Self.formatPercent) ?? "—"
    }

    // MARK: Actions

    public func setComputeUnits(_ units: SpeechComputeUnits) {
        guard canChangeComputeUnits, units != computeUnits else { return }
        pendingComputeUnits = units
        computeUnitsError = nil
        // A new device choice invalidates the last verdict.
        performanceTestResult = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.computeUnitsSetter(units)
            } catch {
                self.computeUnitsError = Self.message(for: error, verb: String(localized: "change the compute units", bundle: .module))
            }
            self.pendingComputeUnits = nil
        }
    }

    public func runPerformanceTest() {
        guard canRunPerformanceTest else { return }
        isRunningPerformanceTest = true
        performanceTestError = nil
        performanceTestResult = nil
        peakCPUDuringTest = 0
        peakGPUDuringTest = nil
        cpuSeries = []
        if gpuSeries != nil { gpuSeries = [] }
        // Prime the CPU delta so the first in-test sample covers the test.
        _ = telemetry.cpuUtilisation()
        let units = computeUnits
        Task { [weak self] in
            guard let self else { return }
            do {
                let run = try await self.sampleTranscriber()
                // One last sample so a short run still has a peak.
                self.sampleUtilisation()
                self.performanceTestResult = PerformanceTestResult(
                    run: run,
                    computeUnits: units,
                    peakCPU: self.peakCPUDuringTest,
                    peakGPU: self.peakGPUDuringTest,
                    verdict: self.snapshot?.runtime?.hasComputeUnitChoice == false
                        // ADR-025: no device was chosen, so there is nothing
                        // to grade against — report the figure as a fact.
                        ? .asExpected(String(localized: "Placed by macOS (RTF \(RuntimeExpectation.formatRealTimeFactor(run.realTimeFactor)))", bundle: .module))
                        : RuntimeExpectation.verdict(
                            realTimeFactor: run.realTimeFactor, units: units, expectations: self.expectations
                        )
                )
            } catch {
                self.performanceTestError = Self.message(for: error, verb: String(localized: "run the performance test", bundle: .module))
            }
            self.isRunningPerformanceTest = false
        }
    }

    // MARK: Internals

    private func sampleUtilisation() {
        if let cpu = telemetry.cpuUtilisation() {
            cpuSeries.append(cpu)
            if cpuSeries.count > Self.sparklineLength { cpuSeries.removeFirst(cpuSeries.count - Self.sparklineLength) }
            if isRunningPerformanceTest { peakCPUDuringTest = max(peakCPUDuringTest, cpu) }
        }
        guard gpuSeries != nil else { return }
        if let gpu = telemetry.gpuUtilisation() {
            gpuSeries?.append(gpu)
            if let count = gpuSeries?.count, count > Self.sparklineLength {
                gpuSeries?.removeFirst(count - Self.sparklineLength)
            }
            if isRunningPerformanceTest { peakGPUDuringTest = max(peakGPUDuringTest ?? 0, gpu) }
        } else {
            // The counter is absent on this system; say so once, never zeros.
            gpuSeries = nil
        }
    }

    private static func message(for error: Error, verb: String) -> String {
        if let error = error as? KVoiceError, error.code == .appBusy {
            return String(localized: "Finish the current dictation first.", bundle: .module)
        }
        return String(localized: "Could not \(verb): \(error.localizedDescription)", bundle: .module)
    }

    // MARK: Formatting

    /// "1.2 GB" / "850 MB" — decimal units, one decimal above a gigabyte.
    /// Hand-rolled because `ByteCountFormatter`'s memory style is binary
    /// ("1.12 GB" for 1.2 × 10⁹) and its file style varies its precision.
    nonisolated static func formatBytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= 1e9 { return String(format: "%.1f GB", value / 1e9) }
        return String(format: "%.0f MB", value / 1e6)
    }

    nonisolated static func formatSeconds(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1_000) }
        return String(format: "%.1f s", seconds)
    }

    nonisolated static func formatPercent(_ share: Double) -> String {
        String(format: "%.0f %%", min(max(share, 0), 1) * 100)
    }
}
