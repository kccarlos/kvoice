import AppKit
import SwiftUI
import KvoiceUI

/// The one main window (product decision #7, regrouped 2026-09-13): a sidebar
/// of `MainWindowSection`s under four headings — Dictation (Shortcuts &
/// Triggers, Recording, Speech Models, Audio Input), AI (AI Actions), Data
/// (History, Data & Privacy), App (General, Permissions, Help) — hosting the
/// existing views. Every "open History / Settings / Model…" entry point in the
/// app lands here through `open(section:)`.
///
/// Owned by AppKit rather than a SwiftUI scene:
/// `NSApp.sendAction(Selector(("showSettingsWindow:")))` is a private, renamed
/// selector that silently does nothing for this accessory (`LSUIElement`) app,
/// and a `WindowGroup` would open at launch. `OnboardingWindowController`
/// works the same way.
///
/// The window frame is autosaved by AppKit; the selected section is persisted
/// through `LocalState.mainWindowSection` so both survive a relaunch.
@MainActor
final class MainWindowController: NSWindowController {
    /// View models for the sections the app delegate does not own directly.
    /// Lives as long as the window does, which is the life of the app once
    /// opened.
    let surface: SettingsSurface
    let model: MainWindowModel

    init(appDelegate: AppDelegate) {
        surface = SettingsSurface(appDelegate: appDelegate)
        model = MainWindowModel(
            selection: MainWindowSection(persisted: appDelegate.currentLocalState.mainWindowSection),
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
        let rootView = MainWindowView(model: model) { [weak appDelegate] section in
            guard let appDelegate else { return AnyView(EmptyView()) }
            return Self.content(for: section, appDelegate: appDelegate, surface: surface)
        }
        // NSHostingController rather than NSHostingView so SwiftUI owns the
        // toolbar: the sidebar toggle and the navigation title need it.
        let hosting = NSHostingController(rootView: rootView)
        // Without this the controller publishes SwiftUI's ideal size as its
        // preferredContentSize and the window grows to fit the History
        // split view (observed: 1054×1194) instead of keeping the size below.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        // M13/N27: no AppKit title — `MainWindowView`'s `.navigationTitle`
        // (`model.selection.title`) is what the hosting controller's unified
        // toolbar shows, and `toolbars.md › Titles` says not to title a
        // window with the app's own name. A static "kvoice" here only ever
        // showed before SwiftUI's first layout pass, if at all; left
        // unset, that gap is a blank title bar rather than a wrong one.
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
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
                availability: appDelegate.settingsAvailability
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
