import AppKit
import MarkprevCore
import SwiftUI

@main
struct MarkprevApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspaceRestoration = InitialWorkspaceRestorationCoordinator()
    @StateObject private var themeStore = ThemeSettingsStore()
    private let workspaceWindowRequests = WorkspaceWindowRequestCenter.shared

    var body: some Scene {
        WindowGroup(
            "Markprev",
            id: MarkprevWorkspaceWindowRequest.windowGroupID,
            for: MarkprevWorkspaceWindowRequest.self
        ) { request in
            MarkprevWindowRootView(
                request: request.wrappedValue,
                themeStore: themeStore,
                workspaceRestoration: workspaceRestoration
            )
                .background(WorkspaceWindowRequestInstaller(requestCenter: workspaceWindowRequests))
                .frame(minWidth: 920, minHeight: 620)
        } defaultValue: {
            MarkprevWorkspaceWindowRequest()
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

private struct MarkprevWindowRootView: View {
    @StateObject private var workspaceStore = WorkspaceStore()
    let request: MarkprevWorkspaceWindowRequest
    @ObservedObject var themeStore: ThemeSettingsStore
    @ObservedObject var workspaceRestoration: InitialWorkspaceRestorationCoordinator
    @State private var didHandleInitialRequest = false

    var body: some View {
        ContentView(store: workspaceStore, themeStore: themeStore)
            .task {
                guard !didHandleInitialRequest else { return }
                didHandleInitialRequest = true

                if let workspaceURL = request.workspaceURL {
                    workspaceStore.openWorkspace(workspaceURL)
                } else if workspaceRestoration.claimInitialRestore() {
                    workspaceStore.restoreWorkspace()
                }
            }
    }
}

private struct WorkspaceWindowRequestInstaller: View {
    @Environment(\.openWindow) private var openWindow
    let requestCenter: WorkspaceWindowRequestCenter

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                requestCenter.installOpenWindowAction { request in
                    openWindow(
                        id: MarkprevWorkspaceWindowRequest.windowGroupID,
                        value: request
                    )
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let recentWorkspaceStore = RecentWorkspaceStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let recentWorkspaces = existingRecentWorkspaces()
        guard !recentWorkspaces.isEmpty else { return nil }

        let menu = NSMenu()
        for workspace in recentWorkspaces {
            let item = NSMenuItem(
                title: workspace.displayName,
                action: #selector(openRecentWorkspaceFromDockMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = workspace.path
            item.toolTip = workspace.path
            item.image = icon(forWorkspacePath: workspace.path)
            menu.addItem(item)
        }

        return menu
    }

    @objc private func openRecentWorkspaceFromDockMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }

        NSApp.activate(ignoringOtherApps: true)
        WorkspaceWindowRequestCenter.shared.openWorkspaceWindow(
            at: URL(fileURLWithPath: path, isDirectory: true)
        )
    }

    private func existingRecentWorkspaces() -> [RecentWorkspaceEntry] {
        recentWorkspaceStore.entries().filter { entry in
            var isDirectory = ObjCBool(false)
            return FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) &&
                isDirectory.boolValue
        }
    }

    private func icon(forWorkspacePath path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}
