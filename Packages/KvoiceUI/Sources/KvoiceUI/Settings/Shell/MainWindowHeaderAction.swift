import SwiftUI

/// UI v2 fidelity F3b: the page header's one trailing button (Window.dc
/// `headerAction`: "Runtime…" on Speech Models, "Transcribe File…" on
/// History). The page publishes it with `mainWindowHeaderAction(_:)`
/// because the page owns the state behind it (the Runtime sheet, whether a
/// file can be transcribed); `MainWindowView` draws it in
/// `SectionHeaderView`, and only on the section it belongs to.
public struct MainWindowHeaderAction: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Speech Models › the Runtime details sheet.
        case runtimeDetails
        /// History › transcribe an audio or video file into a history row.
        case transcribeFile
    }

    public let kind: Kind
    public let isEnabled: Bool
    /// The work it starts is running: a spinner replaces the button.
    public let isBusy: Bool
    /// Tooltip and VoiceOver hint; says why when disabled.
    public let help: String
    let perform: @MainActor @Sendable () -> Void

    public init(kind: Kind, isEnabled: Bool = true, isBusy: Bool = false, help: String, perform: @escaping @MainActor @Sendable () -> Void) {
        self.kind = kind
        self.isEnabled = isEnabled
        self.isBusy = isBusy
        self.help = help
        self.perform = perform
    }

    /// The button's words (Window.dc).
    public var title: String {
        switch kind {
        case .runtimeDetails: return String(localized: "Runtime…", bundle: .module)
        case .transcribeFile: return String(localized: "Transcribe File…", bundle: .module)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.isEnabled == rhs.isEnabled && lhs.isBusy == rhs.isBusy && lhs.help == rhs.help
    }

    /// Speech Models' "Runtime…": always available.
    public static func runtimeDetails(perform: @escaping @MainActor @Sendable () -> Void) -> Self {
        Self(kind: .runtimeDetails, help: String(localized: "Show the speech runtime, its memory and the model package.", bundle: .module), perform: perform)
    }

    /// History's "Transcribe File…": absent when this build cannot
    /// transcribe files, disabled while Save History is off (FR-HIST-001:
    /// the result is a history row), a spinner while a file is running.
    public static func transcribeFile(
        canTranscribeFiles: Bool,
        historyEnabled: Bool,
        isTranscribing: Bool,
        perform: @escaping @MainActor @Sendable () -> Void
    ) -> Self? {
        guard canTranscribeFiles else { return nil }
        return Self(
            kind: .transcribeFile,
            isEnabled: historyEnabled && !isTranscribing,
            isBusy: isTranscribing,
            help: historyEnabled
                ? String(localized: "Transcribe an audio or video file…", bundle: .module)
                : String(localized: "Turn on Save History to transcribe files", bundle: .module),
            perform: perform
        )
    }
}

extension MainWindowSection {
    /// Which header action this page may show (Window.dc: only Speech
    /// Models and History have one).
    public var headerActionKind: MainWindowHeaderAction.Kind? {
        switch self {
        case .models: return .runtimeDetails
        case .history: return .transcribeFile
        default: return nil
        }
    }

    /// The published action, if it belongs on this page.
    func headerAction(from published: MainWindowHeaderAction?) -> MainWindowHeaderAction? {
        guard let published, published.kind == headerActionKind else { return nil }
        return published
    }
}

struct MainWindowHeaderActionKey: PreferenceKey {
    static let defaultValue: MainWindowHeaderAction? = nil

    static func reduce(value: inout MainWindowHeaderAction?, nextValue: () -> MainWindowHeaderAction?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Publishes the page header's trailing button (nil: none).
    public func mainWindowHeaderAction(_ action: MainWindowHeaderAction?) -> some View {
        preference(key: MainWindowHeaderActionKey.self, value: action)
    }
}

/// The drawn header button: 28 pt, radius 7, `line` border on `surface`,
/// 12 pt (Window.dc).
struct MainWindowHeaderActionButton: View {
    let action: MainWindowHeaderAction

    var body: some View {
        if action.isBusy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(verbatim: action.title.replacingOccurrences(of: "…", with: ""))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kv.text2)
            }
            .frame(height: 28)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: action.title))
            .accessibilityValue(Text("In progress", bundle: .module))
        } else {
            Button {
                action.perform()
            } label: {
                Text(verbatim: action.title)
            }
            .buttonStyle(KVButtonStyle(.standard, height: 28))
            .disabled(!action.isEnabled)
            .help(Text(verbatim: action.help))
            .accessibilityHint(Text(verbatim: action.help))
        }
    }
}
