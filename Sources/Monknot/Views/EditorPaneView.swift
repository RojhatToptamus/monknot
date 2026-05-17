import AppKit
import MonknotCore
import SwiftUI

struct EditorPaneView: View {
    @ObservedObject var store: WorkspaceStore
    @Binding var editorMode: EditorMode
    @AppStorage("Monknot.terminalDrawerWidth") private var terminalDrawerWidth = 420.0
    @StateObject private var terminalSessions = TerminalSessionCollectionStore()
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
    let openFolder: () -> Void
    let toggleTerminal: () -> Void
    let toggleSidebar: () -> Void
    let outlineItems: [MarkdownOutlineItem]
    let selectOutlineItem: (MarkdownOutlineItem) -> Void
    let onPreviewSourceJump: (MarkdownSourceLocation) -> Void

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
        }
        .onChange(of: store.workspaceURL) { _, _ in
            terminalSessions.setDefaultDirectory(activeTerminalDirectory)
        }
        .onChange(of: store.selectedDocument?.id) { _, _ in
            terminalSessions.setDefaultDirectory(activeTerminalDirectory)
        }
    }

    @ViewBuilder
    private func editorAndDrawer(in size: CGSize) -> some View {
        let isCompact = size.width < 760
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

                    resizableTerminalDrawer(width: drawerWidth, maxWidth: drawerMaxWidth(for: size.width)) {
                        setTerminalPresented(false)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(1)
                }
            }
            .animation(drawerAnimation, value: isTerminalPresented)
        } else {
            HStack(spacing: 0) {
                editorColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isTerminalPresented {
                    resizableTerminalDrawer(width: drawerWidth, maxWidth: drawerMaxWidth(for: size.width)) {
                        setTerminalPresented(false)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(drawerAnimation, value: isTerminalPresented)
        }
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            TopNavigationBar(
                store: store,
                editorMode: $editorMode,
                theme: theme,
                zoomScale: zoomScale,
                isTerminalPresented: isTerminalPresented,
                isSidebarVisible: isSidebarVisible,
                newMarkdown: newMarkdown,
                openFolder: openFolder,
                toggleTerminal: toggleTerminal,
                toggleSidebar: toggleSidebar,
                outlineItems: outlineItems,
                selectOutlineItem: selectOutlineItem,
                documentSearch: $documentSearch,
                tabs: tabs,
                activeTabID: activeTabID,
                missingTabIDs: missingTabIDs,
                selectTab: selectTab,
                closeTab: closeTab,
                togglePinTab: togglePinTab,
                reorderTab: reorderTab
            )

            editorContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resizableTerminalDrawer(width: CGFloat, maxWidth: CGFloat, close: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            TerminalResizeHandle(
                width: $terminalDrawerWidth,
                minWidth: terminalDrawerMinWidth,
                maxWidth: maxWidth
            )
            .frame(width: terminalResizeGutterWidth)

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
        .background(theme.surfaceColor)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.borderColor)
                .frame(width: 1)
        }
    }

    private var terminalResizeGutterWidth: CGFloat {
        12
    }

    private var activeTerminalDirectory: URL? {
        TerminalWorkingDirectoryPolicy.directory(
            workspaceURL: store.workspaceURL,
            selectedDocumentURL: store.selectedDocument?.url
        )
    }

    @ViewBuilder
    private var editorContent: some View {
        if let selectedDocument = store.selectedDocument {
            editor(for: selectedDocument)
                .overlay {
                    if store.isDocumentLoading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(12)
                            .background(
                                theme.elevatedSurfaceColor,
                                in: RoundedRectangle(cornerRadius: theme.chromeRadius(10, zoomScale: zoomScale))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: theme.chromeRadius(10, zoomScale: zoomScale))
                                    .strokeBorder(theme.borderColor, lineWidth: 1)
                            )
                    }
                }
        } else {
            EmptyDetailView(theme: theme)
        }
    }

    @ViewBuilder
    private func editor(for selectedDocument: WorkspaceDocument) -> some View {
        switch selectedDocument.kind {
        case .markdown:
            markdownEditor(for: selectedDocument)
        case .text:
            textEditor(for: selectedDocument)
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
                    store.markPDFDocumentEdited(id: selectedDocument.id, previousData: previousData, data: data)
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
            .help(selectedDocument.relativePath)
        case .media:
            MediaPreviewView(url: selectedDocument.url, theme: theme)
                .help(selectedDocument.relativePath)
        case .nativePreview:
            QuickLookPreviewView(url: selectedDocument.url, theme: theme)
                .help(selectedDocument.relativePath)
        case .unsupported:
            UnsupportedDocumentView(
                document: selectedDocument,
                theme: theme,
                zoomScale: zoomScale
            )
            .help(selectedDocument.relativePath)
        }
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
        switch editorMode {
        case .source:
            NativeMarkdownEditorView(
                documentID: selectedDocument.id,
                text: Binding(
                    get: { store.documentText },
                    set: { store.setDocumentText($0) }
                ),
                theme: theme,
                fontSize: codeFontSize * zoomScale,
                zoomScale: zoomScale,
                fontSmoothing: fontSmoothing,
                scrollPosition: activeViewportState?.textScrollPosition,
                sourceLocation: $sourceLocation,
                searchState: $documentSearch,
                onScrollPositionChange: { position in
                    updateViewportState(selectedDocument.id, .textScrollPosition(position))
                }
            )
            .help(selectedDocument.relativePath)

        case .preview:
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
                sourceLocation: $previewLocation,
                searchState: $documentSearch,
                onSourceJump: onPreviewSourceJump,
                onScrollPositionChange: { position in
                    updateViewportState(selectedDocument.id, .markdownPreviewScrollPosition(position))
                }
            )
            .help(selectedDocument.relativePath)
        }
    }

    private var drawerAnimation: Animation {
        .spring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.08)
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
        if availableWidth < 760 {
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
        max(base * zoomScale * CGFloat(theme.uiFontSize / 16), base * 0.75)
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

private struct TerminalResizeHandle: NSViewRepresentable {
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
            dragStartWidth = width.wrappedValue
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

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "markdown")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(theme.mutedForegroundColor.opacity(0.6))

            VStack(spacing: 5) {
                Text("Select a document")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.foregroundColor)
                Text("Open a folder or drop Markdown or PDF documents into the sidebar.")
                    .foregroundStyle(theme.mutedForegroundColor)
            }

            Text("⇧⌘O to open a folder")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(theme.mutedForegroundColor.opacity(0.6))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
