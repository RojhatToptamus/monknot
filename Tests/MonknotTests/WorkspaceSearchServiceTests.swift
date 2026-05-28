import CoreGraphics
import CoreText
import XCTest
@testable import MonknotCore

final class WorkspaceSearchServiceTests: XCTestCase {
    func testSearchReturnsLineAndColumnForMarkdownMatches() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("notes.md")
        try "First line\nNeedle here\nanother needle".write(to: note, atomically: true, encoding: .utf8)

        let documents = [WorkspaceDocument(url: note, rootURL: root)]
        let results = try WorkspaceSearchService().search(query: "needle", documents: documents)

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

        XCTAssertTrue(try WorkspaceSearchService().search(query: "   \n\t", documents: documents).isEmpty)
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

        let results = try WorkspaceSearchService(maxMatches: 3, maxMatchesPerFile: 2).search(query: "needle", documents: documents)

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
        let results = try WorkspaceSearchService().search(query: "resume", documents: documents)

        XCTAssertEqual(results.map(\.line), [1, 2])
    }

    func testSearchReturnsPageMatchesForPDFDocuments() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("guide.pdf")
        try writeSearchablePDF("PDF heading\nNeedle in a searchable PDF page", to: pdf)

        let documents = [WorkspaceDocument(url: pdf, rootURL: root)]
        let results = try WorkspaceSearchService().search(query: "needle", documents: documents)

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
        let results = try WorkspaceSearchService().search(query: "needle", documents: documents)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.map(\.locationLabel), ["p1", "p2"])
        XCTAssertEqual(results.map { $0.pdfTarget?.page }, [1, 2])
        XCTAssertEqual(results.map { $0.pdfTarget?.matchIndex }, [0, 1])
    }

    func testSearchReturnsMatchesForTextDocuments() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = root.appendingPathComponent("plain.txt")
        try "needle".write(to: text, atomically: true, encoding: .utf8)

        let documents = [WorkspaceDocument(url: text, rootURL: root)]

        let results = try WorkspaceSearchService().search(query: "needle", documents: documents)

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

        let results = try WorkspaceSearchService().search(query: "needle", documents: documents)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].kind, .text)
        XCTAssertEqual(results[0].relativePath, "preview.html")
    }

    func testSearchSkipsUnsupportedFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("archive.zip")
        try "needle".write(to: binary, atomically: true, encoding: .utf8)

        let documents = [
            WorkspaceDocument(url: binary, rootURL: root)
        ]

        XCTAssertTrue(try WorkspaceSearchService().search(query: "needle", documents: documents).isEmpty)
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
            try WorkspaceSearchService().search(query: "needle", documents: documents)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected workspace search to throw CancellationError")
        } catch is CancellationError {
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monknot-search-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSearchablePDF(_ text: String, to url: URL) throws {
        try writeSearchablePDF(pages: [text], to: url)
    }

    private func writeSearchablePDF(pages: [String], to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "MonknotTests", code: 1)
        }

        for text in pages {
            context.beginPDFPage(nil)

            let attributed = NSAttributedString(string: text, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 14, nil),
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1)
            ])
            let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
            let path = CGMutablePath()
            path.addRect(CGRect(x: 72, y: 72, width: 468, height: 648))
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: attributed.length),
                path,
                nil
            )
            CTFrameDraw(frame, context)

            context.endPDFPage()
        }
        context.closePDF()
    }
}
