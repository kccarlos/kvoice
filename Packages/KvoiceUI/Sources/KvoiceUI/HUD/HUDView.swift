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

/// SwiftUI content hosted by `HUDPanel`. It has no buttons or focusable
/// controls during dictation, so the target application remains interactive.
/// Two states take a click, never making the panel key: the failure that
/// keeps the transcript (Copy / Insert Again, ADR-022 item 6) and Model
/// unavailable's "Open Speech Models to reinstall" link (UI v2 fidelity F5).
///
/// UI v2 recorder (`Recorder.dc.html`): one glyph, one title, one subtitle,
/// one trailing signal. Orange (`kv.voice`) while it listens, blue
/// (`kv.cursor`) while it makes text, amber (`kv.warn`) when it needs the
/// user, red (`kv.err`) when it failed. Two recorder styles (ADR-021) render
/// the same `HUDViewState`:
///
/// - **Mini**: a 316 × 54 capsule on the opaque `kv.hud` surface; a rounded
///   rectangle (radius 18) once it carries live text or a kept transcript.
/// - **Notch**: an opaque black shape hanging from the menu bar under the
///   camera housing (`HUDPlacement`), always dark, 380 × 44 (62 with live
///   text), widened by the controller past a wider housing.
///
/// Motion (`Motion.dc.html` § 1·2·3, 4·6, 5, 7): the pill springs in (scale
/// .92 → 1 and a 6 pt rise) and drops back out; the notch grows out of the
/// housing (width 190 → full, height 0 → full) and its content fades in
/// 120 ms later. Everything animates inside the panel's fixed frame — the
/// `NSPanel` frame never animates. The glyph morphs (`HUDGlyphView`), the
/// meter follows `KVLevelFollower` and folds into the glyph on release, the
/// clock's digits roll, live words sharpen in (`HUDLiveWords`). Reduce
/// Motion: 150 ms cross-fades, nothing moves or scales, colours still change.
///
/// The recoverable-transcript failure falls back to the Mini layout in
/// either style because the transcript must be selectable;
/// `HUDController.effectiveStyle` gives it Mini placement as well.
public struct HUDView: View {
    /// Width of every Mini state, the kept transcript included (F5: the
    /// design draws it 316 wide too).
    public static let panelWidth: CGFloat = 316
    public static let recoveryPanelWidth: CGFloat = 316
    /// One row: the capsule's height.
    public static let minimumPanelHeight: CGFloat = 54
    /// The notch's design width; `HUDPlacement.notchContentWidth` widens it
    /// past a wider housing.
    public static let notchPanelWidth: CGFloat = 380
    public static let notchPanelHeight: CGFloat = 44
    /// With a line of live text.
    public static let notchLivePanelHeight: CGFloat = 62
    public static let notchCornerRadius: CGFloat = 18
    /// The width the notch grows from (the design's collapsed shape).
    static let notchCollapsedWidth: CGFloat = 190

    /// How the view enters and leaves. `.still` (previews, renders) draws
    /// the shown state without motion; the controller drives `.live`.
    public enum Presentation: Equatable, Sendable {
        case still
        /// `id` changes on every appearance of the panel — a fresh content
        /// tree, so a new job's glyph does not morph out of the last job's
        /// check — and `shown` turns false for the exit.
        case live(id: Int, shown: Bool)
    }

    public let state: HUDViewState
    public let style: HUDStyle
    /// Layout width for the notch style, from the controller; nil uses
    /// `notchPanelWidth`. Ignored by the mini style.
    public let notchWidth: CGFloat?
    /// The recovery buttons' handlers; nil renders the buttons disabled
    /// (previews, a shell that has not wired them).
    public let recoveryActions: HUDRecoveryActions?
    /// Model unavailable's link; nil renders it as plain text.
    public let openSpeechModels: (@MainActor @Sendable () -> Void)?
    public let presentation: Presentation
    /// Renders force Reduce Motion so stills are deterministic; nil reads
    /// the environment.
    public let reduceMotionOverride: Bool?

    public init(
        state: HUDViewState,
        style: HUDStyle = .mini,
        notchWidth: CGFloat? = nil,
        recoveryActions: HUDRecoveryActions? = nil,
        openSpeechModels: (@MainActor @Sendable () -> Void)? = nil,
        presentation: Presentation = .still,
        reduceMotionOverride: Bool? = nil
    ) {
        self.state = state
        self.style = style
        self.notchWidth = notchWidth
        self.recoveryActions = recoveryActions
        self.openSpeechModels = openSpeechModels
        self.presentation = presentation
        self.reduceMotionOverride = reduceMotionOverride
    }

    public var body: some View {
        HUDContent(view: self, shown: presentationShown, animatesEntrance: presentationAnimates)
            .id(presentationID)
    }

    private var presentationID: Int {
        if case .live(let id, _) = presentation { return id }
        return 0
    }

    private var presentationShown: Bool {
        if case .live(_, let shown) = presentation { return shown }
        return true
    }

    private var presentationAnimates: Bool {
        if case .live = presentation { return true }
        return false
    }

    /// The same view with another presentation (the controller's exit).
    func withPresentation(_ presentation: Presentation) -> HUDView {
        HUDView(
            state: state, style: style, notchWidth: notchWidth, recoveryActions: recoveryActions,
            openSpeechModels: openSpeechModels, presentation: presentation,
            reduceMotionOverride: reduceMotionOverride
        )
    }

    /// The layout height of the notch for `state`.
    public static func notchHeight(for state: HUDViewState) -> CGFloat {
        if state.partialTranscript != nil { return notchLivePanelHeight }
        // H5 keeps the instruction under the title from 4:30, so the long
        // state carries a third line (the design draws only the hint).
        if case .recording(let recording) = state.phase, recording.isLong { return notchLongPanelHeight }
        return notchPanelHeight
    }

    /// The long-dictation notch: title, instruction and the amber hint.
    public static let notchLongPanelHeight: CGFloat = 58
}

/// The body of `HUDView`, keyed by the presentation id so each appearance
/// starts from a fresh tree (its `@State`: the entrance flag, the level
/// follower, the glyph's morph).
private struct HUDContent: View {
    let view: HUDView
    let shown: Bool
    let animatesEntrance: Bool

    @Environment(\.accessibilityReduceMotion) private var environmentReduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var appeared = false
    @State private var follower = KVLevelFollower()

    private var state: HUDViewState { view.state }
    private var reduceMotion: Bool { view.reduceMotionOverride ?? environmentReduceMotion }
    /// On screen and meant to be: entered, and not leaving.
    private var visible: Bool { (appeared || !animatesEntrance) && shown }

    var body: some View {
        Group {
            if view.style == .notch, state.recoverableTranscript == nil {
                notchBody
            } else {
                miniBody
            }
        }
        // One VoiceOver element for the read-only phases; a container when
        // a button or the link is present, so each is reachable with its
        // own label and hint.
        .accessibilityElement(children: takesClicks ? .contain : .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAddTraits(.updatesFrequently)
        // Normal HUD phases never intercept input; the kept transcript (to
        // select it, and its buttons) and the Speech Models link do.
        .allowsHitTesting(takesClicks)
        .onAppear {
            follower = KVLevelFollower(level: rawLevel)
            // A fresh tree (new presentation id) draws once hidden, then
            // enters on the next turn of the run loop.
            guard animatesEntrance, !appeared else { return }
            DispatchQueue.main.async { appeared = true }
        }
        .onChange(of: rawLevel) { _, raw in follower.follow(raw: raw, at: Date()) }
    }

    private var takesClicks: Bool {
        state.recoverableTranscript != nil || state.offersSpeechModelsLink
    }

    private var rawLevel: Double {
        guard let recording, recording.captureStarted else { return 0 }
        return recording.inputLevel
    }

    private var recording: HUDRecordingState? {
        if case .recording(let recording) = state.phase { return recording }
        return nil
    }

    private var increasedContrast: Bool { contrast == .increased }

    // MARK: Motion

    /// Enter / exit for Mini: scale .92 → 1 with a 6 pt rise on the
    /// design's spring, opacity with it; out: back to .92 and fade 180 ms.
    /// Reduce Motion: a 150 ms fade only.
    private var entranceSpring: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.78)
    }

    private var entranceFade: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : (visible ? .easeOut(duration: 0.2) : .easeOut(duration: 0.18))
    }

    // MARK: Mini

    private var miniIsTall: Bool {
        state.partialTranscript != nil || state.recoverableTranscript != nil
    }

    private var miniBody: some View {
        let shape = HUDPillShape()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                HUDGlyphView(glyph: state.glyph, diameter: 30, onNotch: false, level: follower.level, reduceMotion: reduceMotion)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .center, spacing: 6) {
                        titleText(size: 13, fits: headerFit(.mini).titleFits)
                            .foregroundStyle(Color.kv.text)
                        chips(onNotch: false, fit: headerFit(.mini))
                    }
                    subtitleLines(onNotch: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailingSlot(onNotch: false)
            }
            // One row is the 54 pt capsule; a subtitle that wraps grows it
            // with 8 pt to spare above and below.
            .padding(.vertical, miniIsTall ? 0 : 8)
            .frame(minHeight: miniIsTall ? 30 : Self.rowHeight, alignment: .center)

            if let partial = state.partialTranscript {
                HUDLiveWords(
                    text: partial, fontSize: 13, lineHeight: 18.2, maxLines: 2,
                    newest: Color.kv.text, older: Color.kv.text2, reduceMotion: reduceMotion
                )
                .padding(.leading, 40)
            }

            if let transcript = state.recoverableTranscript {
                ScrollView(.vertical) {
                    Text(verbatim: transcript)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.kv.text)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.kv.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel(Text("Transcript to copy", bundle: .module))
            }

            if !state.recoveryActions.isEmpty {
                recoveryButtons
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 14)
        .padding(.top, miniIsTall ? 11 : 0)
        .padding(.bottom, miniIsTall ? 12 : 0)
        .frame(width: HUDView.panelWidth, alignment: .leading)
        .frame(minHeight: HUDView.minimumPanelHeight, alignment: .center)
        .background(Color.kv.hud, in: shape)
        .overlay {
            // The design's 0.5 pt hairline; the panel's own window shadow
            // does the lift.
            shape.strokeBorder(
                increasedContrast ? Color.kv.text.opacity(0.6) : Color.kv.line,
                lineWidth: increasedContrast ? 1 : 0.5
            )
        }
        .animation(entranceSpring) { content in
            content
                .scaleEffect(visible || reduceMotion ? 1 : 0.92)
                .offset(y: visible || reduceMotion ? 0 : 6)
        }
        .animation(entranceFade) { content in
            content.opacity(visible ? 1 : 0)
        }
    }

    static let rowHeight: CGFloat = 54

    /// ADR-022 item 6. Trailing buttons, Insert Again as the prominent blue
    /// one because it is the recovery the user most often wants. No key
    /// equivalents: the panel is never key, and Escape (dismiss) is handled
    /// by the shell's monitor, not here.
    private var recoveryButtons: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            ForEach(state.recoveryActions) { action in
                Button {
                    view.recoveryActions?.perform(action)
                } label: {
                    Text(action.title)
                        .font(.system(size: 12, weight: action == .insertAgain ? .semibold : .regular))
                }
                .buttonStyle(HUDRecoveryButtonStyle(prominent: action == .insertAgain))
                .controlSize(.small)
                .disabled(view.recoveryActions == nil)
                .accessibilityLabel(action.accessibilityLabel)
                .accessibilityHint(action.accessibilityHint)
            }
        }
    }

    // MARK: Notch

    /// Bottom corners only: the top edge sits flush against the menu bar.
    private var notchShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            bottomLeadingRadius: HUDView.notchCornerRadius,
            bottomTrailingRadius: HUDView.notchCornerRadius,
            style: .continuous
        )
    }

    private var notchBody: some View {
        let width = view.notchWidth ?? HUDView.notchPanelWidth
        let height = HUDView.notchHeight(for: state)
        let grown = visible || reduceMotion
        return ZStack(alignment: .top) {
            // H2: opaque black is deliberate, not a placeholder material —
            // the Notch style continues the camera housing it hangs under,
            // and a HUD is allowed to not match the system appearance
            // (`panels.md › HUD-style panels`). Do not "fix" this to a
            // material; that was considered and rejected in the 2026-09-16
            // design review (see `Docs/Architecture.md › The recorder HUD`).
            notchShape
                .fill(Color.black)
                .overlay {
                    notchShape.strokeBorder(Color.white.opacity(increasedContrast ? 0.5 : 0.14), lineWidth: 1)
                }
                // Motion § 1·2·3: grows out of the housing — width 380 ms,
                // height 320 ms on the design's overshoot curve; back in
                // without overshoot (a height cannot go below zero).
                .animation(grown ? .timingCurve(0.34, 1.56, 0.64, 1, duration: 0.38) : .easeIn(duration: 0.2)) { shape in
                    shape.frame(width: grown ? width : HUDView.notchCollapsedWidth)
                }
                .animation(grown ? .timingCurve(0.34, 1.56, 0.64, 1, duration: 0.32) : .easeIn(duration: 0.2)) { shape in
                    shape.frame(height: grown ? height : 0)
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.15) : nil) { shape in
                    shape.opacity(reduceMotion ? (visible ? 1 : 0) : 1)
                }

            notchContent(width: width, height: height)
                .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.16).delay(visible ? 0.12 : 0)) { content in
                    content.opacity(visible ? 1 : 0)
                }
        }
        .frame(width: width, height: height, alignment: .top)
        // Always dark: the kv tokens resolve to their dark values and
        // `.primary` is white whatever the system appearance.
        .environment(\.colorScheme, .dark)
    }

    private func notchContent(width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                HUDGlyphView(glyph: state.glyph, diameter: 24, onNotch: true, level: follower.level, reduceMotion: reduceMotion)
                chips(onNotch: true, fit: headerFit(.notch))

                VStack(alignment: .leading, spacing: 0) {
                    titleText(size: 12, fits: headerFit(.notch).titleFits)
                        .foregroundStyle(Color.white)
                    subtitleLines(onNotch: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailingSlot(onNotch: true)
            }

            if let partial = state.partialTranscript {
                HUDLiveWords(
                    text: partial, fontSize: 12, lineHeight: 15, maxLines: 1,
                    newest: .white, older: .white, reduceMotion: reduceMotion
                )
                .padding(.leading, 34)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(width: width, height: height, alignment: .leading)
    }

    // MARK: Shared pieces

    /// The title truncates only when it cannot fit the row even beside the
    /// smallest chip (`HUDHeaderFit`); otherwise it keeps its full width and
    /// the chip gives way.
    private func titleText(size: CGFloat, fits: Bool) -> some View {
        Text(state.title)
            .font(.system(size: size, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: fits, vertical: false)
            .layoutPriority(1)
    }

    /// How the title row degrades for this state in `style` (2026-10-22).
    private func headerFit(_ style: HUDStyle) -> HUDHeaderFit {
        HUDHeaderFit.resolve(
            title: state.title,
            ai: recording?.ai,
            finishingBadge: state.finishingBadge,
            style: style,
            notchWidth: view.notchWidth,
            clockText: recording.map { HUDViewState.formatElapsed($0.captureStarted ? $0.elapsed : .zero) } ?? "0:00"
        )
    }

    /// The AI action chip while recording (ADR-021), the action's badge
    /// while polishing (F5) and the "1 finishing" badge (ADR-022 item 7).
    /// `ModeChip`'s cursor-soft / cursor-ink resolve to the design's notch
    /// literals (#1E2A45 / #8AB0FA) under the notch's dark scheme.
    @ViewBuilder
    private func chips(onNotch: Bool, fit: HUDHeaderFit) -> some View {
        if let ai = recording?.ai {
            ModeChip(
                text: ai.chipText,
                symbolName: ai.chipSymbolName,
                isActive: ai.isEnabled,
                shortcut: fit.showsShortcut ? ai.chipShortcut : nil
            )
            .frame(maxWidth: fit.chipMaxWidth ?? .infinity, alignment: .leading)
            .fixedSize(horizontal: fit.chipMaxWidth == nil, vertical: false)
        }
        if let badge = state.processingBadge {
            ModeChip(text: badge)
                .frame(maxWidth: 120, alignment: .leading)
                .fixedSize(horizontal: onNotch, vertical: false)
        }
        if let badge = state.finishingBadge {
            ModeChip(text: badge).fixedSize()
        }
    }

    /// The instruction or outcome line. While recording: the instruction,
    /// and from 4:30 the length hint on a line of its own in amber (the
    /// instruction never disappears, H5 — the design drops it, see the F5
    /// design problems). Otherwise `HUDViewState.subtitle`.
    @ViewBuilder
    private func subtitleLines(onNotch: Bool) -> some View {
        let secondary = onNotch ? Self.notchText2 : Color.kv.text2
        if let recording {
            Text(recording.instruction)
                .font(.system(size: 11))
                .foregroundStyle(secondary)
                .lineLimit(1)
            if let hint = recording.lengthHint {
                Text(hint)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(onNotch ? Self.notchWarn : Color.kv.warnInk)
                    .lineLimit(1)
            }
        } else if let subtitle = state.subtitle {
            switch subtitle.style {
            case .link:
                Button {
                    view.openSpeechModels?()
                } label: {
                    Text(subtitle.text)
                        .font(.system(size: 11))
                        .foregroundStyle(onNotch ? Self.notchLink : Color.kv.cursorInk)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(view.openSpeechModels == nil)
                .accessibilityLabel(subtitle.text)
                .accessibilityHint(Text("Opens Speech Models in the KVoice window.", bundle: .module))
            case .plain:
                Text(subtitle.text)
                    .font(.system(size: 11))
                    .foregroundStyle(secondary)
                    .lineLimit(subtitle.wraps && !onNotch ? 3 : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: subtitle.wraps && !onNotch)
            }
        }
    }

    static let notchText2 = Color(red: 163 / 255, green: 164 / 255, blue: 174 / 255)
    static let notchWarn = Color(red: 1, green: 201 / 255, blue: 102 / 255)
    static let notchLink = Color(red: 138 / 255, green: 176 / 255, blue: 250 / 255)

    /// Meter and clock while recording. On release the bars fold into the
    /// glyph (each slides 8·(i+1) pt left and flattens to .4 while fading,
    /// 220 ms) and the clock fades.
    @ViewBuilder
    private func trailingSlot(onNotch: Bool) -> some View {
        if let recording {
            HStack(spacing: 10) {
                HUDMeter(
                    level: follower.level,
                    live: recording.captureStarted,
                    boxHeight: onNotch ? 18 : 22,
                    onNotch: onNotch,
                    reduceMotion: reduceMotion
                )
                clock(recording, onNotch: onNotch)
            }
            .fixedSize()
            .accessibilityHidden(true)
            .transition(reduceMotion ? .opacity.animation(.easeInOut(duration: 0.15)) : .asymmetric(
                insertion: .opacity.animation(.easeOut(duration: 0.2)),
                removal: AnyTransition.modifier(active: HUDMeterFold(active: true), identity: HUDMeterFold(active: false))
                    .animation(.easeOut(duration: 0.22))
            ))
        }
    }

    /// The clock (m:ss), whose digits roll (§ 7: numericText, 320 ms on
    /// cubic-bezier(.34,1.4,.64,1)); dimmed at 0:00 while the mic starts;
    /// amber from 4:30.
    private func clock(_ recording: HUDRecordingState, onNotch: Bool) -> some View {
        let text = HUDViewState.formatElapsed(recording.captureStarted ? recording.elapsed : .zero)
        let color: Color = state.detailTone == .warn
            ? (onNotch ? Self.notchWarn : Color.kv.warnInk)
            : (onNotch ? Self.notchText2 : Color.kv.text2)
        return Text(verbatim: text)
            .font(KVFont.metric())
            .foregroundStyle(color)
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .animation(reduceMotion ? nil : .timingCurve(0.34, 1.4, 0.64, 1, duration: 0.32), value: text)
            .opacity(recording.captureStarted ? 1 : 0.45)
            .frame(minWidth: 34, alignment: .trailing)
    }

    private var accessibilityLabel: String {
        var label = state.accessibilityTitle
        if let badge = state.processingBadge {
            label += ", \(badge)"
        }
        if let badge = state.finishingBadge {
            label += ", \(badge)"
        }
        if case .recording = state.phase, let detail = state.detail, !detail.isEmpty {
            return "\(label). \(detail)"
        }
        if let detail = state.spokenDetail, !detail.isEmpty {
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

/// The Mini outline: a capsule while the pill is one 54 pt row, a rounded
/// rectangle with the design's 18 pt radius once it grows (live text, a
/// kept transcript, a subtitle that wraps).
struct HUDPillShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        let radius = rect.height <= HUDView.minimumPanelHeight + 0.5 ? box.height / 2 : 18 - inset
        return Path(roundedRect: box, cornerRadius: max(0, radius), style: .continuous)
    }

    func inset(by amount: CGFloat) -> HUDPillShape {
        HUDPillShape(inset: inset + amount)
    }
}

/// The recorder's five-bar meter (Motion § 1·2·3 / 4·6): 3 pt bars, 2 pt
/// apart, at `4 + h·level·(box − 4)` pt for h = .45 .8 1 .7 .5 — live
/// signal, so 70 ms linear. While the mic starts every bar is a 6 pt stub
/// in `meter-off` (#4A4B55 on the notch).
struct HUDMeter: View {
    static let peaks: [CGFloat] = [0.45, 0.8, 1, 0.7, 0.5]

    let level: Double
    let live: Bool
    let boxHeight: CGFloat
    let onNotch: Bool
    let reduceMotion: Bool
    @Environment(\.hudMeterFolded) private var folded

    static func barHeight(peak: CGFloat, level: Double, live: Bool, boxHeight: CGFloat) -> CGFloat {
        guard live else { return 6 }
        return 4 + peak * CGFloat(min(max(level, 0), 1)) * (boxHeight - 4)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(Self.peaks.enumerated()), id: \.offset) { index, peak in
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: 3, height: Self.barHeight(peak: peak, level: level, live: live, boxHeight: boxHeight))
                    // The fold on release: into the glyph, flattened.
                    .scaleEffect(x: 1, y: folded ? 0.4 : 1)
                    .offset(x: folded ? -8 * CGFloat(index + 1) : 0)
            }
        }
        .frame(height: boxHeight, alignment: .center)
        .animation(reduceMotion ? nil : .linear(duration: 0.07), value: level)
        .animation(.easeInOut(duration: 0.22), value: live)
        .accessibilityHidden(true)
    }

    private var color: Color {
        if live { return onNotch ? HUDGlyphView.solid(.voice, onNotch: true) : Color.kv.voice }
        return onNotch ? Color(red: 74 / 255, green: 75 / 255, blue: 85 / 255) : Color.kv.meterOff
    }
}

/// The meter's removal on release (Motion § 1·2·3): the bars slide into
/// the glyph and flatten (`HUDMeter` reads the flag) while the slot fades.
private struct HUDMeterFold: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.hudMeterFolded, active)
            .opacity(active ? 0 : 1)
    }
}

private struct HUDMeterFoldedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var hudMeterFolded: Bool {
        get { self[HUDMeterFoldedKey.self] }
        set { self[HUDMeterFoldedKey.self] = newValue }
    }
}

/// Copy is a bordered `kv.surface` button; Insert Again the one blue
/// (`kv.cursor`) button. Drawn here rather than with `.borderedProminent`,
/// which greys out in a window that is not key — and the HUD panel never
/// is.
private struct HUDRecoveryButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .foregroundStyle(prominent ? Color.white : Color.kv.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(prominent ? Color.kv.cursor : Color.kv.surface, in: shape)
            .overlay {
                if !prominent {
                    shape.strokeBorder(Color.kv.line, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(shape)
    }
}

#if DEBUG
// The HUD is a nonactivating panel that only appears mid-dictation, so these
// are the practical way to see its states side by side;
// `LayoutSnapshotTests.testRenderEveryHUDState` renders all of them.
#Preview("HUD: every state, Mini") {
    ScrollView {
        VStack(spacing: 16) {
            ForEach(HUDViewState.galleryStates, id: \.name) { entry in
                HUDView(state: entry.state)
            }
        }
        .padding()
    }
}

#Preview("HUD: every state, Notch") {
    ScrollView {
        VStack(spacing: 16) {
            ForEach(HUDViewState.galleryStates.filter { $0.state.recoverableTranscript == nil }, id: \.name) { entry in
                HUDView(state: entry.state, style: .notch)
            }
        }
        .padding()
    }
}
#endif
