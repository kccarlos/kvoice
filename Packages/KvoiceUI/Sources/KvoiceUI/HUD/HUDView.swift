import Foundation
import KvoiceDomain
import SwiftUI

/// The shell's implementations of the failure HUD's recovery buttons
/// (ADR-022 item 6). Plain closures so `KvoiceUI` never sees the
/// controller; `HUDController.recoveryActions` holds the one instance.
public struct HUDRecoveryActions: Sendable {
    public let perform: @MainActor @Sendable (HUDRecoveryAction) -> Void

    public init(perform: @escaping @MainActor @Sendable (HUDRecoveryAction) -> Void) {
        self.perform = perform
    }
}

/// SwiftUI content hosted by `HUDPanel`.  It has no buttons or focusable
/// controls during dictation, so the target application remains interactive.
/// The one exception is the failure that keeps the transcript: it shows the
/// Copy / Insert Again buttons (ADR-022 item 6), which work on a mouse click
/// in the non-activating panel without ever making it key.
///
/// Two recorder styles (ADR-021) render the same `HUDViewState`:
///
/// - **Mini** (D.3's original): a floating material pill. Geometry is
///   deliberately stable across phases — a fixed panel width, a fixed symbol
///   slot, a detail area that reserves two lines, and a fixed trailing slot
///   that holds either the recording meter and clock or the activity
///   indicator — so recording → finalizing → transcribing → inserted swap
///   content in place instead of resizing the panel on every transition.
/// - **Notch**: a dark shape hanging from the menu bar under the camera
///   housing (`HUDPlacement`), one row tall: the AI indicator and action name
///   at the leading edge, the phase title in the middle, the meter and clock
///   at the trailing edge. Its width is given by the controller so it always
///   clears the housing.
///
/// The one state allowed to grow, in either style, is the recoverable-
/// transcript failure, which falls back to the mini layout because the
/// transcript must be selectable; `HUDController.effectiveStyle` gives it
/// Mini placement as well, so content and geometry never disagree.
public struct HUDView: View {
    /// Width of every regular mini state. Wide enough for the longest D.4
    /// title on one line at the headline size.
    public static let panelWidth: CGFloat = 380
    /// Width when a recoverable transcript is shown, the only wider state.
    public static let recoveryPanelWidth: CGFloat = 480
    public static let minimumPanelHeight: CGFloat = 72
    /// The notch style's minimum width; `HUDPlacement.notchContentWidth`
    /// widens it past the housing.
    public static let notchPanelWidth: CGFloat = 360
    public static let notchPanelHeight: CGFloat = 44
    public static let notchCornerRadius: CGFloat = 18

    public let state: HUDViewState
    public let style: HUDStyle
    /// Layout width for the notch style, from the controller; nil uses
    /// `notchPanelWidth`. Ignored by the mini style.
    public let notchWidth: CGFloat?
    /// The recovery buttons' handlers; nil renders the buttons disabled
    /// (previews, a shell that has not wired them).
    public let recoveryActions: HUDRecoveryActions?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        state: HUDViewState,
        style: HUDStyle = .mini,
        notchWidth: CGFloat? = nil,
        recoveryActions: HUDRecoveryActions? = nil
    ) {
        self.state = state
        self.style = style
        self.notchWidth = notchWidth
        self.recoveryActions = recoveryActions
    }

    public var body: some View {
        Group {
            if style == .notch, state.recoverableTranscript == nil {
                notchBody
            } else {
                miniBody
            }
        }
        // One VoiceOver element for the read-only phases; a container when
        // the recovery buttons are present, so each button is reachable
        // with its own label and hint.
        .accessibilityElement(children: state.recoveryActions.isEmpty ? .ignore : .contain)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAddTraits(.updatesFrequently)
        // Normal HUD phases never intercept input. A failed clipboard
        // fallback is the exception: the exact transcript must be selectable
        // while this nonactivating warning remains onscreen.
        .allowsHitTesting(state.recoverableTranscript != nil)
        // Keyed on the phase kind, not the whole state, so a meter tick or
        // clock tick during recording is not a cross-fade.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: state.phase.kind)
    }

    // MARK: Mini

    private var miniBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                symbol

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(state.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1...2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let ai = recordingAI {
                            AIActionBadge(indicator: ai, onDark: false)
                        }
                        if let badge = state.finishingBadge {
                            FinishingBadge(text: badge)
                        }
                    }

                    // Reserved even when empty so a state without a detail
                    // line is the same height as one with it.
                    Text(state.detail ?? " ")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2...3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailingSlot
            }

            // ADR-017: live partial text of a streaming dictation. Present
            // (possibly empty) from the moment streaming starts so the panel
            // reserves the space once instead of growing on the first word;
            // head-truncated so the newest words stay visible.
            if let partial = state.partialTranscript {
                partialLine(partial, lines: 2)
            }

            if let transcript = state.recoverableTranscript {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcript")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.vertical) {
                        Text(verbatim: transcript)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 220)
                    .accessibilityLabel("Transcript to copy")
                }
            }

            if !state.recoveryActions.isEmpty {
                recoveryButtons
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(
            width: state.recoverableTranscript == nil ? Self.panelWidth : Self.recoveryPanelWidth,
            alignment: .leading
        )
        .frame(minHeight: Self.minimumPanelHeight, alignment: .leading)
        .miniPillBackground(increasedContrast: increasedContrast)
    }

    /// ADR-022 item 6. Bordered buttons at the trailing edge, Insert Again
    /// as the prominent one because it is the recovery the user most
    /// often wants. No key equivalents: the panel is never key, and
    /// Escape (dismiss) is handled by the shell's monitor, not here.
    private var recoveryButtons: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            ForEach(state.recoveryActions) { action in
                Button {
                    recoveryActions?.perform(action)
                } label: {
                    Label(action.title, systemImage: action.symbolName)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(action == .insertAgain ? .accentColor : nil)
                .disabled(recoveryActions == nil)
                .accessibilityLabel(action.accessibilityLabel)
                .accessibilityHint(action.accessibilityHint)
            }
        }
    }

    // MARK: Notch

    /// Bottom corners only: the top edge sits flush against the menu bar.
    private var notchShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            bottomLeadingRadius: Self.notchCornerRadius,
            bottomTrailingRadius: Self.notchCornerRadius,
            style: .continuous
        )
    }

    private var notchBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                // Leading slot: the recording dot and the AI controls while
                // recording, otherwise the phase symbol — same minimum width
                // either way, so the title does not shift when recording
                // ends.
                Group {
                    if let ai = recordingAI {
                        HStack(spacing: 8) {
                            symbol
                            AIActionBadge(indicator: ai, onDark: true)
                        }
                    } else {
                        symbol
                    }
                }
                .frame(minWidth: 28, alignment: .leading)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(state.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let badge = state.finishingBadge {
                            FinishingBadge(text: badge)
                        }
                    }
                    if let detail = state.detail, !detail.isEmpty {
                        // H3: .caption2 sat at the 10 pt macOS floor; .subheadline
                        // is 11 pt and still fits `notchPanelHeight` unchanged.
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailingSlot
            }

            if let partial = state.partialTranscript {
                partialLine(partial, lines: 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 9)
        .frame(width: notchWidth ?? Self.notchPanelWidth, alignment: .leading)
        .frame(minHeight: Self.notchPanelHeight, alignment: .top)
        // H2: opaque black is deliberate, not a placeholder material — the
        // Notch style continues the camera housing it hangs under, and a
        // HUD is allowed to not match the system appearance
        // (`panels.md › HUD-style panels`). Do not "fix" this to a
        // material; that was considered and rejected in the 2026-09-16
        // design review (see `Docs/Architecture.md › The recorder HUD`).
        .background(Color.black, in: notchShape)
        .overlay {
            notchShape.strokeBorder(Color.white.opacity(increasedContrast ? 0.5 : 0.14), lineWidth: 1)
        }
        // Black background: fix the scheme so `.primary` is white whatever
        // the system appearance.
        .environment(\.colorScheme, .dark)
    }

    // MARK: Shared pieces

    private var increasedContrast: Bool {
        contrast == .increased
    }

    fileprivate static let miniPillShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    /// The AI indicator only while recording; nil for every other phase and
    /// for a job that carries none (the onboarding test).
    private var recordingAI: HUDAIIndicator? {
        if case .recording(let recording) = state.phase {
            return recording.ai
        }
        return nil
    }

    /// The phase symbol — except while recording, where the slot holds the
    /// recording dot: hollow and pulsing until the first buffer with signal
    /// ("Starting mic…"), solid once the recording is live (2026-09-16).
    @ViewBuilder
    private var symbol: some View {
        if case .recording(let recording) = state.phase {
            RecordingDot(live: recording.captureStarted, reduceMotion: reduceMotion)
                .frame(width: style == .notch ? 16 : 28, height: 28)
                .accessibilityHidden(true)
        } else {
            Image(systemName: state.symbolName)
                .font(.system(size: style == .notch ? 16 : 22, weight: .semibold))
                .foregroundStyle(symbolColor)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
    }

    private func partialLine(_ partial: String, lines: Int) -> some View {
        Text(verbatim: partial.isEmpty ? " " : partial)
            .font(style == .notch ? .caption : .callout)
            .foregroundStyle(.primary)
            .lineLimit(lines, reservesSpace: true)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .privacySensitive()
            // Announcing every revision would talk over the user;
            // the outcome announcement carries the result.
            .accessibilityHidden(true)
    }

    /// Meter and clock while recording, activity indicator while working,
    /// otherwise empty — always the same width, so the text column does not
    /// reflow between phases.
    @ViewBuilder
    private var trailingSlot: some View {
        Group {
            if case .recording(let recording) = state.phase {
                // Starting: every bar inactive and the clock dimmed at 0:00;
                // the level and the clock only move once the recording is
                // live (the controller holds both at zero until then).
                HStack(spacing: 8) {
                    Meter(level: recording.captureStarted ? recording.inputLevel : 0, reduceMotion: reduceMotion)
                    Text(HUDViewState.formatElapsed(recording.captureStarted ? recording.elapsed : .zero))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .opacity(recording.captureStarted ? 1 : 0.45)
                        .frame(minWidth: 36, alignment: .trailing)
                }
            } else if state.showsActivityIndicator {
                if reduceMotion {
                    Image(systemName: "hourglass")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                Color.clear
            }
        }
        .frame(width: 76, height: 28, alignment: .trailing)
        .accessibilityHidden(true)
    }

    private var symbolColor: Color {
        switch state.symbolTone {
        case .neutral: return .primary
        case .accent: return .accentColor
        case .secondary: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .fatal: return .red
        }
    }

    private var accessibilityLabel: String {
        var label = state.accessibilityTitle
        if let badge = state.finishingBadge {
            label += ", \(badge)"
        }
        if let detail = state.detail, !detail.isEmpty {
            return "\(label). \(detail)"
        }
        return label
    }

    /// The parts that change often go in the value, which VoiceOver reads on
    /// demand rather than announcing on every change.
    private var accessibilityValue: String {
        if case .recording(let recording) = state.phase {
            let level = String(localized: "Input level \(Int(recording.inputLevel * 100)) percent, \(HUDViewState.formatElapsed(recording.elapsed)) elapsed", bundle: .module)
            if let ai = recording.ai {
                return "\(level). \(ai.accessibilityDescription)"
            }
            return level
        }
        return ""
    }
}

/// ADR-022 item 7: "1 finishing" beside the title while an older job is
/// still in post-processing behind the one shown. A capsule in the same
/// caption weight as the AI badge; never a control.
struct FinishingBadge: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.18), in: Capsule())
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// ADR-021: the sparkles indicator plus the action name and its ⌘ badge.
/// A plain label, not a control — the HUD never takes input; the keys are
/// handled by the recording key monitor.
private struct AIActionBadge: View {
    let indicator: HUDAIIndicator
    let onDark: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: indicator.symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(indicator.isEnabled ? Color.accentColor : Color.secondary)
            if let name = indicator.actionName {
                Text(verbatim: name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(indicator.isEnabled ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120, alignment: .leading)
            }
            if let badge = indicator.shortcutBadge {
                Text(verbatim: badge)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            (onDark ? Color.white : Color.primary).opacity(0.1),
            in: Capsule(style: .continuous)
        )
        .accessibilityHidden(true)
    }
}

#if DEBUG
// One preview per phase. The HUD is a nonactivating panel that only appears
// mid-dictation, so these are the only practical way to see its states side by
// side without recording something for each one.
#Preview("HUD: recording") {
    HUDView(state: HUDViewState(
        phase: .recording(HUDRecordingState(
            inputLevel: 0.62,
            elapsed: .seconds(7),
            mode: .pushToTalk,
            ai: HUDAIIndicator(isEnabled: true, actionName: "Polish", shortcutBadge: "⌘1")
        ))
    ))
    .padding()
}

#Preview("HUD: starting mic (both styles)") {
    VStack(spacing: 24) {
        HUDView(state: HUDViewState(
            phase: .recording(HUDRecordingState(
                mode: .pushToTalk,
                ai: HUDAIIndicator(isEnabled: true, actionName: "Polish", shortcutBadge: "⌘1"),
                captureStarted: false
            ))
        ))
        HUDView(
            state: HUDViewState(
                phase: .recording(HUDRecordingState(
                    mode: .pushToTalk,
                    ai: HUDAIIndicator(isEnabled: true, actionName: "Polish", shortcutBadge: "⌘1"),
                    captureStarted: false
                ))
            ),
            style: .notch,
            notchWidth: 420
        )
    }
    .padding()
}

#Preview("HUD: recording, notch style") {
    VStack(spacing: 24) {
        HUDView(
            state: HUDViewState(
                phase: .recording(HUDRecordingState(
                    inputLevel: 0.62,
                    elapsed: .seconds(7),
                    mode: .pushToTalk,
                    ai: HUDAIIndicator(isEnabled: true, actionName: "Polish", shortcutBadge: "⌘1")
                ))
            ),
            style: .notch,
            notchWidth: 420
        )
        HUDView(
            state: HUDViewState(
                phase: .recording(HUDRecordingState(
                    inputLevel: 0.2,
                    elapsed: .seconds(71),
                    mode: .toggle,
                    ai: HUDAIIndicator(isEnabled: false, actionName: "Translate", shortcutBadge: "⌘2")
                ))
            ),
            style: .notch
        )
        HUDView(state: HUDViewState(phase: .transcribing), style: .notch)
        HUDView(state: HUDViewState(phase: .completed(HUDCompletionState(kind: .success))), style: .notch)
    }
    .padding()
}

#Preview("HUD: transcribing") {
    HUDView(state: HUDViewState(phase: .transcribing))
        .padding()
}

#Preview("HUD: processing AI") {
    HUDView(state: HUDViewState(
        phase: .processingAI(HUDProcessingAIState(
            mode: .translate,
            targetLanguageDisplayName: "Japanese"
        ))
    ))
    .padding()
}

#Preview("HUD: completed with warning") {
    HUDView(state: HUDViewState(
        phase: .completed(HUDCompletionState(
            kind: .clipboardFallback,
            warningMessage: "Copied to the clipboard instead."
        ))
    ))
    .padding()
}

// The widest layout: a failed insertion keeps the transcript selectable so the
// user can rescue it, which is the one state where the HUD accepts clicks.
#Preview("HUD: failed with recoverable transcript") {
    HUDView(state: HUDViewState(
        phase: .failed(HUDFailureState(
            code: "insertion.failed",
            message: "Could not insert or copy the transcript."
        )),
        recoverableTranscript: """
        I think we should ship the menu bar work first, then look at the \
        onboarding copy.
        """
    ))
    .padding()
}
#endif

/// The recording indicator (2026-09-16): a hollow ring that pulses while
/// the input route is still coming up, a solid accent dot once the first
/// buffer with signal has been captured. The pulse is an opacity cycle on
/// the ring only, so it is a repaint; under Reduce Motion the ring is
/// static, matching the meter's own animation guard.
///
/// Shared with the status menu's header row (P-D3, `StatusMenuHeaderView`),
/// which adds the idle form: a hollow ring in `tint` that never pulses.
struct RecordingDot: View {
    let live: Bool
    let reduceMotion: Bool
    /// The ring and dot colour; the HUD uses the accent, the menu's idle
    /// row a secondary tint so a menu that is not recording shows no accent.
    var tint: Color = .accentColor
    /// False for the idle ring: hollow, static, whatever `live` says.
    var pulses = true
    var diameter: CGFloat = 12

    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(tint, lineWidth: 2)
                .opacity(live ? 0 : (pulsing ? 0.35 : 1))
            Circle()
                .fill(tint)
                .opacity(live ? 1 : 0)
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: live)
        .onAppear { startPulsingIfNeeded() }
        .onChange(of: live) { _, _ in startPulsingIfNeeded() }
        .onChange(of: pulses) { _, _ in startPulsingIfNeeded() }
    }

    private func startPulsingIfNeeded() {
        guard !live, !reduceMotion, pulses else {
            pulsing = false
            return
        }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}

/// H1/N22: Mini's pill on macOS 26 and later — the textbook floating
/// functional element Liquid Glass is for (`liquid-glass.md › The two
/// layers`). Below 26, the material path is unchanged, border included;
/// glass draws its own edge, so the border is material-only. Glass answers
/// Reduce Transparency and Increase Contrast by itself (`liquid-glass.md ›
/// Which variant`), so `increasedContrast` only matters on the material path.
private extension View {
    @ViewBuilder
    func miniPillBackground(increasedContrast: Bool) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: HUDView.miniPillShape)
        } else {
            self
                .background(
                    increasedContrast ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.regularMaterial),
                    in: HUDView.miniPillShape
                )
                .overlay {
                    HUDView.miniPillShape
                        .strokeBorder(Color.primary.opacity(increasedContrast ? 0.6 : 0.12), lineWidth: 1)
                }
        }
    }
}

/// Five bars driven by the smoothed level from `HUDRecordingFeedbackFilter`.
/// The bars are fixed-size and only their fill changes, so a level update is
/// a repaint, not a layout pass. Shared with the status menu's header row
/// (P-D3), which draws it at `scale` 0.75 to fit a menu row.
struct Meter: View {
    let level: Double
    let reduceMotion: Bool
    var scale: CGFloat = 1
    /// The lit bars' colour; the menu row passes the selected-text colour
    /// while highlighted, where accent-on-accent would vanish.
    var tint: Color = .accentColor
    var inactive: Color = Color.secondary.opacity(0.25)

    var body: some View {
        HStack(alignment: .bottom, spacing: 2 * scale) {
            ForEach(0..<5, id: \.self) { index in
                let threshold = Double(index + 1) / 5
                Capsule(style: .continuous)
                    .fill(level >= threshold ? tint : inactive)
                    .frame(width: 4 * scale, height: CGFloat(8 + index * 3) * scale)
            }
        }
        .frame(height: 24 * scale, alignment: .bottom)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}
