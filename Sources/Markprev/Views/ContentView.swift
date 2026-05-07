import AppKit
import MarkprevCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var themeStore: ThemeSettingsStore
    @AppStorage("Markprev.editorMode") private var editorModeRawValue = EditorMode.preview.rawValue
    @AppStorage("Markprev.themePreference") private var themePreferenceRawValue = ThemePreference.system.rawValue
    @AppStorage("Markprev.zoomScale") private var zoomScale = 1.0
    @AppStorage("Markprev.previewWidthPercent") private var previewWidthPercent = 88.0
    @SceneStorage("Markprev.isTerminalDrawerOpen") private var isTerminalDrawerOpen = false
    @State private var pendingSourceLocation: MarkdownSourceLocation?
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.colorScheme) private var systemColorScheme

    private var editorMode: EditorMode {
        get { EditorMode(rawValue: editorModeRawValue) ?? .preview }
        nonmutating set { editorModeRawValue = newValue.rawValue }
    }

    private var themePreference: ThemePreference {
        get { ThemePreference(rawValue: themePreferenceRawValue) ?? .system }
        nonmutating set { themePreferenceRawValue = newValue.rawValue }
    }

    private var activeTheme: AppTheme {
        themeStore.activeTheme(
            themePreference: themePreference,
            systemAppearance: systemColorScheme == .dark ? .dark : .light
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView(
                store: store,
                theme: activeTheme,
                zoomScale: zoomScale,
                uiFontSize: activeTheme.uiFontSize,
                openFolder: openFolderPanel
            )
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 440)
        } detail: {
            EditorPaneView(
                store: store,
                editorMode: Binding(
                    get: { editorMode },
                    set: { editorMode = $0 }
                ),
                theme: activeTheme,
                zoomScale: zoomScale,
                codeFontSize: CGFloat(activeTheme.codeFontSize),
                previewWidthPercent: previewWidthPercent,
                isTerminalPresented: $isTerminalDrawerOpen,
                sourceLocation: $pendingSourceLocation,
                isSidebarVisible: sidebarVisibility != .detailOnly,
                toggleSidebar: toggleSidebar,
                newMarkdown: { store.createMarkdownFile() },
                openFolder: openFolderPanel,
                zoomOut: { adjustZoom(by: -0.1) },
                resetZoom: { zoomScale = 1.0 },
                zoomIn: { adjustZoom(by: 0.1) },
                toggleTerminal: toggleTerminalDrawer,
                onPreviewSourceJump: openSourceFromPreview(location:)
            )
        }
        .ignoresSafeArea(.container, edges: .top)
        .toolbar(removing: .sidebarToggle)
        .background(activeTheme.surfaceColor)
        .background(WindowBackgroundDragEnabler())
        .preferredColorScheme(themePreference.preferredColorScheme)
        .accentColor(activeTheme.accentColor)
        .navigationTitle(store.selectedFile?.displayName ?? "Markprev")
        .task {
            store.restoreWorkspace()
        }
        .focusedSceneValue(\.markprevCommandActions, commandActions)
        .alert("Markprev", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = "Open"
        panel.message = "Choose a folder containing Markdown files."

        if panel.runModal() == .OK, let url = panel.url {
            store.openWorkspace(url)
        }
    }

    private func adjustZoom(by delta: Double) {
        let stepped = ((zoomScale + delta) * 10).rounded() / 10
        zoomScale = min(1.8, max(0.7, stepped))
    }

    private func openSourceFromPreview(location: MarkdownSourceLocation) {
        pendingSourceLocation = location
        editorMode = .source
    }

    private var commandActions: MarkprevCommandActions {
        MarkprevCommandActions(
            newMarkdown: { store.createMarkdownFile() },
            openFolder: openFolderPanel,
            saveDocument: { store.saveSelectedFile() },
            refreshWorkspace: { store.refresh() },
            zoomIn: { adjustZoom(by: 0.1) },
            zoomOut: { adjustZoom(by: -0.1) },
            resetZoom: { zoomScale = 1.0 },
            toggleTerminal: { toggleTerminalDrawer() }
        )
    }

    private func toggleTerminalDrawer() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.08)) {
            isTerminalDrawerOpen.toggle()
        }
    }

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.22)) {
            sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
        }
    }
}
