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

    func discard() {
        generation &+= 1
        clear()
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
    let terminationCoordinator: ApplicationTerminationCoordinator
    @AppStorage("Monknot.editorMode") private var editorModeRawValue = EditorMode.source.rawValue
    @AppStorage("Monknot.themePreference") private var themePreferenceRawValue = ThemePreference.defaultValue.rawValue
    @AppStorage("Monknot.zoomScale") private var persistedZoomScale = WorkspaceZoomPolicy.defaultValue
    @AppStorage(ContentWidthPreference.key) private var contentWidthPercent = ContentWidthPreference.initialValue()
    @AppStorage("Monknot.showDocumentOutline") private var showDocumentOutline = true
    @State private var isMarkdownSplitViewEnabled = false
    @AppStorage("Monknot.usePointerCursors") private var usePointerCursors = false
    @AppStorage("Monknot.fontSmoothing") private var fontSmoothing = true
    @AppStorage(TerminalWorkingDirectoryPreference.key)
    private var terminalWorkingDirectory = TerminalWorkingDirectoryPreference.defaultValue.rawValue
    @SceneStorage("Monknot.isTerminalDrawerOpen") private var terminalPreferredVisible = false
    @State private var isTerminalVisible = false
    @State private var terminalRevealRequest: UInt = 0
    @StateObject private var terminalFocusRestorer = TerminalFocusRestorer()
    @StateObject private var goToLineFocusRestorer = TerminalFocusRestorer()
    @StateObject private var terminalSessions = TerminalSessionCollectionStore()
    @StateObject private var workspaceSearch = WorkspaceSearchState()
    @StateObject private var quickOpen = WorkspaceQuickOpenState()
    @StateObject private var symbolQuickOpen = MarkdownSymbolQuickOpenState()
    @StateObject private var outlineStore = MarkdownOutlineStore()
    @StateObject private var linkInspection = MarkdownLinkInspectionState()
    @State private var isGoToLinePresented = false
    @State private var pendingSourceLocation: MarkdownSourceLocation?
    @State private var pendingPreviewLocation: MarkdownSourceLocation?
    @State private var pendingPDFSearchTarget: WorkspaceSearchPDFTarget?
    @State private var pendingPDFPageNavigationRequest: PDFPageNavigationRequest?
    @State private var pdfPageNavigationSerial = 0
    @State private var pdfNavigatorToggleCommandSerial = 0
    @State private var pdfSelectionSnapshot: PDFSelectionSnapshot?
    @State private var pdfExcerptCopyTask: Task<Void, Never>?
    @State private var markdownEditorSelection: MarkdownEditorSelectionSnapshot?
    @State private var deferredWorkspaceHeadingJump: DeferredWorkspaceHeadingJump?
    @State private var ambiguousMarkdownLinkRequest: AmbiguousMarkdownLinkRequest?
    @State private var missingWikilinkCreationRequest: MissingWikilinkCreationRequest?
    @State private var deferredWorkspaceSourceJump: DeferredWorkspaceSourceJump?
    @State private var tabState = WorkspaceTabState()
    @State private var documentNavigationHistory = DocumentNavigationHistory()
    @State private var restoredTabStateWorkspacePath: String?
    @State private var pendingTabStatePersistenceTask: Task<Void, Never>?
    @State private var documentViewportStates: [String: DocumentViewportState] = [:]
    @State private var restoredViewportStateWorkspacePath: String?
    @State private var pendingViewportStatePersistenceTask: Task<Void, Never>?
    @StateObject private var pdfViewportCaptureBridge = PDFViewportCaptureBridge()
    @State private var pdfUndoCommandSerial = 0
    @State private var pdfRedoCommandSerial = 0
    @State private var canUndoPDFAnnotation = false
    @State private var canRedoPDFAnnotation = false
    @State private var documentSearch = DocumentSearchState()
    @State private var isSidebarVisible = true
    @SceneStorage("Monknot.sidebarPreferredVisible") private var sidebarPreferredVisible = true
    @State private var sidebarRevealRequest: UInt = 0
    @State private var successNotice: SuccessNotice?
    @State private var pendingPDFExportDocument: WorkspaceDocument?
    @State private var pdfExportOptions = MarkdownPDFExportOptions.loadLastUsed()
    @State private var isExportingPDF = false
    @State private var isResolvingUnsavedChanges = false
    @State private var isKeyboardShortcutsHelpPresented = false
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let tabStatePersistence = WorkspaceTabStatePersistence()
    private let viewportStatePersistence = DocumentViewportStatePersistence()

    private var zoomScale: Double {
        get { WorkspaceZoomPolicy.clamp(persistedZoomScale) }
        nonmutating set { persistedZoomScale = WorkspaceZoomPolicy.clamp(newValue) }
    }

    private var editorMode: EditorMode {
        get { EditorMode(rawValue: editorModeRawValue) ?? .source }
        nonmutating set { editorModeRawValue = newValue.rawValue }
    }

    private var themePreference: ThemePreference {
        get { ThemePreference.resolved(rawValue: themePreferenceRawValue) }
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
                terminationCoordinator: terminationCoordinator,
                shouldClose: { await prepareForWindowClose() }
            ))
            .background(KeyboardShortcutMonitor(handler: handleKeyDown))
            .preferredColorScheme(themePreference.preferredColorScheme)
            .accentColor(activeTheme.accentColor)
        )
    }

    private var lifecycleContent: AnyView {
        AnyView(chromeContent
            .onChange(of: store.selectedDocument?.id) { oldDocumentID, newDocumentID in
                dismissGoToLine(restoreFocus: false)
                linkInspection.dismiss()
                missingWikilinkCreationRequest = nil
                if documentNavigationHistory.currentDocumentID != newDocumentID {
                    documentNavigationHistory.replaceCurrent(with: newDocumentID)
                }
                resetPDFAnnotationShortcutState()
                pendingPDFSearchTarget = nil
                cancelPDFExcerptCopy()
                pdfSelectionSnapshot = nil
                markdownEditorSelection = nil
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
                fulfillDeferredWorkspaceHeadingJump()
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
                refreshLinkInspection()
                fulfillDeferredWorkspaceSourceJump()
                fulfillDeferredWorkspaceHeadingJump()
            }
            .onChange(of: store.isDocumentLoading) { _, isLoading in
                if !isLoading {
                    updateOutline()
                }
                fulfillDeferredWorkspaceSourceJump()
                fulfillDeferredWorkspaceHeadingJump()
            }
            .onChange(of: store.documents) { _, documents in
                workspaceSearch.refresh(
                    documents: documents,
                    dirtyTextByDocumentID: store.dirtyTextByDocumentID,
                    dirtyPDFDataByDocumentID: store.dirtyPDFDataByDocumentID
                )
                quickOpen.refresh(documents: documents)
                reconcileTabsWithStore()
                refreshLinkInspection()
            }
            .onChange(of: store.workspaceSearchContentChangeSerial) { _, _ in
                workspaceSearch.refresh(
                    documents: store.documents,
                    dirtyTextByDocumentID: store.dirtyTextByDocumentID,
                    dirtyPDFDataByDocumentID: store.dirtyPDFDataByDocumentID
                )
            }
            .onChange(of: store.workspaceURL?.standardizedFileURL.path ?? "") { previousPath, _ in
                cancelPDFExcerptCopy()
                linkInspection.dismiss()
                if !previousPath.isEmpty {
                    flushPendingViewportStatePersistence(
                        for: URL(fileURLWithPath: previousPath, isDirectory: true)
                    )
                }
                tabState.reset()
                documentNavigationHistory.reset()
                restoredTabStateWorkspacePath = nil
                restoredViewportStateWorkspacePath = nil
                pendingViewportStatePersistenceTask?.cancel()
                pendingViewportStatePersistenceTask = nil
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
                cancelPDFExcerptCopy()
                flushPendingTabStatePersistence()
                flushPendingViewportStatePersistence()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                flushPendingTabStatePersistence()
                flushPendingViewportStatePersistence()
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
            .alert(
                "Create Note?",
                isPresented: Binding(
                    get: { missingWikilinkCreationRequest != nil },
                    set: { if !$0 { missingWikilinkCreationRequest = nil } }
                ),
                presenting: missingWikilinkCreationRequest
            ) { request in
                Button("Create Note") {
                    createMissingWikilink(request)
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {
                    missingWikilinkCreationRequest = nil
                }
            } message: { request in
                Text("Create “\(request.fileName)” at \(request.relativePath)?")
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
            }
    }

    private var rootContentStack: some View {
        ZStack {
            VStack(spacing: 0) {
                MonknotChromePanel(theme: activeTheme, surface: activeTheme.sidebarSurfaceColor) {
                    primaryTitlebar
                }

                WorkspaceSplitView(
                    isSidebarPresented: sidebarPreferredVisible,
                    isTerminalPresented: terminalPreferredVisible,
                    layoutScale: activeTheme.layoutScale(zoomScale: zoomScale),
                    separatorColor: NSColor(activeTheme.separatorColor),
                    accentColor: NSColor(activeTheme.accentColor),
                    sidebarRevealRequest: sidebarRevealRequest,
                    terminalRevealRequest: terminalRevealRequest,
                    onSidebarPresentationChange: { isPresented, userInitiated in
                        handleNativeSidebarPresentationChange(
                            isPresented,
                            userInitiated: userInitiated
                        )
                    },
                    onTerminalPresentationChange: { isPresented, userInitiated in
                        handleNativeTerminalPresentationChange(
                            isPresented,
                            userInitiated: userInitiated
                        )
                    }
                ) {
                    sidebarContent
                } detail: {
                    detailContent
                } terminal: {
                    terminalContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let successNotice {
                SuccessToast(
                    notice: successNotice,
                    theme: activeTheme,
                    showInFinder: {
                        guard let revealURL = successNotice.revealURL else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                        self.successNotice = nil
                    },
                    dismiss: { self.successNotice = nil }
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

            if isGoToLinePresented {
                GoToLineView(
                    theme: activeTheme,
                    zoomScale: zoomScale,
                    close: { dismissGoToLine(restoreFocus: true) },
                    go: goToLine(_:)
                )
                .transition(.opacity)
            }

            if let ambiguousMarkdownLinkRequest {
                AmbiguousMarkdownLinkPicker(
                    documents: ambiguousMarkdownLinkRequest.documentIDs.compactMap(store.document(id:)),
                    theme: activeTheme,
                    zoomScale: zoomScale,
                    close: { self.ambiguousMarkdownLinkRequest = nil },
                    open: { documentID in
                        let request = ambiguousMarkdownLinkRequest
                        self.ambiguousMarkdownLinkRequest = nil
                        openResolvedMarkdownDocument(
                            documentID: documentID,
                            normalizedFragment: request.normalizedFragment,
                            rawFragment: request.rawFragment,
                            preferredMode: request.preferredMode
                        )
                    }
                )
                .transition(.opacity)
            }

        }
        .task(id: successNotice?.id) {
            guard successNotice != nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(MonknotMotion.toastAnimation(reduceMotion: reduceMotion)) {
                successNotice = nil
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
            isTerminalPresented: isTerminalVisible,
            isSidebarVisible: isSidebarVisible,
            isLinkInspectionPresented: linkInspection.isPresented,
            toggleTerminal: { toggleTerminalDrawer(animated: true) },
            toggleSidebar: { toggleSidebar(animated: true) },
            toggleSplitView: toggleMarkdownSplitView,
            toggleLinkInspection: toggleLinkInspection,
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
            openWorkspaceSearchResult: openWorkspaceSearchResult(_:),
            copyRelativePath: copyRelativePath(_:)
        )
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    private var detailContent: some View {
        HStack(spacing: 0) {
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
                contentWidthPercent: contentWidthPercent,
                showsDocumentOutline: showDocumentOutline,
                usePointerCursors: usePointerCursors,
                fontSmoothing: fontSmoothing,
                activeViewportState: activeDocumentViewportState,
                pdfViewportCaptureBridge: pdfViewportCaptureBridge,
                updateViewportState: updateDocumentViewportState(documentID:change:),
                pdfUndoCommandSerial: pdfUndoCommandSerial,
                pdfRedoCommandSerial: pdfRedoCommandSerial,
                updatePDFAnnotationUndoState: updatePDFAnnotationShortcutState(canUndo:canRedo:),
                isTerminalPresented: isTerminalVisible,
                sourceLocation: $pendingSourceLocation,
                previewLocation: $pendingPreviewLocation,
                pdfSearchTarget: $pendingPDFSearchTarget,
                pdfPageNavigationRequest: pendingPDFPageNavigationRequest,
                pdfNavigatorToggleCommandSerial: pdfNavigatorToggleCommandSerial,
                documentSearch: $documentSearch,
                newMarkdown: { store.createMarkdownFile() },
                bootstrapStarterWorkspace: { store.bootstrapStarterWorkspace() },
                openFolder: openFolderPanel,
                closeTerminal: { setTerminalDrawerPresented(false, animated: true) },
                saveDocument: saveSelectedDocument,
                outlineItems: outlineStore.items,
                selectOutlineItem: openOutlineItem(_:),
                onPreviewSourceJump: openSourceFromPreview(location:),
                copyPDFLinkedExcerpt: { selection in
                    updatePDFSelectionSnapshot(selection)
                    copyPDFLinkedExcerpt(selection)
                },
                updatePDFSelectionSnapshot: updatePDFSelectionSnapshot(_:),
                consumePDFPageNavigationRequest: { request in
                    if pendingPDFPageNavigationRequest == request {
                        pendingPDFPageNavigationRequest = nil
                    }
                },
                onMarkdownSelectionChange: handleMarkdownEditorSelection(_:),
                onMarkdownLinkRequest: handleMarkdownEditorLink(_:),
                onMarkdownImagePasteRequest: handleMarkdownImagePaste(_:),
                onMarkdownPreviewLinkRequest: handleMarkdownPreviewLink(_:),
                onMarkdownTaskRequest: handleMarkdownTaskRequest(_:)
            )
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)

            if linkInspection.isPresented, let document = store.selectedDocument, document.kind == .markdown {
                MarkdownLinkInspectionPanel(
                    state: linkInspection,
                    document: document,
                    documentsByID: Dictionary(uniqueKeysWithValues: store.documents.map { ($0.id, $0) }),
                    theme: activeTheme,
                    zoomScale: zoomScale,
                    refresh: { refreshLinkInspection(debounce: false) },
                    close: { linkInspection.dismiss() },
                    openSource: openLinkInspectionSource(documentID:location:),
                    openTarget: openLinkInspectionTarget(documentID:)
                )
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var terminalContent: some View {
        if terminalPreferredVisible {
            TerminalDrawerView(
                sessions: terminalSessions,
                workingDirectory: activeTerminalDirectory,
                workspaceRoot: store.workspaceURL,
                theme: activeTheme,
                zoomScale: zoomScale,
                usePointerCursors: usePointerCursors,
                fontSmoothing: fontSmoothing,
                showsChrome: true,
                close: { setTerminalDrawerPresented(false, animated: true) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(activeTheme.terminalSurfaceColor)
        }
    }

    private var activeTerminalDirectory: URL? {
        TerminalWorkingDirectoryPolicy.directory(
            preference: TerminalWorkingDirectoryPreference(rawValue: terminalWorkingDirectory)
                ?? .defaultValue,
            workspaceURL: store.workspaceURL,
            selectedDocumentURL: store.selectedDocument?.url
        )
    }

    private func copyRelativePath(_ url: URL) {
        guard let workspaceURL = store.workspaceURL else {
            store.errorMessage = "Open a workspace before copying a relative path."
            return
        }
        do {
            let relativePath = try WorkspacePasteboardExportService.copyRelativePath(
                for: url,
                in: workspaceURL
            )
            showSuccessNotice("Copied \(relativePath)")
        } catch {
            store.errorMessage = "Could not copy the relative path: \(error.localizedDescription)"
        }
    }

    private func showSuccessNotice(_ message: String, revealURL: URL? = nil) {
        withAnimation(MonknotMotion.toastAnimation(reduceMotion: reduceMotion)) {
            successNotice = SuccessNotice(message: message, revealURL: revealURL)
        }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
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
            return await saveDocument(id: documentID)
        case .discard:
            if document.kind == .pdf {
                pdfViewportCaptureBridge.cancelActiveFreeTextEdit(documentID: documentID)
            }
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

    private func prepareForWindowClose() async -> Bool {
        guard await resolveAllOpenUnsavedChanges() else { return false }
        flushPendingTabStatePersistence()
        flushPendingViewportStatePersistence()
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

                showSuccessNotice(
                    "Exported \(destinationURL.lastPathComponent)",
                    revealURL: destinationURL
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
        persistViewportStates()
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
        persistViewportStates()
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

        restorePersistedViewportStatesIfNeeded(for: workspaceURL)

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

    private func restorePersistedViewportStatesIfNeeded(for workspaceURL: URL) {
        let workspacePath = workspaceURL.standardizedFileURL.path
        guard restoredViewportStateWorkspacePath != workspacePath else { return }
        restoredViewportStateWorkspacePath = workspacePath

        let availableDocumentIDs = Set(store.documents.map(\.id))
        documentViewportStates = viewportStatePersistence
            .load(for: workspaceURL)
            .filter { availableDocumentIDs.contains($0.key) }
    }

    private func persistViewportStates() {
        guard let workspaceURL = store.workspaceURL?.standardizedFileURL else { return }
        let states = documentViewportStates
        let retainedDocumentIDs = tabState.tabs.map(\.documentID)
        let persistence = viewportStatePersistence

        pendingViewportStatePersistenceTask?.cancel()
        pendingViewportStatePersistenceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            persistence.save(states, retaining: retainedDocumentIDs, for: workspaceURL)
        }
    }

    private func flushPendingViewportStatePersistence(for explicitWorkspaceURL: URL? = nil) {
        captureLivePDFViewportState()
        pendingViewportStatePersistenceTask?.cancel()
        pendingViewportStatePersistenceTask = nil
        guard let workspaceURL = explicitWorkspaceURL?.standardizedFileURL
            ?? store.workspaceURL?.standardizedFileURL
        else { return }
        viewportStatePersistence.save(
            documentViewportStates,
            retaining: tabState.tabs.map(\.documentID),
            for: workspaceURL
        )
    }

    private func captureLivePDFViewportState() {
        guard let capture = pdfViewportCaptureBridge.capture() else { return }
        updateDocumentViewportState(
            documentID: capture.documentID,
            change: .pdfViewportState(capture.state)
        )
    }

    private func commitActiveFreeTextEdit(for documentID: String) {
        pdfViewportCaptureBridge.commitActiveFreeTextEdit(documentID: documentID)
    }

    private func saveSelectedDocument() {
        if let document = store.selectedDocument, document.kind == .pdf {
            commitActiveFreeTextEdit(for: document.id)
        }
        store.saveSelectedFile()
    }

    private func saveAllDocuments() {
        guard canSaveAllDocuments else { return }
        let documentIDs = tabState.tabs.map(\.documentID)
        if let document = store.selectedDocument, document.kind == .pdf {
            commitActiveFreeTextEdit(for: document.id)
        }
        store.errorMessage = nil
        Task {
            _ = await store.saveDocumentsInOrder(documentIDs)
        }
    }

    private var canSaveAllDocuments: Bool {
        guard !store.isBusy, !store.isSaving else { return false }
        if let documentID = store.selectedDocumentID,
           pdfViewportCaptureBridge.hasActiveFreeTextEditor(documentID: documentID) {
            return true
        }
        return tabState.tabs.contains { !store.saveState(for: $0.documentID).isClean }
    }

    private func saveDocument(id documentID: String) async -> Bool {
        if store.document(id: documentID)?.kind == .pdf {
            commitActiveFreeTextEdit(for: documentID)
        }
        return await store.saveDocument(id: documentID)
    }

    private var activeDocumentViewportState: DocumentViewportState? {
        guard let selectedDocumentID = tabState.selectedDocumentID else { return nil }
        return documentViewportStates[selectedDocumentID]
    }

    private func updateDocumentViewportState(documentID: String, change: DocumentViewportStateChange) {
        guard shouldAcceptDocumentViewportUpdate(
            documentID: documentID,
            isCurrentWorkspaceDocument: store.document(id: documentID) != nil,
            removedDirtyDocumentIDs: store.removedDirtyOpenDocumentIDs
        ) else { return }

        var state = documentViewportStates[documentID] ?? DocumentViewportState()

        switch change {
        case .textScrollPosition(let position):
            guard position.isMeaningfullyDifferent(from: state.textScrollPosition) else { return }
            state.textScrollPosition = position
        case .textSelection(let selection):
            guard selection != state.textSelection else { return }
            state.textSelection = selection
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
        persistViewportStates()
    }

    private func pruneDocumentViewportStates() {
        let retainedDocumentIDs = tabState.openDocumentIDs
            .union(store.removedDirtyOpenDocumentIDs)
            .union(store.selectedDocumentID.map { [$0] } ?? [])
        documentViewportStates = documentViewportStates.filter { retainedDocumentIDs.contains($0.key) }
        persistViewportStates()
    }

    private func openSourceFromPreview(location: MarkdownSourceLocation) {
        pendingSourceLocation = location
        editorMode = .source
    }

    private func handleMarkdownEditorSelection(_ selection: MarkdownEditorSelectionSnapshot) {
        guard selection.documentID == store.selectedDocumentID else { return }
        markdownEditorSelection = selection
        updateDocumentViewportState(
            documentID: selection.documentID,
            change: .textSelection(DocumentTextSelection(
                location: selection.selectedRange.location,
                length: selection.selectedRange.length
            ))
        )
    }

    private func handleMarkdownEditorLink(_ request: MarkdownEditorLinkRequest) {
        guard request.documentID == store.selectedDocumentID,
              MarkdownWorkspaceLinkParser().links(in: store.documentText).contains(request.link)
        else {
            store.errorMessage = "The link changed before it could be opened."
            return
        }
        navigateMarkdownLink(
            request.link,
            sourceDocumentID: request.documentID,
            preferredMode: .source
        )
    }

    private func handleMarkdownPreviewLink(_ request: MarkdownPreviewLinkRequest) {
        guard request.identity.documentID == store.selectedDocumentID else { return }
        let link = MarkdownWorkspaceLink(
            kind: request.kind,
            destination: request.destination,
            label: request.destination,
            sourceRange: MarkdownSourceRange(location: 0, length: 0),
            destinationRange: MarkdownSourceRange(location: 0, length: 0)
        )
        navigateMarkdownLink(
            link,
            sourceDocumentID: request.identity.documentID,
            preferredMode: .preview
        )
    }

    private func navigateMarkdownLink(
        _ link: MarkdownWorkspaceLink,
        sourceDocumentID: String,
        preferredMode: EditorMode
    ) {
        guard let workspaceURL = store.workspaceURL,
              let sourceDocument = store.document(id: sourceDocumentID)
        else { return }

        let resolution = MarkdownWorkspaceLinkResolver().resolve(
            link,
            sourceDocument: sourceDocument,
            workspaceRootURL: workspaceURL,
            documents: store.documents
        )
        let rawFragment = link.destinationComponents.fragment?.removingPercentEncoding

        switch resolution {
        case .document(let documentID, let fragment):
            openResolvedMarkdownDocument(
                documentID: documentID,
                normalizedFragment: fragment,
                rawFragment: rawFragment,
                preferredMode: preferredMode
            )
        case .external(let url):
            guard NSWorkspace.shared.open(url) else {
                store.errorMessage = "macOS could not open this link."
                return
            }
        case .ambiguous(let documentIDs):
            ambiguousMarkdownLinkRequest = AmbiguousMarkdownLinkRequest(
                documentIDs: documentIDs,
                normalizedFragment: rawFragment.map(MarkdownHeadingFragment.normalized),
                rawFragment: rawFragment,
                preferredMode: preferredMode
            )
        case .missing:
            guard let currentLink = currentWikilink(
                matching: link,
                sourceDocumentID: sourceDocumentID
            ),
                  let targetURL = MarkdownWorkspaceLinkResolver().missingWikilinkCreationURL(
                      currentLink,
                      sourceDocument: sourceDocument,
                      workspaceRootURL: workspaceURL,
                      documents: store.documents
                  )
            else {
                store.errorMessage = "No workspace document matches this link."
                return
            }
            missingWikilinkCreationRequest = MissingWikilinkCreationRequest(
                sourceDocumentID: sourceDocumentID,
                destination: currentLink.destination,
                targetURL: targetURL,
                relativePath: WorkspaceDocumentSupport.relativePath(for: targetURL, in: workspaceURL)
            )
        case .invalid:
            store.errorMessage = "This link is not a safe workspace or web destination."
        }
    }

    private func createMissingWikilink(_ request: MissingWikilinkCreationRequest) {
        missingWikilinkCreationRequest = nil
        guard let workspaceURL = store.workspaceURL,
              store.selectedDocumentID == request.sourceDocumentID,
              let sourceDocument = store.document(id: request.sourceDocumentID),
              let link = MarkdownWorkspaceLinkParser().links(in: store.documentText).first(where: {
                  $0.kind == .wikilink && $0.destination == request.destination
              }),
              let currentTarget = MarkdownWorkspaceLinkResolver().missingWikilinkCreationURL(
                  link,
                  sourceDocument: sourceDocument,
                  workspaceRootURL: workspaceURL,
                  documents: store.documents
              ),
              currentTarget.standardizedFileURL == request.targetURL.standardizedFileURL
        else {
            store.errorMessage = "The link target changed before the note could be created."
            return
        }
        store.createMarkdownFile(at: currentTarget)
    }

    private func currentWikilink(
        matching link: MarkdownWorkspaceLink,
        sourceDocumentID: String
    ) -> MarkdownWorkspaceLink? {
        guard store.selectedDocumentID == sourceDocumentID else { return nil }
        return MarkdownWorkspaceLinkParser().links(in: store.documentText).first {
            $0.kind == .wikilink && $0.destination == link.destination
        }
    }

    private func openResolvedMarkdownDocument(
        documentID: String,
        normalizedFragment: String?,
        rawFragment: String?,
        preferredMode: EditorMode
    ) {
        guard let document = store.document(id: documentID) else {
            store.errorMessage = "The linked document is no longer available."
            return
        }
        openDocumentTab(id: documentID)

        if document.kind == .pdf, let rawFragment {
            guard let pageNumber = pdfPageNumber(from: rawFragment) else {
                if rawFragment.hasPrefix("page=") {
                    store.errorMessage = "The PDF page link is not valid."
                }
                return
            }
            pdfPageNavigationSerial &+= 1
            pendingPDFPageNavigationRequest = PDFPageNavigationRequest(
                serial: pdfPageNavigationSerial,
                documentID: documentID,
                pageNumber: pageNumber
            )
            return
        }

        guard document.kind == .markdown, let normalizedFragment else { return }
        editorMode = preferredMode
        deferredWorkspaceHeadingJump = DeferredWorkspaceHeadingJump(
            documentID: documentID,
            normalizedFragment: normalizedFragment,
            preferredMode: preferredMode
        )
        fulfillDeferredWorkspaceHeadingJump()
    }

    private func fulfillDeferredWorkspaceHeadingJump() {
        guard let jump = deferredWorkspaceHeadingJump,
              store.selectedDocumentID == jump.documentID,
              !store.isDocumentLoading
        else { return }
        deferredWorkspaceHeadingJump = nil
        guard let location = MarkdownHeadingFragment.sourceLocation(
            for: jump.normalizedFragment,
            in: store.documentText
        ) else {
            store.errorMessage = "The linked heading no longer exists in this document."
            return
        }
        if jump.preferredMode == .preview {
            pendingPreviewLocation = location
        } else {
            pendingSourceLocation = location
        }
    }

    private func handleMarkdownTaskRequest(_ request: MarkdownPreviewTaskRequest) {
        guard request.identity.documentID == store.selectedDocumentID,
              let replacement = MarkdownTaskSourceMutation.replacement(
                in: store.documentText,
                sourceLine: request.sourceLine,
                expectedChecked: request.expectedChecked,
                desiredChecked: request.desiredChecked
              ),
              let undoMutation = store.applyTextMutation(
                documentID: request.identity.documentID,
                range: replacement.range.nsRange,
                expectedText: replacement.expectedText,
                replacement: replacement.replacementText
              )
        else {
            store.errorMessage = "The task changed before it could be updated."
            return
        }
        WorkspaceTextMutationUndo.register(
            undoMutation,
            store: store,
            undoManager: NSApp.keyWindow?.undoManager,
            actionName: "Toggle Task"
        )
    }

    private func handleMarkdownImagePaste(_ request: MarkdownImagePasteRequest) {
        guard request.documentID == store.selectedDocumentID,
              request.sourceText == store.documentText,
              let pngData = WorkspacePasteboardImportService.pngData(for: request.image)
        else {
            store.errorMessage = "The image or insertion point is no longer available."
            return
        }
        store.createMarkdownImageAsset(
            pngData: pngData,
            documentID: request.documentID
        ) { asset in
            request.insertMarkdown(asset.markdown)
        }
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
                    if document.kind == .pdf {
                        commitActiveFreeTextEdit(for: document.id)
                    }
                    store.exportPDFAnnotationsToMarkdown(for: document)
                }
            },
            canExportPDFAnnotationsMarkdown: store.selectedDocument?.kind == .pdf,
            exportAllPDFAnnotationsMarkdown: {
                if let document = store.selectedDocument, document.kind == .pdf {
                    commitActiveFreeTextEdit(for: document.id)
                }
                store.exportAllPDFAnnotationsToMarkdown()
            },
            canExportAllPDFAnnotationsMarkdown: !store.isBusy && store.hasPDFDocuments,
            exportAnnotatedPDFCopy: {
                if let document = store.selectedDocument {
                    if document.kind == .pdf {
                        commitActiveFreeTextEdit(for: document.id)
                    }
                    store.exportAnnotatedPDFCopy(for: document)
                }
            },
            canExportAnnotatedPDFCopy: store.selectedDocument?.kind == .pdf,
            saveDocument: saveSelectedDocument,
            saveAllDocuments: saveAllDocuments,
            canSaveAllDocuments: canSaveAllDocuments,
            undoPDFAnnotation: { pdfUndoCommandSerial &+= 1 },
            canUndoPDFAnnotation: store.selectedDocument?.kind == .pdf && canUndoPDFAnnotation,
            redoPDFAnnotation: { pdfRedoCommandSerial &+= 1 },
            canRedoPDFAnnotation: store.selectedDocument?.kind == .pdf && canRedoPDFAnnotation,
            isPDFDocumentActive: store.selectedDocument?.kind == .pdf,
            cut: { _ = cutFromCommand() },
            copy: { _ = copyFromCommand() },
            copyRenderedMarkdown: {
                _ = MonknotNativeMarkdownCommand.copyRenderedSelection()
            },
            canCopyRenderedMarkdown: canCopyRenderedMarkdown,
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
            showGoToLine: showGoToLine,
            canShowGoToLine: canShowGoToLine,
            toggleLinkInspection: toggleLinkInspection,
            canInspectLinks: canInspectLinks,
            findNext: { documentSearch.findNext() },
            findPrevious: { documentSearch.findPrevious() },
            toggleTerminal: { toggleTerminalDrawer(animated: false) },
            toggleSidebar: { toggleSidebar(animated: false) },
            toggleSplitView: { toggleMarkdownSplitView() },
            canToggleSplitView: canToggleMarkdownSplitView,
            togglePDFNavigator: {
                pdfNavigatorToggleCommandSerial &+= 1
            },
            canTogglePDFNavigator: store.selectedDocument?.kind == .pdf,
            copyPDFLinkedExcerpt: {
                if let pdfSelectionSnapshot,
                   pdfSelectionSnapshot.documentID == store.selectedDocumentID {
                    copyPDFLinkedExcerpt(pdfSelectionSnapshot)
                }
            },
            canCopyPDFLinkedExcerpt: store.selectedDocument?.kind == .pdf
                && pdfSelectionSnapshot?.documentID == store.selectedDocumentID,
            showKeyboardShortcutsHelp: {
                dismissGoToLine(restoreFocus: false)
                isKeyboardShortcutsHelpPresented = true
            },
            undoWorkspaceReplace: { store.undoLastWorkspaceReplace() },
            canUndoWorkspaceReplace: store.canUndoWorkspaceReplace && !store.isBusy
        )
    }

    private var canToggleMarkdownSplitView: Bool {
        guard !store.isBusy else { return false }
        return supportsSplitView(store.selectedDocument)
    }

    private var canCopyRenderedMarkdown: Bool {
        guard MonknotNativeMarkdownCommand.canCopyRenderedSelection,
              let selection = markdownEditorSelection,
              selection.documentID == store.selectedDocumentID,
              selection.selectedRange.length > 0,
              NSMaxRange(selection.selectedRange) <= (store.documentText as NSString).length
        else { return false }
        return (store.documentText as NSString).substring(with: selection.selectedRange)
            == selection.selectedMarkdown
    }

    private func supportsSplitView(_ document: WorkspaceDocument?) -> Bool {
        guard let document else { return false }
        return document.kind == .markdown || document.capabilities.canPreviewHTML
    }

    private func toggleMarkdownSplitView() {
        guard canToggleMarkdownSplitView else { return }
        isMarkdownSplitViewEnabled.toggle()
    }

    private var canInspectLinks: Bool {
        store.workspaceURL != nil
            && store.selectedDocument?.kind == .markdown
            && !store.isBusy
            && !store.isDocumentLoading
    }

    private var linkInspectionTextSnapshot: [String: String] {
        var texts = store.dirtyTextByDocumentID
        if let documentID = store.selectedDocumentID {
            texts[documentID] = store.documentText
        }
        return texts
    }

    private func toggleLinkInspection() {
        if linkInspection.isPresented {
            linkInspection.dismiss()
            return
        }
        guard canInspectLinks,
              let document = store.selectedDocument,
              let workspaceURL = store.workspaceURL
        else { return }
        linkInspection.present(
            document: document,
            workspaceRootURL: workspaceURL,
            documents: store.documents,
            textByDocumentID: linkInspectionTextSnapshot
        )
    }

    private func refreshLinkInspection(debounce: Bool = true) {
        guard linkInspection.isPresented,
              let document = store.selectedDocument,
              document.kind == .markdown,
              let workspaceURL = store.workspaceURL
        else { return }
        linkInspection.refresh(
            document: document,
            workspaceRootURL: workspaceURL,
            documents: store.documents,
            textByDocumentID: linkInspectionTextSnapshot,
            debounce: debounce
        )
    }

    private func openLinkInspectionSource(
        documentID: String,
        location: MarkdownSourceLocation
    ) {
        linkInspection.dismiss()
        editorMode = .source
        deferredWorkspaceSourceJump = DeferredWorkspaceSourceJump(
            documentID: documentID,
            location: location
        )
        openDocumentTab(id: documentID)
        fulfillDeferredWorkspaceSourceJump()
    }

    private func openLinkInspectionTarget(documentID: String) {
        linkInspection.dismiss()
        openDocumentTab(id: documentID)
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

        if (action == .undoWorkspaceReplace
            || action == .undoPDFAnnotation
            || action == .redoPDFAnnotation),
           MonknotNativePasteboardCommand.hasNativeEditingFocus {
            return false
        }

        if (action == .undoPDFAnnotation || action == .redoPDFAnnotation),
           let documentID = store.selectedDocumentID,
           pdfViewportCaptureBridge.hasActiveFreeTextEditor(documentID: documentID) {
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
            isLinkInspectionPresented: linkInspection.isPresented,
            hasMarkdownOutline: store.selectedDocument?.kind == .markdown && !outlineStore.items.isEmpty,
            canToggleSplitView: canToggleMarkdownSplitView,
            canInspectLinks: canInspectLinks,
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
            saveSelectedDocument()
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
        case .dismissKeyboardShortcutsHelp:
            isKeyboardShortcutsHelpPresented = false
        case .toggleSplitView:
            toggleMarkdownSplitView()
        case .toggleLinkInspection:
            toggleLinkInspection()
        case .dismissLinkInspection:
            linkInspection.dismiss()
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
        dismissGoToLine(restoreFocus: false)
        symbolQuickOpen.dismiss()
        workspaceSearch.dismiss()
        quickOpen.present(documents: store.documents)
    }

    private func showGoToSymbol() {
        guard store.selectedDocument?.kind == .markdown, !outlineStore.items.isEmpty else { return }
        isKeyboardShortcutsHelpPresented = false
        dismissGoToLine(restoreFocus: false)
        quickOpen.dismiss()
        workspaceSearch.dismiss()
        symbolQuickOpen.present(items: outlineStore.items)
    }

    private func showGoToLine() {
        guard canShowGoToLine else { return }
        isKeyboardShortcutsHelpPresented = false
        quickOpen.dismiss()
        symbolQuickOpen.dismiss()
        workspaceSearch.dismiss()
        goToLineFocusRestorer.capture(from: NSApp.keyWindow)
        isGoToLinePresented = true
    }

    private func dismissGoToLine(restoreFocus: Bool) {
        guard isGoToLinePresented else { return }
        isGoToLinePresented = false
        if restoreFocus {
            goToLineFocusRestorer.restore(fallbackFrom: NSApp.keyWindow)
        } else {
            goToLineFocusRestorer.discard()
        }
    }

    private var canShowGoToLine: Bool {
        store.selectedDocument?.capabilities.canEditText == true
            && !store.isBusy
            && !store.isDocumentLoading
    }

    private func goToLine(_ input: String) -> String? {
        switch MarkdownSourceLocationInputParser.parse(input, in: store.documentText) {
        case let .success(location):
            isGoToLinePresented = false
            goToLineFocusRestorer.discard()
            editorMode = .source
            pendingSourceLocation = location
            return nil
        case .failure(.invalidFormat):
            return "Enter a line or line:column. Numbers start at 1."
        case let .failure(.lineOutOfRange(maximum)):
            return "Line must be between 1 and \(maximum)."
        case let .failure(.columnOutOfRange(maximum)):
            return "Column must be between 1 and \(maximum)."
        }
    }

    private func showDocumentSearch() {
        guard canShowDocumentSearch else { return }
        dismissGoToLine(restoreFocus: false)
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
        dismissGoToLine(restoreFocus: false)
        requestSidebarPresentation(true, animated: false)
        workspaceSearch.present(
            documents: store.documents,
            dirtyTextByDocumentID: store.dirtyTextByDocumentID,
            dirtyPDFDataByDocumentID: store.dirtyPDFDataByDocumentID
        )
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

    private func copyPDFLinkedExcerpt(_ selection: PDFSelectionSnapshot) {
        cancelPDFExcerptCopy()

        guard let workspaceURL = store.workspaceURL?.standardizedFileURL,
              store.selectedDocumentID == selection.documentID,
              let sourceDocument = store.document(id: selection.documentID),
              sourceDocument.kind == .pdf,
              selection.contentVersion == store.pdfContentVersion(for: selection.documentID)
        else {
            store.errorMessage = "The PDF source or selection is no longer available. Select the text again and retry."
            return
        }

        let sourceURL = sourceDocument.url.standardizedFileURL
        let sourceRelativePath = sourceDocument.relativePath
        let dirtyPDFData = store.dirtyPDFData(for: sourceDocument.id)
        let dirtyPDFEditVersion = store.dirtyPDFEditVersion(for: sourceDocument.id)
        guard (dirtyPDFData == nil) == (dirtyPDFEditVersion == nil),
              let sourceRevision = PDFLinkedExcerptSourceRevision.capture(
                sourceURL: sourceURL,
                workspaceURL: workspaceURL,
                expectedRelativePath: sourceRelativePath,
                dirtyEditVersion: dirtyPDFEditVersion
              )
        else {
            store.errorMessage = "The PDF source or selection is no longer available. Select the text again and retry."
            return
        }

        pdfExcerptCopyTask = Task { @MainActor in
            let validationTask = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let data: Data
                if let dirtyPDFData {
                    data = dirtyPDFData
                } else {
                    do {
                        data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
                    } catch {
                        throw PDFLinkedExcerptSourceValidationError.unreadablePDF
                    }
                }
                try Task.checkCancellation()
                let markdown = try PDFLinkedExcerptFormatter().validatedMarkdown(
                    for: selection,
                    sourceRelativePath: sourceRelativePath,
                    pdfData: data
                )
                if dirtyPDFData == nil {
                    guard let currentData = try? Data(contentsOf: sourceURL, options: [.mappedIfSafe]),
                          currentData == data
                    else {
                        throw PDFLinkedExcerptSourceValidationError.selectionChanged
                    }
                }
                return markdown
            }

            let markdown: String
            do {
                markdown = try await withTaskCancellationHandler {
                    try await validationTask.value
                } onCancel: {
                    validationTask.cancel()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                pdfExcerptCopyTask = nil
                store.errorMessage = "The linked excerpt was not copied: \(error.localizedDescription)"
                return
            }

            guard !Task.isCancelled else { return }
            pdfExcerptCopyTask = nil
            let currentSourceDocument = store.document(id: selection.documentID)
            guard store.workspaceURL?.standardizedFileURL == workspaceURL,
                  store.selectedDocumentID == selection.documentID,
                  currentSourceDocument?.kind == .pdf,
                  currentSourceDocument?.url.standardizedFileURL == sourceURL,
                  currentSourceDocument?.relativePath == sourceRelativePath,
                  selection.contentVersion == store.pdfContentVersion(for: selection.documentID),
                  pdfSelectionSnapshot == selection
            else {
                store.errorMessage = "The PDF source or selection changed before the excerpt was copied. The clipboard was not changed."
                return
            }

            guard sourceRevision.stillMatches(
                sourceURL: sourceURL,
                workspaceURL: workspaceURL,
                expectedRelativePath: sourceRelativePath,
                dirtyEditVersion: store.dirtyPDFEditVersion(for: selection.documentID)
            ) else {
                store.errorMessage = "The PDF source or annotation edits changed before the excerpt was copied. The clipboard was not changed."
                return
            }

            do {
                try WorkspacePasteboardExportService.copyPlainText(markdown)
                showSuccessNotice("Copied linked excerpt")
            } catch {
                store.errorMessage = "Could not copy the linked excerpt: \(error.localizedDescription)"
            }
        }
    }

    private func updatePDFSelectionSnapshot(_ snapshot: PDFSelectionSnapshot?) {
        guard pdfSelectionSnapshot != snapshot else { return }
        cancelPDFExcerptCopy()
        pdfSelectionSnapshot = snapshot
    }

    private func cancelPDFExcerptCopy() {
        pdfExcerptCopyTask?.cancel()
        pdfExcerptCopyTask = nil
    }

    private func fulfillDeferredWorkspaceSourceJump() {
        guard let deferredWorkspaceSourceJump else { return }
        guard store.selectedDocumentID == deferredWorkspaceSourceJump.documentID else { return }
        guard !store.isDocumentLoading else { return }

        self.deferredWorkspaceSourceJump = nil
        guard let location = MarkdownSourceLocationValidator.validated(
            deferredWorkspaceSourceJump.location,
            in: store.documentText
        ) else {
            store.errorMessage = "The requested line or column no longer exists in this document."
            return
        }
        pendingSourceLocation = location
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
        setTerminalDrawerPresented(!isTerminalVisible, animated: animated)
    }

    private func setTerminalDrawerPresented(_ isPresented: Bool, animated: Bool) {
        guard terminalPreferredVisible != isPresented || isTerminalVisible != isPresented else { return }
        let wasEffectivelyVisible = isTerminalVisible
        if isPresented {
            terminalFocusRestorer.capture(from: NSApp.keyWindow)
        }
        updateChromeState(animated: animated) {
            terminalPreferredVisible = isPresented
            if isPresented {
                terminalRevealRequest &+= 1
            } else {
                isTerminalVisible = false
            }
        }
        if !isPresented {
            if wasEffectivelyVisible {
                terminalFocusRestorer.restore(fallbackFrom: NSApp.keyWindow)
            } else {
                terminalFocusRestorer.discard()
            }
        }
    }

    private func handleNativeTerminalPresentationChange(
        _ isPresented: Bool,
        userInitiated: Bool
    ) {
        let updatesPreference = userInitiated && terminalPreferredVisible != isPresented
        let updatesEffectiveState = isTerminalVisible != isPresented
        guard updatesPreference || updatesEffectiveState else {
            if !userInitiated, !isPresented, terminalPreferredVisible {
                // A forced native report after an infeasible explicit reveal
                // cancels the focus capture without moving keyboard focus.
                terminalFocusRestorer.discard()
            }
            return
        }

        if userInitiated, isPresented {
            terminalFocusRestorer.capture(from: NSApp.keyWindow)
        }

        let shouldRestoreDocumentFocus = isTerminalVisible && !isPresented
        updateChromeState(animated: false) {
            if userInitiated {
                terminalPreferredVisible = isPresented
            }
            isTerminalVisible = isPresented
        }
        if shouldRestoreDocumentFocus {
            terminalFocusRestorer.restore(fallbackFrom: NSApp.keyWindow)
        }
    }

    private func toggleSidebar(animated: Bool) {
        requestSidebarPresentation(!isSidebarVisible, animated: animated)
    }

    private func requestSidebarPresentation(_ isPresented: Bool, animated: Bool) {
        guard sidebarPreferredVisible != isPresented || isSidebarVisible != isPresented else { return }
        updateChromeState(animated: animated) {
            sidebarPreferredVisible = isPresented
            if isPresented {
                sidebarRevealRequest &+= 1
            } else {
                isSidebarVisible = false
            }
        }
    }

    private func handleNativeSidebarPresentationChange(
        _ isPresented: Bool,
        userInitiated: Bool
    ) {
        let updatesPreference = userInitiated && sidebarPreferredVisible != isPresented
        let updatesEffectiveState = isSidebarVisible != isPresented
        guard updatesPreference || updatesEffectiveState else { return }
        updateChromeState(animated: false) {
            if userInitiated {
                sidebarPreferredVisible = isPresented
            }
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

func shouldAcceptDocumentViewportUpdate(
    documentID: String,
    isCurrentWorkspaceDocument: Bool,
    removedDirtyDocumentIDs: Set<String>
) -> Bool {
    isCurrentWorkspaceDocument || removedDirtyDocumentIDs.contains(documentID)
}

func pdfPageNumber(from fragment: String) -> Int? {
    let expression = try? NSRegularExpression(pattern: #"^page=([1-9][0-9]*)$"#)
    let range = NSRange(location: 0, length: (fragment as NSString).length)
    guard let match = expression?.firstMatch(in: fragment, range: range),
          let valueRange = Range(match.range(at: 1), in: fragment),
          let page = Int(fragment[valueRange]),
          page > 0
    else { return nil }
    return page
}

@MainActor
enum WorkspaceTextMutationUndo {
    static func register(
        _ mutation: WorkspaceTextMutation,
        store: WorkspaceStore,
        undoManager: UndoManager?,
        actionName: String
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: store) { target in
            MainActor.assumeIsolated {
                guard let inverse = target.applyTextMutation(
                    documentID: mutation.documentID,
                    range: mutation.range,
                    expectedText: mutation.expectedText,
                    replacement: mutation.replacement
                ) else {
                    NSSound.beep()
                    return
                }
                register(
                    inverse,
                    store: target,
                    undoManager: undoManager,
                    actionName: actionName
                )
            }
        }
        undoManager.setActionName(actionName)
    }
}

private struct SuccessNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let revealURL: URL?
}

private struct SuccessToast: View {
    let notice: SuccessNotice
    let theme: AppTheme
    let showInFinder: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: theme.semanticColors.diffAdded))
                .accessibilityHidden(true)

            Text(notice.message)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.foregroundColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 230, alignment: .leading)
                .accessibilityLabel(notice.message)

            if notice.revealURL != nil {
                Button("Show in Finder", action: showInFinder)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.accentColor)
                    .monknotPointerCursor()
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss notification")
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

private struct DeferredWorkspaceHeadingJump: Equatable {
    let documentID: String
    let normalizedFragment: String
    let preferredMode: EditorMode
}

private struct AmbiguousMarkdownLinkRequest: Equatable {
    let documentIDs: [String]
    let normalizedFragment: String?
    let rawFragment: String?
    let preferredMode: EditorMode
}

private struct MissingWikilinkCreationRequest: Equatable {
    let sourceDocumentID: String
    let destination: String
    let targetURL: URL
    let relativePath: String

    var fileName: String {
        targetURL.lastPathComponent
    }
}

private struct AmbiguousMarkdownLinkPicker: View {
    let documents: [WorkspaceDocument]
    let theme: AppTheme
    let zoomScale: Double
    let close: () -> Void
    let open: (String) -> Void
    @FocusState private var focusedDocumentID: String?

    private func scaled(_ value: CGFloat) -> CGFloat {
        MonknotMetrics.scale(value, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        MonknotCommandOverlay(
            theme: theme,
            zoomScale: zoomScale,
            panelHeight: scaled(CGFloat(52 + min(max(documents.count, 1), 8) * 40)),
            close: close
        ) {
            VStack(spacing: 0) {
                HStack {
                    Text("Choose Linked Note")
                        .font(.system(size: scaled(13), weight: .medium))
                        .foregroundStyle(theme.foregroundColor)
                    Spacer()
                    MonknotCommandOverlayEscapeButton(theme: theme, close: close)
                }
                .padding(.horizontal, scaled(14))
                .frame(height: scaled(44))

                Divider().overlay(theme.separatorColor)

                ScrollView {
                    LazyVStack(spacing: scaled(2)) {
                        ForEach(documents) { document in
                            Button {
                                open(document.id)
                            } label: {
                                HStack(spacing: scaled(8)) {
                                    Image(systemName: document.kind.resolvedSystemImage)
                                        .foregroundStyle(theme.mutedForegroundColor)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(document.displayName)
                                            .foregroundStyle(theme.foregroundColor)
                                        Text(document.relativePath)
                                            .font(.caption)
                                            .foregroundStyle(theme.tertiaryForegroundColor)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, scaled(12))
                                .frame(height: scaled(38))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focused($focusedDocumentID, equals: document.id)
                            .monknotPointerCursor()
                        }
                    }
                    .padding(scaled(6))
                }
            }
        }
        .onAppear {
            focusedDocumentID = documents.first?.id
        }
    }
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
