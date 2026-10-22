import SwiftUI

/// UI v2 wave 5b: the main-window pages' card layout, replacing the system
/// grouped `Form` (Docs/Design/Cards-Layout-Plan.md).
///
/// `KVCardPage` is the scrolling page with a capped content column;
/// `KVCardSection` mirrors `Section`'s initialisers and draws a titled white
/// card with its rows separated by `kv.line-2`; the row styles below give
/// the existing `Toggle` and `LabeledContent` rows label-left/control-right
/// without changing their code.
public enum KVCardLayout {
    /// The content column never grows past this, so rows do not stretch
    /// across a wide or full-screen window.
    /// UI v2 fidelity F3: Models.dc's 920 pt column (Window.dc draws no
    /// cap; its frames are never wider than 1040).
    public static let maxContentWidth: CGFloat = 920
    /// Matches `SectionHeaderView`'s horizontal padding (Window.dc `main`
    /// padding 0 36).
    public static let sidePadding: CGFloat = 36
    /// Window.dc: header and blocks 18 pt apart.
    public static let blockSpacing: CGFloat = 18
    /// Window.dc `group()` card radius.
    public static let cardRadius: CGFloat = 11
    /// Under this content-column width a row stacks its label above its
    /// control.
    public static let stackedBelow: CGFloat = 520
    public static let rowHorizontalPadding: CGFloat = 14
    public static let rowVerticalPadding: CGFloat = 7
    public static let rowMinHeight: CGFloat = 40

    /// The content column for a detail (page) width.
    public static func contentWidth(forPageWidth width: CGFloat) -> CGFloat {
        min(maxContentWidth, max(0, width - 2 * sidePadding))
    }

    /// Whether rows stack at this page width. An unmeasured page (0) is
    /// treated as wide so the first frame does not flip.
    public static func isStacked(pageWidth width: CGFloat) -> Bool {
        width > 0 && contentWidth(forPageWidth: width) < stackedBelow
    }
}

extension EnvironmentValues {
    /// Set by `KVCardPage`: rows stack label above control.
    @Entry public var kvCardRowsStacked: Bool = false
}

/// The page container: one `ScrollView`, sections 24 pt apart, the column
/// capped at `KVCardLayout.maxContentWidth` and aligned with the header.
public struct KVCardPage<Content: View>: View {
    private let content: Content
    @State private var pageWidth: CGFloat = 0

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: KVCardLayout.blockSpacing) {
                content
            }
            .frame(maxWidth: KVCardLayout.maxContentWidth, alignment: .leading)
            .padding(.horizontal, KVCardLayout.sidePadding)
            // 12 + the header's 6 pt bottom padding = Window.dc's 18.
            .padding(.top, KVSpacing.s)
            .padding(.bottom, KVSpacing.l)
            // Leading, not centred: on a wide window a centred column
            // drifted away from the page header, which stays at the left.
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.kvCardRowsStacked, KVCardLayout.isStacked(pageWidth: pageWidth))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            pageWidth = width
        }
    }
}

/// A titled card (Window.dc `group()`): the 13 pt semibold header 6 pt above
/// the white card holding the rows, and the 11 pt secondary footnote. Rows are the content's direct
/// subviews, so `ForEach` and `if` rows behave as they do in a `Section`.
public struct KVCardSection<Content: View, Header: View, Footer: View>: View {
    private let content: Content
    private let header: Header
    private let footer: Footer

    public init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer
    ) {
        self.content = content()
        self.header = header()
        self.footer = footer()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.kv.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
                .accessibilityAddTraits(.isHeader)
            KVCard { content }
            footer
                .font(.system(size: 11))
                .lineSpacing(2)
                .foregroundStyle(Color.kv.text2)
                .tint(Color.kv.cursorInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
    }
}

extension KVCardSection where Header == EmptyView, Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}

extension KVCardSection where Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension KVCardSection where Header == EmptyView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}

extension KVCardSection where Header == Text, Footer == EmptyView {
    public init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }

    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

/// The white bordered card itself; rows are separated by `kv.line-2`.
/// Increase Contrast draws the border and dividers in `kv.line` and thickens
/// the border.
public struct KVCard<Content: View>: View {
    private let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let increased = contrast == .increased
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Rectangle()
                            .fill(increased ? Color.kv.line : Color.kv.line2)
                            .frame(height: 1)
                            .accessibilityHidden(true)
                    }
                    row
                        .font(.system(size: 13))
                        .padding(.horizontal, KVCardLayout.rowHorizontalPadding)
                        .padding(.vertical, KVCardLayout.rowVerticalPadding)
                        .frame(maxWidth: .infinity, minHeight: KVCardLayout.rowMinHeight, alignment: .leading)
                }
            }
        }
        .toggleStyle(KVRowToggleStyle())
        .labeledContentStyle(KVRowLabeledContentStyle())
        .buttonStyle(.kv)
        .background(
            RoundedRectangle(cornerRadius: KVCardLayout.cardRadius, style: .continuous)
                .fill(Color.kv.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: KVCardLayout.cardRadius, style: .continuous)
                .strokeBorder(Color.kv.line, lineWidth: increased ? 1.5 : 1)
        )
    }
}

/// A card row's toggle: label left (wraps), switch right. VoiceOver sees one
/// switch carrying the label, as in the grouped Form.
public struct KVRowToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        KVRowToggle(configuration: configuration)
    }
}

private struct KVRowToggle: View {
    let configuration: ToggleStyleConfiguration

    var body: some View {
        HStack(alignment: .center, spacing: KVSpacing.m) {
            KVRowLabel(label: configuration.label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            KVSwitch(isOn: configuration.$isOn)
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A card row's `LabeledContent`: label left (wraps), value or control
/// right; stacked label-above-control on a narrow page.
public struct KVRowLabeledContentStyle: LabeledContentStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        KVRowLabeledContent(configuration: configuration)
    }
}

private struct KVRowLabeledContent: View {
    let configuration: LabeledContentStyleConfiguration
    @Environment(\.kvCardRowsStacked) private var stacked

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: KVSpacing.xs) {
                KVRowLabel(label: configuration.label)
                configuration.content
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(alignment: .center, spacing: KVSpacing.s) {
                KVRowLabel(label: configuration.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                configuration.content
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A row label (Window.dc `row()`): the first line 13 pt, every further
/// line the 11 pt `text-2` sub-line, 1 pt apart. A `Toggle` or
/// `LabeledContent` whose label holds two `Text`s gets the sub-line.
struct KVRowLabel<Label: View>: View {
    let label: Label

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Group(subviews: label) { lines in
                ForEach(lines) { line in
                    if line.id == lines.first?.id {
                        line.font(.system(size: 13)).foregroundStyle(Color.kv.text)
                    } else {
                        line.font(.system(size: 11)).foregroundStyle(Color.kv.text2).lineSpacing(1)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// UI v2 fidelity F3b: a titled card that holds free content instead of
/// rows (Window.dc's `isTerms`, "What the model sees", "Where AI runs"):
/// the same 13 pt header 6 pt above, the same white bordered card, the
/// content padded as drawn (nil: no padding, for rows the caller lays out).
public struct KVBlockSection<Content: View, Header: View, Footer: View>: View {
    private let padding: CGFloat?
    private let content: Content
    private let header: Header
    private let footer: Footer
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        padding: CGFloat?,
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer
    ) {
        self.padding = padding
        self.content = content()
        self.header = header()
        self.footer = footer()
    }

    public var body: some View {
        let increased = contrast == .increased
        VStack(alignment: .leading, spacing: 6) {
            header
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.kv.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
                .accessibilityAddTraits(.isHeader)
            content
                .padding(padding ?? 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .buttonStyle(.kv)
                .background(
                    RoundedRectangle(cornerRadius: KVCardLayout.cardRadius, style: .continuous)
                        .fill(Color.kv.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: KVCardLayout.cardRadius, style: .continuous)
                        .strokeBorder(Color.kv.line, lineWidth: increased ? 1.5 : 1)
                )
            footer
                .font(.system(size: 11))
                .lineSpacing(2)
                .foregroundStyle(Color.kv.text2)
                .tint(Color.kv.cursorInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
    }
}

extension KVBlockSection where Footer == EmptyView {
    public init(padding: CGFloat?, @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(padding: padding, content: content, header: header, footer: { EmptyView() })
    }
}

/// A divider between rows a caller lays out itself inside a `KVBlockSection`.
struct KVRowDivider: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle()
            .fill(contrast == .increased ? Color.kv.line : Color.kv.line2)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
