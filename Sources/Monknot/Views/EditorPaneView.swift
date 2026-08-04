import AppKit
import MonknotCore
import SwiftUI

enum TerminalDrawerPresentation: Equatable {
    case sideBySide
    case takeover
}

struct TerminalDrawerLayout: Equatable {
    let presentation: TerminalDrawerPresentation
    let drawerWidth: CGFloat
    let maximumDrawerWidth: CGFloat

    var isResizable: Bool {
        presentation == .sideBySide
            && maximumDrawerWidth > MonknotMetrics.terminalDrawerMinWidth
    }
}

enum TerminalDrawerLayoutPolicy {
    static func resolve(
        availableWidth: CGFloat,
        preferredDrawerWidth: CGFloat
    ) -> TerminalDrawerLayout {
        let availableWidth = max(0, availableWidth)
        let minimumSideBySideWidth = MonknotMetrics.editorMinimumReadableWidth
            + MonknotMetrics.terminalDrawerMinWidth

        guard availableWidth >= minimumSideBySideWidth else {
            return TerminalDrawerLayout(
                presentation: .takeover,
                drawerWidth: availableWidth,
                maximumDrawerWidth: availableWidth
            )
        }

        let maximumDrawerWidth = min(
            MonknotMetrics.terminalDrawerMaxWidth,
            availableWidth - MonknotMetrics.editorMinimumReadableWidth
        )
        let drawerWidth = min(
            max(preferredDrawerWidth, MonknotMetrics.terminalDrawerMinWidth),
            maximumDrawerWidth
        )

        return TerminalDrawerLayout(
            presentation: .sideBySide,
            drawerWidth: drawerWidth,
            maximumDrawerWidth: maximumDrawerWidth
        )
    }
}

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
    @State private var currentVisibleSourceLine = 1
    let theme: AppTheme
    let zoomScale: Double
    let codeFontSize: CGFloat
    let previewWidthPercent: Double
    let showsDocumentOutline: Bool
    let usePointerCursors: Bool
    let fontSmoothing: Bool
    let activeViewportState: DocumentViewportState?
    let updateViewportState: (String, DocumentViewportStateChange) -> Void
    let pdfUndoCommandSerial: Int
    let pdfRedoCommandSerial: Int
    let updatePDFAnnotationUndoState: (Bool, Bool) -> Void
    @Binding var isTerminalPresented: Bool
    @Binding var sourceLocation: MarkdownSourceLocation?
    @Binding var previewLocation: MarkdownSourceLocation?
    @Binding var pdfSearchTarget: WorkspaceSearchPDFTarget?
    @Binding var documentSearch: DocumentSearchState
    let newMarkdown: () -> Void
    let bootstrapStarterWorkspace: () -> Void
    let openFolder: () -> Void
    let closeTerminal: () -> Void
    let outlineItems: [MarkdownOutlineItem]
    let selectOutlineItem: (MarkdownOutlineItem) -> Void
    let onPreviewSourceJump: (MarkdownSourceLocation) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            editorAndDrawer(in: proxy.size)
        }
        .background(theme.surfaceColor)
        .onExitCommand {
            if documentSearch.isPresented {
                documentSearch.dismiss()
                return
            }
            guard isTerminalPresented else { return }
            closeTerminal()
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
            currentVisibleSourceLine = 1
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

    private var showsMarkdownSourceSubchrome: Bool {
        guard let document = store.selectedDocument,
              document.kind == .markdown,
              document.capabilities.canEditText
        else {
            return false
        }
        return editorMode == .source || isSplitViewEnabled
    }

    private func supportsSplitViewRatioPersistence(forDocumentID documentID: String) -> Bool {
        guard let document = store.document(id: documentID) else { return false }
        return document.kind == .markdown || document.capabilities.canPreviewHTML
    }

    @ViewBuilder
    private func editorAndDrawer(in size: CGSize) -> some View {
        let layout = TerminalDrawerLayoutPolicy.resolve(
            availableWidth: size.width,
            preferredDrawerWidth: terminalDrawerWidth
        )
        let editorWidth = isTerminalPresented && layout.presentation == .sideBySide
            ? max(0, size.width - layout.drawerWidth)
            : size.width
        let terminalTakesOver = isTerminalPresented && layout.presentation == .takeover

        ZStack(alignment: .trailing) {
            editorColumn
                .frame(width: editorWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .allowsHitTesting(!terminalTakesOver)
                .accessibilityHidden(terminalTakesOver)

            if isTerminalPresented {
                terminalDrawer(layout: layout)
                    .frame(width: layout.drawerWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing))
                    .zIndex(2)
            }
        }
        .animation(drawerAnimation, value: isTerminalPresented)
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            if showsMarkdownSourceSubchrome {
                MonknotChromePanel(theme: theme) {
                    MarkdownSourceToolbar(
                        theme: theme,
                        zoomScale: zoomScale,
                        text: store.documentText,
                        sendCommand: sendMarkdownCommand
                    )
                }
            }

            editorContent
                .frame(
                    minWidth: 0,
                    maxWidth: .infinity,
                    minHeight: 0,
                    maxHeight: .infinity,
                    alignment: .top
                )
                .clipped()
        }
    }

    private func terminalDrawer(layout: TerminalDrawerLayout) -> some View {
        TerminalDrawerView(
            sessions: terminalSessions,
            workingDirectory: activeTerminalDirectory,
            theme: theme,
            zoomScale: zoomScale,
            usePointerCursors: usePointerCursors,
            fontSmoothing: fontSmoothing,
            showsChrome: true,
            close: closeTerminal
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.contentSurfaceColor)
        .overlay(alignment: .leading) {
            if layout.presentation == .sideBySide {
                Rectangle()
                    .fill(theme.separatorColor)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
        }
        .overlay(alignment: .leading) {
            if layout.isResizable {
                TerminalResizeHandle(
                    width: $terminalDrawerWidth,
                    minWidth: MonknotMetrics.terminalDrawerMinWidth,
                    maxWidth: layout.maximumDrawerWidth
                )
                // Keep the visible divider at one point while providing a
                // forgiving target on both sides of it.
                .frame(width: MonknotMetrics.terminalResizeHitWidth)
                .offset(x: -MonknotMetrics.terminalResizeHitWidth / 2)
                .zIndex(3)
            }
        }
    }

    private var activeTerminalDirectory: URL? {
        TerminalWorkingDirectoryPolicy.directory(
            workspaceURL: store.workspaceURL,
            selectedDocumentURL: store.selectedDocument?.url
        )
    }

    private func sendMarkdownCommand(_ command: MarkdownTextEditorCommand) {
        markdownCommandSerial += 1
        markdownCommandRequest = MarkdownTextEditorCommandRequest(
            serial: markdownCommandSerial,
            command: command
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
                viewportState: activeViewportState?.pdfViewportState,
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
                onViewportStateChange: { state in
                    updateViewportState(selectedDocument.id, .pdfViewportState(state))
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
            fontSize: codeFontSize * WorkspaceZoomPolicy.documentScale(zoomScale),
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
            fontSize: codeFontSize * WorkspaceZoomPolicy.documentScale(zoomScale),
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
        ZStack(alignment: .trailing) {
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

            if showsDocumentOutline, outlineItems.count >= 2 {
                MarkdownOutlineRail(
                    items: outlineItems,
                    visibleLine: currentVisibleSourceLine,
                    theme: theme,
                    zoomScale: zoomScale,
                    select: { item in
                        currentVisibleSourceLine = item.location.line
                        selectOutlineItem(item)
                    }
                )
                .frame(maxHeight: .infinity)
                .zIndex(5)
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
            fontSize: codeFontSize * WorkspaceZoomPolicy.documentScale(zoomScale),
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
                currentVisibleSourceLine = line
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
                currentVisibleSourceLine = line
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

    private var drawerAnimation: Animation? {
        MonknotMotion.sidebarTransition(reduceMotion: reduceMotion)
    }
}

private struct UnsupportedDocumentView: View {
    let document: WorkspaceDocument
    let theme: AppTheme
    let zoomScale: Double

    var body: some View {
        MonknotEmptyState(
            systemImage: "doc",
            title: document.displayName,
            detail: "Preview is not available for this file type.",
            theme: theme,
            zoomScale: zoomScale
        ) {
            EmptyView()
        }
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
        view.setAccessibilityLabel("Resize terminal panel")
        view.setAccessibilityHelp("Drag left or right to resize the terminal panel.")
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

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        MonknotEmptyState(
            systemImage: emptyStateSystemImage,
            title: title,
            detail: message,
            theme: theme,
            zoomScale: zoomScale
        ) {
            if isLoadingWorkspace {
                ProgressView()
                    .controlSize(.small)
            } else {
                HStack(spacing: scaled(MonknotMetrics.Spacing.s)) {
                    if hasWorkspace {
                        MonknotActionButton(
                            title: "New Markdown",
                            systemImage: "square.and.pencil",
                            role: .primary,
                            theme: theme,
                            zoomScale: zoomScale,
                            action: newMarkdown
                        )

                        if canBootstrapStarterWorkspace {
                            MonknotActionButton(
                                title: "Starter Workspace",
                                systemImage: "wand.and.stars",
                                role: .secondary,
                                theme: theme,
                                zoomScale: zoomScale,
                                action: bootstrapStarterWorkspace
                            )
                        }
                    } else {
                        MonknotActionButton(
                            title: "Open Folder",
                            systemImage: MonknotWorkspaceIcons.openFolder,
                            role: .primary,
                            theme: theme,
                            zoomScale: zoomScale,
                            action: openFolder
                        )
                    }
                }

                Text(hasWorkspace ? "⌘N for a new note" : "⌘O to open a folder")
                    .font(MonknotTypography.emptyStateDetail(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.foregroundColor.opacity(0.48))
                    .multilineTextAlignment(.center)

                if !hasWorkspace, UserDefaults.standard.data(forKey: "Monknot.workspaceBookmark") != nil {
                    Text("Your last workspace reopens automatically on launch.")
                        .font(MonknotTypography.emptyStateDetail(theme: theme, zoomScale: zoomScale))
                        .foregroundStyle(theme.foregroundColor.opacity(0.48))
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var emptyStateSystemImage: String {
        if isLoadingWorkspace || !hasWorkspace {
            return MonknotWorkspaceIcons.openFolder
        }
        return WorkspaceDocumentKind.markdown.resolvedSystemImage
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

}
