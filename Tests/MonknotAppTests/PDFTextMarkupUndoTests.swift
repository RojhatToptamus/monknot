import AppKit
import MonknotCore
import PDFKit
import XCTest
@testable import MonknotApp

final class PDFTextMarkupUndoTests: PDFTextMarkupTestCase {
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
}
