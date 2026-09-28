import Foundation
import Observation

/// The tutorial's three short pages (Later waves: tutorial pages), offered
/// as the "Take the Quick Tour" link on the wizard's Ready page and
/// re-openable any time from Help › Quick Tour. Copy and an SF Symbol illustration live on the case
/// so `TutorialPageContentView` stays a pure renderer of whichever page is
/// current — the same split `OnboardingStage` uses for the wizard.
public enum TutorialPage: Int, CaseIterable, Identifiable, Sendable, Equatable {
    case textDestination
    case menuBar
    case makeItYours

    public var id: Self { self }

    /// 1-based position, for "Page 2 of 3".
    public var ordinal: Int { rawValue + 1 }

    public var next: TutorialPage? { TutorialPage(rawValue: rawValue + 1) }
    public var previous: TutorialPage? { TutorialPage(rawValue: rawValue - 1) }

    public var title: String {
        switch self {
        case .textDestination: return String(localized: "Where the text goes", bundle: .module)
        case .menuBar: return String(localized: "The menu bar", bundle: .module)
        case .makeItYours: return String(localized: "Make it yours", bundle: .module)
        }
    }

    public var body: String {
        switch self {
        case .textDestination:
            return String(localized: "Dictate into whatever field has focus — KVoice types straight into apps like Terminal, not just text boxes that accept pasted text. If a target cannot be reached safely, the finished text goes to the clipboard instead and the HUD says so.", bundle: .module)
        case .menuBar:
            return String(localized: "Click the KVoice icon in the menu bar any time: Start or Stop and Cancel the current dictation, turn AI Actions on or off, pick the Default Action, and open History.", bundle: .module)
        case .makeItYours:
            return String(localized: "Teach KVoice names and jargon in Dictionary, turn on polish or translation in AI Actions, switch speech models, or choose a different device in Microphone — all in KVoice's main window.", bundle: .module)
        }
    }

    /// The illustration's main SF Symbol; `TutorialPageContentView` composes
    /// the rest of the picture around it.
    public var symbolName: String {
        switch self {
        case .textDestination: return "cursorarrow.rays"
        case .menuBar: return "menubar.arrow.up.rectangle"
        case .makeItYours: return "slider.horizontal.3"
        }
    }
}

/// One entry in the "Make it yours" page's pointer list: a symbol, a label,
/// and the main-window section it deep-links to via `openMainWindow(section:)`.
public struct TutorialCustomizePointer: Identifiable, Sendable {
    public let id: MainWindowSection
    public let symbolName: String
    public let title: String

    public static let all: [TutorialCustomizePointer] = [
        TutorialCustomizePointer(id: .dictionary, symbolName: "character.book.closed", title: String(localized: "Dictionary", bundle: .module)),
        TutorialCustomizePointer(id: .aiActions, symbolName: "sparkles", title: String(localized: "AI Actions", bundle: .module)),
        TutorialCustomizePointer(id: .models, symbolName: "waveform", title: String(localized: "Speech Models", bundle: .module)),
        TutorialCustomizePointer(id: .audioInput, symbolName: "mic", title: String(localized: "Microphone", bundle: .module))
    ]
}

/// Drives the standalone tutorial window (Help › Quick Tour, and the
/// wizard's Ready-page link, which opens the same window). Since the
/// six-step wizard of 2026-09-16 there is no embedded tutorial stage; this
/// is the only tutorial flow.
@Observable
@MainActor
public final class TutorialViewModel {
    public private(set) var page: TutorialPage
    public private(set) var isFinished = false

    /// "Open kvoice" on the last page. Nil (tests, previews) does nothing.
    public var openMainWindowHandler: (@MainActor (MainWindowSection) -> Void)?

    private let onFinished: @MainActor () -> Void

    public init(
        page: TutorialPage = .textDestination,
        openMainWindowHandler: (@MainActor (MainWindowSection) -> Void)? = nil,
        onFinished: @escaping @MainActor () -> Void = {}
    ) {
        self.page = page
        self.openMainWindowHandler = openMainWindowHandler
        self.onFinished = onFinished
    }

    public var isFirstPage: Bool { page == TutorialPage.allCases[0] }
    public var isLastPage: Bool { page.next == nil }

    public var progressLabel: String {
        String(localized: "Page \(page.ordinal) of \(TutorialPage.allCases.count)", bundle: .module)
    }

    public func next() {
        guard !isFinished else { return }
        if let next = page.next {
            page = next
        } else {
            finish()
        }
    }

    public func back() {
        guard !isFinished, let previous = page.previous else { return }
        page = previous
    }

    public func skip() {
        finish()
    }

    public func openMainWindow(section: MainWindowSection) {
        openMainWindowHandler?(section)
    }

    /// Starts over from the first page. The Help window is reused
    /// (`TutorialWindowController`, like `OnboardingWindowController`), so
    /// reopening it should not resume mid-tour from a previous viewing.
    public func restart() {
        guard !isFinished else { return }
        page = TutorialPage.allCases[0]
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        onFinished()
    }
}
