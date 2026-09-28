import SwiftUI
import KvoiceDomain

/// The Permissions section: one card per prerequisite — Keyboard Shortcut,
/// Microphone, Accessibility — each with why, status, last checked, one
/// action, and a refresh.
///
/// Permission state is polled every second while the section is on screen
/// (FR-PERM-005) and re-read on app activation; the `.task` is cancelled as
/// soon as the section is hidden. The shortcut registration state is read
/// from the shell on the same tick.
@MainActor
public struct PermissionsSectionView: View {
    private let general: GeneralSettingsViewModel
    private let permissions: PermissionStatusViewModel
    private let shortcutRegistration: @MainActor () -> ShortcutRegistrationState
    private let onChooseShortcut: @MainActor () -> Void

    @State private var registration: ShortcutRegistrationState = .unregistered
    @State private var shortcutCheckedAt: Date?

    public init(
        general: GeneralSettingsViewModel = .init(),
        permissions: PermissionStatusViewModel = .init(),
        shortcutRegistration: @escaping @MainActor () -> ShortcutRegistrationState = { .unregistered },
        onChooseShortcut: @escaping @MainActor () -> Void = {}
    ) {
        self.general = general
        self.permissions = permissions
        self.shortcutRegistration = shortcutRegistration
        self.onChooseShortcut = onChooseShortcut
    }

    public var body: some View {
        Form {
            Section {
                ShortcutCardView(
                    card: ShortcutCard(
                        confirmed: general.confirmedShortcut,
                        registration: registration,
                        lastChecked: shortcutCheckedAt
                    ),
                    onAction: {
                        if general.confirmedShortcut == nil {
                            general.confirmRecommendedShortcut()
                        } else {
                            onChooseShortcut()
                        }
                        refreshShortcut()
                    }
                )

                ForEach(PermissionKind.allCases) { kind in
                    PermissionCardView(
                        card: permissions.card(for: kind),
                        deepLinkFailed: permissions.systemSettingsOpenFailed == kind,
                        isActionInProgress: permissions.actionInProgress == kind,
                        onAction: {
                            Task { @MainActor in
                                await permissions.performAction(for: kind)
                            }
                        }
                    )
                }
            } footer: {
                // M9/P-M9 (2026-09-16): one Refresh for the page instead of
                // one per card — every card already refreshes itself once a
                // second while the page is open, so the footer no longer
                // contradicts that by also offering a button per card.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Status refreshes every second while this page is open; a grant made in System Settings appears here without relaunching.")
                    Button {
                        refreshAll()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .accessibilityHint("Reads the shortcut, microphone, and Accessibility status again, without prompting.")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            refreshShortcut()
            // Non-prompting reads only. Cancelled when the section disappears.
            await permissions.pollWhileVisible()
        }
        .task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                refreshShortcut()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshShortcut()
            Task { @MainActor in
                await permissions.refresh()
            }
        }
    }

    private func refreshShortcut() {
        let latest = shortcutRegistration()
        // Equality-guarded: an unchanged state must not re-render the card
        // once a second.
        if latest != registration {
            registration = latest
        }
        shortcutCheckedAt = Date()
    }

    /// The page's one Refresh (M9/P-M9): every card's non-prompting re-read,
    /// in one press.
    private func refreshAll() {
        refreshShortcut()
        Task { @MainActor in
            await permissions.refresh()
        }
    }
}
