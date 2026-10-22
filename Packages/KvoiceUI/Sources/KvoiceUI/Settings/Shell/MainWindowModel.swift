import Foundation
import Observation

/// UI v2: the readiness pill at the foot of the sidebar — the same
/// one-line summary the status panel and menu lead with (the shell's
/// `statusSummary`), a dot and words, and the recording shortcut's keys.
/// Nil (a preview, or before the shell's first update) draws no pill.
public struct MainWindowReadiness: Equatable, Sendable {
    public let title: String
    /// Something blocks or degrades dictation: warn tone instead of ok.
    public let needsAttention: Bool
    /// The recording shortcut as key caps ("⌃", "⇧", "Space"); empty when
    /// none is set.
    public let shortcutKeys: [String]

    public init(title: String, needsAttention: Bool, shortcutKeys: [String]) {
        self.title = title
        self.needsAttention = needsAttention
        self.shortcutKeys = shortcutKeys
    }

    /// The shell's projection: `statusSummary` plus the shortcut's glyphs.
    public init(statusTitle: String, isBlocked: Bool, shortcutGlyphs: String?) {
        self.init(title: statusTitle, needsAttention: isBlocked, shortcutKeys: StatusPanelState.keyCaps(shortcutGlyphs))
    }

    var tone: KVTone { needsAttention ? .warn : .ok }

    /// One VoiceOver phrase: "Ready. Shortcut ⌃⇧Space".
    var accessibilityLabel: String {
        guard !shortcutKeys.isEmpty else { return title }
        let shortcut = String(localized: "Shortcut", bundle: .module)
        return "\(title). \(shortcut) \(shortcutKeys.joined())"
    }

    /// A stand-in for previews and the offscreen renders.
    static let preview = MainWindowReadiness(title: "Ready", needsAttention: false, shortcutKeys: ["⌃", "⇧", "Space"])
}

/// Which section the main window shows. The app shell owns one instance,
/// routes every "open History / Settings / Model…" entry point through
/// `select(_:)`, and persists the choice through `onSelectionChange`.
@Observable
@MainActor
public final class MainWindowModel {
    public var selection: MainWindowSection {
        didSet {
            guard selection != oldValue else { return }
            onSelectionChange(selection)
        }
    }

    /// The "New: a quick tour" banner (Later waves: tutorial pages), for a
    /// user who finished setup before the tutorial existed. Shown at most
    /// once: both "Show" and "Not now" dismiss it for good, never a forced
    /// wizard.
    public private(set) var showTutorialBanner: Bool

    /// The sidebar's readiness pill; the shell pushes it with every status
    /// update (`AppDelegate.updateStatusPanel`).
    public var readiness: MainWindowReadiness?

    /// UI v2 wave 5a: the Home page's hero; the shell pushes it with the
    /// readiness pill. Nil draws a hero without chips.
    public var home: HomeHeroState?

    private let onSelectionChange: @MainActor (MainWindowSection) -> Void
    private let onShowTutorial: @MainActor () -> Void
    private let onTutorialBannerDismissed: @MainActor () -> Void

    public init(
        selection: MainWindowSection = .default,
        showTutorialBanner: Bool = false,
        onSelectionChange: @escaping @MainActor (MainWindowSection) -> Void = { _ in },
        onShowTutorial: @escaping @MainActor () -> Void = {},
        onTutorialBannerDismissed: @escaping @MainActor () -> Void = {}
    ) {
        self.selection = selection
        self.showTutorialBanner = showTutorialBanner
        self.onSelectionChange = onSelectionChange
        self.onShowTutorial = onShowTutorial
        self.onTutorialBannerDismissed = onTutorialBannerDismissed
    }

    public func select(_ section: MainWindowSection) {
        selection = section
    }

    /// The banner's "Show" button: opens the tour and dismisses the banner.
    public func showTutorial() {
        onShowTutorial()
        dismissTutorialBanner()
    }

    /// The banner's "Not now" button, or any other dismissal. Marks the
    /// tutorial seen either way — the banner is a one-time offer, not a
    /// recurring nag.
    public func dismissTutorialBanner() {
        guard showTutorialBanner else { return }
        showTutorialBanner = false
        onTutorialBannerDismissed()
    }
}
