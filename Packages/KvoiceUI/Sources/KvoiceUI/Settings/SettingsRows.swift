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

/// How a `StatusLabel` reads: the color lives on the dot (the symbol under
/// Increase Contrast), and the words say it too
/// (`color.md › Best practices`; M1/W6, design review 2026-09-16 — plain
/// `Color.green`/`Color.orange` text was ~2.2:1 in light mode).
enum StatusTone {
    /// A good status: ok dot, secondary text ("Ready").
    case positive
    /// Needs attention, a warning, or an error: warn dot and warn-ink text
    /// so it reads as more urgent than a status line.
    case attention
    /// In progress or unknown: secondary dot and text.
    case neutral

    /// UI v2 wave 4: the same meaning as a design tone, for a
    /// `StatusPill` chip (good → ok, attention → warn, neutral → neutral).
    var kvTone: KVTone {
        switch self {
        case .positive: .ok
        case .attention: .warn
        case .neutral: .neutral
        }
    }
}

/// A status or error row whose meaning is carried by a dot and the words,
/// never by colour alone (M1/W6; UI v2 wave 4). Use this instead of coloring a `Text`
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

    @Environment(\.colorSchemeContrast) private var contrast

    /// UI v2 wave 4: the design's status form everywhere in the window — a
    /// dot in the tone's solid colour and the words (secondary for a good or
    /// neutral state, warn-ink for one that needs the user). `symbol` is
    /// kept for Increase Contrast, where the shape carries the meaning a
    /// second time beside the words.
    var body: some View {
        HStack(spacing: 6) {
            if contrast == .increased {
                Image(systemName: symbol)
                    .foregroundStyle(tone.kvTone.solid.color)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(tone.kvTone.solid.color)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            Text(text)
                .foregroundStyle(tone == .attention ? Color.kv.warnInk : Color.kv.text2)
        }
        .accessibilityElement(children: .combine)
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
        // UI v2 fidelity F3 (Window.dc `group(…, { reset: true })`): one
        // 11 pt `cursor-ink` link at the trailing end of the section header.
        if rows.contains(where: changed.contains) {
            Button {
                for row in rows where changed.contains(row) {
                    host.send(.resetToDefault(row, origin: origin))
                }
            } label: {
                Text("Changed · Reset to Default", bundle: .module)
                    .font(.system(size: 11, weight: .regular))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.kv.cursorInk)
            .accessibilityLabel(Text("Reset to Default", bundle: .module))
            .accessibilityValue(Text("Changed from default", bundle: .module))
            .accessibilityHint(Text("Puts this section's settings back to the values KVoice ships with.", bundle: .module))
        }
    }
}

/// A section header with a trailing accessory — the reset link, a status
/// line, an "Add…" link (Window.dc's `h3` + right-aligned item).
struct KVHeaderRow<Trailing: View>: View {
    let title: Text
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: LocalizedStringKey, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = Text(title, bundle: .module)
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            title.accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing()
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

/// ADR-026 (2026-09-28 amendment): the pointer to the full edition under a
/// "not in this edition" sentence. `url` comes from
/// `SettingsAvailabilityModel.fullEditionLink` (or its static rule), so it is
/// nil — and this renders nothing — in the Developer ID edition and when
/// `HelpLinks.offersFullEditionLink` is off. A caller must not put it inside
/// a `.disabled` container, or the link is dead in exactly the edition it is
/// for.
struct FullEditionLink: View {
    let url: URL?

    var body: some View {
        if let url {
            Link("Get the full version from GitHub", destination: url)
                .accessibilityHint("Opens the KVoice releases page on GitHub in your browser.")
        }
    }
}
