import AppKit
import MarkprevCore
import SwiftUI

@main
struct MarkprevApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspaceStore = WorkspaceStore()
    @StateObject private var themeStore = ThemeSettingsStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: workspaceStore, themeStore: themeStore)
                .frame(minWidth: 920, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            MarkprevCommandMenu()
        }

        Settings {
            PreferencesView(themeStore: themeStore)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
