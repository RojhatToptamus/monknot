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
    @StateObject private var workspaceSearch = WorkspaceSearchState()
    @StateObject private var outlineStore = MarkdownOutlineStore()
    @State private var pendingSourceLocation: MarkdownSourceLocation?
    @State private var pendingPreviewLocation: MarkdownSourceLocation?
    @State private var pendingPDFSearchTarget: WorkspaceSearchPDFTarget?
    @State private var deferredWorkspaceSourceJump: DeferredWorkspaceSourceJump?
    @State private var tabState = WorkspaceTabState()
    @State private var documentSearch = DocumentSearchState()
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var exportNotice: String?
    @State private var pendingPDFExportDocument: WorkspaceDocument?
    @State private var pdfExportOptions = MarkdownPDFExportOptions.loadLastUsed()
    @State private var isExportingPDF = false
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
        configuredContent
    }

    private var configuredContent: AnyView {
        AnyView(alertContent)
    }

    private var chromeContent: AnyView {
        AnyView(rootContent
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
        )
    }

    private var lifecycleContent: AnyView {
        AnyView(chromeContent
            .task {
                store.restoreWorkspace()
            }
            .onChange(of: store.selectedDocument?.id) { _, _ in
                reconcileTabsWithStore()
                documentSearch.updateResult(.init())
                workspaceSearch.refresh(documents: store.documents)
                updateOutline()
                fulfillDeferredWorkspaceSourceJump()
            }
            .onChange(of: store.documentText) { _, _ in
                updateOutline()
                fulfillDeferredWorkspaceSourceJump()
            }
            .onChange(of: store.isDocumentLoading) { _, _ in
                fulfillDeferredWorkspaceSourceJump()
            }
            .onChange(of: store.documents) { _, documents in
                workspaceSearch.refresh(documents: documents)
                reconcileTabsWithStore()
            }
            .onChange(of: store.workspaceURL?.standardizedFileURL.path ?? "") { _, _ in
                tabState.reset()
                publishOpenTabIDs()
            }
            .onChange(of: store.removedDirtyOpenDocumentIDs) { _, _ in
                reconcileTabsWithStore()
            }
            .onChange(of: store.documentIDRemapEvent?.serial ?? 0) { _, _ in
                applyDocumentIDRemapEvent()
            }
            .focusedSceneValue(\.markprevCommandActions, commandActions)
        )
    }

    private var alertContent: AnyView {
        AnyView(lifecycleContent
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
            .sheet(item: $pendingPDFExportDocument) { document in
                MarkdownPDFExportOptionsSheet(
                    document: document,
                    theme: activeTheme,
                    options: $pdfExportOptions,
                    isExporting: isExportingPDF,
                    cancel: {
                        guard !isExportingPDF else { return }
                        pendingPDFExportDocument = nil
                    },
                    export: {
                        performMarkdownPDFExport(document, options: pdfExportOptions)
                    }
                )
            }
        )
    }

    private var rootContent: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            sidebarContent
        } detail: {
            detailContent
        }
    }

    private var sidebarContent: some View {
        SidebarView(
            store: store,
            workspaceSearch: workspaceSearch,
            theme: activeTheme,
            zoomScale: zoomScale,
            uiFontSize: activeTheme.uiFontSize,
            openFolder: openFolderPanel,
            exportPDF: exportMarkdownPDF(_:),
            openDocument: openDocumentTab(id:),
            openWorkspaceSearchResult: openWorkspaceSearchResult(_:)
        )
        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 440)
    }

    private var detailContent: some View {
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
            tabs: tabState.tabs,
            activeTabID: tabState.selectedDocumentID,
            missingTabIDs: store.removedDirtyOpenDocumentIDs,
            selectTab: activateTab(id:),
            closeTab: closeTab(id:),
            togglePinTab: togglePinTab(id:),
            reorderTab: reorderTab(draggedID:targetID:),
            isTerminalPresented: $isTerminalDrawerOpen,
            sourceLocation: $pendingSourceLocation,
            previewLocation: $pendingPreviewLocation,
            pdfSearchTarget: $pendingPDFSearchTarget,
            documentSearch: $documentSearch,
            isSidebarVisible: sidebarVisibility != .detailOnly,
            newMarkdown: { store.createMarkdownFile() },
            openFolder: openFolderPanel,
            toggleTerminal: toggleTerminalDrawer,
            toggleSidebar: toggleSidebar,
            outlineItems: outlineStore.items,
            selectOutlineItem: openOutlineItem(_:),
            onPreviewSourceJump: openSourceFromPreview(location:)
        )
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
        pendingPDFExportDocument = document
    }

    private func exportSelectedMarkdownPDF() {
        guard let document = store.selectedDocument, document.kind == .markdown else {
            return
        }

        exportMarkdownPDF(document)
    }

    private func performMarkdownPDFExport(_ document: WorkspaceDocument, options: MarkdownPDFExportOptions) {
        Task { @MainActor in
            isExportingPDF = true
            defer {
                isExportingPDF = false
            }

            guard let destinationURL = pdfExportDestination(for: document) else {
                pendingPDFExportDocument = nil
                return
            }

            do {
                pdfExportOptions = options
                options.saveLastUsed()
                let exportTheme = pdfExportTheme(for: options)
                let markdown = try await store.markdownTextForExport(document)
                let exporter = try MarkdownPDFExportService.makeDefault()
                try await exporter.exportPDF(for: MarkdownPDFExportRequest(
                    markdown: markdown,
                    baseURL: store.workspaceURL,
                    theme: exportTheme,
                    zoomScale: options.resolvedScale,
                    codeFontSize: exportTheme.codeFontSize,
                    previewWidthPercent: previewWidthPercent,
                    usePointerCursors: usePointerCursors,
                    fontSmoothing: fontSmoothing,
                    options: options
                ), to: destinationURL)

                if isInsideWorkspace(destinationURL) {
                    store.refresh()
                }

                exportNotice = "Saved \(destinationURL.lastPathComponent)."
                pendingPDFExportDocument = nil
            } catch {
                store.errorMessage = "Could not export \(document.displayName) as PDF: \(error.localizedDescription)"
            }
        }
    }

    private func pdfExportTheme(for options: MarkdownPDFExportOptions) -> AppTheme {
        switch options.themeMode {
        case .current:
            return activeTheme
        case .light:
            return themeStore.effectiveTheme(for: .light)
        case .dark:
            return themeStore.effectiveTheme(for: .dark)
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

    private func openDocumentTab(id documentID: String) {
        guard !store.isBusy, let document = store.document(id: documentID) else { return }
        guard store.selectDocument(id: documentID) else { return }
        tabState.open(document)
        publishOpenTabIDs()
    }

    private func activateTab(id documentID: String) {
        guard !store.isBusy else { return }
        guard tabState.contains(documentID: documentID) else { return }
        guard store.selectDocument(id: documentID) else { return }

        if let document = store.document(id: documentID) {
            tabState.open(document)
        } else {
            tabState.activate(documentID: documentID)
        }
        publishOpenTabIDs()
    }

    private func closeTab(id documentID: String) {
        guard !store.isBusy else { return }
        let wasActive = tabState.selectedDocumentID == documentID
        let nextDocumentID = tabState.close(documentID: documentID)
        publishOpenTabIDs()

        if wasActive || store.selectedDocumentID == documentID {
            _ = store.selectDocument(id: nextDocumentID)
        }
    }

    private func closeActiveTab() {
        guard let selectedDocumentID = tabState.selectedDocumentID else { return }
        closeTab(id: selectedDocumentID)
    }

    private func togglePinTab(id documentID: String) {
        tabState.togglePin(documentID: documentID)
    }

    private func toggleActiveTabPin() {
        guard let selectedDocumentID = tabState.selectedDocumentID else { return }
        togglePinTab(id: selectedDocumentID)
    }

    private func reorderTab(draggedID: String, targetID: String?) {
        guard !store.isBusy else { return }
        tabState.moveTab(documentID: draggedID, before: targetID)
    }

    private func reconcileTabsWithStore() {
        guard !store.isBusy else { return }

        let availableDocumentIDs = Set(store.documents.map(\.id))
        tabState.updateSnapshots(from: store.documents)
        tabState.pruneUnavailableDocuments(
            availableDocumentIDs: availableDocumentIDs,
            preserving: store.removedDirtyOpenDocumentIDs
        )

        if let selectedDocument = store.selectedDocument {
            if tabState.contains(documentID: selectedDocument.id) {
                tabState.open(selectedDocument)
            } else if !tabState.isEmptyByUserChoice {
                tabState.open(selectedDocument)
            }
        } else if store.selectedDocumentID == nil, tabState.tabs.isEmpty {
            tabState.activate(documentID: nil)
        }

        publishOpenTabIDs()

        if tabState.selectedDocumentID != store.selectedDocumentID {
            _ = store.selectDocument(id: tabState.selectedDocumentID)
        }
    }

    private func applyDocumentIDRemapEvent() {
        guard let event = store.documentIDRemapEvent else { return }
        tabState.remapDocumentID(
            sourceID: event.sourceID,
            destinationID: event.destinationID,
            document: store.document(id: event.destinationID)
        )
        publishOpenTabIDs()
    }

    private func publishOpenTabIDs() {
        store.setOpenDocumentIDs(tabState.openDocumentIDs)
    }

    private func openSourceFromPreview(location: MarkdownSourceLocation) {
        pendingSourceLocation = location
        editorMode = .source
    }

    private var commandActions: MarkprevCommandActions {
        MarkprevCommandActions(
            newMarkdown: { store.createMarkdownFile() },
            openFolder: openFolderPanel,
            exportPDF: { exportSelectedMarkdownPDF() },
            canExportPDF: store.selectedDocument?.kind == .markdown,
            saveDocument: { store.saveSelectedFile() },
            refreshWorkspace: { store.refresh() },
            closeTab: { closeActiveTab() },
            canCloseTab: tabState.selectedDocumentID != nil && !store.isBusy,
            togglePinTab: { toggleActiveTabPin() },
            canTogglePinTab: tabState.selectedDocumentID != nil && !store.isBusy,
            zoomIn: { adjustZoom(by: 0.1) },
            zoomOut: { adjustZoom(by: -0.1) },
            resetZoom: { zoomScale = 1.0 },
            showFind: { showDocumentSearch() },
            showWorkspaceSearch: { showWorkspaceSearch() },
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
        let isCommandOnly = flags.contains(.command) &&
            !flags.contains(.shift) &&
            !flags.contains(.option) &&
            !flags.contains(.control)

        if characters == "w", isCommandOnly, tabState.selectedDocumentID != nil {
            closeActiveTab()
            return true
        }

        if characters == "f", flags.contains(.command), flags.contains(.shift) {
            showWorkspaceSearch()
            return true
        }

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

    private func showWorkspaceSearch() {
        guard store.workspaceURL != nil else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            sidebarVisibility = .all
        }
        workspaceSearch.present(documents: store.documents)
    }

    private func openWorkspaceSearchResult(_ result: WorkspaceSearchResult) {
        let query = workspaceSearch.query
        workspaceSearch.dismiss()
        documentSearch.present()
        documentSearch.setQuery(query)

        if result.kind == .text {
            editorMode = .source
        }

        openDocumentTab(id: result.documentID)
        if result.kind == .text {
            deferredWorkspaceSourceJump = DeferredWorkspaceSourceJump(
                documentID: result.documentID,
                location: MarkdownSourceLocation(line: result.line, offset: result.column)
            )
            fulfillDeferredWorkspaceSourceJump()
        } else if result.kind == .pdf {
            pendingPDFSearchTarget = result.pdfTarget
        }
    }

    private func fulfillDeferredWorkspaceSourceJump() {
        guard let deferredWorkspaceSourceJump else { return }
        guard store.selectedDocumentID == deferredWorkspaceSourceJump.documentID else { return }
        guard !store.isDocumentLoading else { return }

        pendingSourceLocation = deferredWorkspaceSourceJump.location
        self.deferredWorkspaceSourceJump = nil
    }

    private func openOutlineItem(_ item: MarkdownOutlineItem) {
        if editorMode == .preview {
            pendingPreviewLocation = item.location
        } else {
            editorMode = .source
            pendingSourceLocation = item.location
        }
    }

    private func updateOutline() {
        outlineStore.update(
            markdown: store.documentText,
            isMarkdown: store.selectedDocument?.kind == .markdown
        )
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

private struct DeferredWorkspaceSourceJump: Equatable {
    let documentID: String
    let location: MarkdownSourceLocation
}
