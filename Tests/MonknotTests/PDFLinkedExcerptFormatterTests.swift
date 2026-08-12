import CoreGraphics
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import MonknotCore

final class PDFLinkedExcerptFormatterTests: XCTestCase {
    func testSourceRevisionDetectsDirtyEditAndDiskRaces() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFLinkedExcerptSourceRevision-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = directory.appendingPathComponent("Source.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("initial".utf8).write(to: sourceURL)

        let revision = try XCTUnwrap(PDFLinkedExcerptSourceRevision.capture(
            sourceURL: sourceURL,
            workspaceURL: directory,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: 3
        ))
        XCTAssertTrue(revision.stillMatches(
            sourceURL: sourceURL,
            workspaceURL: directory,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: 3
        ))
        XCTAssertFalse(revision.stillMatches(
            sourceURL: sourceURL,
            workspaceURL: directory,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: 4
        ))

        try Data("a longer replacement".utf8).write(to: sourceURL, options: .atomic)
        XCTAssertFalse(revision.stillMatches(
            sourceURL: sourceURL,
            workspaceURL: directory,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: 3
        ))
    }

    func testSourceRevisionRejectsDeletedSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFLinkedExcerptSourceRevision-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = directory.appendingPathComponent("Source.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("initial".utf8).write(to: sourceURL)
        let revision = try XCTUnwrap(PDFLinkedExcerptSourceRevision.capture(
            sourceURL: sourceURL,
            workspaceURL: directory,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: nil
        ))

        try FileManager.default.removeItem(at: sourceURL)

        XCTAssertNil(PDFLinkedExcerptSourceRevision.capture(
            sourceURL: sourceURL,
            workspaceURL: directory,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: nil
        ))
        XCTAssertFalse(revision.stillMatches(
            sourceURL: sourceURL,
            workspaceURL: directory,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: nil
        ))
    }

    func testSourceRevisionRejectsSymlinkReplacementOutsideWorkspace() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFLinkedExcerptSourceRevision-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = parent.appendingPathComponent("Workspace", isDirectory: true)
        let sourceURL = workspaceURL.appendingPathComponent("Source.pdf")
        let outsideURL = parent.appendingPathComponent("Outside.pdf")
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("initial".utf8).write(to: sourceURL)
        try Data("outside".utf8).write(to: outsideURL)
        let revision = try XCTUnwrap(PDFLinkedExcerptSourceRevision.capture(
            sourceURL: sourceURL,
            workspaceURL: workspaceURL,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: nil
        ))

        try FileManager.default.removeItem(at: sourceURL)
        try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: outsideURL)

        XCTAssertFalse(revision.stillMatches(
            sourceURL: sourceURL,
            workspaceURL: workspaceURL,
            expectedRelativePath: "Source.pdf",
            dirtyEditVersion: nil
        ))
    }

    func testFormatsMultilineSelectionWithWorkspaceRootPageWikilink() throws {
        let selection = PDFSelectionSnapshot(
            documentID: "/workspace/reference/Paper.pdf",
            text: "First line\n\nSecond line",
            pageNumber: 12
        )

        let markdown = try PDFLinkedExcerptFormatter().markdown(
            for: selection,
            sourceRelativePath: "reference/Paper.pdf"
        )

        XCTAssertEqual(
            markdown,
            """
            > First line
            >
            > Second line
            >
            > [[reference/Paper.pdf#page=12|Source: Paper.pdf, page 12]]
            """
        )
    }

    func testPreservesUnicodeAndEncodesWikilinkStructuralCharacters() throws {
        let selection = PDFSelectionSnapshot(
            documentID: "/workspace/papers/Guide [draft].pdf",
            text: "Quoted result",
            pageNumber: 2
        )

        let markdown = try PDFLinkedExcerptFormatter().markdown(
            for: selection,
            sourceRelativePath: "papers/Guide [draft] | 100% #1 ü.pdf"
        )

        XCTAssertEqual(
            markdown,
            "> Quoted result\n>\n> [[papers/Guide%20%5Bdraft%5D%20%7C%20100%25%20%231%20%C3%BC.pdf#page=2|Source: page 2]]"
        )
    }

    func testUnsafeFilenameControlsCannotInjectMarkdownLines() throws {
        let selection = PDFSelectionSnapshot(
            documentID: "/workspace/papers/Break\nInjected.pdf",
            text: "Quoted result",
            pageNumber: 2
        )

        let markdown = try PDFLinkedExcerptFormatter().markdown(
            for: selection,
            sourceRelativePath: "papers/Break\nInjected.pdf"
        )

        XCTAssertEqual(
            markdown,
            "> Quoted result\n>\n> [[papers/Break%0AInjected.pdf#page=2|Source: page 2]]"
        )
        XCTAssertEqual(markdown.components(separatedBy: "\n").count, 3)
    }

    func testPreservesUnicodeExcerptText() throws {
        let selection = PDFSelectionSnapshot(documentID: "source", text: "Grüße 🌍\n第二行", pageNumber: 1)

        let markdown = try PDFLinkedExcerptFormatter().markdown(
            for: selection,
            sourceRelativePath: "papers/Übersicht.pdf"
        )

        XCTAssertEqual(
            markdown,
            "> Grüße 🌍\n> 第二行\n>\n> [[papers/%C3%9Cbersicht.pdf#page=1|Source: Übersicht.pdf, page 1]]"
        )
    }

    func testWorkspaceRootWikilinkResolvesFromNestedMarkdownDocument() throws {
        let root = URL(fileURLWithPath: "/tmp/monknot-linked-excerpt", isDirectory: true)
        let nestedNote = WorkspaceDocument(
            url: root.appendingPathComponent("notes/research/Findings.md"),
            rootURL: root
        )
        let pdf = WorkspaceDocument(
            url: root.appendingPathComponent("papers/example.pdf"),
            rootURL: root
        )
        let markdown = try PDFLinkedExcerptFormatter().markdown(
            for: PDFSelectionSnapshot(documentID: pdf.id, text: "Quote", pageNumber: 4),
            sourceRelativePath: pdf.relativePath
        )
        let link = try XCTUnwrap(MarkdownWorkspaceLinkParser().links(in: markdown).first)
        XCTAssertEqual(link.destinationComponents.fragment, "page=4")

        XCTAssertEqual(
            MarkdownWorkspaceLinkResolver().resolve(
                link,
                sourceDocument: nestedNote,
                workspaceRootURL: root,
                documents: [nestedNote, pdf]
            ),
            .document(documentID: pdf.id, fragment: "page4")
        )
    }

    func testWorkspaceRootPDFBasenameWinsNestedCollisionForGeneratedWikilink() throws {
        let root = URL(fileURLWithPath: "/tmp/monknot-linked-excerpt-basename", isDirectory: true)
        let nestedNote = WorkspaceDocument(
            url: root.appendingPathComponent("notes/research/Findings.md"),
            rootURL: root
        )
        let rootPDF = WorkspaceDocument(
            url: root.appendingPathComponent("example.pdf"),
            rootURL: root
        )
        let nestedPDF = WorkspaceDocument(
            url: root.appendingPathComponent("notes/research/example.pdf"),
            rootURL: root
        )
        let markdown = try PDFLinkedExcerptFormatter().markdown(
            for: PDFSelectionSnapshot(documentID: rootPDF.id, text: "Quote", pageNumber: 4),
            sourceRelativePath: rootPDF.relativePath
        )
        let link = try XCTUnwrap(MarkdownWorkspaceLinkParser().links(in: markdown).first)

        XCTAssertEqual(
            markdown,
            "> Quote\n>\n> [[example.pdf#page=4|Source: example.pdf, page 4]]"
        )
        XCTAssertEqual(
            MarkdownWorkspaceLinkResolver().resolve(
                link,
                sourceDocument: nestedNote,
                workspaceRootURL: root,
                documents: [nestedNote, rootPDF, nestedPDF]
            ),
            .document(documentID: rootPDF.id, fragment: "page4")
        )
    }

    func testRejectsEmptySelectionInvalidPageAndEscapingWorkspacePath() {
        let formatter = PDFLinkedExcerptFormatter()

        XCTAssertThrowsError(
            try formatter.markdown(
                for: PDFSelectionSnapshot(documentID: "source", text: " \n ", pageNumber: 1),
                sourceRelativePath: "Paper.pdf"
            )
        ) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptFormatterError, .emptySelection)
        }

        XCTAssertThrowsError(
            try formatter.markdown(
                for: PDFSelectionSnapshot(documentID: "source", text: "Quote", pageNumber: 0),
                sourceRelativePath: "Paper.pdf"
            )
        ) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptFormatterError, .invalidPageNumber)
        }

        XCTAssertThrowsError(
            try formatter.markdown(
                for: PDFSelectionSnapshot(documentID: "source", text: "Quote", pageNumber: 1),
                sourceRelativePath: "../Paper.pdf"
            )
        ) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptFormatterError, .invalidRelativePath)
        }

        XCTAssertThrowsError(
            try formatter.markdown(
                for: PDFSelectionSnapshot(documentID: "source", text: "Quote", pageNumber: 1),
                sourceRelativePath: "papers/../Paper.pdf"
            )
        ) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptFormatterError, .invalidRelativePath)
        }
    }
}

final class PDFLinkedExcerptSourceValidatorTests: XCTestCase {
    private let validator = PDFLinkedExcerptSourceValidator()

    func testAcceptsNormalizedSelectionOnExactPage() throws {
        let data = try makeTextPDFData(pages: ["Introduction", "Selected phrase on page two"])
        let exactSelection = try snapshot(
            matching: "Selected phrase",
            pageNumber: 2,
            in: data
        )
        let selection = PDFSelectionSnapshot(
            documentID: exactSelection.documentID,
            text: "Selected\n phrase",
            pageNumber: exactSelection.pageNumber,
            textRanges: exactSelection.textRanges
        )

        XCTAssertNoThrow(try validator.validate(selection, in: data))
    }

    func testRejectsSelectionThatIsNoLongerPresent() throws {
        let originalData = try makeTextPDFData(pages: ["Earlier page contents"])
        let selection = try snapshot(
            matching: "Earlier page contents",
            pageNumber: 1,
            in: originalData
        )
        let currentData = try makeTextPDFData(pages: ["Current page contents"])

        XCTAssertThrowsError(try validator.validate(selection, in: currentData)) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptSourceValidationError, .selectionChanged)
        }
    }

    func testRejectsSelectionFoundOnlyOnAnotherPage() throws {
        let originalData = try makeTextPDFData(pages: ["First page", "Exact quoted text"])
        let selection = try snapshot(
            matching: "Exact quoted text",
            pageNumber: 2,
            in: originalData
        )
        let currentData = try makeTextPDFData(pages: ["Exact quoted text", "Different second page"])

        XCTAssertThrowsError(try validator.validate(selection, in: currentData)) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptSourceValidationError, .selectionChanged)
        }
    }

    func testRejectsUnavailablePage() throws {
        let originalData = try makeTextPDFData(pages: ["First page", "Selected second page"])
        let selection = try snapshot(
            matching: "Selected second page",
            pageNumber: 2,
            in: originalData
        )
        let currentData = try makeTextPDFData(pages: ["Only page"])

        XCTAssertThrowsError(try validator.validate(selection, in: currentData)) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptSourceValidationError, .pageUnavailable)
        }
    }

    func testRejectsOriginalDuplicateOccurrenceWhenOnlyAnotherCopyRemains() throws {
        let originalData = try makeTextPDFData(
            pages: ["Repeated quote between Repeated quote"]
        )
        let selection = try snapshot(
            matching: "Repeated quote",
            occurrence: 2,
            pageNumber: 1,
            in: originalData
        )
        let currentData = try makeTextPDFData(
            pages: ["Repeated quote between Replacement text"]
        )

        XCTAssertThrowsError(try validator.validate(selection, in: currentData)) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptSourceValidationError, .selectionChanged)
        }
    }

    func testRejectsNonemptySelectionWithoutOccurrenceIdentity() throws {
        let data = try makeTextPDFData(pages: ["Selected text"])
        let selection = PDFSelectionSnapshot(
            documentID: "/workspace/Paper.pdf",
            text: "Selected text",
            pageNumber: 1
        )

        XCTAssertThrowsError(try validator.validate(selection, in: data)) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptSourceValidationError, .selectionChanged)
        }
    }

    func testRejectsEmptyNormalizedSelection() throws {
        let data = try makeTextPDFData(pages: ["Page text"])
        let selection = PDFSelectionSnapshot(
            documentID: "/workspace/Paper.pdf",
            text: " \n\t ",
            pageNumber: 1
        )

        XCTAssertThrowsError(try validator.validate(selection, in: data)) { error in
            XCTAssertEqual(error as? PDFLinkedExcerptSourceValidationError, .emptySelection)
        }
    }

    private func snapshot(
        matching text: String,
        occurrence: Int = 1,
        pageNumber: Int,
        in data: Data
    ) throws -> PDFSelectionSnapshot {
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: pageNumber - 1))
        let pageText = try XCTUnwrap(page.string) as NSString
        var searchRange = NSRange(location: 0, length: pageText.length)
        var matchedRange = NSRange(location: NSNotFound, length: 0)
        for _ in 0..<occurrence {
            matchedRange = pageText.range(of: text, options: [], range: searchRange)
            guard matchedRange.location != NSNotFound else {
                XCTFail("Expected occurrence \(occurrence) of selected PDF text")
                throw NSError(domain: "PDFLinkedExcerptSourceValidatorTests", code: 1)
            }
            let nextLocation = NSMaxRange(matchedRange)
            searchRange = NSRange(location: nextLocation, length: pageText.length - nextLocation)
        }

        let selection = try XCTUnwrap(page.selection(for: matchedRange))
        let rangeCount = selection.numberOfTextRanges(on: page)
        let textRanges = (0..<rangeCount).map { selection.range(at: $0, on: page) }
        return PDFSelectionSnapshot(
            documentID: "/workspace/Paper.pdf",
            text: try XCTUnwrap(selection.string),
            pageNumber: pageNumber,
            textRanges: textRanges
        )
    }

    private func makeTextPDFData(pages: [String]) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 240)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        ]

        for text in pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 28, y: 180)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()

        return data as Data
    }
}
