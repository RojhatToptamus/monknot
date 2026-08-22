import AppKit
import MonknotCore
import PDFKit
import XCTest
@testable import MonknotApp

final class PDFTextMarkupEditingLifecycleTests: PDFTextMarkupTestCase {
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
}
