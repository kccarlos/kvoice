import SwiftUI

/// ADR-017's live text, drawn the UI v2 way (`Motion.dc.html` § 5,
/// `Recorder.dc.html` "Recording · live text"): word by word, never
/// character by character. Each new word sharpens in — opacity, blur 4 → 0
/// and a 3 pt rise over 160 ms easeOut — and only the last
/// `keptWords` words are kept; older ones slide out to the left. On Mini the
/// older words fade to `text-2` and the newest stay `text`; the notch is one
/// white line. Reduce Motion: words appear at once.
///
/// Read-only and private: `.privacySensitive()` and hidden from VoiceOver
/// (announcing every revision would talk over the user; the outcome
/// announcement carries the result).
struct HUDLiveWords: View {
    /// Motion § 5: "keep last ~9 words".
    static let keptWords = 9
    /// Words drawn in the primary colour; the rest of the kept ones are
    /// older and fade to the secondary colour (Mini).
    static let newestWords = 5

    let text: String
    let fontSize: CGFloat
    let lineHeight: CGFloat
    let maxLines: Int
    let newest: Color
    let older: Color
    let reduceMotion: Bool

    var body: some View {
        let tokens = Self.tokens(text)
        let firstKept = max(0, tokens.count - Self.keptWords)
        let firstNewest = max(0, tokens.count - Self.newestWords)
        // Keyed by position and text: a word the stream revises sharpens in
        // again, an unchanged one keeps its place.
        let kept = tokens.indices.dropFirst(firstKept).map { (key: "\($0)|\(tokens[$0])", index: $0, token: tokens[$0]) }
        HUDWordFlow(lineHeight: lineHeight, maxLines: maxLines) {
            ForEach(kept, id: \.key) { word in
                Text(verbatim: word.token)
                    .font(.system(size: fontSize))
                    .foregroundStyle(word.index >= firstNewest ? newest : older)
                    .fixedSize()
                    .transition(reduceMotion ? .identity : Self.sharpen)
            }
        }
        .frame(height: lineHeight * CGFloat(maxLines), alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: tokens)
        .privacySensitive()
        .accessibilityHidden(true)
    }

    static let sharpen: AnyTransition = .asymmetric(
        insertion: .modifier(active: WordSharpen(active: true), identity: WordSharpen(active: false)),
        removal: .opacity
    )

    /// Splits `text` into words the way the language counts them
    /// (`.byWords`), each token running to the next word's start so the
    /// spaces and punctuation round-trip and a Chinese sentence splits into
    /// its words, not one block. Text before the first word ("…") joins the
    /// first token.
    static func tokens(_ text: String) -> [String] {
        var starts: [String.Index] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            starts.append(range.lowerBound)
        }
        guard !starts.isEmpty else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [text]
        }
        var tokens: [String] = []
        for (index, start) in starts.enumerated() {
            let lower = index == 0 ? text.startIndex : start
            let upper = index + 1 < starts.count ? starts[index + 1] : text.endIndex
            tokens.append(String(text[lower..<upper]))
        }
        return tokens
    }
}

/// The word's entrance: from transparent, blurred 4 pt and 3 pt low.
private struct WordSharpen: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 4 : 0)
            .offset(y: active ? 3 : 0)
    }
}

/// Lays words out left to right in lines of `lineHeight`, wrapping at the
/// proposed width, and keeps the newest: when the words need more than
/// `maxLines` lines, the oldest are placed outside the bounds (and clipped)
/// until the rest fit — the head-truncation of the design's live line.
struct HUDWordFlow: Layout {
    let lineHeight: CGFloat
    let maxLines: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: lineHeight * CGFloat(maxLines))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let first = Self.firstVisible(widths: sizes.map(\.width), width: bounds.width, maxLines: maxLines)
        var x: CGFloat = 0
        var line = 0
        for index in subviews.indices {
            let size = sizes[index]
            guard index >= first else {
                subviews[index].place(at: CGPoint(x: bounds.minX - 10_000, y: bounds.minY), proposal: .unspecified)
                continue
            }
            if x > 0, x + size.width > bounds.width + 0.5 {
                line += 1
                x = 0
            }
            let y = bounds.minY + CGFloat(line) * lineHeight + (lineHeight - size.height) / 2
            subviews[index].place(at: CGPoint(x: bounds.minX + x, y: y), proposal: .unspecified)
            x += size.width
        }
    }

    /// The first word to show so that the words from it to the end fit in
    /// `maxLines` lines of `width`.
    static func firstVisible(widths: [CGFloat], width: CGFloat, maxLines: Int) -> Int {
        guard width > 0 else { return 0 }
        for start in widths.indices {
            if lineCount(widths[start...], width: width) <= maxLines {
                return start
            }
        }
        return widths.count
    }

    static func lineCount(_ widths: ArraySlice<CGFloat>, width: CGFloat) -> Int {
        guard !widths.isEmpty else { return 0 }
        var lines = 1
        var x: CGFloat = 0
        for item in widths {
            if x > 0, x + item > width + 0.5 {
                lines += 1
                x = 0
            }
            x += item
        }
        return lines
    }
}
