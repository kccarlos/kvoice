import XCTest
@testable import KvoiceDomain
@testable import KvoiceUI

/// The Runtime card: verdict thresholds, placement formatting, the sampling
/// cadence (driven by `tick()` and a recording clock, never real time), the
/// picker lock while a dictation runs, the performance test bookkeeping, and
/// the honest hiding of an unreadable GPU counter.
@MainActor
final class RuntimeCardViewModelTests: XCTestCase {
    // MARK: Fakes

    /// Scripted counters: each call pops the next value, the last repeats.
    private final class FakeTelemetry: RuntimeTelemetryProviding, @unchecked Sendable {
        var memory: [UInt64?]
        var cpu: [Double?]
        var gpu: [Double?]
        var memoryReads = 0
        var cpuReads = 0
        var gpuReads = 0

        init(memory: [UInt64?] = [1_200_000_000], cpu: [Double?] = [0.5], gpu: [Double?] = [0.2]) {
            self.memory = memory
            self.cpu = cpu
            self.gpu = gpu
        }

        func memoryFootprintBytes() -> UInt64? {
            memoryReads += 1
            return Self.next(&memory)
        }

        func cpuUtilisation() -> Double? {
            cpuReads += 1
            return Self.next(&cpu)
        }

        func gpuUtilisation() -> Double? {
            gpuReads += 1
            return Self.next(&gpu)
        }

        private static func next<T>(_ values: inout [T?]) -> T? {
            guard let first = values.first else { return nil }
            if values.count > 1 { values.removeFirst() }
            return first
        }
    }

    /// Records every sleep and ends the loop after `limit` of them.
    private final class RecordingClock: KvoiceClock, @unchecked Sendable {
        private(set) var sleeps: [Duration] = []
        let limit: Int

        init(limit: Int) { self.limit = limit }

        var now: ContinuousClock.Instant { ContinuousClock().now }

        func sleep(for duration: Duration) async throws {
            sleeps.append(duration)
            if sleeps.count >= limit { throw CancellationError() }
        }
    }

    /// Holds the fake transcription open until the test has sampled.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Yields (never sleeps) until the view model's task has finished.
    private func settle(while condition: @MainActor () -> Bool) async {
        for _ in 0..<5_000 where condition() { await Task.yield() }
    }

    private func placement(_ neural: Int, _ gpu: Int, _ cpu: Int) -> ModelPlacement {
        ModelPlacement(operationCounts: [.neuralEngine: neural, .gpu: gpu, .cpu: cpu])
    }

    private func snapshot(
        resident: ModelID? = "turbo",
        units: SpeechComputeUnits = .neuralEngineAndCPU,
        placement: ModelPlacementReport? = nil,
        pending: Bool = false,
        reloading: Bool = false,
        dictationActive: Bool = false,
        exercising: Bool = false,
        statistics: TranscriptionRuntimeStatistics = .init(),
        availability: SettingAvailability? = nil
    ) -> RuntimeSnapshot {
        // The shell fills the projection row from its gate; here it is
        // derived from the same two flags unless a test passes one.
        let computeUnitsAvailability: SettingAvailability = availability ?? SettingsAvailability.availability(
            key: .speechComputeUnits,
            settings: AppSettings(),
            environment: EnvironmentProfile(residentModelID: resident),
            gate: SettingsGate(dictation: dictationActive ? .jobActive : .idle)
        )
        return RuntimeSnapshot(
            residentModelID: resident,
            residentModelName: resident.map { "Whisper \($0)" },
            computeUnits: units,
            placement: placement,
            placementIsPending: pending,
            statistics: statistics,
            isReloading: reloading,
            dictationIsActive: dictationActive,
            isExercisingRuntime: exercising,
            computeUnitsAvailability: computeUnitsAvailability
        )
    }

    // MARK: Verdicts and thresholds

    func testVerdictIsGreenAtOrBelowTheExpectedFactorAndAmberAbove() {
        let fast = RuntimeExpectation.verdict(realTimeFactor: 0.18, units: .neuralEngineAndCPU)
        XCTAssertEqual(fast, .asExpected("Running on Neural Engine (RTF 0.18×)"))
        let edge = RuntimeExpectation.verdict(realTimeFactor: 0.35, units: .neuralEngineAndCPU)
        XCTAssertTrue(edge.isAsExpected, "the threshold itself passes")
        let slow = RuntimeExpectation.verdict(realTimeFactor: 0.9, units: .neuralEngineAndCPU)
        XCTAssertEqual(
            slow,
            .slowerThanExpected("Slower than expected for Neural Engine (RTF 0.90×) — check the compute-unit setting")
        )
        // Each choice is judged against its own device and range.
        XCTAssertEqual(RuntimeExpectation.verdict(realTimeFactor: 0.5, units: .gpuAndCPU).message, "Running on GPU (RTF 0.50×)")
        XCTAssertTrue(RuntimeExpectation.verdict(realTimeFactor: 3, units: .cpuOnly).isAsExpected)
        XCTAssertFalse(RuntimeExpectation.verdict(realTimeFactor: 3, units: .all).isAsExpected)
        // The measured M4 figures: a warm CPU-only run (0.6×) must read amber
        // under the Neural Engine choice — that is the misplacement the card
        // exists to catch — and the CPU's own 11.4× first pass stays green.
        XCTAssertFalse(RuntimeExpectation.verdict(realTimeFactor: 0.601, units: .neuralEngineAndCPU).isAsExpected)
        XCTAssertTrue(RuntimeExpectation.verdict(realTimeFactor: 0.155, units: .neuralEngineAndCPU).isAsExpected)
        XCTAssertTrue(RuntimeExpectation.verdict(realTimeFactor: 0.749, units: .gpuAndCPU).isAsExpected)
        XCTAssertTrue(RuntimeExpectation.verdict(realTimeFactor: 11.4, units: .cpuOnly).isAsExpected)
        XCTAssertEqual(RuntimeExpectation.verdict(realTimeFactor: 22.4, units: .cpuOnly).message, "Slower than expected for CPU (RTF 22×) — check the compute-unit setting")
        for units in SpeechComputeUnits.allCases {
            XCTAssertGreaterThan(RuntimeExpectation.expectedMaximumRealTimeFactor(for: units), 0)
        }
        XCTAssertLessThan(
            RuntimeExpectation.expectedMaximumRealTimeFactor(for: .neuralEngineAndCPU),
            RuntimeExpectation.expectedMaximumRealTimeFactor(for: .cpuOnly),
            "the Neural Engine is expected to be faster than the CPU"
        )
    }

    // MARK: Placement formatting

    func testPlacementLinesFormatSharesAndFallBackHonestly() {
        let model = RuntimeCardViewModel(snapshot: snapshot(placement: ModelPlacementReport(
            modelID: "turbo",
            computeUnits: .neuralEngineAndCPU,
            encoder: placement(970, 0, 30),
            decoder: nil
        )))
        let lines = model.placementLines
        XCTAssertEqual(lines.map(\.label), ["Encoder", "Decoder"])
        XCTAssertEqual(lines[0].value, "97 % Neural Engine · 3 % CPU")
        XCTAssertTrue(lines[0].isAvailable)
        XCTAssertEqual(lines[1].value, "Unavailable for this model")
        XCTAssertFalse(lines[1].isAvailable)

        XCTAssertEqual(placement(1, 1, 998).summary, "100 % CPU · <1 % Neural Engine · <1 % GPU")
        XCTAssertEqual(placement(0, 0, 0).summary, "No operations")
        XCTAssertEqual(placement(3, 5, 2).dominantDevice, .gpu)
        XCTAssertEqual(placement(1, 1, 2).share(of: .cpu), 0.5)

        // A plan for other units (or another model) is stale, not shown.
        model.apply(snapshot(units: .cpuOnly, placement: ModelPlacementReport(
            modelID: "turbo", computeUnits: .neuralEngineAndCPU, encoder: placement(9, 0, 1), decoder: placement(9, 0, 1)
        ), pending: true))
        XCTAssertEqual(model.placementLines.map(\.value), ["Planning…", "Planning…"])
        model.apply(snapshot(resident: nil))
        XCTAssertTrue(model.placementLines.isEmpty)
    }

    // MARK: Sampling cadence

    func testMemoryIsReadEveryEighthTickAndUtilisationOnlyWhileExercising() async {
        let telemetry = FakeTelemetry(memory: [1_000, 2_000], cpu: [0.1, 0.2, 0.3], gpu: [0.4])
        var current = snapshot()
        let model = RuntimeCardViewModel(telemetry: telemetry, snapshotProvider: { current })

        for _ in 0..<RuntimeCardViewModel.memoryTicks { await model.tick() }
        XCTAssertEqual(telemetry.memoryReads, 1, "eight ticks at 250 ms is one memory read")
        XCTAssertEqual(model.memoryFootprintBytes, 1_000)
        XCTAssertTrue(model.cpuSeries.isEmpty, "idle: no utilisation samples")
        XCTAssertEqual(telemetry.cpuReads, RuntimeCardViewModel.memoryTicks, "idle ticks keep the CPU baseline fresh")
        XCTAssertEqual(telemetry.gpuReads, 0)

        await model.tick()
        XCTAssertEqual(telemetry.memoryReads, 2)
        XCTAssertEqual(model.memoryFootprintBytes, 2_000)

        current = snapshot(exercising: true)
        await model.tick()
        await model.tick()
        XCTAssertEqual(model.cpuSeries.count, 2)
        XCTAssertEqual(model.gpuSeries, [0.4, 0.4])
        XCTAssertTrue(model.isSampling)
    }

    func testPollLoopSleepsTheTickIntervalAndStopsWhenTheClockCancels() async {
        let clock = RecordingClock(limit: 3)
        let telemetry = FakeTelemetry()
        let model = RuntimeCardViewModel(telemetry: telemetry, clock: clock, snapshotProvider: { nil })

        await model.pollWhileVisible()

        XCTAssertEqual(clock.sleeps, Array(repeating: RuntimeCardViewModel.tickInterval, count: 3))
        XCTAssertEqual(RuntimeCardViewModel.tickInterval * RuntimeCardViewModel.memoryTicks, .seconds(2))
        XCTAssertFalse(model.isAvailable, "no shell: the card says it is not connected")
        XCTAssertEqual(model.controlsDisabledReason, "The speech runtime is not connected in this build.")
    }

    func testUnreadableGPUCounterHidesTheLineInsteadOfDrawingZeros() async {
        let telemetry = FakeTelemetry(cpu: [0.3], gpu: [nil])
        let model = RuntimeCardViewModel(telemetry: telemetry, snapshotProvider: { [self] in snapshot(exercising: true) })
        XCTAssertTrue(model.gpuCounterIsReadable, "assumed readable until proven otherwise")

        await model.tick()
        await model.tick()

        XCTAssertNil(model.gpuSeries)
        XCTAssertFalse(model.gpuCounterIsReadable)
        XCTAssertEqual(telemetry.gpuReads, 1, "not asked again once it proved absent")
        XCTAssertEqual(model.cpuSeries, [0.3, 0.3])
        XCTAssertEqual(model.currentCPUDescription, "30 %")
        XCTAssertEqual(model.currentGPUDescription, "—")
    }

    func testSparklinesKeepOnlyTheLastSixtyPoints() async {
        let telemetry = FakeTelemetry(cpu: [0.5], gpu: [0.5])
        let model = RuntimeCardViewModel(telemetry: telemetry, snapshotProvider: { [self] in snapshot(exercising: true) })
        for _ in 0..<(RuntimeCardViewModel.sparklineLength + 10) { await model.tick() }
        XCTAssertEqual(model.cpuSeries.count, RuntimeCardViewModel.sparklineLength)
        XCTAssertEqual(model.gpuSeries?.count, RuntimeCardViewModel.sparklineLength)
    }

    // MARK: Compute units

    func testPickerIsDisabledWhileDictationRunsAndWhileNothingIsLoaded() {
        let model = RuntimeCardViewModel(snapshot: snapshot(dictationActive: true))
        XCTAssertFalse(model.canChangeComputeUnits)
        XCTAssertFalse(model.canRunPerformanceTest)
        XCTAssertEqual(model.controlsDisabledReason, "Finish the current dictation first.")

        model.apply(snapshot(resident: nil))
        XCTAssertEqual(model.controlsDisabledReason, "No model is loaded.")

        // The projection's other rows come through verbatim: the shell
        // decides, the card only shows the reason.
        model.apply(snapshot(availability: .disabled(reason: SettingAvailabilityReason.performanceTestRunning.message)))
        XCTAssertEqual(model.controlsDisabledReason, "Performance test running…")
        XCTAssertFalse(model.canChangeComputeUnits)

        model.apply(snapshot(reloading: true))
        XCTAssertEqual(model.controlsDisabledReason, "Reloading the model with the new compute units…")

        model.apply(snapshot())
        XCTAssertNil(model.controlsDisabledReason)
        XCTAssertTrue(model.canChangeComputeUnits)
    }

    func testChoosingComputeUnitsIsOptimisticUntilTheShellAgreesAndReportsFailure() async {
        var applied: [SpeechComputeUnits] = []
        var shouldFail = false
        var current = snapshot()
        let model = RuntimeCardViewModel(
            snapshotProvider: { current },
            setComputeUnits: { units in
                if shouldFail { throw KVoiceError(code: .appBusy) }
                applied.append(units)
                current = self.snapshot(units: units)
            }
        )
        await model.tick()

        model.setComputeUnits(.cpuOnly)
        XCTAssertEqual(model.computeUnits, .cpuOnly, "the picker does not snap back for a poll tick")
        XCTAssertEqual(model.pendingComputeUnits, .cpuOnly)
        XCTAssertFalse(model.canChangeComputeUnits, "locked while the reload runs")
        await Task.yield()
        await model.tick()
        XCTAssertEqual(applied, [.cpuOnly])
        XCTAssertNil(model.pendingComputeUnits)
        XCTAssertEqual(model.computeUnits, .cpuOnly)

        // The same choice again does nothing; a busy engine is reported.
        model.setComputeUnits(.cpuOnly)
        await Task.yield()
        XCTAssertEqual(applied, [.cpuOnly])
        shouldFail = true
        model.setComputeUnits(.gpuAndCPU)
        await Task.yield()
        await model.tick()
        XCTAssertEqual(model.computeUnitsError, "Finish the current dictation first.")
        XCTAssertEqual(model.computeUnits, .cpuOnly, "a refused change snaps back to the shell's value")
    }

    // MARK: Performance test

    func testPerformanceTestRecordsPeaksAndVerdictAndRefusesWhileBusy() async {
        let telemetry = FakeTelemetry(cpu: [0.1, 0.6, 0.2], gpu: [0.05, 0.3, 0.1])
        let gate = Gate()
        var runs = 0
        let model = RuntimeCardViewModel(
            snapshot: snapshot(units: .neuralEngineAndCPU),
            telemetry: telemetry,
            snapshotProvider: { [self] in snapshot() },
            transcribePerformanceSample: {
                runs += 1
                await gate.wait()
                return PerformanceSampleRun(realTimeFactor: 0.21, audioDuration: .seconds(11.6), inferenceDuration: .seconds(2.4))
            }
        )

        model.runPerformanceTest()
        XCTAssertTrue(model.isRunningPerformanceTest)
        XCTAssertTrue(model.isSampling, "the test counts as exercising the runtime")
        XCTAssertFalse(model.canRunPerformanceTest, "no double-click into two runs")
        model.runPerformanceTest()
        // Samples taken while the run is in flight feed the peaks: the
        // priming read took 0.1 / 0.05, these two take 0.6 / 0.3 and 0.2 / 0.1.
        await model.tick()
        await model.tick()
        gate.open()
        await settle(while: { model.isRunningPerformanceTest })

        XCTAssertEqual(runs, 1)
        XCTAssertFalse(model.isRunningPerformanceTest)
        let result = try? XCTUnwrap(model.performanceTestResult)
        XCTAssertEqual(result?.verdict, .asExpected("Running on Neural Engine (RTF 0.21×)"))
        XCTAssertEqual(result?.peakCPU ?? 0, 0.6, accuracy: 0.0001)
        XCTAssertEqual(result?.peakGPU ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(result?.computeUnits, .neuralEngineAndCPU)
        XCTAssertEqual(
            RuntimeCardView.detail(for: result!),
            "2.4 s for 11.6 s of audio · peak CPU 60 % · peak GPU 30 %"
        )
    }

    func testPerformanceTestFailureIsShownAndABusyEngineGetsTheDictationMessage() async {
        let model = RuntimeCardViewModel(
            snapshot: snapshot(),
            snapshotProvider: { [self] in snapshot() },
            transcribePerformanceSample: { throw KVoiceError(code: .appBusy) }
        )
        model.runPerformanceTest()
        await settle(while: { model.isRunningPerformanceTest })
        XCTAssertEqual(model.performanceTestError, "Finish the current dictation first.")
        XCTAssertNil(model.performanceTestResult)

        // A verdict is invalidated by a new device choice.
        let second = RuntimeCardViewModel(
            snapshot: snapshot(),
            snapshotProvider: { [self] in snapshot() },
            setComputeUnits: { _ in },
            transcribePerformanceSample: {
                PerformanceSampleRun(realTimeFactor: 0.2, audioDuration: .seconds(10), inferenceDuration: .seconds(2))
            }
        )
        second.runPerformanceTest()
        await settle(while: { second.isRunningPerformanceTest })
        XCTAssertNotNil(second.performanceTestResult)
        second.setComputeUnits(.gpuAndCPU)
        XCTAssertNil(second.performanceTestResult)
    }

    // MARK: Formatting

    func testFactsFormatLikeActivityMonitor() {
        XCTAssertEqual(RuntimeCardViewModel.formatBytes(1_200_000_000), "1.2 GB")
        XCTAssertEqual(RuntimeCardViewModel.formatBytes(850_000_000), "850 MB")
        XCTAssertEqual(RuntimeCardViewModel.formatSeconds(.milliseconds(640)), "640 ms")
        XCTAssertEqual(RuntimeCardViewModel.formatSeconds(.seconds(3.26)), "3.3 s")
        XCTAssertEqual(RuntimeExpectation.formatRealTimeFactor(0.183), "0.18×")
        XCTAssertEqual(RuntimeExpectation.formatRealTimeFactor(.nan), "—")
        let model = RuntimeCardViewModel(snapshot: snapshot(statistics: TranscriptionRuntimeStatistics(
            lastLoadDuration: .seconds(4.2),
            lastRealTimeFactor: 0.25,
            lastWarmUpDuration: .milliseconds(410)
        )))
        XCTAssertEqual(model.loadTimeDescription, "4.2 s")
        XCTAssertEqual(model.warmUpTimeDescription, "410 ms", "ADR-022 item 8: the card shows the warm-up pass")
        XCTAssertEqual(
            RuntimeCardViewModel(snapshot: snapshot(statistics: TranscriptionRuntimeStatistics())).warmUpTimeDescription,
            "—",
            "no warm-up yet, or it failed: an honest dash, never a zero"
        )
        XCTAssertEqual(model.lastRealTimeFactorDescription, "0.25×")
        XCTAssertEqual(model.memoryFootprintDescription, "—")
        XCTAssertEqual(model.residentModelName, "Whisper turbo")
    }
}
