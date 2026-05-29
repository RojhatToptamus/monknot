import AppKit
import MonknotCore
import SwiftUI

struct EditorPaneView: View {
    @ObservedObject var store: WorkspaceStore
    @Binding var editorMode: EditorMode
    @AppStorage("Monknot.terminalDrawerWidth") private var terminalDrawerWidth = 420.0
    @StateObject private var terminalSessions = TerminalSessionCollectionStore()
    @State private var markdownCommandSerial = 0
    @State private var markdownCommandRequest: MarkdownTextEditorCommandRequest?
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
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(1)
                }
            }
            .animation(drawerAnimation, value: isTerminalPresented)
        } else if isTerminalPresented {
            wideLayoutWithTerminal(
                drawerWidth: drawerWidth,
                maxDrawerWidth: drawerMaxWidth(for: size.width)
            )
            .animation(drawerAnimation, value: isTerminalPresented)
        } else {
            editorColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var showsMarkdownSourceSubchrome: Bool {
        store.selectedDocument?.kind == .markdown && editorMode == .source
    }

    /// Wide layout with terminal: primary chrome is one shared row (aligned tops);
    /// resize gutter and content sit below, not between chrome headers.
    private func wideLayoutWithTerminal(drawerWidth: CGFloat, maxDrawerWidth: CGFloat) -> some View {
        return VStack(spacing: 0) {
            sharedPrimaryChromeRow(terminalDrawerWidth: drawerWidth)
                .fixedSize(horizontal: false, vertical: true)

            if showsMarkdownSourceSubchrome {
                editorSecondaryChromeRow(terminalDrawerWidth: drawerWidth)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 0) {
                editorContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                terminalContentColumn(
                    drawerWidth: drawerWidth,
                    maxDrawerWidth: maxDrawerWidth,
                    close: { setTerminalPresented(false) }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
    }

    private func sharedPrimaryChromeRow(terminalDrawerWidth: CGFloat) -> some View {
        let terminalChromeWidth = max(0, terminalDrawerWidth - 1)

        return HStack(alignment: .top, spacing: 0) {
            MonknotChromePanel(theme: theme, showsBottomBorder: false) {
                editorPrimaryChrome
            }
            .frame(maxWidth: .infinity)

            editorTerminalVerticalSeparator

            MonknotChromePanel(theme: theme, showsBottomBorder: false, surface: theme.contentSurfaceColor) {
                TerminalDrawerChromeRow(
                    sessions: terminalSessions,
                    workingDirectory: activeTerminalDirectory,
                    theme: theme,
                    zoomScale: zoomScale,
                    uiFontSize: theme.uiFontSize,
                    close: { setTerminalPresented(false) }
                )
            }
            .frame(width: terminalChromeWidth)
        }
        .background {
            MonknotChromeSurfaceBackground(theme: theme, surface: theme.contentSurfaceColor)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.separatorColor)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func editorSecondaryChromeRow(terminalDrawerWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            MonknotChromePanel(theme: theme) {
                VStack(spacing: 0) {
                    MonknotChromeDivider(theme: theme)
                    MarkdownSourceToolbar(
                        theme: theme,
                        zoomScale: zoomScale,
                        sendCommand: sendMarkdownCommand
                    )
                }
            }
            .frame(maxWidth: .infinity)

            editorTerminalVerticalSeparator

            Color.clear
                .frame(width: max(0, terminalDrawerWidth - 1))
                .background(theme.contentSurfaceColor)
                .accessibilityHidden(true)
        }
        .background(theme.contentSurfaceColor)
    }

    private var editorTerminalVerticalSeparator: some View {
        Rectangle()
            .fill(theme.separatorColor)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }

    private func terminalContentColumn(
        drawerWidth: CGFloat,
        maxDrawerWidth: CGFloat,
        close: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 0) {
            editorTerminalVerticalSeparator

            TerminalDrawerView(
                sessions: terminalSessions,
                workingDirectory: activeTerminalDirectory,
                theme: theme,
                zoomScale: zoomScale,
                usePointerCursors: usePointerCursors,
                fontSmoothing: fontSmoothing,
                includesChrome: false,
                close: close
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: drawerWidth)
        .background(theme.contentSurfaceColor)
        .overlay(alignment: .leading) {
            TerminalResizeHandle(
                width: $terminalDrawerWidth,
                minWidth: terminalDrawerMinWidth,
                maxWidth: maxDrawerWidth
            )
            .frame(width: terminalResizeHitWidth)
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
            editorTerminalVerticalSeparator

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
        }
    }

    private var terminalResizeHitWidth: CGFloat {
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
            EmptyDetailView(theme: theme, zoomScale: zoomScale)
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

    @ViewBuilder
    private func htmlEditor(for selectedDocument: WorkspaceDocument) -> some View {
        switch editorMode {
        case .source:
            textEditor(for: selectedDocument)
        case .preview:
            HTMLPreviewView(
                documentID: selectedDocument.id,
                html: store.documentText,
                baseURL: URL(fileURLWithPath: selectedDocument.id).deletingLastPathComponent(),
                theme: theme,
                zoomScale: zoomScale,
                scrollPosition: activeViewportState?.htmlPreviewScrollPosition,
                searchState: $documentSearch,
                onScrollPositionChange: { position in
                    updateViewportState(selectedDocument.id, .htmlPreviewScrollPosition(position))
                }
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
                fontSmoothing: fontSmoothing,
                scrollPosition: activeViewportState?.textScrollPosition,
                sourceLocation: $sourceLocation,
                searchState: $documentSearch,
                commandRequest: markdownCommandRequest,
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
    let zoomScale: Double

    var body: some View {
        VStack(spacing: MonknotMetrics.Spacing.xl) {
            Image(systemName: WorkspaceDocumentKind.markdown.resolvedSystemImage)
                .font(.system(size: MonknotMetrics.scale(40, theme: theme, zoomScale: zoomScale), weight: .semibold))
                .foregroundStyle(theme.mutedForegroundColor.opacity(0.6))
                .accessibilityHidden(true)

            VStack(spacing: MonknotMetrics.Spacing.xs) {
                Text("Select a document")
                    .font(MonknotTypography.emptyStateTitle(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.foregroundColor)
                Text("Open a folder or drop Markdown or PDF documents into the sidebar.")
                    .font(MonknotTypography.emptyStateDetail(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .multilineTextAlignment(.center)
            }

            Text("⌘O to open a folder")
                .font(MonknotTypography.emptyStateDetail(theme: theme, zoomScale: zoomScale))
                .foregroundStyle(theme.mutedForegroundColor.opacity(0.6))
                .padding(.top, MonknotMetrics.Spacing.xxs)
        }
        .padding(MonknotMetrics.Spacing.windowMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No document selected. Open a folder or drop Markdown or PDF documents into the sidebar.")
    }
}
