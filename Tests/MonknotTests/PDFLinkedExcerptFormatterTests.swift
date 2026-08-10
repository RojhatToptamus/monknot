import CoreGraphics
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import MonknotCore

final class PDFLinkedExcerptFormatterTests: XCTestCase {
    func testFormatsMultilineSelectionWithRelativePageLink() throws {
        let selection = PDFSelectionSnapshot(
            documentID: "/workspace/reference/Paper.pdf",
            text: "First line\n\nSecond line",
            pageNumber: 12
        )

        let markdown = try PDFLinkedExcerptFormatter().markdown(
            for: selection,
            sourceRelativePath: "reference/Paper.pdf",
            destinationRelativePath: "notes/research/Findings.md"
        )

        XCTAssertEqual(
            markdown,
            """
            > First line
            >
            > Second line
            >
            > [Source: Paper.pdf, page 12](../../reference/Paper.pdf#page=12)
            """
        )
    }

    func testEncodesPathComponentsAndEscapesLinkLabel() throws {
        let selection = PDFSelectionSnapshot(
            documentID: "/workspace/papers/Guide [draft].pdf",
            text: "Quoted result",
            pageNumber: 2
        )

        let markdown = try PDFLinkedExcerptFormatter().markdown(
            for: selection,
            sourceRelativePath: "papers/Guide [draft] ü.pdf",
            destinationRelativePath: "notes/Review.md"
        )

        XCTAssertEqual(
            markdown,
            "> Quoted result\n>\n> [Source: Guide \\[draft\\] ü.pdf, page 2](../papers/Guide%20%5Bdraft%5D%20%C3%BC.pdf#page=2)"
        )
    }

    func testUsesFilenameWhenSourceAndDestinationShareDirectory() throws {
        let selection = PDFSelectionSnapshot(documentID: "source", text: "Quote", pageNumber: 1)

        let markdown = try PDFLinkedExcerptFormatter().markdown(
            for: selection,
            sourceRelativePath: "notes/Paper.pdf",
            destinationRelativePath: "notes/Excerpt.md"
        )

        XCTAssertTrue(markdown.hasSuffix("(Paper.pdf#page=1)"))
    }

    func testRejectsEmptySelectionInvalidPageAndEscapingWorkspacePath() {
        let formatter = PDFLinkedExcerptFormatter()

        XCTAssertThrowsError(
            try formatter.markdown(
                for: PDFSelectionSnapshot(documentID: "source", text: " \n ", pageNumber: 1),
                sourceRelativePath: "Paper.pdf",
                destinationRelativePath: "Note.md"
            )
        ) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptFormatterError, .emptySelection)
        }

        XCTAssertThrowsError(
            try formatter.markdown(
                for: PDFSelectionSnapshot(documentID: "source", text: "Quote", pageNumber: 0),
                sourceRelativePath: "Paper.pdf",
                destinationRelativePath: "Note.md"
            )
        ) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptFormatterError, .invalidPageNumber)
        }

        XCTAssertThrowsError(
            try formatter.markdown(
                for: PDFSelectionSnapshot(documentID: "source", text: "Quote", pageNumber: 1),
                sourceRelativePath: "../Paper.pdf",
                destinationRelativePath: "Note.md"
            )
        ) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptFormatterError, .invalidRelativePath)
        }
    }
}

final class PDFLinkedExcerptSourceValidatorTests: XCTestCase {
    private let validator = PDFLinkedExcerptSourceValidator()

    func testAcceptsNormalizedSelectionOnExactPage() throws {
        let data = try makeTextPDFData(pages: ["Introduction", "Selected phrase on page two"])
        let selection = PDFSelectionSnapshot(
            documentID: "/workspace/Paper.pdf",
            text: "Selected\n phrase",
            pageNumber: 2
        )

        XCTAssertNoThrow(try validator.validate(selection, in: data))
    }

    func testRejectsSelectionThatIsNoLongerPresent() throws {
        let data = try makeTextPDFData(pages: ["Current page contents"])
        let selection = PDFSelectionSnapshot(
            documentID: "/workspace/Paper.pdf",
            text: "Earlier page contents",
            pageNumber: 1
        )

        XCTAssertThrowsError(try validator.validate(selection, in: data)) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptSourceValidationError, .selectionChanged)
        }
    }

    func testRejectsSelectionFoundOnlyOnAnotherPage() throws {
        let data = try makeTextPDFData(pages: ["Exact quoted text", "Different second page"])
        let selection = PDFSelectionSnapshot(
            documentID: "/workspace/Paper.pdf",
            text: "Exact quoted text",
            pageNumber: 2
        )

        XCTAssertThrowsError(try validator.validate(selection, in: data)) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptSourceValidationError, .selectionChanged)
        }
    }

    func testRejectsUnavailablePage() throws {
        let data = try makeTextPDFData(pages: ["Only page"])
        let selection = PDFSelectionSnapshot(
            documentID: "/workspace/Paper.pdf",
            text: "Only page",
            pageNumber: 2
        )

        XCTAssertThrowsError(try validator.validate(selection, in: data)) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptSourceValidationError, .pageUnavailable)
        }
    }

    func testRejectsEmptyNormalizedSelection() throws {
        let data = try makeTextPDFData(pages: ["Page text"])
        let selection = PDFSelectionSnapshot(
            documentID: "/workspace/Paper.pdf",
            text: " \n\t ",
            pageNumber: 1
        )

        XCTAssertThrowsError(try validator.validate(selection, in: data)) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptSourceValidationError, .emptySelection)
        }
    }

    private func makeTextPDFData(pages: [String]) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 240)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        ]

        for text in pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 28, y: 180)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()

        return data as Data
    }
}
