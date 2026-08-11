import Foundation
import XCTest
@testable import MonknotCore

final class MarkdownWorkspaceLinkServiceTests: XCTestCase {
    func testReferenceStyleUsageNavigatesThroughItsDefinitionWithoutRewritingUsage() throws {
        let markdown = "Read [the guide][Guide Ref].\n\n[guide ref]: Guide.md#Setup\n"
        let links = MarkdownWorkspaceLinkParser().links(in: markdown)
        let usage = try XCTUnwrap(links.first { $0.kind == .referenceUsage })

        XCTAssertEqual(usage.destination, "Guide.md#Setup")
        XCTAssertEqual(usage.label, "the guide")
        XCTAssertEqual(
            MarkdownWorkspaceLinkParser().link(
                atUTF16Offset: (markdown as NSString).range(of: "the guide").location,
                in: markdown
            ),
            usage
        )
        XCTAssertEqual(
            (markdown as NSString).substring(with: usage.destinationRange.nsRange),
            "Guide Ref"
        )
    }

    private let parser = MarkdownWorkspaceLinkParser()
    private let resolver = MarkdownWorkspaceLinkResolver()

    func testParserFindsMarkdownWikilinkAndHeadingDestinationsWithExactRanges() throws {
        let markdown = "See [guide](notes/Guide.md#Setup), [[Daily Note#Plan|today]], and [above](#Overview)."

        let links = parser.links(in: markdown)

        XCTAssertEqual(links.map(\.kind), [.markdown, .wikilink, .markdown])
        XCTAssertEqual(links.map(\.destination), ["notes/Guide.md#Setup", "Daily Note#Plan", "#Overview"])
        XCTAssertEqual(links.map(\.label), ["guide", "today", "above"])
        for link in links {
            XCTAssertEqual((markdown as NSString).substring(with: link.destinationRange.nsRange), link.destination)
        }
        let wikilinkOffset = (markdown as NSString).range(of: "Daily Note").location
        XCTAssertEqual(parser.link(atUTF16Offset: wikilinkOffset, in: markdown), links[1])
    }

    func testParserSupportsAngleBracketImageAndReferenceDestinationsWhileIgnoringCode() {
        let markdown = """
        [spaced](<Folder/My Note.md>) ![image](assets/image.png) `[[inline]]`

        [guide]: Reference/Guide.md?mode=read#setup "Guide"

        ```md
        [fenced](Hidden.md)
        [[Also Hidden]]
        ```

        [[Shown]]
        """

        let links = parser.links(in: markdown)

        XCTAssertEqual(
            links.map(\.destination),
            ["Folder/My Note.md", "assets/image.png", "Reference/Guide.md?mode=read#setup", "Shown"]
        )
        XCTAssertEqual(links.map(\.kind), [.markdown, .image, .referenceDefinition, .wikilink])
        let reference = links[2]
        XCTAssertEqual(reference.destinationComponents.path, "Reference/Guide.md")
        XCTAssertEqual(reference.destinationComponents.query, "mode=read")
        XCTAssertEqual(reference.destinationComponents.fragment, "setup")
        XCTAssertEqual(reference.destinationComponents.suffix, "?mode=read#setup")
        XCTAssertEqual(
            reference.destinationComponents.replacingPath(with: "Moved/Guide.md"),
            "Moved/Guide.md?mode=read#setup"
        )
    }

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

    func testHeadingNormalizationMatchesRendererRulesAndFindsFirstHeading() {
        XCTAssertEqual(MarkdownHeadingFragment.normalized("  Hello, **World**!  "), "hello-world")
        XCTAssertEqual(MarkdownHeadingFragment.normalized("日本語"), "section")
        XCTAssertEqual(MarkdownHeadingFragment.normalized("A---B"), "a-b")

        let markdown = """
        ```md
        # Hidden Heading
        ```
        # Hello, **World**!
        ## Later
        """
        XCTAssertEqual(
            MarkdownHeadingFragment.sourceLocation(for: "hello-world", in: markdown),
            MarkdownSourceLocation(line: 4, offset: 0)
        )
        XCTAssertNil(MarkdownHeadingFragment.sourceLocation(for: "hidden-heading", in: markdown))
    }

    func testSourceLocationValidationRejectsStaleLinesAndOffsets() {
        let text = "alpha\r\n😀beta\n"

        XCTAssertEqual(
            MarkdownSourceLocationValidator.validated(
                MarkdownSourceLocation(line: 2, offset: 2),
                in: text
            ),
            MarkdownSourceLocation(line: 2, offset: 2)
        )
        XCTAssertNil(MarkdownSourceLocationValidator.validated(
            MarkdownSourceLocation(line: 2, offset: 7),
            in: text
        ))
        XCTAssertNil(MarkdownSourceLocationValidator.validated(
            MarkdownSourceLocation(line: 4, offset: 0),
            in: text
        ))
        XCTAssertNil(MarkdownSourceLocationValidator.validated(
            MarkdownSourceLocation(line: 0, offset: 0),
            in: text
        ))
    }

    func testTaskReplacementRevalidatesLineAndExpectedStateWhilePreservingCRLF() throws {
        let markdown = "Intro\r\n- [ ] first\r\n1. [X] second\r\n"
        let first = try XCTUnwrap(MarkdownTaskSourceMutation.replacement(
            in: markdown,
            sourceLine: 2,
            expectedChecked: false,
            desiredChecked: true
        ))
        XCTAssertEqual((markdown as NSString).substring(with: first.range.nsRange), " ")
        XCTAssertEqual(first.replacementText, "x")

        let second = try XCTUnwrap(MarkdownTaskSourceMutation.replacement(
            in: markdown,
            sourceLine: 3,
            expectedChecked: true,
            desiredChecked: false
        ))
        XCTAssertEqual(second.expectedText, "X")
        XCTAssertEqual(second.replacementText, " ")
        XCTAssertNil(MarkdownTaskSourceMutation.replacement(
            in: markdown,
            sourceLine: 2,
            expectedChecked: true,
            desiredChecked: false
        ))
        XCTAssertNil(MarkdownTaskSourceMutation.replacement(
            in: markdown,
            sourceLine: 1,
            expectedChecked: false,
            desiredChecked: true
        ))
    }

    private func resolve(
        _ markdown: String,
        source: WorkspaceDocument,
        root: URL,
        documents: [WorkspaceDocument]
    ) -> MarkdownWorkspaceLinkResolution {
        guard let link = parser.links(in: markdown).first else { return .invalid }
        return resolver.resolve(
            link,
            sourceDocument: source,
            workspaceRootURL: root,
            documents: documents
        )
    }
}
