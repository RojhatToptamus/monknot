import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import MonknotCore

final class WorkspacePDFSearchIndexTests: WorkspaceSearchServiceTestCase {
    func testPDFSearchIndexEvictsLeastRecentlyUsedEntryWhenBounded() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPDF = root.appendingPathComponent("first.pdf")
        let secondPDF = root.appendingPathComponent("second.pdf")
        try writeSearchablePDF("First indexed needle", to: firstPDF)
        try writeSearchablePDF("Second indexed needle", to: secondPDF)

        let cache = WorkspacePDFTextCache()
        let index = WorkspacePDFSearchIndex(pdfCache: cache, maxEntryCount: 1)
        let service = WorkspaceSearchService(pdfCache: cache, pdfIndex: index)
        let firstDocument = WorkspaceDocument(url: firstPDF, rootURL: root)
        let secondDocument = WorkspaceDocument(url: secondPDF, rootURL: root)

        XCTAssertEqual(try service.search(query: "indexed", documents: [firstDocument]).results.count, 1)
        XCTAssertTrue(index.indexedDocumentIDs.contains(firstDocument.id))

        XCTAssertEqual(try service.search(query: "indexed", documents: [secondDocument]).results.count, 1)
        XCTAssertFalse(index.indexedDocumentIDs.contains(firstDocument.id))
        XCTAssertTrue(index.indexedDocumentIDs.contains(secondDocument.id))
        XCTAssertLessThanOrEqual(index.indexedDocumentIDs.count, index.maxEntryCount)
    }
}
