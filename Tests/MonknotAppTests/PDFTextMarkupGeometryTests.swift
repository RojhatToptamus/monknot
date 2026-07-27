import AppKit
import PDFKit
import XCTest
@testable import MonknotApp

final class PDFTextMarkupGeometryTests: XCTestCase {
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
}
