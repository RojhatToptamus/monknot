import AppKit
import PDFKit
import SwiftUI
import MonknotCore
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
        // Caps Lock is not a held modifier.
        XCTAssertNotNil(AnnotatingPDFView.commandScrollZoomFactor(
            for: try XCTUnwrap(scrollEvent(lines: 1, flags: [.maskCommand, .maskAlphaShift]))
        ))
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

    func testZoomInTheMountedPreviewStaysPutWhileItsViewportStateRoundTrips() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonknotPDFZoom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("zoom.pdf")
        XCTAssertTrue(try makeImagePDFDocument(pageCount: 3, pageSize: NSSize(width: 400, height: 500)).write(to: url))

        let host = NSHostingView(rootView: PDFZoomRoundTripHost(
            document: WorkspaceDocument(url: url, rootURL: root)
        ).frame(width: 900, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        var pdfView: AnnotatingPDFView?
        for _ in 0..<100 {
            pdfView = host.allDescendantsForTesting().compactMap { $0 as? AnnotatingPDFView }.first
            if pdfView?.document != nil { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let view = try XCTUnwrap(pdfView)
        XCTAssertNotNil(view.document)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let start = view.scaleFactor

        // ⌘-scroll.
        view.zoom(by: 2, keepingInPlace: NSPoint(x: view.bounds.midX, y: view.bounds.midY))
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(view.scaleFactor, start * 2, accuracy: 0.01, "A ⌘-scroll zoom must not snap back")

        // Back down and up again: every intermediate state echoes back late.
        view.zoom(by: 0.5, keepingInPlace: NSPoint(x: view.bounds.midX, y: view.bounds.midY))
        view.zoom(by: 3, keepingInPlace: NSPoint(x: view.bounds.midX, y: view.bounds.midY))
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(view.scaleFactor, start * 3, accuracy: 0.01, "Late echoes of earlier zooms must not win")

        // ⌘= on a focused PDF.
        let beforeKey = view.scaleFactor
        applyPDFZoomCommand(.zoomIn, to: view)
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertGreaterThan(view.scaleFactor, beforeKey + 0.01, "⌘= zoom must not snap back")
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

/// The PDF preview with its viewport state fed back the way the editor pane does.
private struct PDFZoomRoundTripHost: View {
    let document: WorkspaceDocument
    @State private var viewport: PDFDocumentViewportState?
    @State private var search = DocumentSearchState()
    @State private var target: WorkspaceSearchPDFTarget?
    @StateObject private var bridge = PDFViewportCaptureBridge()

    var body: some View {
        PDFPreviewView(
            document: document,
            theme: .defaultDark,
            zoomScale: 1,
            saveState: .clean,
            dirtyData: nil,
            savedEditCheckpoint: nil,
            contentVersion: 0,
            viewportState: viewport,
            viewportCaptureBridge: bridge,
            externalUndoCommandSerial: 0,
            externalRedoCommandSerial: 0,
            searchState: $search,
            searchTarget: $target,
            markEdited: { _, _, _ in },
            restoreSavedEditCheckpoint: { _ in true },
            reportError: { _ in },
            saveDocument: {},
            // Deferred: the final state arrives while the host itself is being torn down.
            onViewportStateChange: { state in DispatchQueue.main.async { viewport = state } },
            updateAnnotationUndoState: { _, _ in }
        )
    }
}
