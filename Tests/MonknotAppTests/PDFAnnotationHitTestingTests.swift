import PDFKit
import XCTest
@testable import MonknotApp

final class PDFAnnotationHitTestingTests: XCTestCase {
    func testEraserSelectsOnlyErasableDirectAndTolerantHits() {
        let page = PDFPage()
        let highlight = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 24, height: 8),
            forType: .highlight,
            withProperties: nil
        )
        let ink = PDFAnnotation(
            bounds: CGRect(x: 80, y: 30, width: 16, height: 16),
            forType: .ink,
            withProperties: nil
        )
        let link = PDFAnnotation(
            bounds: CGRect(x: 10, y: 60, width: 30, height: 12),
            forType: .link,
            withProperties: nil
        )
        [highlight, link, ink].forEach(page.addAnnotation)

        XCTAssertTrue(PDFAnnotationHitTesting.isErasable(highlight))
        XCTAssertTrue(PDFAnnotationHitTesting.isErasable(ink))
        XCTAssertFalse(PDFAnnotationHitTesting.isErasable(link))
        XCTAssertTrue(PDFAnnotationHitTesting.annotationForErasing(
            on: page,
            at: CGPoint(x: 82, y: 32),
            tolerance: 0
        ) === ink)
        XCTAssertTrue(PDFAnnotationHitTesting.annotationForErasing(
            on: page,
            at: CGPoint(x: 8, y: 14),
            tolerance: 3
        ) === highlight)
        XCTAssertNil(PDFAnnotationHitTesting.annotationForErasing(
            on: page,
            at: CGPoint(x: 16, y: 64),
            tolerance: 0
        ))
    }
}
