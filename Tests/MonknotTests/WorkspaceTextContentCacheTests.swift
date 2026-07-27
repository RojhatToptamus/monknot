import XCTest
@testable import MonknotCore

final class WorkspaceTextContentCacheTests: XCTestCase {
    func testCapacityEvictionDoesNotInvalidateAnExistingSearchIndexEntry() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)

        let cache = WorkspaceTextContentCache(maxEntryCount: 1)
        let document = try XCTUnwrap(
            WorkspaceDocumentScanner().scan(rootURL: root).documents.first(where: {
                $0.url == first.standardizedFileURL
            })
        )
        let searchIndex = WorkspaceSearchIndex(textCache: cache)
        try searchIndex.update(document: document)
        let revisionBeforeEviction = cache.revision(for: first)

        cache.store(text: "second", for: second)

        XCTAssertNil(cache.text(for: first))
        XCTAssertEqual(cache.revision(for: first), revisionBeforeEviction)

        let search = try searchIndex.search(query: "first", documents: [document])
        XCTAssertEqual(search.results.count, 1)
        XCTAssertNil(cache.text(for: first), "A valid search-index entry should not reread an evicted text-cache entry")
    }

    func testCacheReturnsTextUntilFileChanges() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("note.md")
        try "version one".write(to: file, atomically: true, encoding: .utf8)

        let cache = WorkspaceTextContentCache()
        let first = try WorkspaceTextFileGuard.readUTF8Text(from: file, cache: cache)
        let second = try WorkspaceTextFileGuard.readUTF8Text(from: file, cache: cache)

        XCTAssertEqual(first, "version one")
        XCTAssertEqual(second, "version one")

        try "version two".write(to: file, atomically: true, encoding: .utf8)
        cache.invalidate(paths: [file.path])

        let third = try WorkspaceTextFileGuard.readUTF8Text(from: file, cache: cache)
        XCTAssertEqual(third, "version two")
    }

    func testInvalidateAllClearsEntries() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("note.md")
        try "cached".write(to: file, atomically: true, encoding: .utf8)

        let cache = WorkspaceTextContentCache()
        _ = try WorkspaceTextFileGuard.readUTF8Text(from: file, cache: cache)
        cache.invalidateAll()

        try "updated".write(to: file, atomically: true, encoding: .utf8)
        let text = try WorkspaceTextFileGuard.readUTF8Text(from: file, cache: cache)
        XCTAssertEqual(text, "updated")
    }

    func testSearchLinesAreFoldedAndInvalidatedWithTextCache() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("note.md")
        try "Résumé\nSecond".write(to: file, atomically: true, encoding: .utf8)

        let cache = WorkspaceTextContentCache()
        let text = try WorkspaceTextFileGuard.readUTF8Text(from: file, cache: cache)
        let firstLines = cache.searchLines(for: file, buildingFrom: text)

        XCTAssertEqual(firstLines.map(\.number), [1, 2])
        XCTAssertEqual(firstLines[0].text, "Résumé")
        XCTAssertEqual(firstLines[0].foldedText, "resume")

        try "Changed".write(to: file, atomically: true, encoding: .utf8)
        cache.invalidate(paths: [file.path])
        let updatedText = try WorkspaceTextFileGuard.readUTF8Text(from: file, cache: cache)
        let updatedLines = cache.searchLines(for: file, buildingFrom: updatedText)

        XCTAssertEqual(updatedLines.count, 1)
        XCTAssertEqual(updatedLines[0].text, "Changed")
    }

    func testCacheEvictsLeastRecentlyUsedEntryWhenLimitIsExceeded() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        let third = root.appendingPathComponent("third.md")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)
        try "third".write(to: third, atomically: true, encoding: .utf8)

        let cache = WorkspaceTextContentCache(maxEntryCount: 2)
        _ = try WorkspaceTextFileGuard.readUTF8Text(from: first, cache: cache)
        _ = try WorkspaceTextFileGuard.readUTF8Text(from: second, cache: cache)
        _ = try WorkspaceTextFileGuard.readUTF8Text(from: third, cache: cache)

        XCTAssertNil(cache.text(for: first))
        XCTAssertEqual(cache.text(for: second), "second")
        XCTAssertEqual(cache.text(for: third), "third")

        try "first-updated".write(to: first, atomically: true, encoding: .utf8)
        XCTAssertEqual(try WorkspaceTextFileGuard.readUTF8Text(from: first, cache: cache), "first-updated")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-text-cache-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
