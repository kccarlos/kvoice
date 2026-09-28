import SwiftUI
import KvoiceUI

@main
struct KvoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The app presents its one window from AppKit (see MainWindowController).
    // `App` still requires a scene; a `Settings` scene never opens on its
    // own, and its app-menu item is replaced below so ⌘, opens the main
    // window on the Settings section instead of this empty scene.
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(String(localized: "Settings…", table: "Shell")) {
                    appDelegate.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
