import AppKit
import MarkprevCore
import PDFKit
import SwiftUI

struct PDFPreviewView: View {
    let document: WorkspaceDocument
    let theme: AppTheme
    let zoomScale: Double
    let saveState: DocumentSaveState
    let dirtyData: Data?
    let viewportPosition: PDFDocumentViewportPosition?
    let externalUndoCommandSerial: Int
    let externalRedoCommandSerial: Int
    @Binding var searchState: DocumentSearchState
    @Binding var searchTarget: WorkspaceSearchPDFTarget?
    let markEdited: (Data?, Data) -> Void
    let reportError: (String) -> Void
    let saveDocument: () -> Void
    let onViewportPositionChange: (PDFDocumentViewportPosition) -> Void
    let updateAnnotationUndoState: (Bool, Bool) -> Void

    @State private var interactionMode: PDFAnnotationInteractionMode = .select
    @State private var selectedColor: PDFAnnotationPaletteColor = .yellow
    @State private var strokeWidth = 3.0
    @State private var markupCommand: PDFTextMarkupCommand?
    @State private var markupCommandSerial = 0
    @State private var undoCommandSerial = 0
    @State private var redoCommandSerial = 0
    @State private var canUndo = false
    @State private var canRedo = false

    private var uiFontSize: Double { theme.uiFontSize }

    var body: some View {
        VStack(spacing: 0) {
            PDFAnnotationToolbar(
                interactionMode: $interactionMode,
                selectedColor: $selectedColor,
                strokeWidth: $strokeWidth,
                saveState: saveState,
                canUndo: canUndo,
                canRedo: canRedo,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize,
                runMarkup: runMarkup(_:),
                undo: runUndo,
                redo: runRedo,
                saveDocument: saveDocument
            )

            Divider()
                .overlay(theme.borderColor)

            PDFKitPreviewRepresentable(
                documentID: document.id,
                url: document.url,
                dirtyData: dirtyData,
                theme: theme,
                zoomScale: zoomScale,
                viewportPosition: viewportPosition,
                annotationMode: interactionMode,
                annotationColor: selectedColor,
                strokeWidth: CGFloat(strokeWidth),
                markupCommand: markupCommand,
                undoCommandSerial: externalUndoCommandSerial + undoCommandSerial,
                redoCommandSerial: externalRedoCommandSerial + redoCommandSerial,
                searchState: $searchState,
                searchTarget: $searchTarget,
                markEdited: markEdited,
                onViewportPositionChange: onViewportPositionChange,
                updateUndoState: updateUndoState(canUndo:canRedo:),
                reportError: reportError
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.surfaceColor)
    }

    private func runMarkup(_ kind: PDFTextMarkupKind) {
        markupCommandSerial += 1
        markupCommand = PDFTextMarkupCommand(
            serial: markupCommandSerial,
            kind: kind,
            color: selectedColor
        )
    }

    private func runUndo() {
        undoCommandSerial += 1
    }

    private func runRedo() {
        redoCommandSerial += 1
    }

    private func updateUndoState(canUndo: Bool, canRedo: Bool) {
        if self.canUndo != canUndo {
            self.canUndo = canUndo
        }
        if self.canRedo != canRedo {
            self.canRedo = canRedo
        }
        updateAnnotationUndoState(canUndo, canRedo)
    }
}

private struct PDFAnnotationToolbar: View {
    @Binding var interactionMode: PDFAnnotationInteractionMode
    @Binding var selectedColor: PDFAnnotationPaletteColor
    @Binding var strokeWidth: Double
    let saveState: DocumentSaveState
    let canUndo: Bool
    let canRedo: Bool
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let runMarkup: (PDFTextMarkupKind) -> Void
    let undo: () -> Void
    let redo: () -> Void
    let saveDocument: () -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        HStack(spacing: scaled(7)) {
            ScrollView(.horizontal, showsIndicators: false) {
                toolbarContent
                    .padding(.vertical, scaled(7))
            }
            .frame(minWidth: 0, maxWidth: .infinity)

            saveButton
        }
        .padding(.horizontal, scaled(12))
        .frame(height: scaled(42))
        .animation(.easeOut(duration: 0.14), value: interactionMode)
    }

    private var toolbarContent: some View {
        HStack(spacing: scaled(7)) {
            PDFToolbarIconButton(
                systemImage: "arrow.uturn.backward",
                label: "Undo",
                isDisabled: !canUndo,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize
            ) {
                undo()
            }

            PDFToolbarIconButton(
                systemImage: "arrow.uturn.forward",
                label: "Redo",
                isDisabled: !canRedo,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize
            ) {
                redo()
            }

            toolbarDivider

            PDFToolbarIconButton(
                systemImage: "cursorarrow",
                label: "Select",
                isActive: interactionMode == .select,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize
            ) {
                interactionMode = .select
            }

            toolbarDivider

            PDFToolbarIconButton(
                systemImage: "highlighter",
                label: "Highlight Selection",
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize
            ) {
                runMarkup(.highlight)
            }

            PDFToolbarIconButton(
                systemImage: "underline",
                label: "Underline Selection",
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize
            ) {
                runMarkup(.underline)
            }

            PDFToolbarIconButton(
                systemImage: "strikethrough",
                label: "Strike Through Selection",
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize
            ) {
                runMarkup(.strikeOut)
            }

            toolbarDivider

            PDFToolbarIconButton(
                systemImage: "pencil.tip",
                label: "Draw",
                isActive: interactionMode == .pen,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize
            ) {
                interactionMode = interactionMode == .pen ? .select : .pen
            }

            PDFToolbarIconButton(
                systemImage: "eraser",
                label: "Erase Annotation",
                isActive: interactionMode == .eraser,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize
            ) {
                interactionMode = interactionMode == .eraser ? .select : .eraser
            }

            if interactionMode == .pen {
                Slider(value: $strokeWidth, in: 1...10, step: 1)
                    .frame(width: scaled(92))
                    .tint(selectedColor.color)
                    .help("Stroke Width")
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .leading)))
            }

            toolbarDivider

            HStack(spacing: scaled(5)) {
                ForEach(PDFAnnotationPaletteColor.all) { color in
                    PDFColorSwatchButton(
                        color: color,
                        isSelected: color == selectedColor,
                        theme: theme,
                        zoomScale: zoomScale,
                        uiFontSize: uiFontSize
                    ) {
                        selectedColor = color
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var saveButton: some View {
        PDFToolbarIconButton(
            systemImage: "externaldrive.badge.checkmark",
            label: "Save PDF",
            isActive: !saveState.isClean,
            isDisabled: saveState.isClean || saveState == .saving,
            theme: theme,
            zoomScale: zoomScale,
            uiFontSize: uiFontSize
        ) {
            saveDocument()
        }
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(theme.borderColor)
            .frame(width: 1, height: scaled(20))
            .accessibilityHidden(true)
    }
}

private struct PDFToolbarIconButton: View {
    let systemImage: String
    let label: String
    var isActive = false
    var isDisabled = false
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let action: () -> Void

    @State private var isHovered = false

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: scaled(13), weight: .regular))
                .foregroundStyle(iconColor)
                .frame(width: scaled(30), height: scaled(28))
                .background(background, in: RoundedRectangle(cornerRadius: theme.chromeRadius(7, zoomScale: zoomScale)))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.chromeRadius(7, zoomScale: zoomScale))
                        .strokeBorder(borderColor, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: theme.chromeRadius(7, zoomScale: zoomScale)))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.46 : 1)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isActive)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .markprevPointerCursor(enabled: !isDisabled)
    }

    private var iconColor: Color {
        if isActive {
            return theme.foregroundColor
        }
        if isHovered && !isDisabled {
            return theme.foregroundColor.opacity(0.92)
        }
        return theme.mutedForegroundColor
    }

    private var background: Color {
        if isActive {
            return theme.controlTrackFillColor
        }
        if isHovered && !isDisabled {
            return theme.foregroundColor.opacity(theme.isDark ? 0.065 : 0.048)
        }
        return .clear
    }

    private var borderColor: Color {
        isActive ? theme.borderColor : Color.clear
    }
}

private struct PDFColorSwatchButton: View {
    let color: PDFAnnotationPaletteColor
    let isSelected: Bool
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let action: () -> Void

    @State private var isHovered = false

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.color)
                .frame(width: scaled(16), height: scaled(16))
                .overlay {
                    Circle()
                        .strokeBorder(theme.surfaceColor.opacity(0.85), lineWidth: scaled(1))
                }
                .padding(scaled(4))
                .background(
                    Circle()
                        .fill(isSelected ? theme.controlTrackFillColor : Color.clear)
                )
                .overlay {
                    Circle()
                        .strokeBorder(isSelected ? theme.borderColor : Color.clear, lineWidth: 1)
                }
                .scaleEffect(isHovered ? 1.06 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .help(color.name)
        .accessibilityLabel(color.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .markprevPointerCursor()
    }
}

private struct PDFKitPreviewRepresentable: NSViewRepresentable {
    let documentID: String
    let url: URL
    let dirtyData: Data?
    let theme: AppTheme
    let zoomScale: Double
    let viewportPosition: PDFDocumentViewportPosition?
    let annotationMode: PDFAnnotationInteractionMode
    let annotationColor: PDFAnnotationPaletteColor
    let strokeWidth: CGFloat
    let markupCommand: PDFTextMarkupCommand?
    let undoCommandSerial: Int
    let redoCommandSerial: Int
    @Binding var searchState: DocumentSearchState
    @Binding var searchTarget: WorkspaceSearchPDFTarget?
    let markEdited: (Data?, Data) -> Void
    let onViewportPositionChange: (PDFDocumentViewportPosition) -> Void
    let updateUndoState: (Bool, Bool) -> Void
    let reportError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AnnotatingPDFView {
        let view = AnnotatingPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.autoScales = true
        view.minScaleFactor = 0.35
        view.maxScaleFactor = 4
        view.backgroundColor = NSColor(hex: theme.background)
        context.coordinator.documentID = documentID
        context.coordinator.onViewportPositionChange = onViewportPositionChange
        context.coordinator.acceptCurrentUndoRedoSerials(
            undoSerial: undoCommandSerial,
            redoSerial: redoCommandSerial
        )
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ pdfView: AnnotatingPDFView, context: Context) {
        let didChangeDocument = context.coordinator.prepareForDocument(
            documentID,
            undoSerial: undoCommandSerial,
            redoSerial: redoCommandSerial,
            in: pdfView
        )
        context.coordinator.onViewportPositionChange = onViewportPositionChange
        pdfView.annotationMode = annotationMode
        pdfView.annotationColor = annotationColor.nsColor
        pdfView.annotationLineWidth = strokeWidth
        pdfView.onEdited = markEdited
        pdfView.onError = reportError
        pdfView.onUndoStateChanged = { canUndo, canRedo in
            DispatchQueue.main.async {
                self.updateUndoState(canUndo, canRedo)
            }
        }

        context.coordinator.onSearchResult = { result in
            DispatchQueue.main.async {
                let current = DocumentSearchResult(
                    currentIndex: self.searchState.currentIndex,
                    totalCount: self.searchState.totalCount
                )
                if current != result {
                    self.searchState.updateResult(result)
                }
            }
        }
        context.coordinator.onSearchTargetConsumed = {
            DispatchQueue.main.async {
                self.searchTarget = nil
            }
        }
        context.coordinator.setPendingSearchTarget(searchTarget)

        let didLoadDocument = context.coordinator.loadDocumentIfNeeded(url, dirtyData: dirtyData, in: pdfView)
        context.coordinator.applyAppearance(theme: theme, zoomScale: zoomScale, force: didLoadDocument, in: pdfView)
        context.coordinator.restoreViewportPositionIfNeeded(
            viewportPosition,
            force: didChangeDocument || didLoadDocument,
            skip: searchTarget != nil,
            in: pdfView
        )
        context.coordinator.applySearch(searchState, theme: theme, in: pdfView)
        context.coordinator.applyMarkupCommand(markupCommand, in: pdfView)
        context.coordinator.applyUndoRedoCommands(undoSerial: undoCommandSerial, redoSerial: redoCommandSerial, in: pdfView)
    }

    static func dismantleNSView(_ pdfView: AnnotatingPDFView, coordinator: Coordinator) {
        coordinator.publishViewportPosition(from: pdfView)
        coordinator.detach()
    }

    final class Coordinator {
        var documentID: String?
        var onSearchResult: (DocumentSearchResult) -> Void = { _ in }
        var onSearchTargetConsumed: () -> Void = {}
        var onViewportPositionChange: (PDFDocumentViewportPosition) -> Void = { _ in }
        private var documentURL: URL?
        private var lastAppliedTheme: AppTheme?
        private var lastZoomScale: Double?
        private var lastSearchRequest: DocumentSearchRequest?
        private var lastSearchHighlightTheme: SearchHighlightTheme?
        private var matches: [PDFSelection] = []
        private var currentMatchIndex = 0
        private var pendingSearchTarget: WorkspaceSearchPDFTarget?
        private var lastMarkupCommandSerial = 0
        private var lastUndoCommandSerial = 0
        private var lastRedoCommandSerial = 0
        private var shouldRestoreViewportPosition = false
        private var lastPublishedViewportPosition: PDFDocumentViewportPosition?
        private var isRestoringViewportPosition = false

        func attach(to pdfView: AnnotatingPDFView) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pdfViewViewportDidChange(_:)),
                name: .PDFViewPageChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pdfViewViewportDidChange(_:)),
                name: .PDFViewVisiblePagesChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pdfViewViewportDidChange(_:)),
                name: .PDFViewScaleChanged,
                object: pdfView
            )
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
        }

        func acceptCurrentUndoRedoSerials(undoSerial: Int, redoSerial: Int) {
            lastUndoCommandSerial = undoSerial
            lastRedoCommandSerial = redoSerial
        }

        func prepareForDocument(
            _ nextDocumentID: String,
            undoSerial: Int,
            redoSerial: Int,
            in pdfView: AnnotatingPDFView
        ) -> Bool {
            guard documentID != nextDocumentID else { return false }

            publishViewportPosition(from: pdfView)
            documentID = nextDocumentID
            acceptCurrentUndoRedoSerials(undoSerial: undoSerial, redoSerial: redoSerial)
            lastPublishedViewportPosition = nil
            shouldRestoreViewportPosition = true
            return true
        }

        @discardableResult
        func loadDocumentIfNeeded(_ url: URL, dirtyData: Data?, in pdfView: AnnotatingPDFView) -> Bool {
            let standardizedURL = url.standardizedFileURL
            guard documentURL != standardizedURL else { return false }

            documentURL = standardizedURL
            matches = []
            currentMatchIndex = 0
            lastSearchRequest = nil
            lastSearchHighlightTheme = nil
            performWithoutPublishingViewportChanges {
                if let dirtyData, let dirtyDocument = PDFDocument(data: dirtyData) {
                    pdfView.document = dirtyDocument
                } else {
                    pdfView.document = PDFDocument(url: standardizedURL)
                }
                pdfView.autoScales = true
                pdfView.layoutDocumentView()
            }
            pdfView.clearAnnotationUndoHistory()
            shouldRestoreViewportPosition = true
            onSearchResult(.init())
            return true
        }

        func setPendingSearchTarget(_ target: WorkspaceSearchPDFTarget?) {
            guard let target else { return }
            pendingSearchTarget = target
        }

        func applyAppearance(theme: AppTheme, zoomScale: Double, force: Bool, in pdfView: AnnotatingPDFView) {
            pdfView.backgroundColor = NSColor(hex: theme.background)

            guard force || lastAppliedTheme != theme || lastZoomScale != zoomScale else {
                return
            }

            lastAppliedTheme = theme
            lastZoomScale = zoomScale

            let destination = pdfView.currentDestination

            performWithoutPublishingViewportChanges {
                if abs(zoomScale - 1) < 0.001 {
                    pdfView.autoScales = true
                } else {
                    let sizeToFitScale = pdfView.scaleFactorForSizeToFit
                    if sizeToFitScale.isFinite, sizeToFitScale > 0 {
                        let nextScale = max(pdfView.minScaleFactor, min(pdfView.maxScaleFactor, sizeToFitScale * CGFloat(zoomScale)))
                        pdfView.autoScales = false
                        pdfView.scaleFactor = nextScale
                    } else {
                        pdfView.autoScales = true
                    }
                }

                pdfView.layoutDocumentView()

                if let destination {
                    pdfView.go(to: destination)
                }
            }
        }

        func applySearch(_ state: DocumentSearchState, theme: AppTheme, in pdfView: AnnotatingPDFView) {
            let request = DocumentSearchRequest(state)
            guard request.isPresented, !request.query.isEmpty, let document = pdfView.document else {
                if shouldClearSearch(for: request) {
                    clearSearch(in: pdfView)
                }
                lastSearchRequest = request
                return
            }

            let queryDidChange = request.query != lastSearchRequest?.query
            let navigationDidChange = request.navigationSerial != lastSearchRequest?.navigationSerial
            if queryDidChange {
                matches = document.findString(request.query, withOptions: [.caseInsensitive, .diacriticInsensitive])
                currentMatchIndex = matches.isEmpty ? 0 : 0
                lastSearchHighlightTheme = nil
            } else if navigationDidChange, !matches.isEmpty {
                switch request.navigationDirection {
                case .next:
                    currentMatchIndex = (currentMatchIndex + 1) % matches.count
                case .previous:
                    currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
                }
            }

            var shouldRevealSelection = queryDidChange || navigationDidChange
            if let targetIndex = pendingTargetIndex(in: pdfView), !matches.isEmpty {
                currentMatchIndex = targetIndex
                pendingSearchTarget = nil
                shouldRevealSelection = true
                onSearchTargetConsumed()
            }

            let highlightTheme = SearchHighlightTheme(theme: theme)
            if lastSearchHighlightTheme != highlightTheme {
                let highlightColor = NSColor(hex: theme.accent).withAlphaComponent(theme.isDark ? 0.38 : 0.28)
                matches.forEach { selection in
                    selection.color = highlightColor
                }
                pdfView.highlightedSelections = matches
                lastSearchHighlightTheme = highlightTheme
            }

            if matches.isEmpty {
                pdfView.clearSelection()
                onSearchResult(.init())
            } else {
                let selection = matches[currentMatchIndex]
                if shouldRevealSelection {
                    pdfView.setCurrentSelection(selection, animate: true)
                    pdfView.go(to: selection)
                    publishViewportPosition(from: pdfView)
                }
                onSearchResult(DocumentSearchResult(currentIndex: currentMatchIndex + 1, totalCount: matches.count))
            }

            lastSearchRequest = request
        }

        func applyMarkupCommand(_ command: PDFTextMarkupCommand?, in pdfView: AnnotatingPDFView) {
            guard let command, command.serial != lastMarkupCommandSerial else { return }
            lastMarkupCommandSerial = command.serial
            pdfView.addTextMarkup(kind: command.kind, color: command.color.nsColor)
        }

        func applyUndoRedoCommands(undoSerial: Int, redoSerial: Int, in pdfView: AnnotatingPDFView) {
            if undoSerial != lastUndoCommandSerial {
                lastUndoCommandSerial = undoSerial
                pdfView.undoAnnotationEdit()
            }

            if redoSerial != lastRedoCommandSerial {
                lastRedoCommandSerial = redoSerial
                pdfView.redoAnnotationEdit()
            }
        }

        func restoreViewportPositionIfNeeded(
            _ position: PDFDocumentViewportPosition?,
            force: Bool,
            skip: Bool,
            in pdfView: AnnotatingPDFView
        ) {
            if force {
                shouldRestoreViewportPosition = true
            }

            guard shouldRestoreViewportPosition else { return }
            guard !skip else {
                shouldRestoreViewportPosition = false
                return
            }

            shouldRestoreViewportPosition = false
            guard let position,
                  let document = pdfView.document,
                  let destination = position.destination(in: document)
            else {
                return
            }

            performWithoutPublishingViewportChanges {
                pdfView.layoutDocumentView()
                pdfView.go(to: destination)
            }
            lastPublishedViewportPosition = position
            onViewportPositionChange(position)
        }

        func publishViewportPosition(from pdfView: PDFView) {
            guard !isRestoringViewportPosition,
                  let position = PDFDocumentViewportPosition(pdfView: pdfView),
                  position != lastPublishedViewportPosition
            else {
                return
            }

            lastPublishedViewportPosition = position
            onViewportPositionChange(position)
        }

        @objc private func pdfViewViewportDidChange(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView else { return }
            publishViewportPosition(from: pdfView)
        }

        private func performWithoutPublishingViewportChanges(_ body: () -> Void) {
            isRestoringViewportPosition = true
            defer { isRestoringViewportPosition = false }
            body()
        }

        private func clearSearch(in pdfView: AnnotatingPDFView) {
            matches = []
            currentMatchIndex = 0
            if pendingSearchTarget != nil {
                pendingSearchTarget = nil
                onSearchTargetConsumed()
            }
            lastSearchHighlightTheme = nil
            pdfView.highlightedSelections = nil
            pdfView.clearSelection()
            onSearchResult(.init())
        }

        private func shouldClearSearch(for request: DocumentSearchRequest) -> Bool {
            return !matches.isEmpty
                || lastSearchHighlightTheme != nil
                || pendingSearchTarget != nil
                || (lastSearchRequest?.isPresented == true && !request.isPresented)
        }

        private func pendingTargetIndex(in pdfView: AnnotatingPDFView) -> Int? {
            guard let target = pendingSearchTarget, !matches.isEmpty else { return nil }

            if target.matchIndex >= 0,
               target.matchIndex < matches.count,
               isSelection(matches[target.matchIndex], onPage: target.page, in: pdfView) {
                return target.matchIndex
            }

            return matches.firstIndex { selection in
                isSelection(selection, onPage: target.page, in: pdfView)
            }
        }

        private func isSelection(_ selection: PDFSelection, onPage pageNumber: Int, in pdfView: AnnotatingPDFView) -> Bool {
            guard pageNumber > 0, let document = pdfView.document else { return false }
            return selection.pages.contains { page in
                document.index(for: page) + 1 == pageNumber
            }
        }

        private struct SearchHighlightTheme: Equatable {
            let accent: String
            let isDark: Bool

            init(theme: AppTheme) {
                self.accent = theme.accent
                self.isDark = theme.isDark
            }
        }
    }
}

private extension PDFDocumentViewportPosition {
    init?(pdfView: PDFView) {
        guard let document = pdfView.document,
              let destination = pdfView.currentDestination,
              let page = destination.page
        else {
            return nil
        }

        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return nil }

        self.init(
            pageIndex: pageIndex,
            point: DocumentScrollPosition(destination.point)
        )
    }

    func destination(in document: PDFDocument) -> PDFDestination? {
        guard pageIndex >= 0, let page = document.page(at: pageIndex) else {
            return nil
        }

        return PDFDestination(page: page, at: point.point)
    }
}

private final class AnnotatingPDFView: PDFView {
    var annotationMode: PDFAnnotationInteractionMode = .select {
        didSet {
            if oldValue != annotationMode {
                discardActiveInkAnnotation()
                syncToolTrackingArea()
                window?.invalidateCursorRects(for: self)
                setToolCursorIfPointerIsInside()
            }
        }
    }
    var annotationColor: NSColor = PDFAnnotationPaletteColor.yellow.nsColor
    var annotationLineWidth: CGFloat = 3
    var onEdited: (Data?, Data) -> Void = { _, _ in }
    var onUndoStateChanged: (Bool, Bool) -> Void = { _, _ in }
    var onError: (String) -> Void = { _ in }

    private weak var activeInkPage: PDFPage?
    private var activeInkPoints: [CGPoint] = []
    private var activeInkAnnotation: PDFAnnotation?
    private var activeInkBaselineData: Data?
    private var toolTrackingArea: NSTrackingArea?
    private var undoStack: [PDFAnnotationEditOperation] = []
    private var redoStack: [PDFAnnotationEditOperation] = []
    private var toolCursor: NSCursor {
        PDFAnnotationToolCursor.cursor(for: annotationMode)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }

        let flags = event.modifierFlags.independentFlags
        if characters == "z",
           flags.contains(.command),
           !flags.contains(.option),
           !flags.contains(.control) {
            if flags.contains(.shift) {
                redoAnnotationEdit()
            } else {
                undoAnnotationEdit()
            }
            return
        }

        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        if annotationMode == .select {
            super.resetCursorRects()
        } else {
            // In annotation modes Markprev owns the cursor; PDFView cursor rects otherwise compete with it.
            addCursorRect(bounds, cursor: toolCursor)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        syncToolTrackingArea()
    }

    override func cursorUpdate(with event: NSEvent) {
        guard annotationMode != .select else {
            super.cursorUpdate(with: event)
            return
        }
        toolCursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        if annotationMode == .select {
            super.mouseMoved(with: event)
        } else {
            toolCursor.set()
        }
    }

    private func syncToolTrackingArea() {
        if let toolTrackingArea {
            if trackingAreas.contains(where: { $0 === toolTrackingArea }) {
                removeTrackingArea(toolTrackingArea)
            }
            self.toolTrackingArea = nil
        }

        guard annotationMode != .select else { return }

        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .cursorUpdate, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        toolTrackingArea = nextTrackingArea
    }

    private func setToolCursorIfPointerIsInside() {
        guard annotationMode != .select, let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(point) {
            toolCursor.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        switch annotationMode {
        case .select:
            super.mouseDown(with: event)
        case .pen:
            guard canAnnotate() else { return }
            guard let target = pagePoint(for: event) else { return }
            activeInkPage = target.page
            activeInkPoints = [target.point]
            activeInkAnnotation = nil
            activeInkBaselineData = document?.dataRepresentation()
        case .eraser:
            eraseAnnotation(at: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        switch annotationMode {
        case .select:
            super.mouseDragged(with: event)
        case .pen:
            guard let activeInkPage,
                  let target = pagePoint(for: event),
                  target.page === activeInkPage else {
                return
            }

            if let last = activeInkPoints.last, squaredDistance(from: last, to: target.point) < 1.8 {
                return
            }

            activeInkPoints.append(target.point)
            renderActiveInkAnnotation(finalizing: false)
        case .eraser:
            eraseAnnotation(at: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch annotationMode {
        case .select:
            super.mouseUp(with: event)
        case .pen:
            if activeInkPoints.count > 1 {
                let inkPage = activeInkPage
                if let annotation = renderActiveInkAnnotation(finalizing: true),
                   let inkPage,
                   let document {
                    registerAnnotationEdit(
                        PDFAnnotationEditOperation(
                            added: [.init(pageIndex: document.index(for: inkPage), annotation: annotation)],
                            removed: []
                        )
                    )
                }
                publishEditedDocument(previousData: activeInkBaselineData)
            } else {
                discardActiveInkAnnotation()
            }
            activeInkBaselineData = nil
        case .eraser:
            break
        }
    }

    func addTextMarkup(kind: PDFTextMarkupKind, color: NSColor) {
        guard canAnnotate() else { return }
        guard let selection = currentSelection,
              !selection.pages.isEmpty,
              selection.string?.isEmpty == false else {
            onError(PDFAnnotationOperationError.noSelection.localizedDescription)
            return
        }

        guard let document else { return }
        let previousData = document.dataRepresentation()

        let lineSelections = selection.selectionsByLine()
        var addedAnnotations: [PDFAnnotationEditOperation.Item] = []

        for lineSelection in lineSelections {
            for page in lineSelection.pages {
                let bounds = lineSelection.bounds(for: page).insetBy(dx: -1, dy: -1)
                guard bounds.width > 0, bounds.height > 0 else { continue }

                let annotation = PDFAnnotation(bounds: bounds, forType: kind.annotationSubtype, withProperties: nil)
                annotation.color = kind == .highlight ? color.withAlphaComponent(0.46) : color
                annotation.contents = selection.string
                annotation.userName = NSFullUserName()
                annotation.modificationDate = Date()
                annotation.shouldDisplay = true
                annotation.shouldPrint = true
                annotation.setValue(quadPoints(for: bounds), forAnnotationKey: .quadPoints)
                page.addAnnotation(annotation)
                addedAnnotations.append(.init(pageIndex: document.index(for: page), annotation: annotation))
            }
        }

        guard !addedAnnotations.isEmpty else {
            onError(PDFAnnotationOperationError.noSelection.localizedDescription)
            return
        }

        registerAnnotationEdit(PDFAnnotationEditOperation(added: addedAnnotations, removed: []))
        refreshAnnotationDisplay()
        clearSelection()
        publishEditedDocument(previousData: previousData)
    }

    @discardableResult
    private func renderActiveInkAnnotation(finalizing: Bool) -> PDFAnnotation? {
        guard let activeInkPage else { return nil }

        if let activeInkAnnotation {
            activeInkPage.removeAnnotation(activeInkAnnotation)
            self.activeInkAnnotation = nil
        }

        guard let annotation = inkAnnotation(points: activeInkPoints) else { return nil }
        activeInkPage.addAnnotation(annotation)

        if finalizing {
            self.activeInkPage = nil
            activeInkPoints = []
        } else {
            activeInkAnnotation = annotation
        }

        refreshAnnotationDisplay(on: activeInkPage)
        return annotation
    }

    private func discardActiveInkAnnotation() {
        if let activeInkPage, let activeInkAnnotation {
            activeInkPage.removeAnnotation(activeInkAnnotation)
        }
        activeInkPoints = []
        activeInkPage = nil
        activeInkAnnotation = nil
        activeInkBaselineData = nil
    }

    private func inkAnnotation(points: [CGPoint]) -> PDFAnnotation? {
        guard points.count > 1 else { return nil }

        let padding = max(annotationLineWidth * 2, 3)
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let bounds = CGRect(
            x: minX - padding,
            y: minY - padding,
            width: max(maxX - minX + padding * 2, annotationLineWidth * 2),
            height: max(maxY - minY + padding * 2, annotationLineWidth * 2)
        )

        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = annotationLineWidth

        if let first = points.first {
            path.move(to: CGPoint(x: first.x - bounds.minX, y: first.y - bounds.minY))
        }
        for point in points.dropFirst() {
            path.line(to: CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY))
        }

        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        let border = PDFBorder()
        border.style = .solid
        border.lineWidth = annotationLineWidth
        annotation.border = border
        annotation.color = annotationColor
        annotation.userName = NSFullUserName()
        annotation.modificationDate = Date()
        annotation.shouldDisplay = true
        annotation.shouldPrint = true
        annotation.add(path)
        return annotation
    }

    private func eraseAnnotation(at event: NSEvent) {
        guard canAnnotate() else { return }
        guard let target = pagePoint(for: event),
              let annotation = annotationForErasing(on: target.page, at: target.point),
              let document else {
            return
        }

        let previousData = document.dataRepresentation()
        let removedItem = PDFAnnotationEditOperation.Item(pageIndex: document.index(for: target.page), annotation: annotation)
        target.page.removeAnnotation(annotation)
        registerAnnotationEdit(PDFAnnotationEditOperation(added: [], removed: [removedItem]))
        refreshAnnotationDisplay(on: target.page)
        publishEditedDocument(previousData: previousData)
    }

    func undoAnnotationEdit() {
        guard let operation = undoStack.popLast() else { return }
        applyInverse(operation)
        redoStack.append(operation)
        publishUndoState()
        publishEditedDocument(previousData: nil)
    }

    func redoAnnotationEdit() {
        guard let operation = redoStack.popLast() else { return }
        apply(operation)
        undoStack.append(operation)
        publishUndoState()
        publishEditedDocument(previousData: nil)
    }

    func clearAnnotationUndoHistory() {
        undoStack = []
        redoStack = []
        publishUndoState()
    }

    private func registerAnnotationEdit(_ operation: PDFAnnotationEditOperation) {
        guard !operation.added.isEmpty || !operation.removed.isEmpty else { return }
        undoStack.append(operation)
        redoStack = []
        publishUndoState()
    }

    private func apply(_ operation: PDFAnnotationEditOperation) {
        for item in operation.removed {
            page(at: item.pageIndex)?.removeAnnotation(item.annotation)
        }

        for item in operation.added {
            page(at: item.pageIndex)?.addAnnotation(item.annotation)
        }

        refreshAnnotationDisplay()
    }

    private func applyInverse(_ operation: PDFAnnotationEditOperation) {
        for item in operation.added {
            page(at: item.pageIndex)?.removeAnnotation(item.annotation)
        }

        for item in operation.removed {
            page(at: item.pageIndex)?.addAnnotation(item.annotation)
        }

        refreshAnnotationDisplay()
    }

    private func page(at pageIndex: Int) -> PDFPage? {
        guard pageIndex >= 0 else { return nil }
        return document?.page(at: pageIndex)
    }

    private func publishUndoState() {
        onUndoStateChanged(!undoStack.isEmpty, !redoStack.isEmpty)
    }

    private func refreshAnnotationDisplay(on page: PDFPage? = nil) {
        if let page {
            let pageBounds = page.bounds(for: displayBox)
            setNeedsDisplay(convert(pageBounds, from: page))
        } else {
            needsDisplay = true
            documentView?.needsDisplay = true
        }
    }

    private func publishEditedDocument(previousData: Data?) {
        guard let data = document?.dataRepresentation() else {
            onError(PDFAnnotationOperationError.dataRepresentationFailed.localizedDescription)
            return
        }
        onEdited(previousData, data)
    }

    private func canAnnotate() -> Bool {
        guard let document else {
            onError(PDFAnnotationOperationError.noDocument.localizedDescription)
            return false
        }

        if document.isLocked {
            onError(PDFAnnotationOperationError.locked.localizedDescription)
            return false
        }

        if !document.allowsCommenting {
            onError(PDFAnnotationOperationError.commentingNotAllowed.localizedDescription)
            return false
        }

        return true
    }

    private func pagePoint(for event: NSEvent) -> (page: PDFPage, point: CGPoint)? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else {
            return nil
        }
        return (page, convert(viewPoint, to: page))
    }

    private func annotationForErasing(on page: PDFPage, at point: CGPoint) -> PDFAnnotation? {
        let tolerance = max(annotationLineWidth * 2.2, 8)
        return PDFAnnotationHitTesting.annotationForErasing(on: page, at: point, tolerance: tolerance)
    }

    private func quadPoints(for bounds: CGRect) -> [NSNumber] {
        [
            NSNumber(value: Double(bounds.minX)),
            NSNumber(value: Double(bounds.maxY)),
            NSNumber(value: Double(bounds.maxX)),
            NSNumber(value: Double(bounds.maxY)),
            NSNumber(value: Double(bounds.minX)),
            NSNumber(value: Double(bounds.minY)),
            NSNumber(value: Double(bounds.maxX)),
            NSNumber(value: Double(bounds.minY))
        ]
    }

    private func squaredDistance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}

private enum PDFAnnotationInteractionMode: Equatable {
    case select
    case pen
    case eraser
}

private struct PDFAnnotationEditOperation {
    struct Item {
        let pageIndex: Int
        let annotation: PDFAnnotation
    }

    let added: [Item]
    let removed: [Item]
}

private enum PDFAnnotationToolCursor {
    static func cursor(for mode: PDFAnnotationInteractionMode) -> NSCursor {
        switch mode {
        case .select:
            return .arrow
        case .pen:
            return pen
        case .eraser:
            return eraser
        }
    }

    private static let pen = symbolCursor(systemName: "pencil.tip", fallback: .crosshair, hotSpot: CGPoint(x: 3, y: 21))
    private static let eraser = symbolCursor(systemName: "eraser", fallback: .pointingHand, hotSpot: CGPoint(x: 5, y: 18))

    private static func symbolCursor(systemName: String, fallback: NSCursor, hotSpot: CGPoint) -> NSCursor {
        guard let symbol = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else {
            return fallback
        }

        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        NSColor.labelColor.set()
        symbol.draw(
            in: NSRect(x: 2, y: 2, width: 20, height: 20),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: hotSpot)
    }
}

private enum PDFTextMarkupKind: Equatable {
    case highlight
    case underline
    case strikeOut

    var annotationSubtype: PDFAnnotationSubtype {
        switch self {
        case .highlight:
            return .highlight
        case .underline:
            return .underline
        case .strikeOut:
            return .strikeOut
        }
    }
}

private struct PDFTextMarkupCommand: Equatable {
    let serial: Int
    let kind: PDFTextMarkupKind
    let color: PDFAnnotationPaletteColor
}

private struct PDFAnnotationPaletteColor: Identifiable, Equatable {
    let id: String
    let name: String
    let hex: String

    var color: Color {
        Color(hex: hex)
    }

    var nsColor: NSColor {
        NSColor(hex: hex)
    }

    static let yellow = PDFAnnotationPaletteColor(id: "yellow", name: "Yellow", hex: "#ffd84d")
    static let green = PDFAnnotationPaletteColor(id: "green", name: "Green", hex: "#76d672")
    static let blue = PDFAnnotationPaletteColor(id: "blue", name: "Blue", hex: "#66b8ff")
    static let pink = PDFAnnotationPaletteColor(id: "pink", name: "Pink", hex: "#ff6fae")
    static let red = PDFAnnotationPaletteColor(id: "red", name: "Red", hex: "#ef5350")
    static let graphite = PDFAnnotationPaletteColor(id: "graphite", name: "Graphite", hex: "#d8dee9")

    static let all: [PDFAnnotationPaletteColor] = [.yellow, .green, .blue, .pink, .red, .graphite]
}

private enum PDFAnnotationOperationError: LocalizedError {
    case noDocument
    case locked
    case commentingNotAllowed
    case noSelection
    case dataRepresentationFailed

    var errorDescription: String? {
        switch self {
        case .noDocument:
            return "No PDF document is loaded."
        case .locked:
            return "This PDF is locked."
        case .commentingNotAllowed:
            return "This PDF does not allow annotations."
        case .noSelection:
            return "Select PDF text before applying markup."
        case .dataRepresentationFailed:
            return "PDFKit could not prepare the annotated document."
        }
    }
}
