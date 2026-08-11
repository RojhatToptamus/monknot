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
    let savedEditCheckpoint: PDFAnnotationEditCheckpoint?
    let contentVersion: Int
    let viewportState: PDFDocumentViewportState?
    let viewportCaptureBridge: PDFViewportCaptureBridge
    let externalUndoCommandSerial: Int
    let externalRedoCommandSerial: Int
    @Binding var searchState: DocumentSearchState
    @Binding var searchTarget: WorkspaceSearchPDFTarget?
    let markEdited: (Data?, Data, PDFAnnotationEditCheckpoint) -> Void
    let restoreSavedEditCheckpoint: (PDFAnnotationEditCheckpoint) -> Bool
    let reportError: (String) -> Void
    let saveDocument: () -> Void
    var pageNavigationRequest: PDFPageNavigationRequest? = nil
    var externalNavigatorToggleCommandSerial: Int = 0
    var copyLinkedExcerpt: (PDFSelectionSnapshot) -> Void = { _ in }
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
    @State private var selectedFreeTextFormatting: PDFFreeTextFormatting?
    @State private var freeTextFormattingCommand: PDFFreeTextFormattingCommand?
    @State private var freeTextFormattingCommandSerial = 0

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
                    toggleNavigator: toggleNavigator,
                    selectedFreeTextFormatting: selectedFreeTextFormatting,
                    updateFreeTextFormatting: updateFreeTextFormatting(_:)
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
                    savedEditCheckpoint: savedEditCheckpoint,
                    contentVersion: contentVersion,
                    theme: theme,
                    viewportState: viewportState,
                    viewportCaptureBridge: viewportCaptureBridge,
                    annotationMode: interactionMode,
                    annotationColor: selectedColor,
                    strokeWidth: CGFloat(strokeWidth),
                    markupCommand: markupCommand,
                    freeTextFormattingCommand: freeTextFormattingCommand,
                    zoomCommand: zoomCommand,
                    undoCommandSerial: externalUndoCommandSerial + undoCommandSerial,
                    redoCommandSerial: externalRedoCommandSerial + redoCommandSerial,
                    pageNavigationRequest: pageNavigationRequest,
                    isNavigatorPresented: isNavigatorPresented,
                    workspaceZoomScale: zoomScale,
                    searchState: $searchState,
                    searchTarget: $searchTarget,
                    markEdited: markEdited,
                    restoreSavedEditCheckpoint: restoreSavedEditCheckpoint,
                    copyLinkedExcerpt: copyLinkedExcerpt,
                    onSelectionSnapshotChange: onSelectionSnapshotChange,
                    onFreeTextSelectionChange: updateFreeTextSelection(_:),
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
            selectedFreeTextFormatting = nil
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

    private func updateFreeTextFormatting(_ formatting: PDFFreeTextFormatting) {
        freeTextFormattingCommandSerial &+= 1
        freeTextFormattingCommand = PDFFreeTextFormattingCommand(
            serial: freeTextFormattingCommandSerial,
            formatting: formatting
        )
    }

    private func updateFreeTextSelection(_ formatting: PDFFreeTextFormatting?) {
        if selectedFreeTextFormatting != formatting {
            selectedFreeTextFormatting = formatting
        }
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

struct PDFAnnotationEditCheckpoint: Equatable, Sendable {
    let operationCount: Int
    let lastOperationID: UUID?
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

struct PDFFreeTextFormatting: Equatable {
    var fontFamily: String
    var fontSize: CGFloat
    var fontColor: NSColor
    var isBold: Bool
    var isItalic: Bool
    var alignment: NSTextAlignment

    static let defaultValue = PDFFreeTextFormatting(
        fontFamily: "Helvetica",
        fontSize: 14,
        fontColor: .black,
        isBold: false,
        isItalic: false,
        alignment: .left
    )

    init(
        fontFamily: String,
        fontSize: CGFloat,
        fontColor: NSColor,
        isBold: Bool,
        isItalic: Bool,
        alignment: NSTextAlignment
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.fontColor = fontColor
        self.isBold = isBold
        self.isItalic = isItalic
        self.alignment = alignment
    }

    init(annotation: PDFAnnotation) {
        let font = annotation.font ?? NSFont(name: "Helvetica", size: 14) ?? .systemFont(ofSize: 14)
        let traits = NSFontManager.shared.traits(of: font)
        self.init(
            fontFamily: font.familyName ?? font.fontName,
            fontSize: max(6, font.pointSize),
            fontColor: annotation.fontColor ?? .black,
            isBold: traits.contains(.boldFontMask),
            isItalic: traits.contains(.italicFontMask),
            alignment: annotation.alignment
        )
    }

    static func == (lhs: PDFFreeTextFormatting, rhs: PDFFreeTextFormatting) -> Bool {
        lhs.fontFamily == rhs.fontFamily
            && abs(lhs.fontSize - rhs.fontSize) < 0.01
            && lhs.fontColor.isEqual(rhs.fontColor)
            && lhs.isBold == rhs.isBold
            && lhs.isItalic == rhs.isItalic
            && lhs.alignment == rhs.alignment
    }

    var font: NSFont {
        var traits: NSFontTraitMask = []
        if isBold { traits.insert(.boldFontMask) }
        if isItalic { traits.insert(.italicFontMask) }
        return NSFontManager.shared.font(
            withFamily: fontFamily,
            traits: traits,
            weight: isBold ? 9 : 5,
            size: min(max(fontSize, 6), 144)
        ) ?? NSFont(name: fontFamily, size: min(max(fontSize, 6), 144))
            ?? NSFont(name: "Helvetica", size: min(max(fontSize, 6), 144))
            ?? .systemFont(ofSize: min(max(fontSize, 6), 144))
    }

    func apply(to annotation: PDFAnnotation) {
        let current = PDFFreeTextFormatting(annotation: annotation)
        let changesFace = fontFamily != current.fontFamily
            || isBold != current.isBold
            || isItalic != current.isItalic
        let changesSize = abs(fontSize - current.fontSize) >= 0.01
        if changesFace {
            annotation.font = font
        } else if changesSize {
            let size = min(max(fontSize, 6), 144)
            annotation.font = annotation.font?.withSize(size) ?? font
        }
        annotation.fontColor = fontColor
        if alignment != current.alignment {
            annotation.alignment = Self.supportedAlignment(alignment)
        }
    }

    private static func supportedAlignment(_ alignment: NSTextAlignment) -> NSTextAlignment {
        switch alignment {
        case .left, .center, .right:
            return alignment
        default:
            return .left
        }
    }
}

private struct PDFFreeTextFormattingCommand {
    let serial: Int
    let formatting: PDFFreeTextFormatting
}

final class PDFFreeTextCommittedColorWell: NSColorWell {
    private var onCommit: ((NSColor) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureControl()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureControl()
    }

    func update(color: NSColor, onCommit: @escaping (NSColor) -> Void) {
        self.onCommit = onCommit
        if !self.color.isEqual(color) {
            self.color = color
        }
    }

    func tearDown() {
        deactivate()
        target = nil
        action = nil
        onCommit = nil
    }

    private func configureControl() {
        isContinuous = false
        colorWellStyle = .minimal
        target = self
        action = #selector(commitColorChange(_:))
    }

    @objc private func commitColorChange(_ sender: NSColorWell) {
        onCommit?(sender.color)
    }
}

private struct PDFFreeTextColorWell: NSViewRepresentable {
    let color: NSColor
    let onCommit: (NSColor) -> Void

    func makeNSView(context: Context) -> PDFFreeTextCommittedColorWell {
        let colorWell = PDFFreeTextCommittedColorWell(frame: .zero)
        colorWell.update(color: color, onCommit: onCommit)
        return colorWell
    }

    func updateNSView(_ colorWell: PDFFreeTextCommittedColorWell, context: Context) {
        colorWell.update(color: color, onCommit: onCommit)
    }

    static func dismantleNSView(_ colorWell: PDFFreeTextCommittedColorWell, coordinator: ()) {
        colorWell.tearDown()
    }
}

private struct PDFFreeTextFormattingPopover: View {
    let formatting: PDFFreeTextFormatting
    let theme: AppTheme
    let zoomScale: Double
    let update: (PDFFreeTextFormatting) -> Void

    private var availableFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(value, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(10)) {
            HStack(spacing: scaled(8)) {
                Picker("Font", selection: valueBinding(\.fontFamily)) {
                    ForEach(availableFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .labelsHidden()
                .frame(width: scaled(188))

                Stepper(
                    value: Binding(
                        get: { Double(formatting.fontSize) },
                        set: { value in
                            var next = formatting
                            next.fontSize = CGFloat(min(max(value, 6), 144))
                            update(next)
                        }
                    ),
                    in: 6...144,
                    step: 1
                ) {
                    Text("\(Int(formatting.fontSize.rounded())) pt")
                        .monospacedDigit()
                        .frame(width: scaled(48), alignment: .trailing)
                }

                PDFFreeTextColorWell(color: formatting.fontColor) { color in
                    var next = formatting
                    next.fontColor = color
                    update(next)
                }
                .frame(width: scaled(28), height: scaled(24))
                .accessibilityLabel("Text Color")
            }

            HStack(spacing: scaled(6)) {
                formatToggle(
                    title: "Bold",
                    systemImage: "bold",
                    isOn: formatting.isBold
                ) {
                    var next = formatting
                    next.isBold.toggle()
                    update(next)
                }
                formatToggle(
                    title: "Italic",
                    systemImage: "italic",
                    isOn: formatting.isItalic
                ) {
                    var next = formatting
                    next.isItalic.toggle()
                    update(next)
                }

                Divider()
                    .frame(height: scaled(22))

                alignmentButton(.left, image: "text.alignleft", label: "Align Left")
                alignmentButton(.center, image: "text.aligncenter", label: "Align Center")
                alignmentButton(.right, image: "text.alignright", label: "Align Right")
            }
        }
        .font(.system(size: scaled(12)))
        .foregroundStyle(theme.foregroundColor)
        .padding(scaled(12))
        .frame(minWidth: scaled(372))
    }

    private func valueBinding<Value>(_ keyPath: WritableKeyPath<PDFFreeTextFormatting, Value>) -> Binding<Value> {
        Binding(
            get: { formatting[keyPath: keyPath] },
            set: { value in
                var next = formatting
                next[keyPath: keyPath] = value
                update(next)
            }
        )
    }

    private func alignmentButton(_ alignment: NSTextAlignment, image: String, label: String) -> some View {
        formatToggle(
            title: label,
            systemImage: image,
            isOn: formatting.alignment == alignment
        ) {
            var next = formatting
            next.alignment = alignment
            update(next)
        }
    }

    private func formatToggle(
        title: String,
        systemImage: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: scaled(24), height: scaled(22))
                .background(
                    isOn ? theme.accentColor.opacity(theme.isDark ? 0.28 : 0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: theme.chromeRadius(6, zoomScale: zoomScale))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
    let selectedFreeTextFormatting: PDFFreeTextFormatting?
    let updateFreeTextFormatting: (PDFFreeTextFormatting) -> Void

    @State private var strokeWidthPopoverAnchor: PDFStrokeWidthPopoverAnchor?
    @State private var hoveredMenu: PDFToolbarMenuHoverTarget?
    @State private var isFreeTextFormattingPresented = false

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
        .onChange(of: interactionMode) { _, mode in
            if mode != .pen {
                strokeWidthPopoverAnchor = nil
            }
            if mode != .freeText {
                isFreeTextFormattingPresented = false
            }
        }
        .onChange(of: selectedFreeTextFormatting) { _, formatting in
            if formatting == nil {
                isFreeTextFormattingPresented = false
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
            if interactionMode != .freeText {
                toolbarDivider
                strokeWidthControl
            }
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
            if interactionMode == .freeText {
                freeTextStyleButtonIfAvailable
            } else {
                styleMenu(anchor: .compact)
            }
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
            freeTextButton
            eraserButton
            if interactionMode == .freeText {
                freeTextStyleButtonIfAvailable
            } else {
                colorPalette
            }
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
            if interactionMode == .freeText {
                freeTextStyleButtonIfAvailable
            } else {
                styleMenu(anchor: .minimal)
            }
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
            freeTextButton
            eraserButton

            if interactionMode == .freeText {
                freeTextStyleButtonIfAvailable
            } else {
                toolbarDivider
                colorPalette
            }
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

    private var freeTextButton: some View {
        MonknotIconButton(
            systemImage: "character.textbox",
            label: "Free Text",
            theme: theme,
            zoomScale: zoomScale,
            isActive: interactionMode == .freeText,
            size: .compact
        ) {
            interactionMode = .freeText
        }
        .accessibilityAddTraits(interactionMode == .freeText ? .isSelected : [])
    }

    @ViewBuilder
    private var freeTextStyleButtonIfAvailable: some View {
        if selectedFreeTextFormatting != nil {
            MonknotIconButton(
                systemImage: "textformat",
                label: "Text Style",
                theme: theme,
                zoomScale: zoomScale,
                isActive: isFreeTextFormattingPresented,
                size: .compact
            ) {
                isFreeTextFormattingPresented.toggle()
            }
            .accessibilityAddTraits(isFreeTextFormattingPresented ? .isSelected : [])
            .popover(isPresented: $isFreeTextFormattingPresented, arrowEdge: .top) {
                if let selectedFreeTextFormatting {
                    PDFFreeTextFormattingPopover(
                        formatting: selectedFreeTextFormatting,
                        theme: theme,
                        zoomScale: zoomScale,
                        update: updateFreeTextFormatting
                    )
                }
            }
        }
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
            Button("Free Text", systemImage: "character.textbox") {
                interactionMode = .freeText
            }
            Button("Erase Annotation", systemImage: "eraser") {
                interactionMode = .eraser
            }

            if interactionMode == .freeText, selectedFreeTextFormatting != nil {
                Divider()
                Button("Text Style…", systemImage: "textformat") {
                    isFreeTextFormattingPresented = true
                }
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
        case .freeText:
            return "character.textbox"
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
        case .freeText:
            return "Free Text"
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

struct PDFNavigatorMetrics: Equatable {
    static let minimumBaseWidth: CGFloat = 220
    static let preferredBaseWidth: CGFloat = 248
    static let maximumBaseWidth: CGFloat = 320

    let densityScale: CGFloat
    let minimumWidth: CGFloat
    let preferredWidth: CGFloat
    let maximumWidth: CGFloat
    let headerHeight: CGFloat
    let headerInset: CGFloat
    let segmentedHeight: CGFloat
    let segmentedFontSize: CGFloat
    let contentInset: CGFloat
    let thumbnailLabelFontSize: CGFloat
    let outlineRowHeight: CGFloat
    let outlineIndentation: CGFloat
    let outlineFontSize: CGFloat
    let annotationRowHeight: CGFloat
    let annotationFontSize: CGFloat
    let cellInset: CGFloat
    let selectionHorizontalInset: CGFloat
    let selectionVerticalInset: CGFloat
    let selectionCornerRadius: CGFloat
    let emptyFontSize: CGFloat
    let emptyInset: CGFloat

    init(theme: AppTheme, workspaceZoomScale: Double) {
        densityScale = theme.interfaceDensityScale(zoomScale: workspaceZoomScale)
        minimumWidth = MonknotMetrics.interfaceDensity(
            Self.minimumBaseWidth,
            theme: theme,
            zoomScale: workspaceZoomScale
        )
        preferredWidth = MonknotMetrics.interfaceDensity(
            Self.preferredBaseWidth,
            theme: theme,
            zoomScale: workspaceZoomScale
        )
        maximumWidth = MonknotMetrics.interfaceDensity(
            Self.maximumBaseWidth,
            theme: theme,
            zoomScale: workspaceZoomScale
        )
        headerHeight = (40 * theme.interfaceRowScale(zoomScale: workspaceZoomScale)).rounded()
        headerInset = MonknotMetrics.interfaceDensity(8, theme: theme, zoomScale: workspaceZoomScale)
        segmentedHeight = MonknotMetrics.interfaceControl(28, theme: theme, zoomScale: workspaceZoomScale)
        segmentedFontSize = MonknotMetrics.interfaceText(12, theme: theme, zoomScale: workspaceZoomScale)
        contentInset = MonknotMetrics.interfaceDensity(8, theme: theme, zoomScale: workspaceZoomScale)
        thumbnailLabelFontSize = MonknotMetrics.interfaceText(12, theme: theme, zoomScale: workspaceZoomScale)
        outlineRowHeight = (30 * theme.interfaceRowScale(zoomScale: workspaceZoomScale)).rounded()
        outlineIndentation = MonknotMetrics.interfaceDensity(16, theme: theme, zoomScale: workspaceZoomScale)
        outlineFontSize = MonknotMetrics.interfaceText(13, theme: theme, zoomScale: workspaceZoomScale)
        annotationRowHeight = (30 * theme.interfaceRowScale(zoomScale: workspaceZoomScale)).rounded()
        annotationFontSize = MonknotMetrics.interfaceText(13, theme: theme, zoomScale: workspaceZoomScale)
        cellInset = MonknotMetrics.interfaceDensity(10, theme: theme, zoomScale: workspaceZoomScale)
        selectionHorizontalInset = MonknotMetrics.interfaceDensity(4, theme: theme, zoomScale: workspaceZoomScale)
        selectionVerticalInset = MonknotMetrics.interfaceDensity(2, theme: theme, zoomScale: workspaceZoomScale)
        selectionCornerRadius = MonknotMetrics.interfaceDensity(8, theme: theme, zoomScale: workspaceZoomScale)
        emptyFontSize = MonknotMetrics.interfaceText(12, theme: theme, zoomScale: workspaceZoomScale)
        emptyInset = MonknotMetrics.interfaceDensity(16, theme: theme, zoomScale: workspaceZoomScale)
    }

    func renderedWidth(forBaseWidth baseWidth: CGFloat) -> CGFloat {
        let clampedBaseWidth = min(
            Self.maximumBaseWidth,
            max(Self.minimumBaseWidth, baseWidth)
        )
        return (clampedBaseWidth * densityScale).rounded()
    }

    func baseWidth(forRenderedWidth renderedWidth: CGFloat) -> CGFloat {
        guard densityScale > 0 else { return Self.preferredBaseWidth }
        return min(
            Self.maximumBaseWidth,
            max(Self.minimumBaseWidth, renderedWidth / densityScale)
        )
    }

    func thumbnailSize(forPanelWidth panelWidth: CGFloat) -> NSSize {
        let availableWidth = max(1, panelWidth - (contentInset * 2))
        let width = min(availableWidth, max(1, (panelWidth * 0.74).rounded()))
        return NSSize(width: width, height: (width * sqrt(2)).rounded())
    }
}

final class PDFNavigatorSplitView: NSSplitView {
    var themedDividerColor = NSColor.separatorColor
    private(set) var isTrackingDividerInteraction = false
    private var isApplyingProgrammaticPosition = false

    override var dividerColor: NSColor {
        themedDividerColor
    }

    override func mouseDown(with event: NSEvent) {
        let wasTrackingDividerInteraction = isTrackingDividerInteraction
        isTrackingDividerInteraction = true
        defer { isTrackingDividerInteraction = wasTrackingDividerInteraction }
        super.mouseDown(with: event)
    }

    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        let wasTrackingDividerInteraction = isTrackingDividerInteraction
        if !isApplyingProgrammaticPosition {
            // AppKit's AX splitter uses setPosition; automatic split layout does not.
            isTrackingDividerInteraction = true
        }
        defer { isTrackingDividerInteraction = wasTrackingDividerInteraction }
        super.setPosition(position, ofDividerAt: dividerIndex)
    }

    func setProgrammaticPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        let wasApplyingProgrammaticPosition = isApplyingProgrammaticPosition
        isApplyingProgrammaticPosition = true
        defer { isApplyingProgrammaticPosition = wasApplyingProgrammaticPosition }
        setPosition(position, ofDividerAt: dividerIndex)
    }
}

final class PDFPreviewContainerView: NSView, NSSplitViewDelegate {
    let pdfView = AnnotatingPDFView()
    let navigatorView = PDFNavigatorView()

    private let splitView = PDFNavigatorSplitView()
    private(set) var navigatorMetrics = PDFNavigatorMetrics(
        theme: .defaultLight,
        workspaceZoomScale: 1
    )
    private var navigatorBaseWidth = PDFNavigatorMetrics.preferredBaseWidth
    private var pendingNavigatorWidth: CGFloat?
    private var isNavigatorPresented = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureViews()
    }

    override func layout() {
        super.layout()
        applyPendingNavigatorWidthIfPossible()
        applyNavigatorVisibility()
        restoreNavigatorBaseWidthAfterAutomaticLayoutIfNeeded()
        navigatorView.updatePanelWidth(navigatorView.bounds.width)
    }

    func applyNavigatorMetrics(theme: AppTheme, workspaceZoomScale: Double) {
        let previousMetrics = navigatorMetrics
        let nextMetrics = PDFNavigatorMetrics(
            theme: theme,
            workspaceZoomScale: workspaceZoomScale
        )
        navigatorMetrics = nextMetrics
        splitView.themedDividerColor = NSColor(hex: theme.foreground)
            .withAlphaComponent(theme.isDark ? 0.09 : 0.12)
        splitView.needsDisplay = true
        navigatorView.applyMetrics(
            nextMetrics,
            theme: theme,
            panelWidth: navigatorView.bounds.width > 0
                ? navigatorView.bounds.width
                : nextMetrics.renderedWidth(forBaseWidth: navigatorBaseWidth)
        )
        if previousMetrics != nextMetrics {
            queueNavigatorWidth(
                isNavigatorPresented
                    ? nextMetrics.renderedWidth(forBaseWidth: navigatorBaseWidth)
                    : 0
            )
        }
    }

    func setNavigatorPresented(_ isPresented: Bool) {
        guard isNavigatorPresented != isPresented else {
            navigatorView.setPresented(isPresented)
            if !isPresented {
                queueNavigatorWidth(0)
            } else {
                applyNavigatorVisibility()
            }
            return
        }
        isNavigatorPresented = isPresented
        navigatorView.setPresented(isPresented)
        queueNavigatorWidth(
            isPresented
                ? navigatorMetrics.renderedWidth(forBaseWidth: navigatorBaseWidth)
                : 0
        )
    }

    func prepareForDismantle() {
        splitView.delegate = nil
        navigatorView.prepareForDismantle()
        pdfView.prepareForDismantle()
    }

    private func configureViews() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        addSubview(splitView)
        splitView.addArrangedSubview(navigatorView)
        splitView.addArrangedSubview(pdfView)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        navigatorView.isHidden = true
        navigatorView.setAccessibilityHidden(true)
        navigatorView.applyMetrics(
            navigatorMetrics,
            theme: .defaultLight,
            panelWidth: navigatorMetrics.preferredWidth
        )
    }

    private func applyPendingNavigatorWidthIfPossible() {
        guard let pendingNavigatorWidth,
              splitView.bounds.width > 0,
              splitView.subviews.count == 2
        else {
            return
        }
        self.pendingNavigatorWidth = nil
        navigatorView.isHidden = false
        navigatorView.setAccessibilityHidden(false)
        splitView.setProgrammaticPosition(pendingNavigatorWidth, ofDividerAt: 0)
        applyNavigatorVisibility()
        navigatorView.updatePanelWidth(navigatorView.bounds.width)
    }

    private func restoreNavigatorBaseWidthAfterAutomaticLayoutIfNeeded() {
        guard pendingNavigatorWidth == nil,
              isNavigatorPresented,
              !splitView.isTrackingDividerInteraction,
              splitView.bounds.width > 0
        else {
            return
        }
        let targetWidth = navigatorMetrics.renderedWidth(forBaseWidth: navigatorBaseWidth)
        guard abs(navigatorView.bounds.width - targetWidth) > 0.5 else { return }
        splitView.setProgrammaticPosition(targetWidth, ofDividerAt: 0)
    }

    private func queueNavigatorWidth(_ width: CGFloat) {
        pendingNavigatorWidth = width
        if splitView.bounds.width > 0 {
            applyPendingNavigatorWidthIfPossible()
        } else {
            needsLayout = true
        }
    }

    private func applyNavigatorVisibility() {
        let isHidden = !isNavigatorPresented
        navigatorView.isHidden = isHidden
        navigatorView.setAccessibilityHidden(isHidden)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0 else { return proposedMinimumPosition }
        guard isNavigatorPresented else { return 0 }
        return navigatorMetrics.minimumWidth
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0 else { return proposedMaximumPosition }
        guard isNavigatorPresented else { return 0 }
        return min(proposedMaximumPosition, navigatorMetrics.maximumWidth)
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        dividerIndex == 0 && !isNavigatorPresented
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard isNavigatorPresented, navigatorView.bounds.width > 0 else {
            return
        }
        navigatorView.updatePanelWidth(navigatorView.bounds.width)
        guard splitView.isTrackingDividerInteraction else { return }
        navigatorBaseWidth = navigatorMetrics.baseWidth(
            forRenderedWidth: navigatorView.bounds.width
        )
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
    let accessibilityExcerpt: String?

    var label: String {
        let pageLabel = "Page \(pageIndex + 1) · \(kind)"
        guard let excerpt else { return pageLabel }
        return "\(pageLabel) — \(excerpt)"
    }

    var accessibilityLabel: String {
        let pageLabel = "Page \(pageIndex + 1), \(kind)"
        guard let accessibilityExcerpt else { return pageLabel }
        return "\(pageLabel). \(accessibilityExcerpt)"
    }
}

final class PDFNavigatorTableRowView: NSTableRowView {
    var themedSelectionColor = NSColor.selectedContentBackgroundColor
    var selectionHorizontalInset: CGFloat = 4
    var selectionVerticalInset: CGFloat = 2
    var selectionCornerRadius: CGFloat = 8

    override var isEmphasized: Bool {
        didSet { needsDisplay = true }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        resolvedSelectionColor(isKeyWindow: window?.isKeyWindow == true).setFill()
        NSBezierPath(
            roundedRect: selectionDrawingRect,
            xRadius: selectionCornerRadius,
            yRadius: selectionCornerRadius
        ).fill()
    }

    var selectionDrawingRect: NSRect {
        bounds.insetBy(dx: selectionHorizontalInset, dy: selectionVerticalInset)
    }

    func resolvedSelectionColor(isKeyWindow: Bool) -> NSColor {
        guard isEmphasized, isKeyWindow else {
            return .unemphasizedSelectedContentBackgroundColor
        }
        return themedSelectionColor
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
    private var headerHeightConstraint: NSLayoutConstraint!
    private var segmentedHeightConstraint: NSLayoutConstraint!
    private var segmentedLeadingConstraint: NSLayoutConstraint!
    private var segmentedTrailingConstraint: NSLayoutConstraint!
    private var thumbnailLeadingConstraint: NSLayoutConstraint!
    private var thumbnailTrailingConstraint: NSLayoutConstraint!
    private var thumbnailTopConstraint: NSLayoutConstraint!
    private var thumbnailBottomConstraint: NSLayoutConstraint!
    private var emptyLeadingConstraint: NSLayoutConstraint!
    private var emptyTrailingConstraint: NSLayoutConstraint!
    private weak var pdfView: AnnotatingPDFView?
    private var outlineRoot: PDFOutline?
    private var selectedSection = PDFNavigatorSection.pages
    private var isPresented = false
    private var annotationsNeedReload = true
    private(set) var foregroundColor = NSColor.labelColor
    private var mutedForegroundColor = NSColor.secondaryLabelColor
    private(set) var selectionColor = NSColor.selectedContentBackgroundColor
    private(set) var metrics = PDFNavigatorMetrics(theme: .defaultLight, workspaceZoomScale: 1)
    private var appliedTheme: AppTheme?

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
        thumbnailView.labelFont = .systemFont(
            ofSize: metrics.thumbnailLabelFontSize,
            weight: .regular
        )
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

    func applyMetrics(_ metrics: PDFNavigatorMetrics, theme: AppTheme, panelWidth: CGFloat) {
        guard self.metrics != metrics || appliedTheme != theme else {
            updatePanelWidth(panelWidth)
            return
        }
        self.metrics = metrics
        appliedTheme = theme
        let foreground = NSColor(hex: theme.foreground)
        foregroundColor = foreground
        mutedForegroundColor = foreground.withAlphaComponent(theme.isDark ? 0.62 : 0.64)
        selectionColor = NSColor(hex: theme.selectionBackground)
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: theme.sidebarSurfaceHex).cgColor
        headerSeparatorView.layer?.backgroundColor = foreground
            .withAlphaComponent(theme.isDark ? 0.09 : 0.12)
            .cgColor
        headerHeightConstraint.constant = metrics.headerHeight
        segmentedHeightConstraint.constant = metrics.segmentedHeight
        segmentedLeadingConstraint.constant = metrics.headerInset
        segmentedTrailingConstraint.constant = -metrics.headerInset
        segmentedControl.font = .systemFont(ofSize: metrics.segmentedFontSize, weight: .regular)
        segmentedControl.selectedSegmentBezelColor = selectionColor
        thumbnailLeadingConstraint.constant = metrics.contentInset
        thumbnailTrailingConstraint.constant = -metrics.contentInset
        thumbnailTopConstraint.constant = metrics.contentInset
        thumbnailBottomConstraint.constant = -metrics.contentInset
        thumbnailView.labelFont = .systemFont(
            ofSize: metrics.thumbnailLabelFontSize,
            weight: .regular
        )
        outlineView.rowHeight = metrics.outlineRowHeight
        outlineView.indentationPerLevel = metrics.outlineIndentation
        annotationTableView.rowHeight = metrics.annotationRowHeight
        emptyLabel.font = .systemFont(ofSize: metrics.emptyFontSize, weight: .regular)
        emptyLeadingConstraint.constant = metrics.emptyInset
        emptyTrailingConstraint.constant = -metrics.emptyInset
        emptyLabel.textColor = mutedForegroundColor
        thumbnailView.backgroundColor = .clear
        updatePanelWidth(panelWidth)
        outlineView.reloadData()
        annotationTableView.reloadData()
    }

    func updatePanelWidth(_ panelWidth: CGFloat) {
        guard panelWidth > 0 else { return }
        let thumbnailSize = metrics.thumbnailSize(forPanelWidth: panelWidth)
        if thumbnailView.thumbnailSize != thumbnailSize {
            thumbnailView.thumbnailSize = thumbnailSize
        }
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
        segmentedControl.segmentDistribution = .fillEqually
        segmentedControl.selectedSegment = PDFNavigatorSection.pages.rawValue
        segmentedControl.target = self
        segmentedControl.action = #selector(sectionChanged(_:))
        segmentedControl.setAccessibilityLabel("PDF Navigator")
        headerView.addSubview(segmentedControl)

        headerHeightConstraint = headerView.heightAnchor.constraint(equalToConstant: metrics.headerHeight)
        segmentedHeightConstraint = segmentedControl.heightAnchor.constraint(equalToConstant: metrics.segmentedHeight)
        segmentedLeadingConstraint = segmentedControl.leadingAnchor.constraint(
            equalTo: headerView.leadingAnchor,
            constant: metrics.headerInset
        )
        segmentedTrailingConstraint = segmentedControl.trailingAnchor.constraint(
            equalTo: headerView.trailingAnchor,
            constant: -metrics.headerInset
        )

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerHeightConstraint,
            segmentedLeadingConstraint,
            segmentedTrailingConstraint,
            segmentedHeightConstraint,
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
        thumbnailView.thumbnailSize = metrics.thumbnailSize(forPanelWidth: metrics.preferredWidth)
        thumbnailView.maximumNumberOfColumns = 1
        thumbnailView.labelFont = .systemFont(
            ofSize: metrics.thumbnailLabelFontSize,
            weight: .regular
        )
        thumbnailView.allowsDragging = false
        thumbnailView.allowsMultipleSelection = false
        thumbnailView.setAccessibilityLabel("PDF Pages")
        contentView.addSubview(thumbnailView)
        thumbnailLeadingConstraint = thumbnailView.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor,
            constant: metrics.contentInset
        )
        thumbnailTrailingConstraint = thumbnailView.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor,
            constant: -metrics.contentInset
        )
        thumbnailTopConstraint = thumbnailView.topAnchor.constraint(
            equalTo: contentView.topAnchor,
            constant: metrics.contentInset
        )
        thumbnailBottomConstraint = thumbnailView.bottomAnchor.constraint(
            equalTo: contentView.bottomAnchor,
            constant: -metrics.contentInset
        )
        NSLayoutConstraint.activate([
            thumbnailLeadingConstraint,
            thumbnailTrailingConstraint,
            thumbnailTopConstraint,
            thumbnailBottomConstraint
        ])
    }

    private func configureOutlineView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PDFNavigatorOutlineColumn"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.indentationPerLevel = metrics.outlineIndentation
        outlineView.style = .sourceList
        outlineView.rowHeight = metrics.outlineRowHeight
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
        annotationTableView.style = .sourceList
        annotationTableView.rowHeight = metrics.annotationRowHeight
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
        emptyLabel.font = .systemFont(ofSize: metrics.emptyFontSize, weight: .regular)
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2
        contentView.addSubview(emptyLabel)
        emptyLeadingConstraint = emptyLabel.leadingAnchor.constraint(
            greaterThanOrEqualTo: contentView.leadingAnchor,
            constant: metrics.emptyInset
        )
        emptyTrailingConstraint = emptyLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: contentView.trailingAnchor,
            constant: -metrics.emptyInset
        )
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            emptyLeadingConstraint,
            emptyTrailingConstraint
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
        if thumbnailView.pdfView != nil {
            thumbnailView.labelFont = .systemFont(
                ofSize: metrics.thumbnailLabelFontSize,
                weight: .regular
            )
        }

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
                let accessibilityExcerpt = normalizedAnnotationExcerpt(annotation.contents)
                items.append(PDFNavigatorAnnotationItem(
                    pageIndex: pageIndex,
                    annotation: annotation,
                    kind: kind,
                    excerpt: accessibilityExcerpt.map {
                        unicodeScalarPrefix($0, maximumUTF16Count: 140)
                    },
                    accessibilityExcerpt: accessibilityExcerpt
                ))
            }
        }
        return items
    }

    private static func normalizedAnnotationExcerpt(_ contents: String?) -> String? {
        guard let contents else { return nil }
        let maximumOutputUTF16Count = 500
        // Collapsed whitespace does not grow the output, so cap inspected input too.
        let maximumInputUTF16Count = 4_000
        var normalized = ""
        normalized.reserveCapacity(maximumOutputUTF16Count)
        var outputUTF16Count = 0
        var inputUTF16Count = 0
        var needsSpace = false

        for scalar in contents.unicodeScalars {
            let scalarUTF16Count = scalar.value > 0xFFFF ? 2 : 1
            guard inputUTF16Count + scalarUTF16Count <= maximumInputUTF16Count,
                  outputUTF16Count < maximumOutputUTF16Count
            else {
                break
            }
            inputUTF16Count += scalarUTF16Count
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                needsSpace = outputUTF16Count > 0
                continue
            }

            if needsSpace,
               outputUTF16Count + 1 + scalarUTF16Count <= maximumOutputUTF16Count {
                normalized.append(" ")
                outputUTF16Count += 1
            }
            guard outputUTF16Count + scalarUTF16Count <= maximumOutputUTF16Count else { break }
            normalized.unicodeScalars.append(scalar)
            outputUTF16Count += scalarUTF16Count
            needsSpace = false
        }

        return normalized.isEmpty ? nil : normalized
    }

    private static func unicodeScalarPrefix(_ value: String, maximumUTF16Count: Int) -> String {
        var result = ""
        result.reserveCapacity(maximumUTF16Count)
        var resultUTF16Count = 0
        for scalar in value.unicodeScalars {
            let scalarUTF16Count = scalar.value > 0xFFFF ? 2 : 1
            guard resultUTF16Count + scalarUTF16Count <= maximumUTF16Count else { break }
            result.unicodeScalars.append(scalar)
            resultUTF16Count += scalarUTF16Count
        }
        return result
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
        cell.textField?.font = .systemFont(ofSize: metrics.outlineFontSize, weight: .regular)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        themedRowView()
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
        let cell = textCell(in: tableView, identifier: identifier, maximumNumberOfLines: 1)
        cell.textField?.stringValue = annotationItems[row].label
        cell.textField?.textColor = foregroundColor
        cell.textField?.font = .systemFont(ofSize: metrics.annotationFontSize, weight: .regular)
        cell.textField?.setAccessibilityLabel(annotationItems[row].accessibilityLabel)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        themedRowView()
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
            existing.constraints.first { $0.identifier == "PDFNavigatorCellLeading" }?.constant = metrics.cellInset
            existing.constraints.first { $0.identifier == "PDFNavigatorCellTrailing" }?.constant = -metrics.cellInset
            existing.textField?.maximumNumberOfLines = maximumNumberOfLines
            existing.textField?.usesSingleLineMode = maximumNumberOfLines == 1
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
        let leadingConstraint = textField.leadingAnchor.constraint(
            equalTo: cell.leadingAnchor,
            constant: metrics.cellInset
        )
        leadingConstraint.identifier = "PDFNavigatorCellLeading"
        let trailingConstraint = textField.trailingAnchor.constraint(
            equalTo: cell.trailingAnchor,
            constant: -metrics.cellInset
        )
        trailingConstraint.identifier = "PDFNavigatorCellTrailing"
        NSLayoutConstraint.activate([
            leadingConstraint,
            trailingConstraint,
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func themedRowView() -> NSTableRowView {
        let rowView = PDFNavigatorTableRowView()
        rowView.themedSelectionColor = selectionColor
        rowView.selectionHorizontalInset = metrics.selectionHorizontalInset
        rowView.selectionVerticalInset = metrics.selectionVerticalInset
        rowView.selectionCornerRadius = metrics.selectionCornerRadius
        return rowView
    }
}

struct PDFKitPreviewRepresentable: NSViewRepresentable {
    let documentID: String
    let url: URL
    let dirtyData: Data?
    let savedEditCheckpoint: PDFAnnotationEditCheckpoint?
    let contentVersion: Int
    let theme: AppTheme
    let viewportState: PDFDocumentViewportState?
    let viewportCaptureBridge: PDFViewportCaptureBridge
    fileprivate let annotationMode: PDFAnnotationInteractionMode
    fileprivate let annotationColor: PDFAnnotationPaletteColor
    let strokeWidth: CGFloat
    fileprivate let markupCommand: PDFTextMarkupCommand?
    fileprivate let freeTextFormattingCommand: PDFFreeTextFormattingCommand?
    let zoomCommand: PDFZoomCommandRequest?
    let undoCommandSerial: Int
    let redoCommandSerial: Int
    let pageNavigationRequest: PDFPageNavigationRequest?
    let isNavigatorPresented: Bool
    let workspaceZoomScale: Double
    @Binding var searchState: DocumentSearchState
    @Binding var searchTarget: WorkspaceSearchPDFTarget?
    let markEdited: (Data?, Data, PDFAnnotationEditCheckpoint) -> Void
    let restoreSavedEditCheckpoint: (PDFAnnotationEditCheckpoint) -> Bool
    let copyLinkedExcerpt: (PDFSelectionSnapshot) -> Void
    let onSelectionSnapshotChange: (PDFSelectionSnapshot?) -> Void
    let onFreeTextSelectionChange: (PDFFreeTextFormatting?) -> Void
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
        container.applyNavigatorMetrics(theme: theme, workspaceZoomScale: workspaceZoomScale)
        container.setNavigatorPresented(isNavigatorPresented)
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
        pdfView.onFreeTextSelectionChanged = { formatting in
            DispatchQueue.main.async {
                self.onFreeTextSelectionChange(formatting)
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
        pdfView.onRestoreSavedEditCheckpoint = restoreSavedEditCheckpoint
        pdfView.onError = reportError
        pdfView.onRequestLinkedExcerptCopy = copyLinkedExcerpt
        pdfView.onFreeTextSelectionChanged = { formatting in
            DispatchQueue.main.async {
                self.onFreeTextSelectionChange(formatting)
            }
        }
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

        container.applyNavigatorMetrics(theme: theme, workspaceZoomScale: workspaceZoomScale)
        container.setNavigatorPresented(isNavigatorPresented)
        let didLoadDocument = context.coordinator.loadDocumentIfNeeded(
            url,
            dirtyData: dirtyData,
            contentVersion: contentVersion,
            in: pdfView,
            navigatorView: container.navigatorView
        )
        pdfView.reconcileEditBaselineCapture(
            hasDirtyData: dirtyData != nil,
            savedEditCheckpoint: savedEditCheckpoint
        )
        context.coordinator.applyAppearance(theme: theme, in: pdfView)
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
        context.coordinator.applyFreeTextFormattingCommand(freeTextFormattingCommand, in: pdfView)
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
        private var lastFreeTextFormattingCommandSerial = 0
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

            pdfView.finishFreeTextEditingForDocumentSwitch()
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
            var loadedSourceData: Data?
            performWithoutPublishingViewportStateChanges {
                pdfView.cancelFreeTextEditingBeforeDocumentReplacement()
                if let dirtyData, let dirtyDocument = PDFDocument(data: dirtyData) {
                    loadedDocument = dirtyDocument
                } else {
                    // PDFKit may rewrite object order, metadata, or trailers when a loaded
                    // document is serialized. Keep the exact bytes parsed by the live view so
                    // the first conditional save compares against the real disk revision.
                    if let sourceData = try? Data(contentsOf: nextIdentity.url),
                       let sourceDocument = PDFDocument(data: sourceData) {
                        loadedSourceData = sourceData
                        loadedDocument = sourceDocument
                    }
                }
                pdfView.document = loadedDocument
                pdfView.replaceEditBaselineCapture(
                    with: loadedSourceData,
                    needsSnapshot: dirtyData == nil && loadedDocument != nil,
                    currentOwnedData: dirtyData
                )
                applyPDFZoomMode(.fixed(scaleFactor: 1), to: pdfView)
            }
            onLoadStateChange(loadedDocument == nil ? .failed : .loaded)
            pdfView.clearAnnotationUndoHistory()
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

        fileprivate func applyFreeTextFormattingCommand(
            _ command: PDFFreeTextFormattingCommand?,
            in pdfView: AnnotatingPDFView
        ) {
            guard let command, command.serial != lastFreeTextFormattingCommandSerial else { return }
            lastFreeTextFormattingCommandSerial = command.serial
            pdfView.applyFreeTextFormatting(command.formatting)
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

    @discardableResult
    func commitActiveFreeTextEdit(documentID: String) -> Bool {
        guard self.documentID == documentID,
              let pdfView = pdfView as? AnnotatingPDFView
        else { return false }
        return pdfView.commitActiveFreeTextEdit()
    }

    func hasActiveFreeTextEditor(documentID: String) -> Bool {
        guard self.documentID == documentID,
              let pdfView = pdfView as? AnnotatingPDFView
        else { return false }
        return pdfView.hasActiveFreeTextEditor
    }

    @discardableResult
    func cancelActiveFreeTextEdit(documentID: String) -> Bool {
        guard self.documentID == documentID,
              let pdfView = pdfView as? AnnotatingPDFView,
              pdfView.hasActiveFreeTextEditor
        else { return false }
        pdfView.cancelFreeTextEditingBeforeDocumentReplacement()
        return true
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
              let page = pdfView.currentPage
        else {
            return nil
        }

        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return nil }
        let bounds = page.bounds(for: pdfView.displayBox)
        let candidatePoint: CGPoint
        if let destination = pdfView.currentDestination,
           destination.page === page {
            candidatePoint = destination.point
        } else {
            let pageRect = pdfView.convert(bounds, from: page)
            let visiblePageRect = pageRect.intersection(pdfView.bounds)
            if visiblePageRect.isNull || visiblePageRect.isEmpty {
                candidatePoint = CGPoint(x: bounds.minX, y: bounds.maxY)
            } else {
                candidatePoint = pdfView.convert(
                    CGPoint(x: visiblePageRect.minX, y: visiblePageRect.maxY),
                    to: page
                )
            }
        }
        let point = CGPoint(
            x: candidatePoint.x.isFinite
                ? min(max(candidatePoint.x, bounds.minX), bounds.maxX)
                : bounds.minX,
            y: candidatePoint.y.isFinite
                ? min(max(candidatePoint.y, bounds.minY), bounds.maxY)
                : bounds.maxY
        )

        self.init(
            pageIndex: pageIndex,
            point: DocumentScrollPosition(point)
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
    guard let page = document.page(at: pageIndex) else { return nil }

    let rangeCount = selection.numberOfTextRanges(on: page)
    guard rangeCount > 0 else { return nil }
    var textRanges: [NSRange] = []
    textRanges.reserveCapacity(rangeCount)
    for index in 0..<rangeCount {
        let range = selection.range(at: index, on: page)
        guard range.location != NSNotFound,
              range.length > 0,
              range.location <= Int.max - range.length
        else { return nil }
        textRanges.append(range)
    }

    return PDFSelectionSnapshot(
        documentID: documentID,
        text: text,
        pageNumber: pageIndex + 1,
        contentVersion: contentVersion,
        textRanges: textRanges
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

struct PDFFreeTextAnnotationSnapshot: Equatable {
    let bounds: CGRect
    let contents: String
    let formatting: PDFFreeTextFormatting
    let font: NSFont?
    let fontColor: NSColor?
    let alignment: NSTextAlignment
    let shouldDisplay: Bool
    let shouldPrint: Bool
    let modificationDate: Date?

    init(annotation: PDFAnnotation) {
        bounds = annotation.bounds.standardized
        contents = annotation.contents ?? ""
        formatting = PDFFreeTextFormatting(annotation: annotation)
        font = annotation.font
        fontColor = annotation.fontColor
        alignment = annotation.alignment
        shouldDisplay = annotation.shouldDisplay
        shouldPrint = annotation.shouldPrint
        modificationDate = annotation.modificationDate
    }

    func apply(to annotation: PDFAnnotation) {
        annotation.bounds = bounds
        annotation.contents = contents
        annotation.font = font
        annotation.fontColor = fontColor
        annotation.alignment = alignment
        annotation.shouldDisplay = shouldDisplay
        annotation.shouldPrint = shouldPrint
        annotation.modificationDate = modificationDate
    }
}

struct PDFFreeTextEditorGeometry: Equatable {
    let center: CGPoint
    let localXAxis: CGVector
    let localYAxis: CGVector
    let effectiveScale: CGFloat
    let unrotatedSize: CGSize
    let rotationDegrees: CGFloat
}

struct PDFFreeTextOverlayGeometry: Equatable {
    let minXMinY: CGPoint
    let maxXMinY: CGPoint
    let maxXMaxY: CGPoint
    let minXMaxY: CGPoint
    let minXMidY: CGPoint
    let maxXMidY: CGPoint

    var center: CGPoint {
        CGPoint(
            x: (minXMinY.x + maxXMaxY.x) / 2,
            y: (minXMinY.y + maxXMaxY.y) / 2
        )
    }

    var boundingRect: CGRect {
        let points = [minXMinY, maxXMinY, maxXMaxY, minXMaxY]
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func mapPoints(_ transform: (CGPoint) -> CGPoint) -> PDFFreeTextOverlayGeometry {
        PDFFreeTextOverlayGeometry(
            minXMinY: transform(minXMinY),
            maxXMinY: transform(maxXMinY),
            maxXMaxY: transform(maxXMaxY),
            minXMaxY: transform(minXMaxY),
            minXMidY: transform(minXMidY),
            maxXMidY: transform(maxXMidY)
        )
    }
}

enum PDFFreeTextResizeCursorAxis: Equatable {
    case horizontal
    case vertical
}

func pdfFreeTextResizeCursorAxis(
    for annotationBounds: CGRect,
    on page: PDFPage,
    in pdfView: PDFView
) -> PDFFreeTextResizeCursorAxis {
    let bounds = annotationBounds.standardized
    let leading = pdfView.convert(
        CGPoint(x: bounds.minX, y: bounds.midY),
        from: page
    )
    let trailing = pdfView.convert(
        CGPoint(x: bounds.maxX, y: bounds.midY),
        from: page
    )
    return abs(trailing.x - leading.x) >= abs(trailing.y - leading.y)
        ? .horizontal
        : .vertical
}

func pdfFreeTextEditorGeometry(
    for annotationBounds: CGRect,
    on page: PDFPage,
    in pdfView: PDFView
) -> PDFFreeTextEditorGeometry? {
    let bounds = annotationBounds.standardized
    guard bounds.width > 0, bounds.height > 0 else { return nil }

    let center = pdfView.convert(
        CGPoint(x: bounds.midX, y: bounds.midY),
        from: page
    )
    let xStart = pdfView.convert(
        CGPoint(x: bounds.minX, y: bounds.midY),
        from: page
    )
    let xEnd = pdfView.convert(
        CGPoint(x: bounds.maxX, y: bounds.midY),
        from: page
    )
    let yStart = pdfView.convert(
        CGPoint(x: bounds.midX, y: bounds.minY),
        from: page
    )
    let yEnd = pdfView.convert(
        CGPoint(x: bounds.midX, y: bounds.maxY),
        from: page
    )
    let xAxis = CGVector(dx: xEnd.x - xStart.x, dy: xEnd.y - xStart.y)
    let yAxis = CGVector(dx: yEnd.x - yStart.x, dy: yEnd.y - yStart.y)
    let displayedWidth = hypot(xAxis.dx, xAxis.dy)
    let displayedHeight = hypot(yAxis.dx, yAxis.dy)
    let xScale = displayedWidth / bounds.width
    let yScale = displayedHeight / bounds.height
    let effectiveScale = (xScale + yScale) / 2
    guard center.x.isFinite,
          center.y.isFinite,
          displayedWidth.isFinite,
          displayedHeight.isFinite,
          displayedWidth > 0,
          displayedHeight > 0,
          effectiveScale.isFinite,
          effectiveScale > 0
    else { return nil }

    return PDFFreeTextEditorGeometry(
        center: center,
        localXAxis: xAxis,
        localYAxis: yAxis,
        effectiveScale: effectiveScale,
        unrotatedSize: CGSize(width: displayedWidth, height: displayedHeight),
        rotationDegrees: atan2(xAxis.dy, xAxis.dx) * 180 / .pi
    )
}

func pdfFreeTextOverlayGeometry(
    for annotationBounds: CGRect,
    on page: PDFPage,
    in pdfView: PDFView
) -> PDFFreeTextOverlayGeometry? {
    guard let geometry = pdfFreeTextEditorGeometry(
        for: annotationBounds,
        on: page,
        in: pdfView
    ) else { return nil }

    let halfX = CGVector(
        dx: geometry.localXAxis.dx / 2,
        dy: geometry.localXAxis.dy / 2
    )
    let halfY = CGVector(
        dx: geometry.localYAxis.dx / 2,
        dy: geometry.localYAxis.dy / 2
    )
    func point(x: CGFloat, y: CGFloat) -> CGPoint {
        CGPoint(
            x: geometry.center.x + halfX.dx * x + halfY.dx * y,
            y: geometry.center.y + halfX.dy * x + halfY.dy * y
        )
    }
    return PDFFreeTextOverlayGeometry(
        minXMinY: point(x: -1, y: -1),
        maxXMinY: point(x: 1, y: -1),
        maxXMaxY: point(x: 1, y: 1),
        minXMaxY: point(x: -1, y: 1),
        minXMidY: point(x: -1, y: 0),
        maxXMidY: point(x: 1, y: 0)
    )
}

func clampedPDFFreeTextBounds(
    _ requestedBounds: CGRect,
    to pageBounds: CGRect,
    minimumSize: CGSize = CGSize(width: 36, height: 24)
) -> CGRect {
    let pageBounds = pageBounds.standardized
    guard pageBounds.width > 0, pageBounds.height > 0 else { return .zero }

    var bounds = requestedBounds.standardized
    bounds.size.width = min(max(bounds.width, minimumSize.width), pageBounds.width)
    bounds.size.height = min(max(bounds.height, minimumSize.height), pageBounds.height)
    bounds.origin.x = min(max(bounds.minX, pageBounds.minX), pageBounds.maxX - bounds.width)
    bounds.origin.y = min(max(bounds.minY, pageBounds.minY), pageBounds.maxY - bounds.height)
    return bounds
}

func defaultPDFFreeTextBounds(at point: CGPoint, pageBounds: CGRect) -> CGRect {
    clampedPDFFreeTextBounds(
        CGRect(x: point.x, y: point.y - 72, width: 220, height: 72),
        to: pageBounds
    )
}

func draggedPDFFreeTextBounds(from start: CGPoint, to end: CGPoint, pageBounds: CGRect) -> CGRect {
    clampedPDFFreeTextBounds(
        CGRect(
            x: start.x,
            y: start.y,
            width: end.x - start.x,
            height: end.y - start.y
        ).standardized,
        to: pageBounds
    )
}

func makePDFFreeTextAnnotation(
    bounds: CGRect,
    contents: String = "",
    formatting: PDFFreeTextFormatting = .defaultValue
) -> PDFAnnotation {
    let annotation = PDFAnnotation(bounds: bounds.standardized, forType: .freeText, withProperties: nil)
    annotation.contents = contents
    formatting.apply(to: annotation)
    let border = PDFBorder()
    border.lineWidth = 0
    annotation.border = border
    annotation.color = .clear
    annotation.userName = NSFullUserName()
    annotation.modificationDate = Date()
    annotation.shouldDisplay = true
    annotation.shouldPrint = true
    return annotation
}

enum PDFFreeTextResizeHandle: CaseIterable {
    case minXMidY
    case maxXMidY
}

struct PDFFreeTextResizeResult: Equatable {
    let bounds: CGRect
    let fontSize: CGFloat
}

func resizedPDFFreeText(
    _ original: CGRect,
    fontSize: CGFloat,
    handle: PDFFreeTextResizeHandle,
    to point: CGPoint,
    pageBounds: CGRect,
    minimumSize: CGSize
) -> PDFFreeTextResizeResult {
    let original = original.standardized
    let pageBounds = pageBounds.standardized
    let sourceFontSize = fontSize.isFinite && fontSize > 0 ? fontSize : 14
    guard original.width > 0,
          original.height > 0,
          pageBounds.width > 0,
          pageBounds.height > 0
    else {
        return PDFFreeTextResizeResult(
            bounds: original,
            fontSize: min(max(sourceFontSize, 6), 144)
        )
    }

    let requestedWidth: CGFloat
    let availableWidth: CGFloat
    switch handle {
    case .minXMidY:
        requestedWidth = original.maxX - point.x
        availableWidth = original.maxX - pageBounds.minX
    case .maxXMidY:
        requestedWidth = point.x - original.minX
        availableWidth = pageBounds.maxX - original.minX
    }

    let minimumScale = max(
        max(minimumSize.width / original.width, minimumSize.height / original.height),
        6 / sourceFontSize
    )
    let verticalScale = min(
        (original.midY - pageBounds.minY) * 2 / original.height,
        (pageBounds.maxY - original.midY) * 2 / original.height
    )
    let maximumScale = max(
        0,
        min(min(availableWidth / original.width, verticalScale), 144 / sourceFontSize)
    )
    let lowerScale = min(minimumScale, maximumScale)
    let requestedScale = requestedWidth / original.width
    let scale = min(max(requestedScale, lowerScale), maximumScale)
    guard scale.isFinite, scale > 0 else {
        return PDFFreeTextResizeResult(
            bounds: original,
            fontSize: min(max(sourceFontSize, 6), 144)
        )
    }

    let size = CGSize(width: original.width * scale, height: original.height * scale)
    let originX = handle == .minXMidY ? original.maxX - size.width : original.minX
    let bounds = CGRect(
        x: originX,
        y: original.midY - size.height / 2,
        width: size.width,
        height: size.height
    ).standardized
    return PDFFreeTextResizeResult(
        bounds: bounds,
        fontSize: min(max(sourceFontSize * scale, 6), 144)
    )
}

private final class PDFFreeTextGesture {
    enum Kind {
        case create
        case move
        case resize(PDFFreeTextResizeHandle)
    }

    let kind: Kind
    let page: PDFPage
    let pageIndex: Int
    let startPoint: CGPoint
    var baselineData: Data?
    var didCaptureBaseline = false
    var annotation: PDFAnnotation?
    var beforeSnapshot: PDFFreeTextAnnotationSnapshot?
    var expectedSnapshot: PDFFreeTextAnnotationSnapshot?
    var currentPoint: CGPoint

    init(
        kind: Kind,
        page: PDFPage,
        pageIndex: Int,
        startPoint: CGPoint,
        baselineData: Data?,
        annotation: PDFAnnotation? = nil,
        beforeSnapshot: PDFFreeTextAnnotationSnapshot? = nil
    ) {
        self.kind = kind
        self.page = page
        self.pageIndex = pageIndex
        self.startPoint = startPoint
        self.baselineData = baselineData
        didCaptureBaseline = baselineData != nil
        self.annotation = annotation
        self.beforeSnapshot = beforeSnapshot
        self.expectedSnapshot = beforeSnapshot
        self.currentPoint = startPoint
    }
}

private final class PDFFreeTextEditorTextView: NSTextView {
    var cancelEditing: () -> Void = {}
    var commitEditing: () -> Void = {}

    override func cancelOperation(_ sender: Any?) {
        cancelEditing()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.independentFlags == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            commitEditing()
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class PDFFreeTextSelectionOverlay: NSView {
    enum Content {
        case selection(PDFFreeTextOverlayGeometry)
        case creation(start: CGPoint, end: CGPoint)
    }

    var content: Content? {
        didSet {
            isHidden = content == nil
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let content, let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        context.setLineWidth(1)
        switch content {
        case .creation(let start, let end):
            let rect = CGRect(
                x: start.x,
                y: start.y,
                width: end.x - start.x,
                height: end.y - start.y
            ).standardized
            guard rect.width >= 1, rect.height >= 1 else {
                context.restoreGState()
                return
            }
            context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.72).cgColor)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(rect)

        case .selection(let geometry):
            context.setStrokeColor(NSColor(calibratedWhite: 0.42, alpha: 0.78).cgColor)
            context.beginPath()
            context.move(to: geometry.minXMinY)
            context.addLine(to: geometry.maxXMinY)
            context.addLine(to: geometry.maxXMaxY)
            context.addLine(to: geometry.minXMaxY)
            context.closePath()
            context.strokePath()

            let handleSize: CGFloat = 8
            context.setFillColor(NSColor.controlAccentColor.cgColor)
            context.setStrokeColor(NSColor.white.cgColor)
            for point in [geometry.minXMidY, geometry.maxXMidY] {
                let rect = CGRect(
                    x: point.x - handleSize / 2,
                    y: point.y - handleSize / 2,
                    width: handleSize,
                    height: handleSize
                )
                context.fillEllipse(in: rect)
                context.strokeEllipse(in: rect)
            }
        }
        context.restoreGState()
    }
}

final class AnnotatingPDFView: PDFView, NSTextViewDelegate {
    var annotationMode: PDFAnnotationInteractionMode = .select {
        didSet {
            if oldValue != annotationMode {
                discardActiveInkAnnotation()
                if oldValue == .freeText, annotationMode != .freeText {
                    endFreeTextEditing(commit: true)
                    clearFreeTextSelection()
                }
                syncToolTrackingArea()
                window?.invalidateCursorRects(for: self)
                setToolCursorIfPointerIsInside()
            }
        }
    }
    var annotationColor: NSColor = PDFAnnotationPaletteColor.yellow.nsColor
    var annotationLineWidth: CGFloat = 3
    var onEdited: (Data?, Data, PDFAnnotationEditCheckpoint) -> Void = { _, _, _ in }
    var onRestoreSavedEditCheckpoint: (PDFAnnotationEditCheckpoint) -> Bool = { _ in false }
    var onUndoStateChanged: (Bool, Bool) -> Void = { _, _ in }
    var onError: (String) -> Void = { _ in }
    var onRequestLinkedExcerptCopy: (PDFSelectionSnapshot) -> Void = { _ in }
    var onAnnotationsChanged: () -> Void = {}
    var onFreeTextSelectionChanged: (PDFFreeTextFormatting?) -> Void = { _ in }
    var linkedExcerptDocumentID: String?
    var linkedExcerptContentVersion = 0

    private weak var activeInkPage: PDFPage?
    private var activeInkPoints: [CGPoint] = []
    private var activeInkAnnotation: PDFAnnotation?
    private var activeInkBaselineData: Data?
    private var selectedFreeTextAnnotation: PDFAnnotation?
    private weak var selectedFreeTextPage: PDFPage?
    private var freeTextGesture: PDFFreeTextGesture?
    private var freeTextEditorScrollView: NSScrollView?
    private var freeTextEditor: PDFFreeTextEditorTextView?
    private var freeTextEditorBeforeSnapshot: PDFFreeTextAnnotationSnapshot?
    private var freeTextEditorBaselineData: Data?
    private var freeTextEditorOriginalData: Data?
    private var freeTextEditorOriginalShouldDisplay: Bool?
    private var freeTextEditorStartedWithCleanBaseline = false
    private var freeTextEditorIsNew = false
    private var freeTextEditorHasPublished = false
    private var freeTextEditorObserverTokens: [NSObjectProtocol] = []
    private weak var freeTextObservedClipView: NSClipView?
    private var freeTextObservedClipViewPreviouslyPostedBoundsChanges = false
    private var freeTextSelectionOverlay: PDFFreeTextSelectionOverlay?
    private var freeTextOverlayObserverTokens: [NSObjectProtocol] = []
    private weak var freeTextOverlayObservedClipView: NSClipView?
    private var freeTextOverlayObservedClipViewPreviouslyPostedBoundsChanges = false
    private var isEndingFreeTextEditing = false
    private var toolTrackingArea: NSTrackingArea?
    private var undoStack: [PDFAnnotationEditOperation] = []
    private var redoStack: [PDFAnnotationEditOperation] = []
    private var needsEditBaselineSnapshot = true
    private var loadedSourceBaselineData: Data?
    private var lastPublishedDocumentData: Data?
    private var cleanUndoOperationIDs: [UUID]?
    private var savedEditCheckpoint: PDFAnnotationEditCheckpoint?
    var serializeDocument: (PDFDocument) -> Data? = { $0.dataRepresentation() }
    private var toolCursor: NSCursor { PDFAnnotationToolCursor.cursor(for: annotationMode) }

    override var acceptsFirstResponder: Bool {
        true
    }

    var hasActiveFreeTextEditor: Bool {
        freeTextEditor != nil && freeTextEditorScrollView?.superview === self
    }

    override func layout() {
        super.layout()
        if let scrollView = documentView?.enclosingScrollView {
            MonknotScrollbarStyle.apply(to: scrollView)
        }
        updateFreeTextSelectionOverlay()
        updateFreeTextEditorFrame()
        if annotationMode == .freeText {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if annotationMode == .freeText {
            if event.keyCode == 51 || event.keyCode == 117 {
                deleteSelectedFreeTextAnnotation()
                return
            }
            if event.keyCode == 53 {
                clearFreeTextSelection()
                return
            }
        }

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
        let title = "Copy Linked Excerpt"
        let item: NSMenuItem
        if let existingItem = menu.items.first(where: { $0.title == title }) {
            item = existingItem
        } else {
            if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false {
                menu.addItem(.separator())
            }
            item = NSMenuItem(
                title: title,
                action: #selector(requestLinkedExcerptCopy(_:)),
                keyEquivalent: ""
            )
            menu.addItem(item)
        }
        item.target = self
        item.isEnabled = currentLinkedExcerptSelectionSnapshot != nil
        return menu
    }

    @objc private func requestLinkedExcerptCopy(_ sender: Any?) {
        guard let snapshot = currentLinkedExcerptSelectionSnapshot else {
            onError("Select text on one PDF page to copy a linked excerpt.")
            return
        }
        onRequestLinkedExcerptCopy(snapshot)
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
        switch annotationMode {
        case .select:
            super.resetCursorRects()
        case .freeText:
            addCursorRect(bounds, cursor: .iBeam)
            if let annotation = selectedFreeTextAnnotation,
               let page = selectedFreeTextPage,
               isValidFreeTextAnnotation(annotation, on: page) {
                addCursorRect(convert(annotation.bounds, from: page).standardized, cursor: .openHand)
                for (_, point) in freeTextHandlePoints(annotation: annotation, page: page) {
                    addCursorRect(
                        freeTextHandleHitRect(centeredAt: point),
                        cursor: freeTextResizeCursor(annotation: annotation, page: page)
                    )
                }
            }
        case .pen, .eraser:
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
        cursor(for: event).set()
    }

    override func mouseMoved(with event: NSEvent) {
        if annotationMode == .select {
            super.mouseMoved(with: event)
        } else {
            cursor(for: event).set()
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
            cursor(at: point).set()
        }
    }

    private func cursor(for event: NSEvent) -> NSCursor {
        cursor(at: convert(event.locationInWindow, from: nil))
    }

    private func cursor(at viewPoint: CGPoint) -> NSCursor {
        guard annotationMode == .freeText else { return toolCursor }
        if let gesture = freeTextGesture {
            switch gesture.kind {
            case .move:
                return .closedHand
            case .resize:
                guard let annotation = gesture.annotation else { return .resizeLeftRight }
                return freeTextResizeCursor(annotation: annotation, page: gesture.page)
            case .create:
                return .iBeam
            }
        }
        if let annotation = selectedFreeTextAnnotation,
           let page = selectedFreeTextPage,
           isValidFreeTextAnnotation(annotation, on: page) {
            if freeTextResizeHandle(at: viewPoint, annotation: annotation, page: page) != nil {
                return freeTextResizeCursor(annotation: annotation, page: page)
            }
            if convert(annotation.bounds, from: page).standardized.contains(viewPoint) {
                return .openHand
            }
        }
        if let page = page(for: viewPoint, nearest: false),
           freeTextAnnotation(on: page, at: convert(viewPoint, to: page)) != nil {
            return .openHand
        }
        return .iBeam
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
        case .freeText:
            handleFreeTextMouseDown(event)
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
        case .freeText:
            handleFreeTextMouseDragged(event)
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
        case .freeText:
            handleFreeTextMouseUp(event)
        case .eraser:
            break
        }
    }

    private func handleFreeTextMouseDown(_ event: NSEvent) {
        guard canAnnotate(), let target = pagePoint(for: event), let document else { return }
        if freeTextEditor != nil {
            endFreeTextEditing(commit: true)
        }

        let viewPoint = convert(event.locationInWindow, from: nil)
        if let annotation = selectedFreeTextAnnotation,
           let page = selectedFreeTextPage,
           page === target.page,
           isValidFreeTextAnnotation(annotation, on: page) {
            if beginEditingSelectedFreeTextIfDoubleClicked(
                at: target.point,
                on: page,
                clickCount: event.clickCount
            ) {
                return
            }
            let before = PDFFreeTextAnnotationSnapshot(annotation: annotation)
            if let handle = freeTextResizeHandle(at: viewPoint, annotation: annotation, page: page) {
                freeTextGesture = PDFFreeTextGesture(
                    kind: .resize(handle),
                    page: page,
                    pageIndex: document.index(for: page),
                    startPoint: target.point,
                    baselineData: nil,
                    annotation: annotation,
                    beforeSnapshot: before
                )
                freeTextResizeCursor(annotation: annotation, page: page).set()
                return
            }
            if convert(annotation.bounds, from: page).standardized.contains(viewPoint) {
                freeTextGesture = PDFFreeTextGesture(
                    kind: .move,
                    page: page,
                    pageIndex: document.index(for: page),
                    startPoint: target.point,
                    baselineData: nil,
                    annotation: annotation,
                    beforeSnapshot: before
                )
                NSCursor.closedHand.set()
                return
            }
        }

        if let annotation = freeTextAnnotation(on: target.page, at: target.point) {
            selectFreeTextAnnotation(annotation, on: target.page)
            if event.clickCount >= 2 {
                beginFreeTextEditing(
                    annotation,
                    on: target.page,
                    isNew: false,
                    baselineData: editBaselineDataWithoutConsuming(),
                    initialSelectionPagePoint: target.point,
                    selectsWordAtInitialPoint: true
                )
            } else {
                let before = PDFFreeTextAnnotationSnapshot(annotation: annotation)
                freeTextGesture = PDFFreeTextGesture(
                    kind: .move,
                    page: target.page,
                    pageIndex: document.index(for: target.page),
                    startPoint: target.point,
                    baselineData: nil,
                    annotation: annotation,
                    beforeSnapshot: before
                )
                NSCursor.closedHand.set()
            }
            return
        }

        clearFreeTextSelection()
        freeTextGesture = PDFFreeTextGesture(
            kind: .create,
            page: target.page,
            pageIndex: document.index(for: target.page),
            startPoint: target.point,
            baselineData: nil
        )
        NSCursor.iBeam.set()
        updateFreeTextSelectionOverlay()
    }

    private func handleFreeTextMouseDragged(_ event: NSEvent) {
        guard let gesture = freeTextGesture,
              let document,
              document.page(at: gesture.pageIndex) === gesture.page
        else { return }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let currentPoint = convert(viewPoint, to: gesture.page)
        gesture.currentPoint = currentPoint

        switch gesture.kind {
        case .create:
            updateFreeTextSelectionOverlay()
        case .move, .resize:
            guard let annotation = gesture.annotation,
                  let before = gesture.beforeSnapshot,
                  let expected = gesture.expectedSnapshot,
                  isValidFreeTextAnnotation(annotation, on: gesture.page),
                  PDFFreeTextAnnotationSnapshot(annotation: annotation) == expected
            else {
                cancelFreeTextGestureWithStaleAnnotation()
                return
            }

            if !gesture.didCaptureBaseline {
                gesture.baselineData = editBaselineDataWithoutConsuming()
                gesture.didCaptureBaseline = true
                if needsEditBaselineSnapshot, gesture.baselineData == nil {
                    freeTextGesture = nil
                    onError(PDFAnnotationOperationError.dataRepresentationFailed.localizedDescription)
                    return
                }
            }

            let pageBounds = gesture.page.bounds(for: displayBox)
            let nextBounds: CGRect
            var nextFormatting: PDFFreeTextFormatting?
            switch gesture.kind {
            case .move:
                let delta = CGPoint(
                    x: currentPoint.x - gesture.startPoint.x,
                    y: currentPoint.y - gesture.startPoint.y
                )
                nextBounds = clampedPDFFreeTextBounds(
                    before.bounds.offsetBy(dx: delta.x, dy: delta.y),
                    to: pageBounds,
                    minimumSize: before.bounds.size
                )
            case .resize(let handle):
                let resize = resizedPDFFreeText(
                    before.bounds,
                    fontSize: before.font?.pointSize ?? before.formatting.fontSize,
                    handle: handle,
                    to: currentPoint,
                    pageBounds: pageBounds,
                    minimumSize: CGSize(width: 36, height: 24)
                )
                nextBounds = resize.bounds
                var formatting = before.formatting
                formatting.fontSize = resize.fontSize
                nextFormatting = formatting
            case .create:
                return
            }

            let formattingChanged = nextFormatting.map {
                $0 != PDFFreeTextFormatting(annotation: annotation)
            } ?? false
            guard nextBounds != annotation.bounds.standardized || formattingChanged else { return }
            annotation.bounds = nextBounds
            nextFormatting?.apply(to: annotation)
            gesture.expectedSnapshot = PDFFreeTextAnnotationSnapshot(annotation: annotation)
            // PDFKit owns the annotation appearance, while the lightweight AppKit
            // overlay owns only selection chrome.
            annotationsChanged(on: gesture.page)
            updateFreeTextSelectionOverlay()
            cursor(for: event).set()
        }
    }

    private func handleFreeTextMouseUp(_ event: NSEvent) {
        guard let gesture = freeTextGesture else { return }
        freeTextGesture = nil
        defer {
            updateFreeTextSelectionOverlay()
            window?.invalidateCursorRects(for: self)
            cursor(for: event).set()
        }

        switch gesture.kind {
        case .create:
            guard let document,
                  document.page(at: gesture.pageIndex) === gesture.page,
                  canAnnotate()
            else { return }
            let startViewPoint = convert(gesture.startPoint, from: gesture.page)
            let currentViewPoint = convert(gesture.currentPoint, from: gesture.page)
            let distance = hypot(currentViewPoint.x - startViewPoint.x, currentViewPoint.y - startViewPoint.y)
            let requestedBounds: CGRect
            if distance < 4 {
                requestedBounds = defaultPDFFreeTextBounds(
                    at: gesture.startPoint,
                    pageBounds: gesture.page.bounds(for: displayBox)
                )
            } else {
                requestedBounds = draggedPDFFreeTextBounds(
                    from: gesture.startPoint,
                    to: gesture.currentPoint,
                    pageBounds: gesture.page.bounds(for: displayBox)
                )
            }
            let bounds = clampedPDFFreeTextBounds(
                requestedBounds,
                to: gesture.page.bounds(for: displayBox)
            )
            guard bounds.width > 0, bounds.height > 0 else { return }
            let baselineData = editBaselineDataWithoutConsuming()
            guard !needsEditBaselineSnapshot || baselineData != nil else {
                onError(PDFAnnotationOperationError.dataRepresentationFailed.localizedDescription)
                return
            }
            guard let originalData = baselineData
                ?? lastPublishedDocumentData
                ?? serializeDocument(document)
            else {
                onError(PDFAnnotationOperationError.dataRepresentationFailed.localizedDescription)
                return
            }
            let annotation = makePDFFreeTextAnnotation(bounds: bounds)
            gesture.baselineData = needsEditBaselineSnapshot ? baselineData : nil
            gesture.didCaptureBaseline = true
            gesture.page.addAnnotation(annotation)
            selectFreeTextAnnotation(annotation, on: gesture.page)
            annotationsChanged(on: gesture.page)
            onAnnotationsChanged()
            beginFreeTextEditing(
                annotation,
                on: gesture.page,
                isNew: true,
                baselineData: gesture.baselineData,
                originalData: originalData
            )
        case .move, .resize:
            guard let annotation = gesture.annotation,
                  let before = gesture.beforeSnapshot,
                  let expected = gesture.expectedSnapshot,
                  isValidFreeTextAnnotation(annotation, on: gesture.page),
                  PDFFreeTextAnnotationSnapshot(annotation: annotation) == expected
            else {
                restoreUncommittedFreeTextGestureIfSafe(gesture)
                clearFreeTextSelection()
                onError(PDFAnnotationOperationError.annotationChanged.localizedDescription)
                return
            }
            let finalSnapshot = PDFFreeTextAnnotationSnapshot(annotation: annotation)
            guard before != finalSnapshot else { return }
            annotation.modificationDate = Date()
            let after = PDFFreeTextAnnotationSnapshot(annotation: annotation)
            registerAnnotationEdit(PDFAnnotationEditOperation(
                added: [],
                removed: [],
                updated: [.init(
                    pageIndex: gesture.pageIndex,
                    annotation: annotation,
                    before: before,
                    after: after
                )]
            ))
            annotationsChanged(on: gesture.page)
            onAnnotationsChanged()
            publishEditedDocument(previousData: gesture.baselineData)
            publishFreeTextSelection()
        }
    }

    func selectFreeTextAnnotation(_ annotation: PDFAnnotation, on page: PDFPage) {
        guard isValidFreeTextAnnotation(annotation, on: page) else {
            onError(PDFAnnotationOperationError.annotationChanged.localizedDescription)
            return
        }
        selectedFreeTextAnnotation = annotation
        selectedFreeTextPage = page
        updateFreeTextSelectionOverlay()
        window?.invalidateCursorRects(for: self)
        publishFreeTextSelection()
    }

    @discardableResult
    func beginEditingSelectedFreeTextIfDoubleClicked(
        at pagePoint: CGPoint,
        on page: PDFPage,
        clickCount: Int
    ) -> Bool {
        guard clickCount >= 2,
              let annotation = selectedFreeTextAnnotation,
              selectedFreeTextPage === page,
              isValidFreeTextAnnotation(annotation, on: page),
              annotation.bounds.standardized.contains(pagePoint)
        else { return false }
        beginFreeTextEditing(
            annotation,
            on: page,
            isNew: false,
            baselineData: editBaselineDataWithoutConsuming(),
            initialSelectionPagePoint: pagePoint,
            selectsWordAtInitialPoint: true
        )
        return true
    }

    func applyFreeTextFormatting(_ formatting: PDFFreeTextFormatting) {
        if let annotation = selectedFreeTextAnnotation,
           let page = selectedFreeTextPage,
           isValidFreeTextAnnotation(annotation, on: page),
           formatting == PDFFreeTextFormatting(annotation: annotation) {
            publishFreeTextSelection()
            return
        }
        let editorSelection = freeTextEditor?.selectedRange()
        endFreeTextEditing(commit: true)
        guard let annotation = selectedFreeTextAnnotation,
              let page = selectedFreeTextPage,
              let document,
              isValidFreeTextAnnotation(annotation, on: page)
        else {
            onError(PDFAnnotationOperationError.annotationChanged.localizedDescription)
            clearFreeTextSelection()
            return
        }

        let before = PDFFreeTextAnnotationSnapshot(annotation: annotation)
        let previousData = editBaselineDataWithoutConsuming()
        if needsEditBaselineSnapshot, previousData == nil {
            onError(PDFAnnotationOperationError.dataRepresentationFailed.localizedDescription)
            return
        }
        formatting.apply(to: annotation)
        guard PDFFreeTextAnnotationSnapshot(annotation: annotation) != before else {
            publishFreeTextSelection()
            resumeFreeTextEditingIfNeeded(
                selectedRange: editorSelection,
                annotation: annotation,
                page: page
            )
            return
        }
        annotation.modificationDate = Date()
        let after = PDFFreeTextAnnotationSnapshot(annotation: annotation)

        registerAnnotationEdit(PDFAnnotationEditOperation(
            added: [],
            removed: [],
            updated: [.init(
                pageIndex: document.index(for: page),
                annotation: annotation,
                before: before,
                after: after
            )]
        ))
        annotationsChanged(on: page)
        onAnnotationsChanged()
        guard publishEditedDocument(previousData: previousData) else { return }
        publishFreeTextSelection()
        resumeFreeTextEditingIfNeeded(
            selectedRange: editorSelection,
            annotation: annotation,
            page: page
        )
    }

    private func resumeFreeTextEditingIfNeeded(
        selectedRange: NSRange?,
        annotation: PDFAnnotation,
        page: PDFPage
    ) {
        guard let selectedRange,
              isValidFreeTextAnnotation(annotation, on: page)
        else { return }
        beginFreeTextEditing(
            annotation,
            on: page,
            isNew: false,
            baselineData: editBaselineDataWithoutConsuming()
        )
        guard let editor = freeTextEditor else { return }
        let length = (editor.string as NSString).length
        let location = min(max(selectedRange.location, 0), length)
        let selectionLength = min(max(selectedRange.length, 0), length - location)
        editor.setSelectedRange(NSRange(location: location, length: selectionLength))
    }

    func beginFreeTextEditing(
        _ annotation: PDFAnnotation,
        on page: PDFPage,
        isNew: Bool,
        baselineData: Data?,
        originalData: Data? = nil,
        initialSelectionPagePoint: CGPoint? = nil,
        selectsWordAtInitialPoint: Bool = false
    ) {
        guard isValidFreeTextAnnotation(annotation, on: page) else {
            onError(PDFAnnotationOperationError.annotationChanged.localizedDescription)
            return
        }
        if needsEditBaselineSnapshot, baselineData == nil {
            onError(PDFAnnotationOperationError.dataRepresentationFailed.localizedDescription)
            return
        }
        endFreeTextEditing(commit: true)
        selectFreeTextAnnotation(annotation, on: page)
        let beforeSnapshot = isNew ? nil : PDFFreeTextAnnotationSnapshot(annotation: annotation)
        let originalShouldDisplay = annotation.shouldDisplay

        let scrollView = NSScrollView(frame: .zero)
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let editor = PDFFreeTextEditorTextView(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 4, height: 3)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.lineFragmentPadding = 0
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.string = annotation.contents ?? ""
        let formatting = PDFFreeTextFormatting(annotation: annotation)
        editor.font = annotation.font ?? formatting.font
        editor.textColor = annotation.fontColor ?? formatting.fontColor
        editor.alignment = annotation.alignment
        editor.delegate = self
        editor.cancelEditing = { [weak self] in
            self?.cancelActiveFreeTextEditing()
        }
        editor.commitEditing = { [weak self] in
            self?.commitActiveFreeTextEdit()
        }
        scrollView.documentView = editor
        addSubview(scrollView)

        freeTextEditorScrollView = scrollView
        freeTextEditor = editor
        freeTextEditorBeforeSnapshot = beforeSnapshot
        freeTextEditorBaselineData = baselineData
        freeTextEditorOriginalData = originalData
            ?? baselineData
            ?? lastPublishedDocumentData
            ?? document.flatMap(serializeDocument)
        freeTextEditorOriginalShouldDisplay = originalShouldDisplay
        freeTextEditorStartedWithCleanBaseline = baselineData != nil
        freeTextEditorIsNew = isNew
        freeTextEditorHasPublished = false
        installFreeTextEditorObservers()
        updateFreeTextEditorFrame()
        annotation.shouldDisplay = false
        annotationsChanged(on: page)
        if let initialSelectionPagePoint {
            let pointInPDFView = convert(initialSelectionPagePoint, from: page)
            let pointInEditor = editor.convert(pointInPDFView, from: self)
            let length = (editor.string as NSString).length
            let characterIndex = min(max(editor.characterIndexForInsertion(at: pointInEditor), 0), length)
            let insertionRange = NSRange(location: characterIndex, length: 0)
            let selection = selectsWordAtInitialPoint
                ? editor.selectionRange(
                    forProposedRange: insertionRange,
                    granularity: .selectByWord
                  )
                : insertionRange
            editor.setSelectedRange(selection)
        } else {
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
        window?.makeFirstResponder(editor)
        publishUndoState()
    }

    func cancelActiveFreeTextEditing() {
        endFreeTextEditing(commit: true)
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = notification.object as? PDFFreeTextEditorTextView,
              editor === freeTextEditor,
              let annotation = selectedFreeTextAnnotation,
              let page = selectedFreeTextPage,
              isValidFreeTextAnnotation(annotation, on: page)
        else { return }
        defer { publishUndoState() }

        annotation.contents = editor.string
        if freeTextEditorIsNew || freeTextEditorBeforeSnapshot?.contents != editor.string {
            annotation.modificationDate = Date()
        }
        updateFreeTextSelectionOverlay()

        if reconcileCleanFreeTextEditorBaselineIfNeeded(editor) {
            return
        }
        if !freeTextEditorHasPublished {
            publishActiveFreeTextEdit()
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView,
              editor === freeTextEditor,
              !isEndingFreeTextEditing
        else { return }
        endFreeTextEditing(commit: true)
    }

    func finishFreeTextEditingForDocumentSwitch() {
        endFreeTextEditing(commit: true)
    }

    func cancelFreeTextEditingBeforeDocumentReplacement() {
        endFreeTextEditing(commit: false)
        freeTextGesture = nil
        clearFreeTextSelection()
    }

    private func endFreeTextEditing(commit: Bool) {
        guard !isEndingFreeTextEditing,
              let editor = freeTextEditor,
              let annotation = selectedFreeTextAnnotation,
              let page = selectedFreeTextPage
        else { return }
        isEndingFreeTextEditing = true
        defer {
            isEndingFreeTextEditing = false
            publishUndoState()
        }

        removeFreeTextEditorObservers()
        editor.delegate = nil
        editor.cancelEditing = {}
        editor.commitEditing = {}
        freeTextEditorScrollView?.removeFromSuperview()
        freeTextEditorScrollView = nil
        freeTextEditor = nil
        annotation.shouldDisplay = freeTextEditorOriginalShouldDisplay ?? true

        guard isValidFreeTextAnnotation(annotation, on: page) else {
            clearFreeTextEditorState()
            clearFreeTextSelection()
            onError(PDFAnnotationOperationError.annotationChanged.localizedDescription)
            return
        }

        annotation.contents = editor.string
        if !commit, !freeTextEditorIsNew {
            freeTextEditorBeforeSnapshot?.apply(to: annotation)
            annotationsChanged(on: page)
            onAnnotationsChanged()
            clearFreeTextEditorState()
            publishFreeTextSelection()
            return
        }
        let isEmpty = editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let finalPreviousData = freeTextEditorHasPublished ? nil : freeTextEditorBaselineData
        if freeTextEditorIsNew, (!commit || isEmpty) {
            page.removeAnnotation(annotation)
            annotationsChanged(on: page)
            onAnnotationsChanged()
            if commit {
                restoreOriginalFreeTextDataAfterCancellationIfNeeded()
            }
            clearFreeTextEditorState()
            clearFreeTextSelection()
            return
        }

        if !freeTextEditorIsNew,
           let before = freeTextEditorBeforeSnapshot,
           before.contents == editor.string {
            before.apply(to: annotation)
            annotationsChanged(on: page)
            onAnnotationsChanged()
            restoreOriginalFreeTextDataAfterCancellationIfNeeded()
            clearFreeTextEditorState()
            publishFreeTextSelection()
            return
        }

        if freeTextEditorIsNew || freeTextEditorBeforeSnapshot?.contents != editor.string {
            annotation.modificationDate = Date()
        }
        let after = PDFFreeTextAnnotationSnapshot(annotation: annotation)
        if freeTextEditorIsNew, let document {
            registerAnnotationEdit(PDFAnnotationEditOperation(
                added: [.init(pageIndex: document.index(for: page), annotation: annotation)],
                removed: [],
                updated: []
            ))
        } else if let before = freeTextEditorBeforeSnapshot,
                  before != after,
                  let document {
            registerAnnotationEdit(PDFAnnotationEditOperation(
                added: [],
                removed: [],
                updated: [.init(
                    pageIndex: document.index(for: page),
                    annotation: annotation,
                    before: before,
                    after: after
                )]
            ))
        }

        if freeTextEditorIsNew || freeTextEditorBeforeSnapshot != after {
            publishEditedDocument(previousData: finalPreviousData)
            annotationsChanged(on: page)
            onAnnotationsChanged()
        }
        clearFreeTextEditorState()
        publishFreeTextSelection()
    }

    private func clearFreeTextEditorState() {
        freeTextEditorBeforeSnapshot = nil
        freeTextEditorBaselineData = nil
        freeTextEditorOriginalData = nil
        freeTextEditorOriginalShouldDisplay = nil
        freeTextEditorStartedWithCleanBaseline = false
        freeTextEditorIsNew = false
        freeTextEditorHasPublished = false
    }

    private func restoreOriginalFreeTextDataAfterCancellationIfNeeded() {
        guard freeTextEditorHasPublished else { return }
        if let originalData = freeTextEditorOriginalData {
            publishEditedData(originalData, previousData: nil)
            if freeTextEditorStartedWithCleanBaseline {
                needsEditBaselineSnapshot = true
            }
        } else {
            publishEditedDocument(previousData: nil)
        }
    }

    private func reconcileCleanFreeTextEditorBaselineIfNeeded(
        _ editor: PDFFreeTextEditorTextView
    ) -> Bool {
        guard !freeTextEditorIsNew,
              freeTextEditorStartedWithCleanBaseline,
              freeTextEditorBeforeSnapshot?.contents == editor.string
        else { return false }

        guard freeTextEditorHasPublished,
              let originalData = freeTextEditorOriginalData
        else {
            // A duplicate text notification at the untouched clean baseline must not
            // create a dirty PDF edit.
            return true
        }

        freeTextEditorHasPublished = false
        freeTextEditorBaselineData = originalData
        needsEditBaselineSnapshot = true
        publishEditedData(originalData, previousData: nil)
        return true
    }

    private func publishActiveFreeTextEdit() {
        guard freeTextEditor != nil,
              let annotation = selectedFreeTextAnnotation,
              let page = selectedFreeTextPage,
              isValidFreeTextAnnotation(annotation, on: page)
        else { return }
        let previousData = freeTextEditorHasPublished ? nil : freeTextEditorBaselineData
        annotation.shouldDisplay = freeTextEditorOriginalShouldDisplay ?? true
        let didPublish = publishEditedDocument(previousData: previousData)
        if didPublish,
           freeTextEditor != nil,
           selectedFreeTextAnnotation === annotation,
           selectedFreeTextPage === page,
           isValidFreeTextAnnotation(annotation, on: page) {
            annotation.shouldDisplay = false
        }
        if didPublish {
            freeTextEditorHasPublished = true
            freeTextEditorBaselineData = nil
        }
    }

    private func installFreeTextEditorObservers() {
        removeFreeTextEditorObservers()
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewVisiblePagesChanged] {
            freeTextEditorObserverTokens.append(center.addObserver(
                forName: name,
                object: self,
                queue: .main
            ) { [weak self] _ in
                self?.updateFreeTextEditorFrame()
            })
        }
        if let clipView = documentView?.enclosingScrollView?.contentView {
            freeTextObservedClipView = clipView
            freeTextObservedClipViewPreviouslyPostedBoundsChanges = clipView.postsBoundsChangedNotifications
            clipView.postsBoundsChangedNotifications = true
            freeTextEditorObserverTokens.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                self?.updateFreeTextEditorFrame()
            })
        }
    }

    private func removeFreeTextEditorObservers() {
        for token in freeTextEditorObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        freeTextEditorObserverTokens = []
        if let freeTextObservedClipView {
            freeTextObservedClipView.postsBoundsChangedNotifications =
                freeTextObservedClipViewPreviouslyPostedBoundsChanges
        }
        freeTextObservedClipView = nil
        freeTextObservedClipViewPreviouslyPostedBoundsChanges = false
    }

    private func updateFreeTextEditorFrame() {
        guard let scrollView = freeTextEditorScrollView,
              let editor = freeTextEditor,
              let annotation = selectedFreeTextAnnotation,
              let page = selectedFreeTextPage,
              isValidFreeTextAnnotation(annotation, on: page),
              let geometry = pdfFreeTextEditorGeometry(
                for: annotation.bounds,
                on: page,
                in: self
              )
        else { return }

        let editorSize = CGSize(
            width: max(geometry.unrotatedSize.width - 2, 1),
            height: max(geometry.unrotatedSize.height - 2, 1)
        )
        scrollView.frameCenterRotation = 0
        scrollView.frame = CGRect(
            x: geometry.center.x - editorSize.width / 2,
            y: geometry.center.y - editorSize.height / 2,
            width: editorSize.width,
            height: editorSize.height
        )
        scrollView.frameCenterRotation = geometry.rotationDegrees

        let formatting = PDFFreeTextFormatting(annotation: annotation)
        let exactFont = annotation.font ?? formatting.font
        editor.font = exactFont.withSize(
            max(exactFont.pointSize * geometry.effectiveScale, 1)
        )
        editor.textColor = annotation.fontColor ?? formatting.fontColor
        editor.alignment = annotation.alignment
        editor.textContainerInset = NSSize(
            width: 4 * geometry.effectiveScale,
            height: 3 * geometry.effectiveScale
        )
        editor.frame = NSRect(origin: .zero, size: editorSize)
        window?.invalidateCursorRects(for: self)
    }

    @discardableResult
    func commitActiveFreeTextEdit() -> Bool {
        guard hasActiveFreeTextEditor else { return false }
        endFreeTextEditing(commit: true)
        return true
    }

    func deleteSelectedFreeTextAnnotation() {
        endFreeTextEditing(commit: true)
        guard let annotation = selectedFreeTextAnnotation,
              let page = selectedFreeTextPage,
              let document,
              isValidFreeTextAnnotation(annotation, on: page)
        else {
            clearFreeTextSelection()
            return
        }
        let previousData = editBaselineDataWithoutConsuming()
        if needsEditBaselineSnapshot, previousData == nil {
            onError(PDFAnnotationOperationError.dataRepresentationFailed.localizedDescription)
            return
        }
        let item = PDFAnnotationEditOperation.Item(pageIndex: document.index(for: page), annotation: annotation)
        page.removeAnnotation(annotation)
        registerAnnotationEdit(PDFAnnotationEditOperation(added: [], removed: [item], updated: []))
        annotationsChanged(on: page)
        onAnnotationsChanged()
        clearFreeTextSelection()
        publishEditedDocument(previousData: previousData)
    }

    private func clearFreeTextSelection() {
        selectedFreeTextAnnotation = nil
        selectedFreeTextPage = nil
        freeTextGesture = nil
        removeFreeTextSelectionOverlay()
        window?.invalidateCursorRects(for: self)
        onFreeTextSelectionChanged(nil)
    }

    private func publishFreeTextSelection() {
        guard let annotation = selectedFreeTextAnnotation,
              let page = selectedFreeTextPage,
              isValidFreeTextAnnotation(annotation, on: page)
        else {
            onFreeTextSelectionChanged(nil)
            return
        }
        onFreeTextSelectionChanged(PDFFreeTextFormatting(annotation: annotation))
    }

    private func freeTextAnnotation(on page: PDFPage, at point: CGPoint) -> PDFAnnotation? {
        page.annotations.reversed().first {
            isFreeTextAnnotation($0) && $0.bounds.standardized.contains(point)
        }
    }

    private func isFreeTextAnnotation(_ annotation: PDFAnnotation) -> Bool {
        (annotation.type ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .caseInsensitiveCompare("FreeText") == .orderedSame
    }

    private func isValidFreeTextAnnotation(_ annotation: PDFAnnotation, on page: PDFPage) -> Bool {
        guard isFreeTextAnnotation(annotation),
              let document,
              document.index(for: page) >= 0,
              document.page(at: document.index(for: page)) === page
        else { return false }
        return page.annotations.contains { $0 === annotation }
    }

    private func editBaselineDataWithoutConsuming() -> Data? {
        guard needsEditBaselineSnapshot else { return nil }
        return loadedSourceBaselineData ?? document?.dataRepresentation()
    }

    private func cancelFreeTextGestureWithStaleAnnotation() {
        if let freeTextGesture {
            restoreUncommittedFreeTextGestureIfSafe(freeTextGesture)
        }
        freeTextGesture = nil
        onError(PDFAnnotationOperationError.annotationChanged.localizedDescription)
        clearFreeTextSelection()
    }

    private func restoreUncommittedFreeTextGestureIfSafe(_ gesture: PDFFreeTextGesture) {
        guard let annotation = gesture.annotation,
              let before = gesture.beforeSnapshot,
              let expected = gesture.expectedSnapshot,
              isValidFreeTextAnnotation(annotation, on: gesture.page)
        else { return }

        let current = PDFFreeTextAnnotationSnapshot(annotation: annotation)
        var restored = false
        if current.bounds == expected.bounds {
            annotation.bounds = before.bounds
            restored = true
        }
        if current.font == expected.font {
            annotation.font = before.font
            restored = true
        }
        if restored {
            annotationsChanged(on: gesture.page)
        }
    }

    private func freeTextResizeHandle(
        at viewPoint: CGPoint,
        annotation: PDFAnnotation,
        page: PDFPage
    ) -> PDFFreeTextResizeHandle? {
        return freeTextHandlePoints(annotation: annotation, page: page).first { _, point in
            freeTextHandleHitRect(centeredAt: point).contains(viewPoint)
        }?.0
    }

    private func freeTextResizeCursor(
        annotation: PDFAnnotation,
        page: PDFPage
    ) -> NSCursor {
        switch pdfFreeTextResizeCursorAxis(
            for: annotation.bounds,
            on: page,
            in: self
        ) {
        case .horizontal:
            return .resizeLeftRight
        case .vertical:
            return .resizeUpDown
        }
    }

    private func freeTextHandleHitRect(centeredAt point: CGPoint) -> CGRect {
        let hitSize: CGFloat = 18
        return CGRect(
            x: point.x - hitSize / 2,
            y: point.y - hitSize / 2,
            width: hitSize,
            height: hitSize
        )
    }

    private func freeTextHandlePoints(
        annotation: PDFAnnotation,
        page: PDFPage
    ) -> [(PDFFreeTextResizeHandle, CGPoint)] {
        let bounds = annotation.bounds.standardized
        let points: [(PDFFreeTextResizeHandle, CGPoint)] = [
            (.minXMidY, CGPoint(x: bounds.minX, y: bounds.midY)),
            (.maxXMidY, CGPoint(x: bounds.maxX, y: bounds.midY))
        ]
        return points.map { ($0.0, convert($0.1, from: page)) }
    }

    var freeTextSelectionOverlayGeometryInPDFView: PDFFreeTextOverlayGeometry? {
        guard let overlay = freeTextSelectionOverlay,
              let content = overlay.content,
              case .selection(let geometry) = content
        else { return nil }
        return geometry.mapPoints { convert($0, from: overlay) }
    }

    private func updateFreeTextSelectionOverlay() {
        if let gesture = freeTextGesture,
           case .create = gesture.kind {
            let overlay = ensureFreeTextSelectionOverlay()
            overlay.content = .creation(
                start: overlay.convert(convert(gesture.startPoint, from: gesture.page), from: self),
                end: overlay.convert(convert(gesture.currentPoint, from: gesture.page), from: self)
            )
            return
        }

        guard let annotation = selectedFreeTextAnnotation,
              let page = selectedFreeTextPage,
              isValidFreeTextAnnotation(annotation, on: page),
              let geometry = pdfFreeTextOverlayGeometry(
                for: annotation.bounds,
                on: page,
                in: self
              )
        else {
            removeFreeTextSelectionOverlay()
            return
        }

        let overlay = ensureFreeTextSelectionOverlay()
        overlay.content = .selection(
            geometry.mapPoints { overlay.convert($0, from: self) }
        )
    }

    private func ensureFreeTextSelectionOverlay() -> PDFFreeTextSelectionOverlay {
        if let overlay = freeTextSelectionOverlay {
            overlay.frame = bounds
            return overlay
        }
        let overlay = PDFFreeTextSelectionOverlay(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay, positioned: .above, relativeTo: nil)
        freeTextSelectionOverlay = overlay
        installFreeTextOverlayObservers()
        return overlay
    }

    private func removeFreeTextSelectionOverlay() {
        removeFreeTextOverlayObservers()
        freeTextSelectionOverlay?.removeFromSuperview()
        freeTextSelectionOverlay = nil
    }

    private func installFreeTextOverlayObservers() {
        guard freeTextOverlayObserverTokens.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewVisiblePagesChanged] {
            freeTextOverlayObserverTokens.append(center.addObserver(
                forName: name,
                object: self,
                queue: .main
            ) { [weak self] _ in
                self?.updateFreeTextSelectionOverlay()
            })
        }
        if let clipView = documentView?.enclosingScrollView?.contentView {
            freeTextOverlayObservedClipView = clipView
            freeTextOverlayObservedClipViewPreviouslyPostedBoundsChanges =
                clipView.postsBoundsChangedNotifications
            clipView.postsBoundsChangedNotifications = true
            freeTextOverlayObserverTokens.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                self?.updateFreeTextSelectionOverlay()
            })
        }
    }

    private func removeFreeTextOverlayObservers() {
        for token in freeTextOverlayObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        freeTextOverlayObserverTokens = []
        if let freeTextOverlayObservedClipView {
            freeTextOverlayObservedClipView.postsBoundsChangedNotifications =
                freeTextOverlayObservedClipViewPreviouslyPostedBoundsChanges
        }
        freeTextOverlayObservedClipView = nil
        freeTextOverlayObservedClipViewPreviouslyPostedBoundsChanges = false
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
        for pageIndex in Set(addedAnnotations.map(\.pageIndex)) {
            if let page = page(at: pageIndex) {
                annotationsChanged(on: page)
            }
        }
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
        if let editor = freeTextEditor {
            guard let undoManager = editor.undoManager, undoManager.canUndo else {
                publishUndoState()
                return
            }
            undoManager.undo()
            publishUndoState()
            return
        }
        endFreeTextEditing(commit: true)
        guard let operation = undoStack.popLast() else { return }
        let previousData = editBaselineDataWithoutConsuming()
        guard apply(operation, inverse: true) else {
            undoStack.append(operation)
            onError(PDFAnnotationOperationError.annotationChanged.localizedDescription)
            publishUndoState()
            return
        }
        redoStack.append(operation)
        publishUndoState()
        onAnnotationsChanged()
        publishUndoRedoDocument(previousData: previousData)
        publishFreeTextSelection()
    }

    func redoAnnotationEdit() {
        if let editor = freeTextEditor {
            guard let undoManager = editor.undoManager, undoManager.canRedo else {
                publishUndoState()
                return
            }
            undoManager.redo()
            publishUndoState()
            return
        }
        endFreeTextEditing(commit: true)
        guard let operation = redoStack.popLast() else { return }
        let previousData = editBaselineDataWithoutConsuming()
        guard apply(operation, inverse: false) else {
            redoStack.append(operation)
            onError(PDFAnnotationOperationError.annotationChanged.localizedDescription)
            publishUndoState()
            return
        }
        undoStack.append(operation)
        publishUndoState()
        onAnnotationsChanged()
        publishUndoRedoDocument(previousData: previousData)
        publishFreeTextSelection()
    }

    func clearAnnotationUndoHistory() {
        undoStack = []
        redoStack = []
        savedEditCheckpoint = nil
        cleanUndoOperationIDs = loadedSourceBaselineData == nil ? nil : []
        publishUndoState()
    }

    func replaceEditBaselineCapture(
        with sourceData: Data?,
        needsSnapshot: Bool,
        currentOwnedData: Data? = nil
    ) {
        loadedSourceBaselineData = sourceData
        lastPublishedDocumentData = currentOwnedData
        cleanUndoOperationIDs = sourceData == nil ? nil : undoStack.map(\.id)
        needsEditBaselineSnapshot = needsSnapshot
    }

    func reconcileEditBaselineCapture(
        hasDirtyData: Bool,
        savedEditCheckpoint: PDFAnnotationEditCheckpoint? = nil
    ) {
        self.savedEditCheckpoint = savedEditCheckpoint
        if hasDirtyData {
            needsEditBaselineSnapshot = false
            return
        }

        if let lastPublishedDocumentData {
            loadedSourceBaselineData = lastPublishedDocumentData
            self.lastPublishedDocumentData = nil
        }
        cleanUndoOperationIDs = loadedSourceBaselineData == nil ? nil : undoStack.map(\.id)
        needsEditBaselineSnapshot = loadedSourceBaselineData != nil
    }

    private func takeEditBaselineSnapshotIfNeeded() -> Data? {
        guard needsEditBaselineSnapshot else { return nil }
        guard let baselineData = loadedSourceBaselineData ?? document?.dataRepresentation() else {
            return nil
        }
        needsEditBaselineSnapshot = false
        return baselineData
    }

    private func registerAnnotationEdit(_ operation: PDFAnnotationEditOperation) {
        guard !operation.added.isEmpty || !operation.removed.isEmpty || !operation.updated.isEmpty else { return }
        undoStack.append(operation)
        redoStack = []
        publishUndoState()
    }

    private func apply(_ operation: PDFAnnotationEditOperation, inverse: Bool) -> Bool {
        guard canApply(operation, inverse: inverse) else { return false }
        let removing = inverse ? operation.added : operation.removed
        let adding = inverse ? operation.removed : operation.added

        for item in removing {
            page(at: item.pageIndex)?.removeAnnotation(item.annotation)
            if selectedFreeTextAnnotation === item.annotation {
                clearFreeTextSelection()
            }
        }
        for item in adding {
            page(at: item.pageIndex)?.addAnnotation(item.annotation)
        }
        for item in operation.updated {
            let snapshot = inverse ? item.before : item.after
            snapshot.apply(to: item.annotation)
        }

        let changedPageIndices = Set(
            removing.map(\.pageIndex) + adding.map(\.pageIndex) + operation.updated.map(\.pageIndex)
        )
        for pageIndex in changedPageIndices {
            if let page = page(at: pageIndex) {
                annotationsChanged(on: page)
            }
        }
        refreshAnnotationDisplay()
        return true
    }

    private func canApply(_ operation: PDFAnnotationEditOperation, inverse: Bool) -> Bool {
        let removing = inverse ? operation.added : operation.removed
        let adding = inverse ? operation.removed : operation.added
        for item in removing {
            guard let page = page(at: item.pageIndex),
                  page.annotations.contains(where: { $0 === item.annotation })
            else { return false }
        }
        for item in adding {
            guard let page = page(at: item.pageIndex),
                  !page.annotations.contains(where: { $0 === item.annotation })
            else { return false }
        }
        for item in operation.updated {
            guard let page = page(at: item.pageIndex),
                  page.annotations.contains(where: { $0 === item.annotation })
            else { return false }
            let expected = inverse ? item.after : item.before
            guard PDFFreeTextAnnotationSnapshot(annotation: item.annotation) == expected else { return false }
        }
        return true
    }

    private func page(at pageIndex: Int) -> PDFPage? {
        guard pageIndex >= 0 else { return nil }
        return document?.page(at: pageIndex)
    }

    private func publishUndoState() {
        if let editor = freeTextEditor {
            onUndoStateChanged(
                editor.undoManager?.canUndo == true,
                editor.undoManager?.canRedo == true
            )
        } else {
            onUndoStateChanged(!undoStack.isEmpty, !redoStack.isEmpty)
        }
    }

    private func refreshAnnotationDisplay(on page: PDFPage? = nil) {
        if let page {
            annotationsChanged(on: page)
            let pageBounds = page.bounds(for: displayBox)
            setNeedsDisplay(convert(pageBounds, from: page))
        } else {
            needsDisplay = true
            documentView?.needsDisplay = true
        }
    }

    @discardableResult
    private func publishEditedDocument(previousData: Data?) -> Bool {
        guard let document,
              let data = serializeDocument(document) else {
            restoreAfterFailedSerialization(previousData: previousData)
            onError(PDFAnnotationOperationError.dataRepresentationFailed.localizedDescription)
            return false
        }
        publishEditedData(data, previousData: previousData)
        return true
    }

    private func publishUndoRedoDocument(previousData: Data?) {
        if let savedEditCheckpoint,
           savedEditCheckpoint == currentEditCheckpoint,
           onRestoreSavedEditCheckpoint(savedEditCheckpoint) {
            self.savedEditCheckpoint = nil
            loadedSourceBaselineData = nil
            lastPublishedDocumentData = nil
            cleanUndoOperationIDs = undoStack.map(\.id)
            needsEditBaselineSnapshot = true
            return
        }
        if let cleanUndoOperationIDs,
           cleanUndoOperationIDs == undoStack.map(\.id),
           let loadedSourceBaselineData {
            publishEditedData(loadedSourceBaselineData, previousData: previousData)
            needsEditBaselineSnapshot = true
        } else {
            publishEditedDocument(previousData: previousData)
        }
    }

    private func publishEditedData(_ data: Data, previousData: Data?) {
        lastPublishedDocumentData = data
        if previousData != nil {
            needsEditBaselineSnapshot = false
        }
        onEdited(previousData, data, currentEditCheckpoint)
    }

    private var currentEditCheckpoint: PDFAnnotationEditCheckpoint {
        PDFAnnotationEditCheckpoint(
            operationCount: undoStack.count,
            lastOperationID: undoStack.last?.id
        )
    }

    private func restoreAfterFailedSerialization(previousData: Data?) {
        let wasDirty = lastPublishedDocumentData != nil
        if let annotation = selectedFreeTextAnnotation,
           freeTextEditor != nil {
            annotation.shouldDisplay = freeTextEditorOriginalShouldDisplay ?? true
        }
        removeFreeTextEditorObservers()
        freeTextEditor?.delegate = nil
        freeTextEditor?.cancelEditing = {}
        freeTextEditor?.commitEditing = {}
        freeTextEditorScrollView?.removeFromSuperview()
        freeTextEditorScrollView = nil
        freeTextEditor = nil
        clearFreeTextEditorState()
        removeFreeTextSelectionOverlay()
        freeTextGesture = nil
        selectedFreeTextAnnotation = nil
        selectedFreeTextPage = nil
        activeInkPage = nil
        activeInkPoints = []
        activeInkAnnotation = nil
        activeInkBaselineData = nil
        clearSelection()

        guard let rollbackData = lastPublishedDocumentData ?? previousData ?? loadedSourceBaselineData,
              let restoredDocument = PDFDocument(data: rollbackData)
        else {
            clearAnnotationUndoHistory()
            document = nil
            onFreeTextSelectionChanged(nil)
            onAnnotationsChanged()
            return
        }

        document = restoredDocument
        undoStack = []
        redoStack = []
        savedEditCheckpoint = nil
        cleanUndoOperationIDs = wasDirty ? nil : []
        if wasDirty {
            lastPublishedDocumentData = rollbackData
            needsEditBaselineSnapshot = false
        } else {
            loadedSourceBaselineData = rollbackData
            lastPublishedDocumentData = nil
            needsEditBaselineSnapshot = true
        }
        publishUndoState()
        onFreeTextSelectionChanged(nil)
        onAnnotationsChanged()
        refreshAnnotationDisplay()
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
        endFreeTextEditing(commit: true)
        removeFreeTextEditorObservers()
        freeTextGesture = nil
        clearFreeTextSelection()
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
        loadedSourceBaselineData = nil
        lastPublishedDocumentData = nil
        cleanUndoOperationIDs = nil
        savedEditCheckpoint = nil
        linkedExcerptDocumentID = nil
        linkedExcerptContentVersion = 0
        onEdited = { _, _, _ in }
        onRestoreSavedEditCheckpoint = { _ in false }
        onUndoStateChanged = { _, _ in }
        onError = { _ in }
        onRequestLinkedExcerptCopy = { _ in }
        onAnnotationsChanged = {}
        onFreeTextSelectionChanged = { _ in }
        serializeDocument = { $0.dataRepresentation() }
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

enum PDFAnnotationInteractionMode: Equatable {
    case select
    case pen
    case freeText
    case eraser
}

private struct PDFAnnotationEditOperation {
    let id = UUID()

    struct Item {
        let pageIndex: Int
        let annotation: PDFAnnotation
    }

    struct UpdatedItem {
        let pageIndex: Int
        let annotation: PDFAnnotation
        let before: PDFFreeTextAnnotationSnapshot
        let after: PDFFreeTextAnnotationSnapshot
    }

    let added: [Item]
    let removed: [Item]
    let updated: [UpdatedItem]

    init(added: [Item], removed: [Item], updated: [UpdatedItem] = []) {
        self.added = added
        self.removed = removed
        self.updated = updated
    }
}

private enum PDFAnnotationToolCursor {
    static func cursor(for mode: PDFAnnotationInteractionMode) -> NSCursor {
        switch mode {
        case .select:
            return .arrow
        case .pen:
            return pen
        case .freeText:
            return .iBeam
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
    case annotationChanged

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
        case .annotationChanged:
            return "The PDF annotation changed before the action completed."
        }
    }
}
