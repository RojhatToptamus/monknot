import Foundation
import XCTest
@testable import MonknotCore

final class FlowMarkdownInlineProtectedRangeTests: FlowProtectedRangeTestCase {
    func testMarkdownProtectsIncompleteLinkDestinationsWhileTyping() {
        for markdown in ["[label](docs/teh", "Open [[teh", "Open [[target|unfinished alias"] {
            let destinationRange = (markdown as NSString).range(of: "teh")
            let protectedRange = destinationRange.location == NSNotFound
                ? (markdown as NSString).range(of: "unfinished alias")
                : destinationRange
            XCTAssertTrue(
                service.protectedRanges(in: markdown, mode: .markdown).contains {
                    NSIntersectionRange($0, protectedRange).length == protectedRange.length
                },
                "Expected the unfinished destination in \(markdown) to be protected"
            )
        }
    }

    func testMarkdownRequiresAnUnescapedOpeningBracketForLinkDestination() {
        XCTAssertEqual(protectedSubstrings(in: "array](ordinary prose)"), [])
        XCTAssertEqual(protectedSubstrings(in: #"\[label](ordinary prose)"#), [#"\["#])

        let markdown = "[outer [inner]](docs/file.md)"
        let destination = (markdown as NSString).range(of: "docs/file.md")
        XCTAssertTrue(service.protectedRanges(in: markdown, mode: .markdown).contains {
            NSIntersectionRange($0, destination).length == destination.length
        })
    }

    func testMarkdownIgnoresIncompleteDestinationExamplesInsideCode() {
        let markdown = """
        Inline `Open [[unfinished` editable after wikilink example.
        Inline `[label](unfinished` editable after link example.

        ```markdown
        Open [[unfinished
        [label](unfinished
        ```
        Editable after fenced examples.
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for prose in [
            "editable after wikilink example.",
            "editable after link example.",
            "Editable after fenced examples.",
        ] {
            let proseRange = source.range(of: prose)
            XCTAssertFalse(ranges.contains {
                NSIntersectionRange($0, proseRange).length > 0
            }, "Expected \(prose) to remain editable")
        }
    }

    func testMarkdownProtectsNestedAndEscapedDestinationParentheses() {
        for markdown in [
            "[label](docs/foo(bar).md)",
            #"[label](docs/foo\(bar\).md)"#,
        ] {
            let source = markdown as NSString
            let destinationRange = source.range(of: "docs")
            let ranges = service.protectedRanges(in: markdown, mode: .markdown)
            XCTAssertTrue(ranges.contains {
                NSLocationInRange(destinationRange.location, $0) && NSMaxRange($0) == source.length
            }, "Expected the complete destination in \(markdown) to be protected")
        }
    }

    func testMarkdownProtectsNestedPrefixesClosingATXMarkersAndLongEmphasisRuns() {
        let markdown = """
        >   - [ ] # Nested heading ###
        ****bold**** and café_culture
        """
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for marker in [">", "-", "[ ]", "#", "###", "****"] {
            let markerRange = source.range(of: marker)
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, markerRange).length == markerRange.length
            }, "Expected \(marker) to be protected")
        }
        let closingEmphasis = source.range(
            of: "****",
            options: [.backwards],
            range: NSRange(location: 0, length: source.length)
        )
        XCTAssertTrue(ranges.contains {
            NSIntersectionRange($0, closingEmphasis).length == closingEmphasis.length
        })
        let intrawordUnderscore = source.range(of: "café_culture")
        XCTAssertFalse(ranges.contains {
            NSIntersectionRange($0, intrawordUnderscore).length > 0
        })
    }

    func testMarkdownProtectsWorkspaceLinkDestinationsFromSharedParser() {
        let markdown = """
        [guide](docs/Guide.md) [[Daily Note#Plan|today]] ![cover](images/cover.png) [use][ref]

        [ref]: references/Source.md
        """

        let links = MarkdownWorkspaceLinkParser().links(in: markdown)
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for link in links {
            XCTAssertTrue(
                ranges.contains { NSIntersectionRange($0, link.destinationRange.nsRange).length == link.destinationRange.length },
                "Expected \(link.destination) to be protected"
            )
        }
    }

    func testMarkdownSelfClosingCodeAndPreTagsDoNotProtectFollowingProse() {
        let markdown = "<code />Editable after code. <pre/>Editable after pre."
        let source = markdown as NSString
        let ranges = service.protectedRanges(in: markdown, mode: .markdown)

        for tag in ["<code />", "<pre/>"] {
            let tagRange = source.range(of: tag)
            XCTAssertTrue(ranges.contains {
                NSIntersectionRange($0, tagRange).length == tagRange.length
            }, "Expected \(tag) to be protected")
        }
        for prose in ["Editable after code.", "Editable after pre."] {
            let proseRange = source.range(of: prose)
            XCTAssertFalse(ranges.contains {
                NSIntersectionRange($0, proseRange).length > 0
            }, "Expected \(prose) to remain editable")
        }
    }
}
