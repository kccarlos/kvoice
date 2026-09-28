import AppKit
import KvoiceAppCore
import KvoiceDomain
import KvoiceUI

/// The standalone tutorial window and the existing-user banner (Later waves:
/// tutorial pages). Since the six-step wizard (P-W1, 2026-09-16) the tour
/// is no longer a wizard stage: Ready's "Take the Quick Tour" link calls
/// `showTutorial()` below through `OnboardingViewModel.openTutorialHandler`,
/// so this file owns every path to the tour — Help › Quick Tour, the
/// main-window banner, and the wizard link — plus persisting
/// `LocalState.tutorialSeen`.
extension AppDelegate {
    /// Help › Quick Tour, the banner's "Show" button, and the wizard's Ready
    /// link. Reuses one window the same way `showSetup()` reuses
    /// `onboardingWindow`.
    func showTutorial() {
        guard !terminationInProgress else { return }
        if tutorialWindow == nil {
            let viewModel = TutorialViewModel(
                openMainWindowHandler: { [weak self] section in
                    self?.openMainWindow(section: section)
                },
                onFinished: { [weak self] in
                    self?.tutorialWindow?.close()
                }
            )
            tutorialWindow = TutorialWindowController(viewModel: viewModel)
        }
        markTutorialSeen()
        tutorialWindow?.show()
    }

    /// Persists `tutorialSeen` once, whether the tour was actually opened or
    /// the banner's "Not now" dismissed the offer — either way the one-time
    /// offer has been made and must not repeat (Later waves: tutorial pages).
    func markTutorialSeen() {
        sendLocalStateIntent(.markTutorialSeen(origin: .shell))
    }

    /// Whether the main window should open with the "New: a quick tour"
    /// banner: setup was completed under a build before the tutorial
    /// existed, so the wizard never showed it and the banner is the only
    /// offer this user gets — never a forced wizard.
    func shouldOfferTutorialBanner() -> Bool {
        (currentLocalState.onboardingVersionCompleted ?? 0) >= OnboardingViewModel.currentOnboardingVersion
            && !currentLocalState.tutorialSeen
    }
}
