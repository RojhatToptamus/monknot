import Foundation
import XCTest
@testable import MonknotCore

final class MarkdownLinkResolverTests: MarkdownWorkspaceLinkTestCase {
    func testResolverUsesRelativeRootAndMarkdownExtensionCandidates() throws {
        let root = URL(fileURLWithPath: "/tmp/monknot-link-resolution", isDirectory: true)
        let source = WorkspaceDocument(url: root.appendingPathComponent("Folder/Source.md"), rootURL: root)
        let sibling = WorkspaceDocument(url: root.appendingPathComponent("Folder/Sibling.md"), rootURL: root)
        let rooted = WorkspaceDocument(url: root.appendingPathComponent("Reference.md"), rootURL: root)
        let documents = [source, sibling, rooted]

        XCTAssertEqual(
            resolve("[sibling](Sibling#My%20Heading)", source: source, root: root, documents: documents),
            .document(documentID: sibling.id, fragment: "my-heading")
        )
        XCTAssertEqual(
            resolve("[sibling](Sibling.md?mode=read#My%20Heading)", source: source, root: root, documents: documents),
            .document(documentID: sibling.id, fragment: "my-heading")
        )
        XCTAssertEqual(
            resolve("[root](/Reference.md)", source: source, root: root, documents: documents),
            .document(documentID: rooted.id, fragment: nil)
        )
        XCTAssertEqual(
            resolve("[same](#Local%20Heading)", source: source, root: root, documents: documents),
            .document(documentID: source.id, fragment: "local-heading")
        )
    }

    func testResolverPrefersWorkspaceRootForLinkedExcerptPDFWikilinkCollisions() {
        let root = URL(fileURLWithPath: "/tmp/monknot-wikilink-path-collision", isDirectory: true)
        let source = WorkspaceDocument(
            url: root.appendingPathComponent("notes/deep/Review.md"),
            rootURL: root
        )
        let rootLevelPDF = WorkspaceDocument(
            url: root.appendingPathComponent("example.pdf"),
            rootURL: root
        )
        let nestedRootLevelPDF = WorkspaceDocument(
            url: root.appendingPathComponent("notes/deep/example.pdf"),
            rootURL: root
        )
        let rootPDF = WorkspaceDocument(
            url: root.appendingPathComponent("papers/example.pdf"),
            rootURL: root
        )
        let nestedPDF = WorkspaceDocument(
            url: root.appendingPathComponent("notes/deep/papers/example.pdf"),
            rootURL: root
        )
        let parentPDF = WorkspaceDocument(
            url: root.appendingPathComponent("notes/papers/example.pdf"),
            rootURL: root
        )
        let rootNote = WorkspaceDocument(
            url: root.appendingPathComponent("sub/Note.md"),
            rootURL: root
        )
        let nestedNote = WorkspaceDocument(
            url: root.appendingPathComponent("notes/deep/sub/Note.md"),
            rootURL: root
        )
        let documents = [
            source,
            rootLevelPDF,
            nestedRootLevelPDF,
            rootPDF,
            nestedPDF,
            parentPDF,
            rootNote,
            nestedNote,
        ]

        XCTAssertEqual(
            resolve(
                "[[example.pdf#page=4]]",
                source: source,
                root: root,
                documents: documents
            ),
            .document(documentID: rootLevelPDF.id, fragment: "page4")
        )
        XCTAssertEqual(
            resolve(
                "[[papers/example.pdf#page=4]]",
                source: source,
                root: root,
                documents: documents
            ),
            .document(documentID: rootPDF.id, fragment: "page4")
        )
        XCTAssertEqual(
            resolve(
                "[relative](papers/example.pdf#page=4)",
                source: source,
                root: root,
                documents: documents
            ),
            .document(documentID: nestedPDF.id, fragment: "page4")
        )
        XCTAssertEqual(
            resolve(
                "[relative](example.pdf#page=4)",
                source: source,
                root: root,
                documents: documents
            ),
            .document(documentID: nestedRootLevelPDF.id, fragment: "page4")
        )
        XCTAssertEqual(
            resolve(
                "[[example.pdf]]",
                source: source,
                root: root,
                documents: documents
            ),
            .document(documentID: nestedRootLevelPDF.id, fragment: nil)
        )
        XCTAssertEqual(
            resolve(
                "[[example.pdf#overview]]",
                source: source,
                root: root,
                documents: documents
            ),
            .document(documentID: nestedRootLevelPDF.id, fragment: "overview")
        )
        XCTAssertEqual(
            resolve(
                "[[example.pdf?view=compact#page=4]]",
                source: source,
                root: root,
                documents: documents
            ),
            .document(documentID: nestedRootLevelPDF.id, fragment: "page4")
        )
        XCTAssertEqual(
            resolve(
                "[[./papers/example.pdf#page=4]]",
                source: source,
                root: root,
                documents: documents
            ),
            .document(documentID: nestedPDF.id, fragment: "page4")
        )
        XCTAssertEqual(
            resolve(
                "[[../papers/example.pdf#page=4]]",
                source: source,
                root: root,
                documents: documents
            ),
            .document(documentID: parentPDF.id, fragment: "page4")
        )
        XCTAssertEqual(
            resolve(
                "[[sub/Note.md]]",
                source: source,
                root: root,
                documents: documents
            ),
            .document(documentID: nestedNote.id, fragment: nil)
        )
    }

    func testResolverMakesAmbiguousWikilinksExplicit() throws {
        let root = URL(fileURLWithPath: "/tmp/monknot-wikilink-resolution", isDirectory: true)
        let source = WorkspaceDocument(url: root.appendingPathComponent("Source.md"), rootURL: root)
        let first = WorkspaceDocument(url: root.appendingPathComponent("One/Daily.md"), rootURL: root)
        let second = WorkspaceDocument(url: root.appendingPathComponent("Two/Daily.md"), rootURL: root)
        let link = try XCTUnwrap(parser.links(in: "[[Daily]]").first)

        XCTAssertEqual(
            resolver.resolve(link, sourceDocument: source, workspaceRootURL: root, documents: [source, first, second]),
            .ambiguous(documentIDs: [first.id, second.id].sorted())
        )
    }

    func testResolverAllowsDocumentedExternalSchemesAndRejectsOtherSchemes() throws {
        let root = URL(fileURLWithPath: "/tmp/monknot-link-schemes", isDirectory: true)
        let source = WorkspaceDocument(url: root.appendingPathComponent("Source.md"), rootURL: root)

        XCTAssertEqual(
            resolve("[web](https://example.com/a)", source: source, root: root, documents: [source]),
            .external(try XCTUnwrap(URL(string: "https://example.com/a")))
        )
        XCTAssertEqual(
            resolve("[mail](mailto:hello@example.com)", source: source, root: root, documents: [source]),
            .external(try XCTUnwrap(URL(string: "mailto:hello@example.com")))
        )
        XCTAssertEqual(
            resolve("[bad](javascript:alert)", source: source, root: root, documents: [source]),
            .invalid
        )
    }

    func testResolverRejectsTraversalAndFileURLsOutsideWorkspace() throws {
        let root = URL(fileURLWithPath: "/tmp/monknot-link-boundary/workspace", isDirectory: true)
        let source = WorkspaceDocument(url: root.appendingPathComponent("Source.md"), rootURL: root)
        let outsideURL = URL(fileURLWithPath: "/tmp/monknot-link-boundary/Outside.md")

        XCTAssertEqual(
            resolve("[outside](../Outside.md)", source: source, root: root, documents: [source]),
            .invalid
        )
        XCTAssertEqual(
            resolve("[outside](\(outsideURL.absoluteString))", source: source, root: root, documents: [source]),
            .invalid
        )
        XCTAssertEqual(
            resolve("[malformed](Bad%ZZ.md)", source: source, root: root, documents: [source]),
            .invalid
        )
    }
}
