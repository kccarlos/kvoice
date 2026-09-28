import SwiftUI

/// The header every main-window section starts with: symbol, title, and the
/// one-line purpose. Keeping it in one place is what makes the sections read
/// as one window rather than seven tabs that happen to share a sidebar.
struct SectionHeaderView: View {
    let section: MainWindowSection

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: section.symbolName)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.title2.weight(.semibold))
                Text(section.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(section.title). \(section.purpose)")
    }
}
