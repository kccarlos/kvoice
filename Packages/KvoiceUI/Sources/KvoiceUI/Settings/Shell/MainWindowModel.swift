import Foundation
import Observation

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
