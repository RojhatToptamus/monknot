import AppKit
import Combine
import MonknotCore
import Sparkle
import SwiftUI

#if !SWIFT_PACKAGE
@main
#endif
@MainActor
struct MonknotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspaceRestoration = InitialWorkspaceRestorationCoordinator()
    @StateObject private var themeStore = ThemeSettingsStore()
    private let workspaceWindowRequests = WorkspaceWindowRequestCenter.shared
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup(
            "Monknot",
            id: MonknotWorkspaceWindowRequest.windowGroupID,
            for: MonknotWorkspaceWindowRequest.self
        ) { request in
            MonknotWindowRootView(
                request: request.wrappedValue,
                themeStore: themeStore,
                workspaceRestoration: workspaceRestoration,
                workspaceWindowRequests: workspaceWindowRequests,
                terminationCoordinator: appDelegate.terminationCoordinator
            )
                .background(WorkspaceWindowRequestInstaller(requestCenter: workspaceWindowRequests))
                .frame(minWidth: 920, minHeight: 620)
        } defaultValue: {
            MonknotWorkspaceWindowRequest()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            MonknotCommandMenu()
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        Settings {
            PreferencesView(
                themeStore: themeStore,
                updater: updaterController.updater
            )
        }
        .windowStyle(.titleBar)
        .defaultSize(
            width: MonknotMetrics.settingsWindowWidth,
            height: MonknotMetrics.settingsWindowContentHeight
        )
        .windowResizability(.contentSize)
    }
}

@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

private struct CheckForUpdatesView: View {
    @StateObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    @MainActor
    init(updater: SPUUpdater) {
        self.updater = updater
        _viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}

private struct MonknotWindowRootView: View {
    @StateObject private var workspaceStore = WorkspaceStore()
    let request: MonknotWorkspaceWindowRequest
    @ObservedObject var themeStore: ThemeSettingsStore
    @ObservedObject var workspaceRestoration: InitialWorkspaceRestorationCoordinator
    let workspaceWindowRequests: WorkspaceWindowRequestCenter
    let terminationCoordinator: ApplicationTerminationCoordinator
    @AppStorage("Monknot.reopenLastWorkspace") private var reopenLastWorkspace = true
    @State private var didHandleInitialRequest = false
    @State private var reusableWindowHandlerID = UUID()

    var body: some View {
        ContentView(
            store: workspaceStore,
            themeStore: themeStore,
            terminationCoordinator: terminationCoordinator
        )
            .onAppear {
                workspaceWindowRequests.installReusableWindowHandler(id: reusableWindowHandlerID) { request in
                    guard workspaceStore.workspaceURL == nil,
                          !workspaceStore.isBusy,
                          let workspaceURL = request.workspaceURL
                    else {
                        return false
                    }

                    workspaceStore.openWorkspace(workspaceURL, selecting: request.selectedDocumentURL)
                    Task { @MainActor in
                        await importCaptureIfNeeded(from: request)
                    }
                    return true
                }
            }
            .onDisappear {
                workspaceWindowRequests.removeReusableWindowHandler(id: reusableWindowHandlerID)
            }
            .task {
                guard !didHandleInitialRequest else { return }
                didHandleInitialRequest = true

                if let workspaceURL = request.workspaceURL {
                    workspaceStore.openWorkspace(workspaceURL, selecting: request.selectedDocumentURL)
                    await importCaptureIfNeeded(from: request)
                } else if let pendingRequest = workspaceWindowRequests.consumePendingInitialWorkspaceRequest(),
                          let workspaceURL = pendingRequest.workspaceURL {
                    workspaceStore.openWorkspace(workspaceURL, selecting: pendingRequest.selectedDocumentURL)
                    await importCaptureIfNeeded(from: pendingRequest)
                } else if reopenLastWorkspace, workspaceRestoration.claimInitialRestore() {
                    workspaceStore.restoreWorkspace()
                }

                workspaceWindowRequests.finishInitialWorkspaceRequestHandling()
            }
    }

    private func importCaptureIfNeeded(from request: MonknotWorkspaceWindowRequest) async {
        guard let item = request.captureItem else { return }
        guard await waitForWorkspaceReady(request.workspaceURL) else { return }
        workspaceStore.importPasteboardItems([item])
    }

    private func waitForWorkspaceReady(_ workspaceURL: URL?) async -> Bool {
        let expectedPath = workspaceURL?.standardizedFileURL.path
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !workspaceStore.isBusy,
               let currentPath = workspaceStore.workspaceURL?.standardizedFileURL.path,
               expectedPath == nil || currentPath == expectedPath {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
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
                        id: MonknotWorkspaceWindowRequest.windowGroupID,
                        value: request
                    )
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let recentWorkspaceStore = RecentWorkspaceStore()
    let terminationCoordinator = ApplicationTerminationCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openLaunchCaptureIfPresent()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationCoordinator.applicationShouldTerminate(sender)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openCaptureURLsIfPresent(urls)
        openWorkspaceItems(at: urls.filter(\.isFileURL))
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openWorkspaceItems(at: [URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openWorkspaceItems(at: filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
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

    private func openWorkspaceItems(at urls: [URL]) {
        let requests = urls.compactMap(Self.workspaceRequest(for:))
        guard !requests.isEmpty else { return }

        NSApp.activate(ignoringOtherApps: true)
        for request in requests {
            guard let workspaceURL = request.workspaceURL else { continue }
            WorkspaceWindowRequestCenter.shared.openWorkspaceWindow(
                at: workspaceURL,
                selecting: request.selectedDocumentURL
            )
        }
    }

    private func openCaptureURLsIfPresent(_ urls: [URL]) {
        let requests = urls.compactMap(MonknotLaunchCaptureParser.request(url:))
        guard !requests.isEmpty else { return }

        NSApp.activate(ignoringOtherApps: true)
        for request in requests where confirmCapture(request) {
            WorkspaceWindowRequestCenter.shared.openWorkspaceWindow(MonknotWorkspaceWindowRequest(
                workspaceURL: request.workspaceURL,
                captureItem: request.item
            ))
        }
    }

    private func openLaunchCaptureIfPresent(arguments: [String] = CommandLine.arguments) {
        guard let request = MonknotLaunchCaptureParser.request(arguments: arguments) else { return }
        guard confirmCapture(request) else { return }
        NSApp.activate(ignoringOtherApps: true)
        WorkspaceWindowRequestCenter.shared.openWorkspaceWindow(MonknotWorkspaceWindowRequest(
            workspaceURL: request.workspaceURL,
            captureItem: request.item
        ))
    }

    private func confirmCapture(_ request: MonknotLaunchCaptureRequest) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Save this capture to Monknot?"
        alert.informativeText = """
        Another app or link requested permission to add a new note to:
        \(request.workspaceURL.path)/inbox
        """
        alert.addButton(withTitle: "Save Capture")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func workspaceRequest(for url: URL) -> MonknotWorkspaceWindowRequest? {
        guard url.isFileURL else { return nil }

        let standardizedURL = url.standardizedFileURL
        guard let resourceValues = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
            return nil
        }

        if resourceValues.isDirectory == true {
            return MonknotWorkspaceWindowRequest(workspaceURL: standardizedURL)
        }

        if resourceValues.isRegularFile == true {
            return MonknotWorkspaceWindowRequest(
                workspaceURL: standardizedURL.deletingLastPathComponent(),
                selectedDocumentURL: standardizedURL
            )
        }

        return nil
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
