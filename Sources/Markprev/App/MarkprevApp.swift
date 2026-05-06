import AppKit
import MarkprevCore
import SwiftUI

@main
struct MarkprevApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspaceStore = WorkspaceStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: workspaceStore)
                .frame(minWidth: 920, minHeight: 620)
        }
        .commands {
            CommandMenu("Workspace") {
                Button("Open Folder...") {
                    NotificationCenter.default.post(name: .markprevOpenFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Save") {
                    NotificationCenter.default.post(name: .markprevSaveDocument, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Refresh") {
                    NotificationCenter.default.post(name: .markprevRefreshWorkspace, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Settings {
            ThemeSettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
