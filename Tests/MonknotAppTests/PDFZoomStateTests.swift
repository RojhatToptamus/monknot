import AppKit
import PDFKit
import XCTest
@testable import MonknotApp

@MainActor
final class PDFZoomStateTests: XCTestCase {
    func testViewportStateIgnoresSubpixelPositionAndScaleNoise() {
        let first = PDFDocumentViewportState(
            position: PDFDocumentViewportPosition(
                pageIndex: 2,
                point: DocumentScrollPosition(x: 24, y: 180)
            ),
            zoomMode: .fixed(scaleFactor: 1.5)
        )
        let nearlyIdentical = PDFDocumentViewportState(
            position: PDFDocumentViewportPosition(
                pageIndex: 2,
                point: DocumentScrollPosition(x: 24.2, y: 180.3)
            ),
            zoomMode: .fixed(scaleFactor: 1.501)
        )

        XCTAssertFalse(nearlyIdentical.isMeaningfullyDifferent(from: first))
        XCTAssertTrue(
            PDFDocumentViewportState(position: first.position, zoomMode: .fitToView)
                .isMeaningfullyDifferent(from: first)
        )
    }

    func testActualSizeUsesAnAbsoluteOneToOneScale() throws {
        let pdfView = try makePDFView()

        applyPDFZoomMode(.fixed(scaleFactor: 1.75), to: pdfView)
        applyPDFZoomCommand(.actualSize, to: pdfView)

        XCTAssertFalse(pdfView.autoScales)
        XCTAssertEqual(pdfView.scaleFactor, 1, accuracy: 0.001)
        XCTAssertEqual(PDFZoomStatus(pdfView: pdfView).displayLabel, "100%")
        XCTAssertTrue(PDFZoomStatus(pdfView: pdfView).isActualSize)
    }

    func testActualSizePreservesTheCurrentPDFDestination() throws {
        let pdfView = try makePDFView()
        let page = try XCTUnwrap(pdfView.document?.page(at: 0))
        pdfView.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        pdfView.layoutSubtreeIfNeeded()
        pdfView.layoutDocumentView()
        applyPDFZoomMode(.fixed(scaleFactor: 2), to: pdfView)
        pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: 150, y: 650)))
        let before = try XCTUnwrap(pdfView.currentDestination)

        applyPDFZoomCommand(.actualSize, to: pdfView)

        let after = try XCTUnwrap(pdfView.currentDestination)
        XCTAssertTrue(after.page === before.page)
        XCTAssertEqual(after.point.x, before.point.x, accuracy: 0.5)
        XCTAssertEqual(after.point.y, before.point.y, accuracy: 0.5)
    }

    func testFixedPDFZoomDoesNotFollowInterfaceOrViewSizeChanges() throws {
        let pdfView = try makePDFView()
        applyPDFZoomMode(.fixed(scaleFactor: 1.4), to: pdfView)

        pdfView.frame = CGRect(x: 0, y: 0, width: 420, height: 320)
        pdfView.layoutSubtreeIfNeeded()
        pdfView.layoutDocumentView()

        XCTAssertFalse(pdfView.autoScales)
        XCTAssertEqual(pdfView.scaleFactor, 1.4, accuracy: 0.001)
        guard case .fixed(let scaleFactor) = PDFDocumentViewportState(pdfView: pdfView)?.zoomMode else {
            return XCTFail("Expected the native PDF scale to be captured as a fixed zoom mode")
        }
        XCTAssertEqual(scaleFactor, 1.4, accuracy: 0.001)
    }

    func testFitToViewRemainsAResponsiveModeInsteadOfAStoredScale() throws {
        let pdfView = try makePDFView()
        applyPDFZoomMode(.fixed(scaleFactor: 1.4), to: pdfView)

        applyPDFZoomCommand(.fitToView, to: pdfView)

        XCTAssertTrue(pdfView.autoScales)
        XCTAssertEqual(PDFZoomStatus(pdfView: pdfView).displayLabel, "Fit")
        XCTAssertEqual(PDFDocumentViewportState(pdfView: pdfView)?.zoomMode, .fitToView)
    }

    func testFitZoomStatusDoesNotChangeWhenTheResponsiveScaleChanges() throws {
        let pdfView = try makePDFView()
        applyPDFZoomMode(.fitToView, to: pdfView)
        let before = PDFZoomStatus(pdfView: pdfView)

        pdfView.frame = CGRect(x: 0, y: 0, width: 420, height: 320)
        pdfView.layoutSubtreeIfNeeded()
        pdfView.layoutDocumentView()

        XCTAssertEqual(PDFZoomStatus(pdfView: pdfView), before)
    }

    func testInvalidFixedScaleFallsBackToFitToView() throws {
        let pdfView = try makePDFView()

        applyPDFZoomMode(.fixed(scaleFactor: .nan), to: pdfView)

        XCTAssertTrue(pdfView.autoScales)
        XCTAssertEqual(PDFDocumentViewportState(pdfView: pdfView)?.zoomMode, .fitToView)
    }

    private func makePDFView() throws -> PDFView {
        let image = NSImage(size: NSSize(width: 612, height: 792))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
        image.unlockFocus()

        let page = try XCTUnwrap(PDFPage(image: image))
        let document = PDFDocument()
        document.insert(page, at: 0)

        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = document
        pdfView.layoutDocumentView()
        return pdfView
    }
}
