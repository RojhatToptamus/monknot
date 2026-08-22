import AppKit
import MonknotCore
import PDFKit
import XCTest
@testable import MonknotApp

final class PDFTextMarkupAppearanceTests: PDFTextMarkupTestCase {
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

    func testFreeTextFontFamilyOptionsAreCachedReadySortedAndIncludeImportedCurrentFamily() {
        XCTAssertEqual(
            pdfFreeTextFontFamilyOptions(
                currentFamily: "Embedded Sans",
                availableFamilies: ["Helvetica", "Arial", "helvetica", ""]
            ),
            ["Arial", "Embedded Sans", "Helvetica"]
        )
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

    func testUnsupportedFreeTextAlignmentFallsBackWithoutShadowState() throws {
        let annotation = makePDFFreeTextAnnotation(bounds: CGRect(x: 0, y: 0, width: 120, height: 40))
        var formatting = PDFFreeTextFormatting(annotation: annotation)
        formatting.alignment = .justified

        formatting.apply(to: annotation)

        XCTAssertEqual(annotation.alignment, .left)
        XCTAssertEqual(PDFFreeTextFormatting(annotation: annotation).alignment, .left)
    }
}
