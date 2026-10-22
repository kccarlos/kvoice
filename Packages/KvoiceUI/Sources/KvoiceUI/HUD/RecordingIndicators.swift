import SwiftUI

/// Shared with the status menu's header row (P-D3, `StatusMenuHeaderView`):
/// a hollow ring that pulses while the input route is still coming up, a
/// solid dot once the first buffer with signal has been captured, and the
/// idle form — a hollow ring in `tint` that never pulses. The pulse is an
/// opacity cycle on the ring only, so it is a repaint; under Reduce Motion
/// the ring is static.
struct RecordingDot: View {
    let live: Bool
    let reduceMotion: Bool
    /// The ring and dot colour; the menu's idle row passes a secondary tint
    /// so a menu that is not recording shows no colour.
    var tint: Color = Color.kv.voice
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

/// Five bars of the UI v2 level meter (`kv.voice` when live, `kv.meterOff`
/// while the mic is still starting), driven by the smoothed level from
/// `HUDRecordingFeedbackFilter`: each bar keeps its own resting height and
/// scales between 45 % and 100 % of it with the level, so silence still
/// reads as a live meter. Shared with the status menu's header row (P-D3),
/// which draws it at `scale` 0.75 with its own tints.
struct Meter: View {
    static let barHeights: [CGFloat] = [8, 14, 20, 12, 6]

    let level: Double
    let reduceMotion: Bool
    var scale: CGFloat = 1
    /// False while the mic is starting: every bar unlit at full height.
    var live = true
    /// The lit bars' colour; the menu row passes the selected-text colour
    /// while highlighted.
    var tint: Color = Color.kv.voice
    var inactive: Color = Color.kv.meterOff

    static func barScale(level: Double, live: Bool) -> CGFloat {
        guard live else { return 1 }
        return 0.45 + 0.55 * CGFloat(min(max(level, 0), 1))
    }

    var body: some View {
        let factor = Self.barScale(level: level, live: live)
        HStack(alignment: .center, spacing: 2 * scale) {
            ForEach(Array(Self.barHeights.enumerated()), id: \.offset) { _, height in
                Capsule(style: .continuous)
                    .fill(live ? tint : inactive)
                    .frame(width: 3 * scale, height: height * scale * factor)
            }
        }
        .frame(height: 20 * scale, alignment: .center)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}
