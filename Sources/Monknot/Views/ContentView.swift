import AppKit
import MonknotCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var themeStore: ThemeSettingsStore
    @AppStorage("Monknot.editorMode") private var editorModeRawValue = EditorMode.preview.rawValue
    @AppStorage("Monknot.themePreference") private var themePreferenceRawValue = ThemePreference.system.rawValue
    @AppStorage("Monknot.zoomScale") private var zoomScale = 1.0
    @AppStorage("Monknot.previewWidthPercent") private var previewWidthPercent = 88.0
    @AppStorage("Monknot.usePointerCursors") private var usePointerCursors = false
    @AppStorage("Monknot.fontSmoothing") private var fontSmoothing = true
    @SceneStorage("Monknot.isTerminalDrawerOpen") private var isTerminalDrawerOpen = false
    @StateObject private var workspaceSearch = WorkspaceSearchState()
    @StateObject private var outlineStore = MarkdownOutlineStore()
    @State private var pendingSourceLocation: MarkdownSourceLocation?
    @State private var pendingPreviewLocation: MarkdownSourceLocation?
    @State private var pendingPDFSearchTarget: WorkspaceSearchPDFTarget?
    @State private var deferredWorkspaceSourceJump: DeferredWorkspaceSourceJump?
    @State private var tabState = WorkspaceTabState()
    @State private var restoredTabStateWorkspacePath: String?
    @State private var documentViewportStates: [String: DocumentViewportState] = [:]
    @State private var pdfUndoCommandSerial = 0
    @State private var pdfRedoCommandSerial = 0
    @State private var canUndoPDFAnnotation = false
    @State private var canRedoPDFAnnotation = false
    @State private var documentSearch = DocumentSearchState()
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var exportNotice: String?
    @State private var pendingPDFExportDocument: WorkspaceDocument?
    @State private var pdfExportOptions = MarkdownPDFExportOptions.loadLastUsed()
    @State private var isExportingPDF = false
    @State private var isResolvingUnsavedChanges = false
    @Environment(\.colorScheme) private var systemColorScheme
    private let tabStatePersistence = WorkspaceTabStatePersistence()

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
                usesDarkAppearance: activeTheme.isDark
            ))
            .background(WindowCloseGuard(
                shouldClose: { await resolveAllOpenUnsavedChanges() }
            ))
            .background(KeyboardShortcutMonitor(handler: handleKeyDown))
            .toolbar {
                // Keep the unified title-bar zone in step with our SwiftUI
                // chrome height without manually moving the traffic lights.
                ToolbarItem(placement: .principal) {
                    Color.clear
                        .frame(width: 0, height: nativeChromeHeight)
                        .accessibilityHidden(true)
                }
            }
            .preferredColorScheme(themePreference.preferredColorScheme)
            .accentColor(activeTheme.accentColor)
        )
    }

    private var lifecycleContent: AnyView {
        AnyView(chromeContent
            .onChange(of: store.selectedDocument?.id) { _, _ in
                resetPDFAnnotationShortcutState()
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
                restoredTabStateWorkspacePath = nil
                documentViewportStates.removeAll()
                publishOpenTabIDs(persistTabs: false)
            }
            .onChange(of: store.removedDirtyOpenDocumentIDs) { _, _ in
                reconcileTabsWithStore()
            }
            .onChange(of: store.documentIDRemapEvent?.serial ?? 0) { _, _ in
                applyDocumentIDRemapEvent()
            }
            .focusedSceneValue(\.monknotCommandActions, commandActions)
        )
    }

    private var alertContent: AnyView {
        AnyView(lifecycleContent
            .alert("monknot", isPresented: Binding(
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
            newMarkdown: { store.createMarkdownFile() },
            exportPDF: exportMarkdownPDF(_:),
            openDocument: openDocumentTab(id:),
            openWorkspaceSearchResult: openWorkspaceSearchResult(_:)
        )
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 440)
        .monknotStableNavigationChrome()
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
            activeViewportState: activeDocumentViewportState,
            missingTabIDs: store.removedDirtyOpenDocumentIDs,
            selectTab: activateTab(id:),
            closeTab: closeTab(id:),
            togglePinTab: togglePinTab(id:),
            reorderTab: reorderTab(draggedID:targetID:),
            updateViewportState: updateDocumentViewportState(documentID:change:),
            pdfUndoCommandSerial: pdfUndoCommandSerial,
            pdfRedoCommandSerial: pdfRedoCommandSerial,
            updatePDFAnnotationUndoState: updatePDFAnnotationShortcutState(canUndo:canRedo:),
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
            Task { @MainActor in
                guard await resolveAllOpenUnsavedChanges() else { return }
                store.openWorkspace(url)
            }
        }
    }

    private enum UnsavedChangesResolution {
        case save
        case discard
        case cancel
    }

    private func presentUnsavedChangesAlert(for document: WorkspaceDocument) -> UnsavedChangesResolution {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save the changes you made to \(document.displayName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }

    private func resolveUnsavedChangesIfNeeded(for documentID: String) async -> Bool {
        guard !store.saveState(for: documentID).isClean else { return true }
        guard let document = store.document(id: documentID) else { return true }

        switch presentUnsavedChangesAlert(for: document) {
        case .save:
            return await store.saveDocument(id: documentID)
        case .discard:
            store.discardUnsavedChanges(for: documentID)
            return true
        case .cancel:
            return false
        }
    }

    private func resolveAllOpenUnsavedChanges() async -> Bool {
        guard !isResolvingUnsavedChanges else { return false }
        isResolvingUnsavedChanges = true
        defer { isResolvingUnsavedChanges = false }

        for documentID in tabState.tabs.map(\.documentID) where !store.saveState(for: documentID).isClean {
            guard await resolveUnsavedChangesIfNeeded(for: documentID) else {
                return false
            }
        }

        return true
    }

    private func exportMarkdownPDF(_ document: WorkspaceDocument) {
        pendingPDFExportDocument = document
    }

    private func exportSelectedMarkdownPDF() {
        guard let document = store.selectedDocument, document.capabilities.canExportPDF else {
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
                    baseURL: document.url.deletingLastPathComponent(),
                    theme: exportTheme,
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
        zoomScale = min(3.0, max(0.7, stepped))
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
        guard !store.isBusy, !isResolvingUnsavedChanges else { return }

        Task { @MainActor in
            isResolvingUnsavedChanges = true
            defer { isResolvingUnsavedChanges = false }

            guard await resolveUnsavedChangesIfNeeded(for: documentID) else { return }
            closeResolvedTab(id: documentID)
        }
    }

    private func closeResolvedTab(id documentID: String) {
        let wasActive = tabState.selectedDocumentID == documentID
        let nextDocumentID = tabState.close(documentID: documentID)
        documentViewportStates.removeValue(forKey: documentID)
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
        persistTabState()
    }

    private func toggleActiveTabPin() {
        guard let selectedDocumentID = tabState.selectedDocumentID else { return }
        togglePinTab(id: selectedDocumentID)
    }

    private func reorderTab(draggedID: String, targetID: String?) {
        guard !store.isBusy else { return }
        tabState.moveTab(documentID: draggedID, before: targetID)
        persistTabState()
    }

    private func reconcileTabsWithStore() {
        guard !store.isBusy else { return }
        if restorePersistedTabsIfNeeded() {
            return
        }

        let availableDocumentIDs = Set(store.documents.map(\.id))
        tabState.updateSnapshots(from: store.documents)
        tabState.pruneUnavailableDocuments(
            availableDocumentIDs: availableDocumentIDs,
            preserving: store.removedDirtyOpenDocumentIDs
        )
        pruneDocumentViewportStates()

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
        for mapping in event.mappings {
            tabState.remapDocumentID(
                sourceID: mapping.sourceID,
                destinationID: mapping.destinationID,
                document: store.document(id: mapping.destinationID)
            )
            if let viewportState = documentViewportStates.removeValue(forKey: mapping.sourceID) {
                documentViewportStates[mapping.destinationID] = viewportState
            }
        }
        publishOpenTabIDs()
    }

    @discardableResult
    private func restorePersistedTabsIfNeeded() -> Bool {
        guard let workspaceURL = store.workspaceURL?.standardizedFileURL else { return false }
        let workspacePath = workspaceURL.path
        guard restoredTabStateWorkspacePath != workspacePath else { return false }
        restoredTabStateWorkspacePath = workspacePath

        guard var restoredState = tabStatePersistence.load(for: workspaceURL) else {
            return false
        }

        restoredState.updateSnapshots(from: store.documents)
        restoredState.pruneUnavailableDocuments(
            availableDocumentIDs: Set(store.documents.map(\.id)),
            preserving: store.removedDirtyOpenDocumentIDs
        )

        guard !restoredState.tabs.isEmpty || restoredState.isEmptyByUserChoice else {
            return false
        }

        tabState = restoredState
        pruneDocumentViewportStates()
        publishOpenTabIDs()

        if tabState.selectedDocumentID != store.selectedDocumentID {
            _ = store.selectDocument(id: tabState.selectedDocumentID)
        }

        return true
    }

    private func publishOpenTabIDs(persistTabs: Bool = true) {
        store.setOpenDocumentIDs(tabState.openDocumentIDs)
        if persistTabs {
            persistTabState()
        }
    }

    private func persistTabState() {
        guard let workspaceURL = store.workspaceURL?.standardizedFileURL else { return }
        tabStatePersistence.save(tabState, for: workspaceURL)
    }

    private var activeDocumentViewportState: DocumentViewportState? {
        guard let selectedDocumentID = tabState.selectedDocumentID else { return nil }
        return documentViewportStates[selectedDocumentID]
    }

    private func updateDocumentViewportState(documentID: String, change: DocumentViewportStateChange) {
        var state = documentViewportStates[documentID] ?? DocumentViewportState()

        switch change {
        case .textScrollPosition(let position):
            guard position.isMeaningfullyDifferent(from: state.textScrollPosition) else { return }
            state.textScrollPosition = position
        case .markdownPreviewScrollPosition(let position):
            guard position.isMeaningfullyDifferent(from: state.markdownPreviewScrollPosition) else { return }
            state.markdownPreviewScrollPosition = position
        case .htmlPreviewScrollPosition(let position):
            guard position.isMeaningfullyDifferent(from: state.htmlPreviewScrollPosition) else { return }
            state.htmlPreviewScrollPosition = position
        case .pdfPosition(let position):
            guard position != state.pdfPosition else { return }
            state.pdfPosition = position
        }

        documentViewportStates[documentID] = state
    }

    private func pruneDocumentViewportStates() {
        let retainedDocumentIDs = tabState.openDocumentIDs
            .union(store.removedDirtyOpenDocumentIDs)
            .union(store.selectedDocumentID.map { [$0] } ?? [])
        documentViewportStates = documentViewportStates.filter { retainedDocumentIDs.contains($0.key) }
    }

    private func openSourceFromPreview(location: MarkdownSourceLocation) {
        pendingSourceLocation = location
        editorMode = .source
    }

    private var commandActions: MonknotCommandActions {
        MonknotCommandActions(
            newMarkdown: { store.createMarkdownFile() },
            openFolder: openFolderPanel,
            exportPDF: { exportSelectedMarkdownPDF() },
            canExportPDF: store.selectedDocument?.capabilities.canExportPDF == true,
            saveDocument: { store.saveSelectedFile() },
            cut: { _ = cutFromCommand() },
            copy: { _ = copyFromCommand() },
            paste: { _ = pasteFromCommand() },
            selectAll: { _ = MonknotNativePasteboardCommand.performSelectAllIfAvailable() },
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
        guard let shortcutEvent = event.monknotKeyboardShortcutEvent,
              let action = MonknotKeyboardShortcutRouter.action(
                for: shortcutEvent,
                context: keyboardShortcutContext
              )
        else {
            return false
        }

        if action == .importPasteboard {
            return pasteFromCommand()
        }

        if action == .cutDocument {
            return cutFromCommand()
        }

        if action == .copyDocument {
            return copyFromCommand()
        }

        performKeyboardShortcutAction(action)
        return true
    }

    private func cutFromCommand() -> Bool {
        if MonknotNativePasteboardCommand.performCutIfAvailable() {
            return true
        }

        if MonknotNativePasteboardCommand.hasNativeEditingFocus {
            return true
        }

        return cutSelectedDocumentFromCommand()
    }

    private func copyFromCommand() -> Bool {
        if MonknotNativePasteboardCommand.performCopyIfAvailable() {
            return true
        }

        if MonknotNativePasteboardCommand.hasNativeEditingFocus {
            return true
        }

        return copySelectedDocumentFromCommand()
    }

    private func pasteFromCommand() -> Bool {
        if MonknotNativePasteboardCommand.performPasteIfAvailable() {
            return true
        }

        if MonknotNativePasteboardCommand.hasNativeEditingFocus {
            return true
        }

        if WorkspacePasteboardExportService.ownsPasteboard(), store.canPasteDocumentTransfer {
            store.pasteDocumentTransfer()
            return true
        }

        return importPasteboardFromCommand()
    }

    private func copySelectedDocumentFromCommand() -> Bool {
        guard let document = store.selectedDocument, !store.isBusy else { return false }
        do {
            try WorkspacePasteboardExportService.copyFile(at: document.url)
            store.copyDocument(document)
        } catch {
            store.errorMessage = "Could not copy \(document.displayName): \(error.localizedDescription)"
        }
        return true
    }

    private func cutSelectedDocumentFromCommand() -> Bool {
        guard let document = store.selectedDocument, !store.isBusy else { return false }
        WorkspacePasteboardExportService.clearFileTransferPasteboard()
        store.cutDocument(document)
        return true
    }

    private func importPasteboardFromCommand() -> Bool {
        do {
            let items = try WorkspacePasteboardImportService.importItems(from: .general)
            guard !items.isEmpty else { return false }
            store.importPasteboardItems(items)
            return true
        } catch {
            store.errorMessage = "Could not read clipboard contents: \(error.localizedDescription)"
            return true
        }
    }

    private var keyboardShortcutContext: MonknotKeyboardShortcutContext {
        let selectedDocument = store.selectedDocument
        return MonknotKeyboardShortcutContext(
            hasWorkspace: store.workspaceURL != nil,
            hasSelectedDocument: selectedDocument != nil,
            selectedDocumentKind: selectedDocument?.kind,
            canCloseTab: tabState.selectedDocumentID != nil && !store.isBusy,
            canTogglePinTab: tabState.selectedDocumentID != nil && !store.isBusy,
            canExportPDF: selectedDocument?.capabilities.canExportPDF == true,
            canUndoPDFAnnotation: selectedDocument?.kind == .pdf && canUndoPDFAnnotation,
            canRedoPDFAnnotation: selectedDocument?.kind == .pdf && canRedoPDFAnnotation,
            isDocumentSearchPresented: documentSearch.isPresented,
            isBusy: store.isBusy
        )
    }

    private func performKeyboardShortcutAction(_ action: MonknotKeyboardShortcutAction) {
        switch action {
        case .newMarkdown:
            store.createMarkdownFile()
        case .openFolder:
            openFolderPanel()
        case .saveDocument:
            store.saveSelectedFile()
        case .cutDocument:
            _ = cutFromCommand()
        case .copyDocument:
            _ = copyFromCommand()
        case .refreshWorkspace:
            store.refresh()
        case .closeTab:
            closeActiveTab()
        case .togglePinTab:
            toggleActiveTabPin()
        case .exportPDF:
            exportSelectedMarkdownPDF()
        case .showDocumentSearch:
            showDocumentSearch()
        case .showWorkspaceSearch:
            showWorkspaceSearch()
        case .findNext:
            documentSearch.findNext()
        case .findPrevious:
            documentSearch.findPrevious()
        case .zoomIn:
            adjustZoom(by: 0.1)
        case .zoomOut:
            adjustZoom(by: -0.1)
        case .resetZoom:
            zoomScale = 1.0
        case .importPasteboard:
            _ = pasteFromCommand()
        case .toggleTerminal:
            toggleTerminalDrawer()
        case .toggleSidebar:
            toggleSidebar()
        case .undoPDFAnnotation:
            pdfUndoCommandSerial += 1
        case .redoPDFAnnotation:
            pdfRedoCommandSerial += 1
        case .dismissDocumentSearch:
            documentSearch.dismiss()
        }
    }

    private func resetPDFAnnotationShortcutState() {
        canUndoPDFAnnotation = false
        canRedoPDFAnnotation = false
    }

    private func updatePDFAnnotationShortcutState(canUndo: Bool, canRedo: Bool) {
        if canUndoPDFAnnotation != canUndo {
            canUndoPDFAnnotation = canUndo
        }
        if canRedoPDFAnnotation != canRedo {
            canRedoPDFAnnotation = canRedo
        }
    }

    private func showDocumentSearch() {
        guard store.selectedDocument != nil else { return }
        documentSearch.present()
    }

    private func showWorkspaceSearch() {
        guard store.workspaceURL != nil else { return }
        setSidebarVisibility(.all)
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
        "\(themePreference.rawValue)-\(systemColorScheme == .dark ? "dark" : "light")-\(zoomScale)-\(activeTheme.uiFontSize)"
    }

    /// Single source of truth for the chrome row height (in points). The
    /// same formula is mirrored by SwiftUI chrome views (`scaled(44)`),
    /// so the AppKit unified toolbar and the SwiftUI chrome stay in
    /// lockstep when the user changes zoom or font size.
    private var nativeChromeHeight: CGFloat {
        MonknotMetrics.chromeHeight(theme: activeTheme, zoomScale: zoomScale)
    }

    private func toggleSidebar() {
        setSidebarVisibility(sidebarVisibility == .detailOnly ? .all : .detailOnly)
    }

    private func setSidebarVisibility(_ visibility: NavigationSplitViewVisibility) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            sidebarVisibility = visibility
        }
    }
}

private struct DeferredWorkspaceSourceJump: Equatable {
    let documentID: String
    let location: MarkdownSourceLocation
}
