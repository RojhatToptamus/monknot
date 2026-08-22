import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import MonknotCore

final class WorkspaceSearchPrewarmServiceTests: WorkspaceSearchServiceTestCase {
    func testPrewarmServiceIndexesPDFDocumentsWithinLimit() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPDF = root.appendingPathComponent("first.pdf")
        let secondPDF = root.appendingPathComponent("second.pdf")
        try writeSearchablePDF("First prewarm needle", to: firstPDF)
        try writeSearchablePDF("Second prewarm needle", to: secondPDF)

        let documents = [
            WorkspaceDocument(url: firstPDF, rootURL: root),
            WorkspaceDocument(url: secondPDF, rootURL: root)
        ]
        let cache = WorkspacePDFTextCache()
        let index = WorkspacePDFSearchIndex(pdfCache: cache)
        let service = WorkspaceSearchPrewarmService(
            maxTextDocuments: 0,
            maxPDFDocuments: 1,
            textIndex: WorkspaceSearchIndex(textCache: WorkspaceTextContentCache()),
            pdfIndex: index
        )

        try service.prewarm(documents: documents)

        XCTAssertEqual(index.indexedDocumentIDs.count, 1)
        XCTAssertTrue(index.indexedDocumentIDs.contains(documents[0].id))
    }
}
