import AppKit
import MarkprevCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var themeStore: ThemeSettingsStore
    @AppStorage("Markprev.editorMode") private var editorModeRawValue = EditorMode.preview.rawValue
    @AppStorage("Markprev.themePreference") private var themePreferenceRawValue = ThemePreference.system.rawValue
    @AppStorage("Markprev.zoomScale") private var zoomScale = 1.0
    @AppStorage("Markprev.previewWidthPercent") private var previewWidthPercent = 88.0
    @AppStorage("Markprev.usePointerCursors") private var usePointerCursors = false
    @AppStorage("Markprev.fontSmoothing") private var fontSmoothing = true
    @SceneStorage("Markprev.isTerminalDrawerOpen") private var isTerminalDrawerOpen = false
    @State private var pendingSourceLocation: MarkdownSourceLocation?
    @State private var documentSearch = DocumentSearchState()
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var exportNotice: String?
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
                openFolder: openFolderPanel,
                exportPDF: exportMarkdownPDF(_:)
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
                usePointerCursors: usePointerCursors,
                fontSmoothing: fontSmoothing,
                isTerminalPresented: $isTerminalDrawerOpen,
                sourceLocation: $pendingSourceLocation,
                documentSearch: $documentSearch,
                isSidebarVisible: sidebarVisibility != .detailOnly,
                newMarkdown: { store.createMarkdownFile() },
                openFolder: openFolderPanel,
                zoomOut: { adjustZoom(by: -0.1) },
                resetZoom: { zoomScale = 1.0 },
                zoomIn: { adjustZoom(by: 0.1) },
                toggleTerminal: toggleTerminalDrawer,
                toggleSidebar: toggleSidebar,
                onPreviewSourceJump: openSourceFromPreview(location:)
            )
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(activeTheme.surfaceColor)
        .background(WindowBackgroundDragEnabler(
            surfaceColor: activeTheme.surfaceColor,
            layoutToken: nativeChromeLayoutToken,
            toolbarButtonSize: nativeToolbarButtonSize
        ))
        .background(KeyboardShortcutMonitor(handler: handleKeyDown))
        .preferredColorScheme(themePreference.preferredColorScheme)
        .accentColor(activeTheme.accentColor)
        .task {
            store.restoreWorkspace()
        }
        .onChange(of: store.selectedDocument?.id) { _, _ in
            documentSearch.updateResult(.init())
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
        .alert("Export Complete", isPresented: Binding(
            get: { exportNotice != nil },
            set: { if !$0 { exportNotice = nil } }
        )) {
            Button("OK", role: .cancel) {
                exportNotice = nil
            }
        } message: {
            Text(exportNotice ?? "")
        }
    }

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = "Open"
        panel.message = "Choose a folder containing Markdown or PDF documents."

        if panel.runModal() == .OK, let url = panel.url {
            store.openWorkspace(url)
        }
    }

    private func exportMarkdownPDF(_ document: WorkspaceDocument) {
        Task { @MainActor in
            guard let destinationURL = pdfExportDestination(for: document) else {
                return
            }

            do {
                let markdown = try await store.markdownTextForExport(document)
                let exporter = try MarkdownPDFExportService.makeDefault()
                try await exporter.exportPDF(for: MarkdownPDFExportRequest(
                    markdown: markdown,
                    baseURL: store.workspaceURL,
                    theme: activeTheme,
                    zoomScale: zoomScale,
                    codeFontSize: activeTheme.codeFontSize,
                    previewWidthPercent: previewWidthPercent,
                    usePointerCursors: usePointerCursors,
                    fontSmoothing: fontSmoothing
                ), to: destinationURL)

                if isInsideWorkspace(destinationURL) {
                    store.refresh()
                }

                exportNotice = "Saved \(destinationURL.lastPathComponent)."
            } catch {
                store.errorMessage = "Could not export \(document.displayName) as PDF: \(error.localizedDescription)"
            }
        }
    }

    private func pdfExportDestination(for document: WorkspaceDocument) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = document.url.deletingLastPathComponent()
        panel.nameFieldStringValue = document.url.deletingPathExtension().lastPathComponent + ".pdf"
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Export"
        panel.message = "Export the rendered Markdown document as a PDF."

        return panel.runModal() == .OK ? panel.url : nil
    }

    private func isInsideWorkspace(_ url: URL) -> Bool {
        guard let workspaceURL = store.workspaceURL?.standardizedFileURL else {
            return false
        }

        let workspacePath = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(workspacePath)
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
            showFind: { showDocumentSearch() },
            findNext: { documentSearch.findNext() },
            findPrevious: { documentSearch.findPrevious() },
            toggleTerminal: { toggleTerminalDrawer() },
            toggleSidebar: { toggleSidebar() }
        )
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }

        let flags = event.modifierFlags.independentFlags
        let commandFind = characters == "f" && flags.contains(.command)
        let controlFind = characters == "f" && flags.contains(.control)
        if commandFind || controlFind {
            guard store.selectedDocument != nil else { return false }
            showDocumentSearch()
            return true
        }

        if characters == "g", flags.contains(.command) {
            if flags.contains(.shift) {
                documentSearch.findPrevious()
            } else {
                documentSearch.findNext()
            }
            return true
        }

        if event.keyCode == 53, documentSearch.isPresented {
            documentSearch.dismiss()
            return true
        }

        return false
    }

    private func showDocumentSearch() {
        guard store.selectedDocument != nil else { return }
        documentSearch.present()
    }

    private func toggleTerminalDrawer() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.08)) {
            isTerminalDrawerOpen.toggle()
        }
    }

    private var nativeChromeLayoutToken: String {
        "\(themePreference.rawValue)-\(systemColorScheme == .dark ? "dark" : "light")-\(sidebarVisibility == .detailOnly ? "detailOnly" : "all")"
    }

    private var nativeToolbarButtonSize: CGSize {
        let scale = max(zoomScale * activeTheme.uiFontSize / 16, 0.75)
        return CGSize(width: 28 * scale, height: 26 * scale)
    }

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.22)) {
            sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
        }
    }
}
