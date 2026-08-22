import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import MonknotCore

final class WorkspaceTextSearchServiceTests: WorkspaceSearchServiceTestCase {
    func testSearchReturnsLineAndColumnForMarkdownMatches() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("notes.md")
        try "First line\nNeedle here\nanother needle".write(to: note, atomically: true, encoding: .utf8)

        let documents = [WorkspaceDocument(url: note, rootURL: root)]
        let results = try WorkspaceSearchService().search(query: "needle", documents: documents).results

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].kind, .text)
        XCTAssertEqual(results[0].line, 2)
        XCTAssertEqual(results[0].column, 0)
        XCTAssertEqual(results[1].line, 3)
        XCTAssertEqual(results[1].column, 8)
    }

    func testWhitespaceQueryReturnsNoResults() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("notes.md")
        try "needle".write(to: note, atomically: true, encoding: .utf8)

        let documents = [WorkspaceDocument(url: note, rootURL: root)]

        XCTAssertTrue(try WorkspaceSearchService().search(query: "   \n\t", documents: documents).results.isEmpty)
    }

    func testSearchHonorsGlobalAndPerFileLimits() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try "needle needle needle".write(to: first, atomically: true, encoding: .utf8)
        try "needle needle needle".write(to: second, atomically: true, encoding: .utf8)

        let documents = [
            WorkspaceDocument(url: first, rootURL: root),
            WorkspaceDocument(url: second, rootURL: root)
        ]

        let results = try WorkspaceSearchService(maxMatches: 3, maxMatchesPerFile: 2).search(query: "needle", documents: documents).results

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.filter { $0.relativePath == "first.md" }.count, 2)
        XCTAssertEqual(results.filter { $0.relativePath == "second.md" }.count, 1)
    }

    func testSearchIsCaseAndDiacriticInsensitive() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("notes.md")
        try "Résumé\nRESUME\n".write(to: note, atomically: true, encoding: .utf8)

        let documents = [WorkspaceDocument(url: note, rootURL: root)]
        let results = try WorkspaceSearchService().search(query: "resume", documents: documents).results

        XCTAssertEqual(results.map(\.line), [1, 2])
    }

    func testSearchAppliesCaseSensitiveAndWholeWordOptionsWithoutAnotherIndex() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("notes.md")
        try "Needle needle needler\nRésumé resume\n".write(to: note, atomically: true, encoding: .utf8)

        let document = WorkspaceDocument(url: note, rootURL: root)
        let cache = WorkspaceTextContentCache()
        let index = WorkspaceSearchIndex(textCache: cache)
        let service = WorkspaceSearchService(textCache: cache, textIndex: index)

        let sensitive = try service.search(
            query: "needle",
            options: MonknotSearchOptions(isCaseSensitive: true),
            documents: [document]
        ).results
        let wholeWord = try service.search(
            query: "needle",
            options: MonknotSearchOptions(isWholeWord: true),
            documents: [document]
        ).results

        XCTAssertEqual(sensitive.count, 2)
        XCTAssertEqual(wholeWord.count, 2)
        XCTAssertTrue(index.hasIndexedDocument(document.id))
    }

    func testSearchUsesDirtyTextOverrideWithoutUpdatingDiskIndex() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("notes.md")
        try "Disk-only needle\n".write(to: note, atomically: true, encoding: .utf8)

        let document = WorkspaceDocument(url: note, rootURL: root)
        let textCache = WorkspaceTextContentCache()
        let textIndex = WorkspaceSearchIndex(textCache: textCache)
        let service = WorkspaceSearchService(textCache: textCache, textIndex: textIndex)
        let dirtyText = "Unicode π\r\nUnsaved-only needle\r\n"

        let dirtyResults = try service.search(
            query: "unsaved-only",
            documents: [document],
            dirtyTextByDocumentID: [document.id: dirtyText]
        ).results
        XCTAssertEqual(dirtyResults.map(\.line), [2])
        XCTAssertFalse(textIndex.hasIndexedDocument(document.id))
        XCTAssertNil(textCache.text(for: note))

        let diskMaskedResults = try service.search(
            query: "disk-only",
            documents: [document],
            dirtyTextByDocumentID: [document.id: dirtyText]
        ).results
        XCTAssertTrue(diskMaskedResults.isEmpty)

        let diskResults = try service.search(query: "disk-only", documents: [document]).results
        XCTAssertEqual(diskResults.count, 1)
    }

    func testSearchReturnsMatchesForTextDocuments() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = root.appendingPathComponent("plain.txt")
        try "needle".write(to: text, atomically: true, encoding: .utf8)

        let documents = [WorkspaceDocument(url: text, rootURL: root)]

        let results = try WorkspaceSearchService().search(query: "needle", documents: documents).results

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].kind, .text)
        XCTAssertEqual(results[0].relativePath, "plain.txt")
    }

    func testSearchReturnsMatchesForHTMLSourceDocuments() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let html = root.appendingPathComponent("preview.html")
        try "<article><h1>Needle</h1></article>".write(to: html, atomically: true, encoding: .utf8)

        let documents = [WorkspaceDocument(url: html, rootURL: root)]

        let results = try WorkspaceSearchService().search(query: "needle", documents: documents).results

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].kind, .text)
        XCTAssertEqual(results[0].relativePath, "preview.html")
    }

    func testSearchSkipsOversizedTextDocumentsAndReportsCount() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let small = root.appendingPathComponent("small.md")
        let large = root.appendingPathComponent("large.md")
        try "needle in small".write(to: small, atomically: true, encoding: .utf8)
        try String(repeating: "needle ", count: 300).write(to: large, atomically: true, encoding: .utf8)

        let documents = [
            WorkspaceDocument(url: small, rootURL: root),
            WorkspaceDocument(url: large, rootURL: root)
        ]

        let batch = try WorkspaceSearchService(
            maxMatches: 10,
            maxMatchesPerFile: 10,
            maxTextFileBytes: 1024,
            textCache: WorkspaceTextContentCache()
        ).search(query: "needle", documents: documents)

        XCTAssertEqual(batch.skippedLargeFileCount, 1)
        XCTAssertEqual(batch.results.count, 1)
        XCTAssertEqual(batch.results[0].relativePath, "small.md")
    }

    func testSearchSkipsUnsupportedFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("archive.zip")
        try "needle".write(to: binary, atomically: true, encoding: .utf8)

        let documents = [
            WorkspaceDocument(url: binary, rootURL: root)
        ]

        XCTAssertTrue(try WorkspaceSearchService().search(query: "needle", documents: documents).results.isEmpty)
    }

    func testSearchChecksTaskCancellation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let documents = try (0..<200).map { index -> WorkspaceDocument in
            let url = root.appendingPathComponent("note-\(index).md")
            try "needle \(index)".write(to: url, atomically: true, encoding: .utf8)
            return WorkspaceDocument(url: url, rootURL: root)
        }

        let task = Task {
            await Task.yield()
            _ = try WorkspaceSearchService().search(query: "needle", documents: documents)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected workspace search to throw CancellationError")
        } catch is CancellationError {
        }
    }
}
