import SwiftUI
import KvoiceAppCore
import KvoiceDomain

/// A read-only fact in a grouped Form: label on the left, value on the right.
///
/// Every tab used to draw this with its own `HStack { Text; Spacer; Text }`,
/// each with slightly different alignment, selection, and accessibility
/// treatment. `LabeledContent` is the macOS Settings idiom for it, and one
/// row type means the shortcut, model state, and history figures read the
/// same wherever they appear.
struct SettingsFactRow: View {
    /// A `LocalizedStringKey` so the literal at the call site localizes and
    /// is extracted into the String Catalog; the value is runtime data.
    let label: LocalizedStringKey
    let value: String
    var valueColor: Color = .secondary
    var systemImage: String?

    init(_ label: LocalizedStringKey, _ value: String, valueColor: Color = .secondary, systemImage: String? = nil) {
        self.label = label
        self.value = value
        self.valueColor = valueColor
        self.systemImage = systemImage
    }

    var body: some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        } label: {
            if let systemImage {
                Label(label, systemImage: systemImage)
            } else {
                Text(label)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// How a `StatusLabel` reads: the color always lives on the SF Symbol, never
/// on the word, so shape and text carry the meaning together
/// (`color.md › Best practices`; M1/W6, design review 2026-09-16 — plain
/// `Color.green`/`Color.orange` text was ~2.2:1 in light mode).
enum StatusTone {
    /// A good status: green symbol, `.secondary` text ("Ready").
    case positive
    /// Needs attention, a warning, or an error: orange symbol, `.primary`
    /// text so it still reads as more urgent than a status line.
    case attention
    /// In progress or unknown: `.secondary` symbol and text.
    case neutral

    /// The symbol's color. Exposed so a caller drawing its own `Image`
    /// (rather than going through `StatusLabel`) still uses the one mapping.
    var symbolColor: Color {
        switch self {
        case .positive: .green
        case .attention: .orange
        case .neutral: .secondary
        }
    }

    /// The text's color — never the tone's color; only `.primary`/`.secondary`.
    var textColor: Color {
        switch self {
        case .attention: .primary
        case .positive, .neutral: .secondary
        }
    }
}

/// A status or error row whose meaning is carried by the SF Symbol and the
/// word, not by colored text (M1/W6). Use this instead of coloring a `Text`
/// or `Label` green or orange directly.
struct StatusLabel: View {
    let text: String
    let symbol: String
    let tone: StatusTone

    init(_ text: String, symbol: String, tone: StatusTone) {
        self.text = text
        self.symbol = symbol
        self.tone = tone
    }

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(tone.textColor)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tone.symbolColor)
        }
    }
}

/// A file-system location: label above, monospaced path below, truncated in
/// the middle so the meaningful tail survives a narrow window. Paths belong
/// in Settings (Model location, data folder); they never go in the HUD.
struct SettingsPathRow: View {
    let label: LocalizedStringKey
    let url: URL

    init(_ label: LocalizedStringKey, _ url: URL) {
        self.label = label
        self.url = url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            Text(url.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(url.path)
    }
}

/// The "changed from default" affordance (ADR-022 item 2, slice 5): one
/// caption plus a Reset button, rendered under a section's controls only
/// while one of `rows` differs from its compiled default. One view for every
/// page, so the affordance reads the same wherever it appears.
///
/// ADR-022 slice 7 part B: reads `host.effective` (the same host the page's
/// view model projects) instead of a shell-owned `SettingsProvenanceModel`,
/// and sends `SettingsIntent.resetToDefault` itself — the origin is the page
/// the row is shown on, exactly as every other projection's edits are. A
/// section that is disabled (a job in flight) disables this too, and the
/// reducer refuses the reset for the same reason the edit would be.
struct SettingsResetRow: View {
    let rows: [ResettableSetting]
    let host: SettingsProjectionHost
    let origin: SettingsOrigin

    init(_ rows: [ResettableSetting], host: SettingsProjectionHost, origin: SettingsOrigin) {
        self.rows = rows
        self.host = host
        self.origin = origin
    }

    init(_ row: ResettableSetting, host: SettingsProjectionHost, origin: SettingsOrigin) {
        self.init([row], host: host, origin: origin)
    }

    private var changed: Set<ResettableSetting> { host.effective.changedFromDefault }

    var body: some View {
        if rows.contains(where: changed.contains) {
            HStack {
                Label("Changed from default", systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Default") {
                    for row in rows where changed.contains(row) {
                        host.send(.resetToDefault(row, origin: origin))
                    }
                }
                .controlSize(.small)
                .accessibilityHint("Puts this section's settings back to the values KVoice ships with.")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Changed from default")
        }
    }
}

/// A section footer with a projection host's refusal note under it
/// (ADR-022 slice 7). A refused intent leaves the stored value where it
/// was, so the bound control already shows the truth; this sentence is the
/// only thing that tells the user why the click did nothing. Nil renders
/// the base alone, so a page without a shell looks exactly as before.
struct SettingsFooter<Base: View>: View {
    let note: String?
    @ViewBuilder let base: () -> Base

    init(note: String?, @ViewBuilder base: @escaping () -> Base) {
        self.note = note
        self.base = base
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            base()
            if let note {
                Text(note)
                    .accessibilityLabel(note)
            }
        }
    }
}
