import AppKit
import MonknotCore
import SwiftUI

struct EditorPaneView: View {
    @ObservedObject var store: WorkspaceStore
    @Binding var editorMode: EditorMode
    @Binding var isSplitViewEnabled: Bool
    @AppStorage("Monknot.terminalDrawerWidth") private var terminalDrawerWidth = 420.0
    @StateObject private var terminalSessions = TerminalSessionCollectionStore()
    @State private var markdownCommandSerial = 0
    @State private var markdownCommandRequest: MarkdownTextEditorCommandRequest?
    @State private var splitScrollSyncLock = false
    @State private var splitSourcePaneRatio = DocumentSplitViewPersistence.defaultSourcePaneRatio
    @State private var previewSyncLine: Int?
    @State private var sourceSyncLine: Int?
    let theme: AppTheme
    let zoomScale: Double
    let codeFontSize: CGFloat
    let previewWidthPercent: Double
    let usePointerCursors: Bool
    let fontSmoothing: Bool
    let tabs: [WorkspaceTabItem]
    let activeTabID: String?
    let activeViewportState: DocumentViewportState?
    let missingTabIDs: Set<String>
    let selectTab: (String) -> Void
    let closeTab: (String) -> Void
    let togglePinTab: (String) -> Void
    let reorderTab: (String, String?) -> Void
    let updateViewportState: (String, DocumentViewportStateChange) -> Void
    let pdfUndoCommandSerial: Int
    let pdfRedoCommandSerial: Int
    let updatePDFAnnotationUndoState: (Bool, Bool) -> Void
    @Binding var isTerminalPresented: Bool
    @Binding var sourceLocation: MarkdownSourceLocation?
    @Binding var previewLocation: MarkdownSourceLocation?
    @Binding var pdfSearchTarget: WorkspaceSearchPDFTarget?
    @Binding var documentSearch: DocumentSearchState
    let isSidebarVisible: Bool
    let newMarkdown: () -> Void
    let bootstrapStarterWorkspace: () -> Void
    let openFolder: () -> Void
    let toggleTerminal: () -> Void
    let toggleSidebar: () -> Void
    let outlineItems: [MarkdownOutlineItem]
    let selectOutlineItem: (MarkdownOutlineItem) -> Void
    let toggleSplitView: () -> Void
    let canToggleSplitView: Bool
    let onPreviewSourceJump: (MarkdownSourceLocation) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            editorAndDrawer(in: proxy.size)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(theme.surfaceColor)
        .onExitCommand {
            if documentSearch.isPresented {
                documentSearch.dismiss()
                return
            }
            guard isTerminalPresented else { return }
            setTerminalPresented(false)
        }
        .onAppear {
            terminalSessions.setDefaultDirectory(activeTerminalDirectory)
            if let documentID = store.selectedDocument?.id,
               supportsSplitViewRatioPersistence(forDocumentID: documentID) {
                splitSourcePaneRatio = DocumentSplitViewPersistence.sourcePaneRatio(forDocumentPath: documentID)
            }
        }
        .onChange(of: store.workspaceURL) { _, _ in
            terminalSessions.setDefaultDirectory(activeTerminalDirectory)
        }
        .onChange(of: store.selectedDocument?.id) { oldDocumentID, newDocumentID in
            if let oldDocumentID,
               supportsSplitViewRatioPersistence(forDocumentID: oldDocumentID) {
                DocumentSplitViewPersistence.setSourcePaneRatio(
                    splitSourcePaneRatio,
                    forDocumentPath: oldDocumentID
                )
            }
            if let newDocumentID,
               supportsSplitViewRatioPersistence(forDocumentID: newDocumentID) {
                splitSourcePaneRatio = DocumentSplitViewPersistence.sourcePaneRatio(forDocumentPath: newDocumentID)
            } else {
                splitSourcePaneRatio = DocumentSplitViewPersistence.defaultSourcePaneRatio
            }
            terminalSessions.setDefaultDirectory(activeTerminalDirectory)
        }
    }

    @ViewBuilder
    private func editorAndDrawer(in size: CGSize) -> some View {
        let isCompact = size.width < MonknotMetrics.compactLayoutBreakpoint
        let drawerWidth = terminalDrawerWidth(for: size.width)

        if isCompact {
            ZStack(alignment: .trailing) {
                editorColumn

                if isTerminalPresented {
                    theme.scrimColor
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture {
                            setTerminalPresented(false)
                        }
                        .accessibilityHidden(true)

                    resizableTerminalDrawer(
                        width: drawerWidth,
                        maxWidth: drawerMaxWidth(for: size.width),
                        close: { setTerminalPresented(false) }
                    )
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
                }
            }
            .animation(drawerAnimation, value: isTerminalPresented)
        } else {
            wideLayout(
                drawerWidth: drawerWidth,
                maxDrawerWidth: drawerMaxWidth(for: size.width)
            )
            .animation(drawerAnimation, value: isTerminalPresented)
        }
    }

    private var showsMarkdownSourceSubchrome: Bool {
        guard store.selectedDocument?.kind == .markdown else { return false }
        return editorMode == .source || isSplitViewEnabled
    }

    private func supportsSplitViewRatioPersistence(forDocumentID documentID: String) -> Bool {
        guard let document = store.document(id: documentID) else { return false }
        return document.kind == .markdown || document.capabilities.canPreviewHTML
    }

    /// Keep the editor and terminal as independent columns. Both primary
    /// chrome rows use the same shared height, while an editor-only formatting
    /// row must not reserve empty space above the terminal.
    private func wideLayout(drawerWidth: CGFloat, maxDrawerWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            editorColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

            if isTerminalPresented {
                resizableTerminalDrawer(
                    width: drawerWidth,
                    maxWidth: maxDrawerWidth,
                    close: { setTerminalPresented(false) }
                )
                .transition(.move(edge: .trailing))
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            editorChromePanel

            editorContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var editorChromePanel: some View {
        MonknotChromePanel(theme: theme) {
            VStack(spacing: 0) {
                editorPrimaryChrome

                if showsMarkdownSourceSubchrome {
                    MonknotChromeDivider(theme: theme)
                    MarkdownSourceToolbar(
                        theme: theme,
                        zoomScale: zoomScale,
                        sendCommand: sendMarkdownCommand
                    )
                }
            }
        }
    }

    private var editorPrimaryChrome: some View {
        TopNavigationBar(
            editorMode: $editorMode,
            isSplitViewEnabled: $isSplitViewEnabled,
            emptyStateTitle: store.workspaceURL?.lastPathComponent ?? "Monknot",
            selectedDocument: store.selectedDocument,
            isBusy: store.isBusy,
            isDocumentLoading: store.isDocumentLoading,
            isSaving: store.isSaving,
            theme: theme,
            zoomScale: zoomScale,
            isTerminalPresented: isTerminalPresented,
            isSidebarVisible: isSidebarVisible,
            toggleTerminal: toggleTerminal,
            toggleSidebar: toggleSidebar,
            outlineItems: outlineItems,
            selectOutlineItem: selectOutlineItem,
            toggleSplitView: toggleSplitView,
            canToggleSplitView: canToggleSplitView,
            documentSearch: $documentSearch,
            tabs: tabs,
            activeTabID: activeTabID,
            missingTabIDs: missingTabIDs,
            saveState: { store.saveState(for: $0) },
            selectTab: selectTab,
            closeTab: closeTab,
            togglePinTab: togglePinTab,
            reorderTab: reorderTab
        )
    }

    private func sendMarkdownCommand(_ command: MarkdownTextEditorCommand) {
        markdownCommandSerial += 1
        markdownCommandRequest = MarkdownTextEditorCommandRequest(
            serial: markdownCommandSerial,
            command: command
        )
    }

    private func resizableTerminalDrawer(
        width: CGFloat,
        maxWidth: CGFloat,
        close: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 0) {
            middleContentTrailingDivider

            TerminalDrawerView(
                sessions: terminalSessions,
                workingDirectory: activeTerminalDirectory,
                theme: theme,
                zoomScale: zoomScale,
                usePointerCursors: usePointerCursors,
                fontSmoothing: fontSmoothing,
                close: close
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width)
        .background(theme.contentSurfaceColor)
        .overlay(alignment: .leading) {
            TerminalResizeHandle(
                width: $terminalDrawerWidth,
                minWidth: terminalDrawerMinWidth,
                maxWidth: maxWidth
            )
            .frame(width: terminalResizeHitWidth)
            .offset(x: -terminalResizeHitWidth / 2)
        }
    }

    private var terminalResizeHitWidth: CGFloat {
        20
    }

    /// The editor owns the single boundary line between the middle content
    /// and the trailing drawer. The drawer itself does not draw an edge.
    private var middleContentTrailingDivider: some View {
        Rectangle()
            .fill(theme.separatorColor)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }

    private var activeTerminalDirectory: URL? {
        TerminalWorkingDirectoryPolicy.directory(
            workspaceURL: store.workspaceURL,
            selectedDocumentURL: store.selectedDocument?.url
        )
    }

    @ViewBuilder
    private var editorContent: some View {
        VStack(spacing: 0) {
            if store.selectedDocumentExternalChange {
                ExternalDocumentChangeBanner(
                    isRemovedExternally: store.isSelectedDocumentRemovedExternally,
                    isSaving: store.isSaving,
                    theme: theme,
                    zoomScale: zoomScale,
                    reload: { store.reloadSelectedDocumentFromDisk() },
                    keepEditing: { store.acknowledgeExternalChange() },
                    save: { store.saveSelectedFile() }
                )
            }

            if let selectedDocument = store.selectedDocument {
                if store.isDocumentLoading, selectedDocument.capabilities.canEditText {
                    DocumentLoadingPlaceholder(
                        documentName: selectedDocument.displayName,
                        theme: theme,
                        zoomScale: zoomScale
                    )
                } else {
                    editor(for: selectedDocument)
                }
            } else {
                EmptyDetailView(
                    theme: theme,
                    zoomScale: zoomScale,
                    hasWorkspace: store.workspaceURL != nil,
                    isLoadingWorkspace: store.isWorkspaceOpening,
                    canBootstrapStarterWorkspace: store.canBootstrapStarterWorkspace,
                    newMarkdown: newMarkdown,
                    bootstrapStarterWorkspace: bootstrapStarterWorkspace,
                    openFolder: openFolder
                )
            }
        }
    }

    @ViewBuilder
    private func editor(for selectedDocument: WorkspaceDocument) -> some View {
        switch selectedDocument.kind {
        case .markdown:
            markdownEditor(for: selectedDocument)
        case .text:
            if selectedDocument.capabilities.canPreviewHTML {
                htmlEditor(for: selectedDocument)
            } else {
                textEditor(for: selectedDocument)
            }
        case .pdf:
            PDFPreviewView(
                document: selectedDocument,
                theme: theme,
                zoomScale: zoomScale,
                saveState: store.saveState(for: selectedDocument.id),
                dirtyData: store.dirtyPDFData(for: selectedDocument.id),
                viewportPosition: activeViewportState?.pdfPosition,
                externalUndoCommandSerial: pdfUndoCommandSerial,
                externalRedoCommandSerial: pdfRedoCommandSerial,
                searchState: $documentSearch,
                searchTarget: $pdfSearchTarget,
                markEdited: { previousData, data in
                    store.markPDFDocumentEdited(
                        id: selectedDocument.id,
                        previousData: previousData,
                        data: data
                    )
                },
                reportError: { message in
                    store.reportPDFAnnotationError(message)
                },
                saveDocument: {
                    store.saveSelectedFile()
                },
                onViewportPositionChange: { position in
                    updateViewportState(selectedDocument.id, .pdfPosition(position))
                },
                updateAnnotationUndoState: updatePDFAnnotationUndoState
            )
        case .media, .nativePreview, .unsupported:
            UnsupportedDocumentView(
                document: selectedDocument,
                theme: theme,
                zoomScale: zoomScale
            )
            .help(selectedDocument.relativePath)
        }
    }

    @ViewBuilder
    private func htmlEditor(for selectedDocument: WorkspaceDocument) -> some View {
        if isSplitViewEnabled {
            HSplitView {
                htmlSourceEditor(for: selectedDocument)
                    .frame(minWidth: 240)
                    .background(
                        splitViewRatioAccessor(for: selectedDocument)
                    )
                htmlPreviewPane(for: selectedDocument)
                    .frame(minWidth: 240)
            }
        } else {
            switch editorMode {
            case .source:
                htmlSourceEditor(for: selectedDocument)
            case .preview:
                htmlPreviewPane(for: selectedDocument)
            }
        }
    }

    private func htmlSourceEditor(for selectedDocument: WorkspaceDocument) -> some View {
        MarkdownTextEditor(
            documentID: selectedDocument.id,
            text: Binding(
                get: { store.documentText },
                set: { store.setDocumentText($0) }
            ),
            theme: theme,
            fontSize: codeFontSize * zoomScale,
            fontSmoothing: fontSmoothing,
            scrollPosition: activeViewportState?.textScrollPosition,
            sourceLocation: $sourceLocation,
            searchState: $documentSearch,
            onScrollPositionChange: { position in
                updateViewportState(selectedDocument.id, .textScrollPosition(position))
            },
            syncScrollEnabled: isSplitViewEnabled,
            syncScrollTargetLine: sourceSyncLine,
            onVisibleTopLineChange: { line in
                syncHTMLPreviewScroll(to: line, in: store.documentText)
            }
        )
        .help(selectedDocument.relativePath)
    }

    private func htmlPreviewPane(for selectedDocument: WorkspaceDocument) -> some View {
        HTMLPreviewView(
            documentID: selectedDocument.id,
            html: store.documentText,
            baseURL: URL(fileURLWithPath: selectedDocument.id).deletingLastPathComponent(),
            theme: theme,
            zoomScale: zoomScale,
            scrollPosition: activeViewportState?.htmlPreviewScrollPosition,
            syncScrollEnabled: isSplitViewEnabled,
            syncScrollTargetLine: previewSyncLine,
            sourceLineCount: HTMLScrollSync.totalLines(in: store.documentText),
            searchState: $documentSearch,
            onScrollPositionChange: { position in
                updateViewportState(selectedDocument.id, .htmlPreviewScrollPosition(position))
            },
            onVisibleSourceLineChange: { line in
                syncSourceScroll(to: line)
            }
        )
        .help(selectedDocument.relativePath)
    }

    private func textEditor(for selectedDocument: WorkspaceDocument) -> some View {
        MarkdownTextEditor(
            documentID: selectedDocument.id,
            text: Binding(
                get: { store.documentText },
                set: { store.setDocumentText($0) }
            ),
            theme: theme,
            fontSize: codeFontSize * zoomScale,
            fontSmoothing: fontSmoothing,
            scrollPosition: activeViewportState?.textScrollPosition,
            sourceLocation: $sourceLocation,
            searchState: $documentSearch,
            onScrollPositionChange: { position in
                updateViewportState(selectedDocument.id, .textScrollPosition(position))
            }
        )
        .help(selectedDocument.relativePath)
    }

    @ViewBuilder
    private func markdownEditor(for selectedDocument: WorkspaceDocument) -> some View {
        if isSplitViewEnabled {
            HSplitView {
                markdownSourceEditor(for: selectedDocument)
                    .frame(minWidth: 240)
                    .background(
                        splitViewRatioAccessor(for: selectedDocument)
                    )
                markdownPreviewPane(for: selectedDocument)
                    .frame(minWidth: 240)
            }
        } else {
            switch editorMode {
            case .source:
                markdownSourceEditor(for: selectedDocument)
            case .preview:
                markdownPreviewPane(for: selectedDocument)
            }
        }
    }

    private func markdownSourceEditor(for selectedDocument: WorkspaceDocument) -> some View {
        NativeMarkdownEditorView(
            documentID: selectedDocument.id,
            text: Binding(
                get: { store.documentText },
                set: { store.setDocumentText($0) }
            ),
            theme: theme,
            fontSize: codeFontSize * zoomScale,
            fontSmoothing: fontSmoothing,
            scrollPosition: activeViewportState?.textScrollPosition,
            syncScrollEnabled: isSplitViewEnabled,
            syncScrollTargetLine: sourceSyncLine,
            sourceLocation: $sourceLocation,
            searchState: $documentSearch,
            commandRequest: markdownCommandRequest,
            wikilinkDocuments: store.markdownDocuments,
            onScrollPositionChange: { position in
                updateViewportState(selectedDocument.id, .textScrollPosition(position))
            },
            onVisibleTopLineChange: { line in
                syncPreviewScroll(to: line)
            }
        )
        .help(selectedDocument.relativePath)
    }

    private func markdownPreviewPane(for selectedDocument: WorkspaceDocument) -> some View {
        MarkdownPreviewView(
            documentID: selectedDocument.id,
            markdown: store.documentText,
            baseURL: URL(fileURLWithPath: selectedDocument.id).deletingLastPathComponent(),
            theme: theme,
            zoomScale: zoomScale,
            codeFontSize: Double(codeFontSize),
            previewWidthPercent: previewWidthPercent,
            usePointerCursors: usePointerCursors,
            fontSmoothing: fontSmoothing,
            scrollPosition: activeViewportState?.markdownPreviewScrollPosition,
            syncScrollEnabled: isSplitViewEnabled,
            syncScrollTargetLine: previewSyncLine,
            sourceLocation: $previewLocation,
            searchState: $documentSearch,
            onSourceJump: onPreviewSourceJump,
            onScrollPositionChange: { position in
                updateViewportState(selectedDocument.id, .markdownPreviewScrollPosition(position))
            },
            onVisibleSourceLineChange: { line in
                syncSourceScroll(to: line)
            }
        )
        .help(selectedDocument.relativePath)
    }

    private func syncPreviewScroll(to line: Int) {
        guard isSplitViewEnabled, !splitScrollSyncLock, line > 0 else { return }
        splitScrollSyncLock = true
        previewSyncLine = line
        DispatchQueue.main.async {
            splitScrollSyncLock = false
        }
    }

    private func syncHTMLPreviewScroll(to line: Int, in text: String) {
        guard isSplitViewEnabled, !splitScrollSyncLock, line > 0 else { return }
        splitScrollSyncLock = true
        previewSyncLine = line
        DispatchQueue.main.async {
            splitScrollSyncLock = false
        }
    }

    private func syncSourceScroll(to line: Int) {
        guard isSplitViewEnabled, !splitScrollSyncLock, line > 0 else { return }
        splitScrollSyncLock = true
        sourceSyncLine = line
        DispatchQueue.main.async {
            splitScrollSyncLock = false
        }
    }

    private func splitViewRatioAccessor(for document: WorkspaceDocument) -> some View {
        DocumentSplitViewRatioAccessor(
            sourcePaneRatio: $splitSourcePaneRatio,
            minPaneWidth: 240,
            onCommit: { ratio in
                DocumentSplitViewPersistence.setSourcePaneRatio(
                    ratio,
                    forDocumentPath: document.id
                )
            }
        )
    }

    private var drawerAnimation: Animation {
        MonknotMotion.sidebarTransition(reduceMotion: reduceMotion)
    }

    private func terminalDrawerWidth(for availableWidth: CGFloat) -> CGFloat {
        let maxWidth = Double(drawerMaxWidth(for: availableWidth))
        let minWidth = Double(terminalDrawerMinWidth)
        return CGFloat(min(max(terminalDrawerWidth, minWidth), maxWidth))
    }

    private var terminalDrawerMinWidth: CGFloat {
        320
    }

    private func drawerMaxWidth(for availableWidth: CGFloat) -> CGFloat {
        if availableWidth < MonknotMetrics.compactLayoutBreakpoint {
            return min(max(availableWidth * 0.92, terminalDrawerMinWidth), availableWidth)
        }

        return max(terminalDrawerMinWidth, min(720, availableWidth - 360))
    }

    private func setTerminalPresented(_ value: Bool) {
        withAnimation(drawerAnimation) {
            isTerminalPresented = value
        }
    }
}

private struct UnsupportedDocumentView: View {
    let document: WorkspaceDocument
    let theme: AppTheme
    let zoomScale: Double

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(spacing: scaled(12)) {
            Image(systemName: "doc")
                .font(.system(size: scaled(34), weight: .regular))
                .foregroundStyle(theme.mutedForegroundColor.opacity(0.7))

            VStack(spacing: scaled(5)) {
                Text(document.displayName)
                    .font(.system(size: scaled(17), weight: .semibold))
                    .foregroundStyle(theme.foregroundColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("Preview is not available for this file type.")
                    .font(.system(size: scaled(13)))
                    .foregroundStyle(theme.mutedForegroundColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surfaceColor)
    }
}

private struct DocumentLoadingPlaceholder: View {
    let documentName: String
    let theme: AppTheme
    let zoomScale: Double

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(spacing: scaled(12)) {
            ProgressView()
                .controlSize(.small)

            Text(documentName)
                .font(.system(size: scaled(13), weight: .medium))
                .foregroundStyle(theme.mutedForegroundColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: scaled(280))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surfaceColor)
    }
}

struct TerminalResizeHandle: NSViewRepresentable {
    @Binding var width: Double
    let minWidth: CGFloat
    let maxWidth: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(width: $width, minWidth: minWidth, maxWidth: maxWidth)
    }

    func makeNSView(context: Context) -> ResizeHandleView {
        let view = ResizeHandleView()
        view.coordinator = context.coordinator
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel("Resize terminal sidebar")
        view.setAccessibilityHelp("Drag left or right to resize the terminal sidebar.")
        return view
    }

    func updateNSView(_ nsView: ResizeHandleView, context: Context) {
        context.coordinator.width = $width
        context.coordinator.minWidth = minWidth
        context.coordinator.maxWidth = maxWidth
        nsView.coordinator = context.coordinator
    }

    final class Coordinator {
        var width: Binding<Double>
        var minWidth: CGFloat
        var maxWidth: CGFloat
        var dragStartWidth: Double?
        var dragStartX: CGFloat?

        init(width: Binding<Double>, minWidth: CGFloat, maxWidth: CGFloat) {
            self.width = width
            self.minWidth = minWidth
            self.maxWidth = maxWidth
        }

        func beginDrag(at screenX: CGFloat) {
            dragStartWidth = clamped(width.wrappedValue)
            dragStartX = screenX
        }

        func drag(to screenX: CGFloat) {
            guard let dragStartWidth, let dragStartX else { return }
            width.wrappedValue = clamped(dragStartWidth - Double(screenX - dragStartX))
        }

        func endDrag() {
            width.wrappedValue = clamped(width.wrappedValue)
            dragStartWidth = nil
            dragStartX = nil
        }

        private func clamped(_ value: Double) -> Double {
            min(Double(maxWidth), max(Double(minWidth), value))
        }
    }

    final class ResizeHandleView: NSView {
        weak var coordinator: Coordinator?
        private var isCursorPushed = false

        override var mouseDownCanMoveWindow: Bool {
            false
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                    owner: self
                )
            )
        }

        override func mouseEntered(with event: NSEvent) {
            pushResizeCursor()
        }

        override func mouseExited(with event: NSEvent) {
            popResizeCursorIfNeeded()
        }

        override func mouseDown(with event: NSEvent) {
            pushResizeCursor()
            coordinator?.beginDrag(at: event.locationInWindow.x)
        }

        override func mouseDragged(with event: NSEvent) {
            coordinator?.drag(to: event.locationInWindow.x)
        }

        override func mouseUp(with event: NSEvent) {
            coordinator?.endDrag()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                popResizeCursorIfNeeded()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        private func pushResizeCursor() {
            guard !isCursorPushed else { return }
            NSCursor.resizeLeftRight.push()
            isCursorPushed = true
        }

        private func popResizeCursorIfNeeded() {
            guard isCursorPushed else { return }
            NSCursor.pop()
            isCursorPushed = false
        }
    }
}

private struct EmptyDetailView: View {
    let theme: AppTheme
    let zoomScale: Double
    let hasWorkspace: Bool
    let isLoadingWorkspace: Bool
    let canBootstrapStarterWorkspace: Bool
    let newMarkdown: () -> Void
    let bootstrapStarterWorkspace: () -> Void
    let openFolder: () -> Void

    var body: some View {
        VStack(spacing: MonknotMetrics.Spacing.xl) {
            Image(systemName: WorkspaceDocumentKind.markdown.resolvedSystemImage)
                .font(.system(size: MonknotMetrics.scale(40, theme: theme, zoomScale: zoomScale), weight: .semibold))
                .foregroundStyle(theme.mutedForegroundColor.opacity(0.6))
                .accessibilityHidden(true)

            VStack(spacing: MonknotMetrics.Spacing.xs) {
                Text(title)
                    .font(MonknotTypography.emptyStateTitle(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.foregroundColor)
                Text(message)
                    .font(MonknotTypography.emptyStateDetail(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .multilineTextAlignment(.center)
            }

            if isLoadingWorkspace {
                ProgressView()
                    .controlSize(.small)
            } else {
                HStack(spacing: MonknotMetrics.Spacing.s) {
                    if hasWorkspace {
                        Button(action: newMarkdown) {
                            Label("New Markdown", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accentColor)
                        .monknotPointerCursor()

                        if canBootstrapStarterWorkspace {
                            Button(action: bootstrapStarterWorkspace) {
                                Label("Starter Workspace", systemImage: "wand.and.stars")
                            }
                            .buttonStyle(.bordered)
                            .monknotPointerCursor()
                        }
                    } else {
                        Button(action: openFolder) {
                            Label("Open Folder", systemImage: MonknotWorkspaceIcons.openFolder)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accentColor)
                        .monknotPointerCursor()
                    }
                }
            }

            if !isLoadingWorkspace {
                Text(hasWorkspace ? "⌘N for a new note" : "⌘O to open a folder")
                    .font(MonknotTypography.emptyStateDetail(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.mutedForegroundColor.opacity(0.6))
                    .padding(.top, MonknotMetrics.Spacing.xxs)
            }

            if !isLoadingWorkspace, !hasWorkspace, UserDefaults.standard.data(forKey: "Monknot.workspaceBookmark") != nil {
                Text("Your last workspace reopens automatically on launch.")
                    .font(MonknotTypography.emptyStateDetail(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.mutedForegroundColor.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(MonknotMetrics.Spacing.windowMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            accessibilityLabel
        )
    }

    private var title: String {
        if isLoadingWorkspace {
            return "Opening workspace"
        }

        if canBootstrapStarterWorkspace {
            return "No documents yet"
        }

        return hasWorkspace ? "Select a document" : "Open a workspace"
    }

    private var message: String {
        if isLoadingWorkspace {
            return "Scanning files..."
        }

        if canBootstrapStarterWorkspace {
            return "Create a note or generate starter files."
        }

        return hasWorkspace
            ? "Choose a file from the sidebar, or start a new Markdown note."
            : "Open a folder to browse Markdown, text, and PDF files."
    }

    private var accessibilityLabel: String {
        if isLoadingWorkspace {
            return "Opening workspace. Scanning files."
        }

        if canBootstrapStarterWorkspace {
            return "No documents yet. Create a note or generate starter files."
        }

        return hasWorkspace
            ? "No document selected. Choose a file from the sidebar or create a new Markdown note."
            : "No workspace open. Open a folder to browse Markdown, text, and PDF files."
    }
}
