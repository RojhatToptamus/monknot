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
    let viewportState: PDFDocumentViewportState?
    let externalUndoCommandSerial: Int
    let externalRedoCommandSerial: Int
    @Binding var searchState: DocumentSearchState
    @Binding var searchTarget: WorkspaceSearchPDFTarget?
    let markEdited: (Data?, Data) -> Void
    let reportError: (String) -> Void
    let saveDocument: () -> Void

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
                    saveDocument: saveDocument
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
                    theme: theme,
                    viewportState: viewportState,
                    annotationMode: interactionMode,
                    annotationColor: selectedColor,
                    strokeWidth: CGFloat(strokeWidth),
                    markupCommand: markupCommand,
                    zoomCommand: zoomCommand,
                    undoCommandSerial: externalUndoCommandSerial + undoCommandSerial,
                    redoCommandSerial: externalRedoCommandSerial + redoCommandSerial,
                    searchState: $searchState,
                    searchTarget: $searchTarget,
                    markEdited: markEdited,
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

private struct PDFZoomToolbarGroup: View {
    let status: PDFZoomStatus
    let theme: AppTheme
    let zoomScale: Double
    let runZoom: (PDFZoomCommand) -> Void

    @State private var isMenuHovered = false
    @FocusState private var isMenuFocused: Bool

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
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
            HStack(spacing: scaled(8)) {
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
            .foregroundStyle(isMenuHovered ? theme.foregroundColor : theme.mutedForegroundColor)
            .frame(
                width: scaled(86),
                height: MonknotMetrics.interfaceControl(30, theme: theme, zoomScale: zoomScale)
            )
            .background {
                if isMenuHovered, status.isAvailable {
                    RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                        .fill(theme.foregroundColor.opacity(theme.isDark ? 0.065 : 0.048))
                }
            }
            .overlay {
                if isMenuFocused, status.isAvailable {
                    RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                        .strokeBorder(theme.accentColor.opacity(0.9), lineWidth: 1.5)
                        .padding(1)
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(!status.isAvailable)
        .focusable(status.isAvailable)
        .focused($isMenuFocused)
        .opacity(status.isAvailable ? 1 : 0.42)
        .onHover { isMenuHovered = $0 }
        .help("PDF Zoom")
        .accessibilityLabel("PDF Zoom")
        .accessibilityValue(status.displayLabel)
        .background(theme.controlTrackFillColor.opacity(theme.isDark ? 0.74 : 0.62))
        .clipShape(RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)))
        .overlay {
            RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                .strokeBorder(theme.borderColor, lineWidth: 1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .animation(.easeOut(duration: 0.12), value: isMenuHovered)
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

private struct PDFKitPreviewRepresentable: NSViewRepresentable {
    let documentID: String
    let url: URL
    let dirtyData: Data?
    let theme: AppTheme
    let viewportState: PDFDocumentViewportState?
    let annotationMode: PDFAnnotationInteractionMode
    let annotationColor: PDFAnnotationPaletteColor
    let strokeWidth: CGFloat
    let markupCommand: PDFTextMarkupCommand?
    let zoomCommand: PDFZoomCommandRequest?
    let undoCommandSerial: Int
    let redoCommandSerial: Int
    @Binding var searchState: DocumentSearchState
    @Binding var searchTarget: WorkspaceSearchPDFTarget?
    let markEdited: (Data?, Data) -> Void
    let onViewportStateChange: (PDFDocumentViewportState) -> Void
    let updatePageStatus: (PDFPageStatus) -> Void
    let updateZoomStatus: (PDFZoomStatus) -> Void
    let updateUndoState: (Bool, Bool) -> Void
    let updateLoadState: (PDFLoadState) -> Void
    let reportError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AnnotatingPDFView {
        let view = AnnotatingPDFView()
        view.identifier = .monknotDocumentFocusTarget
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.autoScales = false
        view.scaleFactor = 1
        view.backgroundColor = NSColor(hex: theme.background)
        context.coordinator.documentID = documentID
        context.coordinator.onViewportStateChange = { state in
            DispatchQueue.main.async {
                self.onViewportStateChange(state)
            }
        }
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
        context.coordinator.acceptCurrentCommandSerials(
            undoSerial: undoCommandSerial,
            redoSerial: redoCommandSerial,
            zoomSerial: zoomCommand?.serial ?? 0
        )
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ pdfView: AnnotatingPDFView, context: Context) {
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
        context.coordinator.applyAppearance(theme: theme, in: pdfView)
        context.coordinator.restoreViewportStateIfNeeded(
            viewportState,
            force: didChangeDocument || didLoadDocument,
            skipPosition: searchTarget != nil,
            in: pdfView
        )
        context.coordinator.applyZoomCommand(zoomCommand, in: pdfView)
        context.coordinator.applySearch(searchState, theme: theme, in: pdfView)
        context.coordinator.applyMarkupCommand(markupCommand, in: pdfView)
        context.coordinator.applyUndoRedoCommands(undoSerial: undoCommandSerial, redoSerial: redoCommandSerial, in: pdfView)
    }

    static func dismantleNSView(_ pdfView: AnnotatingPDFView, coordinator: Coordinator) {
        coordinator.publishViewportState(from: pdfView)
        coordinator.detach()
    }

    final class Coordinator {
        var documentID: String?
        var onSearchResult: (DocumentSearchResult) -> Void = { _ in }
        var onSearchTargetConsumed: () -> Void = {}
        var onViewportStateChange: (PDFDocumentViewportState) -> Void = { _ in }
        var onPageStatusChange: (PDFPageStatus) -> Void = { _ in }
        var onZoomStatusChange: (PDFZoomStatus) -> Void = { _ in }
        var onLoadStateChange: (PDFLoadState) -> Void = { _ in }
        private var documentURL: URL?
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
        private var shouldRestoreViewportState = false
        private var lastPublishedViewportState: PDFDocumentViewportState?
        private var lastPublishedPageStatus: PDFPageStatus?
        private var lastPublishedZoomStatus: PDFZoomStatus?
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
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
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
            shouldRestoreViewportState = true
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
            var loadedDocument: PDFDocument?
            performWithoutPublishingViewportStateChanges {
                if let dirtyData, let dirtyDocument = PDFDocument(data: dirtyData) {
                    loadedDocument = dirtyDocument
                } else {
                    loadedDocument = PDFDocument(url: standardizedURL)
                }
                pdfView.document = loadedDocument
                applyPDFZoomMode(.fixed(scaleFactor: 1), to: pdfView)
            }
            onLoadStateChange(loadedDocument == nil ? .failed : .loaded)
            pdfView.clearAnnotationUndoHistory()
            pdfView.resetEditBaselineCapture(needsSnapshot: dirtyData == nil)
            shouldRestoreViewportState = true
            onSearchResult(.init())
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

        func restoreViewportStateIfNeeded(
            _ state: PDFDocumentViewportState?,
            force: Bool,
            skipPosition: Bool,
            in pdfView: AnnotatingPDFView
        ) {
            if force {
                shouldRestoreViewportState = true
            }

            guard shouldRestoreViewportState else { return }
            shouldRestoreViewportState = false
            guard let document = pdfView.document else {
                publishZoomStatus(from: pdfView)
                return
            }

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
                   let destination = position.destination(in: document) {
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

    func destination(in document: PDFDocument) -> PDFDestination? {
        guard pageIndex >= 0, let page = document.page(at: pageIndex) else {
            return nil
        }

        return PDFDestination(page: page, at: point.point)
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
                annotation.contents = selection.string
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
}

func pdfTextMarkupQuadrilateralPoints(for size: CGSize) -> [NSValue] {
    [
        NSValue(point: NSPoint(x: 0, y: size.height)),
        NSValue(point: NSPoint(x: size.width, y: size.height)),
        NSValue(point: .zero),
        NSValue(point: NSPoint(x: size.width, y: 0))
    ]
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
