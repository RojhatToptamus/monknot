import CoreGraphics
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import MonknotCore

final class PDFExcerptFormattingTests: PDFLinkedExcerptTestCase {
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
