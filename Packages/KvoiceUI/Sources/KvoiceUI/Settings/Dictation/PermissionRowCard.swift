import SwiftUI

/// UI v2 fidelity F3 (Window.dc `isPerms`): one permission as its own card —
/// 34 pt glyph tile, 14 pt name, 12 pt explanation, an optional 11 pt
/// `warn-ink` hint; on the right the status chip, the one action when there
/// is something to do, and "Checked …". A card that needs attention has a
/// `warn` border.
///
/// Motion §10·12 (confirmation): when the status turns OK the chip changes
/// colour over 240 ms, its check draws over 240 ms easeOut after 120 ms, and
/// the card glows once (1 pt `ok` ring + an 8 pt `ok-soft` halo at 40 %,
/// 700 ms, back to `line`). Reduce Motion: no glow and no drawing; the
/// colour still changes.
struct PermissionRowCard: View {
    struct Action {
        let title: String
        let isPrimary: Bool
        let isInProgress: Bool
        let hint: String
        let perform: @MainActor () -> Void
    }

    let glyph: String
    let tileFill: KVColorToken
    let name: String
    let text: String
    var hint: String?
    var note: String?
    let statusLabel: String
    let tone: KVTone
    var action: Action?
    let checked: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow: Double = 0
    @State private var checkDrawn: CGFloat = 1
    /// The first reads after the page opens are not grants the user just
    /// made; only a change after this settles is celebrated.
    @State private var appearedAt = Date.distantFuture

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            KVGlyphTile(glyph: glyph, fill: tileFill, side: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.kv.text)
                Text(verbatim: text)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(Color.kv.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint {
                    Text(verbatim: hint)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kv.warnInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note {
                    Text(verbatim: note)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kv.text2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                chip
                if let action {
                    HStack(spacing: 6) {
                        if action.isInProgress {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel(Text("Waiting for macOS", bundle: .module))
                        }
                        Button(action.title) { action.perform() }
                            .buttonStyle(KVButtonStyle(action.isPrimary ? .primary : .standard, height: 26))
                            .disabled(action.isInProgress)
                            .accessibilityLabel(Text(verbatim: "\(action.title) — \(name)"))
                            .accessibilityHint(Text(verbatim: action.hint))
                    }
                }
                Text(verbatim: checked)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kv.text2)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(Color.kv.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tone == .warn ? Color.kv.warn : Color.kv.line, lineWidth: 1)
                .animation(.easeInOut(duration: 0.24), value: tone)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.kv.ok, lineWidth: 1)
                .shadow(color: Color.kv.okSoft.opacity(0.4 * 2.5), radius: 8 * glow)
                .opacity(glow)
                .allowsHitTesting(false)
        }
        .onAppear { appearedAt = Date() }
        .onChange(of: tone) { old, new in
            guard new == .ok, old != .ok, Date().timeIntervalSince(appearedAt) > 1.5 else { return }
            celebrate()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(name), \(statusLabel)"))
    }

    private var chip: some View {
        HStack(spacing: 6) {
            if tone == .ok {
                PermissionCheck()
                    .trim(from: 0, to: checkDrawn)
                    .stroke(tone.ink.color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 8, height: 8)
            } else {
                Circle().fill(tone.solid.color).frame(width: 6, height: 6)
            }
            Text(verbatim: statusLabel)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tone.ink.color)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(tone == .neutral ? Color.kv.fill : tone.soft.color, in: Capsule(style: .continuous))
        .animation(.easeInOut(duration: 0.24), value: tone)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(name) status"))
        .accessibilityValue(Text(verbatim: statusLabel))
    }

    private func celebrate() {
        guard !reduceMotion else { return }
        checkDrawn = 0
        withAnimation(.easeOut(duration: 0.24).delay(0.12)) { checkDrawn = 1 }
        withAnimation(.easeOut(duration: 0.28)) { glow = 1 }
        withAnimation(.easeIn(duration: 0.42).delay(0.28)) { glow = 0 }
    }
}

/// The chip's check mark, drawn left to right so `.trim` animates it.
struct PermissionCheck: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.1))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.1))
        return path
    }
}
