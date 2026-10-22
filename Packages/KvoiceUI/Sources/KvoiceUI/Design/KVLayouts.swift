import SwiftUI

/// UI v2 fidelity F2: CSS `grid-template-columns: repeat(auto-fit,
/// minmax(min(<minimum>, 100%), 1fr))` — as many equal columns as fit at
/// `minimumColumnWidth`, never more than there are items (auto-fit
/// collapses empty tracks), every cell in a row as tall as the row's
/// tallest (grid rows stretch).
struct KVAutoFitGrid: Layout {
    var minimumColumnWidth: CGFloat
    var spacing: CGFloat
    /// UI v2 fidelity F3b: CSS `repeat(<n>, minmax(0, 1fr))` — always this
    /// many columns (AI Actions' 4-column grid); nil fits by width.
    var fixedColumns: Int? = nil

    /// The column count for `width` and `count` items.
    static func columns(width: CGFloat, minimum: CGFloat, spacing: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 1 }
        let fit = Int(((width + spacing) / (minimum + spacing)).rounded(.down))
        return min(count, max(1, fit))
    }

    private func metrics(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (columns: Int, cell: CGFloat, rows: [CGFloat]) {
        let width = proposal.width ?? (minimumColumnWidth * CGFloat(subviews.count) + spacing * CGFloat(max(0, subviews.count - 1)))
        let columns = fixedColumns.map { max(1, $0) } ?? Self.columns(width: width, minimum: minimumColumnWidth, spacing: spacing, count: subviews.count)
        let cell = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        var rows: [CGFloat] = []
        for (index, subview) in subviews.enumerated() {
            let height = subview.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height
            if index % columns == 0 { rows.append(height) } else { rows[rows.count - 1] = max(rows[rows.count - 1], height) }
        }
        return (columns, cell, rows)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let m = metrics(proposal, subviews)
        let width = CGFloat(m.columns) * m.cell + spacing * CGFloat(m.columns - 1)
        let height = m.rows.reduce(0, +) + spacing * CGFloat(max(0, m.rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = metrics(ProposedViewSize(width: bounds.width, height: nil), subviews)
        var y = bounds.minY
        for (rowIndex, rowHeight) in m.rows.enumerated() {
            for column in 0..<m.columns {
                let index = rowIndex * m.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (m.cell + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: m.cell, height: rowHeight))
            }
            y += rowHeight + spacing
        }
    }
}

/// CSS `display: flex; flex-wrap: wrap` for chips: items at their ideal
/// size, left to right, wrapping to a new line when the next does not fit.
struct KVFlowLayout: Layout {
    var spacing: CGFloat

    private func lines(_ width: CGFloat, _ subviews: Subviews) -> [[(Int, CGSize)]] {
        var lines: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                lines.append([])
                x = 0
            }
            lines[lines.count - 1].append((index, size))
            x += size.width + spacing
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = lines(width, subviews)
        let widest = rows.map { row in row.map(\.1.width).reduce(0, +) + spacing * CGFloat(max(0, row.count - 1)) }.max() ?? 0
        let height = rows.map { $0.map(\.1.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, widest) } ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in lines(bounds.width, subviews) {
            var x = bounds.minX
            let height = row.map(\.1.height).max() ?? 0
            for (index, size) in row {
                subviews[index].place(at: CGPoint(x: x, y: y + (height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += height + spacing
        }
    }
}
