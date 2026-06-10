import AppKit
import PDFKit
import XCTest
@testable import MonknotCore

final class PDFAnnotationMarkdownExportServiceTests: XCTestCase {
    func testExportMarkdownIncludesAnnotationTextAndMetadata() throws {
        let document = try makePDFDocument()
        guard let page = document.page(at: 0) else {
            return XCTFail("Expected PDF page")
        }

        let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 120, width: 90, height: 18), forType: .highlight, withProperties: nil)
        annotation.contents = "Important finding\nSecond line"
        annotation.userName = "Researcher"
        annotation.modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        annotation.color = NSColor(calibratedRed: 1, green: 0.85, blue: 0.1, alpha: 1)
        page.addAnnotation(annotation)

        guard let data = document.dataRepresentation() else {
            return XCTFail("Expected PDF data")
        }

        let markdown = try PDFAnnotationMarkdownExportService().exportMarkdown(
            from: data,
            documentName: "Guide.pdf",
            relativePath: "papers/Guide.pdf"
        )

        XCTAssertTrue(markdown.contains("# Guide.pdf Annotations"))
        XCTAssertTrue(markdown.contains("- Source: `papers/Guide.pdf`"))
        XCTAssertTrue(markdown.contains("## Page 1"))
        XCTAssertTrue(markdown.contains("- Highlight (color #FFD91A, by Researcher"))
        XCTAssertTrue(markdown.contains("> Important finding"))
        XCTAssertTrue(markdown.contains("> Second line"))
    }

    func testExportMarkdownFallsBackToPageTextWhenAnnotationContentsAreEmpty() throws {
        let document = try makeTextPDFDocument(text: "Quoted insight for export")
        guard let page = document.page(at: 0) else {
            return XCTFail("Expected PDF page")
        }

        let annotation = PDFAnnotation(bounds: CGRect(x: 18, y: 132, width: 170, height: 24), forType: .highlight, withProperties: nil)
        annotation.contents = nil
        annotation.quadrilateralPoints = [
            NSValue(point: NSPoint(x: 0, y: 22)),
            NSValue(point: NSPoint(x: 170, y: 22)),
            NSValue(point: NSPoint(x: 0, y: 0)),
            NSValue(point: NSPoint(x: 170, y: 0))
        ]
        page.addAnnotation(annotation)

        guard let data = document.dataRepresentation() else {
            return XCTFail("Expected PDF data")
        }

        let markdown = try PDFAnnotationMarkdownExportService().exportMarkdown(
            from: data,
            documentName: "Quoted.pdf",
            relativePath: "papers/Quoted.pdf"
        )

        XCTAssertTrue(markdown.contains("> Quoted insight for export"))
        XCTAssertFalse(markdown.contains("> No annotation text available."))
    }

    func testExportMarkdownReportsWhenNoAnnotationsExist() throws {
        let document = try makePDFDocument()

        let markdown = PDFAnnotationMarkdownExportService().exportMarkdown(
            from: document,
            documentName: "Empty.pdf",
            relativePath: "Empty.pdf"
        )

        XCTAssertTrue(markdown.contains("# Empty.pdf Annotations"))
        XCTAssertTrue(markdown.contains("No annotations found."))
    }

    func testBatchExportMarkdownIncludesSeparatePDFSections() throws {
        let firstDocument = try makePDFDocument(annotationText: "First highlight")
        let secondDocument = try makePDFDocument(annotationText: "Second highlight")

        guard let firstData = firstDocument.dataRepresentation(),
              let secondData = secondDocument.dataRepresentation() else {
            return XCTFail("Expected PDF data")
        }

        let markdown = try PDFAnnotationMarkdownExportService().exportMarkdown(
            from: [
                PDFAnnotationMarkdownExportItem(data: firstData, documentName: "First.pdf", relativePath: "papers/First.pdf"),
                PDFAnnotationMarkdownExportItem(data: secondData, documentName: "Second.pdf", relativePath: "papers/Second.pdf")
            ],
            title: "Workspace PDF Annotations"
        )

        XCTAssertTrue(markdown.contains("# Workspace PDF Annotations"))
        XCTAssertTrue(markdown.contains("- PDFs: 2"))
        XCTAssertTrue(markdown.contains("## First.pdf"))
        XCTAssertTrue(markdown.contains("- Source: `papers/First.pdf`"))
        XCTAssertTrue(markdown.contains("### Page 1"))
        XCTAssertTrue(markdown.contains("> First highlight"))
        XCTAssertTrue(markdown.contains("## Second.pdf"))
        XCTAssertTrue(markdown.contains("> Second highlight"))
    }

    private func makePDFDocument() throws -> PDFDocument {
        let image = NSImage(size: NSSize(width: 240, height: 240))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 240, height: 240).fill()
        image.unlockFocus()

        guard let page = PDFPage(image: image) else {
            throw NSError(domain: "PDFAnnotationMarkdownExportServiceTests", code: 1)
        }

        let document = PDFDocument()
        document.insert(page, at: 0)
        return document
    }

    private func makePDFDocument(annotationText: String) throws -> PDFDocument {
        let document = try makePDFDocument()
        guard let page = document.page(at: 0) else {
            throw NSError(domain: "PDFAnnotationMarkdownExportServiceTests", code: 4)
        }

        let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 120, width: 90, height: 18), forType: .highlight, withProperties: nil)
        annotation.contents = annotationText
        page.addAnnotation(annotation)
        return document
    }

    private func makeTextPDFDocument(text: String) throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 260, height: 220)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "PDFAnnotationMarkdownExportServiceTests", code: 2)
        }

        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(
            at: CGPoint(x: 20, y: 136),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.black
            ]
        )
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(data: data as Data) else {
            throw NSError(domain: "PDFAnnotationMarkdownExportServiceTests", code: 3)
        }
        return document
    }
}
