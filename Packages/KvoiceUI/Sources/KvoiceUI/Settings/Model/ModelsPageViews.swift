import SwiftUI
import KvoiceDomain

// UI v2 fidelity F3: Speech Models as drawn in Models.dc — the "In use" card
// (name, summary, status chip; Mode / Transcription language / Placement
// columns) and the "More models" grid with its filter pills.

/// Models.dc's "In use" card.
@MainActor
struct ModelsInUseCard: View {
    @Bindable var speechModels: SpeechModelsViewModel
    let runtime: RuntimeCardViewModel
    let onRuntimeDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let card = speechModels.defaultCard {
                VStack(spacing: 0) {
                    header(card)
                    Rectangle().fill(Color.kv.line).frame(height: 1)
                    KVAdaptiveColumns(minimum: 200) {
                        column(Text("Mode", bundle: .module)) { mode(card) }
                        column(Text("Transcription language", bundle: .module)) { language }
                        column(Text("Placement", bundle: .module)) { placement }
                    }
                }
                .background(Color.kv.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.kv.line, lineWidth: 1))
            } else {
                KVCard {
                    Text(speechModels.isAvailable
                         ? "No speech model is available in this version."
                         : "The speech model catalog is not connected in this build.", bundle: .module)
                        .foregroundStyle(Color.kv.text2)
                }
            }
            if let warning = speechModels.languageCoverageWarning {
                Label {
                    Text(warning).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.kv.warn)
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.kv.warnInk)
                .padding(.horizontal, 2)
                .accessibilityLabel(Text("Language not supported: \(warning)", bundle: .module))
            }
            if let note = speechModels.refusalNote {
                Text(note).font(.system(size: 11)).foregroundStyle(Color.kv.text2).padding(.horizontal, 2)
            }
        }
    }

    private func header(_ card: ModelCardState) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("In use", bundle: .module)
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.55)
                    .foregroundStyle(Color.kv.text2)
                Text(verbatim: card.entry.fullDisplayName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.kv.text)
                Text(verbatim: card.entry.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.kv.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Current model: \(card.entry.fullDisplayName). \(card.statusDescription)", bundle: .module))
            Spacer(minLength: 0)
            KVChip(card.statusDescription, tone: Self.tone(card))
                .padding(.vertical, 1)
        }
        .padding(20)
        .background(Color.kv.wash)
    }

    private func column<Content: View>(_ title: Text, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title.font(.system(size: 12)).foregroundStyle(Color.kv.text2)
            content()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func mode(_ card: ModelCardState) -> some View {
        if card.entry.availableModes.count > 1 {
            KVSegmented(
                "Transcription mode",
                selection: Binding(get: { speechModels.mode(for: card.id) }, set: { speechModels.setMode($0, for: card.id) }),
                options: card.entry.availableModes.map { ($0, DomainCopy.localized($0.displayName)) },
                size: 12
            )
        } else {
            Text(verbatim: card.entry.availableModes.first.map { DomainCopy.localized($0.displayName) } ?? "—")
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private var language: some View {
        let selection = Binding(
            get: { speechModels.transcriptionLanguage ?? "" },
            set: { speechModels.setTranscriptionLanguage($0.isEmpty ? nil : $0) }
        )
        let current = speechModels.transcriptionLanguage.map { LanguageNames.transcriptionLanguageName(forCode: $0) }
            ?? String(localized: "Auto-detect", bundle: .module)
        return KVSelect("Transcription language", selection: selection, current: current) {
            Text("Auto-detect", bundle: .module).tag("")
            Divider()
            ForEach(speechModels.languageOptions) { option in
                Text(verbatim: LanguageNames.transcriptionLanguageName(forCode: option.code)).tag(option.code)
            }
        }
        .accessibilityHint(Text("Auto-detect keeps mixed-language dictation as spoken; a fixed language is a hint to the model.", bundle: .module))
    }

    private var placement: some View {
        VStack(alignment: .leading, spacing: 5) {
            let bars = runtime.placementBars
            if bars.isEmpty {
                ForEach(Array(runtime.placementLines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: "\(line.label) · \(line.value)").font(.system(size: 12)).foregroundStyle(Color.kv.text)
                }
            } else {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    HStack(spacing: 8) {
                        Text(verbatim: bar.label).foregroundStyle(Color.kv.text2).frame(width: 54, alignment: .leading)
                        KVBar(fraction: bar.share, tint: Color.kv.voice, height: 6)
                        Text(verbatim: "\(Int((bar.share * 100).rounded()))%")
                            .font(.system(size: 12, design: .monospaced))
                            .monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .accessibilityElement(children: .combine)
                }
            }
            HStack(spacing: 4) {
                if !bars.isEmpty {
                    Text("on the Neural Engine ·", bundle: .module)
                }
                Button(action: onRuntimeDetails) {
                    Text("Runtime details ›", bundle: .module)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.kv.cursorInk)
                .accessibilityHint(Text("Shows the runtime, memory, the performance test and the package details.", bundle: .module))
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.kv.text2)
        }
    }

    static func tone(_ card: ModelCardState) -> KVTone {
        switch card.state {
        case .ready?: card.isResident || !card.isDefault ? .ok : .neutral
        case .corrupt?, .incompatible?, .error?: .err
        case .downloading?, .verifying?, .installing?, .loading?, .optimizing?: .cursor
        default: .neutral
        }
    }
}

/// A thin rounded progress bar; the width animates 300 ms ease (Motion §7).
struct KVBar: View {
    let fraction: Double
    var tint: Color = Color.kv.cursor
    var height: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule(style: .continuous)
            .fill(Color.kv.fill)
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: proxy.size.width * min(1, max(0, fraction)))
                }
            }
            .clipShape(Capsule(style: .continuous))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: fraction)
            .accessibilityHidden(true)
    }
}

/// Equal columns separated by `line-2` rules when they fit at `minimum`
/// each; stacked (rules between rows) when they don't — Models.dc's
/// `repeat(auto-fit, minmax(200px, 1fr))`.
struct KVAdaptiveColumns<Content: View>: View {
    let minimum: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                Group(subviews: content) { columns in
                    ForEach(columns) { column in
                        if column.id != columns.first?.id {
                            Rectangle().fill(Color.kv.line2).frame(width: 1)
                        }
                        column.frame(minWidth: minimum)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                Group(subviews: content) { columns in
                    ForEach(columns) { column in
                        if column.id != columns.first?.id {
                            Rectangle().fill(Color.kv.line2).frame(height: 1)
                        }
                        column
                    }
                }
            }
        }
    }
}

/// Models.dc's "More models": the title, the filter pills and the grid of
/// model cards (every model but the one in use).
@MainActor
struct ModelsMoreSection: View {
    @Bindable var speechModels: SpeechModelsViewModel
    let reduceMotion: Bool
    let onDelete: (ModelCardState) -> Void

    var body: some View {
        // The in-use card already shows the default; "Recommended" (the
        // view model's default filter) would leave the grid nearly empty,
        // so the grid reads it as All, the design's first pill.
        let source = speechModels.filter == .recommended ? speechModels.cards : speechModels.filteredCards
        let cards = source.filter { !$0.isDefault }
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    title
                    Spacer(minLength: 0)
                    pills
                }
                VStack(alignment: .leading, spacing: 10) {
                    title
                    pills
                }
            }
            if cards.isEmpty {
                Text("No models to show.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kv.text2)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(cards) { card in
                        ModelTileCard(card: card, viewModel: speechModels, reduceMotion: reduceMotion, onDelete: { onDelete(card) })
                    }
                }
            }
        }
    }

    private var title: some View {
        Text("More models", bundle: .module)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.kv.text)
            .accessibilityAddTraits(.isHeader)
    }

    private var pills: some View {
        HStack(spacing: 6) {
            ForEach(ModelCardFilter.allCases.filter { $0 != .recommended }) { filter in
                KVFilterPill(title: filter.title, isOn: speechModels.filter == filter || (filter == .all && speechModels.filter == .recommended)) {
                    withAnimation(KVControlMotion.stateChange(reduceMotion: reduceMotion)) { speechModels.filter = filter }
                }
            }
            Button {
                speechModels.isShowingManagePanel = true
            } label: {
                Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(Color.kv.text2)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Manage Models", bundle: .module))
            .accessibilityHint(Text("Opens the voice activity detection option for streaming.", bundle: .module))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Filter models", bundle: .module))
    }
}

/// A filter pill: 28 pt capsule, 12 pt semibold; chosen = `ink` with white
/// text, otherwise `surface` with a `key-line` border.
struct KVFilterPill: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        // A rounded rectangle, not a stroked Capsule: the continuous
        // capsule stroke left 1 pt slivers beside each pill when rendered.
        Text(verbatim: title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isOn ? Color.white : Color.kv.text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(isOn ? Color.kv.ink : Color.kv.surface, in: RoundedRectangle(cornerRadius: 14, style: .circular))
            .overlay {
                if !isOn { RoundedRectangle(cornerRadius: 14, style: .circular).inset(by: 0.5).stroke(Color.kv.keyLine, lineWidth: 1) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture(perform: action)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            .accessibilityValue(Text(verbatim: KVAccessibility.selectionValue(isOn)))
            .accessibilityAction { action() }
            .focusable()
            .onKeyPress(.space) { action(); return .handled }
    }
}

/// One model card (Models.dc `article`).
@MainActor
struct ModelTileCard: View {
    let card: ModelCardState
    let viewModel: SpeechModelsViewModel
    let reduceMotion: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if card.entry.isRecommended {
                    Text("Recommended", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.kv.voiceInk)
                }
                Text(verbatim: card.entry.fullDisplayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.kv.text)
                Text(verbatim: card.entry.languageSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kv.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            KVFlowLayout(spacing: 5) {
                ForEach(Self.tags(for: card), id: \.0) { tag in
                    Text(verbatim: tag.0)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tag.1 == .neutral ? Color.kv.text : tag.1.ink.color)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(tag.1 == .neutral ? Color.kv.fill : tag.1.soft.color, in: Capsule(style: .continuous))
                }
            }
            if card.state != nil, card.state != .absent {
                status
            }
            if let license = card.licenseLine {
                Text(verbatim: license)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kv.text2.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text("License: \(license)", bundle: .module))
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(Color.kv.line2).frame(height: 1)
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("On disk", bundle: .module).foregroundStyle(Color.kv.text2)
                        Text(verbatim: Self.sizeText(card))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    actionButtons
                }
                if card.isInstalled, card.entry.availableModes.count > 1 {
                    KVSegmented(
                        "Transcription mode",
                        selection: Binding(get: { viewModel.mode(for: card.id) }, set: { viewModel.setMode($0, for: card.id) }),
                        options: card.entry.availableModes.map { ($0, DomainCopy.localized($0.displayName)) }
                    )
                }
                if let reason = viewModel.mutationDisabledReason(for: card), !card.actions.isEmpty {
                    Text(reason).font(.system(size: 11)).foregroundStyle(Color.kv.text2)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.kv.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.kv.line, lineWidth: 1))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: card.actions)
        .accessibilityElement(children: .contain)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(verbatim: card.statusDescription)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress = card.progress {
                    Spacer(minLength: 0)
                    // Motion §7: the percentage rolls, never counts up from 0.
                    Text(verbatim: "\(Int((progress * 100).rounded())) %")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Color.kv.text2)
                        .contentTransition(.numericText(value: progress))
                        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.7), value: Int(progress * 100))
                }
            }
            .font(.system(size: 11))
            if let progress = card.progress {
                KVBar(fraction: progress)
                    .accessibilityLabel(Text("\(card.entry.fullDisplayName) progress", bundle: .module))
                    .accessibilityValue(Text("\(Int(progress * 100)) percent", bundle: .module))
            } else if card.isBusy {
                ProgressView().progressViewStyle(.linear).controlSize(.small).tint(Color.kv.cursor)
            }
        }
    }

    private var statusColor: Color {
        switch card.state {
        case .ready?: Color.kv.okInk
        case .corrupt?, .incompatible?, .error?: Color.kv.errInk
        default: Color.kv.text2
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 6) {
            if viewModel.isPending(card.id) {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
            }
            ForEach(card.actions) { action in
                Button(role: action.isDestructive ? .destructive : nil) {
                    if action == .delete { onDelete() } else { viewModel.perform(action, on: card) }
                } label: {
                    Text(verbatim: card.title(for: action))
                }
                .buttonStyle(KVButtonStyle(action == .retry ? .primary : .standard, height: 28))
                .disabled(!viewModel.isEnabled(action, for: card))
                .accessibilityLabel(Text(verbatim: "\(card.title(for: action)) \(card.entry.fullDisplayName)"))
            }
        }
    }

    static func tags(for card: ModelCardState) -> [(String, KVTone)] {
        var tags: [(String, KVTone)] = []
        if card.entry.supportsStreaming {
            tags.append((String(localized: "Live text", bundle: .module), .voice))
        }
        switch card.entry.punctuation {
        case true?: tags.append((String(localized: "Punctuation", bundle: .module), .neutral))
        case false?: tags.append((String(localized: "No punctuation", bundle: .module), .warn))
        case nil: break
        }
        if card.entry.supportsBatch, !card.entry.supportsStreaming {
            tags.append((String(localized: "Batch", bundle: .module), .neutral))
        }
        return tags
    }

    static func sizeText(_ card: ModelCardState) -> String {
        if card.entry.isSystemManaged { return String(localized: "by macOS", bundle: .module) }
        return ByteCountFormatter.string(fromByteCount: card.entry.downloadBytes, countStyle: .file)
    }
}
