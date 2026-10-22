import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KvoiceDomain

// History's list-side pieces (split from `HistoryView.swift`, Q2b): the
// empty card, the filter chips, the stats strip and the rows.

/// A 28 pt transparent icon button face (Window.dc's ＋ / ⤴︎), `text-2`.
struct HistoryIconLabel: View {
    let systemImage: String
    let size: CGFloat

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size))
            .foregroundStyle(Color.kv.text2)
            .frame(width: 28, height: 28)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - Empty page

/// Window.dc `isEmpty`: a centred card (radius 12, `line` ring) with a
/// 56 pt `fill` tile holding the clock, the 17 pt title, the 13 pt text and
/// a 30 pt primary button.
struct HistoryEmptyCard: View {
    let state: HistoryEmptyState
    let onTestDictation: (@MainActor () -> Void)?
    let onOpenDataPrivacy: (@MainActor () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.kv.fill)
                .frame(width: 56, height: 56)
                .overlay {
                    KVDesignGlyph(data: "M8 2.5a5.5 5.5 0 1 1 0 11 5.5 5.5 0 0 1 0-11zM8 5v3l2 1.5")
                        .stroke(Color.kv.text2, style: StrokeStyle(lineWidth: 1.4 * 26 / 16, lineCap: .round, lineJoin: .round))
                        .frame(width: 26, height: 26)
                }
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.kv.text)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: text)
                .font(.system(size: 13))
                .foregroundStyle(Color.kv.text2)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
            if let action = buttonAction {
                Button(action: action.1) {
                    Text(verbatim: action.0)
                }
                .buttonStyle(KVButtonStyle(.primary, height: 30, fontSize: 13, horizontalPadding: 14))
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.kv.line, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch state {
        case .noHistory: return String(localized: "No History Yet", bundle: .module)
        case .savingOff: return String(localized: "Save History is off", bundle: .module)
        }
    }

    private var text: String {
        switch state {
        case .noHistory: return String(localized: "Completed dictations appear here. Hold your shortcut anywhere to make your first one.", bundle: .module)
        case .savingOff: return String(localized: "New dictations are not kept. Turn it on in Data & Privacy to see them here.", bundle: .module)
        }
    }

    private var buttonAction: (String, () -> Void)? {
        switch state {
        case .noHistory:
            guard let onTestDictation else { return nil }
            return (String(localized: "Try a Test Dictation", bundle: .module), { onTestDictation() })
        case .savingOff:
            guard let onOpenDataPrivacy else { return nil }
            return (String(localized: "Open Data & Privacy", bundle: .module), { onOpenDataPrivacy() })
        }
    }
}

// MARK: - Filter chip

/// UI v2 wave 5a: one History filter chip — a 22 pt capsule, cursor-soft
/// with cursor-ink words while it narrows the list, neutral fill otherwise.
/// The words always say the state; the colour only repeats it.
struct HistoryFilterChip<Label: View>: View {
    let isActive: Bool
    let showsMenuIndicator: Bool
    @ViewBuilder let label: () -> Label
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 3) {
            label()
                .lineLimit(1)
            if showsMenuIndicator {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 11, weight: isActive ? .semibold : .regular))
        .foregroundStyle(isActive ? Color.kv.cursorInk : Color.kv.text)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(isActive ? Color.kv.cursorSoft : Color.kv.fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(isActive ? Color.kv.cursorInk : Color.kv.text2, lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

// MARK: - Dashboard

/// The stats strip (Window.dc `isStats`): `wash` tiles, radius 10, padding
/// 8/12, the 11 pt label over the 17 pt semibold monospaced figure, one row.
/// Every figure is a SQL aggregate over the current filters; the typing
/// speed the time-saved figure assumes is its tooltip.
struct HistoryDashboardView: View {
    let dashboard: HistoryViewModel.Dashboard
    let isFiltered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            tile(String(localized: "Sessions", bundle: .module), String(localized: "Sessions Recorded", bundle: .module), dashboard.sessions.formatted())
            tile(String(localized: "Words", bundle: .module), String(localized: "Words Dictated", bundle: .module), dashboard.words.formatted())
            tile(String(localized: "Words / min", bundle: .module), String(localized: "Words / min", bundle: .module), dashboard.wordsPerMinute.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—")
            tile(String(localized: "Keystrokes", bundle: .module), String(localized: "Keystrokes Saved", bundle: .module), dashboard.keystrokesSaved.formatted())
            tile(String(localized: "Avg AI", bundle: .module), String(localized: "Avg AI Time", bundle: .module), dashboard.averageAIMilliseconds.map(Self.seconds) ?? "—")
            tile(String(localized: "Time saved", bundle: .module), String(localized: "Time Saved", bundle: .module), Self.timeSaved(dashboard.timeSavedSeconds), help: footnote)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dashboard")
    }

    private var footnote: String {
        isFiltered
            ? String(localized: "Figures cover the current filters. Time saved assumes typing at \(HistoryViewModel.assumedTypingWordsPerMinute) words per minute.", bundle: .module)
            : String(localized: "Time saved assumes typing at \(HistoryViewModel.assumedTypingWordsPerMinute) words per minute.", bundle: .module)
    }

    private func tile(_ title: String, _ spoken: String, _ value: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: title)
                .font(.system(size: 11))
                .foregroundStyle(Color.kv.text2)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(verbatim: value)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.kv.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .timingCurve(0.34, 1.4, 0.64, 1, duration: 0.32), value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.kv.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(Text(verbatim: help ?? spoken))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
        .accessibilityValue(Text(verbatim: value))
        .accessibilityHint(Text(verbatim: help ?? ""))
    }

    static func seconds(_ milliseconds: Int) -> String {
        (Double(milliseconds) / 1_000).formatted(.number.precision(.fractionLength(1))) + " s"
    }

    static func timeSaved(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return String(localized: "\(total) s", bundle: .module) }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        return hours > 0 ? String(localized: "\(hours) h \(minutes) m", bundle: .module) : String(localized: "\(minutes) m", bundle: .module)
    }
}

// MARK: - Rows

/// One list row (Window.dc `hist`): padding 10/12, a `line-2` rule under
/// it, the selected one on `select`. Line 1: where the text went (history
/// keeps no app name, J.5) in 12 pt semibold and the time in 11 pt `text-2`;
/// then two lines of the text; then the meta line — the AI mode chip, the
/// length, the kept-recording mark and the warn "Fallback" chip.
struct HistoryRow: View {
    let entry: HistoryEntry
    let hasAudio: Bool
    let isSelected: Bool
    let isFocused: Bool
    let isSelecting: Bool
    let isChecked: Bool
    let onToggleCheck: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isSelecting {
                Button(action: onToggleCheck) {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(isChecked ? Color.kv.cursor : Color.kv.text2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isChecked ? "Checked" : "Not checked")
                .accessibilityHint("Toggles this item for bulk actions")
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: entry.rowTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.kv.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(entry.createdAt.historyRowLabel)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color.kv.text2)
                        .lineLimit(1)
                }
                Text(verbatim: entry.finalText.oneLinePreview)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kv.text)
                    .lineSpacing(1.5)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if entry.mode != .off {
                        HistoryMiniChip(text: entry.mode.displayName, tone: .cursor)
                    }
                    if let milliseconds = entry.recordingDurationMilliseconds {
                        Text(verbatim: Self.durationLabel(milliseconds))
                    }
                    if hasAudio {
                        Image(systemName: "waveform")
                            .accessibilityLabel("Recording kept")
                    }
                    if entry.isFallback {
                        HistoryMiniChip(text: String(localized: "Fallback", bundle: .module), tone: .warn)
                    }
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color.kv.text2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.kv.select : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.kv.line2).frame(height: 1)
        }
        .overlay {
            if isFocused {
                Rectangle().strokeBorder(Color.kv.cursor, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.accessibilitySummary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(Text(verbatim: KVAccessibility.selectionValue(isSelected)))
    }

    /// "0:12", Window.dc's clock style.
    static func durationLabel(_ milliseconds: Int) -> String {
        AudioPlaybackStrip.clock(TimeInterval(milliseconds) / 1_000)
    }
}

/// Window.dc's in-row chip: 10 pt bold, padding 1/6, radius 8, the tone's
/// soft ground and ink.
struct HistoryMiniChip: View {
    let text: String
    let tone: KVTone

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tone.ink.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tone.soft.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .fixedSize()
    }
}
