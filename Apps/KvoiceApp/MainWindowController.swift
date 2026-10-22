import AppKit
import SwiftUI
import KvoiceUI

/// The one main window (product decision #7, regrouped by the owner on
/// 2026-10-21): a sidebar of `MainWindowSection`s — an untitled top group
/// (Home, History), then Dictation (Shortcuts, Recording, Speech Models,
/// Microphone, Dictionary), AI (AI Actions), App (Data & Privacy,
/// Permissions, General, Help) — hosting the existing views. Every "open History / Settings / Model…" entry point in the
/// app lands here through `open(section:)`.
///
/// Owned by AppKit rather than a SwiftUI scene:
/// `NSApp.sendAction(Selector(("showSettingsWindow:")))` is a private, renamed
/// selector that silently does nothing for this accessory (`LSUIElement`) app,
/// and a `WindowGroup` would open at launch. `OnboardingWindowController`
/// works the same way.
///
/// The window frame is autosaved by AppKit. A newly created window opens on
/// Home unless an entry point asked for a page (owner decision 2026-10-21,
/// `MainWindowSection.opening(requested:)`); within a launch the window keeps
/// the page it last showed. The selection is still written to
/// `LocalState.mainWindowSection`, which no longer picks the opening page.
@MainActor
final class MainWindowController: NSWindowController {
    /// View models for the sections the app delegate does not own directly.
    /// Lives as long as the window does, which is the life of the app once
    /// opened.
    let surface: SettingsSurface
    let model: MainWindowModel

    init(appDelegate: AppDelegate, requestedSection: MainWindowSection?) {
        surface = SettingsSurface(appDelegate: appDelegate)
        model = MainWindowModel(
            selection: MainWindowSection.opening(requested: requestedSection),
            showTutorialBanner: appDelegate.shouldOfferTutorialBanner(),
            onSelectionChange: { [weak appDelegate] section in
                appDelegate?.mainWindowSectionChanged(section)
            },
            onShowTutorial: { [weak appDelegate] in
                appDelegate?.showTutorial()
            },
            onTutorialBannerDismissed: { [weak appDelegate] in
                appDelegate?.markTutorialSeen()
            }
        )
        let surface = surface
        let model = model
        appDelegate.configureHomeTestDictation()
        let rootView = MainWindowView(model: model) { [weak appDelegate] section in
            guard let appDelegate else { return AnyView(EmptyView()) }
            if section == .home {
                return AnyView(HomeView(model: model, history: appDelegate.historyViewModel, testDictation: appDelegate.homeTestDictation))
            }
            return Self.content(for: section, appDelegate: appDelegate, surface: surface)
        }
        // NSHostingController: the content view controller AppKit sizes.
        let hosting = NSHostingController(rootView: rootView)
        // SwiftUI manages neither the size nor the title bar: see
        // `MainWindowChrome.configure(_:)` for why each is off.
        MainWindowChrome.configure(hosting)
        let window = NSWindow(contentViewController: hosting)
        // UI v2 fidelity F2: the design has no toolbar and no visible title
        // — the drawn sidebar runs to the top with the traffic lights in it
        // and the detail column starts with an empty 38 pt strip. The title
        // is still set (`MainWindowView` keeps it on the selected page) for
        // VoiceOver and the Window list; `toolbars.md › Titles` (M13/N27):
        // never the app's own name.
        MainWindowChrome.configure(window)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // One size for the window, set here rather than inside any section.
        // When every tab carried its own minWidth/minHeight, the largest one
        // silently dictated the window size and switching tabs resized it.
        window.setContentSize(Self.defaultContentSize)
        window.contentMinSize = Self.minimumContentSize
        super.init(window: window)
        window.center()
        // After `center()`: a frame saved from an earlier launch replaces the
        // centred default, so the window reopens where the user left it.
        window.setFrameAutosaveName("kvoice.main")
        window.isRestorable = false
        // ⌘1–⌘0 pick the default AI action while this window is key (the
        // AI Actions grid shows the badges). A local monitor rather than menu
        // key equivalents: an accessory app has no main menu to hang them on.
        defaultActionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak appDelegate] event in
            guard let self, let appDelegate, event.window === self.window else { return event }
            return appDelegate.handleDefaultActionShortcut(event) ? nil : event
        }
    }

    private var defaultActionKeyMonitor: Any?

    isolated deinit {
        if let defaultActionKeyMonitor {
            NSEvent.removeMonitor(defaultActionKeyMonitor)
        }
    }

    static let defaultContentSize = NSSize(width: 960, height: 640)
    static let minimumContentSize = NSSize(width: 820, height: 540)

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController does not support NSCoder construction")
    }

    /// Shows the window on `section` (or where it was, when nil) and brings
    /// it front.
    func open(section: MainWindowSection?) {
        if let section {
            model.select(section)
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Builds one section's content. Type-erased at this one seam; every view
    /// underneath is concrete.
    private static func content(
        for section: MainWindowSection,
        appDelegate: AppDelegate,
        surface: SettingsSurface
    ) -> AnyView {
        switch section {
        case .home:
            // Built in `init`, which has the window model the page needs.
            return AnyView(EmptyView())

        case .history:
            return AnyView(HistoryView(viewModel: appDelegate.historyViewModel))

        case .aiActions:
            return AnyView(AIActionsSectionView(
                ai: appDelegate.aiSettingsViewModel,
                modes: appDelegate.promptModeSettingsViewModel,
                availability: appDelegate.settingsAvailability
            ))

        case .models:
            return AnyView(
                ModelSettingsView(viewModel: surface.modelSettingsViewModel)
                    // The shell's state is polled only while this section
                    // is on screen. It used to run for the life of the
                    // window, four times a second, on any tab.
                    .task {
                        await surface.syncWhileVisible()
                    }
            )

        case .permissions:
            return AnyView(PermissionsSectionView(
                general: appDelegate.generalSettingsViewModel,
                permissions: surface.permissionStatusViewModel,
                shortcutRegistration: { [weak appDelegate] in
                    appDelegate?.composition.shortcutAdapter.registrationState ?? .unregistered
                },
                onChooseShortcut: { [weak appDelegate] in
                    appDelegate?.composition.shortcutAdapter.presentRecorder()
                }
            ))

        case .dictionary:
            return AnyView(DictionarySectionView(
                model: surface.dictionaryViewModel,
                availability: appDelegate.settingsAvailability
            ))
        case .audioInput:
            return AnyView(AudioInputSectionView(
                microphoneTest: surface.microphoneTestViewModel,
                permissions: surface.permissionStatusViewModel,
                inputSelection: appDelegate.audioInputViewModel
            ))

        case .shortcuts:
            return AnyView(ShortcutsSectionView(
                general: appDelegate.generalSettingsViewModel,
                onChooseShortcut: { [weak appDelegate] in
                    appDelegate?.composition.shortcutAdapter.presentRecorder()
                },
                triggers: surface.triggerOptionBindings,
                availability: appDelegate.settingsAvailability,
                shortcutRegistration: { [weak appDelegate] in
                    appDelegate?.composition.shortcutAdapter.registrationState ?? .unregistered
                }
            ))

        case .recording:
            return AnyView(RecordingSectionView(
                general: appDelegate.generalSettingsViewModel,
                options: surface.recordingOptionBindings,
                availability: appDelegate.settingsAvailability,
                inputSelection: appDelegate.audioInputViewModel
            ))

        case .dataPrivacy:
            return AnyView(DataPrivacySectionView(
                history: appDelegate.historyViewModel,
                dataPrivacy: surface.dataPrivacyViewModel,
                privacy: surface.privacyAboutViewModel
            ))

        case .general:
            // `help` carries Reset Preferences and Restart, which moved from
            // Help to General with the regroup.
            return AnyView(GeneralSectionView(
                viewModel: appDelegate.generalSettingsViewModel,
                backup: surface.backupSettingsViewModel,
                help: surface.helpViewModel
            ))

        case .help:
            return AnyView(HelpSectionView(
                viewModel: surface.helpViewModel,
                privacy: surface.privacyAboutViewModel
            ))
        }
    }
}
