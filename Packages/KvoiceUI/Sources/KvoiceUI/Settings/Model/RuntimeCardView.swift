import KvoiceDomain
import SwiftUI

/// The Runtime card in Speech Models: one authoritative signal (Core ML's
/// placement plan), one empirical signal (the timed performance test), the
/// compute-unit picker that changes both, the memory footprint, the engine's
/// timings, and live CPU / GPU sparklines for the counters that exist.
///
/// There is deliberately no Neural Engine graph: macOS has no public ANE
/// counter, and the footnote says so instead of drawing one.
@MainActor
struct RuntimeCardView: View {
    let viewModel: RuntimeCardViewModel
    let memoryPressure: MemoryPressureViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Section {
            if !viewModel.isAvailable {
                Text(viewModel.controlsDisabledReason ?? String(localized: "The speech runtime is not connected in this build.", bundle: .module))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                if memoryPressure.showsBanner {
                    memoryPressureBanner
                }
                placement
                computeUnitsPicker
                SettingsFactRow("Memory", viewModel.memoryFootprintDescription, systemImage: "memorychip")
                    .accessibilityHint("Physical memory footprint of KVoice, refreshed every two seconds while this section is open.")
                SettingsFactRow("Load time", viewModel.loadTimeDescription)
                SettingsFactRow("Warm-up", viewModel.warmUpTimeDescription)
                    .accessibilityHint("The silent pass run right after the model loaded, so the first dictation is not slower than the second.")
                SettingsFactRow("Last real-time factor", viewModel.lastRealTimeFactorDescription)
                    .accessibilityHint("Inference time divided by audio duration for the last transcription; below one is faster than real time.")
                performanceTest
                sparklines
            }
        } header: {
            Text("Runtime")
        } footer: {
            Text("Placement is Core ML's plan for where each operation runs, not a measurement. Apple Neural Engine load has no public counter; use Placement and the performance test.")
        }
        // The sampling loop is attached to the Form in `ModelSettingsView`
        // (a modifier on a Section applies to every row).
    }

    // MARK: Memory pressure

    /// Later waves: memory-pressure warnings. Shown at `.warning` and
    /// `.critical`; only `.critical` offers "Unload model now" — the same
    /// action, and the same in-flight state, as the status menu's item.
    @ViewBuilder
    private var memoryPressureBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusLabel(
                memoryPressure.isCritical
                    ? String(localized: "Critical memory pressure — dictation may be slower, and the system may reclaim memory on its own.", bundle: .module)
                    : String(localized: "Memory pressure — dictation may be slower.", bundle: .module),
                symbol: "exclamationmark.triangle.fill",
                tone: .attention
            )
            .labelStyle(.titleAndIcon)
            .fixedSize(horizontal: false, vertical: true)
            Text("Current footprint: \(viewModel.memoryFootprintDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if memoryPressure.isCritical {
                HStack(spacing: 6) {
                    Button {
                        memoryPressure.unloadNow()
                    } label: {
                        if memoryPressure.isUnloading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small).accessibilityHidden(true)
                                Text("Unloading…")
                            }
                        } else {
                            Text("Unload Model Now")
                        }
                    }
                    .disabled(!memoryPressure.canUnloadNow)
                    .accessibilityHint("Releases the resident speech model's memory. The next dictation reloads it.")
                    if let reason = memoryPressure.unloadDisabledReason, !memoryPressure.isUnloading {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = memoryPressure.unloadError {
                    StatusLabel(error, symbol: "exclamationmark.triangle.fill", tone: .attention)
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Placement

    @ViewBuilder
    private var placement: some View {
        let lines = viewModel.placementLines
        if lines.isEmpty {
            SettingsFactRow("Placement", String(localized: "No model is loaded", bundle: .module))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Placement")
                ForEach(lines, id: \.label) { line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.label)
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        Text(line.value)
                            .foregroundStyle(line.isAvailable ? Color.primary : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "Placement: \(lines.map { "\($0.label) \($0.value)" }.joined(separator: ", "))", bundle: .module))
        }
    }

    // MARK: Compute units

    @ViewBuilder
    private var computeUnitsPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Compute units", selection: Binding(
                get: { viewModel.computeUnits },
                set: { viewModel.setComputeUnits($0) }
            )) {
                ForEach(SpeechComputeUnits.allCases) { units in
                    Text(domain: units.displayName).tag(units)
                }
            }
            .disabled(!viewModel.canChangeComputeUnits)
            .accessibilityHint("Changing this reloads the model. Neural Engine + CPU is the default and the fast path.")
            if let reason = viewModel.controlsDisabledReason {
                HStack(spacing: 6) {
                    if viewModel.pendingComputeUnits != nil || viewModel.isRunningPerformanceTest {
                        ProgressView().controlSize(.mini).accessibilityHidden(true)
                    } else {
                        Image(systemName: "lock").accessibilityHidden(true)
                    }
                    Text(reason)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let error = viewModel.computeUnitsError {
                StatusLabel(error, symbol: "exclamationmark.triangle.fill", tone: .attention)
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Performance test

    @ViewBuilder
    private var performanceTest: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                Button {
                    viewModel.runPerformanceTest()
                } label: {
                    if viewModel.isRunningPerformanceTest {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).accessibilityHidden(true)
                            Text("Testing…")
                        }
                    } else {
                        Text("Run Performance Test")
                    }
                }
                .disabled(!viewModel.canRunPerformanceTest)
                .accessibilityHint("Transcribes a bundled twelve-second speech sample and reports the real-time factor and peak CPU and GPU use.")
            } label: {
                Text("Performance test")
            }
            if let result = viewModel.performanceTestResult {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: result.verdict.isAsExpected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.verdict.isAsExpected ? Color.green : Color.orange)
                        .accessibilityHidden(true)
                    Text(result.verdict.message)
                        .foregroundStyle(result.verdict.isAsExpected ? Color.secondary : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                Text(Self.detail(for: result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Measured: the first pass after a load is 2× (Neural Engine)
                // to 20× (CPU) slower than the next one.
                Text("The first run after a load includes Core ML warm-up; run it again for the steady figure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = viewModel.performanceTestError {
                StatusLabel(error, symbol: "exclamationmark.triangle.fill", tone: .attention)
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(reduceMotion ? nil : .default, value: viewModel.performanceTestResult)
    }

    static func detail(for result: PerformanceTestResult) -> String {
        var parts = [
            String(
                localized: "\(RuntimeCardViewModel.formatSeconds(result.run.inferenceDuration)) for \(RuntimeCardViewModel.formatSeconds(result.run.audioDuration)) of audio",
                bundle: .module
            ),
            String(localized: "peak CPU \(RuntimeCardViewModel.formatPercent(result.peakCPU))", bundle: .module)
        ]
        if let gpu = result.peakGPU {
            parts.append(String(localized: "peak GPU \(RuntimeCardViewModel.formatPercent(gpu))", bundle: .module))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Sparklines

    @ViewBuilder
    private var sparklines: some View {
        VStack(alignment: .leading, spacing: 8) {
            sparkline(title: "CPU (KVoice)", series: viewModel.cpuSeries, caption: viewModel.currentCPUDescription, tint: .blue)
            if let gpu = viewModel.gpuSeries {
                sparkline(title: "GPU (system)", series: gpu, caption: viewModel.currentGPUDescription, tint: .purple)
            } else {
                Text("GPU utilisation not readable on this system.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(viewModel.isSampling
                 ? "Sampling four times a second while the runtime is busy."
                 : "Graphs update while a recording, a file transcription, or the performance test is running.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sparkline(title: LocalizedStringKey, series: [Double], caption: String, tint: Color) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.callout)
                .frame(width: 96, alignment: .leading)
            SparklineView(values: series, tint: tint)
                .frame(height: 24)
                .frame(maxWidth: .infinity)
            Text(caption)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(caption)")
        .animation(reduceMotion ? nil : .linear(duration: 0.2), value: series.count)
    }
}

/// A fixed-range (0…1) line over the last `RuntimeCardViewModel.sparklineLength`
/// samples, drawn with `Canvas` so sixty points redraw cheaply four times a
/// second. Empty series draw the baseline only.
struct SparklineView: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let baseline = Path { path in
                path.move(to: CGPoint(x: 0, y: size.height - 0.5))
                path.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            }
            context.stroke(baseline, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
            guard values.count > 1 else { return }
            let capacity = max(RuntimeCardViewModel.sparklineLength - 1, 1)
            let step = size.width / CGFloat(capacity)
            let start = CGFloat(capacity - (values.count - 1)) * step
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(
                    x: start + CGFloat(index) * step,
                    y: size.height - CGFloat(min(max(value, 0), 1)) * (size.height - 2) - 1
                )
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}
