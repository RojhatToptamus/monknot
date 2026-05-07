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
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandMenu("Workspace") {
                Button("New Markdown") {
                    NotificationCenter.default.post(name: .markprevNewMarkdown, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])

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

            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    NotificationCenter.default.post(name: .markprevZoomIn, object: nil)
                }
                .keyboardShortcut("+", modifiers: [.command])

                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .markprevZoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button("Actual Size") {
                    NotificationCenter.default.post(name: .markprevResetZoom, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
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
