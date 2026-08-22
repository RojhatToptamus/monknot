import CoreGraphics
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import MonknotCore

class PDFLinkedExcerptTestCase: XCTestCase {
    let validator = PDFLinkedExcerptSourceValidator()

    func snapshot(
        matching text: String,
        occurrence: Int = 1,
        pageNumber: Int,
        in data: Data
    ) throws -> PDFSelectionSnapshot {
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: pageNumber - 1))
        let pageText = try XCTUnwrap(page.string) as NSString
        var searchRange = NSRange(location: 0, length: pageText.length)
        var matchedRange = NSRange(location: NSNotFound, length: 0)
        for _ in 0..<occurrence {
            matchedRange = pageText.range(of: text, options: [], range: searchRange)
            guard matchedRange.location != NSNotFound else {
                XCTFail("Expected occurrence \(occurrence) of selected PDF text")
                throw NSError(domain: "PDFLinkedExcerptSourceValidatorTests", code: 1)
            }
            let nextLocation = NSMaxRange(matchedRange)
            searchRange = NSRange(location: nextLocation, length: pageText.length - nextLocation)
        }

        let selection = try XCTUnwrap(page.selection(for: matchedRange))
        let rangeCount = selection.numberOfTextRanges(on: page)
        let textRanges = (0..<rangeCount).map { selection.range(at: $0, on: page) }
        return PDFSelectionSnapshot(
            documentID: "/workspace/Paper.pdf",
            text: try XCTUnwrap(selection.string),
            pageNumber: pageNumber,
            textRanges: textRanges
        )
    }

    func makeTextPDFData(pages: [String]) throws -> Data {
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
