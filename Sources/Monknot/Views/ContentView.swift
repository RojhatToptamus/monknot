import AppKit
import MonknotCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TerminalFocusRestorer: ObservableObject {
    private weak var window: NSWindow?
    private weak var responder: NSResponder?
    private var generation: UInt = 0

    func capture(from window: NSWindow?) {
        generation &+= 1
        guard !hasValidSavedTarget else { return }
        self.window = window
        responder = Self.preferredResponder(in: window)
    }

    func restore(fallbackFrom fallbackWindow: NSWindow? = nil) {
        if !hasValidSavedTarget {
            generation &+= 1
            window = fallbackWindow
            responder = Self.fallbackDocumentFocusTarget(in: fallbackWindow)
        }

        guard let window, let responder else {
            clear()
            return
        }

        let restoreGeneration = generation
        DispatchQueue.main.async { [weak self, weak window, weak responder] in
            guard let self, self.generation == restoreGeneration else { return }
            defer { self.clear() }
            guard let window, let responder else { return }
            if let view = responder as? NSView {
                guard view.window === window else { return }
            }
            window.makeFirstResponder(responder)
        }
    }

    private var hasValidSavedTarget: Bool {
        guard let window, let responder else { return false }
        guard let view = responder as? NSView else { return true }
        return view.window === window
    }

    private static func preferredResponder(in window: NSWindow?) -> NSResponder? {
        guard let window else { return nil }
        if let view = window.firstResponder as? NSView, view.window === window {
            return view
        }
        return fallbackDocumentFocusTarget(in: window)
    }

    private static func fallbackDocumentFocusTarget(in window: NSWindow?) -> NSResponder? {
        guard let window, let contentView = window.contentView else { return nil }
        return firstDocumentFocusTarget(in: contentView, expectedWindow: window, root: contentView)
    }

    private static func firstDocumentFocusTarget(
        in view: NSView,
        expectedWindow: NSWindow,
        root: NSView
    ) -> NSView? {
        if view.identifier == .monknotDocumentFocusTarget,
           view.window === expectedWindow,
           isVisible(view, within: root) {
            return view
        }
        // Source is mounted before preview in split mode. Preserving depth-first
        // order makes the keyboard-oriented fallback deterministic when a Menu
        // has already discarded the exact first responder.
        for subview in view.subviews {
            if let target = firstDocumentFocusTarget(
                in: subview,
                expectedWindow: expectedWindow,
                root: root
            ) {
                return target
            }
        }
        return nil
    }

    private static func isVisible(_ view: NSView, within root: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current.isHidden { return false }
            if current === root { return true }
            candidate = current.superview
        }
        return false
    }

    private func clear() {
        window = nil
        responder = nil
    }
}

struct ContentView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var themeStore: ThemeSettingsStore
    @AppStorage("Monknot.editorMode") private var editorModeRawValue = EditorMode.source.rawValue
    @AppStorage("Monknot.themePreference") private var themePreferenceRawValue = ThemePreference.system.rawValue
    @AppStorage("Monknot.zoomScale") private var persistedZoomScale = WorkspaceZoomPolicy.defaultValue
    @AppStorage("Monknot.previewWidthPercent") private var previewWidthPercent = 88.0
    @AppStorage("Monknot.showDocumentOutline") private var showDocumentOutline = true
    @State private var isMarkdownSplitViewEnabled = false
    @AppStorage("Monknot.usePointerCursors") private var usePointerCursors = false
    @AppStorage("Monknot.fontSmoothing") private var fontSmoothing = true
    @SceneStorage("Monknot.isTerminalDrawerOpen") private var isTerminalDrawerOpen = false
    @StateObject private var terminalFocusRestorer = TerminalFocusRestorer()
    @StateObject private var workspaceSearch = WorkspaceSearchState()
    @StateObject private var quickOpen = WorkspaceQuickOpenState()
    @StateObject private var symbolQuickOpen = MarkdownSymbolQuickOpenState()
    @StateObject private var outlineStore = MarkdownOutlineStore()
    @State private var pendingSourceLocation: MarkdownSourceLocation?
    @State private var pendingPreviewLocation: MarkdownSourceLocation?
    @State private var pendingPDFSearchTarget: WorkspaceSearchPDFTarget?
    @State private var deferredWorkspaceSourceJump: DeferredWorkspaceSourceJump?
    @State private var tabState = WorkspaceTabState()
    @State private var documentNavigationHistory = DocumentNavigationHistory()
    @State private var restoredTabStateWorkspacePath: String?
    @State private var pendingTabStatePersistenceTask: Task<Void, Never>?
    @State private var documentViewportStates: [String: DocumentViewportState] = [:]
    @State private var pdfUndoCommandSerial = 0
    @State private var pdfRedoCommandSerial = 0
    @State private var canUndoPDFAnnotation = false
    @State private var canRedoPDFAnnotation = false
    @State private var documentSearch = DocumentSearchState()
    @State private var isSidebarVisible = true
    @SceneStorage("Monknot.sidebarPreferredVisible") private var sidebarPreferredVisible = true
    @State private var exportNotice: ExportSuccessNotice?
    @State private var pendingPDFExportDocument: WorkspaceDocument?
    @State private var pdfExportOptions = MarkdownPDFExportOptions.loadLastUsed()
    @State private var isExportingPDF = false
    @State private var isResolvingUnsavedChanges = false
    @State private var isKeyboardShortcutsHelpPresented = false
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let tabStatePersistence = WorkspaceTabStatePersistence()

    private var zoomScale: Double {
        get { WorkspaceZoomPolicy.clamp(persistedZoomScale) }
        nonmutating set { persistedZoomScale = WorkspaceZoomPolicy.clamp(newValue) }
    }

    private var editorMode: EditorMode {
        get { EditorMode(rawValue: editorModeRawValue) ?? .source }
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
                trafficLightRowHeight: MonknotMetrics.chromeHeight(
                    theme: activeTheme,
                    zoomScale: zoomScale
                ),
                usesDarkAppearance: activeTheme.isDark
            ))
            .background(WindowCloseGuard(
                shouldClose: { await resolveAllOpenUnsavedChanges() }
            ))
            .background(KeyboardShortcutMonitor(handler: handleKeyDown))
            .preferredColorScheme(themePreference.preferredColorScheme)
            .accentColor(activeTheme.accentColor)
        )
    }

    private var lifecycleContent: AnyView {
        AnyView(chromeContent
            .onChange(of: store.selectedDocument?.id) { oldDocumentID, newDocumentID in
                if documentNavigationHistory.currentDocumentID != newDocumentID {
                    documentNavigationHistory.replaceCurrent(with: newDocumentID)
                }
                resetPDFAnnotationShortcutState()
                pendingPDFSearchTarget = nil
                if let oldDocumentID, supportsSplitView(store.document(id: oldDocumentID)) {
                    DocumentSplitViewPersistence.setEnabled(
                        isMarkdownSplitViewEnabled,
                        forDocumentPath: oldDocumentID
                    )
                }
                if let newDocumentID, supportsSplitView(store.document(id: newDocumentID)) {
                    isMarkdownSplitViewEnabled = DocumentSplitViewPersistence.isEnabled(forDocumentPath: newDocumentID)
                } else {
                    isMarkdownSplitViewEnabled = false
                }
                syncSelectedTabWithStore()
                if !canShowDocumentSearch {
                    documentSearch.dismiss()
                } else if documentSearch.currentIndex != 0 || documentSearch.totalCount != 0 {
                    documentSearch.updateResult(.init())
                }
                updateOutline()
                fulfillDeferredWorkspaceSourceJump()
            }
            .onChange(of: isMarkdownSplitViewEnabled) { _, isEnabled in
                guard let documentID = store.selectedDocument?.id,
                      supportsSplitView(store.selectedDocument)
                else {
                    return
                }
                DocumentSplitViewPersistence.setEnabled(isEnabled, forDocumentPath: documentID)
            }
            .onChange(of: store.documentText) { _, _ in
                updateOutline()
                fulfillDeferredWorkspaceSourceJump()
            }
            .onChange(of: store.isDocumentLoading) { _, isLoading in
                if !isLoading {
                    updateOutline()
                }
                fulfillDeferredWorkspaceSourceJump()
            }
            .onChange(of: store.documents) { _, documents in
                workspaceSearch.refresh(documents: documents)
                quickOpen.refresh(documents: documents)
                reconcileTabsWithStore()
            }
            .onChange(of: store.workspaceSearchContentChangeSerial) { _, _ in
                workspaceSearch.refresh(documents: store.documents)
            }
            .onChange(of: store.workspaceURL?.standardizedFileURL.path ?? "") { _, _ in
                tabState.reset()
                documentNavigationHistory.reset()
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
            .onDisappear {
                flushPendingTabStatePersistence()
            }
            .focusedSceneValue(\.monknotCommandActions, commandActions)
        )
    }

    private var alertContent: AnyView {
        AnyView(lifecycleContent
            .alert("Monknot", isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {
                    store.errorMessage = nil
                }
            } message: {
                Text(store.errorMessage ?? "")
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
        rootContentStack
            .onAppear {
                persistedZoomScale = WorkspaceZoomPolicy.clamp(persistedZoomScale)
                setSidebarPresented(sidebarPreferredVisible, animated: false)
            }
    }

    private var rootContentStack: some View {
        ZStack {
            VStack(spacing: 0) {
                MonknotChromePanel(theme: activeTheme, surface: activeTheme.sidebarSurfaceColor) {
                    primaryTitlebar
                }

                WorkspaceSplitView(isSidebarPresented: isSidebarVisible) {
                    sidebarContent
                } detail: {
                    detailContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let exportNotice {
                ExportSuccessToast(
                    notice: exportNotice,
                    theme: activeTheme,
                    showInFinder: {
                        NSWorkspace.shared.activateFileViewerSelecting([exportNotice.url])
                        self.exportNotice = nil
                    },
                    dismiss: { self.exportNotice = nil }
                )
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .transition(MonknotMotion.toastTransition(reduceMotion: reduceMotion))
                .zIndex(3)
            }

            if quickOpen.isPresented {
                WorkspaceQuickOpenView(
                    state: quickOpen,
                    documents: store.documents,
                    theme: activeTheme,
                    zoomScale: zoomScale,
                    close: { quickOpen.dismiss() },
                    openDocument: { documentID in
                        quickOpen.dismiss()
                        openDocumentTab(id: documentID)
                    }
                )
                .transition(.opacity)
            }

            if isKeyboardShortcutsHelpPresented {
                MonknotKeyboardShortcutsHelpView(
                    theme: activeTheme,
                    zoomScale: zoomScale,
                    close: { isKeyboardShortcutsHelpPresented = false }
                )
                .transition(.opacity)
            }

            if symbolQuickOpen.isPresented {
                MarkdownSymbolQuickOpenView(
                    state: symbolQuickOpen,
                    items: outlineStore.items,
                    theme: activeTheme,
                    zoomScale: zoomScale,
                    close: { symbolQuickOpen.dismiss() },
                    selectItem: { item in
                        symbolQuickOpen.dismiss()
                        openOutlineItem(item)
                    }
                )
                .transition(.opacity)
            }

        }
        .task(id: exportNotice?.id) {
            guard exportNotice != nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(MonknotMotion.toastAnimation(reduceMotion: reduceMotion)) {
                exportNotice = nil
            }
        }
    }

    private var primaryTitlebar: some View {
        TopNavigationBar(
            editorMode: Binding(
                get: { editorMode },
                set: { editorMode = $0 }
            ),
            isSplitViewEnabled: $isMarkdownSplitViewEnabled,
            emptyStateTitle: store.workspaceURL?.lastPathComponent ?? "Monknot",
            selectedDocument: store.selectedDocument,
            isBusy: store.isBusy,
            isDocumentLoading: store.isDocumentLoading,
            isSaving: store.isSaving,
            theme: activeTheme,
            zoomScale: zoomScale,
            isTerminalPresented: isTerminalDrawerOpen,
            isSidebarVisible: isSidebarVisible,
            toggleTerminal: { toggleTerminalDrawer(animated: true) },
            toggleSidebar: { toggleSidebar(animated: true) },
            toggleSplitView: toggleMarkdownSplitView,
            documentSearch: $documentSearch,
            tabs: tabState.tabs,
            activeTabID: tabState.selectedDocumentID,
            missingTabIDs: store.removedDirtyOpenDocumentIDs,
            saveState: { store.saveState(for: $0) },
            selectTab: activateTab(id:),
            closeTab: closeTab(id:),
            togglePinTab: togglePinTab(id:),
            reorderTab: reorderTab(draggedID:targetID:),
            navigateBack: navigateBack,
            navigateForward: navigateForward,
            canNavigateBack: canNavigateBack,
            canNavigateForward: canNavigateForward
        )
    }

    private var themeScrim: some View {
        activeTheme.scrimColor
            .ignoresSafeArea()
    }

    private var sidebarContent: some View {
        SidebarView(
            store: store,
            workspaceSearch: workspaceSearch,
            theme: activeTheme,
            zoomScale: zoomScale,
            openFolder: openFolderPanel,
            openRecentWorkspace: { url in store.openWorkspace(url) },
            newMarkdown: { store.createMarkdownFile() },
            exportPDF: exportMarkdownPDF(_:),
            openDocument: openDocumentTab(id:),
            openWorkspaceSearchResult: openWorkspaceSearchResult(_:)
        )
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    private var detailContent: some View {
        EditorPaneView(
            store: store,
            editorMode: Binding(
                get: { editorMode },
                set: { editorMode = $0 }
            ),
            isSplitViewEnabled: $isMarkdownSplitViewEnabled,
            theme: activeTheme,
            zoomScale: zoomScale,
            codeFontSize: CGFloat(activeTheme.codeFontSize),
            previewWidthPercent: previewWidthPercent,
            showsDocumentOutline: showDocumentOutline,
            usePointerCursors: usePointerCursors,
            fontSmoothing: fontSmoothing,
            activeViewportState: activeDocumentViewportState,
            updateViewportState: updateDocumentViewportState(documentID:change:),
            pdfUndoCommandSerial: pdfUndoCommandSerial,
            pdfRedoCommandSerial: pdfRedoCommandSerial,
            updatePDFAnnotationUndoState: updatePDFAnnotationShortcutState(canUndo:canRedo:),
            isTerminalPresented: $isTerminalDrawerOpen,
            sourceLocation: $pendingSourceLocation,
            previewLocation: $pendingPreviewLocation,
            pdfSearchTarget: $pendingPDFSearchTarget,
            documentSearch: $documentSearch,
            newMarkdown: { store.createMarkdownFile() },
            bootstrapStarterWorkspace: { store.bootstrapStarterWorkspace() },
            openFolder: openFolderPanel,
            closeTerminal: { setTerminalDrawerPresented(false, animated: true) },
            outlineItems: outlineStore.items,
            selectOutlineItem: openOutlineItem(_:),
            onPreviewSourceJump: openSourceFromPreview(location:)
        )
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
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
        pdfExportOptions = MarkdownPDFExportOptions.loadLastUsed()
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

                withAnimation(MonknotMotion.toastAnimation(reduceMotion: reduceMotion)) {
                    exportNotice = ExportSuccessNotice(url: destinationURL)
                }
                NSAccessibility.post(
                    element: NSApp as Any,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: "Export complete: \(destinationURL.lastPathComponent)",
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue
                    ]
                )
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
        zoomScale = WorkspaceZoomPolicy.stepped(zoomScale, by: delta)
    }

    private var canNavigateBack: Bool {
        !store.isBusy && documentNavigationHistory.canGoBack
    }

    private var canNavigateForward: Bool {
        !store.isBusy && documentNavigationHistory.canGoForward
    }

    private func recordDocumentNavigation(from previousDocumentID: String?, to documentID: String) {
        if documentNavigationHistory.currentDocumentID != previousDocumentID {
            documentNavigationHistory.replaceCurrent(with: previousDocumentID)
        }
        documentNavigationHistory.recordSelection(documentID)
    }

    private func navigateBack() {
        navigateHistory(destination: documentNavigationHistory.backDocumentID) {
            documentNavigationHistory.goBack()
        }
    }

    private func navigateForward() {
        navigateHistory(destination: documentNavigationHistory.forwardDocumentID) {
            documentNavigationHistory.goForward()
        }
    }

    private func navigateHistory(
        destination documentID: String?,
        commit: () -> String?
    ) {
        guard !store.isBusy,
              let documentID,
              let document = store.document(id: documentID),
              store.selectDocument(id: documentID)
        else {
            return
        }

        guard commit() == documentID else { return }
        tabState.open(document)
        publishOpenTabIDs()
    }

    private func openDocumentTab(id documentID: String) {
        guard !store.isBusy, let document = store.document(id: documentID) else { return }
        let previousDocumentID = store.selectedDocumentID
        guard store.selectDocument(id: documentID) else { return }
        recordDocumentNavigation(from: previousDocumentID, to: documentID)
        tabState.open(document)
        publishOpenTabIDs()
    }

    private func activateTab(id documentID: String) {
        guard !store.isBusy else { return }
        guard tabState.contains(documentID: documentID) else { return }
        let previousDocumentID = store.selectedDocumentID
        guard store.selectDocument(id: documentID) else { return }
        recordDocumentNavigation(from: previousDocumentID, to: documentID)

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
        documentNavigationHistory.remove(documentID: documentID)
        documentViewportStates.removeValue(forKey: documentID)
        publishOpenTabIDs()

        if wasActive || store.selectedDocumentID == documentID {
            _ = store.selectDocument(id: nextDocumentID)
            documentNavigationHistory.replaceCurrent(with: nextDocumentID)
        }
    }

    private func closeActiveTab() {
        guard let selectedDocumentID = tabState.selectedDocumentID else { return }

        if tabState.tab(for: selectedDocumentID)?.isPinned == true {
            togglePinTab(id: selectedDocumentID)
            return
        }

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

        let previousState = tabState
        let availableDocumentIDs = Set(store.documents.map(\.id))
        tabState.updateSnapshots(from: store.documents)
        tabState.pruneUnavailableDocuments(
            availableDocumentIDs: availableDocumentIDs,
            preserving: store.removedDirtyOpenDocumentIDs
        )
        documentNavigationHistory.prune(
            availableDocumentIDs: availableDocumentIDs.union(store.removedDirtyOpenDocumentIDs)
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

        if tabState != previousState {
            publishOpenTabIDs()
        }

        if tabState.selectedDocumentID != store.selectedDocumentID {
            _ = store.selectDocument(id: tabState.selectedDocumentID)
        }
    }

    private func syncSelectedTabWithStore() {
        guard !store.isBusy else { return }
        if restorePersistedTabsIfNeeded() {
            return
        }

        let previousState = tabState

        if let selectedDocument = store.selectedDocument {
            if tabState.contains(documentID: selectedDocument.id) || !tabState.isEmptyByUserChoice {
                tabState.open(selectedDocument)
            }
        } else if store.selectedDocumentID == nil, tabState.tabs.isEmpty {
            tabState.activate(documentID: nil)
        }

        if tabState.selectedDocumentID != store.selectedDocumentID {
            _ = store.selectDocument(id: tabState.selectedDocumentID)
        }

        if tabState != previousState {
            publishOpenTabIDs()
        }
    }

    private func applyDocumentIDRemapEvent() {
        guard let event = store.documentIDRemapEvent else { return }
        for mapping in event.mappings {
            DocumentSplitViewPersistence.remapDocumentPath(
                from: mapping.sourceID,
                to: mapping.destinationID
            )
            tabState.remapDocumentID(
                sourceID: mapping.sourceID,
                destinationID: mapping.destinationID,
                document: store.document(id: mapping.destinationID)
            )
            if let viewportState = documentViewportStates.removeValue(forKey: mapping.sourceID) {
                documentViewportStates[mapping.destinationID] = viewportState
            }
            documentNavigationHistory.remapDocumentID(
                from: mapping.sourceID,
                to: mapping.destinationID
            )
        }
        if let selectedDocumentID = store.selectedDocument?.id {
            if supportsSplitView(store.selectedDocument) {
                isMarkdownSplitViewEnabled = DocumentSplitViewPersistence.isEnabled(
                    forDocumentPath: selectedDocumentID
                )
            } else {
                isMarkdownSplitViewEnabled = false
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
        let state = tabState
        let persistence = tabStatePersistence
        pendingTabStatePersistenceTask?.cancel()
        pendingTabStatePersistenceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            persistence.save(state, for: workspaceURL)
        }
    }

    private func flushPendingTabStatePersistence() {
        pendingTabStatePersistenceTask?.cancel()
        pendingTabStatePersistenceTask = nil
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
        case .pdfViewportState(let viewportState):
            guard viewportState.isMeaningfullyDifferent(from: state.pdfViewportState) else { return }
            state.pdfViewportState = viewportState
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
            newDailyNote: { store.createDailyNote() },
            openFolder: openFolderPanel,
            exportPDF: { exportSelectedMarkdownPDF() },
            canExportPDF: store.selectedDocument?.capabilities.canExportPDF == true,
            exportPDFAnnotationsMarkdown: {
                if let document = store.selectedDocument {
                    store.exportPDFAnnotationsToMarkdown(for: document)
                }
            },
            canExportPDFAnnotationsMarkdown: store.selectedDocument?.kind == .pdf,
            exportAllPDFAnnotationsMarkdown: {
                store.exportAllPDFAnnotationsToMarkdown()
            },
            canExportAllPDFAnnotationsMarkdown: !store.isBusy && store.hasPDFDocuments,
            exportAnnotatedPDFCopy: {
                if let document = store.selectedDocument {
                    store.exportAnnotatedPDFCopy(for: document)
                }
            },
            canExportAnnotatedPDFCopy: store.selectedDocument?.kind == .pdf,
            saveDocument: { store.saveSelectedFile() },
            cut: { _ = cutFromCommand() },
            copy: { _ = copyFromCommand() },
            paste: { _ = pasteFromCommand() },
            selectAll: { _ = MonknotNativePasteboardCommand.performSelectAllIfAvailable() },
            refreshWorkspace: { store.refresh() },
            navigateBack: navigateBack,
            canNavigateBack: canNavigateBack,
            navigateForward: navigateForward,
            canNavigateForward: canNavigateForward,
            closeTab: { closeActiveTab() },
            canCloseTab: tabState.selectedDocumentID != nil && !store.isBusy,
            togglePinTab: { toggleActiveTabPin() },
            canTogglePinTab: tabState.selectedDocumentID != nil && !store.isBusy,
            zoomIn: { adjustZoom(by: WorkspaceZoomPolicy.step) },
            zoomOut: { adjustZoom(by: -WorkspaceZoomPolicy.step) },
            resetZoom: { zoomScale = WorkspaceZoomPolicy.defaultValue },
            showFind: { showDocumentSearch() },
            canShowFind: canShowDocumentSearch,
            showWorkspaceSearch: { showWorkspaceSearch() },
            showQuickOpen: { showQuickOpen() },
            canShowQuickOpen: store.workspaceURL != nil && !store.isBusy,
            findNext: { documentSearch.findNext() },
            findPrevious: { documentSearch.findPrevious() },
            toggleTerminal: { toggleTerminalDrawer(animated: false) },
            toggleSidebar: { toggleSidebar(animated: false) },
            toggleSplitView: { toggleMarkdownSplitView() },
            canToggleSplitView: canToggleMarkdownSplitView,
            undoWorkspaceReplace: { store.undoLastWorkspaceReplace() },
            canUndoWorkspaceReplace: store.canUndoWorkspaceReplace && !store.isBusy
        )
    }

    private var canToggleMarkdownSplitView: Bool {
        guard !store.isBusy else { return false }
        return supportsSplitView(store.selectedDocument)
    }

    private func supportsSplitView(_ document: WorkspaceDocument?) -> Bool {
        guard let document else { return false }
        return document.kind == .markdown || document.capabilities.canPreviewHTML
    }

    private func toggleMarkdownSplitView() {
        guard canToggleMarkdownSplitView else { return }
        isMarkdownSplitViewEnabled.toggle()
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
            isQuickOpenPresented: quickOpen.isPresented,
            isKeyboardShortcutsHelpPresented: isKeyboardShortcutsHelpPresented,
            isWorkspaceSearchPresented: workspaceSearch.isPresented,
            isSymbolQuickOpenPresented: symbolQuickOpen.isPresented,
            hasMarkdownOutline: store.selectedDocument?.kind == .markdown && !outlineStore.items.isEmpty,
            canToggleSplitView: canToggleMarkdownSplitView,
            canUndoWorkspaceReplace: store.canUndoWorkspaceReplace && !store.isBusy,
            isBusy: store.isBusy
        )
    }

    private func performKeyboardShortcutAction(_ action: MonknotKeyboardShortcutAction) {
        switch action {
        case .newMarkdown:
            store.createMarkdownFile()
        case .newDailyNote:
            store.createDailyNote()
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
        case .showWorkspaceSearch:
            showWorkspaceSearch()
        case .dismissWorkspaceSearch:
            workspaceSearch.dismiss()
        case .showDocumentSearch:
            showDocumentSearch()
        case .findNext:
            if canShowDocumentSearch {
                documentSearch.findNext()
            }
        case .findPrevious:
            if canShowDocumentSearch {
                documentSearch.findPrevious()
            }
        case .zoomIn:
            adjustZoom(by: WorkspaceZoomPolicy.step)
        case .zoomOut:
            adjustZoom(by: -WorkspaceZoomPolicy.step)
        case .resetZoom:
            zoomScale = WorkspaceZoomPolicy.defaultValue
        case .importPasteboard:
            _ = pasteFromCommand()
        case .toggleTerminal:
            toggleTerminalDrawer(animated: false)
        case .toggleSidebar:
            toggleSidebar(animated: false)
        case .undoPDFAnnotation:
            pdfUndoCommandSerial += 1
        case .redoPDFAnnotation:
            pdfRedoCommandSerial += 1
        case .dismissDocumentSearch:
            documentSearch.dismiss()
        case .showQuickOpen:
            showQuickOpen()
        case .dismissQuickOpen:
            quickOpen.dismiss()
        case .showGoToSymbol:
            showGoToSymbol()
        case .dismissGoToSymbol:
            symbolQuickOpen.dismiss()
        case .workspaceSearchNext:
            workspaceSearch.selectNextResult()
        case .workspaceSearchPrevious:
            workspaceSearch.selectPreviousResult()
        case .workspaceSearchConfirm:
            if let result = workspaceSearch.selectedResult {
                openWorkspaceSearchResult(result)
            }
        case .showKeyboardShortcutsHelp:
            isKeyboardShortcutsHelpPresented = true
        case .dismissKeyboardShortcutsHelp:
            isKeyboardShortcutsHelpPresented = false
        case .toggleSplitView:
            toggleMarkdownSplitView()
        case .undoWorkspaceReplace:
            store.undoLastWorkspaceReplace()
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

    private func showQuickOpen() {
        guard store.workspaceURL != nil, !store.isBusy else { return }
        isKeyboardShortcutsHelpPresented = false
        symbolQuickOpen.dismiss()
        workspaceSearch.dismiss()
        quickOpen.present(documents: store.documents)
    }

    private func showGoToSymbol() {
        guard store.selectedDocument?.kind == .markdown, !outlineStore.items.isEmpty else { return }
        isKeyboardShortcutsHelpPresented = false
        quickOpen.dismiss()
        workspaceSearch.dismiss()
        symbolQuickOpen.present(items: outlineStore.items)
    }

    private func showDocumentSearch() {
        guard canShowDocumentSearch else { return }
        documentSearch.present()
    }

    private var canShowDocumentSearch: Bool {
        guard let document = store.selectedDocument, !store.isBusy else { return false }
        return document.capabilities.canSearchText ||
            document.capabilities.canPreviewHTML ||
            document.capabilities.canSearchPDF
    }

    private func showWorkspaceSearch() {
        guard store.workspaceURL != nil else { return }
        setSidebarPresented(true, animated: false)
        workspaceSearch.present(documents: store.documents)
    }

    private func openWorkspaceSearchResult(_ result: WorkspaceSearchResult) {
        let query = workspaceSearch.query

        if result.kind == .text || result.kind == .pdf {
            documentSearch.present()
            documentSearch.setQuery(query)
        }

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
            isMarkdown: store.selectedDocument?.kind == .markdown && !store.isDocumentLoading
        )
    }

    private func toggleTerminalDrawer(animated: Bool) {
        setTerminalDrawerPresented(!isTerminalDrawerOpen, animated: animated)
    }

    private func setTerminalDrawerPresented(_ isPresented: Bool, animated: Bool) {
        guard isTerminalDrawerOpen != isPresented else { return }
        if isPresented {
            terminalFocusRestorer.capture(from: NSApp.keyWindow)
        }
        updateChromeState(animated: animated) {
            isTerminalDrawerOpen = isPresented
        }
        if !isPresented {
            terminalFocusRestorer.restore(fallbackFrom: NSApp.keyWindow)
        }
    }

    private func toggleSidebar(animated: Bool) {
        let willShowSidebar = !isSidebarVisible
        sidebarPreferredVisible = willShowSidebar
        setSidebarPresented(willShowSidebar, animated: animated)
    }

    private func setSidebarPresented(
        _ isPresented: Bool,
        animated: Bool
    ) {
        updateChromeState(animated: animated) {
            isSidebarVisible = isPresented
        }
    }

    private func updateChromeState(animated: Bool, updates: () -> Void) {
        if animated && !reduceMotion {
            withAnimation(MonknotMotion.sidebarTransition, updates)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, updates)
        }
    }

}

struct WindowNavigationControls: View {
    let navigateBack: () -> Void
    let navigateForward: () -> Void
    let canNavigateBack: Bool
    let canNavigateForward: Bool
    let theme: AppTheme
    let zoomScale: Double

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: scaled(2)) {
            MonknotIconButton(
                systemImage: "chevron.left",
                label: "Back",
                theme: theme,
                zoomScale: zoomScale,
                isDisabled: !canNavigateBack,
                size: .windowNavigation,
                action: navigateBack
            )

            MonknotIconButton(
                systemImage: "chevron.right",
                label: "Forward",
                theme: theme,
                zoomScale: zoomScale,
                isDisabled: !canNavigateForward,
                size: .windowNavigation,
                action: navigateForward
            )
        }
        .padding(scaled(2))
        .overlay {
            RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                .strokeBorder(theme.borderColor, lineWidth: 1)
        }
        .frame(height: MonknotMetrics.chromeHeight(theme: theme, zoomScale: zoomScale))
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ExportSuccessNotice: Identifiable, Equatable {
    let url: URL

    var id: String { url.standardizedFileURL.path }
}

private struct ExportSuccessToast: View {
    let notice: ExportSuccessNotice
    let theme: AppTheme
    let showInFinder: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: theme.semanticColors.diffAdded))
                .accessibilityHidden(true)

            Text("Exported \(notice.url.lastPathComponent)")
                .font(.system(size: 12.5))
                .foregroundStyle(theme.foregroundColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 230, alignment: .leading)
                .accessibilityLabel("Export complete: \(notice.url.lastPathComponent)")

            Button("Show in Finder", action: showInFinder)
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.accentColor)
                .monknotPointerCursor()

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss export notification")
            .monknotPointerCursor()
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: theme.chromeRadius(9, zoomScale: 1))
                .fill(theme.elevatedSurfaceColor)
                .overlay {
                    RoundedRectangle(cornerRadius: theme.chromeRadius(9, zoomScale: 1))
                        .strokeBorder(theme.borderColor, lineWidth: 1)
                }
                .shadow(color: .black.opacity(theme.isDark ? 0.38 : 0.16), radius: 18, y: 8)
        )
        .frame(maxWidth: 420)
        .accessibilityElement(children: .contain)
    }
}

private struct DeferredWorkspaceSourceJump: Equatable {
    let documentID: String
    let location: MarkdownSourceLocation
}

struct DocumentNavigationHistory: Equatable {
    static let maximumStackDepth = 100

    private(set) var backStack: [String] = []
    private(set) var currentDocumentID: String?
    private(set) var forwardStack: [String] = []

    var backDocumentID: String? { backStack.last }
    var forwardDocumentID: String? { forwardStack.last }
    var canGoBack: Bool { backDocumentID != nil }
    var canGoForward: Bool { forwardDocumentID != nil }

    mutating func recordSelection(_ documentID: String) {
        guard documentID != currentDocumentID else { return }

        if let currentDocumentID {
            backStack.append(currentDocumentID)
            Self.trimOldestEntriesIfNeeded(in: &backStack)
        }
        currentDocumentID = documentID
        forwardStack.removeAll()
    }

    @discardableResult
    mutating func goBack() -> String? {
        guard let destination = backStack.popLast() else { return nil }
        if let currentDocumentID {
            forwardStack.append(currentDocumentID)
            Self.trimOldestEntriesIfNeeded(in: &forwardStack)
        }
        currentDocumentID = destination
        return destination
    }

    @discardableResult
    mutating func goForward() -> String? {
        guard let destination = forwardStack.popLast() else { return nil }
        if let currentDocumentID {
            backStack.append(currentDocumentID)
            Self.trimOldestEntriesIfNeeded(in: &backStack)
        }
        currentDocumentID = destination
        return destination
    }

    mutating func replaceCurrent(with documentID: String?) {
        currentDocumentID = documentID
    }

    mutating func remove(documentID: String) {
        backStack.removeAll { $0 == documentID }
        forwardStack.removeAll { $0 == documentID }
        if currentDocumentID == documentID {
            currentDocumentID = nil
        }
    }

    mutating func prune(availableDocumentIDs: Set<String>) {
        backStack.removeAll { !availableDocumentIDs.contains($0) }
        forwardStack.removeAll { !availableDocumentIDs.contains($0) }
        if let currentDocumentID, !availableDocumentIDs.contains(currentDocumentID) {
            self.currentDocumentID = nil
        }
    }

    mutating func remapDocumentID(from sourceID: String, to destinationID: String) {
        guard sourceID != destinationID else { return }
        backStack = backStack.map { $0 == sourceID ? destinationID : $0 }
        forwardStack = forwardStack.map { $0 == sourceID ? destinationID : $0 }
        if currentDocumentID == sourceID {
            currentDocumentID = destinationID
        }
    }

    mutating func reset(currentDocumentID: String? = nil) {
        backStack.removeAll()
        self.currentDocumentID = currentDocumentID
        forwardStack.removeAll()
    }

    private static func trimOldestEntriesIfNeeded(in stack: inout [String]) {
        let overflow = stack.count - Self.maximumStackDepth
        if overflow > 0 {
            stack.removeFirst(overflow)
        }
    }
}
