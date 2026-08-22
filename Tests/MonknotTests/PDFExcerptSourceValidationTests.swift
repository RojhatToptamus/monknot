import CoreGraphics
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import MonknotCore

final class PDFExcerptSourceValidationTests: PDFLinkedExcerptTestCase {
    func testAcceptsNormalizedSelectionOnExactPage() throws {
        let data = try makeTextPDFData(pages: ["Introduction", "Selected phrase on page two"])
        let exactSelection = try snapshot(
            matching: "Selected phrase",
            pageNumber: 2,
            in: data
        )
        let selection = PDFSelectionSnapshot(
            documentID: exactSelection.documentID,
            text: "Selected\n phrase",
            pageNumber: exactSelection.pageNumber,
            textRanges: exactSelection.textRanges
        )

        XCTAssertNoThrow(try validator.validate(selection, in: data))
    }

    func testRejectsSelectionThatIsNoLongerPresent() throws {
        let originalData = try makeTextPDFData(pages: ["Earlier page contents"])
        let selection = try snapshot(
            matching: "Earlier page contents",
            pageNumber: 1,
            in: originalData
        )
        let currentData = try makeTextPDFData(pages: ["Current page contents"])

        XCTAssertThrowsError(try validator.validate(selection, in: currentData)) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptSourceValidationError, .selectionChanged)
        }
    }

    func testRejectsSelectionFoundOnlyOnAnotherPage() throws {
        let originalData = try makeTextPDFData(pages: ["First page", "Exact quoted text"])
        let selection = try snapshot(
            matching: "Exact quoted text",
            pageNumber: 2,
            in: originalData
        )
        let currentData = try makeTextPDFData(pages: ["Exact quoted text", "Different second page"])

        XCTAssertThrowsError(try validator.validate(selection, in: currentData)) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptSourceValidationError, .selectionChanged)
        }
    }

    func testRejectsUnavailablePage() throws {
        let originalData = try makeTextPDFData(pages: ["First page", "Selected second page"])
        let selection = try snapshot(
            matching: "Selected second page",
            pageNumber: 2,
            in: originalData
        )
        let currentData = try makeTextPDFData(pages: ["Only page"])

        XCTAssertThrowsError(try validator.validate(selection, in: currentData)) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptSourceValidationError, .pageUnavailable)
        }
    }

    func testRejectsOriginalDuplicateOccurrenceWhenOnlyAnotherCopyRemains() throws {
        let originalData = try makeTextPDFData(
            pages: ["Repeated quote between Repeated quote"]
        )
        let selection = try snapshot(
            matching: "Repeated quote",
            occurrence: 2,
            pageNumber: 1,
            in: originalData
        )
        let currentData = try makeTextPDFData(
            pages: ["Repeated quote between Replacement text"]
        )

        XCTAssertThrowsError(try validator.validate(selection, in: currentData)) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptSourceValidationError, .selectionChanged)
        }
    }

    func testRejectsNonemptySelectionWithoutOccurrenceIdentity() throws {
        let data = try makeTextPDFData(pages: ["Selected text"])
        let selection = PDFSelectionSnapshot(
            documentID: "/workspace/Paper.pdf",
            text: "Selected text",
            pageNumber: 1
        )

        XCTAssertThrowsError(try validator.validate(selection, in: data)) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptSourceValidationError, .selectionChanged)
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
}
