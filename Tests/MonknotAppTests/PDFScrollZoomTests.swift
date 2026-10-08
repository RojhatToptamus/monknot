import AppKit
import PDFKit
import XCTest
@testable import MonknotApp

@MainActor
final class PDFScrollZoomTests: PDFNavigatorTestCase {
    func testOnlyCommandScrollZoomsAndTheWheelDirectionPicksInOrOut() throws {
        let away = try XCTUnwrap(scrollEvent(lines: 1, flags: .maskCommand))
        let toward = try XCTUnwrap(scrollEvent(lines: -1, flags: .maskCommand))

        XCTAssertGreaterThan(try XCTUnwrap(AnnotatingPDFView.commandScrollZoomFactor(for: away)), 1)
        XCTAssertLessThan(try XCTUnwrap(AnnotatingPDFView.commandScrollZoomFactor(for: toward)), 1)
        XCTAssertNil(AnnotatingPDFView.commandScrollZoomFactor(for: try XCTUnwrap(scrollEvent(lines: 1, flags: []))))
        XCTAssertNil(AnnotatingPDFView.commandScrollZoomFactor(
            for: try XCTUnwrap(scrollEvent(lines: 1, flags: [.maskCommand, .maskShift]))
        ))
        // ⌃-scroll stays with the system's accessibility zoom.
        XCTAssertNil(AnnotatingPDFView.commandScrollZoomFactor(for: try XCTUnwrap(scrollEvent(lines: 1, flags: .maskControl))))
    }

    func testZoomKeepsTheSpotUnderThePointerInPlace() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let pdfView = AnnotatingPDFView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(pdfView)
        pdfView.document = try makeImagePDFDocument(pageCount: 3, pageSize: NSSize(width: 400, height: 500))
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        pdfView.layoutDocumentView()

        let pointer = NSPoint(x: 230, y: 260)
        let page = try XCTUnwrap(pdfView.page(for: pointer, nearest: true))
        let pagePoint = pdfView.convert(pointer, to: page)

        pdfView.zoom(by: 1.5, keepingInPlace: pointer)

        XCTAssertEqual(pdfView.scaleFactor, 1.5, accuracy: 0.001)
        let pointNow = pdfView.convert(pagePoint, from: page)
        XCTAssertEqual(pointNow.x, pointer.x, accuracy: 1)
        XCTAssertEqual(pointNow.y, pointer.y, accuracy: 1)
        withExtendedLifetime(window) {}
    }

    private func scrollEvent(lines: Int32, flags: CGEventFlags) -> NSEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: lines,
            wheel2: 0,
            wheel3: 0
        ) else { return nil }
        event.flags = flags
        return NSEvent(cgEvent: event)
    }
}
