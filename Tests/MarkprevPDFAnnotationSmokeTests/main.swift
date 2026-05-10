import AppKit
import Foundation
import PDFKit

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct MarkprevPDFAnnotationSmokeTests {
    static func main() {
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

        page.addAnnotation(highlight)
        page.addAnnotation(link)
        page.addAnnotation(ink)

        expect(PDFAnnotationHitTesting.isErasable(highlight), "highlight annotations should be erasable")
        expect(PDFAnnotationHitTesting.isErasable(ink), "ink annotations should be erasable")
        expect(!PDFAnnotationHitTesting.isErasable(link), "link annotations should not be erased")

        let directHit = PDFAnnotationHitTesting.annotationForErasing(
            on: page,
            at: CGPoint(x: 82, y: 32),
            tolerance: 0
        )
        expect(directHit === ink, "eraser should prefer topmost direct annotation hit")

        let tolerantHit = PDFAnnotationHitTesting.annotationForErasing(
            on: page,
            at: CGPoint(x: 8, y: 14),
            tolerance: 3
        )
        expect(tolerantHit === highlight, "eraser should tolerate near misses around thin markup annotations")

        let blockedHit = PDFAnnotationHitTesting.annotationForErasing(
            on: page,
            at: CGPoint(x: 16, y: 64),
            tolerance: 0
        )
        expect(blockedHit == nil, "eraser should ignore non-erasable annotations")

        print("Markprev PDF annotation smoke tests passed")
    }
}
