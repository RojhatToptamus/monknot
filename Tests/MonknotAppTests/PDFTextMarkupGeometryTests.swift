import AppKit
import MonknotCore
import PDFKit
import XCTest
@testable import MonknotApp

final class PDFTextMarkupGeometryTests: PDFTextMarkupTestCase {
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
}
