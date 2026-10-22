import AppKit
import KvoiceDomain
import SwiftUI

// MARK: - Welcome hero

/// Welcome's ink hero: hold your shortcut, speak, let go — the three moves
/// of dictation, drawn with the real shortcut's keycaps. The voice bars
/// pulse and the caret blinks unless Reduce Motion is on.
struct WelcomeHero: View {
    let keyCaps: [String]
    let reduceMotion: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            column(title: "1 · Hold", detail: "your shortcut") {
                HStack(spacing: 4) {
                    ForEach(Array(keyCaps.enumerated()), id: \.offset) { _, key in
                        Keycap(key: key, size: .onInk)
                    }
                }
            }
            column(title: "2 · Speak", detail: "naturally") {
                HeroBars(reduceMotion: reduceMotion)
            }
            column(title: "3 · Let go", detail: "text lands at your cursor") {
                HStack(spacing: 2) {
                    Text("See you Thursday")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255))
                        .lineLimit(1)
                    HeroCaret(reduceMotion: reduceMotion)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(.white, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .frame(height: 188)
        .background(Color.kv.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.kv.inkLine, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold your shortcut, speak naturally, let go: the text lands at your cursor.")
    }

    private func column<Art: View>(title: LocalizedStringKey, detail: LocalizedStringKey, @ViewBuilder art: () -> Art) -> some View {
        VStack(spacing: 14) {
            art()
                .frame(height: 30)
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kv.inkText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Welcome's "2 · Speak" level bars. The pulse is computed from the clock
/// (`HeroBarsMotion`), never a `repeatForever` animation: that one was
/// started in `onAppear` while the hero was still being laid out (the
/// window restoring its saved frame, the page arriving), so it captured
/// each bar's x position too and swung the bars sideways for ever, left of
/// their column (owner report 2026-10-21). A scale read from the time
/// cannot move a bar.
private struct HeroBars: View {
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            bars(at: nil)
        } else {
            TimelineView(.animation) { context in
                bars(at: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func bars(at time: TimeInterval?) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(HeroBarsMotion.heights.enumerated()), id: \.offset) { index, height in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(red: 0xFF / 255, green: 0x7A / 255, blue: 0x2F / 255))
                    .frame(width: 4, height: height)
                    .scaleEffect(y: time.map { HeroBarsMotion.scale(bar: index, at: $0) } ?? 1)
            }
        }
    }
}

/// Wizard.dc's `kvlevel` pulse for the Welcome hero's bars: scaleY .45 → 1
/// → .45 over 900 ms, ease-in-out, from the bar's centre; bars 1, 4, 7 run
/// 600 ms ahead and bars 3, 6 300 ms ahead (the design's negative
/// `animation-delay`s on `:nth-child(3n+1)` and `:nth-child(3n)`).
enum HeroBarsMotion {
    static let heights: [CGFloat] = [10, 18, 28, 20, 30, 16, 8]
    static let period: TimeInterval = 0.9
    static let minimumScale: CGFloat = 0.45

    /// How far ahead of the clock bar `index` (0-based) runs.
    static func lead(bar index: Int) -> TimeInterval {
        switch (index + 1) % 3 {
        case 1: return 0.6
        case 0: return 0.3
        default: return 0
        }
    }

    /// The bar's vertical scale at `time`. A raised cosine: .45 at the
    /// start and end of each period, 1 halfway, easing in and out of both.
    static func scale(bar index: Int, at time: TimeInterval) -> CGFloat {
        let shifted = (time + lead(bar: index)) / period
        let progress = shifted - shifted.rounded(.down)
        let wave = (1 - cos(2 * Double.pi * progress)) / 2
        return minimumScale + (1 - minimumScale) * CGFloat(wave)
    }
}

private struct HeroCaret: View {
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            caret(visible: true)
        } else {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                caret(visible: Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0)
            }
        }
    }

    private func caret(visible: Bool) -> some View {
        Rectangle()
            .fill(Color.kv.cursor)
            .frame(width: 2, height: 15)
            .opacity(visible ? 1 : 0)
    }
}
