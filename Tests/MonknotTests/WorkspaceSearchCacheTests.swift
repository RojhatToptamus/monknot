import XCTest
@testable import MonknotCore

final class WorkspaceSearchCacheTests: XCTestCase {
    func testRepeatedSearchReusesTextCacheAcrossDocuments() throws {
        let root = try makeSearchFixtureWorkspace(fileCount: 24)
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        let cache = WorkspaceTextContentCache()
        let service = WorkspaceSearchService(textCache: cache)

        let first = try service.search(query: "fixture-token", documents: scan.documents)
        let second = try service.search(query: "fixture-token", documents: scan.documents)

        XCTAssertEqual(first.results.count, 24)
        XCTAssertEqual(second.results, first.results)
    }

    func testSearchCacheInvalidatesAfterFileMutation() throws {
        let root = try makeSearchFixtureWorkspace(fileCount: 3)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("Docs/doc-0.md")
        let scan = try WorkspaceDocumentScanner().scan(rootURL: root)
        let cache = WorkspaceTextContentCache()
        let service = WorkspaceSearchService(textCache: cache)

        let before = try service.search(query: "replacement-token", documents: scan.documents)
        XCTAssertTrue(before.results.isEmpty)

        try "replacement-token\n".write(to: target, atomically: true, encoding: .utf8)
        cache.invalidate(paths: [target.path])

        let after = try service.search(query: "replacement-token", documents: scan.documents)
        XCTAssertEqual(after.results.count, 1)
        XCTAssertEqual(after.results[0].relativePath, "Docs/doc-0.md")
    }

    private func makeSearchFixtureWorkspace(fileCount: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-search-fixture")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let docs = root.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        for index in 0..<fileCount {
            let file = docs.appendingPathComponent("doc-\(index).md")
            try "fixture-token line \(index)\n".write(to: file, atomically: true, encoding: .utf8)
        }

        return root
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-search-cache-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
