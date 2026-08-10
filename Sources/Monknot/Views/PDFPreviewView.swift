import AppKit
import MonknotCore
import PDFKit
import SwiftUI

struct PDFPreviewView: View {
    let document: WorkspaceDocument
    let theme: AppTheme
    let zoomScale: Double
    let saveState: DocumentSaveState
    let dirtyData: Data?
    let contentVersion: Int
    let viewportState: PDFDocumentViewportState?
    let viewportCaptureBridge: PDFViewportCaptureBridge
    let externalUndoCommandSerial: Int
    let externalRedoCommandSerial: Int
    @Binding var searchState: DocumentSearchState
    @Binding var searchTarget: WorkspaceSearchPDFTarget?
    let markEdited: (Data?, Data) -> Void
    let reportError: (String) -> Void
    let saveDocument: () -> Void
    var pageNavigationRequest: PDFPageNavigationRequest? = nil
    var externalNavigatorToggleCommandSerial: Int = 0
    var insertLinkedExcerpt: (PDFSelectionSnapshot) -> Void = { _ in }
    var onSelectionSnapshotChange: (PDFSelectionSnapshot?) -> Void = { _ in }
    var onPageNavigationRequestConsumed: (PDFPageNavigationRequest) -> Void = { _ in }

    let onViewportStateChange: (PDFDocumentViewportState) -> Void
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
    @State private var zoomCommand: PDFZoomCommandRequest?
    @State private var zoomCommandSerial = 0
    @State private var zoomStatus = PDFZoomStatus.unavailable
    @State private var pageStatus = PDFPageStatus.unavailable
    @State private var loadState = PDFLoadState.loading
    @State private var markupHint: String?
    @State private var isNavigatorPresented = false
    @State private var lastNavigatorToggleCommandSerial = 0

    var body: some View {
        VStack(spacing: 0) {
            MonknotChromePanel(theme: theme) {
                PDFAnnotationToolbar(
                    interactionMode: $interactionMode,
                    selectedColor: $selectedColor,
                    strokeWidth: $strokeWidth,
                    saveState: saveState,
                    canUndo: canUndo,
                    canRedo: canRedo,
                    isDocumentAvailable: loadState == .loaded,
                    theme: theme,
                    zoomScale: zoomScale,
                    runMarkup: runMarkup(_:),
                    undo: runUndo,
                    redo: runRedo,
                    pageStatus: pageStatus,
                    zoomStatus: zoomStatus,
                    runZoom: runZoom(_:),
                    saveDocument: saveDocument,
                    isNavigatorPresented: isNavigatorPresented,
                    toggleNavigator: toggleNavigator
                )
            }

            if let markupHint {
                HStack(spacing: scaled(8)) {
                    Image(systemName: "text.cursor")
                        .font(.system(
                            size: MonknotMetrics.interfaceGlyph(15, theme: theme, zoomScale: zoomScale),
                            weight: .regular
                        ))
                        .foregroundStyle(theme.accentColor)

                    Text(markupHint)
                        .font(.system(
                            size: MonknotMetrics.interfaceText(12.5, theme: theme, zoomScale: zoomScale),
                            weight: .regular
                        ))
                        .foregroundStyle(theme.foregroundColor)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, scaled(12))
                .frame(height: scaled(32))
                .background(theme.accentColor.opacity(theme.isDark ? 0.18 : 0.14))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.separatorColor).frame(height: 1)
                }
                .transition(.opacity)
            }

            ZStack {
                PDFKitPreviewRepresentable(
                    documentID: document.id,
                    url: document.url,
                    dirtyData: dirtyData,
                    contentVersion: contentVersion,
                    theme: theme,
                    viewportState: viewportState,
                    viewportCaptureBridge: viewportCaptureBridge,
                    annotationMode: interactionMode,
                    annotationColor: selectedColor,
                    strokeWidth: CGFloat(strokeWidth),
                    markupCommand: markupCommand,
                    zoomCommand: zoomCommand,
                    undoCommandSerial: externalUndoCommandSerial + undoCommandSerial,
                    redoCommandSerial: externalRedoCommandSerial + redoCommandSerial,
                    pageNavigationRequest: pageNavigationRequest,
                    isNavigatorPresented: isNavigatorPresented,
                    navigatorWidth: scaled(224),
                    searchState: $searchState,
                    searchTarget: $searchTarget,
                    markEdited: markEdited,
                    insertLinkedExcerpt: insertLinkedExcerpt,
                    onSelectionSnapshotChange: onSelectionSnapshotChange,
                    onPageNavigationRequestConsumed: onPageNavigationRequestConsumed,
                    onViewportStateChange: onViewportStateChange,
                    updatePageStatus: updatePageStatus(_:),
                    updateZoomStatus: updateZoomStatus(_:),
                    updateUndoState: updateUndoState(canUndo:canRedo:),
                    updateLoadState: updateLoadState(_:),
                    reportError: handleAnnotationError(_:)
                )
                .opacity(loadState == .loaded ? 1 : 0)

                pdfLoadStatus
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.surfaceColor)
        .onChange(of: document.id) { _, _ in
            loadState = .loading
            markupHint = nil
            onSelectionSnapshotChange(nil)
        }
        .onAppear {
            lastNavigatorToggleCommandSerial = externalNavigatorToggleCommandSerial
        }
        .onChange(of: externalNavigatorToggleCommandSerial) { _, serial in
            guard serial != lastNavigatorToggleCommandSerial else { return }
            lastNavigatorToggleCommandSerial = serial
            toggleNavigator()
        }
        .task(id: markupHint) {
            guard markupHint != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(MonknotMotion.hoverAnimation) {
                markupHint = nil
            }
        }
    }

    private func runMarkup(_ kind: PDFTextMarkupKind) {
        markupCommandSerial += 1
        markupCommand = PDFTextMarkupCommand(
            serial: markupCommandSerial,
            kind: kind,
            color: selectedColor
        )
    }

    private func handleAnnotationError(_ message: String) {
        if message == PDFAnnotationOperationError.noSelection.localizedDescription {
            withAnimation(MonknotMotion.hoverAnimation) {
                markupHint = markupCommand?.kind.selectionHint ?? "Select text on the page before applying markup."
            }
        } else {
            reportError(message)
        }
    }

    private func runUndo() {
        undoCommandSerial += 1
    }

    private func runRedo() {
        redoCommandSerial += 1
    }

    private func runZoom(_ command: PDFZoomCommand) {
        zoomCommandSerial += 1
        zoomCommand = PDFZoomCommandRequest(serial: zoomCommandSerial, command: command)
    }

    private func toggleNavigator() {
        isNavigatorPresented.toggle()
    }

    private func updateZoomStatus(_ status: PDFZoomStatus) {
        if zoomStatus != status {
            zoomStatus = status
        }
    }

    private func updatePageStatus(_ status: PDFPageStatus) {
        if pageStatus != status {
            pageStatus = status
        }
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

    private func updateLoadState(_ state: PDFLoadState) {
        if loadState != state {
            loadState = state
        }
    }

    @ViewBuilder
    private var pdfLoadStatus: some View {
        switch loadState {
        case .loading:
            VStack(spacing: scaled(10)) {
                ProgressView()
                    .controlSize(.small)

                Text("Opening PDF…")
                    .font(MonknotTypography.emptyStateDetail(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.mutedForegroundColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Opening PDF")
        case .loaded:
            EmptyView()
        case .failed:
            MonknotEmptyState(
                systemImage: "exclamationmark.triangle",
                title: "Unable to open PDF",
                detail: "The file may be damaged, incomplete, or unavailable.",
                theme: theme,
                zoomScale: zoomScale
            ) {
                EmptyView()
            }
        }
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }
}

private enum PDFLoadState: Equatable {
    case loading
    case loaded
    case failed
}

private enum PDFStrokeWidthPopoverAnchor: Equatable {
    case compact
    case minimal
}

private enum PDFToolbarMenuHoverTarget: Equatable {
    case tool
    case style
    case more
}

enum PDFZoomCommand: Equatable {
    case zoomOut
    case zoomIn
    case fitToView
    case actualSize
    case preset(scaleFactor: Double)
}

struct PDFZoomCommandRequest: Equatable {
    let serial: Int
    let command: PDFZoomCommand
}

struct PDFPageNavigationRequest: Equatable, Sendable {
    let serial: Int
    let documentID: String
    let pageNumber: Int
}

struct PDFDocumentLoadIdentity: Equatable {
    let url: URL
    let contentVersion: Int

    init(url: URL, contentVersion: Int) {
        self.url = url.standardizedFileURL
        self.contentVersion = contentVersion
    }
}

struct PDFZoomStatus: Equatable {
    let mode: PDFZoomMode
    let scaleFactor: Double
    let isAvailable: Bool

    static let unavailable = PDFZoomStatus(
        mode: .fixed(scaleFactor: 1),
        scaleFactor: 0,
        isAvailable: false
    )

    static let presetPercentages = [100, 120, 140, 160, 180, 200]

    var displayLabel: String {
        guard isAvailable else { return "—" }
        return "\(Int((scaleFactor * 100).rounded()))%"
    }

    var isActualSize: Bool {
        guard case .fixed(let scaleFactor) = mode else { return false }
        return abs(scaleFactor - 1) < 0.002
    }

    func matchesPreset(_ percentage: Int) -> Bool {
        guard case .fixed = mode else { return false }
        return abs(scaleFactor - Double(percentage) / 100) < 0.002
    }
}

struct PDFPageStatus: Equatable {
    let currentPage: Int
    let pageCount: Int
    let isAvailable: Bool

    static let unavailable = PDFPageStatus(currentPage: 0, pageCount: 0, isAvailable: false)

    var displayLabel: String {
        guard isAvailable else { return "—/—" }
        return "\(currentPage)/\(pageCount)"
    }
}

private struct PDFAnnotationToolbar: View {
    @Binding var interactionMode: PDFAnnotationInteractionMode
    @Binding var selectedColor: PDFAnnotationPaletteColor
    @Binding var strokeWidth: Double
    let saveState: DocumentSaveState
    let canUndo: Bool
    let canRedo: Bool
    let isDocumentAvailable: Bool
    let theme: AppTheme
    let zoomScale: Double
    let runMarkup: (PDFTextMarkupKind) -> Void
    let undo: () -> Void
    let redo: () -> Void
    let pageStatus: PDFPageStatus
    let zoomStatus: PDFZoomStatus
    let runZoom: (PDFZoomCommand) -> Void
    let saveDocument: () -> Void
    let isNavigatorPresented: Bool
    let toggleNavigator: () -> Void

    @State private var strokeWidthPopoverAnchor: PDFStrokeWidthPopoverAnchor?
    @State private var hoveredMenu: PDFToolbarMenuHoverTarget?

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            regularToolbar
            annotationToolbar
            compactToolbar
            minimalToolbar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, scaled(10))
        .frame(height: MonknotMetrics.interfaceControl(36, theme: theme, zoomScale: zoomScale))
        .frame(maxWidth: .infinity)
        .disabled(!isDocumentAvailable)
        .opacity(isDocumentAvailable ? 1 : 0.42)
        .animation(.easeOut(duration: 0.14), value: interactionMode)
        .onChange(of: interactionMode) { _, mode in
            if mode != .pen {
                strokeWidthPopoverAnchor = nil
            }
        }
    }

    private var regularToolbar: some View {
        HStack(spacing: scaled(5)) {
            pageIndicator
            toolbarDivider
            navigatorButton
            toolbarDivider
            toolbarContent
            toolbarDivider
            strokeWidthControl
            toolbarDivider
            zoomToolbar
            saveButtonIfNeeded
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compactToolbar: some View {
        HStack(spacing: scaled(5)) {
            pageIndicator
            toolbarDivider
            navigatorButton
            toolMenu
            MonknotIconButton(
                systemImage: "highlighter",
                label: "Highlight Selection",
                theme: theme,
                zoomScale: zoomScale,
                size: .compact
            ) {
                runMarkup(.highlight)
            }
            MonknotIconButton(
                systemImage: "underline",
                label: "Underline Selection",
                theme: theme,
                zoomScale: zoomScale,
                size: .compact
            ) {
                runMarkup(.underline)
            }
            MonknotIconButton(
                systemImage: "strikethrough",
                label: "Strike Through Selection",
                theme: theme,
                zoomScale: zoomScale,
                size: .compact
            ) {
                runMarkup(.strikeOut)
            }
            styleMenu(anchor: .compact)
            moreMenu
            toolbarDivider
            zoomToolbar
            saveButtonIfNeeded
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Keeps the high-frequency markup actions visible at ordinary editor
    /// widths while collapsing the palette, stroke, and history controls.
    /// `ViewThatFits` selects this only when the complete toolbar cannot fit.
    private var annotationToolbar: some View {
        HStack(spacing: scaled(5)) {
            pageIndicator
            toolbarDivider
            navigatorButton
            selectButton

            MonknotIconButton(
                systemImage: "highlighter",
                label: "Highlight Selection",
                theme: theme,
                zoomScale: zoomScale,
                size: .compact
            ) {
                runMarkup(.highlight)
            }

            MonknotIconButton(
                systemImage: "underline",
                label: "Underline Selection",
                theme: theme,
                zoomScale: zoomScale,
                size: .compact
            ) {
                runMarkup(.underline)
            }

            MonknotIconButton(
                systemImage: "strikethrough",
                label: "Strike Through Selection",
                theme: theme,
                zoomScale: zoomScale,
                size: .compact
            ) {
                runMarkup(.strikeOut)
            }

            penButton
            eraserButton
            colorPalette
            moreMenu
            toolbarDivider
            zoomToolbar
            saveButtonIfNeeded
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var minimalToolbar: some View {
        HStack(spacing: scaled(5)) {
            pageIndicator
            toolbarDivider
            navigatorButton
            toolMenu
            styleMenu(anchor: .minimal)
            moreMenu
            toolbarDivider
            zoomToolbar
            saveButtonIfNeeded
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var zoomToolbar: some View {
        PDFZoomToolbarGroup(
            status: zoomStatus,
            theme: theme,
            zoomScale: zoomScale,
            runZoom: runZoom
        )
    }

    private var toolbarContent: some View {
        HStack(spacing: scaled(5)) {
            undoButton
            redoButton

            toolbarDivider

            selectButton

            MonknotIconButton(
                systemImage: "highlighter",
                label: "Highlight Selection",
                theme: theme,
                zoomScale: zoomScale,
                size: .compact
            ) {
                runMarkup(.highlight)
            }

            MonknotIconButton(
                systemImage: "underline",
                label: "Underline Selection",
                theme: theme,
                zoomScale: zoomScale,
                size: .compact
            ) {
                runMarkup(.underline)
            }

            MonknotIconButton(
                systemImage: "strikethrough",
                label: "Strike Through Selection",
                theme: theme,
                zoomScale: zoomScale,
                size: .compact
            ) {
                runMarkup(.strikeOut)
            }

            penButton
            eraserButton

            toolbarDivider

            colorPalette
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var colorPalette: some View {
        HStack(spacing: scaled(3)) {
            ForEach(PDFAnnotationPaletteColor.all) { color in
                PDFColorSwatchButton(
                    color: color,
                    isSelected: color == selectedColor,
                    theme: theme,
                    zoomScale: zoomScale
                ) {
                    selectedColor = color
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var undoButton: some View {
        MonknotIconButton(
            systemImage: "arrow.uturn.backward",
            label: "Undo",
            theme: theme,
            zoomScale: zoomScale,
            isDisabled: !canUndo,
            size: .compact,
            action: undo
        )
    }

    private var redoButton: some View {
        MonknotIconButton(
            systemImage: "arrow.uturn.forward",
            label: "Redo",
            theme: theme,
            zoomScale: zoomScale,
            isDisabled: !canRedo,
            size: .compact,
            action: redo
        )
    }

    private var selectButton: some View {
        MonknotIconButton(
            systemImage: "cursorarrow",
            label: "Select",
            theme: theme,
            zoomScale: zoomScale,
            isActive: interactionMode == .select,
            size: .compact
        ) {
            interactionMode = .select
        }
        .accessibilityAddTraits(interactionMode == .select ? .isSelected : [])
    }

    private var penButton: some View {
        MonknotIconButton(
            systemImage: "pencil.tip",
            label: "Draw",
            theme: theme,
            zoomScale: zoomScale,
            isActive: interactionMode == .pen,
            size: .compact
        ) {
            interactionMode = interactionMode == .pen ? .select : .pen
        }
        .accessibilityAddTraits(interactionMode == .pen ? .isSelected : [])
    }

    private var eraserButton: some View {
        MonknotIconButton(
            systemImage: "eraser",
            label: "Erase Annotation",
            theme: theme,
            zoomScale: zoomScale,
            isActive: interactionMode == .eraser,
            size: .compact
        ) {
            interactionMode = interactionMode == .eraser ? .select : .eraser
        }
        .accessibilityAddTraits(interactionMode == .eraser ? .isSelected : [])
    }

    private var toolMenu: some View {
        Menu {
            Button("Select", systemImage: "cursorarrow") {
                interactionMode = .select
            }
            Button("Draw", systemImage: "pencil.tip") {
                interactionMode = .pen
            }
            Button("Erase Annotation", systemImage: "eraser") {
                interactionMode = .eraser
            }
        } label: {
            toolbarMenuLabel(
                systemImage: interactionModeSystemImage,
                isActive: true,
                isHovered: hoveredMenu == .tool
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { updateMenuHover(.tool, isHovered: $0) }
        .help("Annotation Tool")
        .accessibilityLabel("Annotation Tool")
        .accessibilityValue(interactionModeAccessibilityValue)
        .accessibilityAddTraits(.isSelected)
    }

    private func styleMenu(anchor: PDFStrokeWidthPopoverAnchor) -> some View {
        Menu {
            ForEach(PDFAnnotationPaletteColor.all) { color in
                Button {
                    selectedColor = color
                } label: {
                    HStack {
                        Text(color.name)
                        if color == selectedColor {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button("Stroke Width…", systemImage: "lineweight") {
                strokeWidthPopoverAnchor = anchor
            }
        } label: {
            styleMenuLabel(isHovered: hoveredMenu == .style)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { updateMenuHover(.style, isHovered: $0) }
        .help("Annotation Style")
        .accessibilityLabel("Annotation Style")
        .accessibilityValue("\(selectedColor.name), \(Int(strokeWidth)) point stroke")
        .popover(isPresented: popoverBinding(for: anchor), arrowEdge: .top) {
            strokeWidthPopoverContent
        }
    }

    private func popoverBinding(for anchor: PDFStrokeWidthPopoverAnchor) -> Binding<Bool> {
        Binding(
            get: { strokeWidthPopoverAnchor == anchor },
            set: { isPresented in
                if !isPresented, strokeWidthPopoverAnchor == anchor {
                    strokeWidthPopoverAnchor = nil
                }
            }
        )
    }

    private var moreMenu: some View {
        Menu {
            if !saveState.isClean {
                Button("Save PDF", systemImage: "externaldrive.badge.checkmark", action: saveDocument)
                    .disabled(saveState == .saving)

                Divider()
            }

            Button("Undo", systemImage: "arrow.uturn.backward", action: undo)
                .disabled(!canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward", action: redo)
                .disabled(!canRedo)

            Divider()

            markupCommands
        } label: {
            toolbarMenuLabel(
                systemImage: "ellipsis",
                isActive: false,
                isHovered: hoveredMenu == .more
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { updateMenuHover(.more, isHovered: $0) }
        .help("More PDF actions")
        .accessibilityLabel("More PDF actions")
    }

    private var navigatorButton: some View {
        MonknotIconButton(
            systemImage: "sidebar.left",
            label: isNavigatorPresented ? "Hide PDF Navigator" : "Show PDF Navigator",
            theme: theme,
            zoomScale: zoomScale,
            isActive: isNavigatorPresented,
            size: .compact,
            action: toggleNavigator
        )
        .accessibilityAddTraits(isNavigatorPresented ? .isSelected : [])
    }

    @ViewBuilder
    private var markupCommands: some View {
        Button("Highlight Selection", systemImage: "highlighter") {
            runMarkup(.highlight)
        }
        Button("Underline Selection", systemImage: "underline") {
            runMarkup(.underline)
        }
        Button("Strike Through Selection", systemImage: "strikethrough") {
            runMarkup(.strikeOut)
        }
    }

    private func toolbarMenuLabel(
        systemImage: String,
        isActive: Bool,
        isHovered: Bool
    ) -> some View {
        let buttonSize = MonknotIconButton.IconButtonSize.compact
        let dimension = buttonSize.dimension(theme: theme, zoomScale: zoomScale)
        let shape = RoundedRectangle(
            cornerRadius: buttonSize.cornerRadius(theme: theme, zoomScale: zoomScale)
        )

        return Image(systemName: systemImage)
            .font(.system(
                size: buttonSize.iconSize(theme: theme, zoomScale: zoomScale),
                weight: .regular
            ))
            .foregroundStyle(isActive || isHovered ? theme.foregroundColor : theme.mutedForegroundColor)
            .frame(width: dimension, height: dimension)
            .background {
                if isActive || isHovered {
                    shape.fill(theme.foregroundColor.opacity(
                        isActive
                            ? MonknotIconButton.IconButtonSize.chrome.activeBackgroundOpacity(
                                isDark: theme.isDark
                            )
                            : MonknotIconButton.IconButtonSize.chrome.hoverBackgroundOpacity(
                                isDark: theme.isDark
                            )
                    ))
                }
            }
            .overlay {
                if isActive {
                    shape.strokeBorder(theme.borderColor, lineWidth: 1)
                }
            }
            .contentShape(shape)
    }

    private func styleMenuLabel(isHovered: Bool) -> some View {
        let buttonSize = MonknotIconButton.IconButtonSize.compact
        let dimension = buttonSize.dimension(theme: theme, zoomScale: zoomScale)
        let colorSize = MonknotMetrics.interfaceControl(16, theme: theme, zoomScale: zoomScale)
        let shape = RoundedRectangle(cornerRadius: buttonSize.cornerRadius(theme: theme, zoomScale: zoomScale))

        return HStack(spacing: scaled(4)) {
            Image(systemName: "circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(selectedColor.color)
                .font(.system(size: colorSize, weight: .regular))
                .overlay {
                    Circle()
                        .strokeBorder(theme.surfaceColor.opacity(0.85), lineWidth: 1)
                }

            Image(systemName: "chevron.down")
                .font(.system(
                    size: MonknotMetrics.interfaceGlyph(8, theme: theme, zoomScale: zoomScale),
                    weight: .semibold
                ))
                .foregroundStyle(theme.mutedForegroundColor)
        }
        .frame(width: scaled(42), height: dimension)
        .background(theme.controlTrackFillColor, in: shape)
        .overlay {
            if isHovered {
                shape.fill(theme.foregroundColor.opacity(
                    MonknotIconButton.IconButtonSize.chrome.hoverBackgroundOpacity(
                        isDark: theme.isDark
                    )
                ))
            }
        }
        .overlay {
            shape
                .strokeBorder(theme.borderColor, lineWidth: 1)
        }
        .contentShape(shape)
    }

    private func updateMenuHover(_ target: PDFToolbarMenuHoverTarget, isHovered: Bool) {
        if isHovered {
            hoveredMenu = target
        } else if hoveredMenu == target {
            hoveredMenu = nil
        }
    }

    private var interactionModeSystemImage: String {
        switch interactionMode {
        case .select:
            return "cursorarrow"
        case .pen:
            return "pencil.tip"
        case .eraser:
            return "eraser"
        }
    }

    private var interactionModeAccessibilityValue: String {
        switch interactionMode {
        case .select:
            return "Select"
        case .pen:
            return "Draw"
        case .eraser:
            return "Erase"
        }
    }

    private var strokeWidthPopoverContent: some View {
        VStack(alignment: .leading, spacing: scaled(10)) {
            HStack {
                Text("Stroke Width")
                    .font(.system(
                        size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: zoomScale),
                        weight: .semibold
                    ))

                Spacer(minLength: scaled(12))

                Text("\(Int(strokeWidth)) pt")
                    .font(.system(
                        size: MonknotMetrics.interfaceText(11, theme: theme, zoomScale: zoomScale),
                        weight: .medium,
                        design: .monospaced
                    ))
                    .foregroundStyle(theme.mutedForegroundColor)
            }

            Slider(value: $strokeWidth, in: 1...10, step: 1)
                .tint(selectedColor.color)
        }
        .padding(scaled(12))
        .frame(width: scaled(210))
        .background(theme.elevatedSurfaceColor)
    }

    private var strokeWidthControl: some View {
        HStack(spacing: scaled(8)) {
            Text("Thickness")
                .font(.system(
                    size: MonknotMetrics.interfaceText(11, theme: theme, zoomScale: zoomScale),
                    weight: .regular
                ))
                .foregroundStyle(theme.mutedForegroundColor)

            Slider(value: $strokeWidth, in: 1...10, step: 1)
                .tint(selectedColor.color)
                .frame(width: scaled(90))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stroke Thickness")
        .accessibilityValue("\(Int(strokeWidth)) points")
    }

    @ViewBuilder
    private var saveButtonIfNeeded: some View {
        if !saveState.isClean {
            saveButton
        }
    }

    private var saveButton: some View {
        MonknotIconButton(
            systemImage: "externaldrive.badge.checkmark",
            label: "Save PDF",
            theme: theme,
            zoomScale: zoomScale,
            isActive: !saveState.isClean,
            isDisabled: saveState == .saving,
            size: .compact
        ) {
            saveDocument()
        }
    }

    private var pageIndicator: some View {
        Text(pageStatus.displayLabel)
            .font(.system(
                size: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: zoomScale),
                weight: .regular,
                design: .monospaced
            ))
            .foregroundStyle(pageStatus.isAvailable ? theme.mutedForegroundColor : theme.disabledForegroundColor)
            .monospacedDigit()
            .lineLimit(1)
            .frame(minWidth: scaled(34), alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(
                pageStatus.isAvailable
                    ? "Page \(pageStatus.currentPage) of \(pageStatus.pageCount)"
                    : "Page unavailable"
            )
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(theme.borderColor)
            .frame(width: 1, height: scaled(20))
            .accessibilityHidden(true)
    }
}

struct PDFZoomToolbarGroup: View {
    let status: PDFZoomStatus
    let theme: AppTheme
    let zoomScale: Double
    let runZoom: (PDFZoomCommand) -> Void

    @State private var isMenuHovered = false
    @FocusState private var isMenuFocused: Bool

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: theme, zoomScale: zoomScale)
    }

    private func glyphScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceGlyph(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        Menu {
            ForEach(PDFZoomStatus.presetPercentages, id: \.self) { percentage in
                Button {
                    runZoom(.preset(scaleFactor: Double(percentage) / 100))
                } label: {
                    HStack {
                        Text("\(percentage)%")
                        if status.matchesPreset(percentage) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: scaled(6)) {
                Text(status.displayLabel)
                    .font(.system(size: textScaled(13), weight: .regular))
                    .monospacedDigit()
                    .lineLimit(1)

                PDFZoomChevron()
                    .stroke(
                        style: StrokeStyle(
                            lineWidth: scaled(1.4),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .frame(width: glyphScaled(9), height: glyphScaled(5))
            }
            .foregroundStyle(zoomControlForegroundColor)
            .padding(.leading, scaled(10))
            .padding(.trailing, scaled(9))
            .frame(height: MonknotMetrics.interfaceControl(28, theme: theme, zoomScale: zoomScale))
            .background(zoomControlBackgroundColor, in: zoomControlShape)
            .overlay {
                zoomControlShape
                    .strokeBorder(theme.borderColor, lineWidth: 1)
            }
            .overlay {
                if isMenuFocused, status.isAvailable {
                    zoomControlShape
                        .stroke(theme.accentColor.opacity(0.35), lineWidth: 3)
                        .padding(-2)
                }
            }
            .contentShape(zoomControlShape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(!status.isAvailable)
        .focusable(status.isAvailable)
        .focused($isMenuFocused)
        .focusEffectDisabled()
        .opacity(status.isAvailable ? 1 : 0.42)
        .onHover { isMenuHovered = $0 }
        .help("PDF Zoom")
        .accessibilityLabel("PDF Zoom")
        .accessibilityValue(status.displayLabel)
        .fixedSize(horizontal: true, vertical: false)
        .animation(.easeOut(duration: 0.12), value: isMenuHovered)
    }

    private var zoomControlShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
    }

    private var zoomControlForegroundColor: Color {
        guard status.isAvailable else { return theme.disabledForegroundColor }
        return isMenuHovered ? theme.foregroundColor : theme.mutedForegroundColor
    }

    private var zoomControlBackgroundColor: Color {
        guard status.isAvailable else { return theme.controlTrackFillColor }
        if isMenuHovered {
            return theme.foregroundColor.opacity(theme.isDark ? 0.085 : 0.06)
        }
        return theme.controlTrackFillColor
    }
}

private struct PDFZoomChevron: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

private struct PDFColorSwatchButton: View {
    let color: PDFAnnotationPaletteColor
    let isSelected: Bool
    let theme: AppTheme
    let zoomScale: Double
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isSelected || isHovered ? theme.controlTrackFillColor : Color.clear)

                Circle()
                    .fill(color.color)
                    .frame(
                        width: MonknotMetrics.interfaceControl(15, theme: theme, zoomScale: zoomScale),
                        height: MonknotMetrics.interfaceControl(15, theme: theme, zoomScale: zoomScale)
                    )
                    .overlay {
                        Circle()
                            .strokeBorder(theme.surfaceColor.opacity(0.85), lineWidth: 1)
                    }
            }
            .frame(
                width: MonknotMetrics.interfaceControl(26, theme: theme, zoomScale: zoomScale),
                height: MonknotMetrics.interfaceControl(26, theme: theme, zoomScale: zoomScale)
            )
            .overlay {
                if isFocused {
                    Circle()
                        .strokeBorder(theme.accentColor.opacity(0.9), lineWidth: 1.5)
                        .padding(1)
                } else if isSelected {
                    Circle()
                        .strokeBorder(theme.borderColor, lineWidth: 1)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(MonknotControlPressStyle())
        .focusable()
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .help(color.name)
        .accessibilityLabel(color.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .monknotPointerCursor()
    }
}

final class PDFPreviewContainerView: NSView {
    let pdfView = AnnotatingPDFView()
    let navigatorView = PDFNavigatorView()

    private let separatorView = NSView()
    private var navigatorWidthConstraint: NSLayoutConstraint!
    private var pdfLeadingWithNavigatorConstraint: NSLayoutConstraint!
    private var pdfLeadingWithoutNavigatorConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureViews()
    }

    func setNavigatorWidth(_ width: CGFloat) {
        navigatorWidthConstraint.constant = max(180, min(280, width))
    }

    func setNavigatorPresented(_ isPresented: Bool) {
        navigatorView.isHidden = !isPresented
        separatorView.isHidden = !isPresented
        if isPresented {
            pdfLeadingWithoutNavigatorConstraint.isActive = false
            pdfLeadingWithNavigatorConstraint.isActive = true
        } else {
            pdfLeadingWithNavigatorConstraint.isActive = false
            pdfLeadingWithoutNavigatorConstraint.isActive = true
        }
        navigatorView.setPresented(isPresented)
    }

    func applyAppearance(theme: AppTheme) {
        separatorView.layer?.backgroundColor = NSColor(hex: theme.foreground)
            .withAlphaComponent(theme.isDark ? 0.09 : 0.12)
            .cgColor
        navigatorView.applyAppearance(theme: theme)
    }

    func prepareForDismantle() {
        navigatorView.prepareForDismantle()
        pdfView.prepareForDismantle()
    }

    private func configureViews() {
        navigatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.wantsLayer = true

        addSubview(navigatorView)
        addSubview(separatorView)
        addSubview(pdfView)

        navigatorWidthConstraint = navigatorView.widthAnchor.constraint(equalToConstant: 224)
        pdfLeadingWithNavigatorConstraint = pdfView.leadingAnchor.constraint(equalTo: separatorView.trailingAnchor)
        pdfLeadingWithoutNavigatorConstraint = pdfView.leadingAnchor.constraint(equalTo: leadingAnchor)

        NSLayoutConstraint.activate([
            navigatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            navigatorView.topAnchor.constraint(equalTo: topAnchor),
            navigatorView.bottomAnchor.constraint(equalTo: bottomAnchor),
            navigatorWidthConstraint,
            separatorView.leadingAnchor.constraint(equalTo: navigatorView.trailingAnchor),
            separatorView.topAnchor.constraint(equalTo: topAnchor),
            separatorView.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorView.widthAnchor.constraint(equalToConstant: 1),
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
            pdfLeadingWithoutNavigatorConstraint
        ])

        navigatorView.isHidden = true
        separatorView.isHidden = true
    }
}

enum PDFNavigatorSection: Int {
    case pages
    case outline
    case annotations
}

struct PDFNavigatorAnnotationItem {
    let pageIndex: Int
    let annotation: PDFAnnotation
    let kind: String
    let excerpt: String?

    var label: String {
        let pageLabel = "Page \(pageIndex + 1) · \(kind)"
        guard let excerpt else { return pageLabel }
        return "\(pageLabel)\n\(excerpt)"
    }
}

final class PDFNavigatorView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let thumbnailView = PDFThumbnailView()
    let outlineView = NSOutlineView()
    let annotationTableView = NSTableView()
    private(set) var annotationItems: [PDFNavigatorAnnotationItem] = []

    private let headerView = NSView()
    private let segmentedControl = NSSegmentedControl(
        labels: ["Pages", "Outline", "Annotations"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let headerSeparatorView = NSView()
    private let contentView = NSView()
    private let outlineScrollView = NSScrollView()
    private let annotationScrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private weak var pdfView: AnnotatingPDFView?
    private var outlineRoot: PDFOutline?
    private var selectedSection = PDFNavigatorSection.pages
    private var isPresented = false
    private var annotationsNeedReload = true
    private var foregroundColor = NSColor.labelColor
    private var mutedForegroundColor = NSColor.secondaryLabelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureViews()
    }

    func attach(to pdfView: AnnotatingPDFView) {
        guard self.pdfView !== pdfView else { return }
        thumbnailView.pdfView = nil
        self.pdfView = pdfView
        documentDidChange()
    }

    func setPresented(_ isPresented: Bool) {
        guard self.isPresented != isPresented else { return }
        self.isPresented = isPresented
        if isPresented {
            showSelectedSection()
        } else {
            thumbnailView.pdfView = nil
        }
    }

    func documentDidChange() {
        outlineRoot = nil
        annotationsNeedReload = true
        annotationItems = []
        if isPresented {
            showSelectedSection()
        }
    }

    func noteAnnotationsChanged() {
        annotationsNeedReload = true
        if isPresented, selectedSection == .annotations {
            reloadAnnotationsIfNeeded()
            updateEmptyState()
        }
    }

    func selectSection(_ section: PDFNavigatorSection) {
        selectedSection = section
        segmentedControl.selectedSegment = section.rawValue
        showSelectedSection()
    }

    func applyAppearance(theme: AppTheme) {
        let foreground = NSColor(hex: theme.foreground)
        foregroundColor = foreground
        mutedForegroundColor = foreground.withAlphaComponent(theme.isDark ? 0.62 : 0.64)
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: theme.background)
            .blended(withFraction: theme.isDark ? 0.055 : 0.035, of: foreground)?
            .cgColor
        headerSeparatorView.layer?.backgroundColor = foreground
            .withAlphaComponent(theme.isDark ? 0.09 : 0.12)
            .cgColor
        emptyLabel.textColor = mutedForegroundColor
        outlineView.reloadData()
        annotationTableView.reloadData()
    }

    func prepareForDismantle() {
        thumbnailView.pdfView = nil
        pdfView = nil
        outlineRoot = nil
        annotationItems = []
        segmentedControl.target = nil
        segmentedControl.action = nil
        outlineView.delegate = nil
        outlineView.dataSource = nil
        annotationTableView.delegate = nil
        annotationTableView.dataSource = nil
    }

    private func configureViews() {
        wantsLayer = true
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerSeparatorView.translatesAutoresizingMaskIntoConstraints = false
        headerSeparatorView.wantsLayer = true
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)
        addSubview(headerSeparatorView)
        addSubview(contentView)

        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.controlSize = .small
        segmentedControl.segmentStyle = .rounded
        segmentedControl.selectedSegment = PDFNavigatorSection.pages.rawValue
        segmentedControl.target = self
        segmentedControl.action = #selector(sectionChanged(_:))
        segmentedControl.setAccessibilityLabel("PDF Navigator")
        headerView.addSubview(segmentedControl)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 38),
            segmentedControl.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 8),
            segmentedControl.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),
            segmentedControl.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            headerSeparatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerSeparatorView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerSeparatorView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            headerSeparatorView.heightAnchor.constraint(equalToConstant: 1),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: headerSeparatorView.bottomAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        configureThumbnailView()
        configureOutlineView()
        configureAnnotationView()
        configureEmptyState()
        showSelectedSection()
    }

    private func configureThumbnailView() {
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.thumbnailSize = NSSize(width: 112, height: 150)
        thumbnailView.allowsDragging = false
        thumbnailView.allowsMultipleSelection = false
        thumbnailView.setAccessibilityLabel("PDF Pages")
        contentView.addSubview(thumbnailView)
        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            thumbnailView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            thumbnailView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            thumbnailView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4)
        ])
    }

    private func configureOutlineView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PDFNavigatorOutlineColumn"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 26
        outlineView.indentationPerLevel = 14
        outlineView.style = .sourceList
        outlineView.backgroundColor = .clear
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.setAccessibilityLabel("PDF Outline")

        outlineScrollView.translatesAutoresizingMaskIntoConstraints = false
        outlineScrollView.documentView = outlineView
        outlineScrollView.drawsBackground = false
        outlineScrollView.hasVerticalScroller = true
        contentView.addSubview(outlineScrollView)
        NSLayoutConstraint.activate([
            outlineScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            outlineScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            outlineScrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            outlineScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func configureAnnotationView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PDFNavigatorAnnotationColumn"))
        annotationTableView.addTableColumn(column)
        annotationTableView.headerView = nil
        annotationTableView.rowHeight = 44
        annotationTableView.style = .sourceList
        annotationTableView.backgroundColor = .clear
        annotationTableView.delegate = self
        annotationTableView.dataSource = self
        annotationTableView.setAccessibilityLabel("PDF Annotations")

        annotationScrollView.translatesAutoresizingMaskIntoConstraints = false
        annotationScrollView.documentView = annotationTableView
        annotationScrollView.drawsBackground = false
        annotationScrollView.hasVerticalScroller = true
        contentView.addSubview(annotationScrollView)
        NSLayoutConstraint.activate([
            annotationScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            annotationScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            annotationScrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            annotationScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func configureEmptyState() {
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2
        contentView.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16)
        ])
    }

    @objc private func sectionChanged(_ sender: NSSegmentedControl) {
        guard let section = PDFNavigatorSection(rawValue: sender.selectedSegment) else { return }
        selectSection(section)
    }

    private func showSelectedSection() {
        thumbnailView.isHidden = selectedSection != .pages
        outlineScrollView.isHidden = selectedSection != .outline
        annotationScrollView.isHidden = selectedSection != .annotations
        thumbnailView.pdfView = isPresented && selectedSection == .pages ? pdfView : nil

        if selectedSection == .outline {
            outlineRoot = pdfView?.document?.outlineRoot
            outlineView.reloadData()
            if outlineView.numberOfRows > 0 {
                outlineView.expandItem(nil, expandChildren: false)
            }
        } else if selectedSection == .annotations {
            reloadAnnotationsIfNeeded()
        }
        updateEmptyState()
    }

    private func updateEmptyState() {
        switch selectedSection {
        case .pages:
            emptyLabel.stringValue = "No pages"
            emptyLabel.isHidden = (pdfView?.document?.pageCount ?? 0) > 0
        case .outline:
            emptyLabel.stringValue = "No outline"
            emptyLabel.isHidden = (outlineRoot?.numberOfChildren ?? 0) > 0
        case .annotations:
            emptyLabel.stringValue = "No annotations"
            emptyLabel.isHidden = !annotationItems.isEmpty
        }
    }

    private func reloadAnnotationsIfNeeded() {
        guard annotationsNeedReload else { return }
        annotationsNeedReload = false
        annotationItems = Self.annotationItems(from: pdfView?.document)
        annotationTableView.reloadData()
    }

    static func annotationItems(from document: PDFDocument?) -> [PDFNavigatorAnnotationItem] {
        guard let document else { return [] }
        var items: [PDFNavigatorAnnotationItem] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let annotations = page.annotations
                .filter { annotationKind(for: $0) != nil }
                .sorted { lhs, rhs in
                    if lhs.bounds.maxY == rhs.bounds.maxY {
                        return lhs.bounds.minX < rhs.bounds.minX
                    }
                    return lhs.bounds.maxY > rhs.bounds.maxY
                }
            for annotation in annotations {
                guard let kind = annotationKind(for: annotation) else { continue }
                let trimmed = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines)
                let excerpt = trimmed.flatMap { value -> String? in
                    guard !value.isEmpty else { return nil }
                    return String(value.prefix(140))
                }
                items.append(PDFNavigatorAnnotationItem(
                    pageIndex: pageIndex,
                    annotation: annotation,
                    kind: kind,
                    excerpt: excerpt
                ))
            }
        }
        return items
    }

    private static func annotationKind(for annotation: PDFAnnotation) -> String? {
        let type = (annotation.type ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        switch type {
        case "highlight": return "Highlight"
        case "underline": return "Underline"
        case "strikeout": return "Strikeout"
        case "ink": return "Drawing"
        case "text": return "Note"
        case "freetext": return "Text"
        default: return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? PDFOutline ?? outlineRoot)?.numberOfChildren ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let parent = item as? PDFOutline ?? outlineRoot
        guard let parent,
              index >= 0,
              index < parent.numberOfChildren,
              let child = parent.child(at: index)
        else {
            return NSNull()
        }
        return child
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        ((item as? PDFOutline)?.numberOfChildren ?? 0) > 0
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("PDFNavigatorOutlineCell")
        let cell = textCell(in: outlineView, identifier: identifier, maximumNumberOfLines: 1)
        cell.textField?.stringValue = (item as? PDFOutline)?.label ?? "Untitled section"
        cell.textField?.textColor = foregroundColor
        cell.textField?.font = .systemFont(ofSize: 12)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0,
              let outline = outlineView.item(atRow: row) as? PDFOutline,
              let destination = outline.destination
        else {
            return
        }
        pdfView?.go(to: destination)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        annotationItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < annotationItems.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("PDFNavigatorAnnotationCell")
        let cell = textCell(in: tableView, identifier: identifier, maximumNumberOfLines: 2)
        cell.textField?.stringValue = annotationItems[row].label
        cell.textField?.textColor = foregroundColor
        cell.textField?.font = .systemFont(ofSize: 11.5)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = annotationTableView.selectedRow
        guard row >= 0,
              row < annotationItems.count,
              let pdfView,
              let document = pdfView.document
        else {
            return
        }

        let item = annotationItems[row]
        guard let page = document.page(at: item.pageIndex),
              page.annotations.contains(where: { $0 === item.annotation })
        else {
            annotationsNeedReload = true
            reloadAnnotationsIfNeeded()
            updateEmptyState()
            return
        }

        let bounds = item.annotation.bounds
        let destination = PDFDestination(
            page: page,
            at: CGPoint(x: bounds.minX, y: bounds.maxY)
        )
        pdfView.go(to: destination)
    }

    private func textCell(
        in tableView: NSTableView,
        identifier: NSUserInterfaceItemIdentifier,
        maximumNumberOfLines: Int
    ) -> NSTableCellView {
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            return existing
        }

        let cell = NSTableCellView()
        cell.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = maximumNumberOfLines
        textField.usesSingleLineMode = maximumNumberOfLines == 1
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

struct PDFKitPreviewRepresentable: NSViewRepresentable {
    let documentID: String
    let url: URL
    let dirtyData: Data?
    let contentVersion: Int
    let theme: AppTheme
    let viewportState: PDFDocumentViewportState?
    let viewportCaptureBridge: PDFViewportCaptureBridge
    fileprivate let annotationMode: PDFAnnotationInteractionMode
    fileprivate let annotationColor: PDFAnnotationPaletteColor
    let strokeWidth: CGFloat
    fileprivate let markupCommand: PDFTextMarkupCommand?
    let zoomCommand: PDFZoomCommandRequest?
    let undoCommandSerial: Int
    let redoCommandSerial: Int
    let pageNavigationRequest: PDFPageNavigationRequest?
    let isNavigatorPresented: Bool
    let navigatorWidth: CGFloat
    @Binding var searchState: DocumentSearchState
    @Binding var searchTarget: WorkspaceSearchPDFTarget?
    let markEdited: (Data?, Data) -> Void
    let insertLinkedExcerpt: (PDFSelectionSnapshot) -> Void
    let onSelectionSnapshotChange: (PDFSelectionSnapshot?) -> Void
    let onPageNavigationRequestConsumed: (PDFPageNavigationRequest) -> Void
    let onViewportStateChange: (PDFDocumentViewportState) -> Void
    let updatePageStatus: (PDFPageStatus) -> Void
    let updateZoomStatus: (PDFZoomStatus) -> Void
    let updateUndoState: (Bool, Bool) -> Void
    fileprivate let updateLoadState: (PDFLoadState) -> Void
    let reportError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFPreviewContainerView {
        let container = PDFPreviewContainerView()
        let pdfView = container.pdfView
        pdfView.identifier = .monknotDocumentFocusTarget
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        pdfView.backgroundColor = NSColor(hex: theme.background)
        container.setNavigatorWidth(navigatorWidth)
        container.setNavigatorPresented(isNavigatorPresented)
        container.applyAppearance(theme: theme)
        context.coordinator.documentID = documentID
        context.coordinator.documentContentVersion = contentVersion
        context.coordinator.viewportCaptureBridge = viewportCaptureBridge
        viewportCaptureBridge.attach(documentID: documentID, to: pdfView)
        context.coordinator.onViewportStateChange = { state in
            DispatchQueue.main.async {
                self.onViewportStateChange(state)
            }
        }
        context.coordinator.onFinalViewportStateChange = onViewportStateChange
        context.coordinator.onZoomStatusChange = { status in
            DispatchQueue.main.async {
                self.updateZoomStatus(status)
            }
        }
        context.coordinator.onPageStatusChange = { status in
            DispatchQueue.main.async {
                self.updatePageStatus(status)
            }
        }
        context.coordinator.onLoadStateChange = { state in
            DispatchQueue.main.async {
                self.updateLoadState(state)
            }
        }
        context.coordinator.onSelectionSnapshotChange = { snapshot in
            DispatchQueue.main.async {
                self.onSelectionSnapshotChange(snapshot)
            }
        }
        context.coordinator.onPageNavigationRequestConsumed = { request in
            DispatchQueue.main.async {
                self.onPageNavigationRequestConsumed(request)
            }
        }
        context.coordinator.acceptCurrentCommandSerials(
            undoSerial: undoCommandSerial,
            redoSerial: redoCommandSerial,
            zoomSerial: zoomCommand?.serial ?? 0
        )
        context.coordinator.attach(to: pdfView)
        container.navigatorView.attach(to: pdfView)
        return container
    }

    func updateNSView(_ container: PDFPreviewContainerView, context: Context) {
        let pdfView = container.pdfView
        if context.coordinator.viewportCaptureBridge !== viewportCaptureBridge {
            context.coordinator.viewportCaptureBridge?.detach(from: pdfView)
            context.coordinator.viewportCaptureBridge = viewportCaptureBridge
        }
        viewportCaptureBridge.attach(documentID: documentID, to: pdfView)
        context.coordinator.documentContentVersion = contentVersion
        let didChangeDocument = context.coordinator.prepareForDocument(
            documentID,
            undoSerial: undoCommandSerial,
            redoSerial: redoCommandSerial,
            zoomSerial: zoomCommand?.serial ?? 0,
            in: pdfView
        )
        context.coordinator.onViewportStateChange = { state in
            DispatchQueue.main.async {
                self.onViewportStateChange(state)
            }
        }
        context.coordinator.onFinalViewportStateChange = onViewportStateChange
        context.coordinator.onZoomStatusChange = { status in
            DispatchQueue.main.async {
                self.updateZoomStatus(status)
            }
        }
        context.coordinator.onPageStatusChange = { status in
            DispatchQueue.main.async {
                self.updatePageStatus(status)
            }
        }
        context.coordinator.onLoadStateChange = { state in
            DispatchQueue.main.async {
                self.updateLoadState(state)
            }
        }
        context.coordinator.onSelectionSnapshotChange = { snapshot in
            DispatchQueue.main.async {
                self.onSelectionSnapshotChange(snapshot)
            }
        }
        context.coordinator.onPageNavigationRequestConsumed = { request in
            DispatchQueue.main.async {
                self.onPageNavigationRequestConsumed(request)
            }
        }
        pdfView.annotationMode = annotationMode
        pdfView.annotationColor = annotationColor.nsColor
        pdfView.annotationLineWidth = strokeWidth
        pdfView.linkedExcerptDocumentID = documentID
        pdfView.linkedExcerptContentVersion = contentVersion
        pdfView.onEdited = markEdited
        pdfView.onError = reportError
        pdfView.onRequestLinkedExcerpt = insertLinkedExcerpt
        pdfView.onAnnotationsChanged = { [weak navigatorView = container.navigatorView] in
            navigatorView?.noteAnnotationsChanged()
        }
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

        container.setNavigatorWidth(navigatorWidth)
        container.setNavigatorPresented(isNavigatorPresented)
        let didLoadDocument = context.coordinator.loadDocumentIfNeeded(
            url,
            dirtyData: dirtyData,
            contentVersion: contentVersion,
            in: pdfView,
            navigatorView: container.navigatorView
        )
        context.coordinator.applyAppearance(theme: theme, in: pdfView)
        container.applyAppearance(theme: theme)
        let hasMatchingPageRequest = pageNavigationRequest?.documentID == documentID
        context.coordinator.restoreViewportStateIfNeeded(
            viewportState,
            force: didChangeDocument || didLoadDocument,
            skipPosition: searchTarget != nil || hasMatchingPageRequest,
            in: pdfView
        )
        context.coordinator.applyPageNavigationRequest(
            pageNavigationRequest,
            in: pdfView,
            reportError: reportError
        )
        context.coordinator.applyZoomCommand(zoomCommand, in: pdfView)
        context.coordinator.applySearch(searchState, theme: theme, in: pdfView)
        context.coordinator.applyMarkupCommand(markupCommand, in: pdfView)
        context.coordinator.applyUndoRedoCommands(undoSerial: undoCommandSerial, redoSerial: redoCommandSerial, in: pdfView)
    }

    static func dismantleNSView(_ container: PDFPreviewContainerView, coordinator: Coordinator) {
        coordinator.publishFinalViewportState(from: container.pdfView)
        coordinator.viewportCaptureBridge?.detach(from: container.pdfView)
        coordinator.clearSelectionSnapshot()
        coordinator.detach()
        container.prepareForDismantle()
    }

    final class Coordinator {
        var documentID: String?
        var documentContentVersion = 0
        weak var viewportCaptureBridge: PDFViewportCaptureBridge?
        var onSearchResult: (DocumentSearchResult) -> Void = { _ in }
        var onSearchTargetConsumed: () -> Void = {}
        var onViewportStateChange: (PDFDocumentViewportState) -> Void = { _ in }
        var onFinalViewportStateChange: (PDFDocumentViewportState) -> Void = { _ in }
        var onPageStatusChange: (PDFPageStatus) -> Void = { _ in }
        var onZoomStatusChange: (PDFZoomStatus) -> Void = { _ in }
        fileprivate var onLoadStateChange: (PDFLoadState) -> Void = { _ in }
        var onSelectionSnapshotChange: (PDFSelectionSnapshot?) -> Void = { _ in }
        var onPageNavigationRequestConsumed: (PDFPageNavigationRequest) -> Void = { _ in }
        private var documentLoadIdentity: PDFDocumentLoadIdentity?
        private var lastAppliedTheme: AppTheme?
        private var lastSearchRequest: DocumentSearchRequest?
        private var lastSearchHighlightTheme: SearchHighlightTheme?
        private var matches: [PDFSelection] = []
        private var currentMatchIndex = 0
        private var pendingSearchTarget: WorkspaceSearchPDFTarget?
        private var lastMarkupCommandSerial = 0
        private var lastUndoCommandSerial = 0
        private var lastRedoCommandSerial = 0
        private var lastZoomCommandSerial = 0
        private var lastPageNavigationRequest: PDFPageNavigationRequest?
        private var shouldRestoreViewportState = false
        private var lastPublishedViewportState: PDFDocumentViewportState?
        private var lastPublishedPageStatus: PDFPageStatus?
        private var lastPublishedZoomStatus: PDFZoomStatus?
        private var lastPublishedSelectionSnapshot: PDFSelectionSnapshot?
        private var isRestoringViewportState = false

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
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pdfViewSelectionDidChange(_:)),
                name: .PDFViewSelectionChanged,
                object: pdfView
            )
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            onSearchResult = { _ in }
            onSearchTargetConsumed = {}
            onViewportStateChange = { _ in }
            onFinalViewportStateChange = { _ in }
            onPageStatusChange = { _ in }
            onZoomStatusChange = { _ in }
            onLoadStateChange = { _ in }
            onSelectionSnapshotChange = { _ in }
            onPageNavigationRequestConsumed = { _ in }
            viewportCaptureBridge = nil
            matches = []
            pendingSearchTarget = nil
        }

        func clearSelectionSnapshot() {
            lastPublishedSelectionSnapshot = nil
            onSelectionSnapshotChange(nil)
        }

        func acceptCurrentCommandSerials(undoSerial: Int, redoSerial: Int, zoomSerial: Int) {
            lastUndoCommandSerial = undoSerial
            lastRedoCommandSerial = redoSerial
            lastZoomCommandSerial = zoomSerial
        }

        func prepareForDocument(
            _ nextDocumentID: String,
            undoSerial: Int,
            redoSerial: Int,
            zoomSerial: Int,
            in pdfView: AnnotatingPDFView
        ) -> Bool {
            guard documentID != nextDocumentID else { return false }

            publishViewportState(from: pdfView)
            documentID = nextDocumentID
            acceptCurrentCommandSerials(
                undoSerial: undoSerial,
                redoSerial: redoSerial,
                zoomSerial: zoomSerial
            )
            lastPublishedViewportState = nil
            lastPublishedPageStatus = nil
            lastPublishedZoomStatus = nil
            lastPublishedSelectionSnapshot = nil
            onSelectionSnapshotChange(nil)
            shouldRestoreViewportState = true
            return true
        }

        @discardableResult
        func loadDocumentIfNeeded(
            _ url: URL,
            dirtyData: Data?,
            contentVersion: Int,
            in pdfView: AnnotatingPDFView,
            navigatorView: PDFNavigatorView
        ) -> Bool {
            let nextIdentity = PDFDocumentLoadIdentity(url: url, contentVersion: contentVersion)
            guard documentLoadIdentity != nextIdentity else { return false }

            documentLoadIdentity = nextIdentity
            matches = []
            currentMatchIndex = 0
            lastSearchRequest = nil
            lastSearchHighlightTheme = nil
            var loadedDocument: PDFDocument?
            performWithoutPublishingViewportStateChanges {
                if let dirtyData, let dirtyDocument = PDFDocument(data: dirtyData) {
                    loadedDocument = dirtyDocument
                } else {
                    loadedDocument = PDFDocument(url: nextIdentity.url)
                }
                pdfView.document = loadedDocument
                applyPDFZoomMode(.fixed(scaleFactor: 1), to: pdfView)
            }
            onLoadStateChange(loadedDocument == nil ? .failed : .loaded)
            pdfView.clearAnnotationUndoHistory()
            pdfView.resetEditBaselineCapture(needsSnapshot: dirtyData == nil)
            navigatorView.documentDidChange()
            shouldRestoreViewportState = true
            onSearchResult(.init())
            publishSelectionSnapshot(from: pdfView)
            return true
        }

        func setPendingSearchTarget(_ target: WorkspaceSearchPDFTarget?) {
            guard let target else { return }
            pendingSearchTarget = target
        }

        func applyAppearance(theme: AppTheme, in pdfView: AnnotatingPDFView) {
            guard lastAppliedTheme != theme else { return }
            lastAppliedTheme = theme
            pdfView.backgroundColor = NSColor(hex: theme.background)
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
                    publishViewportState(from: pdfView)
                }
                onSearchResult(DocumentSearchResult(currentIndex: currentMatchIndex + 1, totalCount: matches.count))
            }

            lastSearchRequest = request
        }

        fileprivate func applyMarkupCommand(_ command: PDFTextMarkupCommand?, in pdfView: AnnotatingPDFView) {
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

        func applyZoomCommand(_ request: PDFZoomCommandRequest?, in pdfView: AnnotatingPDFView) {
            guard let request, request.serial != lastZoomCommandSerial else { return }
            lastZoomCommandSerial = request.serial
            guard pdfView.document != nil else {
                publishZoomStatus(from: pdfView)
                return
            }

            performWithoutPublishingViewportStateChanges {
                applyPDFZoomCommand(request.command, to: pdfView)
            }
            publishViewportState(from: pdfView)
        }

        func applyPageNavigationRequest(
            _ request: PDFPageNavigationRequest?,
            in pdfView: AnnotatingPDFView,
            reportError: (String) -> Void
        ) {
            guard let request,
                  request.documentID == documentID,
                  request != lastPageNavigationRequest
            else {
                return
            }

            lastPageNavigationRequest = request
            defer { onPageNavigationRequestConsumed(request) }

            guard let document = pdfView.document,
                  let destination = pdfPageDestination(
                    pageNumber: request.pageNumber,
                    document: document,
                    displayBox: pdfView.displayBox
                  )
            else {
                reportError("Page \(request.pageNumber) is unavailable in this PDF.")
                return
            }

            performWithoutPublishingViewportStateChanges {
                pdfView.clearSelection()
                pdfView.go(to: destination)
            }
            publishSelectionSnapshot(from: pdfView)
            publishViewportState(from: pdfView)
        }

        func restoreViewportStateIfNeeded(
            _ state: PDFDocumentViewportState?,
            force: Bool,
            skipPosition: Bool,
            in pdfView: AnnotatingPDFView
        ) {
            if force {
                shouldRestoreViewportState = true
            }

            if let state,
               state.isMeaningfullyDifferent(from: lastPublishedViewportState) {
                shouldRestoreViewportState = true
            }

            guard shouldRestoreViewportState else { return }
            guard let document = pdfView.document else {
                publishZoomStatus(from: pdfView)
                return
            }
            shouldRestoreViewportState = false

            performWithoutPublishingViewportStateChanges {
                let restoredZoomMode: PDFZoomMode
                switch state?.zoomMode {
                case .fixed(let scaleFactor):
                    restoredZoomMode = .fixed(scaleFactor: scaleFactor)
                case .fitToView, .none:
                    restoredZoomMode = .fixed(scaleFactor: 1)
                }
                applyPDFZoomMode(restoredZoomMode, to: pdfView)
                pdfView.layoutDocumentView()

                if !skipPosition,
                   let position = state?.position,
                   let destination = position.destination(in: document, displayBox: pdfView.displayBox) {
                    pdfView.go(to: destination)
                }
            }
            publishViewportState(from: pdfView)
        }

        func publishViewportState(from pdfView: PDFView) {
            guard !isRestoringViewportState else { return }

            if let state = PDFDocumentViewportState(pdfView: pdfView),
               state.isMeaningfullyDifferent(from: lastPublishedViewportState) {
                lastPublishedViewportState = state
                onViewportStateChange(state)
            }

            publishPageStatus(from: pdfView)
            publishZoomStatus(from: pdfView)
        }

        func publishFinalViewportState(from pdfView: PDFView) {
            deliverFinalPDFViewportStateSynchronously(
                from: pdfView,
                to: onFinalViewportStateChange
            )
        }

        private func publishPageStatus(from pdfView: PDFView) {
            let status = PDFPageStatus(pdfView: pdfView)
            guard status != lastPublishedPageStatus else { return }
            lastPublishedPageStatus = status
            onPageStatusChange(status)
        }

        private func publishZoomStatus(from pdfView: PDFView) {
            let status = PDFZoomStatus(pdfView: pdfView)
            guard status != lastPublishedZoomStatus else {
                return
            }

            lastPublishedZoomStatus = status
            onZoomStatusChange(status)
        }

        @objc private func pdfViewViewportDidChange(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView else { return }
            publishViewportState(from: pdfView)
        }

        @objc private func pdfViewSelectionDidChange(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView else { return }
            publishSelectionSnapshot(from: pdfView)
        }

        private func publishSelectionSnapshot(from pdfView: PDFView) {
            let snapshot = makePDFSelectionSnapshot(
                documentID: documentID,
                contentVersion: documentContentVersion,
                document: pdfView.document,
                selection: pdfView.currentSelection
            )
            guard snapshot != lastPublishedSelectionSnapshot else { return }
            lastPublishedSelectionSnapshot = snapshot
            onSelectionSnapshotChange(snapshot)
        }

        private func performWithoutPublishingViewportStateChanges(_ body: () -> Void) {
            isRestoringViewportState = true
            defer { isRestoringViewportState = false }
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

@MainActor
final class PDFViewportCaptureBridge: ObservableObject {
    private var documentID: String?
    private weak var pdfView: PDFView?

    func attach(documentID: String, to pdfView: PDFView) {
        self.documentID = documentID
        self.pdfView = pdfView
    }

    func detach(from pdfView: PDFView) {
        guard self.pdfView === pdfView else { return }
        documentID = nil
        self.pdfView = nil
    }

    func capture() -> (documentID: String, state: PDFDocumentViewportState)? {
        guard let documentID,
              let pdfView,
              let state = PDFDocumentViewportState(pdfView: pdfView)
        else { return nil }
        return (documentID, state)
    }
}

func deliverFinalPDFViewportStateSynchronously(
    from pdfView: PDFView,
    to callback: (PDFDocumentViewportState) -> Void
) {
    precondition(Thread.isMainThread)
    guard let state = PDFDocumentViewportState(pdfView: pdfView) else { return }
    callback(state)
}

extension PDFDocumentViewportPosition {
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

    func destination(
        in document: PDFDocument,
        displayBox: PDFDisplayBox = .cropBox
    ) -> PDFDestination? {
        guard document.pageCount > 0 else {
            return nil
        }

        let clampedPageIndex = min(max(pageIndex, 0), document.pageCount - 1)
        guard let page = document.page(at: clampedPageIndex) else { return nil }
        let bounds = page.bounds(for: displayBox)
        let requestedPoint = point.point
        let x = requestedPoint.x.isFinite
            ? min(max(requestedPoint.x, bounds.minX), bounds.maxX)
            : bounds.minX
        let y = requestedPoint.y.isFinite
            ? min(max(requestedPoint.y, bounds.minY), bounds.maxY)
            : bounds.maxY
        return PDFDestination(page: page, at: CGPoint(x: x, y: y))
    }
}

extension PDFZoomMode {
    init(pdfView: PDFView) {
        if pdfView.autoScales {
            self = .fitToView
        } else {
            self = .fixed(scaleFactor: Double(pdfView.scaleFactor))
        }
    }
}

extension PDFDocumentViewportState {
    init?(pdfView: PDFView) {
        guard pdfView.document != nil,
              pdfView.scaleFactor.isFinite,
              pdfView.scaleFactor > 0
        else {
            return nil
        }

        self.init(
            position: PDFDocumentViewportPosition(pdfView: pdfView),
            zoomMode: PDFZoomMode(pdfView: pdfView)
        )
    }
}

extension PDFZoomStatus {
    init(pdfView: PDFView) {
        guard pdfView.document != nil,
              pdfView.scaleFactor.isFinite,
              pdfView.scaleFactor > 0
        else {
            self = .unavailable
            return
        }

        self.init(
            mode: PDFZoomMode(pdfView: pdfView),
            scaleFactor: Double(pdfView.scaleFactor),
            isAvailable: true
        )
    }
}

extension PDFPageStatus {
    init(pdfView: PDFView) {
        guard let document = pdfView.document,
              document.pageCount > 0,
              let page = pdfView.currentPage
        else {
            self = .unavailable
            return
        }

        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else {
            self = .unavailable
            return
        }

        self.init(
            currentPage: pageIndex + 1,
            pageCount: document.pageCount,
            isAvailable: true
        )
    }
}

/// Keeps document magnification in PDFKit instead of Monknot's interface zoom.
/// The retired fit-to-view state is normalized to 100%; active zoom uses
/// PDFKit's own minimum/maximum scale bounds.
/// https://developer.apple.com/documentation/pdfkit/pdfview/scalefactor
func applyPDFZoomMode(_ mode: PDFZoomMode, to pdfView: PDFView) {
    switch mode {
    case .fitToView:
        pdfView.autoScales = false
        pdfView.scaleFactor = clampedPDFScaleFactor(1, in: pdfView)
    case .fixed(let scaleFactor):
        let requestedScale = CGFloat(scaleFactor)
        guard requestedScale.isFinite, requestedScale > 0 else {
            pdfView.autoScales = false
            pdfView.scaleFactor = clampedPDFScaleFactor(1, in: pdfView)
            break
        }

        pdfView.autoScales = false
        pdfView.scaleFactor = clampedPDFScaleFactor(requestedScale, in: pdfView)
    }

    pdfView.layoutDocumentView()
}

func applyPDFZoomCommand(_ command: PDFZoomCommand, to pdfView: PDFView) {
    switch command {
    case .zoomOut:
        guard pdfView.canZoomOut else { return }
        pdfView.autoScales = false
        pdfView.zoomOut(nil)
    case .zoomIn:
        guard pdfView.canZoomIn else { return }
        pdfView.autoScales = false
        pdfView.zoomIn(nil)
    case .fitToView:
        let destination = pdfView.currentDestination
        applyPDFZoomMode(.fitToView, to: pdfView)
        if let destination {
            pdfView.go(to: destination)
        }
    case .actualSize:
        let destination = pdfView.currentDestination
        applyPDFZoomMode(.fixed(scaleFactor: 1), to: pdfView)
        if let destination {
            pdfView.go(to: destination)
        }
    case .preset(let scaleFactor):
        let destination = pdfView.currentDestination
        applyPDFZoomMode(.fixed(scaleFactor: scaleFactor), to: pdfView)
        if let destination {
            pdfView.go(to: destination)
        }
    }
}

private func clampedPDFScaleFactor(_ requestedScale: CGFloat, in pdfView: PDFView) -> CGFloat {
    let nativeMinimum = pdfView.minScaleFactor
    let nativeMaximum = pdfView.maxScaleFactor
    let minimum = nativeMinimum.isFinite && nativeMinimum > 0 ? nativeMinimum : requestedScale
    let maximum = nativeMaximum.isFinite && nativeMaximum >= minimum
        ? nativeMaximum
        : Swift.max(requestedScale, minimum)
    return Swift.min(maximum, Swift.max(minimum, requestedScale))
}

func makePDFSelectionSnapshot(
    documentID: String?,
    contentVersion: Int = 0,
    document: PDFDocument?,
    selection: PDFSelection?
) -> PDFSelectionSnapshot? {
    guard let documentID,
          !documentID.isEmpty,
          let document,
          document.allowsCopying,
          let selection,
          let rawText = selection.string
    else {
        return nil
    }

    let text = rawText
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .trimmingCharacters(in: .newlines)
    guard text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil else {
        return nil
    }

    var pageIndices: Set<Int> = []
    for page in selection.pages {
        let index = document.index(for: page)
        guard index >= 0, index < document.pageCount else { return nil }
        pageIndices.insert(index)
    }
    guard pageIndices.count == 1, let pageIndex = pageIndices.first else {
        return nil
    }

    return PDFSelectionSnapshot(
        documentID: documentID,
        text: text,
        pageNumber: pageIndex + 1,
        contentVersion: contentVersion
    )
}

func pdfPageDestination(
    pageNumber: Int,
    document: PDFDocument,
    displayBox: PDFDisplayBox
) -> PDFDestination? {
    guard pageNumber > 0,
          pageNumber <= document.pageCount,
          let page = document.page(at: pageNumber - 1)
    else {
        return nil
    }
    let bounds = page.bounds(for: displayBox)
    return PDFDestination(
        page: page,
        at: CGPoint(x: bounds.minX, y: bounds.maxY)
    )
}

final class AnnotatingPDFView: PDFView {
    fileprivate var annotationMode: PDFAnnotationInteractionMode = .select {
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
    var onRequestLinkedExcerpt: (PDFSelectionSnapshot) -> Void = { _ in }
    var onAnnotationsChanged: () -> Void = {}
    var linkedExcerptDocumentID: String?
    var linkedExcerptContentVersion = 0

    private weak var activeInkPage: PDFPage?
    private var activeInkPoints: [CGPoint] = []
    private var activeInkAnnotation: PDFAnnotation?
    private var activeInkBaselineData: Data?
    private var toolTrackingArea: NSTrackingArea?
    private var undoStack: [PDFAnnotationEditOperation] = []
    private var redoStack: [PDFAnnotationEditOperation] = []
    private var needsEditBaselineSnapshot = true
    private var toolCursor: NSCursor {
        PDFAnnotationToolCursor.cursor(for: annotationMode)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func layout() {
        super.layout()
        if let scrollView = documentView?.enclosingScrollView {
            MonknotScrollbarStyle.apply(to: scrollView)
        }
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let title = "Insert Linked Excerpt into Markdown…"
        let item: NSMenuItem
        if let existingItem = menu.items.first(where: { $0.title == title }) {
            item = existingItem
        } else {
            if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false {
                menu.addItem(.separator())
            }
            item = NSMenuItem(
                title: title,
                action: #selector(requestLinkedExcerpt(_:)),
                keyEquivalent: ""
            )
            menu.addItem(item)
        }
        item.target = self
        item.isEnabled = currentLinkedExcerptSelectionSnapshot != nil
        return menu
    }

    @objc private func requestLinkedExcerpt(_ sender: Any?) {
        guard let snapshot = currentLinkedExcerptSelectionSnapshot else {
            onError("Select text on one PDF page to insert a linked excerpt.")
            return
        }
        onRequestLinkedExcerpt(snapshot)
    }

    private var currentLinkedExcerptSelectionSnapshot: PDFSelectionSnapshot? {
        makePDFSelectionSnapshot(
            documentID: linkedExcerptDocumentID,
            contentVersion: linkedExcerptContentVersion,
            document: document,
            selection: currentSelection
        )
    }

    override func resetCursorRects() {
        if annotationMode == .select {
            super.resetCursorRects()
        } else {
            // In annotation modes Monknot owns the cursor; PDFView cursor rects otherwise compete with it.
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
            activeInkBaselineData = takeEditBaselineSnapshotIfNeeded()
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
                onAnnotationsChanged()
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
        let previousData = takeEditBaselineSnapshotIfNeeded()

        let lineSelections = selection.selectionsByLine()
        var addedAnnotations: [PDFAnnotationEditOperation.Item] = []

        for lineSelection in lineSelections {
            for page in lineSelection.pages {
                let bounds = lineSelection.bounds(for: page).insetBy(dx: -1, dy: -1)
                guard bounds.width > 0, bounds.height > 0 else { continue }

                let annotation = PDFAnnotation(bounds: bounds, forType: kind.annotationSubtype, withProperties: nil)
                annotation.color = kind == .highlight ? color.withAlphaComponent(0.46) : color
                annotation.contents = lineSelection.string?.trimmingCharacters(in: .newlines)
                annotation.userName = NSFullUserName()
                annotation.modificationDate = Date()
                annotation.shouldDisplay = true
                annotation.shouldPrint = true
                annotation.quadrilateralPoints = pdfTextMarkupQuadrilateralPoints(for: bounds.size)
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
        onAnnotationsChanged()
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

        let previousData = takeEditBaselineSnapshotIfNeeded()
        let removedItem = PDFAnnotationEditOperation.Item(pageIndex: document.index(for: target.page), annotation: annotation)
        target.page.removeAnnotation(annotation)
        registerAnnotationEdit(PDFAnnotationEditOperation(added: [], removed: [removedItem]))
        refreshAnnotationDisplay(on: target.page)
        onAnnotationsChanged()
        publishEditedDocument(previousData: previousData)
    }

    func undoAnnotationEdit() {
        guard let operation = undoStack.popLast() else { return }
        applyInverse(operation)
        redoStack.append(operation)
        publishUndoState()
        onAnnotationsChanged()
        publishEditedDocument(previousData: nil)
    }

    func redoAnnotationEdit() {
        guard let operation = redoStack.popLast() else { return }
        apply(operation)
        undoStack.append(operation)
        publishUndoState()
        onAnnotationsChanged()
        publishEditedDocument(previousData: nil)
    }

    func clearAnnotationUndoHistory() {
        undoStack = []
        redoStack = []
        publishUndoState()
    }

    func resetEditBaselineCapture(needsSnapshot: Bool) {
        needsEditBaselineSnapshot = needsSnapshot
    }

    private func takeEditBaselineSnapshotIfNeeded() -> Data? {
        guard needsEditBaselineSnapshot else { return nil }
        needsEditBaselineSnapshot = false
        return document?.dataRepresentation()
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

    private func squaredDistance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    func prepareForDismantle() {
        discardActiveInkAnnotation()
        if let toolTrackingArea,
           trackingAreas.contains(where: { $0 === toolTrackingArea }) {
            removeTrackingArea(toolTrackingArea)
        }
        toolTrackingArea = nil
        highlightedSelections = nil
        clearSelection()
        undoStack = []
        redoStack = []
        linkedExcerptDocumentID = nil
        linkedExcerptContentVersion = 0
        onEdited = { _, _ in }
        onUndoStateChanged = { _, _ in }
        onError = { _ in }
        onRequestLinkedExcerpt = { _ in }
        onAnnotationsChanged = {}
        document = nil
    }
}

func pdfTextMarkupQuadrilateralPoints(for size: CGSize) -> [NSValue] {
    [
        NSValue(point: NSPoint(x: 0, y: size.height)),
        NSValue(point: NSPoint(x: size.width, y: size.height)),
        NSValue(point: .zero),
        NSValue(point: NSPoint(x: size.width, y: 0))
    ]
}

fileprivate enum PDFAnnotationInteractionMode: Equatable {
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

enum PDFTextMarkupKind: Equatable {
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

    var selectionHint: String {
        switch self {
        case .highlight:
            return "Select text on the page to highlight it."
        case .underline:
            return "Select text on the page to underline it."
        case .strikeOut:
            return "Select text on the page to strike it out."
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
