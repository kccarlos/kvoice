import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KvoiceDomain

// History's detail side (split from `HistoryView.swift`, Q2b): the detail
// pane, the recording strip and its waveform, and the re-transcribe sheet.
// MARK: - Detail

/// The detail pane (Window.dc): padding 16/18, 12 pt apart.
struct HistoryDetailView: View {
    let entry: HistoryEntry
    @Bindable var viewModel: HistoryViewModel

    private var tab: HistoryTranscriptTab {
        entry.hasDistinctEnhancedText ? viewModel.transcriptTab : .original
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                transcriptBox
                copyRow

                if let fallbackSummary = entry.aiFallbackSummary {
                    // D.10: what happened and what kvoice did with the text.
                    // The code itself lives in the details grid, not here.
                    StatusLabel(fallbackSummary, symbol: "exclamationmark.triangle.fill", tone: .attention)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11))
                }

                if viewModel.hasStoredAudio(entry) {
                    audioSection
                }

                metadata
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    /// Title and meta at the left, the Original / Enhanced segments at the
    /// right (only when AI changed the text).
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                titleBlock
                Spacer(minLength: 8)
                segments
            }
            VStack(alignment: .leading, spacing: 8) {
                titleBlock
                segments
            }
        }
    }

    @ViewBuilder
    private var segments: some View {
        if entry.hasDistinctEnhancedText {
            KVSegmented(
                "Transcript version",
                selection: $viewModel.transcriptTab,
                options: HistoryTranscriptTab.allCases.map { ($0, $0.title) }
            )
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.createdAt.historyDetailTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.kv.text)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: entry.detailMeta)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kv.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Window.dc: the text on `wash`, radius 10, padding 12/14, 13 pt at a
    /// 1.55 line height.
    private var transcriptBox: some View {
        let text = tab == .original ? entry.rawText : entry.finalText
        return Text(verbatim: text)
            .font(.system(size: 13))
            .foregroundStyle(Color.kv.text)
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.kv.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            // No .accessibilityLabel here: on selectable text SwiftUI hands
            // the override to the AppKit text element, whose label then
            // resolves through itself — an Accessibility walk (VoiceOver)
            // overflowed the stack (Q2, 2026-10-21). The text reads as
            // itself; the segmented control above names the version.
    }

    /// Copy Enhanced (primary) and Copy Original side by side, or the one
    /// Copy Transcript; Delete (not drawn) at the far end. Neither copy
    /// shortcut is plain Command-C: the transcript is selectable, and
    /// claiming Command-C would hijack it.
    private var copyRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                copyButtons
                Spacer(minLength: 8)
                deleteButton
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { copyButtons }
                deleteButton
            }
        }
    }

    @ViewBuilder
    private var copyButtons: some View {
        if entry.hasDistinctEnhancedText {
            Button("Copy Enhanced") { _ = viewModel.copyFinal(entry) }
                .buttonStyle(KVButtonStyle(.primary, height: 26))
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Copy Original") { _ = viewModel.copyRaw(entry) }
                .buttonStyle(KVButtonStyle(.standard, height: 26))
                .keyboardShortcut("c", modifiers: [.command, .option])
        } else {
            Button("Copy Transcript") { _ = viewModel.copyFinal(entry) }
                .buttonStyle(KVButtonStyle(.primary, height: 26))
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
    }

    private var deleteButton: some View {
        Button("Delete", role: .destructive) {
            Task { await viewModel.delete(entry) }
        }
        .buttonStyle(KVButtonStyle(.danger, height: 26))
        // Command-Delete, as in Finder. A bare Delete equivalent on
        // a button also fires while typing in the search field.
        .keyboardShortcut(.delete, modifiers: [.command])
        .help("Delete this item (⌘⌫). Undo is available for ten seconds.")
    }

    /// The playback strip, only for a row with a stored recording (no
    /// waveform is drawn without one), with Show in Finder and Retranscribe
    /// under it.
    private var audioSection: some View {
        VStack(alignment: .trailing, spacing: 6) {
            AudioPlaybackStrip(player: viewModel.player, waveform: viewModel.waveform)
            HStack(spacing: 12) {
                Button("Show in Finder") { viewModel.revealAudio(for: entry) }
                if viewModel.canRetranscribe {
                    if viewModel.isRetranscribing {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Button("Retranscribe") {
                            Task { await viewModel.retranscribe(entry) }
                        }
                        .help("Run the recording through the current model again and choose whether to replace the transcript")
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Color.kv.cursorInk)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording")
    }

    /// Scalar facts about the job (Window.dc: a 110 pt label column, 11 pt,
    /// 5 / 10 pt gaps). Nothing here names the target application or
    /// reproduces its text; `targetClass` is a role class only.
    private var metadata: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            metadataRow("Model", entry.modelID.isEmpty ? String(localized: "Unknown", bundle: .module) : entry.modelID)
            metadataRow("AI", entry.aiDetail)
            if let target = entry.translationTarget, !target.isEmpty {
                metadataRow("Translated to", target)
            }
            if let milliseconds = entry.sttDurationMilliseconds {
                metadataRow("Transcription", String(localized: "\(HistoryDashboardView.seconds(milliseconds)) on this Mac", bundle: .module))
            }
            metadataRow("Insertion", entry.insertionOutcome.detailName(isFile: entry.isFileTranscription))
            if let targetClass = entry.targetClass, !targetClass.isEmpty {
                metadataRow("Target", HistoryEntry.targetDisplayName(targetClass))
            }
            if let errorCode = entry.errorCode {
                metadataRow("Error code", errorCode.rawValue)
            }
            if !entry.appVersion.isEmpty {
                metadataRow("App version", entry.appVersion)
            }
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details")
    }

    private func metadataRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(Color.kv.text2)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .foregroundStyle(Color.kv.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        // Text(label), not "\(label)": interpolating a LocalizedStringKey
        // into a string spells out its debug description.
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: value))
    }
}

/// The playback strip (Window.dc): a `line` ring, radius 10, padding 8/10;
/// a 26 pt `voice` play disc, the waveform as 22 pt bars — played in
/// `voice`, the rest in `line` — and the mono "0:04 / 0:12". Click or drag
/// the bars to scrub; VoiceOver adjusts by 5 %.
struct AudioPlaybackStrip: View {
    @Bindable var player: HistoryAudioPlayer
    let waveform: [Float]

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.kv.voice, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(player.failedToLoad || player.loadedURL == nil)
            .keyboardShortcut(.space, modifiers: [.command])
            .help(player.isPlaying ? "Pause (⌘Space)" : "Play (⌘Space)")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            GeometryReader { geometry in
                WaveformBars(bins: waveform, progress: player.progress)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                player.seek(toProgress: value.location.x / max(1, geometry.size.width))
                            }
                    )
            }
            .frame(height: 22)
            .accessibilityElement()
            .accessibilityLabel("Waveform")
            .accessibilityValue("\(Int(player.progress * 100)) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: player.seek(toProgress: player.progress + 0.05)
                case .decrement: player.seek(toProgress: player.progress - 0.05)
                @unknown default: break
                }
            }

            Text(Self.clock(player.currentTime) + " / " + Self.clock(player.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.kv.text2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.kv.line, lineWidth: 1)
        }
        .overlay(alignment: .bottomLeading) {
            if player.failedToLoad {
                StatusLabel(String(localized: "The recording could not be opened.", bundle: .module), symbol: "exclamationmark.triangle.fill", tone: .attention)
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10))
                    .offset(y: 16)
            }
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Window.dc's waveform: bars 2 pt apart, rounded 1 pt, centred, at least
/// 4 pt tall; the bins are averaged down to what fits (≥ 2 pt a bar).
struct WaveformBars: View {
    let bins: [Float]
    let progress: Double

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 2
            guard !bins.isEmpty, size.width > 0 else {
                context.fill(Path(CGRect(x: 0, y: size.height / 2 - 1, width: size.width, height: 2)), with: .color(Color.kv.line))
                return
            }
            let levels = Self.resample(bins, to: max(1, Int((size.width + gap) / (2 + gap))))
            let barWidth = (size.width - gap * CGFloat(levels.count - 1)) / CGFloat(levels.count)
            for (index, level) in levels.enumerated() {
                let height = max(4, CGFloat(level) * size.height)
                let rect = CGRect(x: CGFloat(index) * (barWidth + gap), y: (size.height - height) / 2, width: barWidth, height: height)
                let played = (Double(index) + 0.5) / Double(levels.count) <= progress
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(played ? Color.kv.voice : Color.kv.line))
            }
        }
    }

    /// Averages `bins` into at most `count` levels (never more than given).
    static func resample(_ bins: [Float], to count: Int) -> [Float] {
        guard bins.count > count, count > 0 else { return bins }
        return (0..<count).map { index in
            let start = index * bins.count / count
            let end = max(start + 1, (index + 1) * bins.count / count)
            let slice = bins[start..<end]
            return slice.reduce(0, +) / Float(slice.count)
        }
    }
}

/// "Replace the transcript?" after Retranscribe: shows both versions so the
/// user decides; nothing is written until Replace.
struct RetranscribeProposalSheet: View {
    let proposal: HistoryViewModel.RetranscribeProposal
    let viewModel: HistoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Replace the transcript?")
                .font(.title3.weight(.semibold))
            Text("The recording was transcribed again with the current model. Replacing keeps the recording, timing, and AI result; only the original transcript changes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                column("Current", proposal.previousRawText)
                column("New", proposal.newRawText)
            }
            SheetButtonBar(
                confirmTitle: "Replace",
                isConfirmEnabled: true,
                onCancel: { viewModel.dismissRetranscription() },
                onConfirm: { Task { await viewModel.acceptRetranscription() } }
            )
            .padding(.horizontal, -20)
            .padding(.bottom, -20)
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 620)
    }

    private func column(_ title: LocalizedStringKey, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 260)
            .padding(10)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: text))
    }
}
