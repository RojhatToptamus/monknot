import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import MonknotCore

final class WorkspacePDFSearchServiceTests: WorkspaceSearchServiceTestCase {
    func testSearchReturnsPageMatchesForPDFDocuments() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("guide.pdf")
        try writeSearchablePDF("PDF heading\nNeedle in a searchable PDF page", to: pdf)

        let documents = [WorkspaceDocument(url: pdf, rootURL: root)]
        let results = try WorkspaceSearchService().search(query: "needle", documents: documents).results

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].kind, .pdf)
        XCTAssertEqual(results[0].line, 1)
        XCTAssertEqual(results[0].locationLabel, "p1")
        XCTAssertTrue(results[0].preview.localizedCaseInsensitiveContains("Needle"))
    }

    func testSearchReturnsMatchesAcrossPDFPages() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("guide.pdf")
        try writeSearchablePDF(pages: [
            "Needle on page one",
            "Needle on page two"
        ], to: pdf)

        let documents = [WorkspaceDocument(url: pdf, rootURL: root)]
        let results = try WorkspaceSearchService().search(query: "needle", documents: documents).results

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.map(\.locationLabel), ["p1", "p2"])
        XCTAssertEqual(results.map { $0.pdfTarget?.page }, [1, 2])
        XCTAssertEqual(results.map { $0.pdfTarget?.matchIndex }, [0, 1])
    }

    func testPDFSearchReturnsAnnotationContents() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("annotated.pdf")
        try writeAnnotatedPDF(pageText: "Visible PDF text", annotationText: "Reviewer-only annotation needle", to: pdf)

        let document = WorkspaceDocument(url: pdf, rootURL: root)
        let pdfCache = WorkspacePDFTextCache()
        let results = try WorkspaceSearchService(
            pdfCache: pdfCache,
            pdfIndex: WorkspacePDFSearchIndex(pdfCache: pdfCache)
        ).search(query: "reviewer-only", documents: [document]).results

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].kind, .pdf)
        XCTAssertEqual(results[0].locationLabel, "p1")
        XCTAssertTrue(results[0].preview.contains("Reviewer-only annotation needle"))
    }

    func testPDFSearchUsesDirtyDataOverrideBeforeDiskData() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("annotated.pdf")
        let dirtyPDF = root.appendingPathComponent("dirty.pdf")
        try writeAnnotatedPDF(pageText: "Visible PDF text", annotationText: "Disk-only annotation needle", to: pdf)
        try writeAnnotatedPDF(pageText: "Visible PDF text", annotationText: "Unsaved-only annotation needle", to: dirtyPDF)
        let dirtyData = try Data(contentsOf: dirtyPDF)

        let document = WorkspaceDocument(url: pdf, rootURL: root)
        let pdfCache = WorkspacePDFTextCache()
        let pdfIndex = WorkspacePDFSearchIndex(pdfCache: pdfCache)
        let service = WorkspaceSearchService(pdfCache: pdfCache, pdfIndex: pdfIndex)

        let dirtyResults = try service.search(
            query: "unsaved-only",
            documents: [document],
            dirtyPDFDataByDocumentID: [document.id: dirtyData]
        ).results
        XCTAssertEqual(dirtyResults.count, 1)
        XCTAssertTrue(dirtyResults[0].preview.contains("Unsaved-only annotation needle"))
        XCTAssertFalse(pdfIndex.indexedDocumentIDs.contains(document.id))

        let diskMaskedResults = try service.search(
            query: "disk-only",
            documents: [document],
            dirtyPDFDataByDocumentID: [document.id: dirtyData]
        ).results
        XCTAssertTrue(diskMaskedResults.isEmpty)

        let diskResults = try service.search(query: "disk-only", documents: [document]).results
        XCTAssertEqual(diskResults.count, 1)
        XCTAssertTrue(diskResults[0].preview.contains("Disk-only annotation needle"))
    }

    func testPDFSearchUsesCacheAndRefreshesAfterFileMutation() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("guide.pdf")
        try writeSearchablePDF("Cached needle", to: pdf)

        let document = WorkspaceDocument(url: pdf, rootURL: root)
        let pdfCache = WorkspacePDFTextCache()
        let pdfIndex = WorkspacePDFSearchIndex(pdfCache: pdfCache)
        let service = WorkspaceSearchService(pdfCache: pdfCache, pdfIndex: pdfIndex)

        let first = try service.search(query: "needle", documents: [document]).results
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(pdfCache.cachedPaths.contains(pdf.standardizedFileURL.path))
        XCTAssertTrue(pdfIndex.indexedDocumentIDs.contains(document.id))

        try FileManager.default.removeItem(at: pdf)
        try writeSearchablePDF("Replacement token with different length", to: pdf)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 2)],
            ofItemAtPath: pdf.path
        )

        let staleQuery = try service.search(query: "needle", documents: [document]).results
        XCTAssertTrue(staleQuery.isEmpty)

        let refreshed = try service.search(query: "replacement", documents: [document]).results
        XCTAssertEqual(refreshed.count, 1)
        XCTAssertTrue(refreshed.first?.preview.localizedCaseInsensitiveContains("Replacement") == true)
        XCTAssertTrue(pdfIndex.indexedDocumentIDs.contains(document.id))
    }
}
