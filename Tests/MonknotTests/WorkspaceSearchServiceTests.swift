import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import MonknotCore

final class WorkspaceSearchServiceTests: XCTestCase {
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

    private func writeAnnotatedPDF(pageText: String, annotationText: String, to url: URL) throws {
        let scratchURL = url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).pdf")
        try writeSearchablePDF(pageText, to: scratchURL)
        defer { try? FileManager.default.removeItem(at: scratchURL) }

        guard let document = PDFDocument(url: scratchURL), let page = document.page(at: 0) else {
            throw NSError(domain: "MonknotTests", code: 2)
        }

        let annotation = PDFAnnotation(
            bounds: CGRect(x: 72, y: 620, width: 240, height: 24),
            forType: .text,
            withProperties: nil
        )
        annotation.contents = annotationText
        page.addAnnotation(annotation)

        guard let data = document.dataRepresentation() else {
            throw NSError(domain: "MonknotTests", code: 3)
        }
        try data.write(to: url)
    }
}
