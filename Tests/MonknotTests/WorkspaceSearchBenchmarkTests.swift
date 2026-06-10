import XCTest
@testable import MonknotCore

final class WorkspaceSearchBenchmarkTests: XCTestCase {
    func testSearchBenchmarkFixtureFindsMatchesAndUsesCache() throws {
        let root = try makeBenchmarkWorkspace(fileCount: 50)
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        XCTAssertGreaterThanOrEqual(scan.documents.count, 40)

        let cache = WorkspaceTextContentCache()
        let service = WorkspaceSearchService(textCache: cache)

        let first = try service.search(query: "benchmark-token", documents: scan.documents)
        XCTAssertGreaterThanOrEqual(first.results.count, 40)
        XCTAssertEqual(first.skippedLargeFileCount, 0)

        let second = try service.search(query: "benchmark-token", documents: scan.documents)
        XCTAssertEqual(second.results.count, first.results.count)
    }

    func testLargeWorkspaceSearchBenchmarkFixtureUsesBoundedIndex() throws {
        let root = try makeBenchmarkWorkspace(fileCount: 600)
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        XCTAssertEqual(scan.documents.count, 600)

        let cache = WorkspaceTextContentCache(maxEntryCount: 1_024)
        let index = WorkspaceSearchIndex(textCache: cache, maxEntryCount: 1_024)

        let first = try index.search(
            query: "benchmark-token",
            documents: scan.documents,
            maxMatches: 1_000,
            maxMatchesPerFile: 3
        )
        XCTAssertEqual(first.results.count, 600)
        XCTAssertEqual(first.skippedLargeFileCount, 0)
        XCTAssertEqual(index.indexedDocumentIDs.count, 600)
        XCTAssertLessThanOrEqual(index.indexedDocumentIDs.count, index.maxEntryCount)

        let second = try index.search(
            query: "benchmark-token",
            documents: scan.documents,
            maxMatches: 1_000,
            maxMatchesPerFile: 3
        )
        XCTAssertEqual(second.results.count, first.results.count)
        XCTAssertLessThanOrEqual(index.indexedDocumentIDs.count, index.maxEntryCount)
    }

    private func makeBenchmarkWorkspace(fileCount: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-search-benchmark")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for index in 0..<fileCount {
            let folder = root.appendingPathComponent(String(format: "Notes/%02d", index % 30), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("note-\(index).md")
            try """
            # Note \(index)
            body line \(index)
            benchmark-token line \(index)
            trailing line \(index)
            """.write(to: file, atomically: true, encoding: .utf8)
        }

        return root
    }
}
