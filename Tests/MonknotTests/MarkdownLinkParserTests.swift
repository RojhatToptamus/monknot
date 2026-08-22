import Foundation
import XCTest
@testable import MonknotCore

final class MarkdownLinkParserTests: MarkdownWorkspaceLinkTestCase {
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
}
