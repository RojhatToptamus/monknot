import AppKit
import MonknotCore
import PDFKit
import XCTest
@testable import MonknotApp

final class PDFTextMarkupGeometryTests: XCTestCase {
    @MainActor
    func testCoordinatorAppliesLightAndDarkThemeTokensToFreeTextOverlay() throws {
        let lightTheme = try XCTUnwrap(MonknotThemeCatalog.lightPresets.first?.theme)
        let darkTheme = try XCTUnwrap(MonknotThemeCatalog.darkPresets.first?.theme)
        let pdfView = AnnotatingPDFView()
        let coordinator = PDFKitPreviewRepresentable.Coordinator()

        coordinator.applyAppearance(
            theme: lightTheme,
            workspaceZoomScale: 0.8,
            in: pdfView
        )
        let light = pdfView.freeTextOverlayAppearance
        XCTAssertEqual(pdfView.freeTextOverlayMetrics.handleSize, 6)
        XCTAssertEqual(pdfView.freeTextOverlayMetrics.handleHitSize, 14)

        coordinator.applyAppearance(
            theme: lightTheme,
            workspaceZoomScale: 1,
            in: pdfView
        )
        XCTAssertEqual(pdfView.freeTextOverlayMetrics.handleSize, 8, accuracy: 0.001)
        XCTAssertEqual(pdfView.freeTextOverlayMetrics.handleHitSize, 18, accuracy: 0.001)

        coordinator.applyAppearance(
            theme: darkTheme,
            workspaceZoomScale: 2,
            in: pdfView
        )
        let dark = pdfView.freeTextOverlayAppearance
        XCTAssertEqual(pdfView.freeTextOverlayMetrics.handleSize, 16, accuracy: 0.001)
        XCTAssertEqual(pdfView.freeTextOverlayMetrics.handleHitSize, 36, accuracy: 0.001)

        XCTAssertTrue(light.handleColor.isEqual(NSColor(hex: lightTheme.accent)))
        XCTAssertTrue(light.handleRingColor.isEqual(NSColor(hex: lightTheme.selectionForeground)))
        XCTAssertTrue(dark.handleColor.isEqual(NSColor(hex: darkTheme.accent)))
        XCTAssertTrue(dark.handleRingColor.isEqual(NSColor(hex: darkTheme.selectionForeground)))
        XCTAssertFalse(light.borderColor.isEqual(dark.borderColor))
        XCTAssertFalse(light.handleColor.isEqual(dark.handleColor))
        XCTAssertEqual(light.borderColor.alphaComponent, 0.82, accuracy: 0.001)
        XCTAssertEqual(dark.borderColor.alphaComponent, 0.82, accuracy: 0.001)
    }

    func testAnnotationStyleDisclosureMatchesActiveTool() {
        XCTAssertEqual(
            PDFAnnotationStyleDisclosure(mode: .select, hasSelectedText: false),
            .markupColor
        )
        XCTAssertEqual(
            PDFAnnotationStyleDisclosure(mode: .pen, hasSelectedText: false),
            .drawing
        )
        XCTAssertEqual(
            PDFAnnotationStyleDisclosure(mode: .select, hasSelectedText: true),
            .text
        )
        XCTAssertEqual(
            PDFAnnotationStyleDisclosure(mode: .pen, hasSelectedText: true),
            .drawing
        )
        XCTAssertEqual(
            PDFAnnotationStyleDisclosure(mode: .eraser, hasSelectedText: true),
            .none
        )
    }

    func testFreeTextPopoverMetricsKeepCompactRowInvariantAcrossWorkspaceZoom() {
        for zoom in WorkspaceZoomPolicy.supportedLevels {
            let metrics = PDFFreeTextPopoverMetrics(
                theme: .defaultLight,
                zoomScale: zoom
            )
            XCTAssertEqual(
                metrics.fontMenuWidth + metrics.itemSpacing + metrics.colorWellDimension,
                metrics.contentWidth,
                accuracy: 0.01,
                "zoom \(zoom)"
            )
            XCTAssertEqual(
                metrics.width,
                MonknotMetrics.interfaceDensity(
                    PDFFreeTextPopoverMetrics.baseWidth,
                    theme: .defaultLight,
                    zoomScale: zoom
                )
            )
            XCTAssertEqual(
                metrics.controlHeight,
                MonknotMetrics.interfaceControl(28, theme: .defaultLight, zoomScale: zoom)
            )
        }
    }

    func testFreeTextFontFamilyOptionsAreCachedReadySortedAndIncludeImportedCurrentFamily() {
        XCTAssertEqual(
            pdfFreeTextFontFamilyOptions(
                currentFamily: "Embedded Sans",
                availableFamilies: ["Helvetica", "Arial", "helvetica", ""]
            ),
            ["Arial", "Embedded Sans", "Helvetica"]
        )
    }

    func testPDFUndoMenuRoutingPreservesNativeEditorUndo() {
        XCTAssertEqual(
            monknotUndoCommandDestination(
                isPDFDocumentActive: true,
                hasNativeEditingFocus: false,
                canPerformNative: false,
                canPerformPDF: true
            ),
            .pdf
        )
        XCTAssertEqual(
            monknotUndoCommandDestination(
                isPDFDocumentActive: true,
                hasNativeEditingFocus: true,
                canPerformNative: true,
                canPerformPDF: true
            ),
            .native
        )
        XCTAssertEqual(
            monknotUndoCommandDestination(
                isPDFDocumentActive: true,
                hasNativeEditingFocus: true,
                canPerformNative: false,
                canPerformPDF: true
            ),
            .unavailable
        )
        XCTAssertEqual(
            monknotUndoCommandDestination(
                isPDFDocumentActive: false,
                hasNativeEditingFocus: false,
                canPerformNative: true,
                canPerformPDF: false
            ),
            .native
        )
    }

    func testUndoMenuRoutingMatchesWorkspaceReplaceShortcutPriority() {
        XCTAssertEqual(
            monknotUndoCommandDestination(
                isPDFDocumentActive: true,
                hasNativeEditingFocus: false,
                canPerformNative: false,
                canPerformWorkspaceReplace: true,
                canPerformPDF: true
            ),
            .workspaceReplace
        )
        XCTAssertEqual(
            monknotUndoCommandDestination(
                isPDFDocumentActive: true,
                hasNativeEditingFocus: true,
                canPerformNative: true,
                canPerformWorkspaceReplace: true,
                canPerformPDF: true
            ),
            .native
        )
        XCTAssertEqual(
            monknotUndoCommandDestination(
                isPDFDocumentActive: true,
                hasNativeEditingFocus: true,
                canPerformNative: false,
                canPerformWorkspaceReplace: true,
                canPerformPDF: true
            ),
            .unavailable
        )
    }

    func testUnderlineQuadrilateralUsesLocalCoordinatesAndSurvivesPDFRoundTrip() throws {
        let bounds = CGRect(x: 40, y: 180, width: 200, height: 40)
        let annotation = PDFAnnotation(bounds: bounds, forType: .underline, withProperties: nil)
        annotation.quadrilateralPoints = pdfTextMarkupQuadrilateralPoints(for: bounds.size)

        XCTAssertEqual(
            annotation.quadrilateralPoints?.map(\.pointValue),
            [
                NSPoint(x: 0, y: 40),
                NSPoint(x: 200, y: 40),
                .zero,
                NSPoint(x: 200, y: 0)
            ]
        )

        let image = NSImage(size: NSSize(width: 280, height: 280))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        guard let page = PDFPage(image: image) else {
            return XCTFail("Expected PDF page")
        }
        page.addAnnotation(annotation)

        let document = PDFDocument()
        document.insert(page, at: 0)
        let data = try XCTUnwrap(document.dataRepresentation())
        let reloadedDocument = try XCTUnwrap(PDFDocument(data: data))
        let reloadedAnnotation = try XCTUnwrap(reloadedDocument.page(at: 0)?.annotations.first)

        XCTAssertEqual(reloadedAnnotation.markupType, .underline)
        XCTAssertEqual(reloadedAnnotation.quadrilateralPoints?.count, 4)
    }

    func testFreeTextAnnotationFormattingAndMultilineContentsSurvivePDFRoundTrip() throws {
        let formatting = PDFFreeTextFormatting(
            fontFamily: "Helvetica",
            fontSize: 19,
            fontColor: .systemRed,
            isBold: true,
            isItalic: true,
            alignment: .right
        )
        let bounds = CGRect(x: 36, y: 72, width: 220, height: 88)
        let annotation = makePDFFreeTextAnnotation(
            bounds: bounds,
            contents: "First line\nSecond line",
            formatting: formatting
        )
        let page = try makePage(size: NSSize(width: 320, height: 420))
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)

        let data = try XCTUnwrap(document.dataRepresentation())
        let reloaded = try XCTUnwrap(PDFDocument(data: data))
        let reloadedAnnotation = try XCTUnwrap(reloaded.page(at: 0)?.annotations.first)
        let reloadedFormatting = PDFFreeTextFormatting(annotation: reloadedAnnotation)

        XCTAssertEqual(
            (reloadedAnnotation.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            "FreeText"
        )
        XCTAssertEqual(reloadedAnnotation.contents, "First line\nSecond line")
        XCTAssertEqual(reloadedAnnotation.bounds, bounds)
        XCTAssertEqual(reloadedFormatting.fontSize, 19, accuracy: 0.01)
        XCTAssertTrue(reloadedFormatting.isBold)
        XCTAssertTrue(reloadedFormatting.isItalic)
        XCTAssertEqual(reloadedFormatting.alignment, .right)
        XCTAssertEqual(PDFNavigatorView.annotationItems(from: reloaded).map(\.kind), ["Text"])
    }

    func testImportedCondensedFontSurvivesColorAlignmentAndSizeOnlyFormatting() throws {
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 20, y: 30, width: 180, height: 64),
            contents: "Imported font"
        )
        let importedFont = try XCTUnwrap(NSFont(name: "HelveticaNeue-CondensedBold", size: 4))
        annotation.font = importedFont

        let changedColor = NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.71, alpha: 1)
        var colorAndAlignment = PDFFreeTextFormatting(annotation: annotation)
        colorAndAlignment.fontColor = changedColor
        colorAndAlignment.alignment = .right
        colorAndAlignment.apply(to: annotation)

        var currentFont = try XCTUnwrap(annotation.font)
        XCTAssertEqual(currentFont.fontName, importedFont.fontName)
        XCTAssertEqual(currentFont.pointSize, 4, accuracy: 0.01)
        XCTAssertTrue(try XCTUnwrap(annotation.fontColor).isEqual(changedColor))
        XCTAssertEqual(annotation.alignment, .right)

        var sizeOnly = PDFFreeTextFormatting(annotation: annotation)
        sizeOnly.fontSize = 18
        sizeOnly.apply(to: annotation)

        currentFont = try XCTUnwrap(annotation.font)
        XCTAssertEqual(currentFont.fontName, importedFont.fontName)
        XCTAssertEqual(currentFont.pointSize, 18, accuracy: 0.01)
        XCTAssertTrue(try XCTUnwrap(annotation.fontColor).isEqual(changedColor))
        XCTAssertEqual(annotation.alignment, .right)
    }

    func testColorOnlyFormattingDoesNotNormalizeUnsupportedImportedAlignment() throws {
        let annotation = ImportedAlignmentPDFAnnotation(
            bounds: CGRect(x: 20, y: 30, width: 180, height: 64),
            forType: .freeText,
            withProperties: nil
        )
        annotation.font = try XCTUnwrap(NSFont(name: "HelveticaNeue-CondensedBold", size: 11))
        var formatting = PDFFreeTextFormatting(annotation: annotation)
        XCTAssertEqual(formatting.alignment, .justified)
        formatting.fontColor = .systemPurple

        formatting.apply(to: annotation)

        XCTAssertEqual(annotation.alignment, .justified)
        XCTAssertTrue(annotation.assignedAlignments.isEmpty)

        var explicitLeft = formatting
        explicitLeft.alignment = .left
        explicitLeft.apply(to: annotation)
        XCTAssertEqual(annotation.assignedAlignments, [.left])
    }

    @MainActor
    func testActiveEditorUsesExactImportedFontAndAlignmentAtDisplayScale() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        page.rotation = 90
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 180, height: 64),
            contents: "Exact editor font"
        )
        let importedFont = try XCTUnwrap(NSFont(name: "HelveticaNeue-CondensedBold", size: 4))
        annotation.font = importedFont
        annotation.alignment = .right
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let baseline = try XCTUnwrap(document.dataRepresentation())
        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 720, height: 560))
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.75
        pdfView.document = document
        pdfView.layoutDocumentView()
        let geometry = try XCTUnwrap(pdfFreeTextEditorGeometry(
            for: annotation.bounds,
            on: page,
            in: pdfView
        ))

        pdfView.beginFreeTextEditing(
            annotation,
            on: page,
            isNew: false,
            baselineData: baseline
        )

        let editor = try activeEditor(in: pdfView)
        let editorFont = try XCTUnwrap(editor.font)
        XCTAssertEqual(editorFont.fontName, importedFont.fontName)
        XCTAssertEqual(editorFont.pointSize, 4 * geometry.effectiveScale, accuracy: 0.01)
        XCTAssertEqual(editor.alignment, .right)
    }

    func testMoveUndoSnapshotRestoresExactImportedFreeTextAppearance() throws {
        let originalBounds = CGRect(x: 20, y: 30, width: 180, height: 64)
        let annotation = makePDFFreeTextAnnotation(
            bounds: originalBounds,
            contents: "Move me"
        )
        let importedFont = try XCTUnwrap(NSFont(name: "HelveticaNeue-CondensedBold", size: 4))
        let importedColor = NSColor(calibratedRed: 0.61, green: 0.19, blue: 0.37, alpha: 0.83)
        annotation.font = importedFont
        annotation.fontColor = importedColor
        annotation.alignment = .right
        let exactPDFKitColor = try XCTUnwrap(annotation.fontColor)
        let exactPDFKitAlignment = annotation.alignment
        let beforeMove = PDFFreeTextAnnotationSnapshot(annotation: annotation)

        annotation.bounds = originalBounds.offsetBy(dx: 42, dy: 31)
        beforeMove.apply(to: annotation)

        let restoredFont = try XCTUnwrap(annotation.font)
        XCTAssertEqual(annotation.bounds, originalBounds)
        XCTAssertEqual(restoredFont.fontName, importedFont.fontName)
        XCTAssertEqual(restoredFont.pointSize, 4, accuracy: 0.01)
        XCTAssertTrue(try XCTUnwrap(annotation.fontColor).isEqual(exactPDFKitColor))
        XCTAssertEqual(annotation.alignment, exactPDFKitAlignment)
    }

    func testFreeTextBoundsClampToNonZeroCropBox() throws {
        let page = try makePage(size: NSSize(width: 420, height: 320))
        let cropBox = CGRect(x: 40, y: 55, width: 280, height: 180)
        page.setBounds(cropBox, for: .cropBox)
        page.rotation = 90
        let requested = CGRect(x: -100, y: 220, width: 420, height: 8)

        let clamped = clampedPDFFreeTextBounds(
            requested,
            to: page.bounds(for: .cropBox),
            minimumSize: CGSize(width: 36, height: 24)
        )

        XCTAssertGreaterThanOrEqual(clamped.minX, cropBox.minX)
        XCTAssertGreaterThanOrEqual(clamped.minY, cropBox.minY)
        XCTAssertLessThanOrEqual(clamped.maxX, cropBox.maxX)
        XCTAssertLessThanOrEqual(clamped.maxY, cropBox.maxY)
        XCTAssertGreaterThanOrEqual(clamped.width, 36)
        XCTAssertGreaterThanOrEqual(clamped.height, 24)
    }

    func testDefaultFreeTextBoundsCenterAtRequestedPointAndClampToPage() {
        let pageBounds = CGRect(x: 40, y: 55, width: 280, height: 180)

        let centeredBounds = defaultPDFFreeTextBounds(
            at: CGPoint(x: pageBounds.midX - 110, y: pageBounds.midY + 36),
            pageBounds: pageBounds
        )
        let clampedBounds = defaultPDFFreeTextBounds(
            at: CGPoint(x: 300, y: 80),
            pageBounds: pageBounds
        )

        XCTAssertEqual(centeredBounds.size, CGSize(width: 220, height: 72))
        XCTAssertEqual(centeredBounds.midX, pageBounds.midX, accuracy: 0.001)
        XCTAssertEqual(centeredBounds.midY, pageBounds.midY, accuracy: 0.001)
        XCTAssertTrue(pageBounds.contains(centeredBounds))
        XCTAssertTrue(pageBounds.contains(clampedBounds))
    }

    func testFreeTextMoveAndSideResizeScaleBoundsAndFontInsideOriginalPage() {
        let pageBounds = CGRect(x: 40, y: 55, width: 280, height: 180)
        let original = CGRect(x: 100, y: 100, width: 120, height: 60)
        let moved = clampedPDFFreeTextBounds(
            original.offsetBy(dx: 500, dy: -500),
            to: pageBounds,
            minimumSize: original.size
        )
        let trailingResize = resizedPDFFreeText(
            original,
            fontSize: 14,
            handle: .maxXMidY,
            to: CGPoint(x: 300, y: original.midY),
            pageBounds: pageBounds,
            minimumSize: CGSize(width: 36, height: 24)
        )
        let leadingResize = resizedPDFFreeText(
            original,
            fontSize: 14,
            handle: .minXMidY,
            to: CGPoint(x: 70, y: original.midY),
            pageBounds: pageBounds,
            minimumSize: CGSize(width: 36, height: 24)
        )

        XCTAssertEqual(moved.maxX, pageBounds.maxX)
        XCTAssertEqual(moved.minY, pageBounds.minY)
        XCTAssertTrue(pageBounds.contains(moved))

        XCTAssertEqual(trailingResize.bounds.minX, original.minX, accuracy: 0.001)
        XCTAssertEqual(trailingResize.bounds.midY, original.midY, accuracy: 0.001)
        XCTAssertEqual(trailingResize.bounds.width, 200, accuracy: 0.001)
        XCTAssertEqual(trailingResize.bounds.height, 100, accuracy: 0.001)
        XCTAssertEqual(trailingResize.fontSize, 23.333, accuracy: 0.001)
        XCTAssertTrue(pageBounds.contains(trailingResize.bounds))

        XCTAssertEqual(leadingResize.bounds.maxX, original.maxX, accuracy: 0.001)
        XCTAssertEqual(leadingResize.bounds.midY, original.midY, accuracy: 0.001)
        XCTAssertEqual(leadingResize.bounds.width, 150, accuracy: 0.001)
        XCTAssertEqual(leadingResize.bounds.height, 75, accuracy: 0.001)
        XCTAssertEqual(leadingResize.fontSize, 17.5, accuracy: 0.001)
        XCTAssertTrue(pageBounds.contains(leadingResize.bounds))
        XCTAssertEqual(PDFFreeTextResizeHandle.allCases.count, 2)
    }

    func testFreeTextSideResizeClampsMinimumMaximumAndPageEdges() {
        let pageBounds = CGRect(x: 40, y: 55, width: 280, height: 180)
        let original = CGRect(x: 100, y: 100, width: 120, height: 60)

        let minimum = resizedPDFFreeText(
            original,
            fontSize: 14,
            handle: .maxXMidY,
            to: CGPoint(x: 101, y: original.midY),
            pageBounds: pageBounds,
            minimumSize: CGSize(width: 36, height: 24)
        )
        XCTAssertEqual(minimum.bounds.minX, original.minX, accuracy: 0.001)
        XCTAssertEqual(minimum.bounds.midY, original.midY, accuracy: 0.001)
        XCTAssertEqual(minimum.bounds.width, 120 * 6 / 14, accuracy: 0.001)
        XCTAssertEqual(minimum.bounds.height, 60 * 6 / 14, accuracy: 0.001)
        XCTAssertEqual(minimum.fontSize, 6, accuracy: 0.001)

        let pageLimited = resizedPDFFreeText(
            original,
            fontSize: 14,
            handle: .maxXMidY,
            to: CGPoint(x: 1_000, y: original.midY),
            pageBounds: pageBounds,
            minimumSize: CGSize(width: 36, height: 24)
        )
        XCTAssertEqual(pageLimited.bounds.minX, original.minX, accuracy: 0.001)
        XCTAssertEqual(pageLimited.bounds.maxX, pageBounds.maxX, accuracy: 0.001)
        XCTAssertEqual(pageLimited.bounds.midY, original.midY, accuracy: 0.001)
        XCTAssertEqual(pageLimited.bounds.height, 110, accuracy: 0.001)
        XCTAssertEqual(pageLimited.fontSize, 25.667, accuracy: 0.001)
        XCTAssertTrue(pageBounds.contains(pageLimited.bounds))

        let fontLimited = resizedPDFFreeText(
            original,
            fontSize: 100,
            handle: .maxXMidY,
            to: CGPoint(x: 1_000, y: original.midY),
            pageBounds: pageBounds,
            minimumSize: CGSize(width: 36, height: 24)
        )
        XCTAssertEqual(fontLimited.bounds.width, 172.8, accuracy: 0.001)
        XCTAssertEqual(fontLimited.bounds.height, 86.4, accuracy: 0.001)
        XCTAssertEqual(fontLimited.fontSize, 144, accuracy: 0.001)
        XCTAssertTrue(pageBounds.contains(fontLimited.bounds))
    }

    func testFreeTextSideResizeUsesExactImportedFontSizeAsItsScaleBasis() {
        let original = CGRect(x: 100, y: 120, width: 100, height: 50)
        let result = resizedPDFFreeText(
            original,
            fontSize: 4,
            handle: .maxXMidY,
            to: CGPoint(x: 300, y: original.midY),
            pageBounds: CGRect(x: 0, y: 0, width: 500, height: 400),
            minimumSize: CGSize(width: 36, height: 24)
        )

        XCTAssertEqual(result.bounds.minX, original.minX, accuracy: 0.001)
        XCTAssertEqual(result.bounds.midY, original.midY, accuracy: 0.001)
        XCTAssertEqual(result.bounds.width, 200, accuracy: 0.001)
        XCTAssertEqual(result.bounds.height, 100, accuracy: 0.001)
        XCTAssertEqual(result.fontSize, 8, accuracy: 0.001)
    }

    @MainActor
    func testFreeTextFormatUpdateUsesValidatedLocalUndoAndRedo() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 180, height: 64),
            contents: "Undoable text"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let pdfView = AnnotatingPDFView()
        pdfView.document = document
        pdfView.replaceEditBaselineCapture(
            with: try XCTUnwrap(document.dataRepresentation()),
            needsSnapshot: true
        )
        var undoStates: [(Bool, Bool)] = []
        var editCount = 0
        pdfView.onUndoStateChanged = { undoStates.append(($0, $1)) }
        pdfView.onEdited = { _, _, _ in editCount += 1 }
        pdfView.selectFreeTextAnnotation(annotation, on: page)

        var formatting = PDFFreeTextFormatting(annotation: annotation)
        formatting.fontSize = 24
        formatting.isBold = true
        formatting.alignment = .center
        pdfView.applyFreeTextFormatting(formatting)

        XCTAssertEqual(try XCTUnwrap(annotation.font).pointSize, 24, accuracy: 0.01)
        XCTAssertEqual(annotation.alignment, .center)
        XCTAssertEqual(undoStates.last?.0, true)
        pdfView.undoAnnotationEdit()
        XCTAssertEqual(try XCTUnwrap(annotation.font).pointSize, 14, accuracy: 0.01)
        XCTAssertEqual(annotation.alignment, .left)
        pdfView.redoAnnotationEdit()
        XCTAssertEqual(try XCTUnwrap(annotation.font).pointSize, 24, accuracy: 0.01)
        XCTAssertEqual(annotation.alignment, .center)
        XCTAssertEqual(editCount, 3)

        let editCountBeforeNoOp = editCount
        pdfView.applyFreeTextFormatting(PDFFreeTextFormatting(annotation: annotation))
        XCTAssertEqual(editCount, editCountBeforeNoOp)
        pdfView.undoAnnotationEdit()
        XCTAssertEqual(try XCTUnwrap(annotation.font).pointSize, 14, accuracy: 0.01)
        XCTAssertEqual(annotation.alignment, .left)
    }

    @MainActor
    func testFreeTextFormattingPreservesActiveEditorSelectionAndDisplaySuppression() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 180, height: 64),
            contents: "Keep this caret"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let baseline = try XCTUnwrap(document.dataRepresentation())
        let pdfView = AnnotatingPDFView()
        pdfView.document = document
        pdfView.beginFreeTextEditing(
            annotation,
            on: page,
            isNew: false,
            baselineData: baseline
        )
        let editor = try activeEditor(in: pdfView)
        editor.setSelectedRange(NSRange(location: 5, length: 4))

        var formatting = PDFFreeTextFormatting(annotation: annotation)
        formatting.fontSize = 22
        formatting.isItalic = true
        pdfView.applyFreeTextFormatting(formatting)

        let resumedEditor = try activeEditor(in: pdfView)
        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)
        XCTAssertEqual(resumedEditor.selectedRange(), NSRange(location: 5, length: 4))
        XCTAssertEqual(try XCTUnwrap(annotation.font).pointSize, 22, accuracy: 0.01)
        XCTAssertTrue(PDFFreeTextFormatting(annotation: annotation).isItalic)
        XCTAssertFalse(annotation.shouldDisplay)

        XCTAssertTrue(pdfView.commitActiveFreeTextEdit())
        XCTAssertTrue(annotation.shouldDisplay)
    }

    @MainActor
    func testFreeTextFormattingNoOpKeepsSameEditorSelectionAndNativeUndoHistory() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 180, height: 64),
            contents: "Original"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let baseline = try XCTUnwrap(document.dataRepresentation())
        let pdfView = AnnotatingPDFView()
        pdfView.document = document
        var editCount = 0
        pdfView.onEdited = { _, _, _ in editCount += 1 }
        pdfView.beginFreeTextEditing(
            annotation,
            on: page,
            isNew: false,
            baselineData: baseline
        )
        let editor = try activeEditor(in: pdfView)
        let nativeUndoManager = UndoManager()
        nativeUndoManager.registerUndo(withTarget: editor) { textView in
            textView.string = "Original"
        }
        editor.string = "Draft"
        pdfView.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        editor.setSelectedRange(NSRange(location: 2, length: 3))

        pdfView.applyFreeTextFormatting(PDFFreeTextFormatting(annotation: annotation))

        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)
        XCTAssertTrue(try activeEditor(in: pdfView) === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 3))
        XCTAssertTrue(nativeUndoManager.canUndo)
        XCTAssertEqual(editCount, 1)
        XCTAssertFalse(annotation.shouldDisplay)
    }

    @MainActor
    func testSerializationFailureReloadsLastOwnedPDFAndClearsJustRegisteredUndo() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 180, height: 64),
            contents: "Owned text"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let baseline = try XCTUnwrap(document.dataRepresentation())
        let pdfView = AnnotatingPDFView()
        pdfView.document = document
        pdfView.replaceEditBaselineCapture(with: baseline, needsSnapshot: true)
        var editCount = 0
        var errors: [String] = []
        var undoStates: [(Bool, Bool)] = []
        pdfView.onEdited = { _, _, _ in editCount += 1 }
        pdfView.onError = { errors.append($0) }
        pdfView.onUndoStateChanged = { undoStates.append(($0, $1)) }
        pdfView.serializeDocument = { _ in nil }
        pdfView.selectFreeTextAnnotation(annotation, on: page)

        var formatting = PDFFreeTextFormatting(annotation: annotation)
        formatting.fontSize = 24
        pdfView.applyFreeTextFormatting(formatting)

        let restoredAnnotation = try XCTUnwrap(pdfView.document?.page(at: 0)?.annotations.first)
        XCTAssertEqual(try XCTUnwrap(restoredAnnotation.font).pointSize, 14, accuracy: 0.01)
        XCTAssertTrue(restoredAnnotation.shouldDisplay)
        XCTAssertEqual(editCount, 0)
        XCTAssertEqual(errors, ["PDFKit could not prepare the annotated document."])
        XCTAssertEqual(undoStates.last?.0, false)
        XCTAssertEqual(undoStates.last?.1, false)
        pdfView.undoAnnotationEdit()
        XCTAssertEqual(editCount, 0)
    }

    @MainActor
    func testLiveFreeTextSerializationFailureRestoresOriginalAndCannotRecommitDraft() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 180, height: 64),
            contents: "Original"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let baseline = try XCTUnwrap(document.dataRepresentation())
        let pdfView = AnnotatingPDFView()
        pdfView.document = document
        pdfView.replaceEditBaselineCapture(with: baseline, needsSnapshot: true)
        var editCount = 0
        var errors: [String] = []
        pdfView.onEdited = { _, _, _ in editCount += 1 }
        pdfView.onError = { errors.append($0) }
        pdfView.beginFreeTextEditing(
            annotation,
            on: page,
            isNew: false,
            baselineData: baseline
        )
        let editor = try activeEditor(in: pdfView)
        pdfView.serializeDocument = { _ in nil }

        editor.string = "Untracked draft"
        pdfView.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))

        XCTAssertFalse(pdfView.hasActiveFreeTextEditor)
        XCTAssertFalse(pdfView.commitActiveFreeTextEdit())
        let restoredAnnotation = try XCTUnwrap(pdfView.document?.page(at: 0)?.annotations.first)
        XCTAssertEqual(restoredAnnotation.contents, "Original")
        XCTAssertTrue(restoredAnnotation.shouldDisplay)
        XCTAssertEqual(editCount, 0)
        XCTAssertEqual(errors, ["PDFKit could not prepare the annotated document."])
    }

    @MainActor
    func testFreeTextColorWellCommitsOneColorChangeAsOneUndoOperation() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 180, height: 64),
            contents: "One color change"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let pdfView = AnnotatingPDFView()
        pdfView.document = document
        pdfView.replaceEditBaselineCapture(
            with: try XCTUnwrap(document.dataRepresentation()),
            needsSnapshot: true
        )
        pdfView.selectFreeTextAnnotation(annotation, on: page)

        var callbackCount = 0
        var editCount = 0
        var undoStates: [(Bool, Bool)] = []
        pdfView.onEdited = { _, _, _ in editCount += 1 }
        pdfView.onUndoStateChanged = { undoStates.append(($0, $1)) }

        let originalColor = try XCTUnwrap(annotation.fontColor)
        let committedColor = NSColor(calibratedRed: 0.12, green: 0.56, blue: 0.34, alpha: 1)
        let colorWell = PDFFreeTextCommittedColorWell(frame: .zero)
        colorWell.update(color: originalColor) { color in
            callbackCount += 1
            var formatting = PDFFreeTextFormatting(annotation: annotation)
            formatting.fontColor = color
            pdfView.applyFreeTextFormatting(formatting)
        }

        XCTAssertFalse(colorWell.isContinuous)
        colorWell.color = .systemRed
        colorWell.color = .systemBlue
        colorWell.color = committedColor
        XCTAssertEqual(callbackCount, 0)
        XCTAssertEqual(editCount, 0)
        XCTAssertTrue(undoStates.isEmpty)

        XCTAssertTrue(colorWell.sendAction(colorWell.action, to: colorWell.target))
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(editCount, 1)
        XCTAssertTrue(try XCTUnwrap(annotation.fontColor).isEqual(committedColor))
        XCTAssertEqual(undoStates.last?.0, true)

        pdfView.undoAnnotationEdit()
        XCTAssertTrue(try XCTUnwrap(annotation.fontColor).isEqual(originalColor))
        XCTAssertEqual(editCount, 2)
        XCTAssertEqual(undoStates.last?.0, false)
        XCTAssertEqual(undoStates.last?.1, true)

        colorWell.tearDown()
        XCTAssertNil(colorWell.target)
        XCTAssertNil(colorWell.action)
    }

    @MainActor
    func testNewEmptyFreeTextCancellationRestoresExactBaselineAndNextEditBaseline() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let document = PDFDocument()
        document.insert(page, at: 0)
        let originalData = try XCTUnwrap(document.dataRepresentation())
        let pdfView = AnnotatingPDFView()
        pdfView.document = document
        pdfView.replaceEditBaselineCapture(with: originalData, needsSnapshot: true)
        var edits: [(previous: Data?, data: Data)] = []
        pdfView.onEdited = { previousData, data, _ in edits.append((previousData, data)) }

        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 180, height: 64)
        )
        page.addAnnotation(annotation)
        pdfView.beginFreeTextEditing(
            annotation,
            on: page,
            isNew: true,
            baselineData: originalData,
            originalData: originalData
        )
        let editor = try activeEditor(in: pdfView)
        editor.string = "temporary"
        pdfView.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        editor.string = ""
        pdfView.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        pdfView.cancelActiveFreeTextEditing()

        XCTAssertTrue(page.annotations.isEmpty)
        XCTAssertEqual(edits.last?.data, originalData)

        let nextAnnotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 180, height: 64),
            contents: "Next"
        )
        page.addAnnotation(nextAnnotation)
        pdfView.selectFreeTextAnnotation(nextAnnotation, on: page)
        var nextFormatting = PDFFreeTextFormatting(annotation: nextAnnotation)
        nextFormatting.fontSize = 18
        pdfView.applyFreeTextFormatting(nextFormatting)
        XCTAssertNotNil(edits.last?.previous)
    }

    @MainActor
    func testMultilineFreeTextEditCommitsAsOneUndoOperation() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 180, height: 80),
            contents: "Original"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let pdfView = AnnotatingPDFView()
        pdfView.document = document
        let baseline = try XCTUnwrap(document.dataRepresentation())
        pdfView.beginFreeTextEditing(
            annotation,
            on: page,
            isNew: false,
            baselineData: baseline
        )
        let editor = try activeEditor(in: pdfView)
        XCTAssertFalse(annotation.shouldDisplay)
        editor.string = "First line\nSecond line"
        pdfView.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        pdfView.cancelActiveFreeTextEditing()

        XCTAssertEqual(annotation.contents, "First line\nSecond line")
        XCTAssertTrue(annotation.shouldDisplay)
        pdfView.undoAnnotationEdit()
        XCTAssertEqual(annotation.contents, "Original")
        pdfView.redoAnnotationEdit()
        XCTAssertEqual(annotation.contents, "First line\nSecond line")
    }

    @MainActor
    func testFreeTextDeleteUndoRedoAndStaleSelectionRejection() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 180, height: 64),
            contents: "Delete me"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let pdfView = AnnotatingPDFView()
        pdfView.document = document
        pdfView.replaceEditBaselineCapture(
            with: try XCTUnwrap(document.dataRepresentation()),
            needsSnapshot: true
        )
        pdfView.selectFreeTextAnnotation(annotation, on: page)
        pdfView.deleteSelectedFreeTextAnnotation()
        XCTAssertTrue(page.annotations.isEmpty)
        pdfView.undoAnnotationEdit()
        XCTAssertTrue(page.annotations.contains { $0 === annotation })
        pdfView.redoAnnotationEdit()
        XCTAssertTrue(page.annotations.isEmpty)

        pdfView.undoAnnotationEdit()
        pdfView.selectFreeTextAnnotation(annotation, on: page)
        page.removeAnnotation(annotation)
        var errors: [String] = []
        pdfView.onError = { errors.append($0) }
        var formatting = PDFFreeTextFormatting(annotation: annotation)
        formatting.fontSize = 22
        pdfView.applyFreeTextFormatting(formatting)
        XCTAssertFalse(errors.isEmpty)
        XCTAssertTrue(page.annotations.isEmpty)
    }

    @MainActor
    func testFreeTextPageConversionRoundTripsAcrossZoomRotationAndMixedPageSizes() throws {
        let first = try makePage(size: NSSize(width: 320, height: 420))
        first.rotation = 90
        first.setBounds(CGRect(x: 20, y: 30, width: 260, height: 340), for: .cropBox)
        let second = try makePage(size: NSSize(width: 500, height: 280))
        second.rotation = 270
        second.setBounds(CGRect(x: 35, y: 25, width: 410, height: 220), for: .cropBox)
        let document = PDFDocument()
        document.insert(first, at: 0)
        document.insert(second, at: 1)
        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 720, height: 560))
        pdfView.displayMode = .singlePageContinuous
        pdfView.document = document

        let pageRect = CGRect(x: 60, y: 80, width: 120, height: 54)
        for scale in [0.75, 1.8] as [CGFloat] {
            pdfView.scaleFactor = scale
            pdfView.layoutDocumentView()
            let viewRect = pdfView.convert(pageRect, from: first)
            let roundTrip = pdfView.convert(viewRect, to: first).standardized
            XCTAssertEqual(roundTrip.minX, pageRect.minX, accuracy: 0.01)
            XCTAssertEqual(roundTrip.minY, pageRect.minY, accuracy: 0.01)
            XCTAssertEqual(roundTrip.width, pageRect.width, accuracy: 0.01)
            XCTAssertEqual(roundTrip.height, pageRect.height, accuracy: 0.01)
        }
        XCTAssertNotEqual(first.bounds(for: .cropBox).size, second.bounds(for: .cropBox).size)
    }

    @MainActor
    func testFreeTextSelectionOverlayAndEditorShareConvertedBoundsAcrossZoomAndRotation() throws {
        let annotationBounds = CGRect(x: 60, y: 80, width: 120, height: 54)
        let rotations = [0, 90, 180, 270]
        let pageAnnotations = try rotations.map { rotation -> (PDFPage, PDFAnnotation) in
            let page = try makePage(size: NSSize(width: 320, height: 420))
            page.rotation = rotation
            page.setBounds(CGRect(x: 20, y: 30, width: 260, height: 340), for: .cropBox)
            let annotation = makePDFFreeTextAnnotation(
                bounds: annotationBounds,
                contents: "Aligned text"
            )
            page.addAnnotation(annotation)
            return (page, annotation)
        }
        let document = PDFDocument()
        for (index, item) in pageAnnotations.enumerated() {
            let page = item.0
            document.insert(page, at: index)
        }
        let baseline = try XCTUnwrap(document.dataRepresentation())
        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 720))
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.document = document

        for scale in [0.75, 1.25, 1.8] as [CGFloat] {
            pdfView.scaleFactor = scale
            pdfView.layoutDocumentView()
            for (index, item) in pageAnnotations.enumerated() {
                let (page, annotation) = item
                let expectedAxis: PDFFreeTextResizeCursorAxis = index.isMultiple(of: 2)
                    ? .horizontal
                    : .vertical
                XCTAssertEqual(
                    pdfFreeTextResizeCursorAxis(
                        for: annotationBounds,
                        on: page,
                        in: pdfView
                    ),
                    expectedAxis
                )

                pdfView.selectFreeTextAnnotation(annotation, on: page)
                let overlay = try XCTUnwrap(pdfView.freeTextSelectionOverlayGeometryInPDFView)
                let convertedBounds = pdfView.convert(annotationBounds, from: page).standardized
                XCTAssertEqual(overlay.boundingRect.minX, convertedBounds.minX, accuracy: 0.01)
                XCTAssertEqual(overlay.boundingRect.minY, convertedBounds.minY, accuracy: 0.01)
                XCTAssertEqual(overlay.boundingRect.width, convertedBounds.width, accuracy: 0.01)
                XCTAssertEqual(overlay.boundingRect.height, convertedBounds.height, accuracy: 0.01)

                pdfView.beginFreeTextEditing(
                    annotation,
                    on: page,
                    isNew: false,
                    baselineData: baseline
                )
                let editor = try activeEditor(in: pdfView)
                let editorScrollView = try XCTUnwrap(editor.enclosingScrollView)
                let editorBounds = editorScrollView.convert(
                    editorScrollView.bounds,
                    to: pdfView
                ).standardized
                XCTAssertEqual(editorBounds.midX, overlay.center.x, accuracy: 0.01)
                XCTAssertEqual(editorBounds.midY, overlay.center.y, accuracy: 0.01)
                XCTAssertTrue(convertedBounds.insetBy(dx: -0.01, dy: -0.01).contains(editorBounds))
                XCTAssertTrue(pdfView.commitActiveFreeTextEdit())
            }
        }

        let (scrollPage, scrollAnnotation) = pageAnnotations[0]
        pdfView.selectFreeTextAnnotation(scrollAnnotation, on: scrollPage)
        let scrollView = try XCTUnwrap(pdfView.documentView?.enclosingScrollView)
        let clipView = scrollView.contentView
        let documentView = try XCTUnwrap(pdfView.documentView)
        let maximumY = max(documentView.bounds.maxY - clipView.bounds.height, clipView.bounds.minY)
        let requestedY = min(clipView.bounds.minY + 80, maximumY)
        XCTAssertGreaterThan(requestedY, clipView.bounds.minY)
        clipView.scroll(to: CGPoint(x: clipView.bounds.minX, y: requestedY))
        scrollView.reflectScrolledClipView(clipView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clipView)

        let scrolledOverlay = try XCTUnwrap(pdfView.freeTextSelectionOverlayGeometryInPDFView)
        let scrolledBounds = pdfView.convert(annotationBounds, from: scrollPage).standardized
        XCTAssertEqual(scrolledOverlay.boundingRect.minX, scrolledBounds.minX, accuracy: 0.01)
        XCTAssertEqual(scrolledOverlay.boundingRect.minY, scrolledBounds.minY, accuracy: 0.01)
        XCTAssertEqual(scrolledOverlay.boundingRect.width, scrolledBounds.width, accuracy: 0.01)
        XCTAssertEqual(scrolledOverlay.boundingRect.height, scrolledBounds.height, accuracy: 0.01)
    }

    @MainActor
    func testFailedAddTextCommandDoesNotCreateTransientState() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let document = PDFDocument()
        document.insert(page, at: 0)
        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 720, height: 560))
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        pdfView.document = document
        pdfView.annotationMode = .pen
        pdfView.replaceEditBaselineCapture(with: nil, needsSnapshot: false)
        pdfView.serializeDocument = { _ in nil }
        pdfView.layoutDocumentView()
        var errors: [String] = []
        pdfView.onError = { errors.append($0) }

        let initialSubviewCount = pdfView.subviews.count
        pdfView.addFreeTextBox()

        XCTAssertEqual(pdfView.annotationMode, .select)
        XCTAssertEqual(pdfView.subviews.count, initialSubviewCount)
        XCTAssertTrue(page.annotations.isEmpty)
        XCTAssertEqual(
            errors.last,
            "PDFKit could not prepare the annotated document."
        )
    }

    @MainActor
    func testStaleMoveMouseUpRestoresOnlyUncommittedGestureFields() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let originalBounds = CGRect(x: 60, y: 100, width: 140, height: 54)
        let annotation = makePDFFreeTextAnnotation(
            bounds: originalBounds,
            contents: "Original"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let baseline = try XCTUnwrap(document.dataRepresentation())
        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 720, height: 560))
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        pdfView.document = document
        pdfView.annotationMode = .select
        pdfView.replaceEditBaselineCapture(with: baseline, needsSnapshot: true)
        pdfView.layoutDocumentView()
        pdfView.selectFreeTextAnnotation(annotation, on: page)
        var editCount = 0
        pdfView.onEdited = { _, _, _ in editCount += 1 }

        let start = pdfView.convert(
            CGPoint(x: originalBounds.midX, y: originalBounds.midY),
            from: page
        )
        let end = CGPoint(x: start.x + 38, y: start.y + 24)
        let down = try XCTUnwrap(freeTextMouseEvent(type: .leftMouseDown, location: start))
        let drag = try XCTUnwrap(freeTextMouseEvent(type: .leftMouseDragged, location: end))
        let up = try XCTUnwrap(freeTextMouseEvent(type: .leftMouseUp, location: end, pressure: 0))

        pdfView.mouseDown(with: down)
        pdfView.mouseDragged(with: drag)
        XCTAssertNotEqual(annotation.bounds.standardized, originalBounds)

        annotation.contents = "External change"
        pdfView.mouseUp(with: up)

        XCTAssertEqual(annotation.bounds.standardized, originalBounds)
        XCTAssertEqual(annotation.contents, "External change")
        XCTAssertEqual(editCount, 0)
        XCTAssertNil(pdfView.freeTextSelectionOverlayGeometryInPDFView)
    }

    @MainActor
    func testMoveUndoAndRedoRefreshSelectionOverlayImmediately() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let originalBounds = CGRect(x: 60, y: 100, width: 140, height: 54)
        let annotation = makePDFFreeTextAnnotation(
            bounds: originalBounds,
            contents: "Undo overlay"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let baseline = try XCTUnwrap(document.dataRepresentation())
        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 720, height: 560))
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        pdfView.document = document
        pdfView.annotationMode = .select
        pdfView.replaceEditBaselineCapture(with: baseline, needsSnapshot: true)
        pdfView.layoutDocumentView()
        pdfView.selectFreeTextAnnotation(annotation, on: page)

        let originalOverlay = try XCTUnwrap(pdfView.freeTextSelectionOverlayGeometryInPDFView)
        let start = pdfView.convert(
            CGPoint(x: originalBounds.midX, y: originalBounds.midY),
            from: page
        )
        let end = CGPoint(x: start.x + 40, y: start.y + 26)
        pdfView.mouseDown(with: try XCTUnwrap(freeTextMouseEvent(type: .leftMouseDown, location: start)))
        pdfView.mouseDragged(with: try XCTUnwrap(freeTextMouseEvent(type: .leftMouseDragged, location: end)))
        pdfView.mouseUp(with: try XCTUnwrap(freeTextMouseEvent(
            type: .leftMouseUp,
            location: end,
            pressure: 0
        )))

        let movedBounds = annotation.bounds.standardized
        let movedOverlay = try XCTUnwrap(pdfView.freeTextSelectionOverlayGeometryInPDFView)
        XCTAssertNotEqual(movedBounds, originalBounds)
        XCTAssertNotEqual(movedOverlay.boundingRect, originalOverlay.boundingRect)

        pdfView.undoAnnotationEdit()

        XCTAssertEqual(annotation.bounds.standardized, originalBounds)
        let undoneOverlay = try XCTUnwrap(pdfView.freeTextSelectionOverlayGeometryInPDFView)
        let originalConvertedBounds = pdfView.convert(originalBounds, from: page).standardized
        XCTAssertEqual(undoneOverlay.boundingRect.minX, originalConvertedBounds.minX, accuracy: 0.01)
        XCTAssertEqual(undoneOverlay.boundingRect.minY, originalConvertedBounds.minY, accuracy: 0.01)
        XCTAssertEqual(undoneOverlay.boundingRect.width, originalConvertedBounds.width, accuracy: 0.01)
        XCTAssertEqual(undoneOverlay.boundingRect.height, originalConvertedBounds.height, accuracy: 0.01)
        XCTAssertEqual(pdfView.freeTextSelectionOverlayShowsHandles, true)

        pdfView.redoAnnotationEdit()

        XCTAssertEqual(annotation.bounds.standardized, movedBounds)
        let redoneOverlay = try XCTUnwrap(pdfView.freeTextSelectionOverlayGeometryInPDFView)
        XCTAssertEqual(redoneOverlay.boundingRect.minX, movedOverlay.boundingRect.minX, accuracy: 0.01)
        XCTAssertEqual(redoneOverlay.boundingRect.minY, movedOverlay.boundingRect.minY, accuracy: 0.01)
        XCTAssertEqual(redoneOverlay.boundingRect.width, movedOverlay.boundingRect.width, accuracy: 0.01)
        XCTAssertEqual(redoneOverlay.boundingRect.height, movedOverlay.boundingRect.height, accuracy: 0.01)
        XCTAssertEqual(pdfView.freeTextSelectionOverlayShowsHandles, true)
    }

    @MainActor
    func testEscapeRollsBackUncommittedSelectMoveAndResize() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let originalBounds = CGRect(x: 60, y: 100, width: 140, height: 54)
        let annotation = makePDFFreeTextAnnotation(
            bounds: originalBounds,
            contents: "Cancel gesture"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let baseline = try XCTUnwrap(document.dataRepresentation())
        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 720, height: 560))
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        pdfView.document = document
        pdfView.annotationMode = .select
        pdfView.replaceEditBaselineCapture(with: baseline, needsSnapshot: true)
        pdfView.layoutDocumentView()
        pdfView.selectFreeTextAnnotation(annotation, on: page)
        var editCount = 0
        pdfView.onEdited = { _, _, _ in editCount += 1 }
        let originalFont = try XCTUnwrap(annotation.font)

        let moveStart = pdfView.convert(
            CGPoint(x: originalBounds.midX, y: originalBounds.midY),
            from: page
        )
        let moveEnd = CGPoint(x: moveStart.x + 42, y: moveStart.y + 24)
        pdfView.mouseDown(with: try XCTUnwrap(freeTextMouseEvent(type: .leftMouseDown, location: moveStart)))
        pdfView.mouseDragged(with: try XCTUnwrap(freeTextMouseEvent(type: .leftMouseDragged, location: moveEnd)))
        XCTAssertNotEqual(annotation.bounds.standardized, originalBounds)

        pdfView.keyDown(with: try XCTUnwrap(freeTextEscapeKeyEvent()))

        XCTAssertEqual(annotation.bounds.standardized, originalBounds)
        XCTAssertEqual(try XCTUnwrap(annotation.font), originalFont)
        XCTAssertNil(pdfView.freeTextSelectionOverlayGeometryInPDFView)
        XCTAssertEqual(editCount, 0)

        pdfView.selectFreeTextAnnotation(annotation, on: page)
        let overlay = try XCTUnwrap(pdfView.freeTextSelectionOverlayGeometryInPDFView)
        let resizeStart = overlay.maxXMidY
        let resizeEnd = CGPoint(x: resizeStart.x + 70, y: resizeStart.y)
        pdfView.mouseDown(with: try XCTUnwrap(freeTextMouseEvent(type: .leftMouseDown, location: resizeStart)))
        pdfView.mouseDragged(with: try XCTUnwrap(freeTextMouseEvent(type: .leftMouseDragged, location: resizeEnd)))
        XCTAssertNotEqual(annotation.bounds.standardized, originalBounds)
        XCTAssertNotEqual(try XCTUnwrap(annotation.font).pointSize, originalFont.pointSize)

        pdfView.keyDown(with: try XCTUnwrap(freeTextEscapeKeyEvent()))

        XCTAssertEqual(annotation.bounds.standardized, originalBounds)
        XCTAssertEqual(try XCTUnwrap(annotation.font), originalFont)
        XCTAssertNil(pdfView.freeTextSelectionOverlayGeometryInPDFView)
        XCTAssertEqual(editCount, 0)
    }

    @MainActor
    func testSelectModeMovesAndDoubleClickEditsExistingText() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 60, y: 100, width: 150, height: 58),
            contents: "Move or edit"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let baseline = try XCTUnwrap(document.dataRepresentation())
        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 720, height: 560))
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        pdfView.document = document
        pdfView.replaceEditBaselineCapture(with: baseline, needsSnapshot: true)
        pdfView.layoutDocumentView()

        let originalBounds = annotation.bounds.standardized
        let start = pdfView.convert(
            CGPoint(x: originalBounds.midX, y: originalBounds.midY),
            from: page
        )
        pdfView.mouseDown(with: try XCTUnwrap(freeTextMouseEvent(
            type: .leftMouseDown,
            location: start,
            clickCount: 2
        )))

        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)
        XCTAssertEqual(annotation.bounds.standardized, originalBounds)
        XCTAssertTrue(pdfView.commitActiveFreeTextEdit())

        let end = CGPoint(x: start.x + 38, y: start.y + 22)
        pdfView.mouseDown(with: try XCTUnwrap(freeTextMouseEvent(type: .leftMouseDown, location: start)))
        pdfView.mouseDragged(with: try XCTUnwrap(freeTextMouseEvent(type: .leftMouseDragged, location: end)))
        pdfView.mouseUp(with: try XCTUnwrap(freeTextMouseEvent(
            type: .leftMouseUp,
            location: end,
            pressure: 0
        )))

        let movedBounds = annotation.bounds.standardized
        XCTAssertNotEqual(movedBounds, originalBounds)
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertFalse(pdfView.hasActiveFreeTextEditor)
        XCTAssertEqual(pdfView.annotationMode, .select)
    }

    @MainActor
    func testAddTextCommandSerialIsOneShotAndReturnsPenAndEraserToSelect() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let document = PDFDocument()
        document.insert(page, at: 0)
        let baseline = try XCTUnwrap(document.dataRepresentation())
        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 720, height: 560))
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        pdfView.document = document
        pdfView.replaceEditBaselineCapture(with: baseline, needsSnapshot: true)
        pdfView.layoutDocumentView()
        let coordinator = PDFKitPreviewRepresentable.Coordinator()

        pdfView.annotationMode = .pen
        coordinator.applyAddFreeTextCommand(1, in: pdfView)

        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertEqual(pdfView.annotationMode, .select)
        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)
        let firstEditor = try activeEditor(in: pdfView)

        coordinator.applyAddFreeTextCommand(1, in: pdfView)

        XCTAssertEqual(page.annotations.count, 1, "Reapplying one command serial must not add another box")
        XCTAssertTrue(try activeEditor(in: pdfView) === firstEditor)
        firstEditor.string = "First box"
        pdfView.textDidChange(Notification(name: NSText.didChangeNotification, object: firstEditor))
        XCTAssertTrue(pdfView.commitActiveFreeTextEdit())

        pdfView.annotationMode = .eraser
        coordinator.applyAddFreeTextCommand(2, in: pdfView)

        XCTAssertEqual(pdfView.annotationMode, .select)
        XCTAssertEqual(page.annotations.count, 2)
        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)
        let secondEditor = try activeEditor(in: pdfView)
        coordinator.applyAddFreeTextCommand(2, in: pdfView)
        XCTAssertEqual(page.annotations.count, 2)
        XCTAssertTrue(try activeEditor(in: pdfView) === secondEditor)

        pdfView.cancelFreeTextEditingBeforeDocumentReplacement()
        XCTAssertEqual(page.annotations.count, 1, "Cancelling the empty second box must preserve the committed first box")
    }

    @MainActor
    func testSeededAddTextCommandSerialDoesNotReplayOnMountOrDocumentSwitch() throws {
        let firstPage = try makePage(size: NSSize(width: 320, height: 420))
        let firstDocument = PDFDocument()
        firstDocument.insert(firstPage, at: 0)
        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 720, height: 560))
        pdfView.document = firstDocument
        pdfView.replaceEditBaselineCapture(
            with: try XCTUnwrap(firstDocument.dataRepresentation()),
            needsSnapshot: true
        )
        pdfView.layoutDocumentView()
        let coordinator = PDFKitPreviewRepresentable.Coordinator()

        coordinator.acceptCurrentCommandSerials(
            undoSerial: 0,
            redoSerial: 0,
            zoomSerial: 0,
            addFreeTextSerial: 7
        )
        coordinator.applyAddFreeTextCommand(7, in: pdfView)
        XCTAssertTrue(firstPage.annotations.isEmpty, "Mounting with an existing serial must not replay Add Text Box")

        coordinator.applyAddFreeTextCommand(8, in: pdfView)
        XCTAssertEqual(firstPage.annotations.count, 1)
        let firstEditor = try activeEditor(in: pdfView)
        firstEditor.string = "First document"
        pdfView.textDidChange(Notification(name: NSText.didChangeNotification, object: firstEditor))
        XCTAssertTrue(pdfView.commitActiveFreeTextEdit())

        XCTAssertTrue(coordinator.prepareForDocument(
            "second.pdf",
            undoSerial: 0,
            redoSerial: 0,
            zoomSerial: 0,
            addFreeTextSerial: 19,
            in: pdfView
        ))
        let secondPage = try makePage(size: NSSize(width: 360, height: 480))
        let secondDocument = PDFDocument()
        secondDocument.insert(secondPage, at: 0)
        pdfView.document = secondDocument
        pdfView.replaceEditBaselineCapture(
            with: try XCTUnwrap(secondDocument.dataRepresentation()),
            needsSnapshot: true
        )
        pdfView.layoutDocumentView()

        coordinator.applyAddFreeTextCommand(19, in: pdfView)
        XCTAssertTrue(secondPage.annotations.isEmpty, "A serial seeded during document switch must not replay")

        coordinator.applyAddFreeTextCommand(20, in: pdfView)
        XCTAssertEqual(secondPage.annotations.count, 1)
        coordinator.applyAddFreeTextCommand(20, in: pdfView)
        XCTAssertEqual(secondPage.annotations.count, 1)
        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)
        pdfView.cancelFreeTextEditingBeforeDocumentReplacement()
    }

    @MainActor
    func testAddTextCommandCentersOneBoxOnTheCurrentVisibleRotatedPage() throws {
        let firstPage = try makePage(size: NSSize(width: 320, height: 420))
        let secondPage = try makePage(size: NSSize(width: 520, height: 360))
        secondPage.rotation = 90
        secondPage.setBounds(CGRect(x: 35, y: 25, width: 430, height: 290), for: .cropBox)
        let document = PDFDocument()
        document.insert(firstPage, at: 0)
        document.insert(secondPage, at: 1)
        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 720, height: 560))
        pdfView.displayMode = .singlePage
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        pdfView.document = document
        pdfView.replaceEditBaselineCapture(
            with: try XCTUnwrap(document.dataRepresentation()),
            needsSnapshot: true
        )
        pdfView.go(to: secondPage)
        pdfView.layoutDocumentView()

        let pageBounds = secondPage.bounds(for: pdfView.displayBox).standardized
        let convertedVisibleBounds = pdfView.convert(pdfView.visibleRect, to: secondPage).standardized
            .intersection(pageBounds)
        let insertionBounds = convertedVisibleBounds.isNull
                || convertedVisibleBounds.width <= 0
                || convertedVisibleBounds.height <= 0
            ? pageBounds
            : convertedVisibleBounds
        let expectedBounds = defaultPDFFreeTextBounds(
            at: CGPoint(x: insertionBounds.midX - 110, y: insertionBounds.midY + 36),
            pageBounds: pageBounds
        )

        pdfView.addFreeTextBox()

        XCTAssertTrue(firstPage.annotations.isEmpty)
        let annotation = try XCTUnwrap(secondPage.annotations.first)
        XCTAssertEqual(secondPage.annotations.count, 1)
        XCTAssertEqual(annotation.bounds.minX, expectedBounds.minX, accuracy: 0.01)
        XCTAssertEqual(annotation.bounds.minY, expectedBounds.minY, accuracy: 0.01)
        XCTAssertEqual(annotation.bounds.width, expectedBounds.width, accuracy: 0.01)
        XCTAssertEqual(annotation.bounds.height, expectedBounds.height, accuracy: 0.01)
        XCTAssertEqual(pdfView.annotationMode, .select)
        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)
        pdfView.cancelFreeTextEditingBeforeDocumentReplacement()
    }

    @MainActor
    func testFormattingNewEmptyTextBoxKeepsEditorAndTransientAnnotation() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let document = PDFDocument()
        document.insert(page, at: 0)
        let baseline = try XCTUnwrap(document.dataRepresentation())
        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 720, height: 560))
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        pdfView.document = document
        pdfView.replaceEditBaselineCapture(with: baseline, needsSnapshot: true)
        pdfView.layoutDocumentView()
        var editCount = 0
        var errors: [String] = []
        pdfView.onEdited = { _, _, _ in editCount += 1 }
        pdfView.onError = { errors.append($0) }

        pdfView.addFreeTextBox()

        let annotation = try XCTUnwrap(page.annotations.first)
        let editor = try activeEditor(in: pdfView)
        XCTAssertEqual(pdfView.annotationMode, .select)
        XCTAssertEqual(editor.string, "")
        var formatting = PDFFreeTextFormatting(annotation: annotation)
        formatting.fontSize = 24
        formatting.isBold = true
        let textColor = NSColor(calibratedRed: 0.48, green: 0.18, blue: 0.72, alpha: 1)
        formatting.fontColor = textColor
        formatting.alignment = .center

        pdfView.applyFreeTextFormatting(formatting)

        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)
        XCTAssertTrue(try activeEditor(in: pdfView) === editor)
        XCTAssertTrue(page.annotations.contains { $0 === annotation })
        XCTAssertEqual(try XCTUnwrap(annotation.font).pointSize, 24, accuracy: 0.01)
        XCTAssertTrue(PDFFreeTextFormatting(annotation: annotation).isBold)
        XCTAssertTrue(try XCTUnwrap(annotation.fontColor).isEqual(textColor))
        XCTAssertEqual(annotation.alignment, .center)
        XCTAssertFalse(annotation.shouldDisplay)
        XCTAssertEqual(editCount, 0, "Styling an empty transient box must not dirty the PDF")
        XCTAssertTrue(errors.isEmpty)

        pdfView.cancelFreeTextEditingBeforeDocumentReplacement()
        XCTAssertTrue(page.annotations.isEmpty)
    }

    @MainActor
    func testAddTextCommandWithoutDocumentReturnsToSelectAndReportsError() {
        let pdfView = AnnotatingPDFView()
        pdfView.annotationMode = .pen
        var errors: [String] = []
        pdfView.onError = { errors.append($0) }

        pdfView.addFreeTextBox()

        XCTAssertEqual(pdfView.annotationMode, .select)
        XCTAssertFalse(pdfView.hasActiveFreeTextEditor)
        XCTAssertEqual(errors, ["No PDF document is loaded."])
    }

    @MainActor
    func testBackspaceAndForwardDeleteRemoveSelectedTextOnlyInSelectMode() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 60, y: 100, width: 150, height: 58),
            contents: "Delete in Select"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 720, height: 560))
        pdfView.document = document
        pdfView.replaceEditBaselineCapture(
            with: try XCTUnwrap(document.dataRepresentation()),
            needsSnapshot: true
        )
        pdfView.selectFreeTextAnnotation(annotation, on: page)
        let backspaceEvent = try XCTUnwrap(freeTextDeleteKeyEvent())

        pdfView.annotationMode = .select
        pdfView.keyDown(with: backspaceEvent)
        XCTAssertFalse(page.annotations.contains { $0 === annotation })

        pdfView.undoAnnotationEdit()
        XCTAssertTrue(page.annotations.contains { $0 === annotation })
        pdfView.selectFreeTextAnnotation(annotation, on: page)
        pdfView.keyDown(with: try XCTUnwrap(freeTextDeleteKeyEvent(keyCode: 117)))
        XCTAssertFalse(page.annotations.contains { $0 === annotation })
    }

    @MainActor
    func testReadOnlyFreeTextCanBeSelectedButMutationAndDeleteAreRejected() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let originalBounds = CGRect(x: 60, y: 100, width: 150, height: 58)
        let annotation = makePDFFreeTextAnnotation(
            bounds: originalBounds,
            contents: "Read only"
        )
        page.addAnnotation(annotation)
        let document = NoCommentingPDFDocument()
        document.insert(page, at: 0)
        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 720, height: 560))
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        pdfView.document = document
        pdfView.annotationMode = .select
        pdfView.layoutDocumentView()
        var errors: [String] = []
        pdfView.onError = { errors.append($0) }
        let center = pdfView.convert(
            CGPoint(x: originalBounds.midX, y: originalBounds.midY),
            from: page
        )

        pdfView.mouseDown(with: try XCTUnwrap(freeTextMouseEvent(
            type: .leftMouseDown,
            location: center
        )))

        XCTAssertNotNil(pdfView.freeTextSelectionOverlayGeometryInPDFView)
        XCTAssertEqual(pdfView.freeTextSelectionOverlayShowsHandles, false)
        XCTAssertTrue(errors.isEmpty, "Initial read-only selection must not report a mutation error")

        pdfView.mouseDown(with: try XCTUnwrap(freeTextMouseEvent(
            type: .leftMouseDown,
            location: center,
            clickCount: 2
        )))
        XCTAssertFalse(errors.isEmpty)
        XCTAssertFalse(pdfView.hasActiveFreeTextEditor)
        XCTAssertEqual(annotation.bounds.standardized, originalBounds)
        XCTAssertNotNil(pdfView.freeTextSelectionOverlayGeometryInPDFView)

        let errorsBeforeDelete = errors.count
        pdfView.keyDown(with: try XCTUnwrap(freeTextDeleteKeyEvent()))
        XCTAssertGreaterThan(errors.count, errorsBeforeDelete)
        XCTAssertTrue(page.annotations.contains { $0 === annotation })

        let errorsBeforeFormatting = errors.count
        var formatting = PDFFreeTextFormatting(annotation: annotation)
        formatting.fontSize += 2
        pdfView.applyFreeTextFormatting(formatting)
        XCTAssertGreaterThan(errors.count, errorsBeforeFormatting)
        XCTAssertEqual(try XCTUnwrap(annotation.font).pointSize, 14, accuracy: 0.01)
        XCTAssertTrue(page.annotations.contains { $0 === annotation })

        let errorsBeforeAdd = errors.count
        pdfView.annotationMode = .eraser
        pdfView.addFreeTextBox()
        XCTAssertEqual(pdfView.annotationMode, .select)
        XCTAssertGreaterThan(errors.count, errorsBeforeAdd)
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertFalse(pdfView.hasActiveFreeTextEditor)
    }

    @MainActor
    func testFreeTextEditorTracksConvertedZoomAndRotationForMixedPages() throws {
        let first = try makePage(size: NSSize(width: 320, height: 420))
        first.rotation = 90
        first.setBounds(CGRect(x: 20, y: 30, width: 260, height: 340), for: .cropBox)
        let second = try makePage(size: NSSize(width: 500, height: 280))
        second.rotation = 270
        second.setBounds(CGRect(x: 35, y: 25, width: 410, height: 220), for: .cropBox)
        let firstBounds = CGRect(x: 60, y: 80, width: 120, height: 54)
        let secondBounds = CGRect(x: 120, y: 70, width: 190, height: 76)
        let firstAnnotation = makePDFFreeTextAnnotation(bounds: firstBounds, contents: "First")
        let secondAnnotation = makePDFFreeTextAnnotation(bounds: secondBounds, contents: "Second")
        first.addAnnotation(firstAnnotation)
        second.addAnnotation(secondAnnotation)

        let document = PDFDocument()
        document.insert(first, at: 0)
        document.insert(second, at: 1)
        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 720))
        pdfView.displayMode = .singlePageContinuous
        pdfView.document = document
        let baseline = try XCTUnwrap(document.dataRepresentation())

        for (page, annotation, bounds, expectedRotation) in [
            (first, firstAnnotation, firstBounds, CGFloat(-90)),
            (second, secondAnnotation, secondBounds, CGFloat(90))
        ] {
            for scale in [0.75, 1.8] as [CGFloat] {
                pdfView.scaleFactor = scale
                pdfView.layoutDocumentView()
                let geometry = try XCTUnwrap(pdfFreeTextEditorGeometry(
                    for: bounds,
                    on: page,
                    in: pdfView
                ))

                XCTAssertEqual(geometry.center.x, pdfView.convert(
                    CGPoint(x: bounds.midX, y: bounds.midY),
                    from: page
                ).x, accuracy: 0.01)
                XCTAssertEqual(geometry.center.y, pdfView.convert(
                    CGPoint(x: bounds.midX, y: bounds.midY),
                    from: page
                ).y, accuracy: 0.01)
                XCTAssertEqual(geometry.effectiveScale, scale, accuracy: 0.01)
                XCTAssertEqual(geometry.unrotatedSize.width, bounds.width * scale, accuracy: 0.01)
                XCTAssertEqual(geometry.unrotatedSize.height, bounds.height * scale, accuracy: 0.01)
                XCTAssertEqual(geometry.rotationDegrees, expectedRotation, accuracy: 0.01)
                XCTAssertEqual(
                    geometry.localXAxis.dx * geometry.localYAxis.dx
                        + geometry.localXAxis.dy * geometry.localYAxis.dy,
                    0,
                    accuracy: 0.01
                )

                pdfView.beginFreeTextEditing(
                    annotation,
                    on: page,
                    isNew: false,
                    baselineData: baseline
                )
                let editor = try activeEditor(in: pdfView)
                let scrollView = try XCTUnwrap(editor.enclosingScrollView)
                XCTAssertFalse(scrollView.drawsBackground)
                XCTAssertEqual(scrollView.backgroundColor.alphaComponent, 0, accuracy: 0.001)
                XCTAssertFalse(editor.drawsBackground)
                XCTAssertEqual(editor.backgroundColor.alphaComponent, 0, accuracy: 0.001)
                XCTAssertEqual(editor.textContainer?.lineFragmentPadding, 0)
                XCTAssertFalse(annotation.shouldDisplay)
                let editorCenter = scrollView.convert(
                    CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY),
                    to: pdfView
                )
                XCTAssertEqual(editorCenter.x, geometry.center.x, accuracy: 0.01)
                XCTAssertEqual(editorCenter.y, geometry.center.y, accuracy: 0.01)
                XCTAssertEqual(scrollView.frameCenterRotation, expectedRotation, accuracy: 0.01)
                XCTAssertEqual(editor.bounds.width, max(geometry.unrotatedSize.width - 2, 1), accuracy: 0.01)
                XCTAssertEqual(editor.bounds.height, max(geometry.unrotatedSize.height - 2, 1), accuracy: 0.01)
                XCTAssertEqual(try XCTUnwrap(editor.font).pointSize, 14 * scale, accuracy: 0.01)
                XCTAssertEqual(editor.textContainerInset.width, 4 * scale, accuracy: 0.01)
                XCTAssertEqual(editor.textContainerInset.height, 3 * scale, accuracy: 0.01)
                XCTAssertTrue(pdfView.commitActiveFreeTextEdit())
                XCTAssertTrue(annotation.shouldDisplay)
            }
        }
    }

    @MainActor
    func testLiveFreeTextPublishesVisibleAnnotationWhileKeepingMountedEditorSingleRendered() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 180, height: 80),
            contents: "Original"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let baseline = try XCTUnwrap(document.dataRepresentation())
        let pdfView = AnnotatingPDFView()
        pdfView.document = document
        var publishedData: Data?
        pdfView.onEdited = { _, data, _ in publishedData = data }

        pdfView.beginFreeTextEditing(
            annotation,
            on: page,
            isNew: false,
            baselineData: baseline
        )
        let editor = try activeEditor(in: pdfView)
        XCTAssertFalse(annotation.shouldDisplay)

        editor.string = "Visible when reloaded"
        pdfView.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))

        XCTAssertFalse(annotation.shouldDisplay)
        let reloaded = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(publishedData)))
        let reloadedAnnotation = try XCTUnwrap(reloaded.page(at: 0)?.annotations.first)
        XCTAssertTrue(reloadedAnnotation.shouldDisplay)
        XCTAssertEqual(reloadedAnnotation.contents, "Visible when reloaded")

        XCTAssertTrue(pdfView.commitActiveFreeTextEdit())
        XCTAssertTrue(annotation.shouldDisplay)
    }

    @MainActor
    func testCommitBridgeFlushesLatestRapidFreeTextAsOneUndoEdit() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 180, height: 80),
            contents: "Original"
        )
        page.addAnnotation(annotation)
        for index in 0..<80 {
            let row = index / 10
            let column = index % 10
            let marker = PDFAnnotation(
                bounds: CGRect(x: 5 + column * 12, y: 180 + row * 8, width: 8, height: 4),
                forType: .highlight,
                withProperties: nil
            )
            marker.contents = "Marker \(index)"
            page.addAnnotation(marker)
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        let baseline = try XCTUnwrap(document.dataRepresentation())
        let pdfView = AnnotatingPDFView()
        pdfView.document = document
        var publishedData: [Data] = []
        var navigatorReloadCount = 0
        pdfView.onEdited = { _, data, _ in publishedData.append(data) }
        pdfView.onAnnotationsChanged = { navigatorReloadCount += 1 }
        pdfView.beginFreeTextEditing(
            annotation,
            on: page,
            isNew: false,
            baselineData: baseline
        )
        let editor = try activeEditor(in: pdfView)

        editor.string = "First draft"
        pdfView.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        editor.string = "Final text"
        pdfView.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertEqual(publishedData.count, 1)
        XCTAssertEqual(navigatorReloadCount, 0)

        let bridge = PDFViewportCaptureBridge()
        bridge.attach(documentID: "paper", to: pdfView)
        XCTAssertTrue(bridge.commitActiveFreeTextEdit(documentID: "paper"))
        XCTAssertFalse(pdfView.hasActiveFreeTextEditor)
        XCTAssertEqual(publishedData.count, 2)
        XCTAssertEqual(navigatorReloadCount, 1)
        let committedDocument = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(publishedData.last)))
        XCTAssertEqual(committedDocument.page(at: 0)?.annotations.first?.contents, "Final text")

        pdfView.undoAnnotationEdit()
        XCTAssertEqual(annotation.contents, "Original")
        XCTAssertEqual(publishedData.count, 3)
        pdfView.undoAnnotationEdit()
        XCTAssertEqual(annotation.contents, "Original")
        XCTAssertEqual(publishedData.count, 3)
    }

    @MainActor
    func testNativeFreeTextUndoToCleanRestoresExactBytesAndRearmsLivePublishing() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 180, height: 80),
            contents: "Original"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let baseline = try XCTUnwrap(document.dataRepresentation())
        let pdfView = AnnotatingPDFView()
        pdfView.document = document
        var edits: [(previous: Data?, data: Data)] = []
        pdfView.onEdited = { previous, data, _ in
            edits.append((previous, data))
        }
        pdfView.beginFreeTextEditing(
            annotation,
            on: page,
            isNew: false,
            baselineData: baseline
        )
        let editor = try activeEditor(in: pdfView)
        let nativeUndoManager = UndoManager()
        nativeUndoManager.registerUndo(withTarget: editor) { textView in
            textView.string = "Original"
            pdfView.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }

        editor.string = "First draft"
        pdfView.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0].previous, baseline)

        nativeUndoManager.undo()
        XCTAssertEqual(edits.count, 2)
        XCTAssertNil(edits[1].previous)
        XCTAssertEqual(edits[1].data, baseline)
        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)
        XCTAssertTrue(try activeEditor(in: pdfView) === editor)
        XCTAssertFalse(annotation.shouldDisplay)

        editor.string = "Second draft"
        pdfView.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertEqual(edits.count, 3)
        XCTAssertEqual(edits[2].previous, baseline)
        let republished = try XCTUnwrap(PDFDocument(data: edits[2].data))
        XCTAssertEqual(republished.page(at: 0)?.annotations.first?.contents, "Second draft")
        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)
        XCTAssertTrue(try activeEditor(in: pdfView) === editor)
    }

    @MainActor
    func testNativeFreeTextUndoLeavesPDFAnnotationUndoUntouched() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 180, height: 80),
            contents: "Original"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let pdfView = AnnotatingPDFView()
        pdfView.document = document
        pdfView.replaceEditBaselineCapture(
            with: try XCTUnwrap(document.dataRepresentation()),
            needsSnapshot: true
        )
        pdfView.selectFreeTextAnnotation(annotation, on: page)
        var formatting = PDFFreeTextFormatting(annotation: annotation)
        formatting.fontSize = 20
        pdfView.applyFreeTextFormatting(formatting)

        pdfView.beginFreeTextEditing(
            annotation,
            on: page,
            isNew: false,
            baselineData: nil
        )
        let editor = try activeEditor(in: pdfView)
        let bridge = PDFViewportCaptureBridge()
        bridge.attach(documentID: "paper", to: pdfView)
        XCTAssertTrue(bridge.hasActiveFreeTextEditor(documentID: "paper"))

        let nativeUndoManager = UndoManager()
        nativeUndoManager.registerUndo(withTarget: editor) { textView in
            textView.string = "Original"
            pdfView.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }
        editor.string = "Draft"
        pdfView.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertEqual(editor.string, "Draft")
        XCTAssertTrue(nativeUndoManager.canUndo)

        // The toolbar/menu route must not consume an older PDF operation while
        // the native text editor owns undo focus.
        pdfView.undoAnnotationEdit()
        XCTAssertEqual(editor.string, "Draft")
        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)
        XCTAssertEqual(try XCTUnwrap(annotation.font).pointSize, 20, accuracy: 0.01)

        nativeUndoManager.undo()

        XCTAssertEqual(editor.string, "Original")
        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)
        XCTAssertEqual(try XCTUnwrap(annotation.font).pointSize, 20, accuracy: 0.01)
        XCTAssertTrue(pdfView.commitActiveFreeTextEdit())
        pdfView.undoAnnotationEdit()
        XCTAssertEqual(try XCTUnwrap(annotation.font).pointSize, 14, accuracy: 0.01)
    }

    @MainActor
    func testDocumentReplacementCancelsEditorAndRestoresOriginalDisplayState() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 180, height: 64),
            contents: "Original"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let pdfView = AnnotatingPDFView()
        pdfView.document = document
        pdfView.beginFreeTextEditing(
            annotation,
            on: page,
            isNew: false,
            baselineData: try XCTUnwrap(document.dataRepresentation())
        )
        let editor = try activeEditor(in: pdfView)
        editor.string = "Discarded replacement draft"
        XCTAssertFalse(annotation.shouldDisplay)

        pdfView.cancelFreeTextEditingBeforeDocumentReplacement()

        XCTAssertFalse(pdfView.hasActiveFreeTextEditor)
        XCTAssertEqual(annotation.contents, "Original")
        XCTAssertTrue(annotation.shouldDisplay)
    }

    @MainActor
    func testDoubleClickEditingUsesNativeTextHitTestingAtTheInitiatingPoint() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 220, height: 72),
            contents: "Alpha Beta Gamma"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let baseline = try XCTUnwrap(document.dataRepresentation())
        let pdfView = AnnotatingPDFView(frame: CGRect(x: 0, y: 0, width: 640, height: 560))
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.25
        pdfView.document = document
        pdfView.layoutDocumentView()
        pdfView.beginFreeTextEditing(
            annotation,
            on: page,
            isNew: false,
            baselineData: baseline
        )

        let firstEditor = try activeEditor(in: pdfView)
        let textContainer = try XCTUnwrap(firstEditor.textContainer)
        let layoutManager = try XCTUnwrap(firstEditor.layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        let betaCharacterRange = NSRange(location: 6, length: 1)
        let betaGlyphRange = layoutManager.glyphRange(
            forCharacterRange: betaCharacterRange,
            actualCharacterRange: nil
        )
        var betaRect = layoutManager.boundingRect(
            forGlyphRange: betaGlyphRange,
            in: textContainer
        )
        betaRect.origin.x += firstEditor.textContainerOrigin.x
        betaRect.origin.y += firstEditor.textContainerOrigin.y
        let betaPointInPDFView = firstEditor.convert(
            CGPoint(x: betaRect.midX, y: betaRect.midY),
            to: pdfView
        )
        let betaPointOnPage = pdfView.convert(betaPointInPDFView, to: page)
        XCTAssertTrue(pdfView.commitActiveFreeTextEdit())

        pdfView.annotationMode = .select
        let clickPoint = pdfView.convert(betaPointOnPage, from: page)
        pdfView.mouseDown(with: try XCTUnwrap(freeTextMouseEvent(
            type: .leftMouseDown,
            location: clickPoint,
            clickCount: 2
        )))
        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)
        let clickedEditor = try activeEditor(in: pdfView)
        let selectedRange = clickedEditor.selectedRange()
        XCTAssertGreaterThan(selectedRange.length, 0)
        XCTAssertEqual(
            (clickedEditor.string as NSString).substring(with: selectedRange),
            "Beta"
        )
    }

    @MainActor
    func testFreeTextEditorAndCallbacksTearDownBeforeDocumentRelease() throws {
        let page = try makePage(size: NSSize(width: 320, height: 420))
        let annotation = makePDFFreeTextAnnotation(
            bounds: CGRect(x: 30, y: 60, width: 180, height: 64),
            contents: "Edit me"
        )
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let pdfView = AnnotatingPDFView()
        pdfView.document = document
        pdfView.annotationMode = .select
        pdfView.selectFreeTextAnnotation(annotation, on: page)
        pdfView.beginFreeTextEditing(
            annotation,
            on: page,
            isNew: false,
            baselineData: try XCTUnwrap(document.dataRepresentation())
        )
        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)
        XCTAssertFalse(annotation.shouldDisplay)

        var callbackCount = 0
        pdfView.onFreeTextSelectionChanged = { _ in callbackCount += 1 }
        pdfView.prepareForDismantle()

        XCTAssertFalse(pdfView.hasActiveFreeTextEditor)
        XCTAssertNil(pdfView.freeTextSelectionOverlayGeometryInPDFView)
        XCTAssertNil(pdfView.document)
        XCTAssertTrue(annotation.shouldDisplay)
        let callbacksAfterTeardown = callbackCount
        pdfView.onFreeTextSelectionChanged(nil)
        XCTAssertEqual(callbackCount, callbacksAfterTeardown)
    }

    func testUnsupportedFreeTextAlignmentFallsBackWithoutShadowState() throws {
        let annotation = makePDFFreeTextAnnotation(bounds: CGRect(x: 0, y: 0, width: 120, height: 40))
        var formatting = PDFFreeTextFormatting(annotation: annotation)
        formatting.alignment = .justified

        formatting.apply(to: annotation)

        XCTAssertEqual(annotation.alignment, .left)
        XCTAssertEqual(PDFFreeTextFormatting(annotation: annotation).alignment, .left)
    }

    private func makePage(size: NSSize) throws -> PDFPage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return try XCTUnwrap(PDFPage(image: image))
    }

    @MainActor
    private func activeEditor(in pdfView: AnnotatingPDFView) throws -> NSTextView {
        let scrollView = try XCTUnwrap(pdfView.subviews.compactMap { $0 as? NSScrollView }.last)
        return try XCTUnwrap(scrollView.documentView as? NSTextView)
    }
}

private func freeTextMouseEvent(
    type: NSEvent.EventType,
    location: NSPoint,
    pressure: Float = 1,
    clickCount: Int = 1
) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        eventNumber: 1,
        clickCount: clickCount,
        pressure: pressure
    )
}

private func freeTextDeleteKeyEvent(keyCode: UInt16 = 51) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: "\u{7F}",
        charactersIgnoringModifiers: "\u{7F}",
        isARepeat: false,
        keyCode: keyCode
    )
}

private func freeTextEscapeKeyEvent() -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: "\u{1B}",
        charactersIgnoringModifiers: "\u{1B}",
        isARepeat: false,
        keyCode: 53
    )
}

private final class NoCommentingPDFDocument: PDFDocument {
    override var allowsCommenting: Bool { false }
}

private final class ImportedAlignmentPDFAnnotation: PDFAnnotation {
    var assignedAlignments: [NSTextAlignment] = []

    override var alignment: NSTextAlignment {
        get { .justified }
        set { assignedAlignments.append(newValue) }
    }
}
