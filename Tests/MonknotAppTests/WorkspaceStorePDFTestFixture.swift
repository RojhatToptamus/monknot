import AppKit
import PDFKit
import XCTest
@testable import MonknotApp

@MainActor
class WorkspaceStorePDFTestCase: WorkspaceStoreTestCase {

    func makePDFData(annotationText: String) throws -> Data {
        let image = NSImage(size: NSSize(width: 240, height: 240))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 240, height: 240).fill()
        image.unlockFocus()

        guard let page = PDFPage(image: image) else {
            throw NSError(domain: "WorkspaceStorePDFAnnotationExportTests", code: 1)
        }

        let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 120, width: 120, height: 18), forType: .highlight, withProperties: nil)
        annotation.contents = annotationText
        annotation.color = .yellow
        page.addAnnotation(annotation)

        let document = PDFDocument()
        document.insert(page, at: 0)

        guard let data = document.dataRepresentation() else {
            throw NSError(domain: "WorkspaceStorePDFAnnotationExportTests", code: 2)
        }
        return data
    }

    func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-pdf-annotation-export-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
