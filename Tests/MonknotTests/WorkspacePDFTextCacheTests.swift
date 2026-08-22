import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import MonknotCore

final class WorkspacePDFTextCacheTests: WorkspaceSearchServiceTestCase {
    func testPDFSearchCacheEvictsLeastRecentlyUsedEntryWhenBounded() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPDF = root.appendingPathComponent("first.pdf")
        let secondPDF = root.appendingPathComponent("second.pdf")
        try writeSearchablePDF("First needle", to: firstPDF)
        try writeSearchablePDF("Second needle", to: secondPDF)

        let cache = WorkspacePDFTextCache(maxEntryCount: 1)
        let service = WorkspaceSearchService(pdfCache: cache)
        let firstDocument = WorkspaceDocument(url: firstPDF, rootURL: root)
        let secondDocument = WorkspaceDocument(url: secondPDF, rootURL: root)

        XCTAssertEqual(try service.search(query: "needle", documents: [firstDocument]).results.count, 1)
        XCTAssertTrue(cache.cachedPaths.contains(firstPDF.standardizedFileURL.path))

        XCTAssertEqual(try service.search(query: "needle", documents: [secondDocument]).results.count, 1)
        XCTAssertFalse(cache.cachedPaths.contains(firstPDF.standardizedFileURL.path))
        XCTAssertTrue(cache.cachedPaths.contains(secondPDF.standardizedFileURL.path))
        XCTAssertLessThanOrEqual(cache.cachedPaths.count, cache.maxEntryCount)
    }
}
