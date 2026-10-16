import AppKit
import MonknotCore
import SwiftUI

enum EditorFlowEligibility {
    static func sourceMode(for document: WorkspaceDocument) -> FlowSourceMode? {
        if document.kind == .markdown {
            return .markdown
        }
        guard document.kind == .text else { return nil }
        switch document.url.pathExtension.lowercased() {
        case "txt", "text": return .plainText
        default: return nil
        }
    }
}

struct EditorPaneView: View {
    @ObservedObject var store: WorkspaceStore
    @Binding var editorMode: EditorMode
    @Binding var isSplitViewEnabled: Bool
    @AppStorage(VisualExternalChangeReviewPreference.key)
    private var visualExternalChangeReviewEnabled = VisualExternalChangeReviewPreference.defaultValue
    @AppStorage(EditorTextCheckingOptions.spellingPreferenceKey)
    private var checksSpelling = EditorTextCheckingOptions.defaultChecksSpelling
    @AppStorage(EditorTextCheckingOptions.grammarPreferenceKey)
    private var checksGrammar = EditorTextCheckingOptions.defaultChecksGrammar
    @AppStorage(EditorTextCheckingOptions.inlinePredictionsPreferenceKey)
    private var inlinePredictions = EditorTextCheckingOptions.defaultInlinePredictions
    @AppStorage(EditorTextCheckingOptions.onDeviceProseCompletionsPreferenceKey)
    private var onDeviceProseCompletions = EditorTextCheckingOptions.defaultOnDeviceProseCompletions
    @State private var markdownCommandSerial = 0
    @State private var markdownCommandRequest: MarkdownTextEditorCommandRequest?
    @State private var splitScrollSyncLock = false
    @State private var splitSourcePaneRatio = DocumentSplitViewPersistence.defaultSourcePaneRatio
    @State private var previewSyncLine: Int?
    @State private var sourceSyncLine: Int?
    /// Held, not observed: only the outline rail observes the visible line, so scrolling past a
    /// line never re-runs the editor bridge (which would cancel an animated scroll-bar page click).
    @State private var outlinePosition = MarkdownOutlinePosition()
    /// The outline rail sits left of the document's vertical scroll bar; laid over it, the bar could
    /// not be grabbed or clicked. The width follows the "Show scroll bars" preference.
    @State private var documentScrollBarWidth = Self.systemScrollBarWidth()
    let theme: AppTheme
    let zoomScale: Double
    let codeFontSize: CGFloat
    let contentWidthPercent: Double
    let showsDocumentOutline: Bool
    let usePointerCursors: Bool
    let fontSmoothing: Bool
    let activeViewportState: DocumentViewportState?
    let pdfViewportCaptureBridge: PDFViewportCaptureBridge
    let updateViewportState: (String, DocumentViewportStateChange) -> Void
    let pdfUndoCommandSerial: Int
    let pdfRedoCommandSerial: Int
    let updatePDFAnnotationUndoState: (Bool, Bool) -> Void
    @Binding var sourceLocation: MarkdownSourceLocation?
    @Binding var previewLocation: MarkdownSourceLocation?
    @Binding var pdfSearchTarget: WorkspaceSearchPDFTarget?
    let pdfPageNavigationRequest: PDFPageNavigationRequest?
    let pdfNavigatorToggleCommandSerial: Int
    @Binding var documentSearch: DocumentSearchState
    let searchOptions: MonknotSearchOptions
    let newMarkdown: () -> Void
    let bootstrapStarterWorkspace: () -> Void
    let openFolder: () -> Void
    let saveDocument: () -> Void
    let outlineItems: [MarkdownOutlineItem]
    let textStatistics: MarkdownTextStatistics?
    let selectOutlineItem: (MarkdownOutlineItem) -> Void
    let onPreviewSourceJump: (MarkdownSourceLocation) -> Void
    let copyPDFLinkedExcerpt: (PDFSelectionSnapshot) -> Void
    let updatePDFSelectionSnapshot: (PDFSelectionSnapshot?) -> Void
    let consumePDFPageNavigationRequest: (PDFPageNavigationRequest) -> Void
    let onMarkdownSelectionChange: (MarkdownEditorSelectionSnapshot) -> Void
    let onMarkdownLinkRequest: (MarkdownEditorLinkRequest) -> Void
    let onInspectLinks: (() -> Void)?
    let onMarkdownImagePasteRequest: (MarkdownImagePasteRequest) -> Void
    let onMarkdownFileDropRequest: (MarkdownFileDropRequest) -> Void
    let onMarkdownPreviewLinkRequest: (MarkdownPreviewLinkRequest) -> Void
    let onMarkdownTaskRequest: (MarkdownPreviewTaskRequest) -> Void

    private var textCheckingOptions: EditorTextCheckingOptions {
        EditorTextCheckingOptions(
            checksSpelling: checksSpelling,
            checksGrammar: checksGrammar,
            inlinePredictions: inlinePredictions,
            onDeviceProseCompletions: onDeviceProseCompletions
        )
    }

    var body: some View {
        editorColumn
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(theme.surfaceColor)
            .onAppear {
                if let documentID = store.selectedDocument?.id,
                   supportsSplitViewRatioPersistence(forDocumentID: documentID) {
                    splitSourcePaneRatio = DocumentSplitViewPersistence.sourcePaneRatio(forDocumentPath: documentID)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
                documentScrollBarWidth = Self.systemScrollBarWidth()
            }
            .onChange(of: store.selectedDocument?.id) { oldDocumentID, newDocumentID in
                // The new document's editor may already have reported its restored line.
                if outlinePosition.documentID != newDocumentID {
                    outlinePosition.update(1, documentID: nil)
                }
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
            }
            .onChange(of: store.activeWritingToolsDocumentID) { _, documentID in
                if documentID != nil {
                    markdownCommandRequest = nil
                }
            }
            .sheet(item: Binding(
                get: { store.externalDocumentReview },
                set: { value in
                    if value == nil {
                        store.cancelExternalDocumentReview()
                    }
                }
            )) { _ in
                ExternalDocumentReconciliationSheet(
                    store: store,
                    theme: theme,
                    zoomScale: zoomScale,
                    saveCopy: saveExternalTextCopy
                )
            }
    }

    /// An editable Markdown document keeps its toolbar row in every view mode, so switching between
    /// Source and Preview never moves the document.
    private var showsMarkdownToolbar: Bool {
        guard let document = store.selectedDocument else { return false }
        return document.kind == .markdown && document.capabilities.canEditText
    }

    /// The toolbar edits the source, so it acts only while the source is on screen.
    private var isMarkdownToolbarEnabled: Bool {
        (editorMode == .source || isSplitViewEnabled) && store.activeWritingToolsDocumentID == nil
    }

    private func supportsSplitViewRatioPersistence(forDocumentID documentID: String) -> Bool {
        guard let document = store.document(id: documentID) else { return false }
        return document.hasPreviewMode
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            if showsMarkdownToolbar {
                MonknotChromePanel(theme: theme) {
                    MarkdownSourceToolbar(
                        theme: theme,
                        zoomScale: zoomScale,
                        statistics: textStatistics,
                        sendCommand: sendMarkdownCommand
                    )
                    .equatable()
                    .disabled(!isMarkdownToolbarEnabled)
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

    private func sendMarkdownCommand(_ command: MarkdownTextEditorCommand) {
        guard isMarkdownToolbarEnabled else { return }
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
                    documentKind: store.selectedDocument?.kind,
                    visualReviewEnabled: visualExternalChangeReviewEnabled,
                    theme: theme,
                    zoomScale: zoomScale,
                    review: { store.prepareExternalDocumentReview() },
                    saveTextCopy: saveExternalTextCopy,
                    keepLocalText: {
                        store.resolveSelectedExternalDocumentWithoutReview(.keepLocal)
                    },
                    useDiskText: {
                        store.resolveSelectedExternalDocumentWithoutReview(.useDisk)
                    },
                    reloadPDF: { store.reloadSelectedDocumentFromDisk() },
                    savePDFCopy: {
                        guard let document = store.selectedDocument,
                              document.kind == .pdf
                        else { return }
                        pdfViewportCaptureBridge.commitActiveFreeTextEdit(
                            documentID: document.id
                        )
                        store.exportAnnotatedPDFCopy(for: document)
                    }
                )
            }

            if let selectedDocument = store.selectedDocument {
                if let failure = store.documentLoadFailure, failure.documentID == selectedDocument.id {
                    UnsupportedDocumentView(
                        document: selectedDocument,
                        detail: failure.message,
                        theme: theme,
                        zoomScale: zoomScale
                    )
                } else if store.isDocumentLoading, selectedDocument.capabilities.canEditText {
                    DocumentLoadingPlaceholder(
                        documentName: selectedDocument.displayName,
                        theme: theme,
                        zoomScale: zoomScale
                    )
                } else {
                    editor(for: selectedDocument)
                        .background(
                            DocumentFocusClaim()
                                .id("\(selectedDocument.id)|\(editorMode)|\(isSplitViewEnabled)")
                        )
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

    private func saveExternalTextCopy() {
        guard let document = store.selectedDocument,
              document.capabilities.canEditText
        else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let sourceURL = document.url
        let fileExtension = sourceURL.pathExtension
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = fileExtension.isEmpty
            ? "\(baseName) Copy"
            : "\(baseName) Copy.\(fileExtension)"

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destinationURL = panel.url else { return }
            store.saveExternalDocumentCopy(to: destinationURL)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
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
        case .pdf, .image:
            // Images use the PDF viewer's zoom and markup tools on a page that draws the image.
            PDFPreviewView(
                document: selectedDocument,
                theme: theme,
                zoomScale: zoomScale,
                saveState: store.saveState(for: selectedDocument.id),
                dirtyData: store.dirtyPDFData(for: selectedDocument.id),
                savedEditCheckpoint: store.pdfSavedEditCheckpoint(for: selectedDocument.id),
                contentVersion: store.pdfContentVersion(for: selectedDocument.id),
                viewportState: activeViewportState?.pdfViewportState,
                viewportCaptureBridge: pdfViewportCaptureBridge,
                externalUndoCommandSerial: pdfUndoCommandSerial,
                externalRedoCommandSerial: pdfRedoCommandSerial,
                searchState: $documentSearch,
                searchOptions: searchOptions,
                searchTarget: $pdfSearchTarget,
                markEdited: { previousData, data, editCheckpoint in
                    store.markPDFDocumentEdited(
                        id: selectedDocument.id,
                        previousData: previousData,
                        data: data,
                        editCheckpoint: editCheckpoint
                    )
                },
                restoreSavedEditCheckpoint: { checkpoint in
                    store.restorePDFSavedEditCheckpoint(
                        id: selectedDocument.id,
                        checkpoint: checkpoint
                    )
                },
                reportError: { message in
                    store.reportPDFAnnotationError(message)
                },
                saveDocument: {
                    saveDocument()
                },
                pageNavigationRequest: pdfPageNavigationRequest,
                externalNavigatorToggleCommandSerial: pdfNavigatorToggleCommandSerial,
                copyLinkedExcerpt: copyPDFLinkedExcerpt,
                onSelectionSnapshotChange: updatePDFSelectionSnapshot,
                onPageNavigationRequestConsumed: consumePDFPageNavigationRequest,
                onViewportStateChange: { state in
                    updateViewportState(selectedDocument.id, .pdfViewportState(state))
                },
                updateAnnotationUndoState: updatePDFAnnotationUndoState
            )
        case .media:
            // One player per document, so switching tabs releases the previous file.
            MediaPlayerView(document: selectedDocument, theme: theme, zoomScale: zoomScale)
                .id(selectedDocument.id)
        case .nativePreview, .unsupported:
            UnsupportedDocumentView(
                document: selectedDocument,
                theme: theme,
                zoomScale: zoomScale
            )
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
            zoomScale: zoomScale,
            contentWidthPercent: contentWidthPercent,
            fontSmoothing: fontSmoothing,
            textCheckingOptions: textCheckingOptions,
            scrollPosition: activeViewportState?.textScrollPosition,
            sourceLocation: $sourceLocation,
            searchState: $documentSearch,
            searchOptions: searchOptions,
            onScrollPositionChange: { position in
                updateViewportState(selectedDocument.id, .textScrollPosition(position))
            },
            syncScrollEnabled: isSplitViewEnabled,
            syncScrollTargetLine: sourceSyncLine,
            onVisibleTopLineChange: { line in
                syncHTMLPreviewScroll(to: line, in: store.documentText)
            }
        )
    }

    private func htmlPreviewPane(for selectedDocument: WorkspaceDocument) -> some View {
        HTMLPreviewView(
            documentID: selectedDocument.id,
            html: store.documentText,
            baseURL: URL(fileURLWithPath: selectedDocument.id).deletingLastPathComponent(),
            resourceRoot: store.workspaceURL,
            theme: theme,
            zoomScale: zoomScale,
            contentWidthPercent: contentWidthPercent,
            scrollPosition: activeViewportState?.htmlPreviewScrollPosition,
            syncScrollEnabled: isSplitViewEnabled,
            syncScrollTargetLine: previewSyncLine,
            sourceLineCount: HTMLScrollSync.totalLines(in: store.documentText),
            searchState: $documentSearch,
            searchOptions: searchOptions,
            onScrollPositionChange: { position in
                updateViewportState(selectedDocument.id, .htmlPreviewScrollPosition(position))
            },
            onVisibleSourceLineChange: { line in
                syncSourceScroll(to: line)
            }
        )
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
            zoomScale: zoomScale,
            contentWidthPercent: contentWidthPercent,
            fontSmoothing: fontSmoothing,
            textCheckingOptions: textCheckingOptions,
            scrollPosition: activeViewportState?.textScrollPosition,
            sourceLocation: $sourceLocation,
            searchState: $documentSearch,
            searchOptions: searchOptions,
            onScrollPositionChange: { position in
                updateViewportState(selectedDocument.id, .textScrollPosition(position))
            },
            flowSourceMode: EditorFlowEligibility.sourceMode(for: selectedDocument),
            onWritingToolsTextCommit: { documentID, text in
                store.commitWritingToolsText(text, documentID: documentID)
            },
            onWritingToolsStateChange: { documentID, isActive in
                store.setWritingToolsActive(isActive, documentID: documentID)
            }
        )
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
                    documentID: selectedDocument.id,
                    items: outlineItems,
                    position: outlinePosition,
                    theme: theme,
                    zoomScale: zoomScale,
                    select: { item in
                        outlinePosition.update(item.location.line, documentID: selectedDocument.id)
                        selectOutlineItem(item)
                    }
                )
                .equatable()
                .frame(maxHeight: .infinity)
                .padding(.trailing, documentScrollBarWidth)
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
            zoomScale: zoomScale,
            contentWidthPercent: contentWidthPercent,
            fontSmoothing: fontSmoothing,
            textCheckingOptions: textCheckingOptions,
            flowSourceMode: EditorFlowEligibility.sourceMode(for: selectedDocument),
            scrollPosition: activeViewportState?.textScrollPosition,
            textSelection: activeViewportState?.textSelection,
            syncScrollEnabled: isSplitViewEnabled,
            syncScrollTargetLine: sourceSyncLine,
            openingTopLine: outlinePosition.visibleLine(in: selectedDocument.id),
            sourceLocation: $sourceLocation,
            searchState: $documentSearch,
            searchOptions: searchOptions,
            commandRequest: markdownCommandRequest,
            wikilinkDocuments: store.markdownDocuments,
            onSelectionChange: onMarkdownSelectionChange,
            onOpenLink: onMarkdownLinkRequest,
            onInspectLinks: onInspectLinks,
            onImagePasteRequest: onMarkdownImagePasteRequest,
            onFileDropRequest: onMarkdownFileDropRequest,
            onWritingToolsTextCommit: { documentID, text in
                store.commitWritingToolsText(text, documentID: documentID)
            },
            onWritingToolsStateChange: { documentID, isActive in
                store.setWritingToolsActive(isActive, documentID: documentID)
            },
            onScrollPositionChange: { position in
                updateViewportState(selectedDocument.id, .textScrollPosition(position))
            },
            onVisibleTopLineChange: { line in
                outlinePosition.update(line, documentID: selectedDocument.id)
                syncPreviewScroll(to: line)
            }
        )
    }

    private func markdownPreviewPane(for selectedDocument: WorkspaceDocument) -> some View {
        MarkdownPreviewView(
            documentID: selectedDocument.id,
            markdown: store.documentText,
            baseURL: URL(fileURLWithPath: selectedDocument.id).deletingLastPathComponent(),
            resourceRoot: store.workspaceURL,
            theme: theme,
            zoomScale: zoomScale,
            codeFontSize: Double(codeFontSize),
            contentWidthPercent: contentWidthPercent,
            usePointerCursors: usePointerCursors,
            fontSmoothing: fontSmoothing,
            scrollPosition: activeViewportState?.markdownPreviewScrollPosition,
            syncScrollEnabled: isSplitViewEnabled,
            syncScrollTargetLine: previewSyncLine,
            openingTopLine: outlinePosition.visibleLine(in: selectedDocument.id),
            sourceLocation: $previewLocation,
            searchState: $documentSearch,
            searchOptions: searchOptions,
            onSourceJump: onPreviewSourceJump,
            onLinkRequest: onMarkdownPreviewLinkRequest,
            onTaskRequest: onMarkdownTaskRequest,
            onScrollPositionChange: { position in
                updateViewportState(selectedDocument.id, .markdownPreviewScrollPosition(position))
            },
            onVisibleSourceLineChange: { line in
                outlinePosition.update(line, documentID: selectedDocument.id)
                syncSourceScroll(to: line)
            }
        )
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

    private static func systemScrollBarWidth() -> CGFloat {
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
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

}

private struct UnsupportedDocumentView: View {
    let document: WorkspaceDocument
    var detail = "Preview is not available for this file type."
    let theme: AppTheme
    let zoomScale: Double

    var body: some View {
        MonknotEmptyState(
            systemImage: "doc",
            title: document.displayName,
            detail: detail,
            theme: theme,
            zoomScale: zoomScale
        ) {
            MonknotActionButton(
                title: "Reveal in Finder",
                systemImage: MonknotWorkspaceIcons.revealInFinder,
                role: .secondary,
                theme: theme,
                zoomScale: zoomScale
            ) {
                NSWorkspace.shared.activateFileViewerSelecting([document.url])
            }
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
            MonknotProgressIndicator(
                size: MonknotMetrics.interfaceGlyph(16, theme: theme, zoomScale: zoomScale),
                theme: theme
            )

            Text(documentName)
                .font(.system(size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: zoomScale)))
                .foregroundStyle(theme.tertiaryForegroundColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: scaled(280))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surfaceColor)
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
        MonknotEmptyState(
            systemImage: hasWorkspace && !isLoadingWorkspace ? "doc.text" : MonknotWorkspaceIcons.openFolder,
            title: title,
            detail: detail,
            theme: theme,
            zoomScale: zoomScale
        ) {
            if isLoadingWorkspace {
                MonknotProgressIndicator(
                    size: MonknotMetrics.interfaceGlyph(16, theme: theme, zoomScale: zoomScale),
                    theme: theme
                )
            } else if hasWorkspace {
                VStack(spacing: MonknotMetrics.interfaceDensity(8, theme: theme, zoomScale: zoomScale)) {
                    MonknotShortcutActionButton(
                        title: "New Markdown",
                        shortcut: "⌘N",
                        theme: theme,
                        zoomScale: zoomScale,
                        action: newMarkdown
                    )
                    if canBootstrapStarterWorkspace {
                        MonknotActionButton(
                            title: "Add Starter Notes",
                            role: .quiet,
                            theme: theme,
                            zoomScale: zoomScale,
                            size: .bar,
                            action: bootstrapStarterWorkspace
                        )
                        .help("Adds a README, a project brief and an ideas note")
                    }
                }
            } else {
                MonknotShortcutActionButton(
                    title: "Open Folder…",
                    shortcut: "⌘O",
                    theme: theme,
                    zoomScale: zoomScale,
                    action: openFolder
                )
            }
        }
    }

    private var title: String {
        if isLoadingWorkspace {
            return "Opening workspace"
        }
        if canBootstrapStarterWorkspace {
            return "This workspace is empty"
        }
        return hasWorkspace ? "No document open" : "No workspace open"
    }

    private var detail: String {
        if isLoadingWorkspace {
            return "Reading files…"
        }
        if canBootstrapStarterWorkspace {
            return "Create a note to start writing."
        }
        return hasWorkspace
            ? "Choose a file in the sidebar, or create a note."
            : "Open a folder of Markdown, text and PDF files."
    }
}

/// Gives a newly shown document keyboard focus when nothing else in the window
/// holds it. It runs once AppKit attaches the view: a state-change hook runs
/// before SwiftUI swaps the document views. The `id` remounts it per document
/// and mode.
private struct DocumentFocusClaim: NSViewRepresentable {
    func makeNSView(context: Context) -> AttachmentView {
        AttachmentView(frame: .zero)
    }

    func updateNSView(_ nsView: AttachmentView, context: Context) {}

    final class AttachmentView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            TerminalFocusRestorer.focusDocumentIfUnfocused(in: window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
