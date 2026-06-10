import XCTest
@testable import MonknotCore

final class WorkspaceSearchIndexTests: XCTestCase {
    func testRebuildIndexesTextDocumentsAndRemoveDropsEntry() throws {
        let root = try makeSearchFixtureWorkspace(fileCount: 2)
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        let index = WorkspaceSearchIndex(textCache: WorkspaceTextContentCache())

        try index.rebuild(documents: scan.documents)

        let textDocumentIDs = Set(scan.documents.filter { $0.kind == .markdown || $0.kind == .text }.map(\.id))
        XCTAssertEqual(index.indexedDocumentIDs, textDocumentIDs)

        guard let firstID = textDocumentIDs.first else {
            return XCTFail("Expected indexed document")
        }
        index.remove(documentID: firstID)

        XCTAssertFalse(index.indexedDocumentIDs.contains(firstID))
    }

    func testUpdateRefreshesSingleDocumentEntry() throws {
        let root = try makeSearchFixtureWorkspace(fileCount: 3)
        defer { try? FileManager.default.removeItem(at: root) }

        let targetURL = root.appendingPathComponent("Docs/doc-0.md")
        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        guard let targetDocument = scan.documents.first(where: { $0.url == targetURL.standardizedFileURL }) else {
            return XCTFail("Expected target document")
        }

        let cache = WorkspaceTextContentCache()
        let index = WorkspaceSearchIndex(textCache: cache)
        try index.rebuild(documents: scan.documents)

        try "replacement-token\n".write(to: targetURL, atomically: true, encoding: .utf8)
        cache.invalidate(paths: [targetURL.path])
        try index.update(document: targetDocument)

        let batch = try index.search(query: "replacement-token", documents: scan.documents)

        XCTAssertEqual(batch.results.count, 1)
        XCTAssertEqual(batch.results[0].relativePath, "Docs/doc-0.md")
    }

    func testWorkspaceSearchServiceColdTextSearchDoesNotPopulateIndex() throws {
        let root = try makeSearchFixtureWorkspace(fileCount: 1)
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        let cache = WorkspaceTextContentCache()
        let index = WorkspaceSearchIndex(textCache: cache)
        let service = WorkspaceSearchService(textCache: cache, textIndex: index)

        let first = try service.search(query: "fixture-token", documents: scan.documents)
        XCTAssertEqual(first.results.count, 1)
        XCTAssertTrue(index.indexedDocumentIDs.isEmpty)
    }

    func testWorkspaceSearchServiceUsesProvidedPrewarmedIndex() throws {
        let root = try makeSearchFixtureWorkspace(fileCount: 1)
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        let cache = WorkspaceTextContentCache()
        let index = WorkspaceSearchIndex(textCache: cache)
        let service = WorkspaceSearchService(textCache: cache, textIndex: index)

        try index.rebuild(documents: scan.documents)

        let first = try service.search(query: "fixture-token", documents: scan.documents)
        XCTAssertEqual(first.results.count, 1)
        XCTAssertEqual(index.indexedDocumentIDs, Set(scan.documents.map(\.id)))
    }

    func testPrewarmServiceIndexesTextDocumentsWithinLimit() throws {
        let root = try makeSearchFixtureWorkspace(fileCount: 3)
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        let cache = WorkspaceTextContentCache()
        let index = WorkspaceSearchIndex(textCache: cache)
        let service = WorkspaceSearchPrewarmService(
            maxTextDocuments: 2,
            maxPDFDocuments: 0,
            textIndex: index,
            pdfIndex: WorkspacePDFSearchIndex(pdfCache: WorkspacePDFTextCache())
        )

        try service.prewarm(documents: scan.documents)

        XCTAssertEqual(index.indexedDocumentIDs.count, 2)
    }

    func testPrewarmServiceDefaultsAvoidEagerPDFIndexing() throws {
        let root = try makeSearchFixtureWorkspace(fileCount: 1)
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Docs/reference.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: pdfURL)

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        let textIndex = WorkspaceSearchIndex(textCache: WorkspaceTextContentCache())
        let pdfIndex = WorkspacePDFSearchIndex(pdfCache: WorkspacePDFTextCache())
        let service = WorkspaceSearchPrewarmService(
            textIndex: textIndex,
            pdfIndex: pdfIndex
        )

        try service.prewarm(documents: scan.documents)

        XCTAssertEqual(textIndex.indexedDocumentIDs.count, 1)
        XCTAssertTrue(pdfIndex.indexedDocumentIDs.isEmpty)
    }

    func testPrewarmServiceReturnsWithoutIndexingWhenLimitsAreZero() throws {
        let root = try makeSearchFixtureWorkspace(fileCount: 1)
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("Docs/reference.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: pdfURL)

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        let textIndex = WorkspaceSearchIndex(textCache: WorkspaceTextContentCache())
        let pdfIndex = WorkspacePDFSearchIndex(pdfCache: WorkspacePDFTextCache())
        let service = WorkspaceSearchPrewarmService(
            maxTextDocuments: 0,
            maxPDFDocuments: 0,
            textIndex: textIndex,
            pdfIndex: pdfIndex
        )

        try service.prewarm(documents: scan.documents)

        XCTAssertTrue(textIndex.indexedDocumentIDs.isEmpty)
        XCTAssertTrue(pdfIndex.indexedDocumentIDs.isEmpty)
    }

    func testIndexEvictsLeastRecentlyUsedEntriesWhenBounded() throws {
        let root = try makeSearchFixtureWorkspace(fileCount: 4)
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        let sortedDocuments = scan.documents.sorted { $0.relativePath < $1.relativePath }
        let index = WorkspaceSearchIndex(textCache: WorkspaceTextContentCache(), maxEntryCount: 2)

        for document in sortedDocuments {
            try index.update(document: document)
        }

        XCTAssertLessThanOrEqual(index.indexedDocumentIDs.count, 2)
        XCTAssertFalse(index.indexedDocumentIDs.contains(sortedDocuments[0].id))
        XCTAssertFalse(index.indexedDocumentIDs.contains(sortedDocuments[1].id))
        XCTAssertTrue(index.indexedDocumentIDs.contains(sortedDocuments[2].id))
        XCTAssertTrue(index.indexedDocumentIDs.contains(sortedDocuments[3].id))
    }

    private func makeSearchFixtureWorkspace(fileCount: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-search-index-fixture")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let docs = root.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        for index in 0..<fileCount {
            let file = docs.appendingPathComponent("doc-\(index).md")
            try "fixture-token line \(index)\n".write(to: file, atomically: true, encoding: .utf8)
        }

        return root
    }
}
