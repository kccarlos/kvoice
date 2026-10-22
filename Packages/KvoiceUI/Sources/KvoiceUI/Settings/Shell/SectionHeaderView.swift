import SwiftUI

/// The header every main-window section starts with: symbol, title, and the
/// one-line purpose. Keeping it in one place is what makes the sections read
/// as one window rather than seven tabs that happen to share a sidebar.
struct SectionHeaderView: View {
    let section: MainWindowSection
    /// UI v2 fidelity F3b: the page's trailing button (Window.dc
    /// `headerAction`), nil for none.
    var action: MainWindowHeaderAction? = nil

    var body: some View {
        // UI v2 fidelity F2 (Window.dc header): the 36 pt tile (radius 9,
        // the design glyph), 22 pt bold title at −0.01 em, the purpose line
        // in 12 pt text-2, 12 pt apart and 1 pt between the lines; the
        // detail column's 36 pt side padding. It sits right under the
        // 38 pt title-bar strip.
        HStack(alignment: .center, spacing: 12) {
            KVGlyphTile(glyph: section.designGlyph, fill: section.tileFill, side: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(section.title)
                    .font(KVFont.pageTitle)
                    .tracking(-0.22)
                    .foregroundStyle(Color.kv.text)
                Text(section.purpose)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kv.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Tile, title and purpose read as one header; the button stays
            // its own element so VoiceOver and Tab reach it.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel("\(section.title). \(section.purpose)")
            Spacer(minLength: 0)
            if let action {
                MainWindowHeaderActionButton(action: action)
            }
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }
}
