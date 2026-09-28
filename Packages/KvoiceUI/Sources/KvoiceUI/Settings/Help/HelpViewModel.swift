import AppKit
import Foundation
import Observation

/// The destinations the Help section links to. Placeholders that can be
/// changed in one place; nothing else in the app knows these URLs.
public enum HelpLinks {
    public static let userGuide = URL(string: "https://github.com/kccarlos/kvoice/blob/main/Docs/README.md")!
    public static let setupAI = URL(string: "https://github.com/kccarlos/kvoice/blob/main/README.md#what-it-does")!
    public static let website = URL(string: "https://github.com/kccarlos/kvoice")!
    /// Where Feedback › Compose addresses its mail. A placeholder until a support
    /// address exists.
    public static let feedbackAddress = "kvoice-feedback@example.com"
    /// ADR-026 (2026-09-28 amendment): where the App Store edition points
    /// for the full-featured Developer ID edition, beside every "not in this
    /// edition" sentence. Shown only in the App Store edition
    /// (`SettingsAvailabilityModel.fullEditionLink`).
    public static let fullEditionReleases = URL(string: "https://github.com/kccarlos/kvoice/releases/latest")!
    /// The one switch for that link. App Review may object to an app
    /// pointing at another distribution of itself (Guidelines 2.3.10 and
    /// 3.1.x); setting this to `false` removes every instance at once.
    public static let offersFullEditionLink = true
}

/// The actions the Help section can take that only the app shell can
/// perform. Every one defaults to a no-op so the view can be previewed and
/// tested without a shell.
public struct HelpActions {
    public var resetOnboarding: @MainActor () -> Void
    public var resetPreferences: @MainActor () -> Void
    public var restartApp: @MainActor () -> Void
    /// "Show Tutorial" (Later waves: tutorial pages). Reopens the standalone
    /// tour without redoing the rest of setup.
    public var showTutorial: @MainActor () -> Void

    public init(
        resetOnboarding: @escaping @MainActor () -> Void = {},
        resetPreferences: @escaping @MainActor () -> Void = {},
        restartApp: @escaping @MainActor () -> Void = {},
        showTutorial: @escaping @MainActor () -> Void = {}
    ) {
        self.resetOnboarding = resetOnboarding
        self.resetPreferences = resetPreferences
        self.restartApp = restartApp
        self.showTutorial = showTutorial
    }
}

/// State for the Help section: links, feedback composition, and the
/// troubleshooting actions. The view model builds URLs; opening them goes
/// through `openURL` so tests can capture what would have been opened.
@Observable
@MainActor
public final class HelpViewModel {
    public var includeDiagnosticsInFeedback = false
    /// Set when `openURL` reported failure, so the section can show the
    /// address to copy instead of a dead button.
    public private(set) var lastOpenFailed: URL?

    public let actions: HelpActions
    private let diagnosticsProvider: @MainActor () -> DiagnosticsSnapshot?
    private let appVersionProvider: @MainActor () -> String
    private let openURL: @MainActor (URL) -> Bool

    public init(
        actions: HelpActions = HelpActions(),
        diagnosticsProvider: @escaping @MainActor () -> DiagnosticsSnapshot? = { nil },
        appVersion: @escaping @MainActor () -> String = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        },
        openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.actions = actions
        self.diagnosticsProvider = diagnosticsProvider
        self.appVersionProvider = appVersion
        self.openURL = openURL
    }

    // MARK: Links

    public func openUserGuide() { open(HelpLinks.userGuide) }
    public func openSetupAI() { open(HelpLinks.setupAI) }
    public func openWebsite() { open(HelpLinks.website) }

    // MARK: Feedback

    /// The `mailto:` the Compose button opens: a subject naming the version
    /// and, when the user opted in, the same redacted diagnostics report Copy
    /// Diagnostics produces (never a transcript, key, or endpoint path).
    public func feedbackMailURL(now: Date = Date()) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = HelpLinks.feedbackAddress
        var body = "\n\n"
        if includeDiagnosticsInFeedback, let snapshot = diagnosticsProvider() {
            body += "---\n" + DiagnosticsReport.render(snapshot, generatedAt: now)
        }
        components.queryItems = [
            URLQueryItem(name: "subject", value: "KVoice \(appVersionProvider()) feedback"),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }

    @discardableResult
    public func composeFeedback() -> URL? {
        guard let url = feedbackMailURL() else { return nil }
        open(url)
        return url
    }

    // MARK: Troubleshooting

    public func resetOnboarding() { actions.resetOnboarding() }
    public func resetPreferences() { actions.resetPreferences() }
    public func restartApp() { actions.restartApp() }
    public func showTutorial() { actions.showTutorial() }

    private func open(_ url: URL) {
        lastOpenFailed = openURL(url) ? nil : url
    }
}
