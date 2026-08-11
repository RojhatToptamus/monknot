import AppKit
import PDFKit
import XCTest
@testable import MonknotApp

final class PDFTextMarkupGeometryTests: XCTestCase {
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

    func testFreeTextBoundsClampToNonZeroCropBoxWithoutScalingFont() throws {
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

    func testFreeTextClickAndDragCreationBoundsUseProductionGeometry() {
        let pageBounds = CGRect(x: 40, y: 55, width: 280, height: 180)

        let clickBounds = defaultPDFFreeTextBounds(
            at: CGPoint(x: 300, y: 80),
            pageBounds: pageBounds
        )
        let dragBounds = draggedPDFFreeTextBounds(
            from: CGPoint(x: 260, y: 200),
            to: CGPoint(x: 90, y: 90),
            pageBounds: pageBounds
        )

        XCTAssertEqual(clickBounds.size, CGSize(width: 220, height: 72))
        XCTAssertTrue(pageBounds.contains(clickBounds))
        XCTAssertEqual(dragBounds, CGRect(x: 90, y: 90, width: 170, height: 110))
        XCTAssertTrue(pageBounds.contains(dragBounds))
    }

    func testFreeTextMoveAndResizeGeometryStayInsideOriginalPage() {
        let pageBounds = CGRect(x: 40, y: 55, width: 280, height: 180)
        let original = CGRect(x: 100, y: 100, width: 120, height: 60)
        let moved = clampedPDFFreeTextBounds(
            original.offsetBy(dx: 500, dy: -500),
            to: pageBounds,
            minimumSize: original.size
        )
        let resized = resizedPDFFreeTextBounds(
            original,
            handle: .minXMinY,
            to: CGPoint(x: 500, y: 500),
            pageBounds: pageBounds,
            minimumSize: CGSize(width: 36, height: 24)
        )

        XCTAssertEqual(moved.maxX, pageBounds.maxX)
        XCTAssertEqual(moved.minY, pageBounds.minY)
        XCTAssertTrue(pageBounds.contains(moved))
        XCTAssertGreaterThanOrEqual(resized.width, 36)
        XCTAssertGreaterThanOrEqual(resized.height, 24)
        XCTAssertTrue(pageBounds.contains(resized))
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
        XCTAssertEqual(pdfView.document?.page(at: 0)?.annotations.first?.contents, "Original")
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
        editor.string = "First line\nSecond line"
        pdfView.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        pdfView.cancelActiveFreeTextEditing()

        XCTAssertEqual(annotation.contents, "First line\nSecond line")
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
            }
        }
    }

    @MainActor
    func testCommitBridgeFlushesLatestRapidFreeTextAsOneUndoEdit() throws {
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
        var publishedData: [Data] = []
        pdfView.onEdited = { _, data, _ in publishedData.append(data) }
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

        let bridge = PDFViewportCaptureBridge()
        bridge.attach(documentID: "paper", to: pdfView)
        XCTAssertTrue(bridge.commitActiveFreeTextEdit(documentID: "paper"))
        XCTAssertFalse(pdfView.hasActiveFreeTextEditor)
        XCTAssertEqual(publishedData.count, 2)
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

        nativeUndoManager.undo()

        XCTAssertEqual(editor.string, "Original")
        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)
        XCTAssertEqual(try XCTUnwrap(annotation.font).pointSize, 20, accuracy: 0.01)
        XCTAssertTrue(pdfView.commitActiveFreeTextEdit())
        pdfView.undoAnnotationEdit()
        XCTAssertEqual(try XCTUnwrap(annotation.font).pointSize, 14, accuracy: 0.01)
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
        pdfView.selectFreeTextAnnotation(annotation, on: page)
        XCTAssertTrue(pdfView.beginEditingSelectedFreeTextIfDoubleClicked(
            at: CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY),
            on: page,
            clickCount: 2
        ))
        XCTAssertTrue(pdfView.hasActiveFreeTextEditor)

        var callbackCount = 0
        pdfView.onFreeTextSelectionChanged = { _ in callbackCount += 1 }
        pdfView.prepareForDismantle()

        XCTAssertFalse(pdfView.hasActiveFreeTextEditor)
        XCTAssertNil(pdfView.document)
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
